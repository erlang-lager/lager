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

%% @doc The lager logging framework.

-module(lager).

-include("lager.hrl").

-define(LAGER_MD_KEY, '__lager_metadata').
-define(TRACE_SINK, '__trace_sink').
-define(ROTATE_TIMEOUT, 100000).

%% API
-export([start/0,
        log/3, log/4, log/5,
        log_unsafe/4,
        md/0, md/1,
        rotate_handler/1, rotate_handler/2, rotate_sink/1, rotate_all/0,
        trace/2, trace/3, trace_file/2, trace_file/3, trace_file/4, trace_console/1, trace_console/2,
        list_all_sinks/0, clear_all_traces/0, stop_trace/1, stop_trace/3, status/0,
        get_loglevel/1, get_loglevel/2, set_loglevel/2, set_loglevel/3, set_loglevel/4, get_loglevels/1,
        update_loglevel_config/1, posix_error/1, set_loghwm/2, set_loghwm/3, set_loghwm/4,
        safe_format/3, safe_format_chop/3, unsafe_format/2, dispatch_log/5, dispatch_log/7, dispatch_log/9,
        do_log/9, do_log/10, do_log_unsafe/10, pr/2, pr/3, pr_stacktrace/1, pr_stacktrace/2]).

-type log_level() :: none | debug | info | notice | warning | error | critical | alert | emergency.
-type log_level_number() :: 0..7.

-export_type([log_level/0, log_level_number/0]).

%% API

%% @doc Start the application. Mainly useful for using `-s lager' as a command
%% line switch to the VM to make lager start on boot.
start() -> start(lager).

start(App) ->
    start_ok(App, application:start(App, permanent)).

start_ok(_App, ok) -> ok;
start_ok(_App, {error, {already_started, _App}}) -> ok;
start_ok(App, {error, {not_started, Dep}}) ->
    ok = start(Dep),
    start(App);
start_ok(App, {error, Reason}) ->
    erlang:error({app_start_failed, App, Reason}).

%% @doc Get lager metadata for current process
-spec md() -> [{atom(), any()}].
md() ->
    case erlang:get(?LAGER_MD_KEY) of
        undefined -> [];
        MD -> MD
    end.

%% @doc Set lager metadata for current process.
%% Will badarg if you don't supply a list of {key, value} tuples keyed by atoms.
-spec md([{atom(), any()},...]) -> ok.
md(NewMD) when is_list(NewMD) ->
    %% make sure its actually a real proplist
    case lists:all(
            fun({Key, _Value}) when is_atom(Key) -> true;
                (_) -> false
            end, NewMD) of
        true ->
            erlang:put(?LAGER_MD_KEY, NewMD),
            ok;
        false ->
            erlang:error(badarg)
    end;
md(_) ->
    erlang:error(badarg).


-spec dispatch_log(atom(), log_level(), list(), string(), list() | none, pos_integer(), safe | unsafe) ->  ok | {error, lager_not_running} | {error, {sink_not_configured, atom()}}.
%% this is the same check that the parse transform bakes into the module at compile time
%% see lager_transform (lines 173-216)
dispatch_log(Sink, Severity, Metadata, Format, Args, Size, Safety) when is_atom(Severity)->
    SeverityAsInt=lager_util:level_to_num(Severity),
    case {whereis(Sink), whereis(?DEFAULT_SINK), lager_config:get({Sink, loglevel}, {?LOG_NONE, []})} of
         {undefined, undefined, _} -> {error, lager_not_running};
         {undefined, _LagerEventPid0, _} -> {error, {sink_not_configured, Sink}};
         {SinkPid, _LagerEventPid1, {Level, Traces}} when Safety =:= safe andalso ( (Level band SeverityAsInt) /= 0 orelse Traces /= [] ) ->
            do_log(Severity, Metadata, Format, Args, Size, SeverityAsInt, Level, Traces, Sink, SinkPid);
         {SinkPid, _LagerEventPid1, {Level, Traces}} when Safety =:= unsafe andalso ( (Level band SeverityAsInt) /= 0 orelse Traces /= [] ) ->
            do_log_unsafe(Severity, Metadata, Format, Args, Size, SeverityAsInt, Level, Traces, Sink, SinkPid);
         _ -> ok
    end.

%% @private Should only be called externally from code generated from the parse transform
do_log(Severity, Metadata, Format, Args, Size, SeverityAsInt, LevelThreshold, TraceFilters, Sink, SinkPid) when is_atom(Severity) ->
    FormatFun = fun() -> safe_format_chop(Format, Args, Size) end,
    do_log_impl(Severity, Metadata, Format, Args, SeverityAsInt, LevelThreshold, TraceFilters, Sink, SinkPid, FormatFun).

do_log_impl(Severity, Metadata, Format, Args, SeverityAsInt, LevelThreshold, TraceFilters, Sink, SinkPid, FormatFun) ->
    {Destinations, TraceSinkPid} = case TraceFilters of
        [] ->
            {[], undefined};
        _ ->
            {lager_util:check_traces(Metadata,SeverityAsInt,TraceFilters,[]), whereis(?TRACE_SINK)}
    end,
    case (LevelThreshold band SeverityAsInt) /= 0 orelse Destinations /= [] of
        true ->
            Msg = case Args of
                A when is_list(A) ->
                    FormatFun();
                _ ->
                    Format
            end,
            LagerMsg = lager_msg:new(Msg,
                Severity, Metadata, Destinations),
            case lager_config:get({Sink, async}, false) of
                true ->
                    gen_event:notify(SinkPid, {log, LagerMsg});
                false ->
                    gen_event:sync_notify(SinkPid, {log, LagerMsg})
            end,
            case TraceSinkPid /= undefined of
                true ->
                    gen_event:notify(TraceSinkPid, {log, LagerMsg});
                false ->
                    ok
            end;
        false ->
            ok
    end.

%% @private Should only be called externally from code generated from the parse transform
%% Specifically, it would be level ++ `_unsafe' as in `info_unsafe'.
do_log_unsafe(Severity, Metadata, Format, Args, _Size, SeverityAsInt, LevelThreshold, TraceFilters, Sink, SinkPid) when is_atom(Severity) ->
    FormatFun = fun() -> unsafe_format(Format, Args) end,
    do_log_impl(Severity, Metadata, Format, Args, SeverityAsInt, LevelThreshold, TraceFilters, Sink, SinkPid, FormatFun).


