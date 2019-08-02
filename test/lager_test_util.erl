%% -------------------------------------------------------------------
%%
%% Copyright (c) 2011-2017 Basho Technologies, Inc.
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
%%
%% -------------------------------------------------------------------

-module(lager_test_util).

-ifdef(TEST).

-export([safe_application_load/1, safe_write_file/2]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

safe_application_load(App) ->
    case application:load(App) of
        ok ->
            ok;
        {error, {already_loaded, App}} ->
            ok;
        Error ->
            ?assertEqual(ok, Error)
    end.

safe_write_file(File, Content) ->
    % Note: ensures that the new creation time is at least one second
    % in the future
    ?assertEqual(ok, file:write_file(File, Content)),
    Ctime0 = calendar:local_time(),
    Ctime0Sec = calendar:datetime_to_gregorian_seconds(Ctime0),
    Ctime1Sec = Ctime0Sec + 1,
    Ctime1 = calendar:gregorian_seconds_to_datetime(Ctime1Sec),
    {ok, FInfo0} = file:read_file_info(File, [raw]),
    FInfo1 = FInfo0#file_info{ctime = Ctime1},
    ?assertEqual(ok, file:write_file_info(File, FInfo1, [raw])).

-endif.
