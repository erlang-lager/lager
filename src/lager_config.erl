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

-export([new/0, get/1, get/2, set/2]).

-define(TBL, lager_config).

new() ->
    %% set up the ETS configuration table
    _ = try ets:new(?TBL, [named_table, public, set, {keypos, 1}, {read_concurrency, true}]) of
        _Result ->
            ok
    catch
        error:badarg ->
            ?INT_LOG(warning, "Table ~p already exists", [?TBL])
    end,
    %% use insert_new here so that if we're in an appup we don't mess anything up
    %%
    %% until lager is completely started, allow all messages to go through
    ets:insert_new(?TBL, {loglevel, {element(2, lager_util:config_to_mask(debug)), []}}),
    ok.


get(Key) ->
    case ets:lookup(?TBL, Key) of
        [] ->
            undefined;
        [{Key, Res}] ->
            Res
    end.

get(Key, Default) ->
    try ?MODULE:get(Key) of
        undefined ->
            Default;
        Res ->
            Res
    catch
        _:_ ->
            Default
    end.

set(Key, Value) ->
    ets:insert(?TBL, {Key, Value}).

