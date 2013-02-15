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

-module(lager_test_backend).

-include("lager.hrl").

-behaviour(gen_event).

-export([init/1, handle_call/2, handle_event/2, handle_info/2, terminate/2,
        code_change/3]).

-record(state, {level, buffer, ignored}).
-record(test, {attrs, format, args}).
-compile([{parse_transform, lager_transform}]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-export([pop/0, count/0, count_ignored/0, flush/0, print_state/0]).
-endif.

init(Level) ->
    {ok, #state{level=lager_util:config_to_mask(Level), buffer=[], ignored=[]}}.

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
    {ok, ok, State#state{level=lager_util:config_to_mask(Level)}};
handle_call(print_state, State) ->
    spawn(fun() -> lager:info("State ~p", [lager:pr(State, ?MODULE)]) end),
    timer:sleep(100),
    {ok, ok, State};
handle_call(print_bad_state, State) ->
    spawn(fun() -> lager:info("State ~p", [lager:pr({state, 1}, ?MODULE)]) end),
    timer:sleep(100),
    {ok, ok, State};
handle_call(_Request, State) ->
    {ok, ok, State}.

handle_event({log, Msg},
             #state{level=LogLevel,buffer=Buffer,ignored=Ignored} = State) ->
    case lager_util:is_loggable(Msg, LogLevel, ?MODULE) of
        true ->
            {ok, State#state{buffer=Buffer ++
                             [{lager_msg:severity_as_int(Msg),
                               lager_msg:timestamp(Msg),
                               lager_msg:message(Msg), lager_msg:metadata(Msg)}]}};
        _ ->
            {ok, State#state{ignored=Ignored ++ [ignored]}}
    end;
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

print_state() ->
    gen_event:call(lager_event, ?MODULE, print_state).

print_bad_state() ->
    gen_event:call(lager_event, ?MODULE, print_bad_state).

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
                        {Level, _Time, Message, _Metadata}  = pop(),
                        ?assertMatch(Level, lager_util:level_to_num(warning)),
                        ?assertEqual("test message", Message),
                        ok
                end
            },
            {"logging with arguments works",
                fun() ->
                        lager:warning("test message ~p", [self()]),
                        ?assertEqual(1, count()),
                        {Level, _Time, Message,_Metadata}  = pop(),
                        ?assertMatch(Level, lager_util:level_to_num(warning)),
                        ?assertEqual(lists:flatten(io_lib:format("test message ~p", [self()])), lists:flatten(Message)),
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
            {"variables inplace of literals in logging statements work",
                fun() ->
                        ?assertEqual(0, count()),
                        Attr = [{a, alpha}, {b, beta}],
                        Fmt = "format ~p",
                        Args = [world],
                        lager:info(Attr, "hello"),
                        lager:info(Attr, "hello ~p", [world]),
                        lager:info(Fmt, [world]),
                        lager:info("hello ~p", Args),
                        lager:info(Attr, "hello ~p", Args),
                        lager:info([{d, delta}, {g, gamma}], Fmt, Args),
                        ?assertEqual(6, count()),
                        {_Level, _Time, Message, Metadata}  = pop(),
                        ?assertMatch([{a, alpha}, {b, beta}|_], Metadata),
                        ?assertEqual("hello", lists:flatten(Message)),
                        {_Level, _Time2, Message2, _Metadata2}  = pop(),
                        ?assertEqual("hello world", lists:flatten(Message2)),
                        {_Level, _Time3, Message3, _Metadata3}  = pop(),
                        ?assertEqual("format world", lists:flatten(Message3)),
                        {_Level, _Time4, Message4, _Metadata4}  = pop(),
                        ?assertEqual("hello world", lists:flatten(Message4)),
                        {_Level, _Time5, Message5, _Metadata5}  = pop(),
                        ?assertEqual("hello world", lists:flatten(Message5)),
                        {_Level, _Time6, Message6, Metadata6}  = pop(),
                        ?assertMatch([{d, delta}, {g, gamma}|_], Metadata6),
                        ?assertEqual("format world", lists:flatten(Message6)),
                        ok
                end
            },
            {"list comprehension inplace of literals in logging statements work",
                fun() ->
                        ?assertEqual(0, count()),
                        Attr = [{a, alpha}, {b, beta}],
                        Fmt = "format ~p",
                        Args = [world],
                        lager:info([{K, atom_to_list(V)} || {K, V} <- Attr], "hello"),
                        lager:info([{K, atom_to_list(V)} || {K, V} <- Attr], "hello ~p", [{atom, X} || X <- Args]),
                        lager:info([X || X <- Fmt], [world]),
                        lager:info("hello ~p", [{atom, X} || X <- Args]),
                        lager:info([{K, atom_to_list(V)} || {K, V} <- Attr], "hello ~p", [{atom, X} || X <- Args]),
                        lager:info([{d, delta}, {g, gamma}], Fmt, [{atom, X} || X <- Args]),
                        ?assertEqual(6, count()),
                        {_Level, _Time, Message, Metadata}  = pop(),
                        ?assertMatch([{a, "alpha"}, {b, "beta"}|_], Metadata),
                        ?assertEqual("hello", lists:flatten(Message)),
                        {_Level, _Time2, Message2, _Metadata2}  = pop(),
                        ?assertEqual("hello {atom,world}", lists:flatten(Message2)),
                        {_Level, _Time3, Message3, _Metadata3}  = pop(),
                        ?assertEqual("format world", lists:flatten(Message3)),
                        {_Level, _Time4, Message4, _Metadata4}  = pop(),
                        ?assertEqual("hello {atom,world}", lists:flatten(Message4)),
                        {_Level, _Time5, Message5, _Metadata5}  = pop(),
                        ?assertEqual("hello {atom,world}", lists:flatten(Message5)),
                        {_Level, _Time6, Message6, Metadata6}  = pop(),
                        ?assertMatch([{d, delta}, {g, gamma}|_], Metadata6),
                        ?assertEqual("format {atom,world}", lists:flatten(Message6)),
                        ok
                end
            },
            {"function calls inplace of literals in logging statements work",
                fun() ->
                        ?assertEqual(0, count()),
                        put(attrs, [{a, alpha}, {b, beta}]),
                        put(format, "format ~p"),
                        put(args, [world]),
                        lager:info(get(attrs), "hello"),
                        lager:info(get(attrs), "hello ~p", get(args)),
                        lager:info(get(format), [world]),
                        lager:info("hello ~p", erlang:get(args)),
                        lager:info(fun() -> get(attrs) end(), "hello ~p", get(args)),
                        lager:info([{d, delta}, {g, gamma}], get(format), get(args)),
                        ?assertEqual(6, count()),
                        {_Level, _Time, Message, Metadata}  = pop(),
                        ?assertMatch([{a, alpha}, {b, beta}|_], Metadata),
                        ?assertEqual("hello", lists:flatten(Message)),
                        {_Level, _Time2, Message2, _Metadata2}  = pop(),
                        ?assertEqual("hello world", lists:flatten(Message2)),
                        {_Level, _Time3, Message3, _Metadata3}  = pop(),
                        ?assertEqual("format world", lists:flatten(Message3)),
                        {_Level, _Time4, Message4, _Metadata4}  = pop(),
                        ?assertEqual("hello world", lists:flatten(Message4)),
                        {_Level, _Time5, Message5, _Metadata5}  = pop(),
                        ?assertEqual("hello world", lists:flatten(Message5)),
                        {_Level, _Time6, Message6, Metadata6}  = pop(),
                        ?assertMatch([{d, delta}, {g, gamma}|_], Metadata6),
                        ?assertEqual("format world", lists:flatten(Message6)),
                        ok
                end
            },
            {"record fields inplace of literals in logging statements work",
                fun() ->
                        ?assertEqual(0, count()),
                        Test = #test{attrs=[{a, alpha}, {b, beta}], format="format ~p", args=[world]},
                        lager:info(Test#test.attrs, "hello"),
                        lager:info(Test#test.attrs, "hello ~p", Test#test.args),
                        lager:info(Test#test.format, [world]),
                        lager:info("hello ~p", Test#test.args),
                        lager:info(Test#test.attrs, "hello ~p", Test#test.args),
                        lager:info([{d, delta}, {g, gamma}], Test#test.format, Test#test.args),
                        ?assertEqual(6, count()),
                        {_Level, _Time, Message, Metadata}  = pop(),
                        ?assertMatch([{a, alpha}, {b, beta}|_], Metadata),
                        ?assertEqual("hello", lists:flatten(Message)),
                        {_Level, _Time2, Message2, _Metadata2}  = pop(),
                        ?assertEqual("hello world", lists:flatten(Message2)),
                        {_Level, _Time3, Message3, _Metadata3}  = pop(),
                        ?assertEqual("format world", lists:flatten(Message3)),
                        {_Level, _Time4, Message4, _Metadata4}  = pop(),
                        ?assertEqual("hello world", lists:flatten(Message4)),
                        {_Level, _Time5, Message5, _Metadata5}  = pop(),
                        ?assertEqual("hello world", lists:flatten(Message5)),
                        {_Level, _Time6, Message6, Metadata6}  = pop(),
                        ?assertMatch([{d, delta}, {g, gamma}|_], Metadata6),
                        ?assertEqual("format world", lists:flatten(Message6)),
                        ok
                end
            },

            {"log messages below the threshold are ignored",
                fun() ->
                        ?assertEqual(0, count()),
                        lager:debug("this message will be ignored"),
                        ?assertEqual(0, count()),
                        ?assertEqual(0, count_ignored()),
                        lager_config:set(loglevel, {element(2, lager_util:config_to_mask(debug)), []}),
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
                        lager_config:set(loglevel, {element(2, lager_util:config_to_mask(error)), []}),
                        ok = lager:info("hello world"),
                        ?assertEqual(0, count()),
                        lager:trace(?MODULE, [{module, ?MODULE}], debug),
                        %% elegible for tracing
                        ok = lager:info("hello world"),
                        %% NOT elegible for tracing
                        ok = lager:log(info, [{pid, self()}], "hello world"),
                        ?assertEqual(1, count()),
                        ok
                end
            },
            {"tracing works with custom attributes",
                fun() ->
                        lager:set_loglevel(?MODULE, error),
                        lager_config:set(loglevel, {element(2, lager_util:config_to_mask(error)), []}),
                        lager:info([{requestid, 6}], "hello world"),
                        ?assertEqual(0, count()),
                        lager:trace(?MODULE, [{requestid, 6}, {foo, bar}], debug),
                        lager:info([{requestid, 6}, {foo, bar}], "hello world"),
                        ?assertEqual(1, count()),
                        lager:trace(?MODULE, [{requestid, '*'}], debug),
                        lager:info([{requestid, 6}], "hello world"),
                        ?assertEqual(2, count()),
                        lager:clear_all_traces(),
                        lager:info([{requestid, 6}], "hello world"),
                        ?assertEqual(2, count()),
                        ok
                end
            },
            {"tracing honors loglevel",
                fun() ->
                        lager:set_loglevel(?MODULE, error),
                        {ok, T} = lager:trace(?MODULE, [{module, ?MODULE}], notice),
                        ok = lager:info("hello world"),
                        ?assertEqual(0, count()),
                        ok = lager:notice("hello world"),
                        ?assertEqual(1, count()),
                        lager:stop_trace(T),
                        ok = lager:notice("hello world"),
                        ?assertEqual(1, count()),
                        ok
                end
            },
            {"record printing works",
                fun() ->
                        print_state(),
                        {Level, _Time, Message, _Metadata}  = pop(),
                        ?assertMatch(Level, lager_util:level_to_num(info)),
                        {mask, Mask} = lager_util:config_to_mask(info),
                        ?assertEqual("State #state{level={mask,"++integer_to_list(Mask)++"},buffer=[],ignored=[]}", lists:flatten(Message)),
                        ok
                end
            },
            {"record printing fails gracefully",
                fun() ->
                        print_bad_state(),
                        {Level, _Time, Message, _Metadata}  = pop(),
                        ?assertMatch(Level, lager_util:level_to_num(info)),
                        ?assertEqual("State {state,1}", lists:flatten(Message)),
                        ok
                end
            },
            {"record printing fails gracefully when no lager_record attribute",
                fun() ->
                        spawn(fun() -> lager:info("State ~p", [lager:pr({state, 1}, lager)]) end),
                        timer:sleep(100),
                        {Level, _Time, Message, _Metadata}  = pop(),
                        ?assertMatch(Level, lager_util:level_to_num(info)),
                        ?assertEqual("State {state,1}", lists:flatten(Message)),
                        ok
                end
            },
            {"record printing fails gracefully when input is not a tuple",
                fun() ->
                        spawn(fun() -> lager:info("State ~p", [lager:pr(ok, lager)]) end),
                        timer:sleep(100),
                        {Level, _Time, Message, _Metadata}  = pop(),
                        ?assertMatch(Level, lager_util:level_to_num(info)),
                        ?assertEqual("State ok", lists:flatten(Message)),
                        ok
                end
            },
            {"record printing fails gracefully when module is invalid",
                fun() ->
                        spawn(fun() -> lager:info("State ~p", [lager:pr({state, 1}, not_a_module)]) end),
                        timer:sleep(100),
                        {Level, _Time, Message, _Metadata}  = pop(),
                        ?assertMatch(Level, lager_util:level_to_num(info)),
                        ?assertEqual("State {state,1}", lists:flatten(Message)),
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
            case string:substr(FileLine, 1, 6) of
                [] ->
                    %% sometimes there's no line information...
                    ?assert(true);
                " line " ->
                    ?assert(true);
                Other ->
                    ?debugFmt("unexpected trailing data ~p", [Other]),
                    ?assert(false)
            end;
        false ->
            ?assertEqual(Expected, Actual)
    end.


error_logger_redirect_crash_test_() ->
    TestBody=fun(Name,CrashReason,Expected) -> {Name,
                fun() ->
                        Pid = whereis(crash),
                        crash(CrashReason),
                        {Level, _, Msg,Metadata} = pop(),
                        test_body(Expected, lists:flatten(Msg)),
                        ?assertEqual(Pid,proplists:get_value(pid,Metadata)),
                        ?assertEqual(lager_util:level_to_num(error),Level)
                end
            } 
    end,
    {foreach,
        fun() ->
                error_logger:tty(false),
                application:load(lager),
                application:set_env(lager, error_logger_redirect, true),
                application:set_env(lager, handlers, [{?MODULE, error}]),
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

            TestBody("bad return value",bad_return,"gen_server crash terminated with reason: bad return value: bleh"),
            TestBody("bad return value with string",bad_return_string,"gen_server crash terminated with reason: bad return value: {tuple,{tuple,\"string\"}}"),
            TestBody("bad return uncaught throw",throw,"gen_server crash terminated with reason: bad return value: a_ball"),
            TestBody("case clause",case_clause,"gen_server crash terminated with reason: no case clause matching {} in crash:handle_call/3"),
            TestBody("case clause string",case_clause_string,"gen_server crash terminated with reason: no case clause matching \"crash\" in crash:handle_call/3"),
            TestBody("function clause",function_clause,"gen_server crash terminated with reason: no function clause matching crash:function({})"),
            TestBody("if clause",if_clause,"gen_server crash terminated with reason: no true branch found while evaluating if expression in crash:handle_call/3"),
            TestBody("try clause",try_clause,"gen_server crash terminated with reason: no try clause matching [] in crash:handle_call/3"),
            TestBody("undefined function",undef,"gen_server crash terminated with reason: call to undefined function crash:booger/0 from crash:handle_call/3"),
            TestBody("bad math",badarith,"gen_server crash terminated with reason: bad arithmetic expression in crash:handle_call/3"),
            TestBody("bad match",badmatch,"gen_server crash terminated with reason: no match of right hand value {} in crash:handle_call/3"),
            TestBody("bad arity",badarity,"gen_server crash terminated with reason: fun called with wrong arity of 1 instead of 3 in crash:handle_call/3"),
            TestBody("bad arg1",badarg1,"gen_server crash terminated with reason: bad argument in crash:handle_call/3"),
            TestBody("bad arg2",badarg2,"gen_server crash terminated with reason: bad argument in call to erlang:iolist_to_binary([\"foo\",bar]) in crash:handle_call/3"),
            TestBody("bad record",badrecord,"gen_server crash terminated with reason: bad record state in crash:handle_call/3"),
            TestBody("noproc",noproc,"gen_server crash terminated with reason: no such process or port in call to gen_event:call(foo, bar, baz)"),
            TestBody("badfun",badfun,"gen_server crash terminated with reason: bad function booger in crash:handle_call/3")
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
                        {Level, _, Msg,Metadata} = pop(),
                        ?assertEqual(lager_util:level_to_num(error),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        Expected = "this: is, a, silly: format",
                        ?assertEqual(Expected, lists:flatten(Msg))

                end
            },
            {"string error reports are printed",
                fun() ->
                        sync_error_logger:error_report("this is less silly"),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(),
                        ?assertEqual(lager_util:level_to_num(error),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        Expected = "this is less silly",
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"error messages are printed",
                fun() ->
                        sync_error_logger:error_msg("doom, doom has come upon you all"),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(),
                        ?assertEqual(lager_util:level_to_num(error),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        Expected = "doom, doom has come upon you all",
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"error messages are truncated at 4096 characters",
                fun() ->
                        sync_error_logger:error_msg("doom, doom has come upon you all ~p", [string:copies("doom", 10000)]),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg,_Metadata} = pop(),
                        ?assert(length(lists:flatten(Msg)) < 5100)
                end
            },
            {"info reports are printed",
                fun() ->
                        sync_error_logger:info_report([{this, is}, a, {silly, format}]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(),
                        ?assertEqual(lager_util:level_to_num(info),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        Expected = "this: is, a, silly: format",
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"info reports are truncated at 4096 characters",
                fun() ->
                        sync_error_logger:info_report([[{this, is}, a, {silly, format}] || _ <- lists:seq(0, 600)]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(),
                        ?assertEqual(lager_util:level_to_num(info),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assert(length(lists:flatten(Msg)) < 5000)
                end
            },
            {"single term info reports are printed",
                fun() ->
                        sync_error_logger:info_report({foolish, bees}),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(),
                        ?assertEqual(lager_util:level_to_num(info),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("{foolish,bees}", lists:flatten(Msg))
                end
            },
            {"single term error reports are printed",
                fun() ->
                        sync_error_logger:error_report({foolish, bees}),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(),
                        ?assertEqual(lager_util:level_to_num(error),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("{foolish,bees}", lists:flatten(Msg))
                end
            },
            {"string info reports are printed",
                fun() ->
                        sync_error_logger:info_report("this is less silly"),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(),
                        ?assertEqual(lager_util:level_to_num(info),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("this is less silly", lists:flatten(Msg))
                end
            },
            {"string info reports are truncated at 4096 characters",
                fun() ->
                        sync_error_logger:info_report(string:copies("this is less silly", 1000)),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(),
                        ?assertEqual(lager_util:level_to_num(info),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assert(length(lists:flatten(Msg)) < 5100)
                end
            },
            {"strings in a mixed report are printed as strings",
                fun() ->
                        sync_error_logger:info_report(["this is less silly", {than, "this"}]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(),
                        ?assertEqual(lager_util:level_to_num(info),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("\"this is less silly\", than: \"this\"", lists:flatten(Msg))
                end
            },
            {"info messages are printed",
                fun() ->
                        sync_error_logger:info_msg("doom, doom has come upon you all"),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(),
                        ?assertEqual(lager_util:level_to_num(info),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("doom, doom has come upon you all", lists:flatten(Msg))
                end
            },
            {"info messages are truncated at 4096 characters",
                fun() ->
                        sync_error_logger:info_msg("doom, doom has come upon you all ~p", [string:copies("doom", 10000)]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(),
                        ?assertEqual(lager_util:level_to_num(info),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assert(length(lists:flatten(Msg)) < 5100)
                end
            },

            {"warning messages are printed at the correct level",
                fun() ->
                        sync_error_logger:warning_msg("doom, doom has come upon you all"),
                        Map = error_logger:warning_map(),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(),
                        ?assertEqual(lager_util:level_to_num(Map),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("doom, doom has come upon you all", lists:flatten(Msg))
                end
            },
            {"warning reports are printed at the correct level",
                fun() ->
                        sync_error_logger:warning_report([{i, like}, pie]),
                        Map = error_logger:warning_map(),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(),
                        ?assertEqual(lager_util:level_to_num(Map),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("i: like, pie", lists:flatten(Msg))
                end
            },
            {"single term warning reports are printed at the correct level",
                fun() ->
                        sync_error_logger:warning_report({foolish, bees}),
                        Map = error_logger:warning_map(),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(),
                        ?assertEqual(lager_util:level_to_num(Map),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("{foolish,bees}", lists:flatten(Msg))
                end
            },
            {"application stop reports",
                fun() ->
                        sync_error_logger:info_report([{application, foo}, {exited, quittin_time}, {type, lazy}]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(),
                        ?assertEqual(lager_util:level_to_num(info),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("Application foo exited with reason: quittin_time", lists:flatten(Msg))
                end
            },
            {"supervisor reports",
                fun() ->
                        sync_error_logger:error_report(supervisor_report, [{errorContext, france}, {offender, [{name, mini_steve}, {mfargs, {a, b, [c]}}, {pid, bleh}]}, {reason, fired}, {supervisor, {local, steve}}]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(),
                        ?assertEqual(lager_util:level_to_num(error),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("Supervisor steve had child mini_steve started with a:b(c) at bleh exit with reason fired in context france", lists:flatten(Msg))
                end
            },
            {"supervisor reports with real error",
                fun() ->
                        sync_error_logger:error_report(supervisor_report, [{errorContext, france}, {offender, [{name, mini_steve}, {mfargs, {a, b, [c]}}, {pid, bleh}]}, {reason, {function_clause,[{crash,handle_info,[foo]}]}}, {supervisor, {local, steve}}]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(),
                        ?assertEqual(lager_util:level_to_num(error),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("Supervisor steve had child mini_steve started with a:b(c) at bleh exit with reason no function clause matching crash:handle_info(foo) in context france", lists:flatten(Msg))
                end
            },

            {"supervisor_bridge reports",
                fun() ->
                        sync_error_logger:error_report(supervisor_report, [{errorContext, france}, {offender, [{mod, mini_steve}, {pid, bleh}]}, {reason, fired}, {supervisor, {local, steve}}]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(),
                        ?assertEqual(lager_util:level_to_num(error),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("Supervisor steve had child at module mini_steve at bleh exit with reason fired in context france", lists:flatten(Msg))
                end
            },
            {"application progress report",
                fun() ->
                        sync_error_logger:info_report(progress, [{application, foo}, {started_at, node()}]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(),
                        ?assertEqual(lager_util:level_to_num(info),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        Expected = lists:flatten(io_lib:format("Application foo started on node ~w", [node()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"supervisor progress report",
                fun() ->
                        lager:set_loglevel(?MODULE, debug),
                        sync_error_logger:info_report(progress, [{supervisor, {local, foo}}, {started, [{mfargs, {foo, bar, 1}}, {pid, baz}]}]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(),
                        ?assertEqual(lager_util:level_to_num(debug),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("Supervisor foo started foo:bar/1 at pid baz", lists:flatten(Msg))
                end
            },
            {"crash report for emfile",
                fun() ->
                        sync_error_logger:error_report(crash_report, [[{pid, self()}, {registered_name, []}, {error_info, {error, emfile, [{stack, trace, 1}]}}], []]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(),
                        ?assertEqual(lager_util:level_to_num(error),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        Expected = lists:flatten(io_lib:format("CRASH REPORT Process ~w with 0 neighbours crashed with reason: maximum number of file descriptors exhausted, check ulimit -n", [self()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"crash report for system process limit",
                fun() ->
                        sync_error_logger:error_report(crash_report, [[{pid, self()}, {registered_name, []}, {error_info, {error, system_limit, [{erlang, spawn, 1}]}}], []]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(),
                        ?assertEqual(lager_util:level_to_num(error),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        Expected = lists:flatten(io_lib:format("CRASH REPORT Process ~w with 0 neighbours crashed with reason: system limit: maximum number of processes exceeded", [self()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"crash report for system process limit2",
                fun() ->
                        sync_error_logger:error_report(crash_report, [[{pid, self()}, {registered_name, []}, {error_info, {error, system_limit, [{erlang, spawn_opt, 1}]}}], []]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(),
                        ?assertEqual(lager_util:level_to_num(error),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        Expected = lists:flatten(io_lib:format("CRASH REPORT Process ~w with 0 neighbours crashed with reason: system limit: maximum number of processes exceeded", [self()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"crash report for system port limit",
                fun() ->
                        sync_error_logger:error_report(crash_report, [[{pid, self()}, {registered_name, []}, {error_info, {error, system_limit, [{erlang, open_port, 1}]}}], []]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(),
                        ?assertEqual(lager_util:level_to_num(error),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        Expected = lists:flatten(io_lib:format("CRASH REPORT Process ~w with 0 neighbours crashed with reason: system limit: maximum number of ports exceeded", [self()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"crash report for system port limit",
                fun() ->
                        sync_error_logger:error_report(crash_report, [[{pid, self()}, {registered_name, []}, {error_info, {error, system_limit, [{erlang, list_to_atom, 1}]}}], []]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(),
                        ?assertEqual(lager_util:level_to_num(error),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        Expected = lists:flatten(io_lib:format("CRASH REPORT Process ~w with 0 neighbours crashed with reason: system limit: tried to create an atom larger than 255, or maximum atom count exceeded", [self()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"crash report for system ets table limit",
                fun() ->
                        sync_error_logger:error_report(crash_report, [[{pid, self()}, {registered_name, test}, {error_info, {error, system_limit, [{ets,new,[segment_offsets,[ordered_set,public]]},{mi_segment,open_write,1},{mi_buffer_converter,handle_cast,2},{gen_server,handle_msg,5},{proc_lib,init_p_do_apply,3}]}}], []]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(),
                        ?assertEqual(lager_util:level_to_num(error),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        Expected = lists:flatten(io_lib:format("CRASH REPORT Process ~w with 0 neighbours crashed with reason: system limit: maximum number of ETS tables exceeded", [test])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"crash report for unknown system limit should be truncated at 500 characters",
                fun() ->
                        sync_error_logger:error_report(crash_report, [[{pid, self()}, {error_info, {error, system_limit, [{wtf,boom,[string:copies("aaaa", 4096)]}]}}], []]),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg,_Metadata} = pop(),
                        ?assert(length(lists:flatten(Msg)) > 550),
                        ?assert(length(lists:flatten(Msg)) < 600)
                end
            },
            {"crash reports for 'special processes' should be handled right - function_clause", 
                fun() ->
                        {ok, Pid} = special_process:start(),
                        unlink(Pid),
                        Pid ! function_clause,
                        timer:sleep(500),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg, _Metadata} = pop(),
                        Expected = lists:flatten(io_lib:format("CRASH REPORT Process ~p with 0 neighbours crashed with reason: no function clause matching special_process:foo(bar)",
                                [Pid])),
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
                        {_, _, Msg, _Metadata} = pop(),
                        Expected = lists:flatten(io_lib:format("CRASH REPORT Process ~p with 0 neighbours crashed with reason: no case clause matching wtf in special_process:loop/0",
                                [Pid])),
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
                        {_, _, Msg, _Metadata} = pop(),
                        Expected = lists:flatten(io_lib:format("CRASH REPORT Process ~p with 0 neighbours exited with reason: byebye in special_process:loop/0",
                                [Pid])),
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
                        {_, _, Msg, _Metadata} = pop(),
                        Expected = lists:flatten(io_lib:format("CRASH REPORT Process ~p with 0 neighbours crashed with reason: mybad in special_process:loop/0",
                                [Pid])),
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
                        lager_config:set(loglevel, {element(2, lager_util:config_to_mask(debug)), []}),
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


