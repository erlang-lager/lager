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
         start_handler/3,
         stop/1]).

-define(FILENAMES, '__lager_file_backend_filenames').
-define(THROTTLE, lager_backend_throttle).
-define(DEFAULT_HANDLER_CONF,
        [{lager_console_backend, info},
         {lager_file_backend,
          [{file, "log/error.log"}, {level, error},
           {size, 10485760}, {date, "$D0"}, {count, 5}]
         },
         {lager_file_backend,
          [{file, "log/console.log"}, {level, info},
           {size, 10485760}, {date, "$D0"}, {count, 5}]
         }
        ]).

start() ->
    application:start(lager).

start_throttle(Sink, Threshold, Window) ->
    _ = supervisor:start_child(lager_handler_watcher_sup,
                               [Sink, ?THROTTLE, [Threshold, Window]]),
    ok.

determine_async_behavior(_Sink, {ok, undefined}, _Window) ->
    ok;
determine_async_behavior(_Sink, undefined, _Window) ->
    ok;
determine_async_behavior(_Sink, {ok, Threshold}, _Window) when not is_integer(Threshold) orelse Threshold < 0 ->
    error_logger:error_msg("Invalid value for 'async_threshold': ~p~n",
                           [Threshold]),
    throw({error, bad_config});
determine_async_behavior(Sink, {ok, Threshold}, undefined) ->
    start_throttle(Sink, Threshold, erlang:trunc(Threshold * 0.2));
determine_async_behavior(_Sink, {ok, Threshold}, {ok, Window}) when not is_integer(Window) orelse Window > Threshold orelse Window < 0 ->
    error_logger:error_msg(
      "Invalid value for 'async_threshold_window': ~p~n", [Window]),
    throw({error, bad_config});
determine_async_behavior(Sink, {ok, Threshold}, {ok, Window}) ->
    start_throttle(Sink, Threshold, Window).

start_handlers(_Sink, undefined) ->
    ok;
start_handlers(_Sink, Handlers) when not is_list(Handlers) ->
    error_logger:error_msg(
      "Invalid value for 'handlers' (must be list): ~p~n", [Handlers]),
    throw({error, bad_config});
start_handlers(Sink, Handlers) ->
    %% handlers failing to start are handled in the handler_watcher
    lager_config:global_set(handlers,
                            lager_config:global_get(handlers, []) ++
                            lists:map(fun({Module, Config}) ->
                                              check_handler_config(Module, Config),
                                              start_handler(Sink, Module, Config);
                                          (_) ->
                                              throw({error, bad_config})
                                      end,
                                      expand_handlers(Handlers))),
    ok.

start_handler(Sink, Module, Config) ->
    {ok, Watcher} = supervisor:start_child(lager_handler_watcher_sup,
                                           [Sink, Module, Config]),
    {Module, Watcher, Sink}.

check_handler_config({lager_file_backend, F}, Config) when is_list(Config) ->
    Fs = case get(?FILENAMES) of
        undefined -> ordsets:new();
        X -> X
    end,
    case ordsets:is_element(F, Fs) of
        true ->
            error_logger:error_msg(
              "Cannot have same file (~p) in multiple file backends~n", [F]),
            throw({error, bad_config});
        false ->
            put(?FILENAMES,
                ordsets:add_element(F, Fs))
    end,
    ok;
check_handler_config(_Handler, Config) when is_list(Config) orelse is_atom(Config) ->
    ok;
check_handler_config(Handler, _BadConfig) ->
    throw({error, {bad_config, Handler}}).

clean_up_config_checks() ->
    erase(?FILENAMES).

interpret_hwm(undefined) ->
    undefined;
interpret_hwm({ok, undefined}) ->
    undefined;
interpret_hwm({ok, HWM}) when not is_integer(HWM) orelse HWM < 0 ->
    _ = lager:log(warning, self(), "Invalid error_logger high water mark: ~p, disabling", [HWM]),
    undefined;
interpret_hwm({ok, HWM}) ->
    HWM.

start_error_logger_handler({ok, false}, _HWM, _Whitelist) ->
    [];
start_error_logger_handler(_, HWM, undefined) ->
    start_error_logger_handler(ignore_me, HWM, {ok, []});
