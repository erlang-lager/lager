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

%% @doc The lager logging framework.

-module(lager).

-include("lager.hrl").
-include_lib("eunit/include/eunit.hrl").

%% API
-export([start/0,
        log/3, log/4,
        trace_file/2, trace_file/3, trace_console/1, trace_console/2,
        clear_all_traces/0, stop_trace/1, status/0,
        get_loglevel/1, set_loglevel/2, set_loglevel/3, get_loglevels/0,
        minimum_loglevel/1, posix_error/1,
        safe_format/3, safe_format_chop/3,dispatch_log/4]).

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


-spec dispatch_log(log_level(), list(), string(), list() | none) ->  ok | {error, lager_not_running}.
dispatch_log(Severity, Metadata, Format, Args) when is_atom(Severity)->
	case whereis(lager_event) of
		undefined ->
			%% lager isn't running
			{error, lager_not_running};
		Pid ->
			
			{LevelThreshold,TraceFilters} = lager_mochiglobal:get(loglevel,{?LOG_NONE,[]}),
			SeverityAsInt=lager_util:level_to_num(Severity),
			Destinations = case TraceFilters of 
							   [] -> [];
							   _ -> 
								   lager_util:check_traces(Metadata,SeverityAsInt,TraceFilters,[])
						   end,
			case (LevelThreshold >= SeverityAsInt orelse Destinations =/= []) of
				true -> 
					Timestamp = lager_util:format_time(),
					Msg=case Args of 
							A when is_list(A) ->safe_format_chop(Format,Args,4096);
							_ -> Format
						end,
					gen_event:sync_notify(Pid, #lager_log_message{destinations=Destinations, 
																  metadata=Metadata, 
																  severity_as_int=SeverityAsInt, 
																  timestamp=Timestamp, 
																  message=Msg});
				_ -> 
					ok
			end
	end.
							

%% @doc Manually log a message into lager without using the parse transform.
-spec log(log_level(), pid(), list()) -> ok | {error, lager_not_running}.
log(Level, Pid, Message) ->
	dispatch_log(Level, [{pid,Pid}], Message,none).

%% @doc Manually log a message into lager without using the parse transform.
-spec log(log_level(), pid(), string(), list()) -> ok | {error, lager_not_running}.
log(Level, Pid, Format, Args) ->
	dispatch_log(Level, [{pid,Pid}], Format, Args).

trace_file(File, Filter) ->
    trace_file(File, Filter, debug).

trace_file(File, Filter, Level) ->
    Trace0 = {Filter, Level, {lager_file_backend, File}},
    case lager_util:validate_trace(Trace0) of
        {ok, Trace} ->
            Handlers = gen_event:which_handlers(lager_event),
            %% check if this file backend is already installed
            case lists:member({lager_file_backend, File}, Handlers) of
                false ->
                    %% install the handler
                    supervisor:start_child(lager_handler_watcher_sup,
                        [lager_event, {lager_file_backend, File}, {File, none}]);
                _ ->
                    ok
            end,
            %% install the trace.
            {MinLevel, Traces} = lager_mochiglobal:get(loglevel),
            case lists:member(Trace, Traces) of
                false ->
                    lager_mochiglobal:put(loglevel, {MinLevel, [Trace|Traces]});
                _ -> ok
            end,
            {ok, Trace};
        Error ->
            Error
    end.

trace_console(Filter) ->
    trace_console(Filter, debug).

trace_console(Filter, Level) ->
    Trace0 = {Filter, Level, lager_console_backend},
    case lager_util:validate_trace(Trace0) of
        {ok, Trace} ->
            {MinLevel, Traces} = lager_mochiglobal:get(loglevel),
            case lists:member(Trace, Traces) of
                false ->
                    lager_mochiglobal:put(loglevel, {MinLevel, [Trace|Traces]});
                _ -> ok
            end,
            {ok, Trace};
        Error ->
            Error
    end.

