-module(lager_dedup).
-include("lager.hrl").
%-export([dispatch_log/9]).
-compile(export_all).

dispatch_log(Severity, Module, Function, Line, Pid, Traces, Format, Args, TruncSize) ->
    try
        dispatch_log1(Severity, Module, Function, Line, Pid, Traces, Format, Args, TruncSize)
    catch
        throw:ok -> % early exit
            ok
    end.

dispatch_log1(Severity, Module, Function, Line, Pid, Traces, Format, Args, TruncSize) ->
    {LevelThreshold,TraceFilters} = lager_mochiglobal:get(loglevel,{?LOG_NONE,[]}),
    Timestamp = lager_util:format_time(lager_util:maybe_utc(lager_util:localtime_ms())),
    {Msg,Dest} =
    case {TraceFilters, LevelThreshold >= lager_util:level_to_num(Severity)} of
        {[], true} ->
            {format_log(Severity,Module,Function,Line,Pid,Format,Args,TruncSize),
             []};
        {[_|_], _} ->
            {format_log(Severity,Module,Function,Line,Pid,Format,Args,TruncSize),
             lager_util:check_traces(Traces,
                                     lager_util:level_to_num(Severity),
                                     TraceFilters,
                                     [])};
        _ ->
            throw(ok)
    end,
    lager_deduper:dedup_notify(Dest, Severity, Timestamp, Msg).

format_log(Level, Module, Function, Line, Pid, Format, Args, TruncSize) ->
    [["[", atom_to_list(Level), "] "],
     io_lib:format("~p@~p:~p:~p ", [Pid, Module, Function, Line]),
     safe_format_chop(Format, Args, TruncSize)].

safe_format(Fmt, Args, Limit, Options) ->
    try lager_trunc_io:format(Fmt, Args, Limit, Options)
    catch
        _:_ -> lager_trunc_io:format("FORMAT ERROR: ~p ~p", [Fmt, Args], Limit)
    end.

%% @private
safe_format_chop(Fmt, Args, Limit) ->
    safe_format(Fmt, Args, Limit, [{chomp, true}]).