%% backwards compatible with beams compiled with lager 1.x
dispatch_log(Severity, _Module, _Function, _Line, _Pid, Metadata, Format, Args, Size) ->
    dispatch_log(Severity, Metadata, Format, Args, Size).

%% backwards compatible with beams compiled with lager 2.x
dispatch_log(Severity, Metadata, Format, Args, Size) ->
    dispatch_log(?DEFAULT_SINK, Severity, Metadata, Format, Args, Size, safe).

%% backwards compatible with beams compiled with lager 2.x
do_log(Severity, Metadata, Format, Args, Size, SeverityAsInt, LevelThreshold, TraceFilters, SinkPid) ->
    do_log(Severity, Metadata, Format, Args, Size, SeverityAsInt,
           LevelThreshold, TraceFilters, ?DEFAULT_SINK, SinkPid).


%% TODO:
%% Consider making log2/4 that takes the Level, Pid and Message params of log/3
%% along with a Sink param??

%% @doc Manually log a message into lager without using the parse transform.
-spec log(log_level(), pid() | atom() | [tuple(),...], list()) -> ok | {error, lager_not_running}.
log(Level, Pid, Message) when is_pid(Pid); is_atom(Pid) ->
    dispatch_log(Level, [{pid,Pid}], Message, [], ?DEFAULT_TRUNCATION);
log(Level, Metadata, Message) when is_list(Metadata) ->
    dispatch_log(Level, Metadata, Message, [], ?DEFAULT_TRUNCATION).

%% @doc Manually log a message into lager without using the parse transform.
-spec log(log_level(), pid() | atom() | [tuple(),...], string(), list()) -> ok | {error, lager_not_running}.
log(Level, Pid, Format, Args) when is_pid(Pid); is_atom(Pid) ->
    dispatch_log(Level, [{pid,Pid}], Format, Args, ?DEFAULT_TRUNCATION);
log(Level, Metadata, Format, Args) when is_list(Metadata) ->
    dispatch_log(Level, Metadata, Format, Args, ?DEFAULT_TRUNCATION).

log_unsafe(Level, Metadata, Format, Args) when is_list(Metadata) ->
    dispatch_log(?DEFAULT_SINK, Level, Metadata, Format, Args, ?DEFAULT_TRUNCATION, unsafe).


