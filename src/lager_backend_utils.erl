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

%% @doc  Module containing useful functions for writing lager backends.

-module(lager_backend_utils).

%%
%% Include files
%%
-include_lib("lager/include/lager.hrl").
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%%
%% Exported Functions
%%
-export([is_loggable/3]).

%%
%% API Functions
%%


-spec is_loggable(#lager_log_message{},integer(),term()) -> boolean().
is_loggable(#lager_log_message{severity_as_int=Severity,destinations=Destinations},SeverityThreshold,MyName) ->
    %?debugFmt("is_loggable: Severity=~p, Threshold=~p, Destinations=~p, MyName=~p", [Severity,SeverityThreshold,Destinations,MyName]),
    Severity =< SeverityThreshold orelse lists:member(MyName, Destinations).


-ifdef(TEST).

is_loggable_test_() ->
    [
        {"Loggable by severity only", ?_assert(is_loggable(#lager_log_message{severity_as_int=1,destinations=[]},2,me))},
        {"Not loggable by severity only", ?_assertNot(is_loggable(#lager_log_message{severity_as_int=2,destinations=[]},1,me))},
        {"Loggable by severity with destination", ?_assert(is_loggable(#lager_log_message{severity_as_int=1,destinations=[you]},2,me))},
        {"Not loggable by severity with destination", ?_assertNot(is_loggable(#lager_log_message{severity_as_int=2,destinations=[you]},1,me))},
        {"Loggable by destination overriding severity", ?_assert(is_loggable(#lager_log_message{severity_as_int=2,destinations=[me]},1,me))}
    ].

-endif.
