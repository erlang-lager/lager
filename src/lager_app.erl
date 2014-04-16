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
    {ok, Pid} = lager_sup:start_link(),


    case application:get_env(lager, async_threshold) of
        undefined ->
            ok;
        {ok, undefined} ->
            undefined;
        {ok, Threshold} when is_integer(Threshold), Threshold >= 0 ->
            DefWindow = erlang:trunc(Threshold * 0.2), % maybe 0?
            ThresholdWindow =
                case application:get_env(lager, async_threshold_window) of
                    undefined ->
                        DefWindow;
                    {ok, Window} when is_integer(Window), Window < Threshold, Window >= 0 ->
                        Window;
                    {ok, BadWindow} ->
                        error_logger:error_msg(
                          "Invalid value for 'async_threshold_window': ~p~n", [BadWindow]),
                        throw({error, bad_config})
                end,
            _ = supervisor:start_child(lager_handler_watcher_sup,
                                       [lager_event, lager_backend_throttle, [Threshold, ThresholdWindow]]),
            ok;
        {ok, BadThreshold} ->
            error_logger:error_msg("Invalid value for 'async_threshold': ~p~n", [BadThreshold]),
            throw({error, bad_config})
    end,

    Handlers = case application:get_env(lager, handlers) of
        undefined ->
            [{lager_console_backend, info},
             {lager_file_backend, [{file, "log/error.log"},   {level, error}, {size, 10485760}, {date, "$D0"}, {count, 5}]},
             {lager_file_backend, [{file, "log/console.log"}, {level, info}, {size, 10485760}, {date, "$D0"}, {count, 5}]}];
        {ok, Val} ->
            Val
    end,

    %% handlers failing to start are handled in the handler_watcher
    _ = [supervisor:start_child(lager_handler_watcher_sup, [lager_event, Module, Config]) ||
        {Module, Config} <- expand_handlers(Handlers)],

    ok = add_configured_traces(),

    %% mask the messages we have no use for
    lager:update_loglevel_config(),

    HighWaterMark = case application:get_env(lager, error_logger_hwm) of
        {ok, undefined} ->
            undefined;
        {ok, HwmVal} when is_integer(HwmVal), HwmVal > 0 ->
            HwmVal;
        {ok, BadVal} ->
            _ = lager:log(warning, self(), "Invalid error_logger high water mark: ~p, disabling", [BadVal]),
            undefined;
        undefined ->
            undefined
    end,

    SavedHandlers =
        case application:get_env(lager, error_logger_redirect) of
            {ok, false} ->
                [];
            _ ->
                WhiteList = case application:get_env(lager, error_logger_whitelist) of
                    undefined ->
                        [];
                    {ok, WhiteList0} ->
                        WhiteList0
                end,

                case supervisor:start_child(lager_handler_watcher_sup, [error_logger, error_logger_lager_h, [HighWaterMark]]) of
                    {ok, _} ->
                        [begin error_logger:delete_report_handler(X), X end ||
                            X <- gen_event:which_handlers(error_logger) -- [error_logger_lager_h | WhiteList]];
                    {error, _} ->
                        []
                end
        end,

    _ = lager_util:trace_filter(none), 

    {ok, Pid, SavedHandlers}.


stop(Handlers) ->
    lists:foreach(fun(Handler) ->
          error_logger:add_report_handler(Handler)
      end, Handlers).

expand_handlers([]) ->
    [];
expand_handlers([{lager_file_backend, [{Key, _Value}|_]=Config}|T]) when is_atom(Key) ->
    %% this is definitely a new-style config, no expansion needed
    [maybe_make_handler_id(lager_file_backend, Config) | expand_handlers(T)];
expand_handlers([{lager_file_backend, Configs}|T]) ->
    ?INT_LOG(notice, "Deprecated lager_file_backend config detected, please consider updating it", []),
    [ {lager_file_backend:config_to_id(Config), Config} || Config <- Configs] ++
      expand_handlers(T);
expand_handlers([{Mod, Config}|T]) when is_atom(Mod) ->
    [maybe_make_handler_id(Mod, Config) | expand_handlers(T)];
expand_handlers([H|T]) ->
    [H | expand_handlers(T)].

add_configured_traces() ->
    Traces = case application:get_env(lager, traces) of
        undefined ->
            [];
        {ok, TraceVal} ->
            TraceVal
    end,

    lists:foreach(fun({Handler, Filter, Level}) ->
                {ok, _} = lager:trace(Handler, Filter, Level)
        end,
        Traces),
    ok.

maybe_make_handler_id(Mod, Config) ->
    %% Allow the backend to generate a gen_event handler id, if it wants to.
    %% We don't use erlang:function_exported here because that requires the module 
    %% already be loaded, which is unlikely at this phase of startup. Using code:load
    %% caused undesireable side-effects with generating code-coverage reports.
    try Mod:config_to_id(Config) of
        Id ->
            {Id, Config}
    catch
        error:undef ->
            {Mod, Config}
    end.

-ifdef(TEST).
application_config_mangling_test_() ->
    [
        {"Explode the file backend handlers",
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
                ))
        },
        {"Explode the short form of backend file handlers",
            ?_assertMatch(
                [{lager_console_backend, info},
                    {{lager_file_backend,"error.log"},{"error.log",error}},
                    {{lager_file_backend,"console.log"},{"console.log",info}}
                ],
                expand_handlers([{lager_console_backend, info},
                        {lager_file_backend, [
                                {"error.log", error},
                                {"console.log", info}
                            ]}]
                ))
        },
        {"Explode with formatter info",
            ?_assertMatch(
                [{{lager_file_backend,"test.log"},  [{"test.log", debug, 10485760, "$D0", 5},{lager_default_formatter,["[",severity,"] ", message, "\n"]}]},
                    {{lager_file_backend,"test2.log"}, [{"test2.log",debug, 10485760, "$D0", 5},{lager_default_formatter,["2>[",severity,"] ", message, "\n"]}]}],
                expand_handlers([{lager_file_backend, [
                                [{"test.log", debug, 10485760, "$D0", 5},{lager_default_formatter,["[",severity,"] ", message, "\n"]}],
                                [{"test2.log",debug, 10485760, "$D0", 5},{lager_default_formatter,["2>[",severity,"] ",message, "\n"]}]
                            ]
                        }])
            )
        },
        {"Explode short form with short formatter info",
            ?_assertMatch(
                [{{lager_file_backend,"test.log"},  [{"test.log", debug},{lager_default_formatter,["[",severity,"] ", message, "\n"]}]},
                    {{lager_file_backend,"test2.log"}, [{"test2.log",debug},{lager_default_formatter}]}],
                expand_handlers([{lager_file_backend, [
                                [{"test.log", debug},{lager_default_formatter,["[",severity,"] ", message, "\n"]}],
                                [{"test2.log",debug},{lager_default_formatter}]
                            ]
                        }])
            )
        },
        {"New form needs no expansion",
            ?_assertMatch([
                    {{lager_file_backend,"test.log"},  [{file, "test.log"}]},
                    {{lager_file_backend,"test2.log"}, [{file, "test2.log"}, {level, info}, {sync_on, none}]},
                    {{lager_file_backend,"test3.log"}, [{formatter, lager_default_formatter}, {file, "test3.log"}]}
                ],
                expand_handlers([
                        {lager_file_backend, [{file, "test.log"}]},
                        {lager_file_backend, [{file, "test2.log"}, {level, info}, {sync_on, none}]},
                        {lager_file_backend, [{formatter, lager_default_formatter},{file, "test3.log"}]}
                    ])
            )
        }
    ].
-endif.
