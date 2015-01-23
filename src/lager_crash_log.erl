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

%% @doc Lager crash log writer. This module implements a gen_server which writes
%% error_logger error messages out to a file in their original format. The
%% location to which it logs is configured by the application var `crash_log'.
%% Omitting this variable disables crash logging. Crash logs are printed safely
%% using trunc_io via code mostly lifted from riak_err.
%%
%% The `crash_log_msg_size' application var is used to specify the maximum
%% size of any message to be logged. `crash_log_size' is used to specify the
%% maximum size of the crash log before it will be rotated (0 will disable).
%% Time based rotation is configurable via `crash_log_date', the syntax is
%% documented in the README. To control the number of rotated files to be
%% retained, use `crash_log_count'.

-module(lager_crash_log).

-include("lager.hrl").

-behaviour(gen_server).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").
-endif.

%% callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
        code_change/3]).

-export([start_link/5, start/5]).

-record(state, {
        name :: string(),
        fd :: pid(),
        inode :: integer(),
        fmtmaxbytes :: integer(),
        size :: integer(),
        date :: undefined | string(),
        count :: integer(),
        flap=false :: boolean()
}).

%% @private
start_link(Filename, MaxBytes, Size, Date, Count) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Filename, MaxBytes,
            Size, Date, Count], []).

%% @private
start(Filename, MaxBytes, Size, Date, Count) ->
    gen_server:start({local, ?MODULE}, ?MODULE, [Filename, MaxBytes, Size,
            Date, Count], []).

%% @private
init([RelFilename, MaxBytes, Size, Date, Count]) ->
    Filename = lager_util:expand_path(RelFilename),
    case lager_util:open_logfile(Filename, false) of
        {ok, {FD, Inode, _}} ->
            schedule_rotation(Date),
            {ok, #state{name=Filename, fd=FD, inode=Inode,
                    fmtmaxbytes=MaxBytes, size=Size, count=Count, date=Date}};
        {error, Reason} ->
            ?INT_LOG(error, "Failed to open crash log file ~s with error: ~s",
                [Filename, file:format_error(Reason)]),
            {ok, #state{name=Filename, fmtmaxbytes=MaxBytes, flap=true,
                    size=Size, count=Count, date=Date}}
    end.

%% @private
handle_call({log, _} = Log, _From, State) ->
    {Reply, NewState} = do_log(Log, State),
    {reply, Reply, NewState};
handle_call(_Call, _From, State) ->
    {reply, ok, State}.

%% @private
handle_cast({log, _} = Log, State) ->
    {_, NewState} = do_log(Log, State),
    {noreply, NewState};
handle_cast(_Request, State) ->
    {noreply, State}.

%% @private
handle_info(rotate, #state{name=Name, count=Count, date=Date} = State) ->
    _ = lager_util:rotate_logfile(Name, Count),
    schedule_rotation(Date),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

schedule_rotation(undefined) ->
    ok;
schedule_rotation(Date) ->
    erlang:send_after(lager_util:calculate_next_rotation(Date) * 1000, self(), rotate),
    ok.

%% ===== Begin code lifted from riak_err =====

-spec limited_fmt(string(), list(), integer()) -> iolist().
%% @doc Format Fmt and Args similar to what io_lib:format/2 does but with 
%%      limits on how large the formatted string may be.
%%
%% If the Args list's size is larger than TermMaxSize, then the
%% formatting is done by trunc_io:print/2, where FmtMaxBytes is used
%% to limit the formatted string's size.

limited_fmt(Fmt, Args, FmtMaxBytes) ->
    lager:safe_format(Fmt, Args, FmtMaxBytes).

limited_str(Term, FmtMaxBytes) ->
    {Str, _} = lager_trunc_io:print(Term, FmtMaxBytes),
    Str.

other_node_suffix(Pid) when node(Pid) =/= node() ->
    "** at node " ++ atom_to_list(node(Pid)) ++ " **\n";
other_node_suffix(_) ->
    "".

perhaps_a_sasl_report(error_report, {Pid, Type, Report}, FmtMaxBytes) ->
    case lager_stdlib:is_my_error_report(Type) of
        true ->
            {sasl_type_to_report_head(Type), Pid,
                sasl_limited_str(Type, Report, FmtMaxBytes), true};
        false ->
            {ignore, ignore, ignore, false}
    end;
%perhaps_a_sasl_report(info_report, {Pid, Type, Report}, FmtMaxBytes) ->
    %case lager_stdlib:is_my_info_report(Type) of
        %true ->
            %{sasl_type_to_report_head(Type), Pid,
                %sasl_limited_str(Type, Report, FmtMaxBytes), false};
        %false ->
            %{ignore, ignore, ignore, false}
    %end;
perhaps_a_sasl_report(_, _, _) ->
    {ignore, ignore, ignore, false}.

sasl_type_to_report_head(supervisor_report) ->
    "SUPERVISOR REPORT";
sasl_type_to_report_head(crash_report) ->
    "CRASH REPORT";
sasl_type_to_report_head(progress) ->
    "PROGRESS REPORT".

sasl_limited_str(supervisor_report, Report, FmtMaxBytes) ->
    Name = lager_stdlib:sup_get(supervisor, Report),
    Context = lager_stdlib:sup_get(errorContext, Report),
    Reason = lager_stdlib:sup_get(reason, Report),
    Offender = lager_stdlib:sup_get(offender, Report),
    FmtString = "     Supervisor: ~p~n     Context:    ~p~n     Reason:     "
    "~s~n     Offender:   ~s~n~n",
    {ReasonStr, _} = lager_trunc_io:print(Reason, FmtMaxBytes),
    {OffenderStr, _} = lager_trunc_io:print(Offender, FmtMaxBytes),
    io_lib:format(FmtString, [Name, Context, ReasonStr, OffenderStr]);
sasl_limited_str(progress, Report, FmtMaxBytes) ->
    [begin
                {Str, _} = lager_trunc_io:print(Data, FmtMaxBytes),
                io_lib:format("    ~16w: ~s~n", [Tag, Str])
        end || {Tag, Data} <- Report];
sasl_limited_str(crash_report, Report, FmtMaxBytes) ->
    lager_stdlib:proc_lib_format(Report, FmtMaxBytes).

do_log({log, Event}, #state{name=Name, fd=FD, inode=Inode, flap=Flap,
        fmtmaxbytes=FmtMaxBytes, size=RotSize, count=Count} = State) ->
    %% borrowed from riak_err
    {ReportStr, Pid, MsgStr, _ErrorP} = case Event of
        {error, _GL, {Pid1, Fmt, Args}} ->
            {"ERROR REPORT", Pid1, limited_fmt(Fmt, Args, FmtMaxBytes), true};
        {error_report, _GL, {Pid1, std_error, Rep}} ->
            {"ERROR REPORT", Pid1, limited_str(Rep, FmtMaxBytes) ++ "\n", true};
        {error_report, _GL, Other} ->
            perhaps_a_sasl_report(error_report, Other, FmtMaxBytes);
        _ ->
            {ignore, ignore, ignore, false}
    end,
    if ReportStr == ignore ->
            {ok, State};
        true ->
            case lager_util:ensure_logfile(Name, FD, Inode, false) of
                {ok, {_, _, Size}} when RotSize /= 0, Size > RotSize ->
                    _ = lager_util:rotate_logfile(Name, Count),
                    handle_cast({log, Event}, State);
                {ok, {NewFD, NewInode, _Size}} ->
                    {Date, TS} = lager_util:format_time(
                        lager_stdlib:maybe_utc(erlang:localtime())),
                    Time = [Date, " ", TS," =", ReportStr, "====\n"],
                    NodeSuffix = other_node_suffix(Pid),
                    Msg = io_lib:format("~s~s~s", [Time, MsgStr, NodeSuffix]),
                    case file:write(NewFD, unicode:characters_to_binary(Msg)) of
                        {error, Reason} when Flap == false ->
                            ?INT_LOG(error, "Failed to write log message to file ~s: ~s",
                                [Name, file:format_error(Reason)]),
                            {ok, State#state{fd=NewFD, inode=NewInode, flap=true}};
                        ok ->
                            {ok, State#state{fd=NewFD, inode=NewInode, flap=false}};
                        _ ->
                            {ok, State#state{fd=NewFD, inode=NewInode}}
                    end;
                {error, Reason} ->
                    case Flap of
                        true ->
                            {ok, State};
                        _ ->
                            ?INT_LOG(error, "Failed to reopen crash log ~s with error: ~s",
                                [Name, file:format_error(Reason)]),
                            {ok, State#state{flap=true}}
                    end
            end
    end.


-ifdef(TEST).

filesystem_test_() ->
    {foreach,
        fun() ->
                file:write_file("crash_test.log", ""),
                error_logger:tty(false),
                application:load(lager),
                application:set_env(lager, handlers, [{lager_test_backend, info}]),
                application:set_env(lager, error_logger_redirect, true),
                application:unset_env(lager, crash_log),
                lager:start(),
                timer:sleep(100),
                lager_test_backend:flush()
        end,
        fun(_) ->
                case whereis(lager_crash_log) of
                    P when is_pid(P) ->
                        exit(P, kill);
                    _ -> ok
                end,
                file:delete("crash_test.log"),
                application:stop(lager),
                application:stop(goldrush),
                error_logger:tty(true)
        end,
        [
            {"under normal circumstances, file should be opened",
                fun() ->
                        {ok, _} = ?MODULE:start_link("crash_test.log", 65535, 0, undefined, 0),
                        _ = gen_event:which_handlers(error_logger),
                        sync_error_logger:error_msg("Test message\n"),
                        {ok, Bin} = file:read_file("crash_test.log"),
                        ?assertMatch([_, "Test message\n"], re:split(Bin, "\n", [{return, list}, {parts, 2}]))
                end
            },
            {"file can't be opened on startup triggers an error message",
                fun() ->
                        {ok, FInfo} = file:read_file_info("crash_test.log"),
                        file:write_file_info("crash_test.log", FInfo#file_info{mode = 0}),
                        {ok, _} = ?MODULE:start_link("crash_test.log", 65535, 0, undefined, 0),
                        ?assertEqual(1, lager_test_backend:count()),
                        {_Level, _Time, Message,_Metadata} = lager_test_backend:pop(),
                        ?assertEqual("Failed to open crash log file crash_test.log with error: permission denied", lists:flatten(Message))
                end
            },
            {"file that becomes unavailable at runtime should trigger an error message",
                fun() ->
                        {ok, _} = ?MODULE:start_link("crash_test.log", 65535, 0, undefined, 0),
                        ?assertEqual(0, lager_test_backend:count()),
                        sync_error_logger:error_msg("Test message\n"),
                        _ = gen_event:which_handlers(error_logger),
                        ?assertEqual(1, lager_test_backend:count()),
                        file:delete("crash_test.log"),
                        file:write_file("crash_test.log", ""),
                        {ok, FInfo} = file:read_file_info("crash_test.log"),
                        file:write_file_info("crash_test.log", FInfo#file_info{mode = 0}),
                        sync_error_logger:error_msg("Test message\n"),
                        _ = gen_event:which_handlers(error_logger),
                        ?assertEqual(3, lager_test_backend:count()),
                        lager_test_backend:pop(),
                        {_Level, _Time, Message,_Metadata} = lager_test_backend:pop(),
                        ?assertEqual("Failed to reopen crash log crash_test.log with error: permission denied", lists:flatten(Message))
                end
            },
            {"unavailable files that are fixed at runtime should start having log messages written",
                fun() ->
                        {ok, FInfo} = file:read_file_info("crash_test.log"),
                        OldPerms = FInfo#file_info.mode,
                        file:write_file_info("crash_test.log", FInfo#file_info{mode = 0}),
                        {ok, _} = ?MODULE:start_link("crash_test.log", 65535, 0, undefined, 0),
                        ?assertEqual(1, lager_test_backend:count()),
                        {_Level, _Time, Message,_Metadata} = lager_test_backend:pop(),
                        ?assertEqual("Failed to open crash log file crash_test.log with error: permission denied", lists:flatten(Message)),
                        file:write_file_info("crash_test.log", FInfo#file_info{mode = OldPerms}),
                        sync_error_logger:error_msg("Test message~n"),
                        _ = gen_event:which_handlers(error_logger),
                        {ok, Bin} = file:read_file("crash_test.log"),
                        ?assertMatch([_, "Test message\n"], re:split(Bin, "\n", [{return, list}, {parts, 2}]))
                end
            },
            {"external logfile rotation/deletion should be handled",
                fun() ->
                        {ok, _} = ?MODULE:start_link("crash_test.log", 65535, 0, undefined, 0),
                        ?assertEqual(0, lager_test_backend:count()),
                        sync_error_logger:error_msg("Test message~n"),
                        _ = gen_event:which_handlers(error_logger),
                        {ok, Bin} = file:read_file("crash_test.log"),
                        ?assertMatch([_, "Test message\n"], re:split(Bin, "\n", [{return, list}, {parts, 2}])),
                        file:delete("crash_test.log"),
                        file:write_file("crash_test.log", ""),
                        sync_error_logger:error_msg("Test message1~n"),
                        _ = gen_event:which_handlers(error_logger),
                        {ok, Bin1} = file:read_file("crash_test.log"),
                        ?assertMatch([_, "Test message1\n"], re:split(Bin1, "\n", [{return, list}, {parts, 2}])),
                        file:rename("crash_test.log", "crash_test.log.0"),
                        sync_error_logger:error_msg("Test message2~n"),
                        _ = gen_event:which_handlers(error_logger),
                        {ok, Bin2} = file:read_file("crash_test.log"),
                        ?assertMatch([_, "Test message2\n"], re:split(Bin2, "\n", [{return, list}, {parts, 2}]))
                end
            }
        ]
    }.

-endif.

