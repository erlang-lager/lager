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

-module(lager_test_backend).

-include("lager.hrl").

-behaviour(gen_event).

-export([init/1, handle_call/2, handle_event/2, handle_info/2, terminate/2,
        code_change/3]).

-record(state, {level, buffer, ignored}).
-compile([{parse_transform, lager_transform}]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-export([pop/0, count/0, count_ignored/0, flush/0]).
-endif.

init(Level) ->
    {ok, #state{level=lager_util:level_to_num(Level), buffer=[], ignored=[]}}.

handle_call(count, #state{buffer=Buffer} = State) ->
    {ok, length(Buffer), State};
handle_call(count_ignored, #state{ignored=Ignored} = State) ->
    {ok, length(Ignored), State};
handle_call(flush, State) ->
    {ok, ok, State#state{buffer=[], ignored=[]}};
handle_call(pop, #state{buffer=Buffer} = State) ->
    case Buffer of
        [] ->
            {ok, undefined, State};
        [H|T] ->
            {ok, H, State#state{buffer=T}}
    end;
handle_call(get_loglevel, #state{level=Level} = State) ->
    {ok, Level, State};
handle_call({set_loglevel, Level}, State) ->
    {ok, ok, State#state{level=lager_util:level_to_num(Level)}};
handle_call(_Request, State) ->
    {ok, ok, State}.

handle_event({log, [?MODULE], Level, Time, Message}, #state{buffer=Buffer} = State) ->
    {ok, State#state{buffer=Buffer ++ [{Level, Time, Message}]}};
handle_event({log, Level, Time, Message}, #state{level=LogLevel,
        buffer=Buffer} = State) when Level =< LogLevel ->
    {ok, State#state{buffer=Buffer ++ [{Level, Time, Message}]}};
handle_event({log, _Level, _Time, _Message}, #state{ignored=Ignored} = State) ->
    {ok, State#state{ignored=Ignored ++ [ignored]}};
handle_event(_Event, State) ->
    {ok, State}.

handle_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

-ifdef(TEST).

pop() ->
    gen_event:call(lager_event, ?MODULE, pop).

count() ->
    gen_event:call(lager_event, ?MODULE, count).

count_ignored() ->
    gen_event:call(lager_event, ?MODULE, count_ignored).

flush() ->
    gen_event:call(lager_event, ?MODULE, flush).

has_line_numbers() ->
	%% are we R15 or greater
	Rel = erlang:system_info(otp_release),
	{match, [Major]} = re:run(Rel, "^R(\\d+)[A|B](|0(\\d))$", [{capture, [1], list}]),
	list_to_integer(Major) >= 15.

not_running_test() ->
    ?assertEqual({error, lager_not_running}, lager:log(info, self(), "not running")).

lager_test_() ->
    {foreach,
        fun setup/0,
        fun cleanup/1,
        [
            {"observe that there is nothing up my sleeve",
                fun() ->
                        ?assertEqual(undefined, pop()),
                        ?assertEqual(0, count())
                end
            },
            {"logging works",
                fun() ->
                        lager:warning("test message"),
                        ?assertEqual(1, count()),
                        {Level, _Time, Message}  = pop(),
                        ?assertMatch(Level, lager_util:level_to_num(warning)),
                        [LevelStr, _LocStr, MsgStr] = re:split(Message, " ", [{return, list}, {parts, 3}]),
                        ?assertEqual("[warning]", LevelStr),
                        ?assertEqual("test message", MsgStr),
                        ok
                end
            },
            {"logging with arguments works",
                fun() ->
                        lager:warning("test message ~p", [self()]),
                        ?assertEqual(1, count()),
                        {Level, _Time, Message}  = pop(),
                        ?assertMatch(Level, lager_util:level_to_num(warning)),
                        [LevelStr, _LocStr, MsgStr] = re:split(Message, " ", [{return, list}, {parts, 3}]),
                        ?assertEqual("[warning]", LevelStr),
                        ?assertEqual(lists:flatten(io_lib:format("test message ~p", [self()])), MsgStr),
                        ok
                end
            },
            {"logging works from inside a begin/end block",
                fun() ->
                        ?assertEqual(0, count()),
                        begin
                                lager:warning("test message 2")
                        end,
                        ?assertEqual(1, count()),
                        ok
                end
            },
            {"logging works from inside a list comprehension",
                fun() ->
                        ?assertEqual(0, count()),
                        [lager:warning("test message") || _N <- lists:seq(1, 10)],
                        ?assertEqual(10, count()),
                        ok
                end
            },
            {"logging works from a begin/end block inside a list comprehension",
                fun() ->
                        ?assertEqual(0, count()),
                        [ begin lager:warning("test message") end || _N <- lists:seq(1, 10)],
                        ?assertEqual(10, count()),
                        ok
                end
            },
            {"logging works from a nested list comprehension",
                fun() ->
                        ?assertEqual(0, count()),
                        [ [lager:warning("test message") || _N <- lists:seq(1, 10)] ||
                            _I <- lists:seq(1, 10)],
                        ?assertEqual(100, count()),
                        ok
                end
            },
            {"log messages below the threshold are ignored",
                fun() ->
                        ?assertEqual(0, count()),
                        lager:debug("this message will be ignored"),
                        ?assertEqual(0, count()),
                        ?assertEqual(0, count_ignored()),
                        lager_mochiglobal:put(loglevel, {?DEBUG, []}),
                        lager:debug("this message should be ignored"),
                        ?assertEqual(0, count()),
                        ?assertEqual(1, count_ignored()),
                        lager:set_loglevel(?MODULE, debug),
                        lager:debug("this message should be logged"),
                        ?assertEqual(1, count()),
                        ?assertEqual(1, count_ignored()),
                        ?assertEqual(debug, lager:get_loglevel(?MODULE)),
                        ok
                end
            },
            {"tracing works",
                fun() ->
                        lager_mochiglobal:put(loglevel, {?ERROR, []}),
                        ok = lager:info("hello world"),
                        ?assertEqual(0, count()),
                        lager_mochiglobal:put(loglevel, {?ERROR, [{[{module,
                                                ?MODULE}], ?DEBUG, ?MODULE}]}),
                        ok = lager:info("hello world"),
                        ?assertEqual(1, count()),
                        ok
                end
            },
            {"tracing works with custom attributes",
                fun() ->
                        lager_mochiglobal:put(loglevel, {?ERROR, []}),
                        lager:info([{requestid, 6}], "hello world"),
                        ?assertEqual(0, count()),
                        lager_mochiglobal:put(loglevel, {?ERROR,
                                [{[{requestid, 6}], ?DEBUG, ?MODULE}]}),
                        lager:info([{requestid, 6}, {foo, bar}], "hello world"),
                        ?assertEqual(1, count()),
                        lager_mochiglobal:put(loglevel, {?ERROR,
                                [{[{requestid, '*'}], ?DEBUG, ?MODULE}]}),
                        lager:info([{requestid, 6}], "hello world"),
                        ?assertEqual(2, count()),
                        ok
                end
            },
            {"tracing honors loglevel",
                fun() ->
                        lager_mochiglobal:put(loglevel, {?ERROR, [{[{module,
                                                ?MODULE}], ?NOTICE, ?MODULE}]}),
                        ok = lager:info("hello world"),
                        ?assertEqual(0, count()),
                        ok = lager:notice("hello world"),
                        ?assertEqual(1, count()),
                        ok
                end
            }
        ]
    }.

setup() ->
    error_logger:tty(false),
    application:load(lager),
    application:set_env(lager, handlers, [{?MODULE, info}]),
    application:set_env(lager, error_logger_redirect, false),
    application:start(compiler),
    application:start(syntax_tools),
    application:start(lager),
    gen_event:call(lager_event, ?MODULE, flush).

cleanup(_) ->
    application:stop(lager),
    error_logger:tty(true).


crash(Type) ->
    spawn(fun() -> gen_server:call(crash, Type) end),
    timer:sleep(100),
    _ = gen_event:which_handlers(error_logger),
    ok.

test_body(Expected, Actual) ->
    case has_line_numbers() of
        true ->
            FileLine = string:substr(Actual, length(Expected)+1),
            Body = string:substr(Actual, 1, length(Expected)),
            ?assertEqual(Expected, Body),
            ?assertEqual(" line ", string:substr(FileLine, 1, 6));
        false ->
            ?assertEqual(Expected, Actual)
    end.


error_logger_redirect_crash_test_() ->
    {foreach,
        fun() ->
                error_logger:tty(false),
                application:load(lager),
                application:set_env(lager, error_logger_redirect, true),
                application:set_env(lager, handlers, [{?MODULE, error}]),
                application:start(compiler),
                application:start(syntax_tools),
                application:start(lager),
                crash:start()
        end,

        fun(_) ->
                application:stop(lager),
                case whereis(crash) of
                    undefined -> ok;
                    Pid -> exit(Pid, kill)
                end,
                error_logger:tty(true)
        end,
        [
            {"again, there is nothing up my sleeve",
                fun() ->
                        ?assertEqual(undefined, pop()),
                        ?assertEqual(0, count())
                end
            },
            {"bad return value",
                fun() ->
                        Pid = whereis(crash),
                        crash(bad_return),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~w gen_server crash terminated with reason: bad return value: bleh", [Pid])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"bad return value with string",
                fun() ->
                        Pid = whereis(crash),
                        crash(bad_return_string),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~w gen_server crash terminated with reason: bad return value: {tuple,{tuple,\"string\"}}", [Pid])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
           {"bad return value uncaught throw",
                fun() ->
                        Pid = whereis(crash),
                        crash(throw),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~w gen_server crash terminated with reason: bad return value: a_ball", [Pid])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"case clause",
                fun() ->
                        Pid = whereis(crash),
                        crash(case_clause),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~w gen_server crash terminated with reason: no case clause matching {} in crash:handle_call/3", [Pid])),
                        test_body(Expected, lists:flatten(Msg))
                end
            },
            {"case clause string",
                fun() ->
                        Pid = whereis(crash),
                        crash(case_clause_string),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~w gen_server crash terminated with reason: no case clause matching \"crash\" in crash:handle_call/3", [Pid])),
                        test_body(Expected, lists:flatten(Msg))
                end
            },
            {"function clause",
                fun() ->
                        Pid = whereis(crash),
                        crash(function_clause),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~w gen_server crash terminated with reason: no function clause matching crash:function({})", [Pid])),
                        test_body(Expected, lists:flatten(Msg))
                end
            },
            {"if clause",
                fun() ->
                        Pid = whereis(crash),
                        crash(if_clause),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~w gen_server crash terminated with reason: no true branch found while evaluating if expression in crash:handle_call/3", [Pid])),
                        test_body(Expected, lists:flatten(Msg))
                end
            },
            {"try clause",
                fun() ->
                        Pid = whereis(crash),
                        crash(try_clause),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~w gen_server crash terminated with reason: no try clause matching [] in crash:handle_call/3", [Pid])),
                        test_body(Expected, lists:flatten(Msg))
                end
            },
            {"undefined function",
                fun() ->
                        Pid = whereis(crash),
                        crash(undef),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~w gen_server crash terminated with reason: call to undefined function crash:booger/0 from crash:handle_call/3", [Pid])),
                        test_body(Expected, lists:flatten(Msg))
                end
            },
            {"bad math",
                fun() ->
                        Pid = whereis(crash),
                        crash(badarith),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~w gen_server crash terminated with reason: bad arithmetic expression in crash:handle_call/3", [Pid])),
                        test_body(Expected, lists:flatten(Msg))
                end
            },
            {"bad match",
                fun() ->
                        Pid = whereis(crash),
                        crash(badmatch),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~w gen_server crash terminated with reason: no match of right hand value {} in crash:handle_call/3", [Pid])),
                        test_body(Expected, lists:flatten(Msg))
                end
            },
            {"bad arity",
                fun() ->
                        Pid = whereis(crash),
                        crash(badarity),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~w gen_server crash terminated with reason: fun called with wrong arity of 1 instead of 3 in crash:handle_call/3", [Pid])),
                        test_body(Expected, lists:flatten(Msg))
                end
            },
            {"bad arg1",
                fun() ->
                        Pid = whereis(crash),
                        crash(badarg1),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~w gen_server crash terminated with reason: bad argument in crash:handle_call/3", [Pid])),
                        test_body(Expected, lists:flatten(Msg))
                end
            },
            {"bad arg2",
                fun() ->
                        Pid = whereis(crash),
                        crash(badarg2),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~w gen_server crash terminated with reason: bad argument in call to erlang:iolist_to_binary([\"foo\",bar]) in crash:handle_call/3", [Pid])),
                        test_body(Expected, lists:flatten(Msg))
                end
            },
            {"bad record",
                fun() ->
                        Pid = whereis(crash),
                        crash(badrecord),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~w gen_server crash terminated with reason: bad record state in crash:handle_call/3", [Pid])),
                        test_body(Expected, lists:flatten(Msg))
                end
            },
            {"noproc",
                fun() ->
                        Pid = whereis(crash),
                        crash(noproc),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~w gen_server crash terminated with reason: no such process or port in call to gen_event:call(foo, bar, baz)", [Pid])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"badfun",
                fun() ->
                        Pid = whereis(crash),
                        crash(badfun),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~w gen_server crash terminated with reason: bad function booger in crash:handle_call/3", [Pid])),
                        test_body(Expected, lists:flatten(Msg))
                end
            }

        ]
    }.

error_logger_redirect_test_() ->
    {foreach,
        fun() ->
                error_logger:tty(false),
                application:load(lager),
                application:set_env(lager, error_logger_redirect, true),
                application:set_env(lager, handlers, [{?MODULE, info}]),
                application:start(lager),
                lager:log(error, self(), "flush flush"),
                timer:sleep(100),
                gen_event:call(lager_event, ?MODULE, flush)
        end,

        fun(_) ->
                application:stop(lager),
                error_logger:tty(true)
        end,
        [
            {"error reports are printed",
                fun() ->
                        sync_error_logger:error_report([{this, is}, a, {silly, format}]),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~w this: is, a, silly: format", [self()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"string error reports are printed",
                fun() ->
                        sync_error_logger:error_report("this is less silly"),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~w this is less silly", [self()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"error messages are printed",
                fun() ->
                        sync_error_logger:error_msg("doom, doom has come upon you all"),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~w doom, doom has come upon you all", [self()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"error messages are truncated at 4096 characters",
                fun() ->
                        sync_error_logger:error_msg("doom, doom has come upon you all ~p", [string:copies("doom", 10000)]),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        ?assert(length(lists:flatten(Msg)) < 5100)
                end
            },
            {"info reports are printed",
                fun() ->
                        sync_error_logger:info_report([{this, is}, a, {silly, format}]),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[info] ~w this: is, a, silly: format", [self()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"info reports are truncated at 4096 characters",
                fun() ->
                        sync_error_logger:info_report([[{this, is}, a, {silly, format}] || _ <- lists:seq(0, 600)]),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        ?assert(length(lists:flatten(Msg)) < 5000)
                end
            },
            {"single term info reports are printed",
                fun() ->
                        sync_error_logger:info_report({foolish, bees}),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[info] ~w {foolish,bees}", [self()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"single term error reports are printed",
                fun() ->
                        sync_error_logger:error_report({foolish, bees}),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~w {foolish,bees}", [self()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"string info reports are printed",
                fun() ->
                        sync_error_logger:info_report("this is less silly"),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[info] ~w this is less silly", [self()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"string info reports are truncated at 4096 characters",
                fun() ->
                        sync_error_logger:info_report(string:copies("this is less silly", 1000)),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        ?assert(length(lists:flatten(Msg)) < 5100)
                end
            },
            {"strings in a mixed report are printed as strings",
                fun() ->
                        sync_error_logger:info_report(["this is less silly", {than, "this"}]),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[info] ~w \"this is less silly\", than: \"this\"", [self()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"info messages are printed",
                fun() ->
                        sync_error_logger:info_msg("doom, doom has come upon you all"),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[info] ~w doom, doom has come upon you all", [self()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"info messages are truncated at 4096 characters",
                fun() ->
                        sync_error_logger:info_msg("doom, doom has come upon you all ~p", [string:copies("doom", 10000)]),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        ?assert(length(lists:flatten(Msg)) < 5100)
                end
            },

            {"warning messages are printed at the correct level",
                fun() ->
                        sync_error_logger:warning_msg("doom, doom has come upon you all"),
                        Map = error_logger:warning_map(),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[~w] ~w doom, doom has come upon you all", [Map, self()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"warning reports are printed at the correct level",
                fun() ->
                        sync_error_logger:warning_report([{i, like}, pie]),
                        Map = error_logger:warning_map(),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[~w] ~w i: like, pie", [Map, self()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"single term warning reports are printed at the correct level",
                fun() ->
                        sync_error_logger:warning_report({foolish, bees}),
                        Map = error_logger:warning_map(),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[~w] ~w {foolish,bees}", [Map, self()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"application stop reports",
                fun() ->
                        sync_error_logger:info_report([{application, foo}, {exited, quittin_time}, {type, lazy}]),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[info] ~w Application foo exited with reason: quittin_time", [self()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"supervisor reports",
                fun() ->
                        sync_error_logger:error_report(supervisor_report, [{errorContext, france}, {offender, [{name, mini_steve}, {mfargs, {a, b, [c]}}, {pid, bleh}]}, {reason, fired}, {supervisor, {local, steve}}]),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~w Supervisor steve had child mini_steve started with a:b(c) at bleh exit with reason fired in context france", [self()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"supervisor reports with real error",
                fun() ->
                        sync_error_logger:error_report(supervisor_report, [{errorContext, france}, {offender, [{name, mini_steve}, {mfargs, {a, b, [c]}}, {pid, bleh}]}, {reason, {function_clause,[{crash,handle_info,[foo]}]}}, {supervisor, {local, steve}}]),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~w Supervisor steve had child mini_steve started with a:b(c) at bleh exit with reason no function clause matching crash:handle_info(foo) in context france", [self()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },

            {"supervisor_bridge reports",
                fun() ->
                        sync_error_logger:error_report(supervisor_report, [{errorContext, france}, {offender, [{mod, mini_steve}, {pid, bleh}]}, {reason, fired}, {supervisor, {local, steve}}]),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~w Supervisor steve had child at module mini_steve at bleh exit with reason fired in context france", [self()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"application progress report",
                fun() ->
                        sync_error_logger:info_report(progress, [{application, foo}, {started_at, node()}]),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[info] ~w Application foo started on node ~w", [self(), node()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"supervisor progress report",
                fun() ->
                        lager:set_loglevel(?MODULE, debug),
                        sync_error_logger:info_report(progress, [{supervisor, {local, foo}}, {started, [{mfargs, {foo, bar, 1}}, {pid, baz}]}]),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[debug] ~w Supervisor foo started foo:bar/1 at pid baz", [self()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"crash report for emfile",
                fun() ->
                        sync_error_logger:error_report(crash_report, [[{pid, self()}, {registered_name, []}, {error_info, {error, emfile, [{stack, trace, 1}]}}], []]),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~w CRASH REPORT Process ~w with 0 neighbours crashed with reason: maximum number of file descriptors exhausted, check ulimit -n", [self(), self()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"crash report for system process limit",
                fun() ->
                        sync_error_logger:error_report(crash_report, [[{pid, self()}, {registered_name, []}, {error_info, {error, system_limit, [{erlang, spawn, 1}]}}], []]),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~w CRASH REPORT Process ~w with 0 neighbours crashed with reason: system limit: maximum number of processes exceeded", [self(), self()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"crash report for system process limit2",
                fun() ->
                        sync_error_logger:error_report(crash_report, [[{pid, self()}, {registered_name, []}, {error_info, {error, system_limit, [{erlang, spawn_opt, 1}]}}], []]),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~w CRASH REPORT Process ~w with 0 neighbours crashed with reason: system limit: maximum number of processes exceeded", [self(), self()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"crash report for system port limit",
                fun() ->
                        sync_error_logger:error_report(crash_report, [[{pid, self()}, {registered_name, []}, {error_info, {error, system_limit, [{erlang, open_port, 1}]}}], []]),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~w CRASH REPORT Process ~w with 0 neighbours crashed with reason: system limit: maximum number of ports exceeded", [self(), self()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"crash report for system port limit",
                fun() ->
                        sync_error_logger:error_report(crash_report, [[{pid, self()}, {registered_name, []}, {error_info, {error, system_limit, [{erlang, list_to_atom, 1}]}}], []]),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~w CRASH REPORT Process ~w with 0 neighbours crashed with reason: system limit: tried to create an atom larger than 255, or maximum atom count exceeded", [self(), self()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"crash report for system ets table limit",
                fun() ->
                        sync_error_logger:error_report(crash_report, [[{pid, self()}, {registered_name, test}, {error_info, {error, system_limit, [{ets,new,[segment_offsets,[ordered_set,public]]},{mi_segment,open_write,1},{mi_buffer_converter,handle_cast,2},{gen_server,handle_msg,5},{proc_lib,init_p_do_apply,3}]}}], []]),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~w CRASH REPORT Process ~w with 0 neighbours crashed with reason: system limit: maximum number of ETS tables exceeded", [self(), test])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"crash report for unknown system limit should be truncated at 500 characters",
                fun() ->
                        sync_error_logger:error_report(crash_report, [[{pid, self()}, {error_info, {error, system_limit, [{wtf,boom,[string:copies("aaaa", 4096)]}]}}], []]),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        ?assert(length(lists:flatten(Msg)) > 600),
                        ?assert(length(lists:flatten(Msg)) < 650)
                end
            },
            {"crash reports for 'special processes' should be handled right - function_clause", 
                fun() ->
                        {ok, Pid} = special_process:start(),
                        unlink(Pid),
                        Pid ! function_clause,
                        timer:sleep(500),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~p CRASH REPORT Process ~p with 0 neighbours crashed with reason: no function clause matching special_process:foo(bar)",
                                [Pid, Pid])),
                        test_body(Expected, lists:flatten(Msg))
                end
            },
            {"crash reports for 'special processes' should be handled right - case_clause", 
                fun() ->
                        {ok, Pid} = special_process:start(),
                        unlink(Pid),
                        Pid ! {case_clause, wtf},
                        timer:sleep(500),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~p CRASH REPORT Process ~p with 0 neighbours crashed with reason: no case clause matching wtf in special_process:loop/0",
                                [Pid, Pid])),
                        test_body(Expected, lists:flatten(Msg))
                end
            },
            {"crash reports for 'special processes' should be handled right - exit", 
                fun() ->
                        {ok, Pid} = special_process:start(),
                        unlink(Pid),
                        Pid ! exit,
                        timer:sleep(500),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~p CRASH REPORT Process ~p with 0 neighbours exited with reason: byebye in special_process:loop/0",
                                [Pid, Pid])),
                        test_body(Expected, lists:flatten(Msg))
                end
            },
            {"crash reports for 'special processes' should be handled right - error", 
                fun() ->
                        {ok, Pid} = special_process:start(),
                        unlink(Pid),
                        Pid ! error,
                        timer:sleep(500),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg} = pop(),
                        Expected = lists:flatten(io_lib:format("[error] ~p CRASH REPORT Process ~p with 0 neighbours crashed with reason: mybad in special_process:loop/0",
                                [Pid, Pid])),
                        test_body(Expected, lists:flatten(Msg))
                end
            },
            {"messages should not be generated if they don't satisfy the threshold",
                fun() ->
                        lager:set_loglevel(?MODULE, error),
                        sync_error_logger:info_report([hello, world]),
                        _ = gen_event:which_handlers(error_logger),
                        ?assertEqual(0, count()),
                        ?assertEqual(0, count_ignored()),
                        lager:set_loglevel(?MODULE, info),
                        sync_error_logger:info_report([hello, world]),
                        _ = gen_event:which_handlers(error_logger),
                        ?assertEqual(1, count()),
                        ?assertEqual(0, count_ignored()),
                        lager:set_loglevel(?MODULE, error),
                        lager_mochiglobal:put(loglevel, {?DEBUG, []}),
                        sync_error_logger:info_report([hello, world]),
                        _ = gen_event:which_handlers(error_logger),
                        ?assertEqual(1, count()),
                        ?assertEqual(1, count_ignored())
                end
            }
        ]
    }.

safe_format_test() ->
    ?assertEqual("foo bar", lists:flatten(lager:safe_format("~p ~p", [foo, bar], 1024))),
    ?assertEqual("FORMAT ERROR: \"~p ~p ~p\" [foo,bar]", lists:flatten(lager:safe_format("~p ~p ~p", [foo, bar], 1024))),
    ok.

-endif.


