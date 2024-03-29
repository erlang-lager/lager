%% -------------------------------------------------------------------
%%
%% Copyright (c) 2011-2017 Basho Technologies, Inc.
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
%%
%% -------------------------------------------------------------------

-module(lager_test_backend).

-behaviour(gen_event).

-export([init/1, handle_call/2, handle_event/2, handle_info/2, terminate/2,
        code_change/3]).

-include("lager.hrl").

-define(TEST_SINK_NAME, '__lager_test_sink').              %% <-- used by parse transform
-define(TEST_SINK_EVENT, '__lager_test_sink_lager_event'). %% <-- used by lager API calls and internals for gen_event

-record(state, {
    level   :: list(),
    buffer  :: list(),
    ignored :: term()
}).
-compile({parse_transform, lager_transform}).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-record(test, {
    attrs   :: list(),
    format  :: list(),
    args    :: list()
}).
-export([
    count/0,
    count_ignored/0,
    flush/0,
    message_stuffer/3,
    pop/0,
    pop_ignored/0,
    print_state/0,
    get_buffer/0
]).
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
handle_call(pop_ignored, #state{ignored=Ignored} = State) ->
    case Ignored of
        [] ->
            {ok, undefined, State};
        [H|T] ->
            {ok, H, State#state{ignored=T}}
    end;
handle_call(get_buffer, #state{buffer=Buffer} = State) ->
    {ok, Buffer, State};
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
                               lager_msg:datetime(Msg),
                               lager_msg:message(Msg), lager_msg:metadata(Msg)}]}};
        _ ->
            {ok, State#state{ignored=Ignored ++ [Msg]}}
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
    pop(lager_event).

pop_ignored() ->
    pop_ignored(lager_event).

get_buffer() ->
    get_buffer(lager_event).

count() ->
    count(lager_event).

count_ignored() ->
    count_ignored(lager_event).

flush() ->
    flush(lager_event).

print_state() ->
    print_state(lager_event).

print_bad_state() ->
    print_bad_state(lager_event).

pop(Sink) ->
    gen_event:call(Sink, ?MODULE, pop).

pop_ignored(Sink) ->
    gen_event:call(Sink, ?MODULE, pop_ignored).

get_buffer(Sink) ->
    gen_event:call(Sink, ?MODULE, get_buffer).

count(Sink) ->
    gen_event:call(Sink, ?MODULE, count).

count_ignored(Sink) ->
    gen_event:call(Sink, ?MODULE, count_ignored).

flush(Sink) ->
    gen_event:call(Sink, ?MODULE, flush).

print_state(Sink) ->
    gen_event:call(Sink, ?MODULE, print_state).

print_bad_state(Sink) ->
    gen_event:call(Sink, ?MODULE, print_bad_state).

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
            {"test sink not running",
                fun() ->
                         ?assertEqual({error, {sink_not_configured, test}}, lager:log(test, info, self(), "~p", "not running"))
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
            {"logging with macro works",
                fun() ->
                        ?lager_warning("test message", []),
                        ?assertEqual(1, count()),
                        {Level, _Time, Message, _Metadata}  = pop(),
                        ?assertMatch(Level, lager_util:level_to_num(warning)),
                        ?assertEqual("test message", Message),
                        ok
                end
            },
            {"unsafe logging works",
                fun() ->
                        lager:warning_unsafe("test message"),
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
            {"logging with macro and arguments works",
                fun() ->
                        ?lager_warning("test message ~p", [self()]),
                        ?assertEqual(1, count()),
                        {Level, _Time, Message,_Metadata}  = pop(),
                        ?assertMatch(Level, lager_util:level_to_num(warning)),
                        ?assertEqual(lists:flatten(io_lib:format("test message ~p", [self()])), lists:flatten(Message)),
                        ok
                end
            },
            {"unsafe logging with args works",
                fun() ->
                        lager:warning_unsafe("test message ~p", [self()]),
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
            {"logging with only metadata works",
                fun() ->
                        ?assertEqual(0, count()),
                        lager:warning([{just, metadata}]),
                        lager:warning([{just, metadata}, {foo, bar}]),
                        ?assertEqual(2, count()),
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
                        {Level, _Time, Message, Metadata}  = pop(),
                        ?assertMatch([{a, alpha}, {b, beta}|_], Metadata),
                        ?assertEqual("hello", lists:flatten(Message)),
                        {Level, _Time2, Message2, _Metadata2}  = pop(),
                        ?assertEqual("hello world", lists:flatten(Message2)),
                        {Level, _Time3, Message3, _Metadata3}  = pop(),
                        ?assertEqual("format world", lists:flatten(Message3)),
                        {Level, _Time4, Message4, _Metadata4}  = pop(),
                        ?assertEqual("hello world", lists:flatten(Message4)),
                        {Level, _Time5, Message5, _Metadata5}  = pop(),
                        ?assertEqual("hello world", lists:flatten(Message5)),
                        {Level, _Time6, Message6, Metadata6}  = pop(),
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
                        {Level, _Time, Message, Metadata}  = pop(),
                        ?assertMatch([{a, "alpha"}, {b, "beta"}|_], Metadata),
                        ?assertEqual("hello", lists:flatten(Message)),
                        {Level, _Time2, Message2, _Metadata2}  = pop(),
                        ?assertEqual("hello {atom,world}", lists:flatten(Message2)),
                        {Level, _Time3, Message3, _Metadata3}  = pop(),
                        ?assertEqual("format world", lists:flatten(Message3)),
                        {Level, _Time4, Message4, _Metadata4}  = pop(),
                        ?assertEqual("hello {atom,world}", lists:flatten(Message4)),
                        {Level, _Time5, Message5, _Metadata5}  = pop(),
                        ?assertEqual("hello {atom,world}", lists:flatten(Message5)),
                        {Level, _Time6, Message6, Metadata6}  = pop(),
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
                        {Level, _Time, Message, Metadata}  = pop(),
                        ?assertMatch([{a, alpha}, {b, beta}|_], Metadata),
                        ?assertEqual("hello", lists:flatten(Message)),
                        {Level, _Time2, Message2, _Metadata2}  = pop(),
                        ?assertEqual("hello world", lists:flatten(Message2)),
                        {Level, _Time3, Message3, _Metadata3}  = pop(),
                        ?assertEqual("format world", lists:flatten(Message3)),
                        {Level, _Time4, Message4, _Metadata4}  = pop(),
                        ?assertEqual("hello world", lists:flatten(Message4)),
                        {Level, _Time5, Message5, _Metadata5}  = pop(),
                        ?assertEqual("hello world", lists:flatten(Message5)),
                        {Level, _Time6, Message6, Metadata6}  = pop(),
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
                        {Level, _Time, Message, Metadata}  = pop(),
                        ?assertMatch([{a, alpha}, {b, beta}|_], Metadata),
                        ?assertEqual("hello", lists:flatten(Message)),
                        {Level, _Time2, Message2, _Metadata2}  = pop(),
                        ?assertEqual("hello world", lists:flatten(Message2)),
                        {Level, _Time3, Message3, _Metadata3}  = pop(),
                        ?assertEqual("format world", lists:flatten(Message3)),
                        {Level, _Time4, Message4, _Metadata4}  = pop(),
                        ?assertEqual("hello world", lists:flatten(Message4)),
                        {Level, _Time5, Message5, _Metadata5}  = pop(),
                        ?assertEqual("hello world", lists:flatten(Message5)),
                        {Level, _Time6, Message6, Metadata6}  = pop(),
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
                        ?assertEqual({?DEBUG bor ?INFO bor ?NOTICE bor ?WARNING bor ?ERROR bor ?CRITICAL bor ?ALERT bor ?EMERGENCY, []}, lager_config:get(loglevel)),
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
                        ?assertMatch({?ERROR bor ?CRITICAL bor ?ALERT bor ?EMERGENCY, _}, lager_config:get(loglevel)),
                        %% eligible for tracing
                        ok = lager:info("hello world"),
                        %% NOT eligible for tracing
                        ok = lager:log(info, [{pid, self()}], "hello world"),
                        ?assertEqual(1, count()),
                        ok
                end
            },
            {"tracing works with custom attributes",
                fun() ->
                        lager:set_loglevel(?MODULE, error),
                        ?assertEqual({?ERROR bor ?CRITICAL bor ?ALERT bor ?EMERGENCY, []}, lager_config:get(loglevel)),
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
            {"tracing works with custom attributes and event stream processing",
                fun() ->
                        lager:set_loglevel(?MODULE, error),
                        ?assertEqual({?ERROR bor ?CRITICAL bor ?ALERT bor ?EMERGENCY, []}, lager_config:get(loglevel)),
                        lager_config:set(loglevel, {element(2, lager_util:config_to_mask(error)), []}),
                        lager:info([{requestid, 6}], "hello world"),
                        ?assertEqual(0, count()),
                        lager:trace(?MODULE, [{requestid, '>', 5}, {requestid, '<', 7}, {foo, bar}], debug),
                        lager:info([{requestid, 5}, {foo, bar}], "hello world"),
                        lager:info([{requestid, 6}, {foo, bar}], "hello world"),
                        ?assertEqual(1, count()),
                        lager:clear_all_traces(),
                        lager:trace(?MODULE, [{requestid, '>', 8}, {foo, bar}]),
                        lager:info([{foo, bar}], "hello world"),
                        lager:info([{requestid, 6}], "hello world"),
                        lager:info([{requestid, 7}], "hello world"),
                        lager:info([{requestid, 8}], "hello world"),
                        lager:info([{requestid, 9}, {foo, bar}], "hello world"),
                        lager:info([{requestid, 10}], "hello world"),
                        ?assertEqual(2, count()),
                        lager:trace(?MODULE, [{requestid, '>', 8}]),
                        lager:info([{foo, bar}], "hello world"),
                        lager:info([{requestid, 6}], "hello world"),
                        lager:info([{requestid, 7}], "hello world"),
                        lager:info([{requestid, 8}], "hello world"),
                        lager:info([{requestid, 9}, {foo, bar}], "hello world"),
                        lager:info([{requestid, 10}], "hello world"),
                        ?assertEqual(4, count()),
                        lager:trace(?MODULE, [{foo, '=', bar}]),
                        lager:info([{foo, bar}], "hello world"),
                        lager:info([{requestid, 6}], "hello world"),
                        lager:info([{requestid, 7}], "hello world"),
                        lager:info([{requestid, 8}], "hello world"),
                        lager:info([{requestid, 9}, {foo, bar}], "hello world"),
                        lager:info([{requestid, 10}], "hello world"),
                        lager:trace(?MODULE, [{fu, '!'}]),
                        lager:info([{foo, bar}], "hello world"),
                        lager:info([{ooh, car}], "hello world"),
                        lager:info([{fu, bar}], "hello world"),
                        lager:trace(?MODULE, [{fu, '*'}]),
                        lager:info([{fu, bar}], "hello world"),
                        ?assertEqual(10, count()),
                        lager:clear_all_traces(),
                        lager:info([{requestid, 6}], "hello world"),
                        ?assertEqual(10, count()),
                        lager:clear_all_traces(),
                        lager:trace(?MODULE, [{requestid, '>=', 5}, {requestid, '=<', 7}], debug),
                        lager:info([{requestid, 4}], "nope!"),
                        lager:info([{requestid, 5}], "hello world"),
                        lager:info([{requestid, 7}], "hello world again"),
                        ?assertEqual(12, count()),
                        lager:clear_all_traces(),
                        lager:trace(?MODULE, [{foo, '!=', bar}]),
                        lager:info([{foo, bar}], "hello world"),
                        ?assertEqual(12, count()),
                        lager:info([{foo, baz}], "blarg"),
                        ?assertEqual(13, count()),
                        lager:clear_all_traces(),
                        lager:trace(?MODULE, [{all, [{foo, '=', bar}, {null, false}]}]),
                        lager:info([{foo, bar}], "should not be logged"),
                        ?assertEqual(13, count()),
                        lager:clear_all_traces(),
                        lager:trace(?MODULE, [{any, [{foo, '=', bar}, {null, true}]}]),
                        lager:info([{foo, qux}], "should be logged"),
                        ?assertEqual(14, count()),
                        ok
                end
            },
            {"tracing custom attributes works with event stream processing statistics and reductions",
                fun() ->
                        lager:set_loglevel(?MODULE, error),
                        ?assertEqual({?ERROR bor ?CRITICAL bor ?ALERT bor ?EMERGENCY, []}, lager_config:get(loglevel)),
                        lager_config:set(loglevel, {element(2, lager_util:config_to_mask(error)), []}),
                        lager:info([{requestid, 6}], "hello world"),
                        ?assertEqual(0, count()),
                        lager:trace(?MODULE, [{beta, '*'}]),
                        lager:trace(?MODULE, [{meta, "data"}]),
                        lager:info([{meta, "data"}], "hello world"),
                        lager:info([{beta, 2}], "hello world"),
                        lager:info([{beta, 2.1}, {foo, bar}], "hello world"),
                        lager:info([{meta, <<"data">>}], "hello world"),
                        ?assertEqual(8, ?DEFAULT_TRACER:info(input)),
                        ?assertEqual(6, ?DEFAULT_TRACER:info(output)),
                        ?assertEqual(2, ?DEFAULT_TRACER:info(filter)),
                        lager:clear_all_traces(),
                        lager:trace(?MODULE, [{meta, "data"}]),
                        lager:trace(?MODULE, [{beta, '>', 2}, {beta, '<', 2.12}]),
                        lager:info([{meta, "data"}], "hello world"),
                        lager:info([{beta, 2}], "hello world"),
                        lager:info([{beta, 2.1}, {foo, bar}], "hello world"),
                        lager:info([{meta, <<"data">>}], "hello world"),
                        ?assertEqual(8, ?DEFAULT_TRACER:info(input)),
                        ?assertEqual(4, ?DEFAULT_TRACER:info(output)),
                        ?assertEqual(4, ?DEFAULT_TRACER:info(filter)),
                        lager:clear_all_traces(),
                        lager:trace_console([{beta, '>', 2}, {meta, "data"}]),
                        lager:trace_console([{beta, '>', 2}, {beta, '<', 2.12}]),
                        Reduced = {all,[{any,[{beta,'<',2.12},{meta,'=',"data"}]},
                                              {beta,'>',2}]},
                        ?assertEqual(Reduced, ?DEFAULT_TRACER:info('query')),

                        lager:clear_all_traces(),
                        lager:info([{requestid, 6}], "hello world"),
                        ?assertEqual(5, count()),
                        ok
                end
            },
            {"persistent traces work",
                fun() ->
                        ?assertEqual(0, count()),
                        lager:debug([{foo, bar}], "hello world"),
                        ?assertEqual(0, count()),
                        application:stop(lager),
                        application:set_env(lager, traces, [{lager_test_backend, [{foo, bar}], debug}]),
                        lager:start(),
                        timer:sleep(5),
                        flush(),
                        lager:debug([{foo, bar}], "hello world"),
                        ?assertEqual(1, count()),
                        application:unset_env(lager, traces),
                        ok
                end
            },
            {"tracing honors loglevel",
                fun() ->
                        lager:set_loglevel(?MODULE, error),
                        ?assertEqual({?ERROR bor ?CRITICAL bor ?ALERT bor ?EMERGENCY, []}, lager_config:get(loglevel)),
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
            {"stopped trace stops and removes its event handler - default sink (gh#267)",
             {timeout, 10,
                fun() ->
                        Sink = ?DEFAULT_SINK,
                        StartHandlers = gen_event:which_handlers(Sink),
                        {_, T0} = lager_config:get({Sink, loglevel}),
                        StartGlobal = lager_config:global_get(handlers),
                        ?assertEqual([], T0),
                        {ok, TestTrace1} = lager:trace_file("/tmp/test", [{a,b}]),
                        MidHandlers = gen_event:which_handlers(Sink),
                        {ok, TestTrace2} = lager:trace_file("/tmp/test", [{c,d}]),
                        MidHandlers = gen_event:which_handlers(Sink),
                        ?assertEqual(length(StartHandlers)+1, length(MidHandlers)),
                        MidGlobal = lager_config:global_get(handlers),
                        ?assertEqual(length(StartGlobal)+1, length(MidGlobal)),
                        {_, T1} = lager_config:get({Sink, loglevel}),
                        ?assertEqual(2, length(T1)),
                        ok = lager:stop_trace(TestTrace1),
                        {_, T2} = lager_config:get({Sink, loglevel}),
                        ?assertEqual(1, length(T2)),
                        ?assertEqual(length(StartHandlers)+1, length(
                                                                gen_event:which_handlers(Sink))),

                        ?assertEqual(length(StartGlobal)+1, length(lager_config:global_get(handlers))),
                        ok = lager:stop_trace(TestTrace2),
                        EndHandlers = gen_event:which_handlers(Sink),
                        EndGlobal = lager_config:global_get(handlers),
                        {_, T3} = lager_config:get({Sink, loglevel}),
                        ?assertEqual([], T3),
                        ?assertEqual(StartHandlers, EndHandlers),
                        ?assertEqual(StartGlobal, EndGlobal),
                        ok
                end}
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
                        timer:sleep(1000),
                        {Level, _Time, Message, _Metadata}  = pop(),
                        ?assertMatch(Level, lager_util:level_to_num(info)),
                        ?assertEqual("State {state,1}", lists:flatten(Message)),
                        ok
                end
            },
            {"installing a new handler adjusts the global loglevel if necessary",
                fun() ->
                        ?assertEqual({?INFO bor ?NOTICE bor ?WARNING bor ?ERROR bor ?CRITICAL bor ?ALERT bor ?EMERGENCY, []}, lager_config:get(loglevel)),
                        supervisor:start_child(lager_handler_watcher_sup, [lager_event, {?MODULE, foo}, debug]),
                        ?assertEqual({?DEBUG bor ?INFO bor ?NOTICE bor ?WARNING bor ?ERROR bor ?CRITICAL bor ?ALERT bor ?EMERGENCY, []}, lager_config:get(loglevel)),
                        ok
                end
            },
            {"metadata in the process dictionary works",
                fun() ->
                        lager:md([{platypus, gravid}, {sloth, hirsute}, {duck, erroneous}]),
                        lager:info("I sing the animal kingdom electric!"),
                        {_Level, _Time, _Message, Metadata}  = pop(),
                        ?assertEqual(gravid, proplists:get_value(platypus, Metadata)),
                        ?assertEqual(hirsute, proplists:get_value(sloth, Metadata)),
                        ?assertEqual(erroneous, proplists:get_value(duck, Metadata)),
                        ?assertEqual(undefined, proplists:get_value(eagle, Metadata)),
                        lager:md([{platypus, gravid}, {sloth, hirsute}, {eagle, superincumbent}]),
                        lager:info("I sing the animal kingdom dielectric!"),
                        {_Level2, _Time2, _Message2, Metadata2}  = pop(),
                        ?assertEqual(gravid, proplists:get_value(platypus, Metadata2)),
                        ?assertEqual(hirsute, proplists:get_value(sloth, Metadata2)),
                        ?assertEqual(undefined, proplists:get_value(duck, Metadata2)),
                        ?assertEqual(superincumbent, proplists:get_value(eagle, Metadata2)),
                        ok
                end
            },
            {"unsafe messages really are not truncated",
                fun() ->
                        lager:info_unsafe("doom, doom has come upon you all ~p", [string:copies("doom", 1500)]),
                        {_, _, Msg,_Metadata} = pop(),
                        ?assert(length(lists:flatten(Msg)) == 6035)
                end
            },
            {"can't store invalid metadata",
                fun() ->
                        ?assertEqual(ok, lager:md([{platypus, gravid}, {sloth, hirsute}, {duck, erroneous}])),
                        ?assertError(badarg, lager:md({flamboyant, flamingo})),
                        ?assertError(badarg, lager:md("zookeeper zephyr")),
                        ok
                end
            },
            {"dates should be local by default",
                fun() ->
                        lager:warning("so long, and thanks for all the fish"),
                        ?assertEqual(1, count()),
                        {_Level, {_Date, Time}, _Message, _Metadata}  = pop(),
                        ?assertEqual(nomatch, binary:match(iolist_to_binary(Time), <<"UTC">>)),
                        ok
                end
            },
            {"dates should be UTC if SASL is configured as UTC",
                fun() ->
                        application:set_env(sasl, utc_log, true),
                        lager:warning("so long, and thanks for all the fish"),
                        application:set_env(sasl, utc_log, false),
                        ?assertEqual(1, count()),
                        {_Level, {_Date, Time}, _Message, _Metadata}  = pop(),
                        ?assertNotEqual(nomatch, binary:match(iolist_to_binary(Time), <<"UTC">>)),
                        ok
                end
            }
        ]
    }.

extra_sinks_test_() ->
    {foreach,
        fun setup_sink/0,
        fun cleanup/1,
        [
            {"observe that there is nothing up my sleeve",
                fun() ->
                        ?assertEqual(undefined, pop(?TEST_SINK_EVENT)),
                        ?assertEqual(0, count(?TEST_SINK_EVENT))
                end
            },
            {"logging works",
                fun() ->
                        ?TEST_SINK_NAME:warning("test message"),
                        ?assertEqual(1, count(?TEST_SINK_EVENT)),
                        {Level, _Time, Message, _Metadata}  = pop(?TEST_SINK_EVENT),
                        ?assertMatch(Level, lager_util:level_to_num(warning)),
                        ?assertEqual("test message", Message),
                        ok
                end
            },
            {"logging with arguments works",
                fun() ->
                        ?TEST_SINK_NAME:warning("test message ~p", [self()]),
                        ?assertEqual(1, count(?TEST_SINK_EVENT)),
                        {Level, _Time, Message,_Metadata}  = pop(?TEST_SINK_EVENT),
                        ?assertMatch(Level, lager_util:level_to_num(warning)),
                        ?assertEqual(lists:flatten(io_lib:format("test message ~p", [self()])), lists:flatten(Message)),
                        ok
                end
            },
            {"variables inplace of literals in logging statements work",
                fun() ->
                        ?assertEqual(0, count(?TEST_SINK_EVENT)),
                        Attr = [{a, alpha}, {b, beta}],
                        Fmt = "format ~p",
                        Args = [world],
                        ?TEST_SINK_NAME:info(Attr, "hello"),
                        ?TEST_SINK_NAME:info(Attr, "hello ~p", [world]),
                        ?TEST_SINK_NAME:info(Fmt, [world]),
                        ?TEST_SINK_NAME:info("hello ~p", Args),
                        ?TEST_SINK_NAME:info(Attr, "hello ~p", Args),
                        ?TEST_SINK_NAME:info([{d, delta}, {g, gamma}], Fmt, Args),
                        ?assertEqual(6, count(?TEST_SINK_EVENT)),
                        {Level, _Time, Message, Metadata}  = pop(?TEST_SINK_EVENT),
                        ?assertMatch([{a, alpha}, {b, beta}|_], Metadata),
                        ?assertEqual("hello", lists:flatten(Message)),
                        {Level, _Time2, Message2, _Metadata2}  = pop(?TEST_SINK_EVENT),
                        ?assertEqual("hello world", lists:flatten(Message2)),
                        {Level, _Time3, Message3, _Metadata3}  = pop(?TEST_SINK_EVENT),
                        ?assertEqual("format world", lists:flatten(Message3)),
                        {Level, _Time4, Message4, _Metadata4}  = pop(?TEST_SINK_EVENT),
                        ?assertEqual("hello world", lists:flatten(Message4)),
                        {Level, _Time5, Message5, _Metadata5}  = pop(?TEST_SINK_EVENT),
                        ?assertEqual("hello world", lists:flatten(Message5)),
                        {Level, _Time6, Message6, Metadata6}  = pop(?TEST_SINK_EVENT),
                        ?assertMatch([{d, delta}, {g, gamma}|_], Metadata6),
                        ?assertEqual("format world", lists:flatten(Message6)),
                        ok
                end
            },
            {"stopped trace stops and removes its event handler - test sink (gh#267)",
                fun() ->
                        Sink = ?TEST_SINK_EVENT,
                        StartHandlers = gen_event:which_handlers(Sink),
                        {_, T0} = lager_config:get({Sink, loglevel}),
                        StartGlobal = lager_config:global_get(handlers),
                        ?assertEqual([], T0),
                        {ok, TestTrace1} = lager:trace_file("/tmp/test", [{sink, Sink}, {a,b}]),
                        MidHandlers = gen_event:which_handlers(Sink),
                        {ok, TestTrace2} = lager:trace_file("/tmp/test", [{sink, Sink}, {c,d}]),
                        MidHandlers = gen_event:which_handlers(Sink),
                        ?assertEqual(length(StartHandlers)+1, length(MidHandlers)),
                        MidGlobal = lager_config:global_get(handlers),
                        ?assertEqual(length(StartGlobal)+1, length(MidGlobal)),
                        {_, T1} = lager_config:get({Sink, loglevel}),
                        ?assertEqual(2, length(T1)),
                        ok = lager:stop_trace(TestTrace1),
                        {_, T2} = lager_config:get({Sink, loglevel}),
                        ?assertEqual(1, length(T2)),
                        ?assertEqual(length(StartHandlers)+1, length(
                                                                gen_event:which_handlers(Sink))),

                        ?assertEqual(length(StartGlobal)+1, length(lager_config:global_get(handlers))),
                        ok = lager:stop_trace(TestTrace2),
                        EndHandlers = gen_event:which_handlers(Sink),
                        EndGlobal = lager_config:global_get(handlers),
                        {_, T3} = lager_config:get({Sink, loglevel}),
                        ?assertEqual([], T3),
                        ?assertEqual(StartHandlers, EndHandlers),
                        ?assertEqual(StartGlobal, EndGlobal),
                        ok
                end
            },
            {"log messages below the threshold are ignored",
                fun() ->
                        ?assertEqual(0, count(?TEST_SINK_EVENT)),
                        ?TEST_SINK_NAME:debug("this message will be ignored"),
                        ?assertEqual(0, count(?TEST_SINK_EVENT)),
                        ?assertEqual(0, count_ignored(?TEST_SINK_EVENT)),
                        lager_config:set({?TEST_SINK_EVENT, loglevel}, {element(2, lager_util:config_to_mask(debug)), []}),
                        ?TEST_SINK_NAME:debug("this message should be ignored"),
                        ?assertEqual(0, count(?TEST_SINK_EVENT)),
                        ?assertEqual(1, count_ignored(?TEST_SINK_EVENT)),
                        lager:set_loglevel(?TEST_SINK_EVENT, ?MODULE, undefined, debug),
                        ?assertEqual({?DEBUG bor ?INFO bor ?NOTICE bor ?WARNING bor ?ERROR bor ?CRITICAL bor ?ALERT bor ?EMERGENCY, []}, lager_config:get({?TEST_SINK_EVENT, loglevel})),
                        ?TEST_SINK_NAME:debug("this message should be logged"),
                        ?assertEqual(1, count(?TEST_SINK_EVENT)),
                        ?assertEqual(1, count_ignored(?TEST_SINK_EVENT)),
                        ?assertEqual(debug, lager:get_loglevel(?TEST_SINK_EVENT, ?MODULE)),
                        ok
                end
            }
    ]
    }.

setup_sink() ->
    error_logger:tty(false),
    application:load(lager),
    application:set_env(lager, handlers, []),
    application:set_env(lager, error_logger_redirect, false),
    application:set_env(lager, extra_sinks, [{?TEST_SINK_EVENT, [{handlers, [{?MODULE, info}]}]}]),
    lager:start(),
    gen_event:call(lager_event, ?MODULE, flush),
    gen_event:call(?TEST_SINK_EVENT, ?MODULE, flush).

setup() ->
    error_logger:tty(false),
    application:load(lager),
    application:set_env(lager, handlers, [{?MODULE, info}]),
    application:set_env(lager, error_logger_redirect, false),
    application:unset_env(lager, traces),
    lager:start(),
    %% There is a race condition between the application start up, lager logging its own
    %% start up condition and several tests that count messages or parse the output of
    %% tests.  When the lager start up message wins the race, it causes these tests
    %% which parse output or count message arrivals to fail.
    %%
    %% We introduce a sleep here to allow `flush' to arrive *after* the start up
    %% message has been received and processed.
    %%
    %% This race condition was first exposed during the work on
    %% 4b5260c4524688b545cc12da6baa2dfa4f2afec9 which introduced the lager
    %% manager killer PR.
    application:set_env(lager, suppress_supervisor_start_stop, true),
    application:set_env(lager, suppress_application_start_stop, true),
    timer:sleep(1000),
    gen_event:call(lager_event, ?MODULE, flush).

cleanup(_) ->
    catch ets:delete(lager_config), %% kill the ets config table with fire
    application:stop(lager),
    application:stop(goldrush),
    error_logger:tty(true).


crash(Type) ->
    spawn(fun() -> gen_server:call(crash, Type) end),
    timer:sleep(100),
    _ = gen_event:which_handlers(error_logger),
    ok.

test_body({slice, Expected}, Actual) ->
    SlicedActual = string:slice(Actual, 0, length(Expected)),
    ?assertEqual(Expected, SlicedActual, {Actual, sliced_to, SlicedActual, is_not_a_member_of, Expected});
test_body(Expected, Actual) ->
    ExLen = length(Expected),
    {Body, Rest} = case length(Actual) > ExLen of
        true ->
            {string:substr(Actual, 1, ExLen),
                string:substr(Actual, (ExLen + 1))};
        _ ->
            {Actual, []}
    end,
    ?assertEqual(Expected, Body),
    % OTP-17 (and maybe later releases) may tack on additional info
    % about the failure, so if Actual starts with Expected (already
    % confirmed by having gotten past assertEqual above) and ends
    % with " line NNN" we can ignore what's in-between. By extension,
    % since there may not be line information appended at all, any
    % text we DO find is reportable, but not a test failure.
    case Rest of
        [] ->
            ok;
        _ ->
            % isolate the extra data and report it if it's not just
            % a line number indicator
            case re:run(Rest, "^.*( line \\d+)$", [{capture, [1]}]) of
                nomatch ->
                    ?debugFmt(
                       "Trailing data \"~s\" following \"~s\"",
                       [Rest, Expected]);
                {match, [{0, _}]} ->
                    % the whole string is " line NNN"
                    ok;
                {match, [{Off, _}]} ->
                    ?debugFmt(
                       "Trailing data \"~s\" following \"~s\"",
                       [string:substr(Rest, 1, Off), Expected])
            end
    end.

error_logger_redirect_crash_setup() ->
    error_logger:tty(false),
    application:load(lager),
    application:set_env(lager, error_logger_redirect, true),
    application:set_env(lager, handlers, [{?MODULE, error}]),
    lager:start(),
    crash:start(),
    lager_event.

error_logger_redirect_crash_setup_sink() ->
    error_logger:tty(false),
    application:load(lager),
    application:set_env(lager, error_logger_redirect, true),
    application:unset_env(lager, handlers),
    application:set_env(lager, extra_sinks, [
        {error_logger_lager_event, [
            {handlers, [{?MODULE, error}]}]}]),
    lager:start(),
    crash:start(),
    error_logger_lager_event.

error_logger_redirect_crash_cleanup(_Sink) ->
    application:stop(lager),
    application:stop(goldrush),
    application:unset_env(lager, extra_sinks),
    case whereis(crash) of
        undefined -> ok;
        Pid -> exit(Pid, kill)
    end,
    error_logger:tty(true).

crash_fsm_setup() ->
    error_logger:tty(false),
    application:load(lager),
    application:set_env(lager, error_logger_redirect, true),
    application:set_env(lager, handlers, [{?MODULE, error}]),
    lager:start(),
    crash_fsm:start(),
    crash_statem:start(),
    lager:log(error, self(), "flush flush"),
    timer:sleep(100),
    gen_event:call(lager_event, ?MODULE, flush),
    lager_event.

crash_fsm_sink_setup() ->
    ErrorSink = error_logger_lager_event,
    error_logger:tty(false),
    application:load(lager),
    application:set_env(lager, error_logger_redirect, true),
    application:set_env(lager, handlers, []),
    application:set_env(lager, extra_sinks, [{ErrorSink, [{handlers, [{?MODULE, error}]}]}]),
    lager:start(),
    crash_fsm:start(),
    crash_statem:start(),
    lager:log(ErrorSink, error, self(), "flush flush", []),
    timer:sleep(100),
    flush(ErrorSink),
    ErrorSink.

crash_fsm_cleanup(_Sink) ->
    application:stop(lager),
    application:stop(goldrush),
    application:unset_env(lager, extra_sinks),
    lists:foreach(fun(N) -> kill_crasher(N) end, [crash_fsm, crash_statem]),
    error_logger:tty(true).

kill_crasher(RegName) ->
    case whereis(RegName) of
        undefined -> ok;
        Pid -> exit(Pid, kill)
    end.

spawn_fsm_crash(Module, Function, Args) ->
    spawn(fun() -> erlang:apply(Module, Function, Args) end),
    timer:sleep(100),
    _ = gen_event:which_handlers(error_logger),
    ok.

crash_fsm_test_() ->
    TestBody = fun(Name, FsmModule, FSMFunc, FSMArgs, Expected) ->
                   fun(Sink) ->
                      {Name,
                       fun() ->
                            case {FsmModule =:= crash_statem, lager_util:otp_version() < 19} of
                                {true, true} -> ok;
                                _ ->
                                    Pid = whereis(FsmModule),
                                    spawn_fsm_crash(FsmModule, FSMFunc, FSMArgs),
                                    {Level, _, Msg, Metadata} = pop(Sink),
                                    test_body(Expected, lists:flatten(Msg)),
                                    ?assertEqual(Pid, proplists:get_value(pid, Metadata)),
                                    ?assertEqual(lager_util:level_to_num(error), Level)
                            end
                       end
                      }
                   end
               end,
    Tests = [
        fun(Sink) ->
            {"again, there is nothing up my sleeve",
                fun() ->
                        ?assertEqual(undefined, pop(Sink)),
                        ?assertEqual(0, count(Sink))
                end
            }
        end,

        TestBody("gen_statem crash", crash_statem, crash, [], {slice, "gen_statem crash_statem in state state1 terminated with reason"}),
        TestBody("gen_statem stop", crash_statem, stop, [explode], {slice, "gen_statem crash_statem in state state1 terminated with reason"}),
        TestBody("gen_statem timeout", crash_statem, timeout, [], {slice, "gen_statem crash_statem in state state1 terminated with reason"})
    ] ++ test_body_gen_fsm_crash(TestBody),

    {"FSM crash output tests", [
        {"Default sink",
         {foreach,
            fun crash_fsm_setup/0,
            fun crash_fsm_cleanup/1,
            Tests}},
        {"Error logger sink",
         {foreach,
            fun crash_fsm_sink_setup/0,
            fun crash_fsm_cleanup/1,
            Tests}}
    ]}.

-if(?OTP_RELEASE < 23).
test_body_gen_fsm_crash(TestBody) ->
    [TestBody("gen_fsm crash", crash_fsm, crash, [], "gen_fsm crash_fsm in state state1 terminated with reason: call to undefined function crash_fsm:state1/3 from gen_fsm:handle_msg/")].
-else.
test_body_gen_fsm_crash(_TestBody) ->
    [].
-endif.

error_logger_redirect_crash_test_() ->
    TestBody=fun(Name,CrashReason,Expected) ->
        fun(Sink) ->
            {Name,
                fun() ->
                        Pid = whereis(crash),
                        crash(CrashReason),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        test_body(Expected, lists:flatten(Msg)),
                        ?assertEqual(Pid,proplists:get_value(pid,Metadata)),
                        ?assertEqual(lager_util:level_to_num(error),Level)
                end
            }
        end
    end,
    Tests = [
        fun(Sink) ->
            {"again, there is nothing up my sleeve",
                fun() ->
                        ?assertEqual(undefined, pop(Sink)),
                        ?assertEqual(0, count(Sink))
                end
            }
        end,

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
        TestBody("noproc_proc_lib",noproc_proc_lib,"gen_server crash terminated with reason: no such process or port in call to proc_lib:stop/3"),
        TestBody("badfun",badfun,"gen_server crash terminated with reason: bad function booger in crash:handle_call/3")
    ],
    {"Error logger redirect crash", [
        {"Redirect to default sink",
            {foreach,
            fun error_logger_redirect_crash_setup/0,
            fun error_logger_redirect_crash_cleanup/1,
            Tests}},
        {"Redirect to error_logger_lager_event sink",
            {foreach,
            fun error_logger_redirect_crash_setup_sink/0,
            fun error_logger_redirect_crash_cleanup/1,
            Tests}}
    ]}.


error_logger_redirect_setup() ->
    error_logger:tty(false),
    application:load(lager),
    application:set_env(lager, error_logger_redirect, true),
    application:set_env(lager, handlers, [{?MODULE, info}]),
    application:set_env(lager, suppress_supervisor_start_stop, false),
    application:set_env(lager, suppress_application_start_stop, false),
    lager:start(),
    lager:log(error, self(), "flush flush"),
    timer:sleep(1000),
    gen_event:call(lager_event, ?MODULE, flush),
    lager_event.

error_logger_redirect_setup_sink() ->
    error_logger:tty(false),
    application:load(lager),
    application:set_env(lager, error_logger_redirect, true),
    application:unset_env(lager, handlers),
    application:set_env(lager, extra_sinks, [
        {error_logger_lager_event, [
            {handlers, [{?MODULE, info}]}]}]),
    application:set_env(lager, suppress_supervisor_start_stop, false),
    application:set_env(lager, suppress_application_start_stop, false),
    lager:start(),
    lager:log(error_logger_lager_event, error, self(), "flush flush", []),
    timer:sleep(1000),
    gen_event:call(error_logger_lager_event, ?MODULE, flush),
    error_logger_lager_event.

error_logger_redirect_cleanup(_) ->
    application:stop(lager),
    application:stop(goldrush),
    application:unset_env(lager, extra_sinks),
    error_logger:tty(true).

error_logger_redirect_test_() ->
    Tests = [
            {"error reports are printed",
                fun(Sink) ->
                        sync_error_logger:error_report([{this, is}, a, {silly, format}]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(error),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        Expected = "this: is, a, silly: format",
                        ?assertEqual(Expected, lists:flatten(Msg))

                end
            },
            {"string error reports are printed",
                fun(Sink) ->
                        sync_error_logger:error_report("this is less silly"),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(error),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        Expected = "this is less silly",
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"error messages are printed",
                fun(Sink) ->
                        sync_error_logger:error_msg("doom, doom has come upon you all"),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(error),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        Expected = "doom, doom has come upon you all",
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"error messages with unicode characters in Args are printed",
                fun(Sink) ->
                        sync_error_logger:error_msg("~ts", ["Привет!"]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(error),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("Привет!", lists:flatten(Msg))
                end
            },
            {"error messages are truncated at 4096 characters",
                fun(Sink) ->
                        sync_error_logger:error_msg("doom, doom has come upon you all ~p", [string:copies("doom", 10000)]),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg,_Metadata} = pop(Sink),
                        ?assert(length(lists:flatten(Msg)) < 5100)
                end
            },

            {"info reports are printed",
                fun(Sink) ->
                        sync_error_logger:info_report([{this, is}, a, {silly, format}]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(info),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        Expected = "this: is, a, silly: format",
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"info reports are truncated at 4096 characters",
                fun(Sink) ->
                        sync_error_logger:info_report([[{this, is}, a, {silly, format}] || _ <- lists:seq(0, 600)]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(info),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assert(length(lists:flatten(Msg)) < 5000)
                end
            },
            {"single term info reports are printed",
                fun(Sink) ->
                        sync_error_logger:info_report({foolish, bees}),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(info),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("{foolish,bees}", lists:flatten(Msg))
                end
            },
            {"single term error reports are printed",
                fun(Sink) ->
                        sync_error_logger:error_report({foolish, bees}),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(error),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("{foolish,bees}", lists:flatten(Msg))
                end
            },
            {"string info reports are printed",
                fun(Sink) ->
                        sync_error_logger:info_report("this is less silly"),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(info),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("this is less silly", lists:flatten(Msg))
                end
            },
            {"string info reports are truncated at 4096 characters",
                fun(Sink) ->
                        sync_error_logger:info_report(string:copies("this is less silly", 1000)),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(info),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assert(length(lists:flatten(Msg)) < 5100)
                end
            },
            {"strings in a mixed report are printed as strings",
                fun(Sink) ->
                        sync_error_logger:info_report(["this is less silly", {than, "this"}]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(info),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("\"this is less silly\", than: \"this\"", lists:flatten(Msg))
                end
            },
            {"info messages are printed",
                fun(Sink) ->
                        sync_error_logger:info_msg("doom, doom has come upon you all"),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(info),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("doom, doom has come upon you all", lists:flatten(Msg))
                end
            },
            {"info messages are truncated at 4096 characters",
                fun(Sink) ->
                        sync_error_logger:info_msg("doom, doom has come upon you all ~p", [string:copies("doom", 10000)]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(info),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assert(length(lists:flatten(Msg)) < 5100)
                end
            },
            {"info messages with unicode characters in Args are printed",
                fun(Sink) ->
                        sync_error_logger:info_msg("~ts", ["Привет!"]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(info),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("Привет!", lists:flatten(Msg))
                end
            },
            {"warning messages with unicode characters in Args are printed",
             %% The next 4 tests need to store the current value of
             %% `error_logger:warning_map/0' into a process dictionary
             %% key `warning_map' so that the error message level used
             %% to process the log messages will match what lager
             %% expects.
             %%
             %% The atom returned by `error_logger:warning_map/0'
             %% changed between OTP 17 and 18 (and later releases)
             %%
             %% `warning_map' is consumed in the `test/sync_error_logger.erl'
             %% module. The default message level used in sync_error_logger
             %% was fine for OTP releases through 17 and then broke
             %% when 18 was released. By storing the expected value
             %% in the process dictionary, sync_error_logger will
             %% use the correct message level to process the
             %% messages and these tests will no longer
             %% break.
                fun(Sink) ->
                        Lvl = error_logger:warning_map(),
                        put(warning_map, Lvl),
                        sync_error_logger:warning_msg("~ts", ["Привет!"]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(Lvl),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("Привет!", lists:flatten(Msg))
                end
            },
            {"warning messages are printed at the correct level",
                fun(Sink) ->
                        Lvl = error_logger:warning_map(),
                        put(warning_map, Lvl),
                        sync_error_logger:warning_msg("doom, doom has come upon you all"),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(Lvl),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("doom, doom has come upon you all", lists:flatten(Msg))
                end
            },
            {"warning reports are printed at the correct level",
                fun(Sink) ->
                        Lvl = error_logger:warning_map(),
                        put(warning_map, Lvl),
                        sync_error_logger:warning_report([{i, like}, pie]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(Lvl),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("i: like, pie", lists:flatten(Msg))
                end
            },
            {"single term warning reports are printed at the correct level",
                fun(Sink) ->
                        Lvl = error_logger:warning_map(),
                        put(warning_map, Lvl),
                        sync_error_logger:warning_report({foolish, bees}),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(Lvl),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("{foolish,bees}", lists:flatten(Msg))
                end
            },
            {"application stop reports",
                fun(Sink) ->
                        sync_error_logger:info_report([{application, foo}, {exited, quittin_time}, {type, lazy}]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(info),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("Application foo exited with reason: quittin_time", lists:flatten(Msg))
                end
            },
            {"supervisor reports",
                fun(Sink) ->
                        sync_error_logger:error_report(supervisor_report, [{errorContext, france}, {offender, [{name, mini_steve}, {mfargs, {a, b, [c]}}, {pid, bleh}]}, {reason, fired}, {supervisor, {local, steve}}]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(error),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("Supervisor steve had child mini_steve started with a:b(c) at bleh exit with reason fired in context france", lists:flatten(Msg))
                end
            },
            {"supervisor reports with real error",
                fun(Sink) ->
                        sync_error_logger:error_report(supervisor_report, [{errorContext, france}, {offender, [{name, mini_steve}, {mfargs, {a, b, [c]}}, {pid, bleh}]}, {reason, {function_clause,[{crash,handle_info,[foo]}]}}, {supervisor, {local, steve}}]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(error),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("Supervisor steve had child mini_steve started with a:b(c) at bleh exit with reason no function clause matching crash:handle_info(foo) in context france", lists:flatten(Msg))
                end
            },

            {"supervisor reports with real error and pid",
                fun(Sink) ->
                        sync_error_logger:error_report(supervisor_report, [{errorContext, france}, {offender, [{name, mini_steve}, {mfargs, {a, b, [c]}}, {pid, bleh}]}, {reason, {function_clause,[{crash,handle_info,[foo]}]}}, {supervisor, somepid}]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(error),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("Supervisor somepid had child mini_steve started with a:b(c) at bleh exit with reason no function clause matching crash:handle_info(foo) in context france", lists:flatten(Msg))
                end
            },

            {"supervisor_bridge reports",
                fun(Sink) ->
                        sync_error_logger:error_report(supervisor_report, [{errorContext, france}, {offender, [{mod, mini_steve}, {pid, bleh}]}, {reason, fired}, {supervisor, {local, steve}}]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(error),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("Supervisor steve had child at module mini_steve at bleh exit with reason fired in context france", lists:flatten(Msg))
                end
            },
            {"application progress report",
                fun(Sink) ->
                        sync_error_logger:info_report(progress, [{application, foo}, {started_at, node()}]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(info),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        Expected = lists:flatten(io_lib:format("Application foo started on node ~w", [node()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"supervisor progress report",
                fun(Sink) ->
                        lager:set_loglevel(Sink, ?MODULE, undefined, debug),
                        ?assertEqual({?DEBUG bor ?INFO bor ?NOTICE bor ?WARNING bor ?ERROR bor ?CRITICAL bor ?ALERT bor ?EMERGENCY, []}, lager_config:get({Sink, loglevel})),
                        sync_error_logger:info_report(progress, [{supervisor, {local, foo}}, {started, [{mfargs, {foo, bar, 1}}, {pid, baz}]}]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(debug),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("Supervisor foo started foo:bar/1 at pid baz", lists:flatten(Msg))
                end
            },
            {"supervisor progress report with pid",
                fun(Sink) ->
                        lager:set_loglevel(Sink, ?MODULE, undefined, debug),
                        ?assertEqual({?DEBUG bor ?INFO bor ?NOTICE bor ?WARNING bor ?ERROR bor ?CRITICAL bor ?ALERT bor ?EMERGENCY, []}, lager_config:get({Sink, loglevel})),
                        sync_error_logger:info_report(progress, [{supervisor, somepid}, {started, [{mfargs, {foo, bar, 1}}, {pid, baz}]}]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(debug),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("Supervisor somepid started foo:bar/1 at pid baz", lists:flatten(Msg))
                end
            },
            {"crash report for emfile",
                fun(Sink) ->
                        sync_error_logger:error_report(crash_report, [[{pid, self()}, {registered_name, []}, {error_info, {error, emfile, [{stack, trace, 1}]}}], []]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(error),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        Expected = lists:flatten(io_lib:format("CRASH REPORT Process ~w with 0 neighbours crashed with reason: maximum number of file descriptors exhausted, check ulimit -n", [self()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"crash report for system process limit",
                fun(Sink) ->
                        sync_error_logger:error_report(crash_report, [[{pid, self()}, {registered_name, []}, {error_info, {error, system_limit, [{erlang, spawn, 1}]}}], []]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(error),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        Expected = lists:flatten(io_lib:format("CRASH REPORT Process ~w with 0 neighbours crashed with reason: system limit: maximum number of processes exceeded", [self()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"crash report for system process limit2",
                fun(Sink) ->
                        sync_error_logger:error_report(crash_report, [[{pid, self()}, {registered_name, []}, {error_info, {error, system_limit, [{erlang, spawn_opt, 1}]}}], []]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(error),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        Expected = lists:flatten(io_lib:format("CRASH REPORT Process ~w with 0 neighbours crashed with reason: system limit: maximum number of processes exceeded", [self()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"crash report for system port limit",
                fun(Sink) ->
                        sync_error_logger:error_report(crash_report, [[{pid, self()}, {registered_name, []}, {error_info, {error, system_limit, [{erlang, open_port, 1}]}}], []]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(error),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        Expected = lists:flatten(io_lib:format("CRASH REPORT Process ~w with 0 neighbours crashed with reason: system limit: maximum number of ports exceeded", [self()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"crash report for system port limit",
                fun(Sink) ->
                        sync_error_logger:error_report(crash_report, [[{pid, self()}, {registered_name, []}, {error_info, {error, system_limit, [{erlang, list_to_atom, 1}]}}], []]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(error),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        Expected = lists:flatten(io_lib:format("CRASH REPORT Process ~w with 0 neighbours crashed with reason: system limit: tried to create an atom larger than 255, or maximum atom count exceeded", [self()])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"crash report for system ets table limit",
                fun(Sink) ->
                        sync_error_logger:error_report(crash_report, [[{pid, self()}, {registered_name, test}, {error_info, {error, system_limit, [{ets,new,[segment_offsets,[ordered_set,public]]},{mi_segment,open_write,1},{mi_buffer_converter,handle_cast,2},{gen_server,handle_msg,5},{proc_lib,init_p_do_apply,3}]}}], []]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(error),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        Expected = lists:flatten(io_lib:format("CRASH REPORT Process ~w with 0 neighbours crashed with reason: system limit: maximum number of ETS tables exceeded", [test])),
                        ?assertEqual(Expected, lists:flatten(Msg))
                end
            },
            {"crash report for unknown system limit should be truncated at 500 characters",
                fun(Sink) ->
                        sync_error_logger:error_report(crash_report, [[{pid, self()}, {error_info, {error, system_limit, [{wtf,boom,[string:copies("aaaa", 4096)]}]}}], []]),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg,_Metadata} = pop(Sink),
                        ?assert(length(lists:flatten(Msg)) > 550),
                        ?assert(length(lists:flatten(Msg)) < 600)
                end
            },
            {"crash reports for 'special processes' should be handled right - function_clause",
                fun(Sink) ->
                        {ok, Pid} = special_process:start(),
                        unlink(Pid),
                        Pid ! function_clause,
                        timer:sleep(500),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg, _Metadata} = pop(Sink),
                        Expected = lists:flatten(io_lib:format("CRASH REPORT Process ~p with 0 neighbours crashed with reason: no function clause matching special_process:foo(bar)",
                                [Pid])),
                        test_body(Expected, lists:flatten(Msg))
                end
            },
            {"crash reports for 'special processes' should be handled right - case_clause",
                fun(Sink) ->
                        {ok, Pid} = special_process:start(),
                        unlink(Pid),
                        Pid ! {case_clause, wtf},
                        timer:sleep(500),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg, _Metadata} = pop(Sink),
                        Expected = lists:flatten(io_lib:format("CRASH REPORT Process ~p with 0 neighbours crashed with reason: no case clause matching wtf in special_process:loop/0",
                                [Pid])),
                        test_body(Expected, lists:flatten(Msg))
                end
            },
            {"crash reports for 'special processes' should be handled right - exit",
                fun(Sink) ->
                        {ok, Pid} = special_process:start(),
                        unlink(Pid),
                        Pid ! exit,
                        timer:sleep(500),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg, _Metadata} = pop(Sink),
                        Expected = lists:flatten(io_lib:format("CRASH REPORT Process ~p with 0 neighbours exited with reason: byebye in special_process:loop/0",
                                [Pid])),
                        test_body(Expected, lists:flatten(Msg))
                end
            },
            {"crash reports for 'special processes' should be handled right - error",
                fun(Sink) ->
                        {ok, Pid} = special_process:start(),
                        unlink(Pid),
                        Pid ! error,
                        timer:sleep(500),
                        _ = gen_event:which_handlers(error_logger),
                        {_, _, Msg, _Metadata} = pop(Sink),
                        Expected = lists:flatten(io_lib:format("CRASH REPORT Process ~p with 0 neighbours crashed with reason: mybad in special_process:loop/0",
                                [Pid])),
                        test_body(Expected, lists:flatten(Msg))
                end
            },
            {"webmachine error reports",
                fun(Sink) ->
                        Path = "/cgi-bin/phpmyadmin",
                        Reason = {error,{error,{badmatch,{error,timeout}},
                                        [{myapp,dostuff,2,[{file,"src/myapp.erl"},{line,123}]},
                                         {webmachine_resource,resource_call,3,[{file,"src/webmachine_resource.erl"},{line,169}]}]}},
                        sync_error_logger:error_msg("webmachine error: path=~p~n~p~n", [Path, Reason]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(error),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("Webmachine error at path \"/cgi-bin/phpmyadmin\" : no match of right hand value {error,timeout} in myapp:dostuff/2 line 123", lists:flatten(Msg))

                end
            },
            {"Cowboy error reports, 8 arg version",
             fun(Sink) ->
                        Stack = [{my_handler,init, 3,[{file,"src/my_handler.erl"},{line,123}]},
                                 {cowboy_handler,handler_init,4,[{file,"src/cowboy_handler.erl"},{line,169}]}],

                        sync_error_logger:error_msg(
                            "** Cowboy handler ~p terminating in ~p/~p~n"
                            "   for the reason ~p:~p~n"
                            "** Options were ~p~n"
                            "** Request was ~p~n"
                            "** Stacktrace: ~p~n~n",
                            [my_handler, init, 3, error, {badmatch, {error, timeout}}, [],
                             "Request", Stack]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(error),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("Cowboy handler my_handler terminated in my_handler:init/3 with reason: no match of right hand value {error,timeout} in my_handler:init/3 line 123", lists:flatten(Msg))
                end
            },
            {"Cowboy error reports, 10 arg version",
             fun(Sink) ->
                        Stack = [{my_handler,somecallback, 3,[{file,"src/my_handler.erl"},{line,123}]},
                                 {cowboy_handler,handler_init,4,[{file,"src/cowboy_handler.erl"},{line,169}]}],
                        sync_error_logger:error_msg(
                            "** Cowboy handler ~p terminating in ~p/~p~n"
                            "   for the reason ~p:~p~n** Message was ~p~n"
                            "** Options were ~p~n** Handler state was ~p~n"
                            "** Request was ~p~n** Stacktrace: ~p~n~n",
                            [my_handler, somecallback, 3, error, {badmatch, {error, timeout}}, hello, [],
                             {}, "Request", Stack]),

                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(error),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("Cowboy handler my_handler terminated in my_handler:somecallback/3 with reason: no match of right hand value {error,timeout} in my_handler:somecallback/3 line 123", lists:flatten(Msg))
                end
            },
            {"Cowboy error reports, 5 arg version",
             fun(Sink) ->
                        sync_error_logger:error_msg(
                            "** Cowboy handler ~p terminating; "
                            "function ~p/~p was not exported~n"
                            "** Request was ~p~n** State was ~p~n~n",
                            [my_handler, to_json, 2, "Request", {}]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg,Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(error),Level),
                        ?assertEqual(self(),proplists:get_value(pid,Metadata)),
                        ?assertEqual("Cowboy handler my_handler terminated with reason: call to undefined function my_handler:to_json/2", lists:flatten(Msg))
                end
            },
            {"Cowboy error reports, 6 arg version",
             fun(Sink) ->
                        Stack = [{app_http, init, 2, [{file, "app_http.erl"}, {line,9}]},
                                 {cowboy_handler, execute, 2, [{file, "cowboy_handler.erl"}, {line, 41}]}],
                        ConnectionPid = list_to_pid("<0.82.0>"),
                        sync_error_logger:error_msg(
                            "Ranch listener ~p, connection process ~p, stream ~p "
                            "had its request process ~p exit with reason "
                            "~999999p and stacktrace ~999999p~n",
                            [my_listner, ConnectionPid, 1, self(), {badmatch, 2}, Stack]),
                        _ = gen_event:which_handlers(error_logger),
                        {Level, _, Msg, Metadata} = pop(Sink),
                        ?assertEqual(lager_util:level_to_num(error), Level),
                        ?assertEqual(self(), proplists:get_value(pid, Metadata)),
                        ?assertEqual("Cowboy stream 1 with ranch listener my_listner and "
                                     "connection process <0.82.0> had its request process exit "
                                     "with reason: no match of right hand value 2 "
                                     "in app_http:init/2 line 9", lists:flatten(Msg))
                end
            },
            {"messages should not be generated if they don't satisfy the threshold",
                fun(Sink) ->
                        lager:set_loglevel(Sink, ?MODULE, undefined, error),
                        ?assertEqual({?ERROR bor ?CRITICAL bor ?ALERT bor ?EMERGENCY, []}, lager_config:get({Sink, loglevel})),
                        sync_error_logger:info_report([hello, world]),
                        _ = gen_event:which_handlers(error_logger),
                        ?assertEqual(0, count(Sink)),
                        ?assertEqual(0, count_ignored(Sink)),
                        lager:set_loglevel(Sink, ?MODULE, undefined, info),
                        ?assertEqual({?INFO bor ?NOTICE bor ?WARNING bor ?ERROR bor ?CRITICAL bor ?ALERT bor ?EMERGENCY, []}, lager_config:get({Sink, loglevel})),
                        sync_error_logger:info_report([hello, world]),
                        _ = gen_event:which_handlers(error_logger),
                        ?assertEqual(1, count(Sink)),
                        ?assertEqual(0, count_ignored(Sink)),
                        lager:set_loglevel(Sink, ?MODULE, undefined, error),
                        ?assertEqual({?ERROR bor ?CRITICAL bor ?ALERT bor ?EMERGENCY, []}, lager_config:get({Sink, loglevel})),
                        lager_config:set({Sink, loglevel}, {element(2, lager_util:config_to_mask(debug)), []}),
                        sync_error_logger:info_report([hello, world]),
                        _ = gen_event:which_handlers(error_logger),
                        ?assertEqual(1, count(Sink)),
                        ?assertEqual(1, count_ignored(Sink))
                end
            }
        ],
    SinkTests = lists:map(
        fun({Name, F}) ->
            fun(Sink) -> {Name, fun() -> F(Sink) end} end
        end,
        Tests),
    {"Error logger redirect", [
        {"Redirect to default sink",
            {foreach,
            fun error_logger_redirect_setup/0,
            fun error_logger_redirect_cleanup/1,
            SinkTests}},
        {"Redirect to error_logger_lager_event sink",
            {foreach,
            fun error_logger_redirect_setup_sink/0,
            fun error_logger_redirect_cleanup/1,
            SinkTests}}
    ]}.

safe_format_test() ->
    ?assertEqual("foo bar", lists:flatten(lager:safe_format("~p ~p", [foo, bar], 1024))),
    ?assertEqual("FORMAT ERROR: \"~p ~p ~p\" [foo,bar]", lists:flatten(lager:safe_format("~p ~p ~p", [foo, bar], 1024))),
    ok.

unsafe_format_test() ->
    ?assertEqual("foo bar", lists:flatten(lager:unsafe_format("~p ~p", [foo, bar]))),
    ?assertEqual("FORMAT ERROR: \"~p ~p ~p\" [foo,bar]", lists:flatten(lager:unsafe_format("~p ~p ~p", [foo, bar]))),
    ok.

async_threshold_test_() ->
    Cleanup = fun(Reset) ->
        _ = error_logger:tty(false),
        _ = application:stop(lager),
        _ = application:stop(goldrush),
        _ = application:unset_env(lager, async_threshold),
        if
            Reset ->
                true = ets:delete(async_threshold_test),
                error_logger:tty(true);
            true ->
                _ = (catch ets:delete(async_threshold_test)),
                ok
        end
    end,
    Setup = fun() ->
        % Evidence suggests that previous tests somewhere are leaving some of this stuff
        % loaded, and cleaning it out forcefully to allows the test to succeed.
        _ = Cleanup(false),
        _ = ets:new(async_threshold_test, [set, named_table, public]),
        ?assertEqual(true, ets:insert_new(async_threshold_test, {sync_toggled, 0})),
        ?assertEqual(true, ets:insert_new(async_threshold_test, {async_toggled, 0})),
        _ = application:load(lager),
        ok = application:set_env(lager, error_logger_redirect, false),
        ok = application:set_env(lager, async_threshold, 2),
        ok = application:set_env(lager, async_threshold_window, 1),
        ok = application:set_env(lager, handlers, [{?MODULE, info}]),
        ok = lager:start(),
        true
    end,
    {foreach, Setup, Cleanup, [
        {"async threshold works",
         {timeout, 30, fun() ->
            Sleep = get_long_sleep_value(),

            %% we start out async
            ?assertEqual(true, lager_config:get(async)),
            ?assertEqual([{sync_toggled, 0}],
                ets:lookup(async_threshold_test, sync_toggled)),

            %% put a ton of things in the queue
            WorkCnt = erlang:max(10, (erlang:system_info(schedulers) * 2)),
            OtpVsn  = lager_util:otp_version(),
            % newer OTPs *may* handle the messages faster, so we'll send more
            MsgCnt  = ((OtpVsn * OtpVsn) div 2),
            Workers = spawn_stuffers(WorkCnt, [MsgCnt, info, "hello world"], []),

            %% serialize on mailbox
            _ = gen_event:which_handlers(lager_event),
            timer:sleep(Sleep),

            %% By now the flood of messages should have forced the backend throttle
            %% to turn off async mode, but it's possible all outstanding requests
            %% have been processed, so checking the current status (sync or async)
            %% is an exercise in race control.
            %% Instead, we'll see whether the backend throttle has toggled into sync
            %% mode at any point in the past.
            ?assertMatch([{sync_toggled, N}] when N > 0,
                ets:lookup(async_threshold_test, sync_toggled)),

            %% Wait for all the workers to return, meaning that all the messages have
            %% been logged (since we're definitely in sync mode at the end of the run).
            collect_workers(Workers),

            %% serialize on the mailbox again
            _ = gen_event:which_handlers(lager_event),
            timer:sleep(Sleep),

            lager:info("hello world"),

            _ = gen_event:which_handlers(lager_event),
            timer:sleep(Sleep),

            %% async is true again now that the mailbox has drained
            ?assertEqual(true, lager_config:get(async)),
            ok
        end}}
    ]}.

% Fire off the stuffers with minimal resource overhead - speed is of the essence.
spawn_stuffers(0, _, Refs) ->
    % Attempt to return them in about the order that they'll finish.
    lists:reverse(Refs);
spawn_stuffers(N, Args, Refs) ->
    {_Pid, Ref} = erlang:spawn_monitor(?MODULE, message_stuffer, Args),
    spawn_stuffers((N - 1), Args, [Ref | Refs]).

% Spawned process to stuff N copies of Message into lager's message queue as fast as possible.
% Skip using a list function for speed and low memory footprint - don't want to take the
% resources to create a sequence (or pass one in).
message_stuffer(N, Level, Message) ->
    message_stuffer_(N, Level, [{pid, erlang:self()}], Message).

message_stuffer_(0, _, _, _) ->
    ok;
message_stuffer_(N, Level, Meta, Message) ->
    lager:log(Level, Meta, Message),
    message_stuffer_((N - 1), Level, Meta, Message).

collect_workers([]) ->
    ok;
collect_workers([Ref | Refs]) ->
    receive
        {'DOWN', Ref, _, _, _} ->
            collect_workers(Refs)
    end.

produce_n_error_logger_msgs(N) ->
    lists:foreach(fun (K) ->
            error_logger:error_msg("Foo ~p!", [K])
        end,
        lists:seq(0, N-1)
    ).

high_watermark_test_() ->
    {foreach,
        fun() ->
            error_logger:tty(false),
            application:load(lager),
            application:set_env(lager, error_logger_redirect, true),
            application:set_env(lager, handlers, [{lager_test_backend, info}]),
            application:set_env(lager, async_threshold, undefined),
            lager:start()
        end,
        fun(_) ->
            application:stop(lager),
            error_logger:tty(true)
        end,
        [
            {"Nothing dropped when error_logger high watermark is undefined",
                fun () ->
                    ok = error_logger_lager_h:set_high_water(undefined),
                    timer:sleep(100),
                    produce_n_error_logger_msgs(10),
                    timer:sleep(500),
                    ?assert(count() >= 10)
                end
            },
            {"Mostly dropped according to error_logger high watermark",
                fun () ->
                    ok = error_logger_lager_h:set_high_water(5),
                    timer:sleep(100),
                    produce_n_error_logger_msgs(50),
                    timer:sleep(1000),
                    ?assert(count() < 20)
                end
            },
            {"Non-notifications are not dropped",
                fun () ->
                    ok = error_logger_lager_h:set_high_water(2),
                    timer:sleep(100),
                    spawn(fun () -> produce_n_error_logger_msgs(300) end),
                    timer:sleep(50),
                    %% if everything were dropped, this call would be dropped
                    %% too, so lets hope it's not
                    ?assert(is_integer(count())),
                    timer:sleep(1000),
                    ?assert(count() < 10)
                end
            }
        ]
    }.

get_long_sleep_value() ->
    case os:getenv("CI") of
        false ->
            500;
        _ ->
            5000
    end.

-endif.
