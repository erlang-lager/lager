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

%% API
-export([start/0,
        log/7, log/8, log/3, log/4,
        get_loglevel/1, set_loglevel/2, set_loglevel/3, get_loglevels/0,
        minimum_loglevel/1]).

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
log(Level, Module, Function, Line, Pid, Time, Message) ->
    Timestamp = lager_util:format_time(Time),
    Msg = [io_lib:format("[~p] ~p@~p:~p:~p ", [Level, Pid, Module,
                Function, Line]),  Message],
    gen_event:sync_notify(lager_event, {log, lager_util:level_to_num(Level),
            Timestamp, Msg}).

%% @private
log(Level, Module, Function, Line, Pid, Time, Format, Args) ->
    Timestamp = lager_util:format_time(Time),
    Msg = [io_lib:format("[~p] ~p@~p:~p:~p ", [Level, Pid, Module,
                Function, Line]), io_lib:format(Format, Args)],
    gen_event:sync_notify(lager_event, {log, lager_util:level_to_num(Level),
            Timestamp, Msg}).

%% @doc Manually log a message into lager without using the parse transform.
log(Level, Pid, Message) ->
    Timestamp = lager_util:format_time(),
    Msg = [io_lib:format("[~p] ~p ", [Level, Pid]), Message],
    gen_event:sync_notify(lager_event, {log, lager_util:level_to_num(Level),
            Timestamp, Msg}).

%% @doc Manually log a message into lager without using the parse transform.
log(Level, Pid, Format, Args) ->
    Timestamp = lager_util:format_time(),
    Msg = [io_lib:format("[~p] ~p ", [Level, Pid]), io_lib:format(Format, Args)],
    gen_event:sync_notify(lager_event, {log, lager_util:level_to_num(Level),
            Timestamp, Msg}).

%% @doc Set the loglevel for a particular backend.
set_loglevel(Handler, Level) when is_atom(Level) ->
    Reply = gen_event:call(lager_event, Handler, {set_loglevel, Level}),
    %% recalculate min log level
    MinLog = minimum_loglevel(get_loglevels()),
    lager_mochiglobal:put(loglevel, MinLog),
    Reply.

%% @doc Set the loglevel for a particular backend that has multiple identifiers
%% (eg. the file backend).
set_loglevel(Handler, Ident, Level) when is_atom(Level) ->
    Reply = gen_event:call(lager_event, Handler, {set_loglevel, Ident, Level}),
    %% recalculate min log level
    MinLog = minimum_loglevel(get_loglevels()),
    lager_mochiglobal:put(loglevel, MinLog),
    Reply.

%% @doc Get the loglevel for a particular backend. In the case that the backend
%% has multiple identifiers, the lowest is returned
get_loglevel(Handler) ->
    case gen_event:call(lager_event, Handler, get_loglevel) of
        X when is_integer(X) ->
            lager_util:num_to_level(X);
        Y -> Y
    end.

%% @private
get_loglevels() ->
    [gen_event:call(lager_event, Handler, get_loglevel) ||
        Handler <- gen_event:which_handlers(lager_event)].

%% @private
minimum_loglevel([]) ->
    9; %% higher than any log level, logging off
minimum_loglevel(Levels) ->
    erlang:hd(lists:sort(Levels)).
