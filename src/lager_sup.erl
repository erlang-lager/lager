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

%% @doc Lager's top level supervisor.

%% @private

-module(lager_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Callbacks
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    %% set up the config, is safe even during relups
    lager_config:new(),
    %% TODO:
    %% Always start lager_event as the default and make sure that 
    %% other gen_event stuff can start up as needed 
    %%
    %% Maybe a new API to handle the sink and its policy?
    Children = [
        {lager, {gen_event, start_link, [{local, lager_event}]},
            permanent, 5000, worker, dynamic},
        {lager_handler_watcher_sup, {lager_handler_watcher_sup, start_link, []},
            permanent, 5000, supervisor, [lager_handler_watcher_sup]}],

    CrashLog = decide_crash_log(lager_app:get_env(lager, crash_log, false)),

    {ok, {{one_for_one, 10, 60},
          Children ++ CrashLog
         }}.

validate_positive({ok, Val}, _Default) when is_integer(Val) andalso Val >= 0 ->
    Val;
validate_positive(_Val, Default) ->
    Default.

determine_rotation_date({ok, ""}) ->
    undefined;
determine_rotation_date({ok, Val3}) ->
    case lager_util:parse_rotation_date_spec(Val3) of
        {ok, Spec} -> Spec;
        {error, _} ->
            error_logger:error_msg("Invalid date spec for "
                                   "crash log ~p~n", [Val3]),
            undefined
    end;
determine_rotation_date(_) ->
    undefined.

decide_crash_log(false) ->
    [];
decide_crash_log(File) ->
    MaxBytes = validate_positive(application:get_env(lager, crash_log_msg_size), 65536),
    RotationSize = validate_positive(application:get_env(lager, crash_log_size), 0),
    RotationCount = validate_positive(application:get_env(lager, crash_log_count), 0),

    RotationDate = determine_rotation_date(application:get_env(lager, crash_log_date)),


    [{lager_crash_log, {lager_crash_log, start_link, [File, MaxBytes,
                                                      RotationSize, RotationDate, RotationCount]},
      permanent, 5000, worker, [lager_crash_log]}].