%% @doc Manually log a message into lager without using the parse transform.
-spec log(atom(), log_level(), pid() | atom() | [tuple(),...], string(), list()) -> ok | {error, lager_not_running}.
log(Sink, Level, Pid, Format, Args) when is_pid(Pid); is_atom(Pid) ->
    dispatch_log(Sink, Level, [{pid,Pid}], Format, Args, ?DEFAULT_TRUNCATION, safe);
log(Sink, Level, Metadata, Format, Args) when is_list(Metadata) ->
    dispatch_log(Sink, Level, Metadata, Format, Args, ?DEFAULT_TRUNCATION, safe).

validate_trace_filters(Filters, Level, Backend) ->
    Sink = proplists:get_value(sink, Filters, ?DEFAULT_SINK),
    {Sink,
     lager_util:validate_trace({
                                 proplists:delete(sink, Filters),
                                 Level,
                                 Backend
                               })
    }.

trace_file(File, Filter) ->
    trace_file(File, Filter, debug, []).

trace_file(File, Filter, Level) when is_atom(Level) ->
    trace_file(File, Filter, Level, []);

trace_file(File, Filter, Options) when is_list(Options) ->
    trace_file(File, Filter, debug, Options).

trace_file(File, Filter, Level, Options) ->
    FileName = lager_util:expand_path(File),
    case validate_trace_filters(Filter, Level, {lager_file_backend, FileName}) of
        {Sink, {ok, Trace}} ->
            Handlers = lager_config:global_get(handlers, []),
            %% check if this file backend is already installed
            Res = case lists:keyfind({lager_file_backend, FileName}, 1, Handlers) of
                      false ->
                          %% install the handler
                          LogFileConfig =
                              lists:keystore(level, 1,
                                             lists:keystore(file, 1,
                                                            Options,
                                                            {file, FileName}),
                                             {level, none}),
                          HandlerInfo =
                              lager_app:start_handler(Sink, {lager_file_backend, FileName},
                                                      LogFileConfig),
                          lager_config:global_set(handlers, [HandlerInfo|Handlers]),
                          {ok, installed};
                      {_Watcher, _Handler, Sink} ->
                          {ok, exists};
                      {_Watcher, _Handler, _OtherSink} ->
                          {error, file_in_use}
            end,
            case Res of
              {ok, _} ->
                add_trace_to_loglevel_config(Trace, Sink),
                {ok, {{lager_file_backend, FileName}, Filter, Level}};
              {error, _} = E ->
                E
            end;
        {_Sink, Error} ->
            Error
    end.

trace_console(Filter) ->
    trace_console(Filter, debug).

trace_console(Filter, Level) ->
    trace(lager_console_backend, Filter, Level).

trace(Backend, Filter) ->
    trace(Backend, Filter, debug).

trace({lager_file_backend, File}, Filter, Level) ->
    trace_file(File, Filter, Level);

trace(Backend, Filter, Level) ->
    case validate_trace_filters(Filter, Level, Backend) of
        {Sink, {ok, Trace}} ->
            add_trace_to_loglevel_config(Trace, Sink),
            {ok, {Backend, Filter, Level}};
        {_Sink, Error} ->
            Error
    end.

stop_trace(Backend, Filter, Level) ->
    case validate_trace_filters(Filter, Level, Backend) of
        {Sink, {ok, Trace}} ->
            stop_trace_int(Trace, Sink);
        {_Sink, Error} ->
            Error
    end.

stop_trace({Backend, Filter, Level}) ->
    stop_trace(Backend, Filter, Level).

%% Important: validate_trace_filters orders the arguments of
%% trace tuples differently than the way outside callers have
%% the trace tuple.
%%
%% That is to say, outside they are represented as 
%% `{Backend, Filter, Level}'
%%
%% and when they come back from validation, they're
%% `{Filter, Level, Backend}'
stop_trace_int({_Filter, _Level, Backend} = Trace, Sink) ->
    {Level, Traces} = lager_config:get({Sink, loglevel}),
    NewTraces =  lists:delete(Trace, Traces),
    _ = lager_util:trace_filter([ element(1, T) || T <- NewTraces ]),
    %MinLevel = minimum_loglevel(get_loglevels() ++ get_trace_levels(NewTraces)),
    lager_config:set({Sink, loglevel}, {Level, NewTraces}),
    case get_loglevel(Sink, Backend) of
        none ->
            %% check no other traces point here
            case lists:keyfind(Backend, 3, NewTraces) of
                false ->
                    gen_event:delete_handler(Sink, Backend, []),
                    lager_config:global_set(handlers,
                                            lists:keydelete(Backend, 1,
                                                            lager_config:global_get(handlers)));
                _ ->
                    ok
            end;
        _ ->
            ok
    end,
    ok.

