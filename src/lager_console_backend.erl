%% Copyright (c) 2011-2012, 2014 Basho Technologies, Inc.  All Rights Reserved.
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

%% @doc Console backend for lager.
%% Configuration is a proplist with the following keys:
%% <ul>
%%    <li>`level' - log level to use</li>
%%    <li>`use_stderr' - either `true' or `false', defaults to false. If set to true,
%%                       use standard error to output console log messages</li>
%%    <li>`formatter' - the module to use when formatting log messages. Defaults to
%%                      `lager_default_formatter'</li>
%%    <li>`formatter_config' - the format configuration string. Defaults to
%%                             `time [ severity ] message'</li>
%% </ul>

-module(lager_console_backend).

-behaviour(gen_event).

-export([init/1, handle_call/2, handle_event/2, handle_info/2, terminate/2,
        code_change/3]).

-record(state, {level :: {'mask', integer()},
                out = user :: user | standard_error | pid(),
                id :: atom() | {atom(), any()},
                formatter :: atom(),
                format_config :: any(),
                colors=[] :: list()}).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-compile([{parse_transform, lager_transform}]).
-endif.


-include("lager.hrl").

-define(TERSE_FORMAT,[time, " ", color, "[", severity,"] ", message]).
-define(DEFAULT_FORMAT_CONFIG, ?TERSE_FORMAT ++ [eol()]).
-define(FORMAT_CONFIG_OFF, [{eol, eol()}]).

-ifdef(TEST).
-define(DEPRECATED(_Msg), ok).
-else.
-define(DEPRECATED(Msg),
        io:format(user, "WARNING: This is a deprecated console configuration. Please use \"~w\" instead.~n", [Msg])).
-endif.

%% @private
init([Level]) when is_atom(Level) ->
    ?DEPRECATED([{level, Level}]),
    init([{level, Level}]);
init([Level, true]) when is_atom(Level) -> % for backwards compatibility
    ?DEPRECATED([{level, Level}, {formatter_config, [{eol, "\\r\\n\\"}]}]),
    init([{level, Level}, {formatter_config, ?FORMAT_CONFIG_OFF}]);
init([Level, false]) when is_atom(Level) -> % for backwards compatibility
    ?DEPRECATED([{level, Level}]),
    init([{level, Level}]);

init(Options) when is_list(Options) ->
    true = validate_options(Options),
    Colors = case application:get_env(lager, colored) of
        {ok, true} ->
            {ok, LagerColors} = application:get_env(lager, colors),
            LagerColors;
        _ -> []
    end,

    Level = get_option(level, Options, undefined),
    try {is_new_style_console_available(), lager_util:config_to_mask(Level)} of
        {false, _} ->
            Msg = "Lager's console backend is incompatible with the 'old' shell, not enabling it",
            %% be as noisy as possible, log to every possible place
            try
                alarm_handler:set_alarm({?MODULE, "WARNING: " ++ Msg})
            catch
                _:_ ->
                    error_logger:warning_msg(Msg ++ "~n")
            end,
            io:format("WARNING: " ++ Msg ++ "~n"),
            ?INT_LOG(warning, Msg, []),
            {error, {fatal, old_shell}};
        {true, L} ->
            [UseErr, GroupLeader, ID, Formatter, Config] = [ get_option(K, Options, Default) || {K, Default} <- [
                                                                                   {use_stderr, false},
                                                                                   {group_leader, false},
                                                                                   {id, ?MODULE},
                                                                                   {formatter, lager_default_formatter},
                                                                                   {formatter_config, ?DEFAULT_FORMAT_CONFIG}
                                                                                               ]
                                          ],
            Out = case UseErr of
                     false ->
                          case GroupLeader of
                              false -> user;
                              GLPid when is_pid(GLPid) ->
                                  erlang:monitor(process, GLPid),
                                  GLPid
                          end;
                     true -> standard_error
                  end,
            {ok, #state{level=L,
                    id=ID,
                    out=Out,
                    formatter=Formatter,
                    format_config=Config,
                    colors=Colors}}
    catch
        _:_ ->
            {error, {fatal, bad_log_level}}
    end;
init(Level) when is_atom(Level) ->
    ?DEPRECATED([{level, Level}]),
    init([{level, Level}]);
init(Other) ->
    {error, {fatal, {bad_console_config, Other}}}.

validate_options([]) -> true;
validate_options([{level, L}|T]) when is_atom(L) ->
    case lists:member(L, ?LEVELS) of
        false ->
            throw({error, {fatal, {bad_level, L}}});
        true ->
            validate_options(T)
    end;
validate_options([{use_stderr, true}|T]) ->
    validate_options(T);
validate_options([{use_stderr, false}|T]) ->
    validate_options(T);
validate_options([{formatter, M}|T]) when is_atom(M) ->
    validate_options(T);
validate_options([{formatter_config, C}|T]) when is_list(C) ->
    validate_options(T);
validate_options([{group_leader, L}|T]) when is_pid(L) ->
    validate_options(T);
validate_options([{id, {?MODULE, _}}|T]) ->
    validate_options(T);
validate_options([H|_]) ->
    throw({error, {fatal, {bad_console_config, H}}}).

get_option(K, Options, Default) ->
   case lists:keyfind(K, 1, Options) of
       {K, V} -> V;
       false -> Default
   end.

%% @private
handle_call(get_loglevel, #state{level=Level} = State) ->
    {ok, Level, State};
handle_call({set_loglevel, Level}, State) ->
    try lager_util:config_to_mask(Level) of
        Levels ->
            {ok, ok, State#state{level=Levels}}
    catch
        _:_ ->
            {ok, {error, bad_log_level}, State}
    end;
handle_call(_Request, State) ->
    {ok, ok, State}.

%% @private
handle_event({log, Message},
    #state{level=L,out=Out,formatter=Formatter,format_config=FormatConfig,colors=Colors,id=ID} = State) ->
    case lager_util:is_loggable(Message, L, ID) of
        true ->
            io:put_chars(Out, Formatter:format(Message,FormatConfig,Colors)),
            {ok, State};
        false ->
            {ok, State}
    end;
handle_event(_Event, State) ->
    {ok, State}.

%% @private
handle_info({'DOWN', _, process, Out, _}, #state{out=Out}) ->
    remove_handler;
handle_info(_Info, State) ->
    {ok, State}.

%% @private
terminate(remove_handler, _State=#state{id=ID}) ->
    %% have to do this asynchronously because we're in the event handlr
    spawn(fun() -> lager:clear_trace_by_destination(ID) end),
    ok;
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

eol() ->
    case application:get_env(lager, colored) of
        {ok, true}  ->
            "\e[0m\r\n";
        _ ->
            "\r\n"
    end.

-ifdef(TEST).
is_new_style_console_available() ->
    true.
-else.
is_new_style_console_available() ->
    %% Criteria:
    %% 1. If the user has specified '-noshell' on the command line,
    %%    then we will pretend that the new-style console is available.
    %%    If there is no shell at all, then we don't have to worry
    %%    about log events being blocked by the old-style shell.
    %% 2. Windows doesn't support the new shell, so all windows users
    %%    have is the oldshell.
    %% 3. If the user_drv process is registered, all is OK.
    %%    'user_drv' is a registered proc name used by the "new"
    %%    console driver.
    init:get_argument(noshell) /= error orelse
        element(1, os:type()) /= win32 orelse
        is_pid(whereis(user_drv)).
-endif.

-ifdef(TEST).
console_config_validation_test_() ->
    Good = [{level, info}, {use_stderr, true}],
    Bad1 = [{level, foo}, {use_stderr, flase}],
    Bad2 = [{level, info}, {use_stderr, flase}],
    AllGood = [{level, info}, {formatter, my_formatter},
               {formatter_config, ["blort", "garbage"]},
               {use_stderr, false}],
    [
     ?_assertEqual(true, validate_options(Good)),
     ?_assertThrow({error, {fatal, {bad_level, foo}}}, validate_options(Bad1)),
     ?_assertThrow({error, {fatal, {bad_console_config, {use_stderr, flase}}}}, validate_options(Bad2)),
     ?_assertEqual(true, validate_options(AllGood))
    ].

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
                lager:start(),
                whereis(user)
        end,
        fun(User) ->
                unregister(user),
                register(user, User),
                application:stop(lager),
                application:stop(goldrush),
                error_logger:tty(true)
        end,
        [
            {"regular console logging",
                fun() ->
                        Pid = spawn(F(self())),
                        unregister(user),
                        register(user, Pid),
                        erlang:group_leader(Pid, whereis(lager_event)),
                        gen_event:add_handler(lager_event, lager_console_backend, [{level, info}]),
                        lager_config:set({lager_event, loglevel}, {element(2, lager_util:config_to_mask(info)), []}),
                        lager:log(info, self(), "Test message"),
                        receive
                            {io_request, From, ReplyAs, {put_chars, unicode, Msg}} ->
                                From ! {io_reply, ReplyAs, ok},
                                TestMsg = "Test message" ++ eol(),
                                ?assertMatch([_, "[info]", TestMsg], re:split(Msg, " ", [{return, list}, {parts, 3}]))
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
                        lager_config:set({lager_event, loglevel}, {element(2, lager_util:config_to_mask(info)), []}),
                        lager:info("Test message"),
                        PidStr = pid_to_list(self()),
                        receive
                            {io_request, _, _, {put_chars, unicode, Msg}} ->
                                TestMsg = "Test message" ++ eol(),
                                ?assertMatch([_, _, "[info]", PidStr, _, TestMsg], re:split(Msg, "[ @]", [{return, list}, {parts, 6}]))
                        after
                            500 ->
                                ?assert(false)
                        end
                end
            },
            {"custom format console logging",
                fun() ->
                        Pid = spawn(F(self())),
                        unregister(user),
                        register(user, Pid),
                        erlang:group_leader(Pid, whereis(lager_event)),
                        gen_event:add_handler(lager_event, lager_console_backend,
                          [{level, info}, {formatter, lager_default_formatter}, {formatter_config, [date,"#",time,"#",severity,"#",node,"#",pid,"#",
                                                            module,"#",function,"#",file,"#",line,"#",message,"\r\n"]}]),
                        lager_config:set({lager_event, loglevel}, {?INFO, []}),
                        lager:info("Test message"),
                        PidStr = pid_to_list(self()),
                        NodeStr = atom_to_list(node()),
                        ModuleStr = atom_to_list(?MODULE),
                        receive
                            {io_request, _, _, {put_chars, unicode, Msg}} ->
                                TestMsg = "Test message" ++ eol(),
                                ?assertMatch([_, _, "info", NodeStr, PidStr, ModuleStr, _, _, _, TestMsg],
                                             re:split(Msg, "#", [{return, list}, {parts, 10}]))
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
                        gen_event:add_handler(lager_event, lager_console_backend, [{level, info}]),
                        erlang:group_leader(Pid, whereis(lager_event)),
                        lager_config:set({lager_event, loglevel}, {element(2, lager_util:config_to_mask(info)), []}),
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
                                TestMsg = "Test message" ++ eol(),
                                ?assertMatch([_, "[debug]", TestMsg], re:split(Msg1, " ", [{return, list}, {parts, 3}]))
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
                        gen_event:add_handler(lager_event, lager_console_backend, [{level, info}]),
                        lager_config:set({lager_event, loglevel}, {element(2, lager_util:config_to_mask(info)), []}),
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
                                TestMsg = "Test message" ++ eol(),
                                ?assertMatch([_, "[error]", TestMsg], re:split(Msg1, " ", [{return, list}, {parts, 3}]))
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
            },
            {"blacklisting a loglevel works",
                fun() ->
                        Pid = spawn(F(self())),
                        unregister(user),
                        register(user, Pid),
                        gen_event:add_handler(lager_event, lager_console_backend, [{level, info}]),
                        lager_config:set({lager_event, loglevel}, {element(2, lager_util:config_to_mask(info)), []}),
                        lager:set_loglevel(lager_console_backend, '!=info'),
                        erlang:group_leader(Pid, whereis(lager_event)),
                        lager:debug("Test message"),
                        receive
                            {io_request, From1, ReplyAs1, {put_chars, unicode, Msg1}} ->
                                From1 ! {io_reply, ReplyAs1, ok},
                                TestMsg = "Test message" ++ eol(),
                                ?assertMatch([_, "[debug]", TestMsg], re:split(Msg1, " ", [{return, list}, {parts, 3}]))
                        after
                            1000 ->
                                ?assert(false)
                        end,
                        %% info is blacklisted
                        lager:info("Test message"),
                        receive
                            {io_request, From2, ReplyAs2, {put_chars, unicode, _Msg2}} ->
                                From2 ! {io_reply, ReplyAs2, ok},
                                ?assert(false)
                        after
                            500 ->
                                ?assert(true)
                        end
                end
            },
            {"whitelisting a loglevel works",
                fun() ->
                        Pid = spawn(F(self())),
                        unregister(user),
                        register(user, Pid),
                        gen_event:add_handler(lager_event, lager_console_backend, [{level, info}]),
                        lager_config:set({lager_event, loglevel}, {element(2, lager_util:config_to_mask(info)), []}),
                        lager:set_loglevel(lager_console_backend, '=debug'),
                        erlang:group_leader(Pid, whereis(lager_event)),
                        lager:debug("Test message"),
                        receive
                            {io_request, From1, ReplyAs1, {put_chars, unicode, Msg1}} ->
                                From1 ! {io_reply, ReplyAs1, ok},
                                TestMsg = "Test message" ++ eol(),
                                ?assertMatch([_, "[debug]", TestMsg], re:split(Msg1, " ", [{return, list}, {parts, 3}]))
                        after
                            1000 ->
                                ?assert(false)
                        end,
                        %% info is blacklisted
                        lager:error("Test message"),
                        receive
                            {io_request, From2, ReplyAs2, {put_chars, unicode, _Msg2}} ->
                                From2 ! {io_reply, ReplyAs2, ok},
                                ?assert(false)
                        after
                            500 ->
                                ?assert(true)
                        end
                end
            },
            {"console backend with custom group leader",
                fun() ->
                        Pid = spawn(F(self())),
                        gen_event:add_handler(lager_event, lager_console_backend, [{level, info}, {group_leader, Pid}]),
                        lager_config:set({lager_event, loglevel}, {element(2, lager_util:config_to_mask(info)), []}),
                        lager:info("Test message"),
                        ?assertNotEqual({group_leader, Pid}, erlang:process_info(whereis(lager_event), group_leader)),
                        receive
                            {io_request, From1, ReplyAs1, {put_chars, unicode, Msg1}} ->
                                From1 ! {io_reply, ReplyAs1, ok},
                                TestMsg = "Test message" ++ eol(),
                                ?assertMatch([_, "[info]", TestMsg], re:split(Msg1, " ", [{return, list}, {parts, 3}]))
                        after
                            1000 ->
                                ?assert(false)
                        end,
                        %% killing the pid should prevent any new log messages (to prove we haven't accidentally redirected
                        %% the group leader some other way
                        exit(Pid, kill),
                        timer:sleep(100),
                        %% additionally, check the lager backend has been removed (because the group leader process died)
                        ?assertNot(lists:member(lager_console_backend, gen_event:which_handlers(lager_event))),
                        lager:error("Test message"),
                        receive
                            {io_request, From2, ReplyAs2, {put_chars, unicode, _Msg2}} ->
                                From2 ! {io_reply, ReplyAs2, ok},
                                ?assert(false)
                        after
                            500 ->
                                ?assert(true)
                        end
                end
            },
            {"console backend with custom group leader using a trace and an ID",
                fun() ->
                        Pid = spawn(F(self())),
                        ID = {?MODULE, trace_test},
                        Handlers = lager_config:global_get(handlers, []),
                        HandlerInfo = lager_app:start_handler(lager_event, ID,
                                                              [{level, none}, {group_leader, Pid},
                                                               {id, ID}]),
                        lager_config:global_set(handlers, [HandlerInfo|Handlers]),
                        lager:info("Test message"),
                        ?assertNotEqual({group_leader, Pid}, erlang:process_info(whereis(lager_event), group_leader)),
                        receive
                            {io_request, From, ReplyAs, {put_chars, unicode, _Msg}} ->
                                From ! {io_reply, ReplyAs, ok},
                                ?assert(false)
                        after
                            500 ->
                                ?assert(true)
                        end,
                        lager:trace(ID, [{module, ?MODULE}], debug),
                        lager:info("Test message"),
                        receive
                            {io_request, From1, ReplyAs1, {put_chars, unicode, Msg1}} ->
                                From1 ! {io_reply, ReplyAs1, ok},
                                TestMsg = "Test message" ++ eol(),
                                ?assertMatch([_, "[info]", TestMsg], re:split(Msg1, " ", [{return, list}, {parts, 3}]))
                        after
                            500 ->
                                ?assert(false)
                        end,
                        ?assertNotEqual({0, []}, lager_config:get({lager_event, loglevel})),
                        %% killing the pid should prevent any new log messages (to prove we haven't accidentally redirected
                        %% the group leader some other way
                        exit(Pid, kill),
                        timer:sleep(100),
                        %% additionally, check the lager backend has been removed (because the group leader process died)
                        ?assertNot(lists:member(lager_console_backend, gen_event:which_handlers(lager_event))),
                        %% finally, check the trace has been removed
                        ?assertEqual({0, []}, lager_config:get({lager_event, loglevel})),
                        lager:error("Test message"),
                        receive
                            {io_request, From3, ReplyAs3, {put_chars, unicode, _Msg3}} ->
                                From3 ! {io_reply, ReplyAs3, ok},
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
                application:set_env(lager, handlers, [{lager_console_backend, [{level, info}]}]),
                application:set_env(lager, error_logger_redirect, false),
                lager:start()
        end,
        fun(_) ->
                application:stop(lager),
                application:stop(goldrush),
                error_logger:tty(true)
        end,
        [
            {"Get/set loglevel test",
                fun() ->
                        ?assertEqual(info, lager:get_loglevel(lager_console_backend)),
                        lager:set_loglevel(lager_console_backend, debug),
                        ?assertEqual(debug, lager:get_loglevel(lager_console_backend)),
                        lager:set_loglevel(lager_console_backend, '!=debug'),
                        ?assertEqual(info, lager:get_loglevel(lager_console_backend)),
                        lager:set_loglevel(lager_console_backend, '!=info'),
                        ?assertEqual(debug, lager:get_loglevel(lager_console_backend)),
                        ok
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
