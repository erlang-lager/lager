%% Copyright (c) 2011-2015 Basho Technologies, Inc.  All Rights Reserved.
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

%% @doc A error_logger backend for redirecting events into lager.
%% Error messages and crash logs are also optionally written to a crash log.

%% @see lager_crash_log

%% @private

-module(error_logger_lager_h).

-include("lager.hrl").

-behaviour(gen_event).

-export([set_high_water/1]).
-export([init/1, handle_call/2, handle_event/2, handle_info/2, terminate/2,
        code_change/3]).

-export([format_reason/1, format_mfa/1, format_args/3]).

-record(state, { 
        sink :: atom(),
        shaper :: lager_shaper(),
        %% group leader strategy
        groupleader_strategy :: handle | ignore | mirror,
        raw :: boolean()
    }).

-define(LOGMSG(Sink, Level, Pid, Msg),
    case ?SHOULD_LOG(Sink, Level) of
        true ->
            _ =lager:log(Sink, Level, Pid, Msg, []),
            ok;
        _ -> ok
    end).

-define(LOGFMT(Sink, Level, Pid, Fmt, Args),
    case ?SHOULD_LOG(Sink, Level) of
        true ->
            _ = lager:log(Sink, Level, Pid, Fmt, Args),
            ok;
        _ -> ok
    end).

-ifdef(TEST).
-compile(export_all).
%% Make CRASH synchronous when testing, to avoid timing headaches
-define(CRASH_LOG(Event),
    catch(gen_server:call(lager_crash_log, {log, Event}))).
-else.
-define(CRASH_LOG(Event),
    gen_server:cast(lager_crash_log, {log, Event})).
-endif.

set_high_water(N) ->
    gen_event:call(error_logger, ?MODULE, {set_high_water, N}, infinity).

