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
%% 5-tuples of the form
%% `{FileName, Level, RotationSize, RotationDate, RotationCount}'.
%% This backend supports external and internal log
%% rotation and will re-open handles to files if the inode changes. It will
%% also rotate the files itself if the size of the file exceeds the
%% `RotationSize' and keep `RotationCount' rotated files. `RotationDate' is
%% an alternate rotation trigger, based on time. See the README for
%% documentation.

-module(lager_file_backend).

-include("lager.hrl").

-behaviour(gen_event).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").
-endif.

-export([init/1, handle_call/2, handle_event/2, handle_info/2, terminate/2,
        code_change/3]).

-record(state, {files}).

-record(file, {
        name :: string(),
        level :: integer(),
        fd :: file:io_device(),
        inode :: integer(),
        flap=false :: boolean(),
        size = 0 :: integer(),
        date,
        count = 10
    }).

%% @private
-spec init([{string(), lager:log_level()},...]) -> {ok, #state{}}.
init(LogFiles) ->
    Files = [begin
                schedule_rotation(Name, Date),
                case lager_util:open_logfile(Name, true) of
                    {ok, {FD, Inode, _}} ->
                        #file{name=Name, level=lager_util:level_to_num(Level),
                            fd=FD, inode=Inode, size=Size, date=Date, count=Count};
                    {error, Reason} ->
                        ?INT_LOG(error, "Failed to open log file ~s with error ~s",
                            [Name, file:format_error(Reason)]),
                        #file{name=Name, level=lager_util:level_to_num(Level),
                            flap=true, size=Size, date=Date, count=Count}
                end
        end ||
        {Name, Level, Size, Date, Count} <- validate_logfiles(LogFiles)],
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
                        ?INT_LOG(notice, "Changed loglevel of ~s to ~p",
                            [Ident, Level]),
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
handle_event({log, Level, {Date, Time}, Message}, #state{files=Files} = State) ->
    NewFiles = lists:map(
        fun(#file{level=L} = File) when Level =< L ->
                write(File, Level, [Date, " ", Time, " ", Message, "\n"]);
            (File) ->
                File
        end, Files),
    {ok, State#state{files=NewFiles}};
handle_event(_Event, State) ->
    {ok, State}.

%% @private
handle_info({rotate, File}, #state{files=Files} = State) ->
    case lists:keyfind(File, #file.name, Files) of
        false ->
            %% no such file exists
            ?INT_LOG(warning, "Asked to rotate non-existant file ~p", [File]),
            {ok, State};
        #file{name=Name, date=Date, count=Count} ->
            lager_util:rotate_logfile(Name, Count),
            schedule_rotation(Name, Date),
            {ok, State}
    end;
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

write(#file{name=Name, fd=FD, inode=Inode, flap=Flap, size=RotSize,
        count=Count} = File, Level, Msg) ->
    case lager_util:ensure_logfile(Name, FD, Inode, true) of
        {ok, {_, _, Size}} when RotSize /= 0, Size > RotSize ->
            lager_util:rotate_logfile(Name, Count),
            write(File, Level, Msg);
        {ok, {NewFD, NewInode, _}} ->
            file:write(NewFD, Msg),
            case Level of
                _ when Level =< ?ERROR ->
                    %% force a sync on any message at error severity or above
                    Flap2 = case file:datasync(NewFD) of
                        {error, Reason2} when Flap == false ->
                            ?INT_LOG(error, "Failed to write log message to file ~s: ~s",
                                [Name, file:format_error(Reason2)]),
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
                    ?INT_LOG(error, "Failed to reopen logfile ~s with error ~s",
                        [Name, file:format_error(Reason)]),
                    File#file{flap=true}
            end
    end.

validate_logfiles([]) ->
    [];
validate_logfiles([{Name, Level, Size, Date, Count}|T]) ->
    ValidLevel = (lists:member(Level, ?LEVELS)),
    ValidSize = (is_integer(Size) andalso Size >= 0),
    ValidCount = (is_integer(Count) andalso Count >= 0),
    case {ValidLevel, ValidSize, ValidCount} of
        {false, _, _} ->
            ?INT_LOG(error, "Invalid log level of ~p for ~s.",
                [Level, Name]),
            validate_logfiles(T);
        {_, false, _} ->
            ?INT_LOG(error, "Invalid rotation size of ~p for ~s.",
                [Size, Name]),
            validate_logfiles(T);
        {_, _, false} ->
            ?INT_LOG(error, "Invalid rotation count of ~p for ~s.",
                [Count, Name]),
            validate_logfiles(T);
        {true, true, true} ->
            case lager_util:parse_rotation_date_spec(Date) of
                {ok, Spec} ->
                    [{Name, Level, Size, Spec,
                            Count}|validate_logfiles(T)];
                {error, _} when Date == "" ->
                    %% blank ones are fine.
                    [{Name, Level, Size, undefined,
                            Count}|validate_logfiles(T)];
                {error, _} ->
                    ?INT_LOG(error, "Invalid rotation date of ~p for ~s.",
                        [Date, Name]),
                    validate_logfiles(T)
            end
    end;
validate_logfiles([H|T]) ->
    ?INT_LOG(error, "Invalid logfile config ~p.", [H]),
    validate_logfiles(T).

schedule_rotation(_, undefined) ->
    undefined;
schedule_rotation(Name, Date) ->
    erlang:send_after(lager_util:calculate_next_rotation(Date) * 1000, self(), {rotate, Name}).

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
    {ok, {FD, Inode, _}} = lager_util:open_logfile("test.log", true),
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

filesystem_test_() ->
    {foreach,
        fun() ->
                file:write_file("test.log", ""),
                error_logger:tty(false),
                application:load(lager),
                application:set_env(lager, handlers, [{lager_test_backend, info}]),
                application:set_env(lager, error_logger_redirect, false),
                application:start(lager)
        end,
        fun(_) ->
                file:delete("test.log"),
                application:stop(lager),
                application:unload(lager),
                error_logger:tty(true)
        end,
        [
            {"under normal circumstances, file should be opened",
                fun() ->
                        gen_event:add_handler(lager_event, lager_file_backend, [{"test.log", info}]),
                        lager:log(error, self(), "Test message"),
                        {ok, Bin} = file:read_file("test.log"),
                        Pid = pid_to_list(self()),
                        ?assertMatch([_, _, "[error]", Pid, "Test message\n"], re:split(Bin, " ", [{return, list}, {parts, 5}]))
                end
            },
            {"file can't be opened on startup triggers an error message",
                fun() ->
                        {ok, FInfo} = file:read_file_info("test.log"),
                        file:write_file_info("test.log", FInfo#file_info{mode = 0}),
                        gen_event:add_handler(lager_event, lager_file_backend, [{"test.log", info}]),
                        ?assertEqual(1, lager_test_backend:count()),
                        {_Level, _Time, [_, _, Message]} = lager_test_backend:pop(),
                        ?assertEqual("Failed to open log file test.log with error permission denied", lists:flatten(Message))
                end
            },
            {"file that becomes unavailable at runtime should trigger an error message",
                fun() ->
                        gen_event:add_handler(lager_event, lager_file_backend, [{"test.log", info}]),
                        ?assertEqual(0, lager_test_backend:count()),
                        lager:log(error, self(), "Test message"),
                        ?assertEqual(1, lager_test_backend:count()),
                        file:delete("test.log"),
                        file:write_file("test.log", ""),
                        {ok, FInfo} = file:read_file_info("test.log"),
                        file:write_file_info("test.log", FInfo#file_info{mode = 0}),
                        lager:log(error, self(), "Test message"),
                        timer:sleep(100),
                        ?assertEqual(3, lager_test_backend:count()),
                        lager_test_backend:pop(),
                        lager_test_backend:pop(),
                        {_Level, _Time, [_, _, Message]} = lager_test_backend:pop(),
                        ?assertEqual("Failed to reopen log file test.log with error permission denied", lists:flatten(Message))
                end
            },
            {"unavailable files that are fixed at runtime should start having log messages written",
                fun() ->
                        {ok, FInfo} = file:read_file_info("test.log"),
                        OldPerms = FInfo#file_info.mode,
                        file:write_file_info("test.log", FInfo#file_info{mode = 0}),
                        gen_event:add_handler(lager_event, lager_file_backend, [{"test.log", info}]),
                        ?assertEqual(1, lager_test_backend:count()),
                        {_Level, _Time, [_, _, Message]} = lager_test_backend:pop(),
                        ?assertEqual("Failed to open log file test.log with error permission denied", lists:flatten(Message)),
                        file:write_file_info("test.log", FInfo#file_info{mode = OldPerms}),
                        lager:log(error, self(), "Test message"),
                        {ok, Bin} = file:read_file("test.log"),
                        Pid = pid_to_list(self()),
                        ?assertMatch([_, _, "[error]", Pid, "Test message\n"], re:split(Bin, " ", [{return, list}, {parts, 5}]))
                end
            },
            {"external logfile rotation/deletion should be handled",
                fun() ->
                        gen_event:add_handler(lager_event, lager_file_backend, [{"test.log", info}]),
                        ?assertEqual(0, lager_test_backend:count()),
                        lager:log(error, self(), "Test message1"),
                        ?assertEqual(1, lager_test_backend:count()),
                        file:delete("test.log"),
                        file:write_file("test.log", ""),
                        lager:log(error, self(), "Test message2"),
                        {ok, Bin} = file:read_file("test.log"),
                        Pid = pid_to_list(self()),
                        ?assertMatch([_, _, "[error]", Pid, "Test message2\n"], re:split(Bin, " ", [{return, list}, {parts, 5}])),
                        file:rename("test.log", "test.log.0"),
                        lager:log(error, self(), "Test message3"),
                        {ok, Bin2} = file:read_file("test.log"),
                        ?assertMatch([_, _, "[error]", Pid, "Test message3\n"], re:split(Bin2, " ", [{return, list}, {parts, 5}]))
                end
            },
            {"runtime level changes",
                fun() ->
                        gen_event:add_handler(lager_event, lager_file_backend, [{"test.log", info}]),
                        ?assertEqual(0, lager_test_backend:count()),
                        lager:log(info, self(), "Test message1"),
                        lager:log(error, self(), "Test message2"),
                        {ok, Bin} = file:read_file("test.log"),
                        Lines = length(re:split(Bin, "\n", [{return, list}, trim])),
                        ?assertEqual(Lines, 2),
                        ?assertEqual(ok, lager:set_loglevel(lager_file_backend, "test.log", warning)),
                        lager:log(info, self(), "Test message3"), %% this won't get logged
                        lager:log(error, self(), "Test message4"),
                        {ok, Bin2} = file:read_file("test.log"),
                        Lines2 = length(re:split(Bin2, "\n", [{return, list}, trim])),
                        ?assertEqual(Lines2, 3)
                end
            },
            {"invalid runtime level changes",
                fun() ->
                        gen_event:add_handler(lager_event, lager_file_backend, [{"test.log", info}]),
                        ?assertEqual({error, bad_identifier}, lager:set_loglevel(lager_file_backend, "test2.log", warning)),
                        ?assertEqual({error, missing_identifier}, lager:set_loglevel(lager_file_backend, warning))
                end
            }

        ]
    }.


-endif.

