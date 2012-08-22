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

-record(state, {level, verbose, mod_levels}).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-compile([{parse_transform, lager_transform}]).
-endif.

-include("lager.hrl").

%% @private
init(Level) when is_atom(Level) ->
    case lists:member(Level, ?LEVELS) of
        true ->
            {ok, #state{level=lager_util:level_to_num(Level), verbose=false, mod_levels = []}};
        _ ->
            {error, bad_log_level}
    end;
init([Level, Verbose]) ->
    case lists:member(Level, ?LEVELS) of
        true ->
            {ok, #state{level=lager_util:level_to_num(Level), verbose=Verbose, mod_levels = []}};
        _ ->
            {error, bad_log_level}
    end.


%% @private
handle_call(get_loglevel, #state{level=GenLevel, mod_levels = ModLvls} = State) ->
    Level = erlang:tl(lists:sort([GenLevel | [ ModLvl || {_, ModLvl} <- ModLvls ]])),
    {ok, Level, State};
handle_call({get_mod_loglevel, Module}, #state{mod_levels = ModLvls} = State) ->
    case lists:keysearch(Module, 1, ModLvls) of
        {value, {_, Level}} ->
            {ok, Level, State};
        false ->
            {ok, false, State}
    end;
handle_call({set_loglevel, Level, Module}, #state{mod_levels = ModLvls} = State) ->
    case lists:member(Level, ?LEVELS) of
        true ->
            case Module of
                '_' ->
                    {ok, ok, State#state{level=lager_util:level_to_num(Level)}};
                _ ->
                    case lists:keymember(Module, 1, ModLvls) of
                        true ->
                            {ok, ok, State#state{mod_levels =
                                lists:keyreplace(Module, 1, ModLvls,
                                    {Module, lager_util:level_to_num(Level)})}};
                        false ->
                            {ok, ok, State#state{mod_levels = [{Module, lager_util:level_to_num(Level)}|ModLvls]}}
                    end
            end;
        _ ->
            {ok, {error, bad_log_level}, State}
    end;
handle_call({clear_loglevel, '_'}, State) ->
    {ok, ok, State#state{ mod_levels = [] }};
handle_call({clear_loglevel, Module}, #state{mod_levels = ModLvls} = State) ->
    {ok, ok, State#state{ mod_levels = lists:keydelete(Module, 1, ModLvls) }};
handle_call(_Request, State) ->
    {ok, ok, State}.

%% @private
handle_event({log, {Dest, Module}, Level, {Date, Time}, [LevelStr, Location, Message]},
    #state{level=GenLevel, verbose=Verbose, mod_levels = ModLvls} = State) ->
    case lists:member(lager_console_backend, Dest)
        andalso lager_util:check_loglevel(GenLevel, ModLvls, Module, Level) of
            true ->
                case Verbose of
                    true ->
                        io:put_chars(user, [Date, " ", Time, " ", LevelStr, Location, Message, "\r\n"]);
                    _ ->
                        io:put_chars(user, [Time, " ", LevelStr, Message, "\r\n"])
                end,
                {ok, State};
            false ->
                {ok, State}
    end;
handle_event({log, Module, Level, {Date, Time}, [LevelStr, Location, Message]},
  #state{level=GenLevel, verbose=Verbose, mod_levels = ModLvls} = State) ->
    case lager_util:check_loglevel(GenLevel, ModLvls, Module, Level) of
        true ->
            case Verbose of
                true ->
                    io:put_chars(user, [Date, " ", Time, " ", LevelStr, Location, Message, "\r\n"]);
                _ ->
                    io:put_chars(user, [Time, " ", LevelStr, Message, "\r\n"])
            end;
        false ->
            ok
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
                application:start(compiler),
                application:start(syntax_tools),
                application:start(lager),
                whereis(user)
        end,
        fun(User) ->
                unregister(user),
                register(user, User),
                application:stop(lager),
                error_logger:tty(true)
        end,
        [
            {"regular console logging",
                fun() ->
                        Pid = spawn(F(self())),
                        gen_event:add_handler(lager_event, lager_console_backend, info),
                        unregister(user),
                        register(user, Pid),
                        erlang:group_leader(Pid, whereis(lager_event)),
                        lager:log(info, self(), "Test message"),
                        receive
                            {io_request, From, ReplyAs, {put_chars, unicode, Msg}} ->
                                From ! {io_reply, ReplyAs, ok},
                                ?assertMatch([_, "[info]", "Test message\r\n"], re:split(Msg, " ", [{return, list}, {parts, 3}]))
                        after
                            500 ->
                                ?assert(false)
                        end
                end
            },
            {"verbose console logging",
                fun() ->
                        Pid = spawn(F(self())),
                        unregister(user),
                        register(user, Pid),
                        erlang:group_leader(Pid, whereis(lager_event)),
                        gen_event:add_handler(lager_event, lager_console_backend, [info, true]),
                        lager:log(info, self(), "Test message"),
                        lager:log(info, self(), "Test message"),
                        PidStr = pid_to_list(self()),
                        receive
                            {io_request, _, _, {put_chars, unicode, Msg}} ->
                                ?assertMatch([_, _, "[info]", PidStr, "Test message\r\n"], re:split(Msg, " ", [{return, list}, {parts, 5}]))
                        after
                            500 ->
                                ?assert(false)
                        end
                end
            },
            {"tracing should work",
                fun() ->
                        Pid = spawn(F(self())),
                        unregister(user),
                        register(user, Pid),
                        gen_event:add_handler(lager_event, lager_console_backend, info),
                        erlang:group_leader(Pid, whereis(lager_event)),
                        lager_mochiglobal:put(loglevel, {?INFO, []}),
                        lager:debug("Test message"),
                        receive
                            {io_request, From, ReplyAs, {put_chars, unicode, _Msg}} ->
                                From ! {io_reply, ReplyAs, ok},
                                ?assert(false)
                        after
                            500 ->
                                ?assert(true)
                        end,
                        {ok, _} = lager:trace_console([{module, ?MODULE}]),
                        lager:debug("Test message"),
                        receive
                            {io_request, From1, ReplyAs1, {put_chars, unicode, Msg1}} ->
                                From1 ! {io_reply, ReplyAs1, ok},
                                ?assertMatch([_, "[debug]", "Test message\r\n"], re:split(Msg1, " ", [{return, list}, {parts, 3}]))
                        after
                            500 ->
                                ?assert(false)
                        end
                end
            },
            {"tracing doesn't duplicate messages",
                fun() ->
                        Pid = spawn(F(self())),
                        unregister(user),
                        register(user, Pid),
                        gen_event:add_handler(lager_event, lager_console_backend, info),
                        lager_mochiglobal:put(loglevel, {?INFO, []}),
                        erlang:group_leader(Pid, whereis(lager_event)),
                        lager:debug("Test message"),
                        receive
                            {io_request, From, ReplyAs, {put_chars, unicode, _Msg}} ->
                                From ! {io_reply, ReplyAs, ok},
                                ?assert(false)
                        after
                            500 ->
                                ?assert(true)
                        end,
                        {ok, _} = lager:trace_console([{module, ?MODULE}]),
                        lager:error("Test message"),
                        receive
                            {io_request, From1, ReplyAs1, {put_chars, unicode, Msg1}} ->
                                From1 ! {io_reply, ReplyAs1, ok},
                                ?assertMatch([_, "[error]", "Test message\r\n"], re:split(Msg1, " ", [{return, list}, {parts, 3}]))
                        after
                            1000 ->
                                ?assert(false)
                        end,
                        %% make sure this event wasn't duplicated
                        receive
                            {io_request, From2, ReplyAs2, {put_chars, unicode, _Msg2}} ->
                                From2 ! {io_reply, ReplyAs2, ok},
                                ?assert(false)
                        after
                            500 ->
                                ?assert(true)
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
                error_logger:tty(true)
        end,
        [
            {"Get/set loglevel test",
                fun() ->
                        ?assertEqual(info, lager:get_loglevel(lager_console_backend)),
                        lager:set_loglevel(lager_console_backend, debug),
                        ?assertEqual(debug, lager:get_loglevel(lager_console_backend))
                end
            },
            {"Get/set invalid loglevel test",
                fun() ->
                        ?assertEqual(info, lager:get_loglevel(lager_console_backend)),
                        ?assertEqual({error, bad_log_level},
                            lager:set_loglevel(lager_console_backend, fatfinger)),
                        ?assertEqual(info, lager:get_loglevel(lager_console_backend))
                end
            }

        ]
    }.

-endif.
