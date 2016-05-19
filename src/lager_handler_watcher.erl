%% Copyright (c) 2011-2012 Basho Technologies, Inc.  All Rights Reserved.
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

-include("lager.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
        code_change/3]).

-export([start_link/3, start/3]).

-record(state, {
        module :: atom(),
        config :: any(),
        sink :: pid() | atom()
    }).

start_link(Sink, Module, Config) ->
    gen_server:start_link(?MODULE, [Sink, Module, Config], []).

start(Sink, Module, Config) ->
    gen_server:start(?MODULE, [Sink, Module, Config], []).

init([Sink, Module, Config]) ->
    install_handler(Sink, Module, Config),
    {ok, #state{sink=Sink, module=Module, config=Config}}.

handle_call(_Call, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({gen_event_EXIT, Module, normal}, #state{module=Module} = State) ->
    {stop, normal, State};
handle_info({gen_event_EXIT, Module, shutdown}, #state{module=Module} = State) ->
    {stop, normal, State};
handle_info({gen_event_EXIT, Module, {'EXIT', {kill_me, [_KillerHWM, KillerReinstallAfter]}}},
        #state{module=Module, sink=Sink} = State) ->
    %% Brutally kill the manager but stay alive to restore settings.
    %%
    %% SinkPid here means the gen_event process. Handlers *all* live inside the
    %% same gen_event process space, so when the Pid is killed, *all* of the 
    %% pending log messages in its mailbox will die too.
    SinkPid = whereis(Sink),
    unlink(SinkPid),
    exit(SinkPid, kill),
    erlang:send_after(KillerReinstallAfter, self(), {reboot, Sink}),
    {noreply, State};
handle_info({gen_event_EXIT, Module, Reason}, #state{module=Module,
        config=Config, sink=Sink} = State) ->
    case lager:log(error, self(), "Lager event handler ~p exited with reason ~s",
        [Module, error_logger_lager_h:format_reason(Reason)]) of
      ok ->
        install_handler(Sink, Module, Config);
      {error, _} ->
        %% lager is not working, so installing a handler won't work
        ok
    end,
    {noreply, State};
handle_info(reinstall_handler, #state{module=Module, config=Config, sink=Sink} = State) ->
    install_handler(Sink, Module, Config),
    {noreply, State};
handle_info({reboot, Sink}, State) ->
    _ = lager_app:boot(Sink),
    {noreply, State};
handle_info(stop, State) ->
    {stop, normal, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% internal
install_handler(Sink, lager_backend_throttle, Config) ->
    %% The lager_backend_throttle needs to know to which sink it is
    %% attached, hence this admittedly ugly workaround. Handlers are
    %% sensitive to the structure of the configuration sent to `init',
    %% sadly, so it's not trivial to add a configuration item to be
    %% ignored to backends without breaking 3rd party handlers.
    install_handler2(Sink, lager_backend_throttle, [{sink, Sink}|Config]);
install_handler(Sink, Module, Config) ->
    install_handler2(Sink, Module, Config).

%% private
install_handler2(Sink, Module, Config) ->
    case gen_event:add_sup_handler(Sink, Module, Config) of
        ok ->
            ?INT_LOG(debug, "Lager installed handler ~p into ~p", [Module, Sink]),
            lager:update_loglevel_config(Sink),
            ok;
        {error, {fatal, Reason}} ->
            ?INT_LOG(error, "Lager fatally failed to install handler ~p into"
                " ~p, NOT retrying: ~p", [Module, Sink, Reason]),
            %% tell ourselves to stop
            self() ! stop,
            ok;
        Error ->
            %% try to reinstall it later
            ?INT_LOG(error, "Lager failed to install handler ~p into"
               " ~p, retrying later : ~p", [Module, Sink, Error]),
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
                    lager:start(),
                    try
                      {_Level, _Time, Message, _Metadata} = lager_test_backend:pop(),
                      ?assertMatch("Lager failed to install handler lager_crash_backend into lager_event, retrying later :"++_, lists:flatten(Message)),
                      timer:sleep(6000),
                      lager_test_backend:flush(),
                      ?assertEqual(0, lager_test_backend:count()),
                      ?assert(lists:member(lager_crash_backend, gen_event:which_handlers(lager_event)))
                    after
                      application:stop(lager),
                      application:stop(goldrush),
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
                    lager:start(),
                    try
                        ?assert(lists:member(lager_crash_backend, gen_event:which_handlers(lager_event))),
                        timer:sleep(6000),

                        pop_until("Lager event handler lager_crash_backend exited with reason crash", fun lists:flatten/1),
                        pop_until("Lager failed to install handler lager_crash_backend into lager_event, retrying later",
                                  fun(Msg) -> string:substr(lists:flatten(Msg), 1, 84) end),
                        ?assertEqual(false, lists:member(lager_crash_backend, gen_event:which_handlers(lager_event)))
                    after
                       application:stop(lager),
                       application:stop(goldrush),
                       error_logger:tty(true)
                   end
            end
        ]
    }.

pop_until(String, Fun) ->
    try_backend_pop(lager_test_backend:pop(), String, Fun).

try_backend_pop(undefined, String, _Fun) ->
    throw("Not found: " ++ String);
try_backend_pop({_Severity, _Date, Msg, _Metadata}, String, Fun) ->
    case Fun(Msg) of
        String ->
            ok;
        _ ->
            try_backend_pop(lager_test_backend:pop(), String, Fun)
    end.

-endif.