list_all_sinks() ->
    sets:to_list(
      lists:foldl(fun({_Watcher, _Handler, Sink}, Set) ->
                          sets:add_element(Sink, Set)
                  end,
                  sets:new(),
                  lager_config:global_get(handlers, []))).

clear_traces_by_sink(Sinks) ->
    lists:foreach(fun(S) ->
                          {Level, _Traces} =
                              lager_config:get({S, loglevel}),
                          lager_config:set({S, loglevel},
                                           {Level, []})
                  end,
                  Sinks).

clear_all_traces() ->
    Handlers = lager_config:global_get(handlers, []),
    clear_traces_by_sink(list_all_sinks()),
    _ = lager_util:trace_filter(none),
    lager_config:global_set(handlers,
                            lists:filter(
      fun({Handler, _Watcher, Sink}) ->
              case get_loglevel(Sink, Handler) of
                  none ->
                      gen_event:delete_handler(Sink, Handler, []),
                      false;
                  _ ->
                      true
              end
      end, Handlers)).

find_traces(Sinks) ->
    lists:foldl(fun(S, Acc) ->
                        {_Level, Traces} = lager_config:get({S, loglevel}),
                        Acc ++ lists:map(fun(T) -> {S, T} end, Traces)
                end,
                [],
                Sinks).

status() ->
    Handlers = lager_config:global_get(handlers, []),
    Sinks = lists:sort(list_all_sinks()),
    Traces = find_traces(Sinks),
    TraceCount = case length(Traces) of
        0 -> 1;
        N -> N
    end,
    Status = ["Lager status:\n",
        [begin
                    Level = get_loglevel(Sink, Handler),
                    case Handler of
                        {lager_file_backend, File} ->
                            io_lib:format("File ~s (~s) at level ~p\n", [File, Sink, Level]);
                        lager_console_backend ->
                            io_lib:format("Console (~s) at level ~p\n", [Sink, Level]);
                        _ ->
                            []
                    end
            end || {Handler, _Watcher, Sink} <- lists:sort(fun({_, _, S1},
                                                               {_, _, S2}) -> S1 =< S2 end,
                                                           Handlers)],
        "Active Traces:\n",
        [begin
                    LevelName = case Level of
                        {mask, Mask} ->
                            case lager_util:mask_to_levels(Mask) of
                                [] -> none;
                                Levels -> hd(Levels)
                            end;
                        Num ->
                            lager_util:num_to_level(Num)
                    end,
                    io_lib:format("Tracing messages matching ~p (sink ~s) at level ~p to ~p\n",
                        [Filter, Sink, LevelName, Destination])
            end || {Sink, {Filter, Level, Destination}} <- Traces],
         [
         "Tracing Reductions:\n",
            case ?DEFAULT_TRACER:info('query') of
                {null, false} -> "";
                Query -> io_lib:format("~p~n", [Query])
            end
         ],
         [
          "Tracing Statistics:\n ",
              [ begin
                    [" ", atom_to_list(Table), ": ",
                     integer_to_list(?DEFAULT_TRACER:info(Table) div TraceCount),
                     "\n"]
                end || Table <- [input, output, filter] ]
         ]],
    io:put_chars(Status).


%% @doc Set the loglevel for a particular backend.
set_loglevel(Handler, Level) when is_atom(Level) ->
    set_loglevel(?DEFAULT_SINK, Handler, undefined, Level).

%% @doc Set the loglevel for a particular backend that has multiple identifiers
%% (eg. the file backend).
set_loglevel(Handler, Ident, Level) when is_atom(Level) ->
    set_loglevel(?DEFAULT_SINK, Handler, Ident, Level).

