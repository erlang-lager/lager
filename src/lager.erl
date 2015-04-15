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

%% API
-export([start/0,
        log/3, log/4,
        md/0, md/1,
        trace/2, trace/3, trace_file/2, trace_file/3, trace_file/4, trace_console/1, trace_console/2,
        clear_all_traces/0, stop_trace/1, stop_trace/3, status/0,
        get_loglevel/1, set_loglevel/2, set_loglevel/3, get_loglevels/0,
        update_loglevel_config/0, posix_error/1,
        safe_format/3, safe_format_chop/3, dispatch_log/5, dispatch_log/9, 
        do_log/9, pr/2]).

-type log_level() :: debug | info | notice | warning | error | critical | alert | emergency.
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

-spec dispatch_log(log_level(), list(), string(), list() | none, pos_integer()) ->  ok | {error, lager_not_running}.
%% this is the same check that the parse transform bakes into the module at compile time
dispatch_log(Severity, Metadata, Format, Args, Size) when is_atom(Severity)->
    SeverityAsInt=lager_util:level_to_num(Severity),
    case {whereis(lager_event), lager_config:get(loglevel, {?LOG_NONE, []})} of
        {undefined, _} ->
            {error, lager_not_running};
        {Pid, {Level, Traces}} when (Level band SeverityAsInt) /= 0 orelse Traces /= [] ->
            do_log(Severity, Metadata, Format, Args, Size, SeverityAsInt, Level, Traces, Pid);
        _ ->
            ok
    end.

%% @private Should only be called externally from code generated from the parse transform
do_log(Severity, Metadata, Format, Args, Size, SeverityAsInt, LevelThreshold, TraceFilters, Pid) when is_atom(Severity) ->
    Destinations = case TraceFilters of
        [] ->
            [];
        _ ->
            lager_util:check_traces(Metadata,SeverityAsInt,TraceFilters,[])
    end,
    case (LevelThreshold band SeverityAsInt) /= 0 orelse Destinations /= [] of
        true ->
            Msg = case Args of
                A when is_list(A) ->
                    safe_format_chop(Format,Args,Size);
                _ ->
                    Format
            end,
            LagerMsg = lager_msg:new(Msg,
                Severity, Metadata, Destinations),
            case lager_config:get(async, false) of
                true ->
                    gen_event:notify(Pid, {log, LagerMsg});
                false ->
                    gen_event:sync_notify(Pid, {log, LagerMsg})
            end;
        false ->
            ok
    end.

%% backwards compatible with beams compiled with lager 1.x
dispatch_log(Severity, _Module, _Function, _Line, _Pid, Metadata, Format, Args, Size) ->
    dispatch_log(Severity, Metadata, Format, Args, Size).

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

trace_file(File, Filter) ->
    trace_file(File, Filter, debug, []).

trace_file(File, Filter, Level) when is_atom(Level) ->
    trace_file(File, Filter, Level, []);

trace_file(File, Filter, Options) when is_list(Options) ->
    trace_file(File, Filter, debug, Options).

trace_file(File, Filter, Level, Options) ->
    FileName = lager_util:expand_path(File),
    Trace0 = {Filter, Level, {lager_file_backend, FileName}},
    case lager_util:validate_trace(Trace0) of
        {ok, Trace} ->
            Handlers = gen_event:which_handlers(lager_event),
            %% check if this file backend is already installed
            Res = case lists:member({lager_file_backend, FileName}, Handlers) of
               false ->
                     %% install the handler
                    LogFileConfig = lists:keystore(level, 1, lists:keystore(file, 1, Options, {file, FileName}), {level, none}),
                    supervisor:start_child(lager_handler_watcher_sup,
                        [lager_event, {lager_file_backend, FileName}, LogFileConfig]);
                _ ->
                    {ok, exists}
            end,
            case Res of
              {ok, _} ->
                add_trace_to_loglevel_config(Trace),
                {ok, {{lager_file_backend, FileName}, Filter, Level}};
              {error, _} = E ->
                E
            end;
        Error ->
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
    Trace0 = {Filter, Level, Backend},
    case lager_util:validate_trace(Trace0) of
        {ok, Trace} ->
            add_trace_to_loglevel_config(Trace),
            {ok, {Backend, Filter, Level}};
        Error ->
            Error
    end.

stop_trace(Backend, Filter, Level) ->
    Trace0 = {Filter, Level, Backend},
    case lager_util:validate_trace(Trace0) of
        {ok, Trace} ->
            stop_trace_int(Trace);
        Error ->
            Error
    end.

stop_trace({Backend, Filter, Level}) ->
    stop_trace(Backend, Filter, Level).

