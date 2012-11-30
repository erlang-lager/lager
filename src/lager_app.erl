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

%% @doc Lager's application module. Not a lot to see here.

%% @private

-module(lager_app).

-behaviour(application).
-include("lager.hrl").
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
-export([start/0,
         start/2,
         stop/1]).

start() ->
    application:start(lager).

start(_StartType, _StartArgs) ->
    %% until lager is completely started, allow all messages to go through
    lager_mochiglobal:put(loglevel, {element(2, lager_util:config_to_mask(debug)), []}),
    {ok, Pid} = lager_sup:start_link(),
    Handlers = case application:get_env(lager, handlers) of
        undefined ->
            [{lager_console_backend, info},
                {lager_file_backend, [{"log/error.log", error, 10485760, "", 5},
                        {"log/console.log", info, 10485760, "", 5}]}];
        {ok, Val} ->
            Val
    end,

    %% handlers failing to start are handled in the handler_watcher
    _ = [supervisor:start_child(lager_handler_watcher_sup, [lager_event, Module, Config]) ||
        {Module, Config} <- expand_handlers(Handlers)],

    %% mask the messages we have no use for
    MinLog = lager:minimum_loglevel(lager:get_loglevels()),
    {_, Traces} = lager_mochiglobal:get(loglevel),
    lager_mochiglobal:put(loglevel, {MinLog, Traces}),

    SavedHandlers = case application:get_env(lager, error_logger_redirect) of
        {ok, false} ->
            [];
        _ ->
            case supervisor:start_child(lager_handler_watcher_sup, [error_logger, error_logger_lager_h, []]) of
              {ok, _} ->
                %% Should we allow user to whitelist handlers to not be removed?
                [begin error_logger:delete_report_handler(X), X end ||
                  X <- gen_event:which_handlers(error_logger) -- [error_logger_lager_h]];
              {error, _} ->
                []
            end
    end,

    {ok, Pid, SavedHandlers}.


stop(Handlers) ->
    lists:foreach(fun(Handler) ->
          error_logger:add_report_handler(Handler)
      end, Handlers).

expand_handlers([]) ->
    [];
expand_handlers([{lager_file_backend, Configs}|T]) ->
    [ to_config(Config) || Config <- Configs] ++
      expand_handlers(T);
expand_handlers([H|T]) ->
    [H | expand_handlers(T)].

to_config({Name,Severity}) ->
    {{lager_file_backend, Name}, {Name, Severity}};
to_config({Name,_Severity,_Size,_Rotation,_Count}=Config) ->
    {{lager_file_backend, Name}, Config};
to_config({Name,Severity,Size,Rotation,Count,Format}) ->
    {{lager_file_backend, Name}, {Name,Severity,Size,Rotation,Count},Format}.



-ifdef(TEST).
application_config_mangling_test_() ->
    [{"Explode the file backend handlers",
            ?_assertMatch(
                [{lager_console_backend, info},
                    {{lager_file_backend,"error.log"},{"error.log",error,10485760, "$D0",5}},
                    {{lager_file_backend,"console.log"},{"console.log",info,10485760, "$D0",5}}
                ],
                expand_handlers([{lager_console_backend, info},
                        {lager_file_backend, [
                                {"error.log", error, 10485760, "$D0", 5},
                                {"console.log", info, 10485760, "$D0", 5}
                            ]}]
                ))},
        {"Explode with formatter info",
            ?_assertMatch(
                [{{lager_file_backend,"test.log"},  {"test.log", debug, 10485760, "$D0", 5},{lager_default_formatter,["[",severity,"] ", message, "\n"]}},
                    {{lager_file_backend,"test2.log"}, {"test2.log",debug, 10485760, "$D0", 5},{lager_default_formatter,["2>[",severity,"] ", message, "\n"]}}],
                expand_handlers([{lager_file_backend, [
                                {"test.log", debug, 10485760, "$D0", 5,{lager_default_formatter,["[",severity,"] ", message, "\n"]}},
                                {"test2.log",debug, 10485760, "$D0", 5,{lager_default_formatter,["2>[",severity,"] ",message, "\n"]}}
                            ]
                        }])
            )
        }].
-endif.