-spec init(any()) -> {ok, #state{}}.
init([HighWaterMark, GlStrategy]) ->
    Shaper = #lager_shaper{hwm=HighWaterMark},
    Raw = lager_app:get_env(lager, error_logger_format_raw, false),
    Sink = configured_sink(),
    {ok, #state{sink=Sink, shaper=Shaper, groupleader_strategy=GlStrategy, raw=Raw}}.

handle_call({set_high_water, N}, #state{shaper=Shaper} = State) ->
    NewShaper = Shaper#lager_shaper{hwm=N},
    {ok, ok, State#state{shaper = NewShaper}};
handle_call(_Request, State) ->
    {ok, unknown_call, State}.

handle_event(Event, #state{sink=Sink, shaper=Shaper} = State) ->
    case lager_util:check_hwm(Shaper) of
        {true, 0, NewShaper} ->
            eval_gl(Event, State#state{shaper=NewShaper});
        {true, Drop, #lager_shaper{hwm=Hwm} = NewShaper} when Drop > 0 ->
            ?LOGFMT(Sink, warning, self(), 
                "lager_error_logger_h dropped ~p messages in the last second that exceeded the limit of ~p messages/sec", 
                [Drop, Hwm]),
            eval_gl(Event, State#state{shaper=NewShaper});
        {false, _, NewShaper} ->
            {ok, State#state{shaper=NewShaper}}
    end.

handle_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.


code_change(_OldVsn, {state, Shaper, GLStrategy}, _Extra) ->
    Raw = lager_app:get_env(lager, error_logger_format_raw, false),
    {ok, #state{
        sink=configured_sink(), 
        shaper=Shaper, 
        groupleader_strategy=GLStrategy, 
        raw=Raw
        }};
code_change(_OldVsn, {state, Sink, Shaper, GLS}, _Extra) ->
    Raw = lager_app:get_env(lager, error_logger_format_raw, false),
    {ok, #state{sink=Sink, shaper=Shaper, groupleader_strategy=GLS, raw=Raw}};
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% internal functions

configured_sink() ->
    case proplists:get_value(?ERROR_LOGGER_SINK, lager_app:get_env(lager, extra_sinks, [])) of
        undefined -> ?DEFAULT_SINK;
        _ -> ?ERROR_LOGGER_SINK
    end.

eval_gl(Event, #state{groupleader_strategy=GlStrategy0}=State) when is_pid(element(2, Event)) ->
    case element(2, Event) of
         GL when node(GL) =/= node(), GlStrategy0 =:= ignore ->
            gen_event:notify({error_logger, node(GL)}, Event),
            {ok, State};
         GL when node(GL) =/= node(), GlStrategy0 =:= mirror ->
            gen_event:notify({error_logger, node(GL)}, Event),
            log_event(Event, State);
         _ ->
            log_event(Event, State)
    end;
eval_gl(Event, State) ->
    log_event(Event, State).

log_event(Event, #state{sink=Sink} = State) ->
    case Event of
        {error, _GL, {Pid, Fmt, Args}} ->
            FormatRaw = State#state.raw,
            case {FormatRaw, Fmt} of
                {false, "** Generic server "++_} ->
                    %% gen_server terminate
                    [Name, _Msg, _State, Reason] = Args,
                    ?CRASH_LOG(Event),
                    ?LOGFMT(Sink, error, Pid, "gen_server ~w terminated with reason: ~s",
                        [Name, format_reason(Reason)]);
                {false, "** State machine "++_} ->
                    %% gen_fsm terminate
                    [Name, _Msg, StateName, _StateData, Reason] = Args,
                    ?CRASH_LOG(Event),
                    ?LOGFMT(Sink, error, Pid, "gen_fsm ~w in state ~w terminated with reason: ~s",
                        [Name, StateName, format_reason(Reason)]);
                {false, "** gen_event handler"++_} ->
                    %% gen_event handler terminate
                    [ID, Name, _Msg, _State, Reason] = Args,
                    ?CRASH_LOG(Event),
                    ?LOGFMT(Sink, error, Pid, "gen_event ~w installed in ~w terminated with reason: ~s",
                        [ID, Name, format_reason(Reason)]);
                {false, "** Cowboy handler"++_} ->
                    %% Cowboy HTTP server error
                    ?CRASH_LOG(Event),
                    case Args of
                        [Module, Function, Arity, _Request, _State] ->
                            %% we only get the 5-element list when its a non-exported function
                            ?LOGFMT(Sink, error, Pid,
                                "Cowboy handler ~p terminated with reason: call to undefined function ~p:~p/~p",
                                [Module, Module, Function, Arity]);
                        [Module, Function, Arity, _Class, Reason | Tail] ->
                            %% any other cowboy error_format list *always* ends with the stacktrace
                            StackTrace = lists:last(Tail),
                            ?LOGFMT(Sink, error, Pid,
                                "Cowboy handler ~p terminated in ~p:~p/~p with reason: ~s",
                                [Module, Module, Function, Arity, format_reason({Reason, StackTrace})])
                    end;
                {false, "Ranch listener "++_} ->
                    %% Ranch errors
                    ?CRASH_LOG(Event),
                    case Args of
                        [Ref, _Protocol, Worker, {[{reason, Reason}, {mfa, {Module, Function, Arity}}, {stacktrace, StackTrace} | _], _}] ->
                            ?LOGFMT(Sink, error, Worker,
                                "Ranch listener ~p terminated in ~p:~p/~p with reason: ~s",
                                [Ref, Module, Function, Arity, format_reason({Reason, StackTrace})]);
                        [Ref, _Protocol, Worker, Reason] ->
                            ?LOGFMT(Sink, error, Worker,
                                "Ranch listener ~p terminated with reason: ~s",
                                [Ref, format_reason(Reason)])
                    end;
                {false, "webmachine error"++_} ->
                    %% Webmachine HTTP server error
                    ?CRASH_LOG(Event),
                    [Path, Error] = Args,
                    %% webmachine likes to mangle the stack, for some reason
                    StackTrace = case Error of
                        {error, {error, Reason, Stack}} ->
                            {Reason, Stack};
                        _ ->
                            Error
                    end,
                    ?LOGFMT(Sink, error, Pid, "Webmachine error at path ~p : ~s", [Path, format_reason(StackTrace)]);
                _ ->
                    ?CRASH_LOG(Event),
                    ?LOGFMT(Sink, error, Pid, Fmt, Args)
            end;
        {error_report, _GL, {Pid, std_error, D}} ->
            ?CRASH_LOG(Event),
            ?LOGMSG(Sink, error, Pid, print_silly_list(D));
        {error_report, _GL, {Pid, supervisor_report, D}} ->
            ?CRASH_LOG(Event),
            case lists:sort(D) of
                [{errorContext, Ctx}, {offender, Off}, {reason, Reason}, {supervisor, Name}] ->
                    Offender = format_offender(Off),
                    ?LOGFMT(Sink, error, Pid,
                        "Supervisor ~w had child ~s exit with reason ~s in context ~w",
                        [supervisor_name(Name), Offender, format_reason(Reason), Ctx]);
                _ ->
                    ?LOGMSG(Sink, error, Pid, "SUPERVISOR REPORT " ++ print_silly_list(D))
            end;
        {error_report, _GL, {Pid, crash_report, [Self, Neighbours]}} ->
            ?CRASH_LOG(Event),
            ?LOGMSG(Sink, error, Pid, "CRASH REPORT " ++ format_crash_report(Self, Neighbours));
        {warning_msg, _GL, {Pid, Fmt, Args}} ->
            ?LOGFMT(Sink, warning, Pid, Fmt, Args);
        {warning_report, _GL, {Pid, std_warning, Report}} ->
            ?LOGMSG(Sink, warning, Pid, print_silly_list(Report));
        {info_msg, _GL, {Pid, Fmt, Args}} ->
            ?LOGFMT(Sink, info, Pid, Fmt, Args);
        {info_report, _GL, {Pid, std_info, D}} when is_list(D) ->
            Details = lists:sort(D),
            case Details of
                [{application, App}, {exited, Reason}, {type, _Type}] ->
                    case application:get_env(lager, suppress_application_start_stop) of
                        {ok, true} when Reason == stopped ->
                            ok;
                        _ ->
                            ?LOGFMT(Sink, info, Pid, "Application ~w exited with reason: ~s",
                                    [App, format_reason(Reason)])
                    end;
                _ ->
                    ?LOGMSG(Sink, info, Pid, print_silly_list(D))
            end;
        {info_report, _GL, {Pid, std_info, D}} ->
            ?LOGFMT(Sink, info, Pid, "~w", [D]);
        {info_report, _GL, {P, progress, D}} ->
            Details = lists:sort(D),
            case Details of
                [{application, App}, {started_at, Node}] ->
                    case application:get_env(lager, suppress_application_start_stop) of
                        {ok, true} ->
                            ok;
                        _ ->
                            ?LOGFMT(Sink, info, P, "Application ~w started on node ~w",
                                    [App, Node])
                    end;
                [{started, Started}, {supervisor, Name}] ->
                    MFA = format_mfa(get_value(mfargs, Started)),
                    Pid = get_value(pid, Started),
                    ?LOGFMT(Sink, debug, P, "Supervisor ~w started ~s at pid ~w",
                        [supervisor_name(Name), MFA, Pid]);
                _ ->
                    ?LOGMSG(Sink, info, P, "PROGRESS REPORT " ++ print_silly_list(D))
            end;
        _ ->
            ?LOGFMT(Sink, warning, self(), "Unexpected error_logger event ~w", [Event])
    end,
    {ok, State}.

format_crash_report(Report, Neighbours) ->
    Name = case get_value(registered_name, Report, []) of
        [] ->
            %% process_info(Pid, registered_name) returns [] for unregistered processes
            get_value(pid, Report);
        Atom -> Atom
    end,
    {Class, Reason, Trace} = get_value(error_info, Report),
    ReasonStr = format_reason({Reason, Trace}),
    Type = case Class of
        exit -> "exited";
        _ -> "crashed"
    end,
    io_lib:format("Process ~w with ~w neighbours ~s with reason: ~s",
        [Name, length(Neighbours), Type, ReasonStr]).

format_offender(Off) ->
    case get_value(mfargs, Off) of
        undefined ->
            %% supervisor_bridge
            io_lib:format("at module ~w at ~w",
                [get_value(mod, Off), get_value(pid, Off)]);
        MFArgs ->
            %% regular supervisor
            MFA = format_mfa(MFArgs),

            %% In 2014 the error report changed from `name' to
            %% `id', so try that first.
            Name = case get_value(id, Off) of
                       undefined ->
                           get_value(name, Off);
                       Id ->
                           Id
                   end,
            io_lib:format("~p started with ~s at ~w",
                [Name, MFA, get_value(pid, Off)])
    end.

format_reason({'function not exported', [{M, F, A},MFA|_]}) ->
    ["call to undefined function ", format_mfa({M, F, length(A)}),
        " from ", format_mfa(MFA)];
format_reason({'function not exported', [{M, F, A, _Props},MFA|_]}) ->
    %% R15 line numbers
    ["call to undefined function ", format_mfa({M, F, length(A)}),
        " from ", format_mfa(MFA)];
format_reason({undef, [MFA|_]}) ->
    ["call to undefined function ", format_mfa(MFA)];
format_reason({bad_return, {_MFA, {'EXIT', Reason}}}) ->
    format_reason(Reason);
format_reason({bad_return, {MFA, Val}}) ->
    ["bad return value ", print_val(Val), " from ", format_mfa(MFA)];
format_reason({bad_return_value, Val}) ->
    ["bad return value: ", print_val(Val)];
format_reason({{bad_return_value, Val}, MFA}) ->
    ["bad return value: ", print_val(Val), " in ", format_mfa(MFA)];
format_reason({{badrecord, Record}, [MFA|_]}) ->
    ["bad record ", print_val(Record), " in ", format_mfa(MFA)];
format_reason({{case_clause, Val}, [MFA|_]}) ->
    ["no case clause matching ", print_val(Val), " in ", format_mfa(MFA)];
format_reason({function_clause, [MFA|_]}) ->
    ["no function clause matching ", format_mfa(MFA)];
format_reason({if_clause, [MFA|_]}) ->
    ["no true branch found while evaluating if expression in ", format_mfa(MFA)];
format_reason({{try_clause, Val}, [MFA|_]}) ->
    ["no try clause matching ", print_val(Val), " in ", format_mfa(MFA)];
format_reason({badarith, [MFA|_]}) ->
    ["bad arithmetic expression in ", format_mfa(MFA)];
format_reason({{badmatch, Val}, [MFA|_]}) ->
    ["no match of right hand value ", print_val(Val), " in ", format_mfa(MFA)];
format_reason({emfile, _Trace}) ->
    "maximum number of file descriptors exhausted, check ulimit -n";
format_reason({system_limit, [{M, F, _}|_] = Trace}) ->
    Limit = case {M, F} of
        {erlang, open_port} ->
            "maximum number of ports exceeded";
        {erlang, spawn} ->
            "maximum number of processes exceeded";
        {erlang, spawn_opt} ->
            "maximum number of processes exceeded";
        {erlang, list_to_atom} ->
            "tried to create an atom larger than 255, or maximum atom count exceeded";
        {ets, new} ->
            "maximum number of ETS tables exceeded";
        _ ->
            {Str, _} = lager_trunc_io:print(Trace, 500),
            Str
    end,
    ["system limit: ", Limit];
format_reason({badarg, [MFA,MFA2|_]}) ->
    case MFA of
        {_M, _F, A, _Props} when is_list(A) ->
            %% R15 line numbers
            ["bad argument in call to ", format_mfa(MFA), " in ", format_mfa(MFA2)];
        {_M, _F, A} when is_list(A) ->
            ["bad argument in call to ", format_mfa(MFA), " in ", format_mfa(MFA2)];
        _ ->
            %% seems to be generated by a bad call to a BIF
            ["bad argument in ", format_mfa(MFA)]
    end;
format_reason({{badarg, Stack}, _}) ->
    format_reason({badarg, Stack});
format_reason({{badarity, {Fun, Args}}, [MFA|_]}) ->
    {arity, Arity} = lists:keyfind(arity, 1, erlang:fun_info(Fun)),
    [io_lib:format("fun called with wrong arity of ~w instead of ~w in ",
            [length(Args), Arity]), format_mfa(MFA)];
format_reason({noproc, MFA}) ->
    ["no such process or port in call to ", format_mfa(MFA)];
format_reason({{badfun, Term}, [MFA|_]}) ->
    ["bad function ", print_val(Term), " in ", format_mfa(MFA)];
format_reason({Reason, [{M, F, A}|_]}) when is_atom(M), is_atom(F), is_integer(A) ->
    [format_reason(Reason), " in ", format_mfa({M, F, A})];
format_reason({Reason, [{M, F, A, Props}|_]}) when is_atom(M), is_atom(F), is_integer(A), is_list(Props) ->
    %% line numbers
    [format_reason(Reason), " in ", format_mfa({M, F, A, Props})];
format_reason(Reason) ->
    {Str, _} = lager_trunc_io:print(Reason, 500),
    Str.

format_mfa({M, F, A}) when is_list(A) ->
    {FmtStr, Args} = format_args(A, [], []),
    io_lib:format("~w:~w("++FmtStr++")", [M, F | Args]);
format_mfa({M, F, A}) when is_integer(A) ->
    io_lib:format("~w:~w/~w", [M, F, A]);
format_mfa({M, F, A, Props}) when is_list(Props) ->
    case get_value(line, Props) of
        undefined ->
            format_mfa({M, F, A});
        Line ->
            [format_mfa({M, F, A}), io_lib:format(" line ~w", [Line])]
    end;
format_mfa([{M, F, A}, _]) ->
   %% this kind of weird stacktrace can be generated by a uncaught throw in a gen_server
   format_mfa({M, F, A});
format_mfa([{M, F, A, Props}, _]) when is_list(Props) ->
   %% this kind of weird stacktrace can be generated by a uncaught throw in a gen_server
   format_mfa({M, F, A, Props});
format_mfa(Other) ->
    io_lib:format("~w", [Other]).

format_args([], FmtAcc, ArgsAcc) ->
    {string:join(lists:reverse(FmtAcc), ", "), lists:reverse(ArgsAcc)};
format_args([H|T], FmtAcc, ArgsAcc) ->
    {Str, _} = lager_trunc_io:print(H, 100),
    format_args(T, ["~s"|FmtAcc], [Str|ArgsAcc]).

print_silly_list(L) when is_list(L) ->
    case lager_stdlib:string_p(L) of
        true ->
            lager_trunc_io:format("~s", [L], ?DEFAULT_TRUNCATION);
        _ ->
            print_silly_list(L, [], [])
    end;
print_silly_list(L) ->
    {Str, _} = lager_trunc_io:print(L, ?DEFAULT_TRUNCATION),
    Str.

print_silly_list([], Fmt, Acc) ->
    lager_trunc_io:format(string:join(lists:reverse(Fmt), ", "),
        lists:reverse(Acc), ?DEFAULT_TRUNCATION);
print_silly_list([{K,V}|T], Fmt, Acc) ->
    print_silly_list(T, ["~p: ~p" | Fmt], [V, K | Acc]);
print_silly_list([H|T], Fmt, Acc) ->
    print_silly_list(T, ["~p" | Fmt], [H | Acc]).

print_val(Val) ->
    {Str, _} = lager_trunc_io:print(Val, 500),
    Str.


%% @doc Faster than proplists, but with the same API as long as you don't need to
%% handle bare atom keys
get_value(Key, Value) ->
    get_value(Key, Value, undefined).

get_value(Key, List, Default) ->
    case lists:keyfind(Key, 1, List) of
        false -> Default;
        {Key, Value} -> Value
    end.

supervisor_name({local, Name}) -> Name;
supervisor_name(Name) -> Name.
