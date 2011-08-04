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

%% @doc Console backend for lager. Configured with a single option, the loglevel
%% desired.

-module(lager_console_backend).

-behaviour(gen_event).

-export([init/1, handle_call/2, handle_event/2, handle_info/2, terminate/2,
        code_change/3]).

-record(state, {level, verbose}).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% @private
init(Level) when is_atom(Level) ->
    {ok, #state{level=lager_util:level_to_num(Level), verbose=false}};
init([Level, Verbose]) ->
    {ok, #state{level=lager_util:level_to_num(Level), verbose=Verbose}}.

%% @private
handle_call(get_loglevel, #state{level=Level} = State) ->
    {ok, Level, State};
handle_call({set_loglevel, Level}, State) ->
    {ok, ok, State#state{level=lager_util:level_to_num(Level)}};
handle_call(_Request, State) ->
    {ok, ok, State}.

%% @private
handle_event({log, Level, {Date, Time}, [LevelStr, Location, Message]},
  #state{level=LogLevel, verbose=Verbose} = State) when Level =< LogLevel ->
    case Verbose of
        true ->
            io:put_chars([Date, " ", Time, " ", LevelStr, Location, Message, "\n"]);
        _ ->
            io:put_chars([Time, " ", LevelStr, Message, "\n"])
    end,
    {ok, State};
handle_event(_Event, State) ->
    {ok, State}.

%% @private
handle_info(_Info, State) ->
    {ok, State}.

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

-ifdef(TEST).
console_log_test_() ->
    %% tiny recursive fun that pretends to be a group leader
    F = fun(Self) ->
            fun() ->
                    YComb = fun(Fun) ->
                            receive
                                {io_request, From, ReplyAs, {put_chars, unicode, _Msg}} = Y ->
                                    From ! {io_reply, ReplyAs, ok},
                                    Self ! Y,
                                    Fun(Fun);
                                Other ->
                                    ?debugFmt("unexpected message ~p~n", [Other]),
                                    Self ! Other
                            end
                    end,
                    YComb(YComb)
            end
    end,

    {foreach,
        fun() ->
                error_logger:tty(false),
                application:load(lager),
                application:set_env(lager, handlers, []),
                application:set_env(lager, error_logger_redirect, false),
                application:start(lager)
        end,
        fun(_) ->
                application:stop(lager),
                application:load(lager),
                error_logger:tty(true)
        end,
        [
            {"regular console logging",
                fun() ->
                        Pid = spawn(F(self())),
                        gen_event:add_handler(lager_event, lager_console_backend, info),
                        erlang:group_leader(Pid, whereis(lager_event)),
                        lager:log(info, self(), "Test message"),
                        receive
                            {io_request, From, ReplyAs, {put_chars, unicode, Msg}} ->
                                From ! {io_reply, ReplyAs, ok},
                                ?assertMatch([_, "[info]", "Test message\n"], re:split(Msg, " ", [{return, list}, {parts, 3}]))
                        after
                            500 ->
                                ?assert(false)
                        end
                end
            },
            {"verbose console logging",
                fun() ->
                        Pid = spawn(F(self())),
                        erlang:group_leader(Pid, whereis(lager_event)),
                        gen_event:add_handler(lager_event, lager_console_backend, [info, true]),
                        lager:log(info, self(), "Test message"),
                        lager:log(info, self(), "Test message"),
                        PidStr = pid_to_list(self()),
                        receive
                            {io_request, _, _, {put_chars, unicode, Msg}} ->
                                ?assertMatch([_, _, "[info]", PidStr, "Test message\n"], re:split(Msg, " ", [{return, list}, {parts, 5}]))
                        after
                            500 ->
                                ?assert(false)
                        end
                end
            }
        ]
    }.

set_loglevel_test_() ->
    {foreach,
        fun() ->
                error_logger:tty(false),
                application:load(lager),
                application:set_env(lager, handlers, [{lager_console_backend, info}]),
                application:set_env(lager, error_logger_redirect, false),
                application:start(lager)
        end,
        fun(_) ->
                application:stop(lager),
                application:load(lager),
                error_logger:tty(true)
        end,
        [
            {"Get/set loglevel test",
                fun() ->
                        ?assertEqual(info, lager:get_loglevel(lager_console_backend)),
                        lager:set_loglevel(lager_console_backend, debug),
                        ?assertEqual(debug, lager:get_loglevel(lager_console_backend))
                end
            }
        ]
    }.

-endif.
