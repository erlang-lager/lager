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

%% @doc Helper functions for working with lager's runtime config

-module(lager_config).

-include("lager.hrl").

-export([new/0, new_sink/1, get/1, get/2, set/2,
         global_get/1, global_get/2, global_set/2]).

-define(TBL, lager_config).
-define(GLOBAL, '_global').

%% For multiple sinks, the key is now the registered event name and the old key
%% as a tuple.
%%
%% {{lager_event, loglevel}, Value} instead of {loglevel, Value}

new() ->
    %% set up the ETS configuration table
    _ = try ets:new(?TBL, [named_table, public, set, {keypos, 1}, {read_concurrency, true}]) of
        _Result ->
            ok
    catch
        error:badarg ->
            ?INT_LOG(warning, "Table ~p already exists", [?TBL])
    end,
    new_sink(?DEFAULT_SINK),
    %% Need to be able to find the `lager_handler_watcher' for all handlers
    ets:insert_new(?TBL, {{?GLOBAL, handlers}, []}),
    ok.

new_sink(Sink) ->
    %% use insert_new here so that if we're in an appup we don't mess anything up
    %%
    %% until lager is completely started, allow all messages to go through
    ets:insert_new(?TBL, {{Sink, loglevel}, {element(2, lager_util:config_to_mask(debug)), []}}).

global_get(Key) ->
    global_get(Key, undefined).

global_get(Key, Default) ->
    get({?GLOBAL, Key}, Default).

global_set(Key, Value) ->
    set({?GLOBAL, Key}, Value).


get({_Sink, _Key}=FullKey) ->
    get(FullKey, undefined);
get(Key) ->
    get({?DEFAULT_SINK, Key}, undefined).

get({Sink, Key}, Default) ->
    try
    case ets:lookup(?TBL, {Sink, Key}) of
        [] ->
            Default;
        [{{Sink, Key}, Res}] ->
            Res
    end
    catch
        _:_ ->
            Default
    end;
get(Key, Default) ->
    get({?DEFAULT_SINK, Key}, Default).

set({Sink, Key}, Value) ->
    ets:insert(?TBL, {{Sink, Key}, Value});
set(Key, Value) ->
    set({?DEFAULT_SINK, Key}, Value).
