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

-module(lager_util).

-export([levels/0, level_to_num/1]).

levels() ->
    [debug, info, notice, warning, error, critical, alert, emergency].

level_to_num(debug) ->
    0;
level_to_num(info) ->
    1;
level_to_num(notice) ->
    2;
level_to_num(warning) ->
    3;
level_to_num(error) ->
    4;
level_to_num(critical) ->
    5;
level_to_num(alert) ->
    6;
level_to_num(emergency) ->
    7;
level_to_num(_) ->
    0.
