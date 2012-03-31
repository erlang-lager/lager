%% Copyright (c) 2011 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.

%% @doc A process that does a gen_event:add_sup_handler and attempts to re-add
%% event handlers when they exit.

%% @private

-module(lager_handler_watcher).

-behaviour(gen_server).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
        code_change/3]).

-export([start_link/3, start/3]).

-record(state, {
        module,
        config,
        event
    }).

start_link(Event, Module, Config) ->
    gen_server:start_link(?MODULE, [Event, Module, Config], []).

start(Event, Module, Config) ->
    gen_server:start(?MODULE, [Event, Module, Config], []).

init([Event, Module, Config]) ->
    install_handler(Event, Module, Config),
    {ok, #state{event=Event, module=Module, config=Config}}.

handle_call(_Call, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({gen_event_EXIT, Module, normal}, #state{module=Module} = State) ->
    {stop, normal, State};
handle_info({gen_event_EXIT, Module, shutdown}, #state{module=Module} = State) ->
    {stop, normal, State};
handle_info({gen_event_EXIT, Module, Reason}, #state{module=Module,
        config=Config, event=Event} = State) ->
    case lager:log(error, self(), "Lager event handler ~p exited with reason ~s",
        [Module, error_logger_lager_h:format_reason(Reason)]) of
      ok ->
        install_handler(Event, Module, Config);
      {error, _} ->
        %% lager is not working, so installing a handler won't work
        ok
    end,
    {noreply, State};
handle_info(reinstall_handler, #state{module=Module, config=Config, event=Event} = State) ->
    install_handler(Event, Module, Config),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% internal

install_handler(Event, Module, Config) ->
    case gen_event:add_sup_handler(Event, Module, Config) of
        ok ->
            _ = lager:log(debug, self(), "Lager installed handler ~p into ~p", [Module, Event]),
            ok;
        Error ->
            %% try to reinstall it later
            _ = lager:log(error, self(), "Lager failed to install handler ~p into"
               " ~p, retrying later : ~p", [Module, Event, Error]),
            erlang:send_after(5000, self(), reinstall_handler),
            ok
    end.

-ifdef(TEST).

from_now(Seconds) ->
    {Mega, Secs, Micro} = os:timestamp(),
    {Mega, Secs + Seconds, Micro}.

reinstall_on_initial_failure_test_() ->
    {timeout, 60000,
        [
            fun() ->
                    error_logger:tty(false),
                    application:load(lager),
                    application:set_env(lager, handlers, [{lager_test_backend, info}, {lager_crash_backend, [from_now(2), undefined]}]),
                    application:set_env(lager, error_logger_redirect, false),
                    application:unset_env(lager, crash_log),
                    application:start(compiler),
                    application:start(syntax_tools),
                    application:start(lager),
                    try
                      ?assertEqual(1, lager_test_backend:count()),
                      {_Level, _Time, [_, _, Message]} = lager_test_backend:pop(),
                      ?assertMatch("Lager failed to install handler lager_crash_backend into lager_event, retrying later :"++_, lists:flatten(Message)),
                      ?assertEqual(0, lager_test_backend:count()),
                      timer:sleep(6000),
                      ?assertEqual(0, lager_test_backend:count()),
                      ?assert(lists:member(lager_crash_backend, gen_event:which_handlers(lager_event)))
                    after
                      application:stop(lager),
                      error_logger:tty(true)
                    end
            end
        ]
    }.

reinstall_on_runtime_failure_test_() ->
    {timeout, 60000,
        [
            fun() ->
                    error_logger:tty(false),
                    application:load(lager),
                    application:set_env(lager, handlers, [{lager_test_backend, info}, {lager_crash_backend, [undefined, from_now(5)]}]),
                    application:set_env(lager, error_logger_redirect, false),
                    application:unset_env(lager, crash_log),
                    application:start(compiler),
                    application:start(syntax_tools),
                    application:start(lager),
                    try
                        ?assertEqual(0, lager_test_backend:count()),
                        ?assert(lists:member(lager_crash_backend, gen_event:which_handlers(lager_event))),
                        timer:sleep(6000),
                        ?assertEqual(2, lager_test_backend:count()),
                        {_Level, _Time, [_, _, Message]} = lager_test_backend:pop(),
                        ?assertEqual("Lager event handler lager_crash_backend exited with reason crash", lists:flatten(Message)),
                        {_Level2, _Time2, [_, _, Message2]} = lager_test_backend:pop(),
                        ?assertMatch("Lager failed to install handler lager_crash_backend into lager_event, retrying later :"++_, lists:flatten(Message2)),
                        ?assertEqual(false, lists:member(lager_crash_backend, gen_event:which_handlers(lager_event)))
                    after
                       application:stop(lager),
                       error_logger:tty(true)
                   end
            end
        ]
    }.


-endif.
