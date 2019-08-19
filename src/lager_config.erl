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
         global_get/1, global_get/2, global_set/2, cleanup/0]).

-define(TBL, lager_config).
-define(GLOBAL, '_global').

%% For multiple sinks, the key is now the registered event name and the old key
%% as a tuple.
%%
%% {{lager_event, loglevel}, Value} instead of {loglevel, Value}

new() ->
    init(),
    new_sink(?DEFAULT_SINK),
    %% Need to be able to find the `lager_handler_watcher' for all handlers
    insert_new({?GLOBAL, handlers}, []),
    ok.

new_sink(Sink) ->
    %% use insert_new here so that if we're in an appup we don't mess anything up
    %%
    %% until lager is completely started, allow all messages to go through
    insert_new({Sink, loglevel}, {element(2, lager_util:config_to_mask(debug)), []}).

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
    lookup({Sink, Key}, Default);
get(Key, Default) ->
    get({?DEFAULT_SINK, Key}, Default).

set({Sink, Key}, Value) ->
    insert({Sink, Key}, Value);
set(Key, Value) ->
    set({?DEFAULT_SINK, Key}, Value).

%% check if we can use persistent_term for config
%% persistent term was added in OTP 21.2 but we can't
%% check minor versions with macros so we're stuck waiting
%% for OTP 22
-ifdef(HAVE_PERSISTENT_TERM).
init() ->
    ok.

insert(Key, Value) ->
    persistent_term:put({?TBL, Key}, Value).

insert_new(Key, Value) ->
    try persistent_term:get({?TBL, Key}) of
        _Value ->
            false
    catch error:badarg ->
              insert(Key, Value),
              true
    end.

lookup(Key, Default) ->
    try persistent_term:get({?TBL, Key}) of
        Value -> Value
    catch
        error:badarg ->
            Default
    end.

cleanup() ->
    [ persistent_term:erase(K) || {{?TBL, _} = K, _} <- persistent_term:get() ].

-else.

init() ->
    %% set up the ETS configuration table
    _ = try ets:new(?TBL, [named_table, public, set, {keypos, 1}, {read_concurrency, true}]) of
            _Result ->
                ok
        catch
            error:badarg ->
                ?INT_LOG(warning, "Table ~p already exists", [?TBL])
        end.

insert(Key, Value) ->
    ets:insert(?TBL, {Key, Value}).

insert_new(Key, Value) ->
    ets:insert_new(?TBL, {Key, Value}).

lookup(Key, Default) ->
    try
        case ets:lookup(?TBL, Key) of
            [] ->
                Default;
            [{Key, Res}] ->
                Res
        end
    catch
        _:_ ->
            Default
    end.

cleanup() -> ok.
-endif.