stop_trace({_Filter, _Level, Target} = Trace) ->
    {MinLevel, Traces} = lager_mochiglobal:get(loglevel),
    NewTraces =  lists:delete(Trace, Traces),
    lager_mochiglobal:put(loglevel, {MinLevel, NewTraces}),
    case get_loglevel(Target) of
        none ->
            %% check no other traces point here
            case lists:keyfind(Target, 3, NewTraces) of
                false ->
                    gen_event:delete_handler(lager_event, Target, []);
                _ ->
                    ok
            end;
        _ ->
            ok
    end,
    ok.

clear_all_traces() ->
    {MinLevel, _Traces} = lager_mochiglobal:get(loglevel),
    lager_mochiglobal:put(loglevel, {MinLevel, []}),
    [begin
                case get_loglevel(Handler) of
                    none ->
                        gen_event:delete_handler(lager_event, Handler, []);
                    _ ->
                        ok
                end
        end || Handler <- gen_event:which_handlers(lager_event)],
    ok.

status() ->
    Handlers = gen_event:which_handlers(lager_event),
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
                    io_lib:format("Tracing messages matching ~p at level ~p to ~p\n",
                        [Filter, lager_util:num_to_level(Level), Destination])
            end || {Filter, Level, Destination} <- element(2, lager_mochiglobal:get(loglevel))]],
    io:put_chars(Status).

%% @doc Set the loglevel for a particular backend.
set_loglevel(Handler, Level) when is_atom(Level) ->
    Reply = gen_event:call(lager_event, Handler, {set_loglevel, Level}, infinity),
    %% recalculate min log level
    MinLog = minimum_loglevel(get_loglevels()),
    {_, Traces} = lager_mochiglobal:get(loglevel),
    lager_mochiglobal:put(loglevel, {MinLog, Traces}),
    Reply.

%% @doc Set the loglevel for a particular backend that has multiple identifiers
%% (eg. the file backend).
set_loglevel(Handler, Ident, Level) when is_atom(Level) ->
    io:format("handler: ~p~n", [{Handler, Ident}]),
    Reply = gen_event:call(lager_event, {Handler, Ident}, {set_loglevel, Level}, infinity),
    %% recalculate min log level
    MinLog = minimum_loglevel(get_loglevels()),
    {_, Traces} = lager_mochiglobal:get(loglevel),
    lager_mochiglobal:put(loglevel, {MinLog, Traces}),
    Reply.

%% @doc Get the loglevel for a particular backend. In the case that the backend
%% has multiple identifiers, the lowest is returned
get_loglevel(Handler) ->
    case gen_event:call(lager_event, Handler, get_loglevel, infinity) of
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
    safe_format_chop("~p", [Error], 4096).

%% @private
get_loglevels() ->
    [gen_event:call(lager_event, Handler, get_loglevel, infinity) ||
        Handler <- gen_event:which_handlers(lager_event)].

%% @private
minimum_loglevel([]) ->
    -1; %% lower than any log level, logging off
minimum_loglevel(Levels) ->
    erlang:hd(lists:reverse(lists:sort(Levels))).

%% @doc Print the format string `Fmt' with `Args' safely with a size
%% limit of `Limit'. If the format string is invalid, or not enough
%% arguments are supplied 'FORMAT ERROR' is printed with the offending
%% arguments. The caller is NOT crashed.

safe_format(Fmt, Args, Limit) ->
    safe_format(Fmt, Args, Limit, []).

safe_format(Fmt, Args, Limit, Options) ->
    try lager_trunc_io:format(Fmt, Args, Limit, Options) of
        Result -> Result
    catch
        _:_ -> lager_trunc_io:format("FORMAT ERROR: ~p ~p", [Fmt, Args], Limit)
    end.

%% @private
safe_format_chop(Fmt, Args, Limit) ->
    safe_format(Fmt, Args, Limit, [{chomp, true}]).
