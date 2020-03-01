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
            logged;
        _ -> no_log
    end).

-define(LOGFMT(Sink, Level, Pid, Fmt, Args),
    case ?SHOULD_LOG(Sink, Level) of
        true ->
            _ = lager:log(Sink, Level, Pid, Fmt, Args),
            logged;
        _ -> no_log
    end).

-ifdef(TEST).
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
    Flush = application:get_env(lager, error_logger_flush_queue, true),
    FlushThr = application:get_env(lager, error_logger_flush_threshold, 0),
    Shaper = #lager_shaper{hwm=HighWaterMark, flush_queue = Flush, flush_threshold = FlushThr, filter=shaper_fun(), id=?MODULE},
    Raw = application:get_env(lager, error_logger_format_raw, false),
    Sink = configured_sink(),
    {ok, #state{sink=Sink, shaper=Shaper, groupleader_strategy=GlStrategy, raw=Raw}}.

handle_call({set_high_water, N}, #state{shaper=Shaper} = State) ->
    NewShaper = Shaper#lager_shaper{hwm=N},
    {ok, ok, State#state{shaper = NewShaper}};
handle_call(_Request, State) ->
    {ok, unknown_call, State}.

shaper_fun() ->
    case {application:get_env(lager, suppress_supervisor_start_stop, false), application:get_env(lager, suppress_application_start_stop, false)} of
        {false, false} ->
            fun(_) -> false end;
        {true, true} ->
            fun suppress_supervisor_start_and_application_start/1;
        {false, true} ->
            fun suppress_application_start/1;
        {true, false} ->
            fun suppress_supervisor_start/1
    end.

suppress_supervisor_start_and_application_start(E) ->
    suppress_supervisor_start(E) orelse suppress_application_start(E).

suppress_application_start({info_report, _GL, {_Pid, std_info, D}}) when is_list(D) ->
    lists:member({exited, stopped}, D);
suppress_application_start({info_report, _GL, {_P, progress, D}}) ->
    lists:keymember(application, 1, D) andalso lists:keymember(started_at, 1, D);
suppress_application_start(_) ->
    false.

suppress_supervisor_start({info_report, _GL, {_P, progress, D}}) ->
    lists:keymember(started, 1, D) andalso lists:keymember(supervisor, 1, D);
suppress_supervisor_start(_) ->
    false.

handle_event(Event, #state{sink=Sink, shaper=Shaper} = State) ->
    case lager_util:check_hwm(Shaper, Event) of
        {true, 0, NewShaper} ->
            eval_gl(Event, State#state{shaper=NewShaper});
        {true, Drop, #lager_shaper{hwm=Hwm} = NewShaper} when Drop > 0 ->
            ?LOGFMT(Sink, warning, self(),
                "lager_error_logger_h dropped ~p messages in the last second that exceeded the limit of ~p messages/sec",
                [Drop, Hwm]),
            eval_gl(Event, State#state{shaper=NewShaper});
        {false, _, #lager_shaper{dropped=D} = NewShaper} ->
            {ok, State#state{shaper=NewShaper#lager_shaper{dropped=D+1}}}
    end.

handle_info({shaper_expired, ?MODULE}, #state{sink=Sink, shaper=Shaper} = State) ->
    case Shaper#lager_shaper.dropped of
        0 ->
            ok;
        Dropped ->
            ?LOGFMT(Sink, warning, self(),
                    "lager_error_logger_h dropped ~p messages in the last second that exceeded the limit of ~p messages/sec",
                    [Dropped, Shaper#lager_shaper.hwm])
    end,
    {ok, State#state{shaper=Shaper#lager_shaper{dropped=0, mps=0, lasttime=os:timestamp()}}};
handle_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.


code_change(_OldVsn, {state, Shaper, GLStrategy}, _Extra) ->
    Raw = application:get_env(lager, error_logger_format_raw, false),
    {ok, #state{
        sink=configured_sink(),
        shaper=Shaper,
        groupleader_strategy=GLStrategy,
        raw=Raw
        }};
code_change(_OldVsn, {state, Sink, Shaper, GLS}, _Extra) ->
    Raw = application:get_env(lager, error_logger_format_raw, false),
    {ok, #state{sink=Sink, shaper=Shaper, groupleader_strategy=GLS, raw=Raw}};
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% internal functions

configured_sink() ->
    case proplists:get_value(?ERROR_LOGGER_SINK, application:get_env(lager, extra_sinks, [])) of
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
    DidLog = case Event of
        {error, _GL, {Pid, Fmt, Args}} ->
            FormatRaw = State#state.raw,
            case {FormatRaw, Fmt} of
                {false, "** Generic server "++_} ->
                    %% gen_server terminate
                    {Reason, Name} = case Args of
                                         [N, _Msg, _State, R] ->
                                             {R, N};
                                         [N, _Msg, _State, R, _Client] ->
                                             %% OTP 20 crash reports where the client pid is dead don't include the stacktrace
                                             {R, N};
                                         [N, _Msg, _State, R, _Client, _Stacktrace] ->
                                             %% OTP 20 crash reports contain the pid of the client and stacktrace
                                             %% TODO do something with them
                                             {R, N}
                                     end,
                    ?CRASH_LOG(Event),
                    {Md, Formatted} = format_reason_md(Reason),
                    ?LOGFMT(Sink, error, [{pid, Pid}, {name, Name} | Md], "gen_server ~w terminated with reason: ~s",
                        [Name, Formatted]);
                {false, "** State machine "++_} ->
                    %% Check if the terminated process is gen_fsm or gen_statem
                    %% since they generate the same exit message
                    {Type, Name, StateName, Reason} = case Args of
                        [TName, _Msg, TStateName, _StateData, TReason] ->
                            {gen_fsm, TName, TStateName, TReason};
                        %% Handle changed logging in gen_fsm stdlib-3.9 (TPid, ClientArgs)
                        [TName, _Msg, TPid, TStateName, _StateData, TReason | _ClientArgs] when is_pid(TPid), is_atom(TStateName) ->
                            {gen_fsm, TName, TStateName, TReason};
                        %% Handle changed logging in gen_statem stdlib-3.9 (ClientArgs)
                        [TName, _Msg, {TStateName, _StateData}, _ExitType, TReason, _CallbackMode, Stacktrace | _ClientArgs] ->
                            {gen_statem, TName, TStateName, {TReason, Stacktrace}};
                        %% Handle changed logging in gen_statem stdlib-3.9 (ClientArgs)
                        [TName, {TStateName, _StateData}, _ExitType, TReason, _CallbackMode, Stacktrace | _ClientArgs] ->
                            {gen_statem, TName, TStateName, {TReason, Stacktrace}};
                        [TName, _Msg, [{TStateName, _StateData}], _ExitType, TReason, _CallbackMode, Stacktrace | _ClientArgs] ->
                            %% sometimes gen_statem wraps its statename/data in a list for some reason???
                            {gen_statem, TName, TStateName, {TReason, Stacktrace}}
                    end,
                    {Md, Formatted} = format_reason_md(Reason),
                    ?CRASH_LOG(Event),
                    ?LOGFMT(Sink, error, [{pid, Pid}, {name, Name} | Md], "~s ~w in state ~w terminated with reason: ~s",
                        [Type, Name, StateName, Formatted]);
                {false, "** gen_event handler"++_} ->
                    %% gen_event handler terminate
                    [ID, Name, _Msg, _State, Reason] = Args,
                    {Md, Formatted} = format_reason_md(Reason),
                    ?CRASH_LOG(Event),
                    ?LOGFMT(Sink, error, [{pid, Pid}, {name, Name} | Md], "gen_event ~w installed in ~w terminated with reason: ~s",
                        [ID, Name, Formatted]);
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
                            {Md, Formatted} = format_reason_md({Reason, StackTrace}),
                            ?LOGFMT(Sink, error, [{pid, Pid} | Md],
                                "Cowboy handler ~p terminated in ~p:~p/~p with reason: ~s",
                                [Module, Module, Function, Arity, Formatted])
                    end;
                {false, "Ranch listener "++_} ->
                    %% Ranch errors
                    ?CRASH_LOG(Event),
                    case Args of
                        %% Error logged by cowboy, which starts as ranch error
                        [Ref, ConnectionPid, StreamID, RequestPid, Reason, StackTrace] ->
                            {Md, Formatted} = format_reason_md({Reason, StackTrace}),
                            ?LOGFMT(Sink, error, [{pid, RequestPid} | Md],
                                "Cowboy stream ~p with ranch listener ~p and connection process ~p "
                                "had its request process exit with reason: ~s",
                                [StreamID, Ref, ConnectionPid, Formatted]);
                        [Ref, _Protocol, Worker, {[{reason, Reason}, {mfa, {Module, Function, Arity}}, {stacktrace, StackTrace} | _], _}] ->
                            {Md, Formatted} = format_reason_md({Reason, StackTrace}),
                            ?LOGFMT(Sink, error, [{pid, Worker} | Md],
                                "Ranch listener ~p terminated in ~p:~p/~p with reason: ~s",
                                [Ref, Module, Function, Arity, Formatted]);
                        [Ref, _Protocol, Worker, Reason] ->
                            {Md, Formatted} = format_reason_md(Reason),
                            ?LOGFMT(Sink, error, [{pid, Worker} | Md],
                                "Ranch listener ~p terminated with reason: ~s",
                                [Ref, Formatted]);
                        [Ref, Protocol, Ret] ->
                            %% ranch_conns_sup.erl module line 119-123 has three parameters error msg, log it.
                            {Md, Formatted} = format_reason_md(Ret),
                            ?LOGFMT(Sink, error, [{pid, Protocol} | Md],
                                "Ranch listener ~p terminated with result:~s",
                                [Ref, Formatted])
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
                    {Md, Formatted} = format_reason_md(StackTrace),
                    ?LOGFMT(Sink, error, [{pid, Pid} | Md], "Webmachine error at path ~p : ~s", [Path, Formatted]);
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
                    {Md, Formatted} = format_reason_md(Reason),
                    ?LOGFMT(Sink, error, [{pid, Pid} | Md],
                        "Supervisor ~w had child ~s exit with reason ~s in context ~w",
                        [supervisor_name(Name), Offender, Formatted, Ctx]);
                _ ->
                    ?LOGMSG(Sink, error, Pid, "SUPERVISOR REPORT " ++ print_silly_list(D))
            end;
        {error_report, _GL, {Pid, crash_report, [Self, Neighbours]}} ->
            ?CRASH_LOG(Event),
            {Md, Formatted} = format_crash_report(Self, Neighbours),
            ?LOGMSG(Sink, error, [{pid, Pid} | Md], "CRASH REPORT " ++ Formatted);
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
                    case application:get_env(lager, suppress_application_start_stop, false) of
                        true when Reason == stopped ->
                            no_log;
                        _ ->
                            {Md, Formatted} = format_reason_md(Reason),
                            ?LOGFMT(Sink, info, [{pid, Pid} | Md], "Application ~w exited with reason: ~s",
                                    [App, Formatted])
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
                    case application:get_env(lager, suppress_application_start_stop, false) of
                        true ->
                            no_log;
                        _ ->
                            ?LOGFMT(Sink, info, P, "Application ~w started on node ~w",
                                    [App, Node])
                    end;
                [{started, Started}, {supervisor, Name}] ->
                    case application:get_env(lager, suppress_supervisor_start_stop, false) of
                        true ->
                            no_log;
                        _ ->
                            MFA = format_mfa(get_value(mfargs, Started)),
                            Pid = get_value(pid, Started),
                            ?LOGFMT(Sink, debug, P, "Supervisor ~w started ~s at pid ~w",
                                [supervisor_name(Name), MFA, Pid])
                    end;
                _ ->
                    ?LOGMSG(Sink, info, P, "PROGRESS REPORT " ++ print_silly_list(D))
            end;
        _ ->
            ?LOGFMT(Sink, warning, self(), "Unexpected error_logger event ~w", [Event])
    end,
    case DidLog of
        logged ->
            {ok, State};
        no_log ->
            Shaper = State#state.shaper,
            {ok, State#state{
                   shaper = Shaper#lager_shaper{
                              mps = Shaper#lager_shaper.mps - 1
                             }
                  }
            }
    end.

format_crash_report(Report, Neighbours) ->
    Name = case get_value(registered_name, Report, []) of
        [] ->
            %% process_info(Pid, registered_name) returns [] for unregistered processes
            get_value(pid, Report);
        Atom -> Atom
    end,
    Md0 = case get_value(dictionary, Report, []) of
        [] ->
            %% process_info(Pid, registered_name) returns [] for unregistered processes
            [];
        Dict ->
            %% pull the lager metadata out of the process dictionary, if we can
            get_value('_lager_metadata', Dict, [])
    end,

    {Class, Reason, Trace} = get_value(error_info, Report),
    {Md, ReasonStr} = format_reason_md({Reason, Trace}),
    Type = case Class of
        exit -> "exited";
        _ -> "crashed"
    end,
    {Md0 ++ Md, io_lib:format("Process ~w with ~w neighbours ~s with reason: ~s",
        [Name, length(Neighbours), Type, ReasonStr])}.

format_offender(Off) ->
    case get_value(mfargs, Off) of
        undefined ->
            %% supervisor_bridge
            io_lib:format("at module ~w at ~w",
                [get_value(mod, Off), get_value(pid, Off)]);
        MFArgs ->
            %% regular supervisor
            {_, MFA} = format_mfa_md(MFArgs),

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

%% backwards compatability shim
format_reason(Reason) ->
    element(2, format_reason_md(Reason)).

-spec format_reason_md(Stacktrace:: any()) -> {Metadata:: [{atom(), any()}], String :: list()}.
format_reason_md({'function not exported', [{M, F, A},MFA|_]}) ->
    {Md, Formatted} = format_mfa_md(MFA),
    {_, Formatted2} = format_mfa_md({M, F, length(A)}),
    {[{reason, 'function not exported'} | Md],
     ["call to undefined function ", Formatted2,
         " from ", Formatted]};
format_reason_md({'function not exported', [{M, F, A, _Props},MFA|_]}) ->
    %% R15 line numbers
    {Md, Formatted} = format_mfa_md(MFA),
    {_, Formatted2} = format_mfa_md({M, F, length(A)}),
    {[{reason, 'function not exported'} | Md],
     ["call to undefined function ", Formatted2,
         " from ", Formatted]};
format_reason_md({undef, [MFA|_]}) ->
    {Md, Formatted} = format_mfa_md(MFA),
    {[{reason, undef} | Md],
     ["call to undefined function ", Formatted]};
format_reason_md({bad_return, {_MFA, {'EXIT', Reason}}}) ->
    format_reason_md(Reason);
format_reason_md({bad_return, {MFA, Val}}) ->
    {Md, Formatted} = format_mfa_md(MFA),
    {[{reason, bad_return} | Md],
     ["bad return value ", print_val(Val), " from ", Formatted]};
format_reason_md({bad_return_value, Val}) ->
    {[{reason, bad_return}],
     ["bad return value: ", print_val(Val)]};
format_reason_md({{bad_return_value, Val}, MFA}) ->
    {Md, Formatted} = format_mfa_md(MFA),
    {[{reason, bad_return_value} | Md],
     ["bad return value: ", print_val(Val), " in ", Formatted]};
format_reason_md({{badrecord, Record}, [MFA|_]}) ->
    {Md, Formatted} = format_mfa_md(MFA),
    {[{reason, badrecord} | Md],
     ["bad record ", print_val(Record), " in ", Formatted]};
format_reason_md({{case_clause, Val}, [MFA|_]}) ->
    {Md, Formatted} = format_mfa_md(MFA),
    {[{reason, case_clause} | Md],
     ["no case clause matching ", print_val(Val), " in ", Formatted]};
format_reason_md({function_clause, [MFA|_]}) ->
    {Md, Formatted} = format_mfa_md(MFA),
    {[{reason, function_clause} | Md],
     ["no function clause matching ", Formatted]};
format_reason_md({if_clause, [MFA|_]}) ->
    {Md, Formatted} = format_mfa_md(MFA),
    {[{reason, if_clause} | Md],
     ["no true branch found while evaluating if expression in ", Formatted]};
format_reason_md({{try_clause, Val}, [MFA|_]}) ->
    {Md, Formatted} = format_mfa_md(MFA),
    {[{reason, try_clause} | Md],
     ["no try clause matching ", print_val(Val), " in ", Formatted]};
format_reason_md({badarith, [MFA|_]}) ->
    {Md, Formatted} = format_mfa_md(MFA),
    {[{reason, badarith} | Md],
     ["bad arithmetic expression in ", Formatted]};
format_reason_md({{badmatch, Val}, [MFA|_]}) ->
    {Md, Formatted} = format_mfa_md(MFA),
    {[{reason, badmatch} | Md],
     ["no match of right hand value ", print_val(Val), " in ", Formatted]};
format_reason_md({emfile, _Trace}) ->
    {[{reason, emfile}],
     "maximum number of file descriptors exhausted, check ulimit -n"};
format_reason_md({system_limit, [{M, F, _}|_] = Trace}) ->
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
    {[{reason, system_limit}], ["system limit: ", Limit]};
format_reason_md({badarg, [MFA,MFA2|_]}) ->
    case MFA of
        {_M, _F, A, _Props} when is_list(A) ->
            %% R15 line numbers
            {Md, Formatted} = format_mfa_md(MFA2),
            {_, Formatted2} = format_mfa_md(MFA),
            {[{reason, badarg} | Md],
             ["bad argument in call to ", Formatted2, " in ", Formatted]};
        {_M, _F, A} when is_list(A) ->
            {Md, Formatted} = format_mfa_md(MFA2),
            {_, Formatted2} = format_mfa_md(MFA),
            {[{reason, badarg} | Md],
             ["bad argument in call to ", Formatted2, " in ", Formatted]};
        _ ->
            %% seems to be generated by a bad call to a BIF
            {Md, Formatted} = format_mfa_md(MFA),
            {[{reason, badarg} | Md],
             ["bad argument in ", Formatted]}
    end;
format_reason_md({{badarg, Stack}, _}) ->
    format_reason_md({badarg, Stack});
format_reason_md({{badarity, {Fun, Args}}, [MFA|_]}) ->
    {arity, Arity} = lists:keyfind(arity, 1, erlang:fun_info(Fun)),
    {Md, Formatted} = format_mfa_md(MFA),
    {[{reason, badarity} | Md],
     [io_lib:format("fun called with wrong arity of ~w instead of ~w in ",
                    [length(Args), Arity]), Formatted]};
format_reason_md({noproc, MFA}) ->
    {Md, Formatted} = format_mfa_md(MFA),
    {[{reason, noproc} | Md],
     ["no such process or port in call to ", Formatted]};
format_reason_md({{badfun, Term}, [MFA|_]}) ->
    {Md, Formatted} = format_mfa_md(MFA),
    {[{reason, badfun} | Md],
     ["bad function ", print_val(Term), " in ", Formatted]};
format_reason_md({Reason, [{M, F, A}|_]}) when is_atom(M), is_atom(F), is_integer(A) ->
    {Md, Formatted} = format_reason_md(Reason),
    {_, Formatted2} = format_mfa_md({M, F, A}),
    {Md, [Formatted, " in ", Formatted2]};
format_reason_md({Reason, [{M, F, A, Props}|_]}) when is_atom(M), is_atom(F), is_integer(A), is_list(Props) ->
    %% line numbers
    {Md, Formatted} = format_reason_md(Reason),
    {_, Formatted2} = format_mfa_md({M, F, A, Props}),
    {Md, [Formatted, " in ", Formatted2]};
format_reason_md(Reason) ->
    {Str, _} = lager_trunc_io:print(Reason, 500),
    {[], Str}.

%% backwards compatability shim
format_mfa(MFA) ->
    element(2, format_mfa_md(MFA)).

-spec format_mfa_md(any()) -> {[{atom(), any()}], list()}.
format_mfa_md({M, F, A}) when is_list(A) ->
    {FmtStr, Args} = format_args(A, [], []),
    {[{module, M}, {function, F}], io_lib:format("~w:~w("++FmtStr++")", [M, F | Args])};
format_mfa_md({M, F, A}) when is_integer(A) ->
    {[{module, M}, {function, F}], io_lib:format("~w:~w/~w", [M, F, A])};
format_mfa_md({M, F, A, Props}) when is_list(Props) ->
    case get_value(line, Props) of
        undefined ->
            format_mfa_md({M, F, A});
        Line ->
            {Md, Formatted} = format_mfa_md({M, F, A}),
            {[{line, Line} | Md], [Formatted, io_lib:format(" line ~w", [Line])]}
    end;
format_mfa_md([{M, F, A}| _]) ->
   %% this kind of weird stacktrace can be generated by a uncaught throw in a gen_server
   format_mfa_md({M, F, A});
format_mfa_md([{M, F, A, Props}| _]) when is_list(Props) ->
   %% this kind of weird stacktrace can be generated by a uncaught throw in a gen_server
   %% TODO we might not always want to print the first MFA we see here, often it is more helpful
   %% to print a lower one, but it is hard to programatically decide.
   format_mfa_md({M, F, A, Props});
format_mfa_md(Other) ->
    {[], io_lib:format("~w", [Other])}.

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

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

no_silent_hwm_drops_test_() ->
    {timeout, 10000,
        [
            fun() ->
                error_logger:tty(false),
                application:load(lager),
                application:set_env(lager, handlers, [{lager_test_backend, warning}]),
                application:set_env(lager, error_logger_redirect, true),
                application:set_env(lager, error_logger_hwm, 5),
                application:set_env(lager, error_logger_flush_queue, false),
                application:set_env(lager, suppress_supervisor_start_stop, true),
                application:set_env(lager, suppress_application_start_stop, true),
                application:unset_env(lager, crash_log),
                lager:start(),
                try
                    {_, _, MS} = os:timestamp(),
                    timer:sleep((1000000 - MS) div 1000 + 1),
                    % start close to the beginning of a new second
                    [error_logger:error_msg("Foo ~p~n", [K]) || K <- lists:seq(1, 15)],
                    wait_for_message("lager_error_logger_h dropped 10 messages in the last second that exceeded the limit of 5 messages/sec", 100, 50),
                    % and once again
                    [error_logger:error_msg("Foo1 ~p~n", [K]) || K <- lists:seq(1, 20)],
                    wait_for_message("lager_error_logger_h dropped 15 messages in the last second that exceeded the limit of 5 messages/sec", 100, 50)
                after
                    application:stop(lager),
                    application:stop(goldrush),
                    error_logger:tty(true)
                end
            end
        ]
    }.

shaper_does_not_forward_sup_progress_messages_to_info_level_backend_test_() ->
    {timeout, 10000,
        [fun() ->
                error_logger:tty(false),
                application:load(lager),
                application:set_env(lager, handlers, [{lager_test_backend, info}]),
                application:set_env(lager, error_logger_redirect, true),
                application:set_env(lager, error_logger_hwm, 5),
                application:set_env(lager, suppress_supervisor_start_stop, false),
                application:set_env(lager, suppress_application_start_stop, false),
                application:unset_env(lager, crash_log),
                lager:start(),
                try
                    PidPlaceholder = self(),
                    SupervisorMsg =
                     [{supervisor, {PidPlaceholder,rabbit_connection_sup}},
                      {started,
                          [{pid, PidPlaceholder},
                           {name,helper_sup},
                           {mfargs,
                               {rabbit_connection_helper_sup,start_link,[]}},
                           {restart_type,intrinsic},
                           {shutdown,infinity},
                           {child_type,supervisor}]}],
                    ApplicationExit =
                        [{application, error_logger_lager_h_test},
                         {exited, stopped},
                         {type, permanent}],

                    error_logger:info_report("This is not a progress message"),
                    error_logger:info_report(ApplicationExit),
                    [error_logger:info_report(progress, SupervisorMsg) || _K <- lists:seq(0, 100)],
                    error_logger:info_report("This is not a progress message 2"),

                    % Note: this gets logged in slow environments:
                    % Application lager started on node nonode@nohost
                    wait_for_count(fun lager_test_backend:count/0, [3, 4], 100, 50),
                    % Note: this debug msg gets ignored in slow environments:
                    % Lager installed handler lager_test_backend into lager_event
                    wait_for_count(fun lager_test_backend:count_ignored/0, [0, 1], 100, 50)
                after
                    application:stop(lager),
                    application:stop(goldrush),
                    error_logger:tty(true)
                end
            end
        ]
    }.

supressed_messages_are_not_counted_for_hwm_test_() ->
    {timeout, 10000,
        [fun() ->
                error_logger:tty(false),
                application:load(lager),
                application:set_env(lager, handlers, [{lager_test_backend, debug}]),
                application:set_env(lager, error_logger_redirect, true),
                application:set_env(lager, error_logger_hwm, 5),
                application:set_env(lager, suppress_supervisor_start_stop, true),
                application:set_env(lager, suppress_application_start_stop, true),
                application:unset_env(lager, crash_log),
                lager:start(),
                try
                    PidPlaceholder = self(),
                    SupervisorMsg =
                     [{supervisor, {PidPlaceholder,rabbit_connection_sup}},
                      {started,
                          [{pid, PidPlaceholder},
                           {name,helper_sup},
                           {mfargs,
                               {rabbit_connection_helper_sup,start_link,[]}},
                           {restart_type,intrinsic},
                           {shutdown,infinity},
                           {child_type,supervisor}]}],
                    ApplicationExit =
                        [{application, error_logger_lager_h_test},
                         {exited, stopped},
                         {type, permanent}],

                    lager_test_backend:flush(),
                    error_logger:info_report("This is not a progress message"),
                    [error_logger:info_report(ApplicationExit) || _K <- lists:seq(0, 100)],
                    [error_logger:info_report(progress, SupervisorMsg) || _K <- lists:seq(0, 100)],
                    error_logger:info_report("This is not a progress message 2"),

                    wait_for_count(fun lager_test_backend:count/0, 2, 100, 50),
                    wait_for_count(fun lager_test_backend:count_ignored/0, 0, 100, 50)
                after
                    application:stop(lager),
                    application:stop(goldrush),
                    error_logger:tty(true)
                end
            end
        ]
    }.

wait_for_message(Expected, Tries, Sleep) ->
    maybe_find_expected_message(lager_test_backend:get_buffer(), Expected, Tries, Sleep).

maybe_find_expected_message(_Buffer, Expected, 0, _Sleep) ->
    throw({not_found, Expected});
maybe_find_expected_message([], Expected, Tries, Sleep) ->
    timer:sleep(Sleep),
    maybe_find_expected_message(lager_test_backend:get_buffer(), Expected, Tries - 1, Sleep);
maybe_find_expected_message([{_Severity, _Date, Msg, _Metadata}|T], Expected, Tries, Sleep) ->
    case lists:flatten(Msg) of
        Expected ->
            ok;
        _ ->
            maybe_find_expected_message(T, Expected, Tries, Sleep)
    end.

wait_for_count(Fun, _Expected, 0, _Sleep) ->
    Actual = Fun(),
    Msg = io_lib:format("wait_for_count: fun ~p final value: ~p~n", [Fun, Actual]),
    throw({failed, Msg});
wait_for_count(Fun, Expected, Tries, Sleep) when is_list(Expected) ->
    Actual = Fun(),
    case lists:member(Actual, Expected) of
        true ->
            ok;
        false ->
            timer:sleep(Sleep),
            wait_for_count(Fun, Expected, Tries - 1, Sleep)
    end;
wait_for_count(Fun, Expected, Tries, Sleep) ->
    case Fun() of
        Expected ->
            ok;
        _ ->
            timer:sleep(Sleep),
            wait_for_count(Fun, Expected, Tries - 1, Sleep)
    end.
-endif.
