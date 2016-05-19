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
-compile([export_all]).
-include_lib("eunit/include/eunit.hrl").
-endif.
-export([start/0,
         start/2,
         start_handler/3,
         configure_sink/2,
         stop/1,
         boot/1]).

%% The `application:get_env/3` compatibility wrapper is useful
%% for other modules
-export([get_env/3]).

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

determine_async_behavior(_Sink, undefined, _Window) ->
    ok;
determine_async_behavior(_Sink, Threshold, _Window) when not is_integer(Threshold) orelse Threshold < 0 ->
    error_logger:error_msg("Invalid value for 'async_threshold': ~p~n",
                           [Threshold]),
    throw({error, bad_config});
determine_async_behavior(Sink, Threshold, undefined) ->
    start_throttle(Sink, Threshold, erlang:trunc(Threshold * 0.2));
determine_async_behavior(_Sink, Threshold, Window) when not is_integer(Window) orelse Window > Threshold orelse Window < 0 ->
    error_logger:error_msg(
      "Invalid value for 'async_threshold_window': ~p~n", [Window]),
    throw({error, bad_config});
determine_async_behavior(Sink, Threshold, Window) ->
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
interpret_hwm(HWM) when not is_integer(HWM) orelse HWM < 0 ->
    _ = lager:log(warning, self(), "Invalid error_logger high water mark: ~p, disabling", [HWM]),
    undefined;
interpret_hwm(HWM) ->
    HWM.

maybe_install_sink_killer(_Sink, undefined, _ReinstallTimer) -> ok;
maybe_install_sink_killer(Sink, HWM, undefined) -> maybe_install_sink_killer(Sink, HWM, 5000);
maybe_install_sink_killer(Sink, HWM, ReinstallTimer) when is_integer(HWM) andalso is_integer(ReinstallTimer) 
                                                        andalso HWM >= 0 andalso ReinstallTimer >= 0 ->
    _ = supervisor:start_child(lager_handler_watcher_sup, [Sink, lager_manager_killer, 
                                                           [HWM, ReinstallTimer]]);
maybe_install_sink_killer(_Sink, HWM, ReinstallTimer) ->
    error_logger:error_msg("Invalid value for 'killer_hwm': ~p or 'killer_reinstall_after': ~p", [HWM, ReinstallTimer]),
    throw({error, bad_config}).

-spec start_error_logger_handler(boolean(), pos_integer(), list()) -> list().
start_error_logger_handler(false, _HWM, _Whitelist) ->
    [];
start_error_logger_handler(true, HWM, WhiteList) ->
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


    _ = case supervisor:start_child(lager_handler_watcher_sup, [error_logger, error_logger_lager_h, [HWM, GlStrategy]]) of
        {ok, _} ->
            [begin error_logger:delete_report_handler(X), X end ||
                X <- gen_event:which_handlers(error_logger) -- [error_logger_lager_h | WhiteList]];
        {error, _} ->
            []
    end,

    Handlers = case application:get_env(lager, handlers) of
        undefined ->
            [{lager_console_backend, info},
             {lager_file_backend, [{file, "log/error.log"},   {level, error}, {size, 10485760}, {date, "$D0"}, {count, 5}]},
             {lager_file_backend, [{file, "log/console.log"}, {level, info}, {size, 10485760}, {date, "$D0"}, {count, 5}]}];
        {ok, Val} ->
            Val
    end,
    Handlers.

configure_sink(Sink, SinkDef) ->
    lager_config:new_sink(Sink),
    ChildId = lager_util:make_internal_sink_name(Sink),
    _ = supervisor:start_child(lager_sup,
                               {ChildId,
                                {gen_event, start_link,
                                 [{local, Sink}]},
                                permanent, 5000, worker, dynamic}),
    determine_async_behavior(Sink, proplists:get_value(async_threshold, SinkDef),
                             proplists:get_value(async_threshold_window, SinkDef)
                            ),
    _ = maybe_install_sink_killer(Sink, proplists:get_value(killer_hwm, SinkDef), 
                              proplists:get_value(killer_reinstall_after, SinkDef)),
    start_handlers(Sink,
                   proplists:get_value(handlers, SinkDef, [])),

    lager:update_loglevel_config(Sink).


configure_extra_sinks(Sinks) ->
    lists:foreach(fun({Sink, Proplist}) -> configure_sink(Sink, Proplist) end,
                  Sinks).

-spec get_env(atom(), atom()) -> term().
get_env(Application, Key) ->
    get_env(Application, Key, undefined).

%% R15 doesn't know about application:get_env/3
-spec get_env(atom(), atom(), term()) -> term().
get_env(Application, Key, Default) ->
    get_env_default(application:get_env(Application, Key), Default).

-spec get_env_default('undefined' | {'ok', term()}, term()) -> term().
get_env_default(undefined, Default) ->
    Default;
get_env_default({ok, Value}, _Default) ->
    Value.

start(_StartType, _StartArgs) ->
    {ok, Pid} = lager_sup:start_link(),
    SavedHandlers = boot(),
    _ = boot('__all_extra'),
    _ = boot('__traces'),
    clean_up_config_checks(),
    {ok, Pid, SavedHandlers}.

boot() ->
    %% Handle the default sink.
    determine_async_behavior(?DEFAULT_SINK,
                             get_env(lager, async_threshold),
                             get_env(lager, async_threshold_window)),

    _ = maybe_install_sink_killer(?DEFAULT_SINK, get_env(lager, killer_hwm), 
                              get_env(lager, killer_reinstall_after)),

    start_handlers(?DEFAULT_SINK,
                   get_env(lager, handlers, ?DEFAULT_HANDLER_CONF)),

    lager:update_loglevel_config(?DEFAULT_SINK),

    SavedHandlers = start_error_logger_handler(
                      get_env(lager, error_logger_redirect, true),
                      interpret_hwm(get_env(lager, error_logger_hwm, 0)),
                      get_env(lager, error_logger_whitelist, [])
                     ),

    SavedHandlers.

boot('__traces') ->
    _ = lager_util:trace_filter(none),
    ok = add_configured_traces();

boot('__all_extra') ->
    configure_extra_sinks(get_env(lager, extra_sinks, []));

boot(?DEFAULT_SINK) -> boot();
boot(Sink) ->
    AllSinksDef = get_env(lager, extra_sinks, []),
    boot_sink(Sink, lists:keyfind(Sink, 1, AllSinksDef)).

boot_sink(Sink, {Sink, Def}) ->
    configure_sink(Sink, Def);
boot_sink(Sink, false) ->
    configure_sink(Sink, []).

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

    lists:foreach(fun start_configured_trace/1, Traces),
    ok.

start_configured_trace({Handler, Filter}) ->
    {ok, _} = lager:trace(Handler, Filter);
start_configured_trace({Handler, Filter, Level}) when is_atom(Level) ->
    {ok, _} = lager:trace(Handler, Filter, Level).

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
