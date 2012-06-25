%% Author: jason
%% Created: Jan 16, 2012
%% Description: TODO: Add description to lager_backend_utils
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
