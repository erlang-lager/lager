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

%% API
-export([start/0,
        log/7, log/8, log/3, log/4,
        get_loglevel/1, set_loglevel/2, set_loglevel/3, get_loglevels/0,
        minimum_loglevel/1, posix_error/1,
        safe_format/3, safe_format_chop/3]).

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

%% @private
-spec log(log_level(), atom(), atom(), pos_integer(), pid(), tuple(), list()) ->
    ok | {error, lager_not_running}.
log(Level, Module, Function, Line, Pid, Time, Message) ->
    Timestamp = lager_util:format_time(Time),
    Msg = [["[", atom_to_list(Level), "] "],
           io_lib:format("~p@~p:~p:~p ", [Pid, Module, Function, Line]),
           safe_format_chop("~s", [Message], 4096)],
    safe_notify(lager_util:level_to_num(Level), Timestamp, Msg).

%% @private
-spec log(log_level(), atom(), atom(), pos_integer(), pid(), tuple(), string(), list()) ->
    ok | {error, lager_not_running}.
log(Level, Module, Function, Line, Pid, Time, Format, Args) ->
    Timestamp = lager_util:format_time(Time),
    Msg = [["[", atom_to_list(Level), "] "],
           io_lib:format("~p@~p:~p:~p ", [Pid, Module, Function, Line]),
           safe_format_chop(Format, Args, 4096)],
    safe_notify(lager_util:level_to_num(Level), Timestamp, Msg).

%% @doc Manually log a message into lager without using the parse transform.
-spec log(log_level(), pid(), list()) -> ok | {error, lager_not_running}.
log(Level, Pid, Message) ->
    Timestamp = lager_util:format_time(),
    Msg = [["[", atom_to_list(Level), "] "], io_lib:format("~p ", [Pid]),
           safe_format_chop("~s", [Message], 4096)],
    safe_notify(lager_util:level_to_num(Level), Timestamp, Msg).

%% @doc Manually log a message into lager without using the parse transform.
-spec log(log_level(), pid(), string(), list()) -> ok | {error, lager_not_running}.
log(Level, Pid, Format, Args) ->
    Timestamp = lager_util:format_time(),
    Msg = [["[", atom_to_list(Level), "] "], io_lib:format("~p ", [Pid]),
           safe_format_chop(Format, Args, 4096)],
    safe_notify(lager_util:level_to_num(Level), Timestamp, Msg).

%% @doc Set the loglevel for a particular backend.
set_loglevel(Handler, Level) when is_atom(Level) ->
    Reply = gen_event:call(lager_event, Handler, {set_loglevel, Level}, infinity),
    %% recalculate min log level
    MinLog = minimum_loglevel(get_loglevels()),
    lager_mochiglobal:put(loglevel, MinLog),
    Reply.

%% @doc Set the loglevel for a particular backend that has multiple identifiers
%% (eg. the file backend).
set_loglevel(Handler, Ident, Level) when is_atom(Level) ->
    Reply = gen_event:call(lager_event, Handler, {set_loglevel, Ident, Level}, infinity),
    %% recalculate min log level
    MinLog = minimum_loglevel(get_loglevels()),
    lager_mochiglobal:put(loglevel, MinLog),
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

safe_notify(Level, Timestamp, Msg) ->
    case whereis(lager_event) of
        undefined ->
            %% lager isn't running
            {error, lager_not_running};
        Pid ->
            gen_event:sync_notify(Pid, {log, Level, Timestamp, Msg})
    end.

%% @doc Print the format string `Fmt' with `Args' safely with a size
%% limit of `Limit'. If the format string is invalid, or not enough
%% arguments are supplied 'FORMAT ERROR' is printed with the offending
%% arguments. The caller is NOT crashed.

safe_format(Fmt, Args, Limit) ->
    try lager_trunc_io:format(Fmt, Args, Limit) of
        Result -> Result
    catch
        _:_ -> lager_trunc_io:format("FORMAT ERROR: ~p ~p", [Fmt, Args], Limit)
    end.

%% @private
safe_format_chop(Fmt, Args, Limit) ->
    re:replace(safe_format(Fmt, Args, Limit), "\n$", "", [{return, list}]).
