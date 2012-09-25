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

-module(lager_crash_backend).

-include("lager.hrl").

-behaviour(gen_event).

-export([init/1, handle_call/2, handle_event/2, handle_info/2, terminate/2,
        code_change/3]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

init([CrashBefore, CrashAfter]) ->
    case is_tuple(CrashBefore) andalso (timer:now_diff(CrashBefore, os:timestamp()) > 0) of
        true ->
            %?debugFmt("crashing!~n", []),
            {error, crashed};
        _ ->
            %?debugFmt("Not crashing!~n", []),
            case is_tuple(CrashAfter) of
                true ->
                    CrashTime = timer:now_diff(CrashAfter, os:timestamp()) div 1000,
                    case CrashTime > 0 of
                        true ->
                            %?debugFmt("crashing in ~p~n", [CrashTime]),
                            erlang:send_after(CrashTime, self(), crash),
                            {ok, {}};
                        _ -> {error, crashed}
                    end;
                _ ->
                    {ok, {}}
            end
    end.

handle_call(_Request, State) ->
    {ok, ok, State}.

handle_event(_Event, State) ->
    {ok, State}.

handle_info(crash, _State) ->
    %?debugFmt("Time to crash!~n", []),
    crash;
handle_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