stop_trace_int({Backend, _Filter, _Level} = Trace) ->
    {Level, Traces} = lager_config:get(loglevel),
    NewTraces =  lists:delete(Trace, Traces),
    _ = lager_util:trace_filter([ element(1, T) || T <- NewTraces ]),
    %MinLevel = minimum_loglevel(get_loglevels() ++ get_trace_levels(NewTraces)),
    lager_config:set(loglevel, {Level, NewTraces}),
    case get_loglevel(Backend) of
        none ->
            %% check no other traces point here
            case lists:keyfind(Backend, 3, NewTraces) of
                false ->
                    gen_event:delete_handler(lager_event, Backend, []);
                _ ->
                    ok
            end;
        _ ->
            ok
    end,
    ok.

clear_all_traces() ->
    {Level, _Traces} = lager_config:get(loglevel),
    _ = lager_util:trace_filter(none),
    lager_config:set(loglevel, {Level, []}),
    lists:foreach(fun(Handler) ->
          case get_loglevel(Handler) of
            none ->
              gen_event:delete_handler(lager_event, Handler, []);
            _ ->
              ok
          end
      end, gen_event:which_handlers(lager_event)).

status() ->
    Handlers = gen_event:which_handlers(lager_event),
    TraceCount = case length(element(2, lager_config:get(loglevel))) of
        0 -> 1;
        N -> N
    end,
    Status = ["Lager status:\n",
        [begin
                    Level = get_loglevel(Handler),
                    case Handler of
                        {lager_file_backend, File} ->
                            io_lib:format("File ~s at level ~p\n", [File, Level]);
                        lager_console_backend ->
                            io_lib:format("Console at level ~p\n", [Level]);
                        _ ->
                            []
                    end
            end || Handler <- Handlers],
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
                    io_lib:format("Tracing messages matching ~p at level ~p to ~p\n",
                        [Filter, LevelName, Destination])
            end || {Filter, Level, Destination} <- element(2, lager_config:get(loglevel))],
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
    Reply = gen_event:call(lager_event, Handler, {set_loglevel, Level}, infinity),
    update_loglevel_config(),
    Reply.

%% @doc Set the loglevel for a particular backend that has multiple identifiers
%% (eg. the file backend).
set_loglevel(Handler, Ident, Level) when is_atom(Level) ->
    Reply = gen_event:call(lager_event, {Handler, Ident}, {set_loglevel, Level}, infinity),
    update_loglevel_config(),
    Reply.

%% @doc Get the loglevel for a particular backend. In the case that the backend
%% has multiple identifiers, the lowest is returned
get_loglevel(Handler) ->
    case gen_event:call(lager_event, Handler, get_loglevel, infinity) of
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
get_loglevels() ->
    [gen_event:call(lager_event, Handler, get_loglevel, infinity) ||
        Handler <- gen_event:which_handlers(lager_event)].

%% @private
add_trace_to_loglevel_config(Trace) ->
    {MinLevel, Traces} = lager_config:get(loglevel),
    case lists:member(Trace, Traces) of
        false ->
            NewTraces = [Trace|Traces],
            _ = lager_util:trace_filter([ element(1, T) || T <- NewTraces]),
            lager_config:set(loglevel, {MinLevel, [Trace|Traces]});
        _ ->
            ok
    end.

%% @doc recalculate min log level
update_loglevel_config() ->
    {_, Traces} = lager_config:get(loglevel),
    MinLog = minimum_loglevel(get_loglevels()),
    lager_config:set(loglevel, {MinLog, Traces}).

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

%% @doc Print a record lager found during parse transform
pr(Record, Module) when is_tuple(Record), is_atom(element(1, Record)) ->
    try 
        case is_record_known(Record, Module) of
            false ->
                Record;
            {RecordName, RecordFields} ->
                {'$lager_record', RecordName, 
                    zip(RecordFields, tl(tuple_to_list(Record)), Module, [])}
        end
    catch
        error:undef ->
            Record
    end;
pr(Record, _) ->
    Record.

zip([FieldName|RecordFields], [FieldValue|Record], Module, ToReturn) ->
    case   is_tuple(FieldValue) andalso
           tuple_size(FieldValue) > 0 andalso
           is_atom(element(1, FieldValue)) andalso
           is_record_known(FieldValue, Module) of
        false ->
            zip(RecordFields, Record, Module, [{FieldName, FieldValue}|ToReturn]);
        _Else ->
            F = {FieldName, pr(FieldValue, Module)},
            zip(RecordFields, Record, Module, [F|ToReturn])
    end;
zip([], [], _Module, ToReturn) ->
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
