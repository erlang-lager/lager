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

-module(lager_file_backend).

-behaviour(gen_event).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include_lib("kernel/include/file.hrl").

-compile([{parse_transform, lager_transform}]).

-export([init/1, handle_call/2, handle_event/2, handle_info/2, terminate/2,
        code_change/3]).

-record(state, {files}).

init(LogFiles) ->
    Files = [begin
                case lager_util:open_logfile(Name, true) of
                    {ok, {FD, Inode}} ->
                        {Name, lager_util:level_to_num(Level), FD, Inode};
                    Error ->
                        lager:error("Failed to open log file ~s with error ~p",
                            [Name, Error]),
                        undefined
                end
        end ||
        {Name, Level} <- LogFiles],
    {ok, #state{files=Files}}.

handle_call({set_loglevel, _}, State) ->
    {ok, {error, missing_identifier}, State};
handle_call({set_loglevel, Ident, Level}, #state{files=Files} = State) ->
    case lists:keyfind(Ident, 1, Files) of
        false ->
            %% no such file exists
            {ok, {error, bad_identifier}, State};
        _ ->
            NewFiles = lists:map(
                fun({Name, _, FD, Inode}) when Name == Ident ->
                        lager:notice("Changed loglevel of ~s to ~p", [Ident, Level]),
                        {Ident, lager_util:level_to_num(Level), FD, Inode};
                    (X) -> X
                end, Files),
            {ok, ok, State#state{files=NewFiles}}
    end;
handle_call(get_loglevel, #state{files=Files} = State) ->
    Result = lists:foldl(fun({_, Level, _, _}, L) -> erlang:min(Level, L);
            (_, L) -> L end, 9,
        Files),
    {ok, Result, State};
handle_call(_Request, State) ->
    {ok, ok, State}.

handle_event({log, Level, Time, Message}, #state{files=Files} = State) ->
    NewFiles = lists:map(
        fun({_, L, _, _} = File) when Level >= L ->
                write(File, Level, [Time, " ", Message, "\n"]);
            (File) ->
                File
        end, Files),
    {ok, State#state{files=NewFiles}};
handle_event(_Event, State) ->
    {ok, State}.

handle_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, State) ->
    %% flush and close any file handles
    lists:foreach(
        fun({_, _, FD, _}) -> file:datasync(FD), file:close(FD);
            (_) -> ok
        end, State#state.files).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

write({Name, L, FD, Inode}, Level, Msg) ->
    case lager_util:ensure_logfile(Name, FD, Inode, true) of
        {ok, {NewFD, NewInode}} ->
            file:write(NewFD, Msg),
            case Level of
                _ when Level >= 4 ->
                    %% force a sync on any message at error severity or above
                    file:datasync(NewFD);
                _ -> ok
            end,
            {Name, L, NewFD, NewInode};
        Error ->
            lager:error("Failed to reopen logfile ~s with error ~w", [Name,
                    Error]),
            undefined
    end.

-ifdef(TEST).

get_loglevel_test() ->
    {ok, Level, _} = handle_call(get_loglevel,
        #state{files=[
                {"foo", lager_util:level_to_num(warning), 0, 0},
                {"bar", lager_util:level_to_num(info), 0, 0}]}),
    ?assertEqual(Level, lager_util:level_to_num(info)),
    {ok, Level2, _} = handle_call(get_loglevel,
        #state{files=[
                {"foo", lager_util:level_to_num(warning), 0, 0},
                {"foo", lager_util:level_to_num(critical), 0, 0},
                {"bar", lager_util:level_to_num(error), 0, 0}]}),
    ?assertEqual(Level2, lager_util:level_to_num(warning)).

rotation_test() ->
    {ok, {FD, Inode}} = lager_util:open_logfile("test.log", true),
    ?assertEqual({"test.log", 0, FD, Inode},
        write({"test.log", 0, FD, Inode}, 0, "hello world")),
    file:delete("test.log"),
    Result = write({"test.log", 0, FD, Inode}, 0, "hello world"),
    %% assert file has changed
    ?assert({"test.log", 0, FD, Inode} =/= Result),
    ?assertMatch({"test.log", 0, _, _}, Result),
    file:rename("test.log", "test.log.1"),
    Result2 = write(Result, 0, "hello world"),
    %% assert file has changed
    ?assert(Result =/= Result2),
    ?assertMatch({"test.log", 0, _, _}, Result2),
    ok.

-endif.

