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

%% @doc Lager's application module. Not a lot to see here.

%% @private

-module(lager_app).

-behaviour(application).

-export([start/0,
         start/2,
         stop/1]).

start() ->
    application:start(lager).

start(_StartType, _StartArgs) ->
    {ok, Pid} = lager_sup:start_link(),
    Handlers = case application:get_env(lager, handlers) of
        undefined ->
            [{lager_console_backend, info},
                {lager_file_backend, [{"log/error.log", error, 10485760, "", 5},
                        {"log/console.log", info, 10485760, "", 5}]}];
        {ok, Val} ->
            Val
    end,
    [supervisor:start_child(lager_handler_watcher_sup, [lager_event, Module, Config]) ||
        {Module, Config} <- Handlers],

    MinLog = lager:minimum_loglevel(lager:get_loglevels()),
    lager_mochiglobal:put(loglevel, MinLog),

    SavedHandlers = case application:get_env(lager, error_logger_redirect) of
        {ok, false} ->
            [];
        _ ->
            supervisor:start_child(lager_handler_watcher_sup, [error_logger, error_logger_lager_h, []]),
            %% Should we allow user to whitelist handlers to not be removed?
            [begin error_logger:delete_report_handler(X), X end ||
                X <- gen_event:which_handlers(error_logger) -- [error_logger_lager_h]]
    end,

    {ok, Pid, SavedHandlers}.


stop(Handlers) ->
    [error_logger:add_report_handler(Handler) || Handler <- Handlers],
    ok.