%% @doc Set the loglevel for a particular sink's backend that potentially has
%% multiple identifiers. (Use `undefined' if it doesn't have any.)
set_loglevel(Sink, Handler, Ident, Level) when is_atom(Level) ->
    HandlerArg = case Ident of
        undefined -> Handler;
        _ -> {Handler, Ident}
    end,
    Reply = gen_event:call(Sink, HandlerArg, {set_loglevel, Level}, infinity),
    update_loglevel_config(Sink),
    Reply.


%% @doc Get the loglevel for a particular backend on the default sink. In the case that the backend
%% has multiple identifiers, the lowest is returned.
get_loglevel(Handler) ->
    get_loglevel(?DEFAULT_SINK, Handler).

%% @doc Get the loglevel for a particular sink's backend. In the case that the backend
%% has multiple identifiers, the lowest is returned.
get_loglevel(Sink, Handler) ->
    case gen_event:call(Sink, Handler, get_loglevel, infinity) of
        {mask, Mask} ->
            case lager_util:mask_to_levels(Mask) of
                [] -> none;
                Levels -> hd(Levels)
            end;
        X when is_integer(X) ->
            lager_util:num_to_level(X);
        Y -> Y
    end.

%% @doc Try to convert an atom to a posix error, but fall back on printing the
%% term if its not a valid posix error code.
posix_error(Error) when is_atom(Error) ->
    case erl_posix_msg:message(Error) of
        "unknown POSIX error" -> atom_to_list(Error);
        Message -> Message
    end;
posix_error(Error) ->
    safe_format_chop("~p", [Error], ?DEFAULT_TRUNCATION).

%% @private
get_loglevels(Sink) ->
    [gen_event:call(Sink, Handler, get_loglevel, infinity) ||
        Handler <- gen_event:which_handlers(Sink)].

%% @doc Set the loghwm for the default sink.
set_loghwm(Handler, Hwm) when is_integer(Hwm) ->
    set_loghwm(?DEFAULT_SINK, Handler, Hwm).

%% @doc Set the loghwm for a particular backend.
set_loghwm(Sink, Handler, Hwm) when is_integer(Hwm) ->
    gen_event:call(Sink, Handler, {set_loghwm, Hwm}, infinity).

%% @doc Set the loghwm (log high water mark) for file backends with multiple identifiers
set_loghwm(Sink, Handler, Ident, Hwm) when is_integer(Hwm) ->
    gen_event:call(Sink, {Handler, Ident}, {set_loghwm, Hwm}, infinity).

%% @private
add_trace_to_loglevel_config(Trace, Sink) ->
    {MinLevel, Traces} = lager_config:get({Sink, loglevel}),
    case lists:member(Trace, Traces) of
        false ->
            NewTraces = [Trace|Traces],
            _ = lager_util:trace_filter([ element(1, T) || T <- NewTraces]),
            lager_config:set({Sink, loglevel}, {MinLevel, [Trace|Traces]});
        _ ->
            ok
    end.

%% @doc recalculate min log level
update_loglevel_config(error_logger) ->
    %% Not a sink under our control, part of the Erlang logging
    %% utility that error_logger_lager_h attaches to
    true;
update_loglevel_config(Sink) ->
    {_, Traces} = lager_config:get({Sink, loglevel}, {ignore_me, []}),
    MinLog = minimum_loglevel(get_loglevels(Sink)),
    lager_config:set({Sink, loglevel}, {MinLog, Traces}).

%% @private
minimum_loglevel(Levels) ->
    lists:foldl(fun({mask, Mask}, Acc) ->
                Mask bor Acc;
            (Level, Acc) when is_integer(Level) ->
                {mask, Mask} = lager_util:config_to_mask(lager_util:num_to_level(Level)),
                Mask bor Acc;
            (_, Acc) ->
                Acc
        end, 0, Levels).

%% @doc Print the format string `Fmt' with `Args' safely with a size
%% limit of `Limit'. If the format string is invalid, or not enough
%% arguments are supplied 'FORMAT ERROR' is printed with the offending
%% arguments. The caller is NOT crashed.

safe_format(Fmt, Args, Limit) ->
    safe_format(Fmt, Args, Limit, []).

safe_format(Fmt, Args, Limit, Options) ->
    try lager_trunc_io:format(Fmt, Args, Limit, Options)
    catch
        _:_ -> lager_trunc_io:format("FORMAT ERROR: ~p ~p", [Fmt, Args], Limit)
    end.

%% @private
safe_format_chop(Fmt, Args, Limit) ->
    safe_format(Fmt, Args, Limit, [{chomp, true}]).

%% @private Print the format string `Fmt' with `Args' without a size limit.
%% This is unsafe because the output of this function is unbounded.
%%
%% Log messages with unbounded size will kill your application dead as
%% OTP mechanisms stuggle to cope with them.  So this function is
%% intended <b>only</b> for messages which have a reasonable bounded
%% size before they're formatted.
%%
%% If the format string is invalid or not enough arguments are
%% supplied a 'FORMAT ERROR' message is printed instead with the
%% offending arguments. The caller is NOT crashed.
unsafe_format(Fmt, Args) ->
    try io_lib:format(Fmt, Args)
    catch
        _:_ -> io_lib:format("FORMAT ERROR: ~p ~p", [Fmt, Args])
    end.

%% @doc Print a record lager found during parse transform
pr(Record, Module) when is_tuple(Record), is_atom(element(1, Record)) ->
    pr(Record, Module, []);
pr(Record, _) ->
    Record.

%% @doc Print a record lager found during parse transform
pr(Record, Module, Options) when is_tuple(Record), is_atom(element(1, Record)), is_list(Options) ->
    try 
        case is_record_known(Record, Module) of
            false ->
                Record;
            {RecordName, RecordFields} ->
                {'$lager_record', RecordName, 
                    zip(RecordFields, tl(tuple_to_list(Record)), Module, Options, [])}
        end
    catch
        error:undef ->
            Record
    end;
pr(Record, _, _) ->
    Record.

zip([FieldName|RecordFields], [FieldValue|Record], Module, Options, ToReturn) ->
    Compress = lists:member(compress, Options),
    case   is_tuple(FieldValue) andalso
           tuple_size(FieldValue) > 0 andalso
           is_atom(element(1, FieldValue)) andalso
           is_record_known(FieldValue, Module) of
        false when Compress andalso FieldValue =:= undefined ->
            zip(RecordFields, Record, Module, Options, ToReturn);
        false ->
            zip(RecordFields, Record, Module, Options, [{FieldName, FieldValue}|ToReturn]);
        _Else ->
            F = {FieldName, pr(FieldValue, Module, Options)},
            zip(RecordFields, Record, Module, Options, [F|ToReturn])
    end;
zip([], [], _Module, _Compress, ToReturn) ->
    lists:reverse(ToReturn).

is_record_known(Record, Module) ->
    Name = element(1, Record),
    Attrs = Module:module_info(attributes),
    case lists:keyfind(lager_records, 1, Attrs) of
        false -> false;
        {lager_records, Records} ->
            case lists:keyfind(Name, 1, Records) of
                false -> false;
                {Name, RecordFields} ->
                    case (tuple_size(Record) - 1) =:= length(RecordFields) of
                        false -> false;
                        true -> {Name, RecordFields}
                    end
            end
    end.


%% @doc Print stacktrace in human readable form
pr_stacktrace(Stacktrace) ->
    Indent = "\n    ",
    lists:foldl(
        fun(Entry, Acc) ->
            Acc ++ Indent ++ error_logger_lager_h:format_mfa(Entry)
        end,
        [],
        lists:reverse(Stacktrace)).

pr_stacktrace(Stacktrace, {Class, Reason}) ->
    lists:flatten(
        pr_stacktrace(Stacktrace) ++ "\n" ++ io_lib:format("~s:~p", [Class, Reason])).
    

%% R15 compatibility only
filtermap(Fun, List1) ->
    lists:foldr(fun(Elem, Acc) ->
                       case Fun(Elem) of
                           false -> Acc;
                           {true,Value} -> [Value|Acc]
                       end
                end, [], List1).

rotate_sink(Sink) ->
    Handlers = lager_config:global_get(handlers),
    RotateHandlers = filtermap(
        fun({Handler,_,S}) when S == Sink -> {true, {Handler, Sink}};
           (_)                            -> false 
        end, 
        Handlers),
    rotate_handlers(RotateHandlers).

rotate_all() -> 
    rotate_handlers(lists:map(fun({H,_,S}) -> {H, S} end,
                              lager_config:global_get(handlers))).


rotate_handlers(Handlers) ->
    [ rotate_handler(Handler, Sink) || {Handler, Sink} <- Handlers ].


rotate_handler(Handler) ->
    Handlers = lager_config:global_get(handlers),
    case lists:keyfind(Handler, 1, Handlers) of
        {Handler, _, Sink} -> rotate_handler(Handler, Sink);
        false              -> ok
    end.

rotate_handler(Handler, Sink) ->
    gen_event:call(Sink, Handler, rotate, ?ROTATE_TIMEOUT).
