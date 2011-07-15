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

%% @doc File backend for lager, with multiple file support.
%% Multiple files are supported, each with the path and the loglevel being
%% configurable. The configuration paramter for this backend is a list of
%% 2-tuples of the form `{FileName, Level}'. This backend supports external log
%% rotation and will re-open handles to files if the inode changes.

-module(lager_file_backend).

-include("lager.hrl").

-behaviour(gen_event).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include_lib("kernel/include/file.hrl").

-export([init/1, handle_call/2, handle_event/2, handle_info/2, terminate/2,
        code_change/3]).

-record(state, {files}).

-record(file, {
        name :: string(),
        level :: integer(),
        fd :: file:io_device(),
        inode :: integer(),
        flap=false :: boolean()
    }).

%% @private
-spec init([{string(), lager:log_level()},...]) -> {ok, #state{}}.
init(LogFiles) ->
    Files = [begin
                case lager_util:open_logfile(Name, true) of
                    {ok, {FD, Inode}} ->
                        #file{name=Name, level=lager_util:level_to_num(Level), fd=FD, inode=Inode};
                    {error, Reason} ->
                        ?INT_LOG(error, "Failed to open log file ~s with error ~s",
                            [Name, file:format_error(Reason)]),
                        #file{name=Name, level=lager_util:level_to_num(Level), flap=true}
                end
        end ||
        {Name, Level} <- LogFiles],
    {ok, #state{files=Files}}.

%% @private
handle_call({set_loglevel, _}, State) ->
    {ok, {error, missing_identifier}, State};
handle_call({set_loglevel, Ident, Level}, #state{files=Files} = State) ->
    case lists:keyfind(Ident, 2, Files) of
        false ->
            %% no such file exists
            {ok, {error, bad_identifier}, State};
        _ ->
            NewFiles = lists:map(
                fun(#file{name=Name} = File) when Name == Ident ->
                        ?INT_LOG(notice, "Changed loglevel of ~s to ~p", [Ident, Level]),
                        File#file{level=lager_util:level_to_num(Level)};
                    (X) -> X
                end, Files),
            {ok, ok, State#state{files=NewFiles}}
    end;
handle_call(get_loglevel, #state{files=Files} = State) ->
    Result = lists:foldl(fun(#file{level=Level}, L) -> erlang:max(Level, L);
            (_, L) -> L end, -1,
        Files),
    {ok, Result, State};
handle_call(_Request, State) ->
    {ok, ok, State}.

%% @private
handle_event({log, Level, Time, Message}, #state{files=Files} = State) ->
    NewFiles = lists:map(
        fun(#file{level=L} = File) when Level =< L ->
                write(File, Level, [Time, " ", Message, "\n"]);
            (File) ->
                File
        end, Files),
    {ok, State#state{files=NewFiles}};
handle_event(_Event, State) ->
    {ok, State}.

%% @private
handle_info(_Info, State) ->
    {ok, State}.

%% @private
terminate(_Reason, State) ->
    %% flush and close any file handles
    lists:foreach(
        fun({_, _, FD, _}) -> file:datasync(FD), file:close(FD);
            (_) -> ok
        end, State#state.files).

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

write(#file{name=Name, fd=FD, inode=Inode, flap=Flap} = File, Level, Msg) ->
    case lager_util:ensure_logfile(Name, FD, Inode, true) of
        {ok, {NewFD, NewInode}} ->
            file:write(NewFD, Msg),
            case Level of
                _ when Level =< ?ERROR ->
                    %% force a sync on any message at error severity or above
                    Flap2 = case file:datasync(NewFD) of
                        {error, Reason2} when Flap == false ->
                            ?INT_LOG(error, "Failed to write log message to file ~s: ~s", [Name, file:format_error(Reason2)]),
                            true;
                        ok ->
                            false;
                        _ ->
                            Flap
                    end,
                    File#file{fd=NewFD, inode=NewInode, flap=Flap2};
                _ -> 
                    File#file{fd=NewFD, inode=NewInode}
            end;
        {error, Reason} ->
            case Flap of
                true ->
                    File;
                _ ->
                    ?INT_LOG(error, "Failed to reopen logfile ~s with error ~s", [Name, file:format_error(Reason)]),
                    File#file{flap=true}
            end
    end.

-ifdef(TEST).

get_loglevel_test() ->
    {ok, Level, _} = handle_call(get_loglevel,
        #state{files=[
                #file{name="foo", level=lager_util:level_to_num(warning), fd=0, inode=0},
                #file{name="bar", level=lager_util:level_to_num(info), fd=0, inode=0}]}),
    ?assertEqual(Level, lager_util:level_to_num(info)),
    {ok, Level2, _} = handle_call(get_loglevel,
        #state{files=[
                #file{name="foo", level=lager_util:level_to_num(warning), fd=0, inode=0},
                #file{name="foo", level=lager_util:level_to_num(critical), fd=0, inode=0},
                #file{name="bar", level=lager_util:level_to_num(error), fd=0, inode=0}]}),
    ?assertEqual(Level2, lager_util:level_to_num(warning)).

rotation_test() ->
    {ok, {FD, Inode}} = lager_util:open_logfile("test.log", true),
    ?assertMatch(#file{name="test.log", level=?DEBUG, fd=FD, inode=Inode},
        write(#file{name="test.log", level=?DEBUG, fd=FD, inode=Inode}, 0, "hello world")),
    file:delete("test.log"),
    Result = write(#file{name="test.log", level=?DEBUG, fd=FD, inode=Inode}, 0, "hello world"),
    %% assert file has changed
    ?assert(#file{name="test.log", level=?DEBUG, fd=FD, inode=Inode} =/= Result),
    ?assertMatch(#file{name="test.log", level=?DEBUG}, Result),
    file:rename("test.log", "test.log.1"),
    Result2 = write(Result, 0, "hello world"),
    %% assert file has changed
    ?assert(Result =/= Result2),
    ?assertMatch(#file{name="test.log", level=?DEBUG}, Result2),
    ok.

-endif.

