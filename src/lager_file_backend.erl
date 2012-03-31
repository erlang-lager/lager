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
-compile([{parse_transform, lager_transform}]).
-endif.

-export([init/1, handle_call/2, handle_event/2, handle_info/2, terminate/2,
        code_change/3]).

-record(state, {
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
init(LogFile) ->
    case validate_logfile(LogFile) of
        {Name, Level, Size, Date, Count} -> 
            schedule_rotation(Name, Date),
            State = case lager_util:open_logfile(Name, true) of
                {ok, {FD, Inode, _}} ->
                    #state{name=Name, level=lager_util:level_to_num(Level),
                        fd=FD, inode=Inode, size=Size, date=Date, count=Count};
                {error, Reason} ->
                    ?INT_LOG(error, "Failed to open log file ~s with error ~s",
                        [Name, file:format_error(Reason)]),
                    #state{name=Name, level=lager_util:level_to_num(Level),
                        flap=true, size=Size, date=Date, count=Count}
            end,
            {ok, State};
        false ->
            ignore
    end.

%% @private
handle_call({set_loglevel, Level}, #state{name=Ident} = State) ->
    ?INT_LOG(notice, "Changed loglevel of ~s to ~p", [Ident, Level]),
    {ok, ok, State#state{level=lager_util:level_to_num(Level)}};
handle_call(get_loglevel, #state{level=Level} = State) ->
    {ok, Level, State};
handle_call(_Request, State) ->
    {ok, ok, State}.

%% @private
handle_event({log, Dest, Level, {Date, Time}, Message},
    #state{name=Name, level=L} = State) when Level > L ->
    case lists:member({lager_file_backend, Name}, Dest) of
        true ->
            {ok, write(State, Level, [Date, " ", Time, " ", Message, "\n"])};
        false ->
            {ok, State}
    end;
handle_event({log, Level, {Date, Time}, Message}, #state{level=L} = State) when Level =< L->
    NewState = write(State, Level, [Date, " ", Time, " ", Message, "\n"]),
    {ok, NewState};
handle_event(_Event, State) ->
    {ok, State}.

%% @private
handle_info({rotate, File}, #state{name=File,count=Count,date=Date} = State) ->
    lager_util:rotate_logfile(File, Count),
    schedule_rotation(File, Date),
    {ok, State};
handle_info(_Info, State) ->
    {ok, State}.

%% @private
terminate(_Reason, #state{fd=FD}) ->
    %% flush and close any file handles
    _ = file:datasync(FD),
    _ = file:close(FD),
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

write(#state{name=Name, fd=FD, inode=Inode, flap=Flap, size=RotSize,
        count=Count} = State, Level, Msg) ->
    case lager_util:ensure_logfile(Name, FD, Inode, true) of
        {ok, {_, _, Size}} when RotSize /= 0, Size > RotSize ->
            lager_util:rotate_logfile(Name, Count),
            write(State, Level, Msg);
        {ok, {NewFD, NewInode, _}} ->
            %% delayed_write doesn't report errors
            _ = file:write(NewFD, Msg),
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
                    State#state{fd=NewFD, inode=NewInode, flap=Flap2};
                _ -> 
                    State#state{fd=NewFD, inode=NewInode}
            end;
        {error, Reason} ->
            case Flap of
                true ->
                    State;
                _ ->
                    ?INT_LOG(error, "Failed to reopen log file ~s with error ~s",
                        [Name, file:format_error(Reason)]),
                    State#state{flap=true}
            end
    end.

validate_logfile({Name, Level}) ->
    case lists:member(Level, ?LEVELS) of
        true ->
            {Name, Level, 0, undefined, 0};
        _ ->
            ?INT_LOG(error, "Invalid log level of ~p for ~s.",
                [Level, Name]),
            false
    end;
validate_logfile({Name, Level, Size, Date, Count}) ->
    ValidLevel = (lists:member(Level, ?LEVELS)),
    ValidSize = (is_integer(Size) andalso Size >= 0),
    ValidCount = (is_integer(Count) andalso Count >= 0),
    case {ValidLevel, ValidSize, ValidCount} of
        {false, _, _} ->
            ?INT_LOG(error, "Invalid log level of ~p for ~s.",
                [Level, Name]),
            false;
        {_, false, _} ->
            ?INT_LOG(error, "Invalid rotation size of ~p for ~s.",
                [Size, Name]),
            false;
        {_, _, false} ->
            ?INT_LOG(error, "Invalid rotation count of ~p for ~s.",
                [Count, Name]),
            false;
        {true, true, true} ->
            case lager_util:parse_rotation_date_spec(Date) of
                {ok, Spec} ->
                    {Name, Level, Size, Spec, Count};
                {error, _} when Date == "" ->
                    %% blank ones are fine.
                    {Name, Level, Size, undefined, Count};
                {error, _} ->
                    ?INT_LOG(error, "Invalid rotation date of ~p for ~s.",
                        [Date, Name]),
                    false
            end
    end;
validate_logfile(H) ->
    ?INT_LOG(error, "Invalid log file config ~p.", [H]),
    false.

schedule_rotation(_, undefined) ->
    ok;
schedule_rotation(Name, Date) ->
    erlang:send_after(lager_util:calculate_next_rotation(Date) * 1000, self(), {rotate, Name}),
    ok.

-ifdef(TEST).

get_loglevel_test() ->
    {ok, Level, _} = handle_call(get_loglevel,
        #state{name="bar", level=lager_util:level_to_num(info), fd=0, inode=0}),
    ?assertEqual(Level, lager_util:level_to_num(info)),
    {ok, Level2, _} = handle_call(get_loglevel,
        #state{name="foo", level=lager_util:level_to_num(warning), fd=0, inode=0}),
    ?assertEqual(Level2, lager_util:level_to_num(warning)).

rotation_test() ->
    {ok, {FD, Inode, _}} = lager_util:open_logfile("test.log", true),
    ?assertMatch(#state{name="test.log", level=?DEBUG, fd=FD, inode=Inode},
        write(#state{name="test.log", level=?DEBUG, fd=FD, inode=Inode}, 0, "hello world")),
    file:delete("test.log"),
    Result = write(#state{name="test.log", level=?DEBUG, fd=FD, inode=Inode}, 0, "hello world"),
    %% assert file has changed
    ?assert(#state{name="test.log", level=?DEBUG, fd=FD, inode=Inode} =/= Result),
    ?assertMatch(#state{name="test.log", level=?DEBUG}, Result),
    file:rename("test.log", "test.log.1"),
    Result2 = write(Result, 0, "hello world"),
    %% assert file has changed
    ?assert(Result =/= Result2),
    ?assertMatch(#state{name="test.log", level=?DEBUG}, Result2),
    ok.

filesystem_test_() ->
    {foreach,
        fun() ->
                file:write_file("test.log", ""),
                error_logger:tty(false),
                application:load(lager),
                application:set_env(lager, handlers, [{lager_test_backend, info}]),
                application:set_env(lager, error_logger_redirect, false),
                application:start(compiler),
                application:start(syntax_tools),
                application:start(lager)
        end,
        fun(_) ->
                file:delete("test.log"),
                application:stop(lager),
                error_logger:tty(true)
        end,
        [
            {"under normal circumstances, file should be opened",
                fun() ->
                        gen_event:add_handler(lager_event, lager_file_backend, {"test.log", info}),
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
                        gen_event:add_handler(lager_event, lager_file_backend, {"test.log", info}),
                        ?assertEqual(1, lager_test_backend:count()),
                        {_Level, _Time, [_, _, Message]} = lager_test_backend:pop(),
                        ?assertEqual("Failed to open log file test.log with error permission denied", lists:flatten(Message))
                end
            },
            {"file that becomes unavailable at runtime should trigger an error message",
                fun() ->
                        gen_event:add_handler(lager_event, lager_file_backend, {"test.log", info}),
                        ?assertEqual(0, lager_test_backend:count()),
                        lager:log(error, self(), "Test message"),
                        ?assertEqual(1, lager_test_backend:count()),
                        file:delete("test.log"),
                        file:write_file("test.log", ""),
                        {ok, FInfo} = file:read_file_info("test.log"),
                        file:write_file_info("test.log", FInfo#file_info{mode = 0}),
                        lager:log(error, self(), "Test message"),
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
                        gen_event:add_handler(lager_event, lager_file_backend, {"test.log", info}),
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
                        gen_event:add_handler(lager_event, lager_file_backend, {"test.log", info}),
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
                        gen_event:add_handler(lager_event, {lager_file_backend, "test.log"}, {"test.log", info}),
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
                        gen_event:add_handler(lager_event, lager_file_backend, {"test.log", info}),
                        gen_event:add_handler(lager_event, lager_file_backend, {"test3.log", info}),
                        ?assertEqual({error, bad_module}, lager:set_loglevel(lager_file_backend, "test.log", warning))
                end
            },
            {"tracing should work",
                fun() ->
                        gen_event:add_handler(lager_event, lager_file_backend,
                            {"test.log", critical}),
                        lager:error("Test message"),
                        ?assertEqual({ok, <<>>}, file:read_file("test.log")),
                        {Level, _} = lager_mochiglobal:get(loglevel),
                        lager_mochiglobal:put(loglevel, {Level, [{[{module,
                                                ?MODULE}], ?DEBUG,
                                        {lager_file_backend, "test.log"}}]}),
                        lager:error("Test message"),
                        {ok, Bin} = file:read_file("test.log"),
                        ?assertMatch([_, _, "[error]", _, "Test message\n"], re:split(Bin, " ", [{return, list}, {parts, 5}]))
                end
            },
            {"tracing should not duplicate messages",
                fun() ->
                        gen_event:add_handler(lager_event, lager_file_backend,
                            {"test.log", critical}),
                        lager:critical("Test message"),
                        {ok, Bin1} = file:read_file("test.log"),
                        ?assertMatch([_, _, "[critical]", _, "Test message\n"], re:split(Bin1, " ", [{return, list}, {parts, 5}])),
                        ok = file:delete("test.log"),
                        {Level, _} = lager_mochiglobal:get(loglevel),
                        lager_mochiglobal:put(loglevel, {Level, [{[{module,
                                                ?MODULE}], ?DEBUG,
                                        {lager_file_backend, "test.log"}}]}),
                        lager:critical("Test message"),
                        {ok, Bin2} = file:read_file("test.log"),
                        ?assertMatch([_, _, "[critical]", _, "Test message\n"], re:split(Bin2, " ", [{return, list}, {parts, 5}])),
                        ok = file:delete("test.log"),
                        lager:error("Test message"),
                        {ok, Bin3} = file:read_file("test.log"),
                        ?assertMatch([_, _, "[error]", _, "Test message\n"], re:split(Bin3, " ", [{return, list}, {parts, 5}]))
                end
            },
            {"tracing to a dedicated file should work",
                fun() ->
                        file:delete("foo.log"),
                        {ok, _} = lager:trace_file("foo.log", [{module, ?MODULE}]),
                        lager:error("Test message"),
                        {ok, Bin3} = file:read_file("foo.log"),
                        ?assertMatch([_, _, "[error]", _, "Test message\n"], re:split(Bin3, " ", [{return, list}, {parts, 5}]))
                end
            }
        ]
    }.


-endif.