start_error_logger_handler(_, HWM, {ok, WhiteList}) ->
    GlStrategy = case application:get_env(lager, error_logger_groupleader_strategy) of
                    undefined ->
                        handle;
                    {ok, GlStrategy0} when 
                            GlStrategy0 =:= handle;
                            GlStrategy0 =:= ignore;
                            GlStrategy0 =:= mirror ->
                        GlStrategy0;
                    {ok, BadGlStrategy} ->
                        error_logger:error_msg(
                          "Invalid value for 'error_logger_groupleader_strategy': ~p~n",
                          [BadGlStrategy]),
                        throw({error, bad_config})
                end,

    case supervisor:start_child(lager_handler_watcher_sup, [error_logger, error_logger_lager_h, [HWM, GlStrategy]]) of
        {ok, _} ->
            [begin error_logger:delete_report_handler(X), X end ||
                X <- gen_event:which_handlers(error_logger) -- [error_logger_lager_h | WhiteList]];
        {error, _} ->
            []
    end.

%% `determine_async_behavior/3' is called with the results from either
%% `application:get_env/2' and `proplists:get_value/2'. Since
%% `application:get_env/2' wraps a successful retrieval in an `{ok,
%% Value}' tuple, do the same for the result from
%% `proplists:get_value/2'.
wrap_proplist_value(undefined) ->
    undefined;
wrap_proplist_value(Value) ->
    {ok, Value}.

configure_sink(Sink, SinkDef) ->
    lager_config:new_sink(Sink),
    ChildId = lager_util:make_internal_sink_name(Sink),
    _ = supervisor:start_child(lager_sup,
                               {ChildId,
                                {gen_event, start_link,
                                 [{local, Sink}]},
                                permanent, 5000, worker, dynamic}),
    determine_async_behavior(Sink,
                             wrap_proplist_value(
                               proplists:get_value(async_threshold, SinkDef)),
                             wrap_proplist_value(
                               proplists:get_value(async_threshold_window, SinkDef))
                            ),
    start_handlers(Sink,
                   proplists:get_value(handlers, SinkDef, [])),

    lager:update_loglevel_config(Sink).


configure_extra_sinks(Sinks) ->
    lists:foreach(fun({Sink, Proplist}) -> configure_sink(Sink, Proplist) end,
                  Sinks).

%% R15 doesn't know about application:get_env/3
get_env(Application, Key, Default) ->
    get_env_default(application:get_env(Application, Key),
                    Default).

get_env_default(undefined, Default) ->
    Default;
get_env_default({ok, Value}, _Default) ->
    Value.

start(_StartType, _StartArgs) ->
    {ok, Pid} = lager_sup:start_link(),

    %% Handle the default sink.
    determine_async_behavior(?DEFAULT_SINK,
                             application:get_env(lager, async_threshold),
                             application:get_env(lager, async_threshold_window)),
    start_handlers(?DEFAULT_SINK,
                   get_env(lager, handlers, ?DEFAULT_HANDLER_CONF)),


    lager:update_loglevel_config(?DEFAULT_SINK),

    SavedHandlers = start_error_logger_handler(
                      application:get_env(lager, error_logger_redirect),
                      interpret_hwm(application:get_env(lager, error_logger_hwm)),
                      application:get_env(lager, error_logger_whitelist)
                     ),

    _ = lager_util:trace_filter(none),

    %% Now handle extra sinks
    configure_extra_sinks(get_env(lager, extra_sinks, [])),

    ok = add_configured_traces(),

    clean_up_config_checks(),

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
    %% caused undesirable side-effects with generating code-coverage reports.
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

check_handler_config_test_() ->
    Good = expand_handlers(?DEFAULT_HANDLER_CONF),
    Bad  = expand_handlers([{lager_console_backend, info},
            {lager_file_backend, [{file, "same_file.log"}]},
            {lager_file_backend, [{file, "same_file.log"}, {level, info}]}]),
    AlsoBad = [{lager_logstash_backend,
                                    {level, info},
                                    {output, {udp, "localhost", 5000}},
                                    {format, json},
                                    {json_encoder, jiffy}}],
    BadToo = [{fail, {fail}}],
    [
        {"lager_file_backend_good",
         ?_assertEqual([ok, ok, ok], [ check_handler_config(M,C) || {M,C} <- Good ])
        },
        {"lager_file_backend_bad",
         ?_assertThrow({error, bad_config}, [ check_handler_config(M,C) || {M,C} <- Bad ])
        },
        {"Invalid config dies",
         ?_assertThrow({error, bad_config}, start_handlers(foo, AlsoBad))
        },
        {"Invalid config dies",
         ?_assertThrow({error, {bad_config, _}}, start_handlers(foo, BadToo))
        }
    ].
-endif.
