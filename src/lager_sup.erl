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
    Children = [
        {lager, {gen_event, start_link, [{local, lager_event}]},
            permanent, 5000, worker, [dynamic]},
        {lager_handler_watcher_sup, {lager_handler_watcher_sup, start_link, []},
            permanent, 5000, supervisor, [lager_handler_watcher_sup]}],

    %% check if the crash log is enabled
    Crash = case application:get_env(lager, crash_log) of
        {ok, undefined} ->
            [];
        {ok, File} ->
            MaxBytes = case application:get_env(lager, crash_log_msg_size) of
                {ok, Val} when is_integer(Val) andalso Val > 0 -> Val;
                _ -> 65536
            end,
            RotationSize = case application:get_env(lager, crash_log_size) of
                {ok, Val1} when is_integer(Val1) andalso Val1 >= 0 -> Val1;
                _ -> 0
            end,
            RotationCount = case application:get_env(lager, crash_log_count) of
                {ok, Val2} when is_integer(Val2) andalso Val2 >=0 -> Val2;
                _ -> 0
            end,
            RotationDate = case application:get_env(lager, crash_log_date) of
                {ok, Val3} ->
                    case lager_util:parse_rotation_date_spec(Val3) of
                        {ok, Spec} -> Spec;
                        {error, _} when Val3 == "" -> undefined; %% blank is ok
                        {error, _} ->
                            error_logger:error_msg("Invalid date spec for "
                                "crash log ~p~n", [Val3]),
                            undefined
                    end;
                _ -> undefined
            end,

            [{lager_crash_log, {lager_crash_log, start_link, [File, MaxBytes,
                        RotationSize, RotationDate, RotationCount]},
                    permanent, 5000, worker, [lager_crash_log]}];
        _ ->
            []
    end,

    {ok, {{one_for_one, 10, 60},
            Children ++ Crash
            }}.
