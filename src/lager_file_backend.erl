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

%% @doc File backend for lager, with multiple file support.
%% Multiple files are supported, each with the path and the loglevel being
%% configurable. The configuration paramter for this backend is a list of
%% key-value 2-tuples. See the init() function for the available options.
%% This backend supports external and internal log
%% rotation and will re-open handles to files if the inode changes. It will
%% also rotate the files itself if the size of the file exceeds the
%% `size' and keep `count' rotated files. `date' is
%% an alternate rotation trigger, based on time. See the README for
%% documentation.
%% For performance, the file backend does delayed writes, although it will
%% sync at specific log levels, configured via the `sync_on' option. By default
%% the error level or above will trigger a sync.

-module(lager_file_backend).

-include("lager.hrl").
-include_lib("kernel/include/file.hrl").

-behaviour(gen_event).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-compile([{parse_transform, lager_transform}]).
-endif.

-export([init/1, handle_call/2, handle_event/2, handle_info/2, terminate/2,
        code_change/3]).

-export([config_to_id/1]).

-define(DEFAULT_LOG_LEVEL, info).
-define(DEFAULT_ROTATION_SIZE, 10485760). %% 10mb
-define(DEFAULT_ROTATION_DATE, "$D0"). %% midnight
-define(DEFAULT_ROTATION_COUNT, 5).
-define(DEFAULT_ROTATION_MOD, lager_rotator_default).
-define(DEFAULT_SYNC_LEVEL, error).
-define(DEFAULT_SYNC_INTERVAL, 1000).
-define(DEFAULT_SYNC_SIZE, 1024*64). %% 64kb
-define(DEFAULT_CHECK_INTERVAL, 1000).

-record(state, {
        name :: string(),
        level :: {'mask', integer()},
        fd :: file:io_device() | undefined,
        inode :: integer() | undefined,
        ctime :: file:date_time() | undefined,
        flap = false :: boolean(),
        size = 0 :: integer(),
        date :: undefined | string(),
        count = 10 :: integer(),
        rotator = lager_util :: atom(),
        shaper :: lager_shaper(),
        formatter :: atom(),
        formatter_config :: any(),
        sync_on :: {'mask', integer()},
        check_interval = ?DEFAULT_CHECK_INTERVAL :: non_neg_integer(),
        sync_interval = ?DEFAULT_SYNC_INTERVAL :: non_neg_integer(),
        sync_size = ?DEFAULT_SYNC_SIZE :: non_neg_integer(),
        last_check = os:timestamp() :: erlang:timestamp(),
        os_type :: atom()
    }).

-type option() :: {file, string()} | {level, lager:log_level()} |
                  {size, non_neg_integer()} | {date, string()} |
                  {count, non_neg_integer()} | {rotator, atom()} |
                  {high_water_mark, non_neg_integer()} |
                  {flush_queue, boolean()} |
                  {flush_threshold, non_neg_integer()} |
                  {sync_interval, non_neg_integer()} |
                  {sync_size, non_neg_integer()} | {sync_on, lager:log_level()} |
                  {check_interval, non_neg_integer()} | {formatter, atom()} |
                  {formatter_config, term()}.

-spec init([option(),...]) -> {ok, #state{}} | {error, {fatal,bad_config}}.
init({FileName, LogLevel}) when is_list(FileName), is_atom(LogLevel) ->
    %% backwards compatibility hack
    init([{file, FileName}, {level, LogLevel}]);
init({FileName, LogLevel, Size, Date, Count}) when is_list(FileName), is_atom(LogLevel) ->
    %% backwards compatibility hack
    init([{file, FileName}, {level, LogLevel}, {size, Size}, {date, Date}, {count, Count}]);
init([{FileName, LogLevel, Size, Date, Count}, {Formatter,FormatterConfig}]) when is_list(FileName), is_atom(LogLevel), is_atom(Formatter) ->
    %% backwards compatibility hack
    init([{file, FileName}, {level, LogLevel}, {size, Size}, {date, Date}, {count, Count}, {formatter, Formatter}, {formatter_config, FormatterConfig}]);
init([LogFile,{Formatter}]) ->
    %% backwards compatibility hack
    init([LogFile,{Formatter,[]}]);
init([{FileName, LogLevel}, {Formatter,FormatterConfig}]) when is_list(FileName), is_atom(LogLevel), is_atom(Formatter) ->
    %% backwards compatibility hack
    init([{file, FileName}, {level, LogLevel}, {formatter, Formatter}, {formatter_config, FormatterConfig}]);
init(LogFileConfig) when is_list(LogFileConfig) ->
    case validate_logfile_proplist(LogFileConfig) of
        false ->
            %% falied to validate config
            {error, {fatal, bad_config}};
        Config ->
            %% probabably a better way to do this, but whatever
            [RelName, Level, Date, Size, Count, Rotator, HighWaterMark, Flush, SyncInterval, SyncSize, SyncOn, CheckInterval, Formatter, FormatterConfig] =
              [proplists:get_value(Key, Config) || Key <- [file, level, date, size, count, rotator, high_water_mark, flush_queue, sync_interval, sync_size, sync_on, check_interval, formatter, formatter_config]],
            FlushThr = proplists:get_value(flush_threshold, Config, 0),
            Name = lager_util:expand_path(RelName),
            schedule_rotation(Name, Date),
            Shaper = lager_util:maybe_flush(Flush, #lager_shaper{hwm=HighWaterMark, flush_threshold = FlushThr, id=Name}),
            State0 = #state{name=Name, level=Level, size=Size, date=Date, count=Count, rotator=Rotator,
                shaper=Shaper, formatter=Formatter, formatter_config=FormatterConfig,
                sync_on=SyncOn, sync_interval=SyncInterval, sync_size=SyncSize, check_interval=CheckInterval},
            State = case Rotator:create_logfile(Name, {SyncSize, SyncInterval}) of
                {ok, {FD, Inode, Ctime, _Size}} ->
                    State0#state{fd=FD, inode=Inode, ctime=Ctime};
                {error, Reason} ->
                    ?INT_LOG(error, "Failed to open log file ~ts with error ~s", [Name, file:format_error(Reason)]),
                    State0#state{flap=true}
            end,
            {ok, State}
    end.

%% @private
handle_call({set_loglevel, Level}, #state{name=Ident} = State) ->
    case validate_loglevel(Level) of
        false ->
            {ok, {error, bad_loglevel}, State};
        Levels ->
            ?INT_LOG(notice, "Changed loglevel of ~s to ~p", [Ident, Level]),
            {ok, ok, State#state{level=Levels}}
    end;
handle_call(get_loglevel, #state{level=Level} = State) ->
    {ok, Level, State};
handle_call({set_loghwm, Hwm}, #state{shaper=Shaper, name=Name} = State) ->
    case validate_logfile_proplist([{file, Name}, {high_water_mark, Hwm}]) of
        false ->
            {ok, {error, bad_log_hwm}, State};
        _ ->
            NewShaper = Shaper#lager_shaper{hwm=Hwm},
            ?INT_LOG(notice, "Changed loghwm of ~ts to ~p", [Name, Hwm]),
            {ok, {last_loghwm, Shaper#lager_shaper.hwm}, State#state{shaper=NewShaper}}
    end;
handle_call(rotate, State = #state{name=File}) ->
    {ok, NewState} = handle_info({rotate, File}, State),
    {ok, ok, NewState};
handle_call(_Request, State) ->
    {ok, ok, State}.

%% @private
handle_event({log, Message},
    #state{name=Name, level=L, shaper=Shaper, formatter=Formatter,formatter_config=FormatConfig} = State) ->
    case lager_util:is_loggable(Message,L,{lager_file_backend, Name}) of
        true ->
            case lager_util:check_hwm(Shaper) of
                {true, Drop, #lager_shaper{hwm=Hwm} = NewShaper} ->
                    NewState = case Drop > 0 of
                        true ->
                            Report = io_lib:format(
                                "lager_file_backend dropped ~p messages in the last second that exceeded the limit of ~p messages/sec",
                                [Drop, Hwm]),
                            ReportMsg = lager_msg:new(Report, warning, [], []),
                            write(State, lager_msg:timestamp(ReportMsg),
                                lager_msg:severity_as_int(ReportMsg), Formatter:format(ReportMsg, FormatConfig));
                        false ->
                            State
                    end,
                    {ok,write(NewState#state{shaper=NewShaper},
                        lager_msg:timestamp(Message), lager_msg:severity_as_int(Message),
                        Formatter:format(Message,FormatConfig))};
                {false, _, #lager_shaper{dropped=D} = NewShaper} ->
                    {ok, State#state{shaper=NewShaper#lager_shaper{dropped=D+1}}}
            end;
        false ->
            {ok, State}
    end;
handle_event(_Event, State) ->
    {ok, State}.

%% @private
handle_info({rotate, File}, #state{name=File, count=Count, date=Date, rotator=Rotator}=State0) ->
    State1 = close_file(State0),
    _ = Rotator:rotate_logfile(File, Count),
    schedule_rotation(File, Date),
    {ok, State1};
handle_info({shaper_expired, Name}, #state{shaper=Shaper, name=Name, formatter=Formatter, formatter_config=FormatConfig} = State) ->
    _ = case Shaper#lager_shaper.dropped of
            0 ->
                ok;
            Dropped ->
                Report = io_lib:format(
                           "lager_file_backend dropped ~p messages in the last second that exceeded the limit of ~p messages/sec",
                           [Dropped, Shaper#lager_shaper.hwm]),
                ReportMsg = lager_msg:new(Report, warning, [], []),
                write(State, lager_msg:timestamp(ReportMsg),
                      lager_msg:severity_as_int(ReportMsg), Formatter:format(ReportMsg, FormatConfig))
        end,
    {ok, State#state{shaper=Shaper#lager_shaper{dropped=0, mps=0, lasttime=os:timestamp()}}};
handle_info(_Info, State) ->
    {ok, State}.

%% @private
terminate(_Reason, State) ->
    %% leaving this function call unmatched makes dialyzer cranky
    _ = close_file(State),
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Convert the config into a gen_event handler ID
config_to_id({Name,_Severity}) when is_list(Name) ->
    {?MODULE, Name};
config_to_id({Name,_Severity,_Size,_Rotation,_Count}) ->
    {?MODULE, Name};
config_to_id([{Name,_Severity,_Size,_Rotation,_Count}, _Format]) ->
    {?MODULE, Name};
config_to_id([{Name,_Severity}, _Format]) when is_list(Name) ->
    {?MODULE, Name};
config_to_id(Config) ->
    case proplists:get_value(file, Config) of
        undefined ->
            erlang:error(no_file);
        File ->
            {?MODULE, File}
    end.

write(#state{name=Name, fd=FD,
             inode=Inode, ctime=Ctime,
             flap=Flap, size=RotSize,
             count=Count, rotator=Rotator}=State0, Timestamp, Level, Msg) ->
    case write_should_check(State0, Timestamp) of
        true ->
            %% need to check for rotation
            Buffer = {State0#state.sync_size, State0#state.sync_interval},
            case Rotator:ensure_logfile(Name, FD, Inode, Ctime, Buffer) of
                {ok, {_FD, _Inode, _Ctime, Size}} when RotSize > 0, Size > RotSize ->
                    State1 = close_file(State0),
                    case Rotator:rotate_logfile(Name, Count) of
                        ok ->
                            %% go around the loop again, we'll do another rotation check and hit the next clause of ensure_logfile
                            write(State1, Timestamp, Level, Msg);
                        {error, Reason} ->
                            case Flap of
                                true ->
                                    State1;
                                _ ->
                                    ?INT_LOG(error, "Failed to rotate log file ~ts with error ~s", [Name, file:format_error(Reason)]),
                                    State1#state{flap=true}
                            end
                    end;
                {ok, {NewFD, NewInode, NewCtime, _Size}} ->
                    %% update our last check and try again
                    State1 = State0#state{last_check=Timestamp, fd=NewFD, inode=NewInode, ctime=NewCtime},
                    do_write(State1, Level, Msg);
                {error, Reason} ->
                    case Flap of
                        true ->
                            State0;
                        _ ->
                            ?INT_LOG(error, "Failed to reopen log file ~ts with error ~s", [Name, file:format_error(Reason)]),
                            State0#state{flap=true}
                    end
            end;
        false ->
            do_write(State0, Level, Msg)
    end.

write_should_check(#state{fd=undefined}, _Timestamp) ->
    true;
write_should_check(#state{last_check=LastCheck0, check_interval=CheckInterval,
                          name=Name, inode=Inode0, ctime=Ctime0}, Timestamp) ->
    LastCheck1 = timer:now_diff(Timestamp, LastCheck0) div 1000,
    case LastCheck1 >= CheckInterval of
        true ->
            true;
        _ ->
            % We need to know if the file has changed "out from under lager" so we don't
            % write to an invalid FD
            {Result, _FInfo} = lager_util:has_file_changed(Name, Inode0, Ctime0),
            Result
    end.

do_write(#state{fd=FD, name=Name, flap=Flap} = State, Level, Msg) ->
    %% delayed_write doesn't report errors
    _ = file:write(FD, unicode:characters_to_binary(Msg)),
    {mask, SyncLevel} = State#state.sync_on,
    case (Level band SyncLevel) =/= 0 of
        true ->
            %% force a sync on any message that matches the 'sync_on' bitmask
            Flap2 = case file:datasync(FD) of
                {error, Reason2} when Flap == false ->
                    ?INT_LOG(error, "Failed to write log message to file ~ts: ~s",
                        [Name, file:format_error(Reason2)]),
                    true;
                ok ->
                    false;
                _ ->
                    Flap
            end,
            State#state{flap=Flap2};
        _ ->
            State
    end.

validate_loglevel(Level) ->
    try lager_util:config_to_mask(Level) of
        Levels ->
            Levels
    catch
        _:_ ->
            false
    end.

validate_logfile_proplist(List) ->
    try validate_logfile_proplist(List, []) of
        Res ->
            case proplists:get_value(file, Res) of
                undefined ->
                    ?INT_LOG(error, "Missing required file option", []),
                    false;
                _File ->
                    %% merge with the default options
                    {ok, DefaultRotationDate} = lager_util:parse_rotation_date_spec(?DEFAULT_ROTATION_DATE),
                    lists:keymerge(1, lists:sort(Res), lists:sort([
                            {level, validate_loglevel(?DEFAULT_LOG_LEVEL)}, {date, DefaultRotationDate},
                            {size, ?DEFAULT_ROTATION_SIZE}, {count, ?DEFAULT_ROTATION_COUNT},
                            {rotator, ?DEFAULT_ROTATION_MOD},
                            {sync_on, validate_loglevel(?DEFAULT_SYNC_LEVEL)}, {sync_interval, ?DEFAULT_SYNC_INTERVAL},
                            {sync_size, ?DEFAULT_SYNC_SIZE}, {check_interval, ?DEFAULT_CHECK_INTERVAL},
                            {formatter, lager_default_formatter}, {formatter_config, []}
                        ]))
            end
    catch
        {bad_config, Msg, Value} ->
            ?INT_LOG(error, "~s ~p for file ~tp",
                [Msg, Value, proplists:get_value(file, List)]),
            false
    end.

validate_logfile_proplist([], Acc) ->
    Acc;
validate_logfile_proplist([{file, File}|Tail], Acc) ->
    %% is there any reasonable validation we can do here?
    validate_logfile_proplist(Tail, [{file, File}|Acc]);
validate_logfile_proplist([{level, Level}|Tail], Acc) ->
    case validate_loglevel(Level) of
        false ->
            throw({bad_config, "Invalid loglevel", Level});
        Res ->
            validate_logfile_proplist(Tail, [{level, Res}|Acc])
    end;
validate_logfile_proplist([{size, Size}|Tail], Acc) ->
    case Size of
        S when is_integer(S), S >= 0 ->
            validate_logfile_proplist(Tail, [{size, Size}|Acc]);
        _ ->
            throw({bad_config, "Invalid rotation size", Size})
    end;
validate_logfile_proplist([{count, Count}|Tail], Acc) ->
    case Count of
        C when is_integer(C), C >= 0 ->
            validate_logfile_proplist(Tail, [{count, Count}|Acc]);
        _ ->
            throw({bad_config, "Invalid rotation count", Count})
    end;
validate_logfile_proplist([{rotator, Rotator}|Tail], Acc) ->
    case is_atom(Rotator) of
        true ->
            validate_logfile_proplist(Tail, [{rotator, Rotator}|Acc]);
        false ->
            throw({bad_config, "Invalid rotation module", Rotator})
    end;
validate_logfile_proplist([{high_water_mark, HighWaterMark}|Tail], Acc) ->
    case HighWaterMark of
        Hwm when is_integer(Hwm), Hwm >= 0 ->
            validate_logfile_proplist(Tail, [{high_water_mark, Hwm}|Acc]);
        _ ->
            throw({bad_config, "Invalid high water mark", HighWaterMark})
    end;
validate_logfile_proplist([{date, Date}|Tail], Acc) ->
    case lager_util:parse_rotation_date_spec(Date) of
        {ok, Spec} ->
            validate_logfile_proplist(Tail, [{date, Spec}|Acc]);
        {error, _} when Date == "" ->
            %% legacy config allowed blanks
            validate_logfile_proplist(Tail, [{date, undefined}|Acc]);
        {error, _} ->
            throw({bad_config, "Invalid rotation date", Date})
    end;
validate_logfile_proplist([{sync_interval, SyncInt}|Tail], Acc) ->
    case SyncInt of
        Val when is_integer(Val), Val >= 0 ->
            validate_logfile_proplist(Tail, [{sync_interval, Val}|Acc]);
        _ ->
            throw({bad_config, "Invalid sync interval", SyncInt})
    end;
validate_logfile_proplist([{sync_size, SyncSize}|Tail], Acc) ->
    case SyncSize of
        Val when is_integer(Val), Val >= 0 ->
            validate_logfile_proplist(Tail, [{sync_size, Val}|Acc]);
        _ ->
            throw({bad_config, "Invalid sync size", SyncSize})
    end;
validate_logfile_proplist([{check_interval, CheckInt}|Tail], Acc) ->
    case CheckInt of
        Val when is_integer(Val), Val >= 0 ->
            validate_logfile_proplist(Tail, [{check_interval, Val}|Acc]);
        always ->
            validate_logfile_proplist(Tail, [{check_interval, 0}|Acc]);
        _ ->
            throw({bad_config, "Invalid check interval", CheckInt})
    end;
validate_logfile_proplist([{sync_on, Level}|Tail], Acc) ->
    case validate_loglevel(Level) of
        false ->
            throw({bad_config, "Invalid sync on level", Level});
        Res ->
            validate_logfile_proplist(Tail, [{sync_on, Res}|Acc])
    end;
validate_logfile_proplist([{formatter, Fmt}|Tail], Acc) ->
    case is_atom(Fmt) of
        true ->
            validate_logfile_proplist(Tail, [{formatter, Fmt}|Acc]);
        false ->
            throw({bad_config, "Invalid formatter module", Fmt})
    end;
validate_logfile_proplist([{formatter_config, FmtCfg}|Tail], Acc) ->
    case is_list(FmtCfg) of
        true ->
            validate_logfile_proplist(Tail, [{formatter_config, FmtCfg}|Acc]);
        false ->
            throw({bad_config, "Invalid formatter config", FmtCfg})
    end;
validate_logfile_proplist([{flush_queue, FlushCfg}|Tail], Acc) ->
    case is_boolean(FlushCfg) of
        true ->
            validate_logfile_proplist(Tail, [{flush_queue, FlushCfg}|Acc]);
        false ->
            throw({bad_config, "Invalid queue flush flag", FlushCfg})
    end;
validate_logfile_proplist([{flush_threshold, Thr}|Tail], Acc) ->
    case Thr of
        _ when is_integer(Thr), Thr >= 0 ->
            validate_logfile_proplist(Tail, [{flush_threshold, Thr}|Acc]);
        _ ->
            throw({bad_config, "Invalid queue flush threshold", Thr})
    end;
validate_logfile_proplist([Other|_Tail], _Acc) ->
    throw({bad_config, "Invalid option", Other}).

schedule_rotation(_, undefined) ->
    ok;
schedule_rotation(Name, Date) ->
    erlang:send_after(lager_util:calculate_next_rotation(Date) * 1000, self(), {rotate, Name}),
    ok.

close_file(#state{fd=undefined} = State) ->
    State;
close_file(#state{fd=FD} = State) ->
    %% Flush and close any file handles.
    %% delayed write can cause file:close not to do a close
    _ = file:datasync(FD),
    _ = file:close(FD),
    _ = file:close(FD),
    State#state{fd=undefined}.

-ifdef(TEST).

get_loglevel_test() ->
    {ok, Level, _} = handle_call(get_loglevel,
        #state{name="bar", level=lager_util:config_to_mask(info), fd=0, inode=0, ctime=undefined}),
    ?assertEqual(Level, lager_util:config_to_mask(info)),
    {ok, Level2, _} = handle_call(get_loglevel,
        #state{name="foo", level=lager_util:config_to_mask(warning), fd=0, inode=0, ctime=undefined}),
    ?assertEqual(Level2, lager_util:config_to_mask(warning)).

rotation_test_() ->
    {foreach,
        fun() ->
            SyncLevel = validate_loglevel(?DEFAULT_SYNC_LEVEL),
            SyncSize = ?DEFAULT_SYNC_SIZE,
            SyncInterval = ?DEFAULT_SYNC_INTERVAL,
            Rotator = ?DEFAULT_ROTATION_MOD,
            CheckInterval = 0, %% hard to test delayed mode
            {ok, TestDir} = lager_util:create_test_dir(),
            TestLog = filename:join(TestDir, "test.log"),
            {OsType, _} = os:type(),
            #state{name=TestLog,
                   level=?DEBUG,
                   sync_on=SyncLevel,
                   sync_size=SyncSize,
                   sync_interval=SyncInterval,
                   check_interval=CheckInterval,
                   rotator=Rotator,
                   os_type=OsType}
        end,
        fun(#state{}) ->
            ok = lager_util:delete_test_dir()
        end, [
        fun(DefaultState=#state{name=TestLog, os_type=OsType, sync_size=SyncSize, sync_interval=SyncInterval, rotator=Rotator}) ->
            {"External rotation should work",
            fun() ->
                case OsType of
                    win32 ->
                        % Note: test is skipped on win32 due to the fact that a file can't be deleted or renamed
                        % while a process has an open file handle referencing it
                        ok;
                    _ ->
                        {ok, {FD, Inode, Ctime, _Size}} = Rotator:open_logfile(TestLog, {SyncSize, SyncInterval}),
                        State0 = DefaultState#state{fd=FD, inode=Inode, ctime=Ctime},
                        State1 = write(State0, os:timestamp(), ?DEBUG, "hello world"),
                        ?assertMatch(#state{name=TestLog, level=?DEBUG, fd=FD, inode=Inode, ctime=Ctime}, State1),
                        ?assertEqual(ok, file:delete(TestLog)),
                        State2 = write(State0, os:timestamp(), ?DEBUG, "hello world"),
                        %% assert file has changed
                        ExpState1 = #state{name=TestLog, level=?DEBUG, fd=FD, inode=Inode, ctime=Ctime},
                        ?assertNotEqual(ExpState1, State2),
                        ?assertMatch(#state{name=TestLog, level=?DEBUG}, State2),
                        ?assertEqual(ok, file:rename(TestLog, TestLog ++ ".1")),
                        State3 = write(State2, os:timestamp(), ?DEBUG, "hello world"),
                        %% assert file has changed
                        ?assertNotEqual(State3, State2),
                        ?assertMatch(#state{name=TestLog, level=?DEBUG}, State3),
                        ok
                end
            end}
        end,
        fun(DefaultState = #state{name=TestLog, sync_size=SyncSize, sync_interval=SyncInterval, rotator=Rotator}) ->
            {"Internal rotation and delayed write",
            fun() ->
                TestLog0 = TestLog ++ ".0",
                CheckInterval = 3000, % 3 sec
                RotationSize = 15,
                PreviousCheck = os:timestamp(),

                {ok, {FD, Inode, Ctime, _Size}} = Rotator:open_logfile(TestLog, {SyncSize, SyncInterval}),
                State0 = DefaultState#state{
                    fd=FD, inode=Inode, ctime=Ctime, size=RotationSize,
                    check_interval=CheckInterval, last_check=PreviousCheck},

                %% new message within check interval with sync_on level
                Msg1Timestamp = add_secs(PreviousCheck, 1),
                State1 = write(State0, Msg1Timestamp, ?ERROR, "big big message 1"),
                ?assertEqual(State0, State1),

                %% new message within check interval under sync_on level
                %% not written to disk yet
                Msg2Timestamp = add_secs(PreviousCheck, 2),
                State2 = write(State1, Msg2Timestamp, ?DEBUG, "buffered message 2"),
                ?assertEqual(State0, State2),

                % Note: we must ensure at least one second (DEFAULT_SYNC_INTERVAL) has passed
                % for message 1 and 2 to be written to disk
                ElapsedMs = timer:now_diff(os:timestamp(), PreviousCheck) div 1000,
                case ElapsedMs > SyncInterval of
                    true ->
                        ok;
                    _ ->
                        S = SyncInterval - ElapsedMs,
                        timer:sleep(S)
                end,

                %% although file size is big enough...
                {ok, FInfo} = file:read_file_info(TestLog, [raw]),
                ?assert(RotationSize < FInfo#file_info.size),
                %% ...no rotation yet
                ?assertEqual(PreviousCheck, State2#state.last_check),
                ?assertNot(filelib:is_regular(TestLog0)),

                %% new message after check interval
                Msg3Timestamp = add_secs(PreviousCheck, 4),
                _State3 = write(State2, Msg3Timestamp, ?DEBUG, "message 3"),

                %% rotation happened
                ?assert(filelib:is_regular(TestLog0)),

                {ok, Bin1} = file:read_file(TestLog0),
                {ok, Bin2} = file:read_file(TestLog),
                %% message 1-2 written to file
                ?assertEqual(<<"big big message 1buffered message 2">>, Bin1),
                %% message 3 buffered, not yet written to file
                ?assertEqual(<<"">>, Bin2),
                ok
            end}
        end
    ]}.

add_secs({Mega, Secs, Micro}, Add) ->
    NewSecs = Secs + Add,
    {Mega + NewSecs div 10000000, NewSecs rem 10000000, Micro}.

filesystem_test_() ->
    {foreach,
        fun() ->
            ok = error_logger:tty(false),
            ok = lager_util:safe_application_load(lager),
            ok = application:set_env(lager, handlers, [{lager_test_backend, info}]),
            ok = application:set_env(lager, error_logger_redirect, false),
            ok = application:set_env(lager, async_threshold, undefined),
            {ok, _TestDir} = lager_util:create_test_dir(),
            ok = lager:start(),
            %% race condition where lager logs its own start up
            %% makes several tests fail. See test/lager_test_backend
            %% around line 800 for more information.
            ok = timer:sleep(5),
            ok = lager_test_backend:flush()
        end,
        fun(_) ->
            ok = application:stop(lager),
            ok = application:stop(goldrush),
            ok = error_logger:tty(true),
            ok = lager_util:delete_test_dir()
        end, [
        {"under normal circumstances, file should be opened",
        fun() ->
            {ok, TestDir} = lager_util:get_test_dir(),
            TestLog = filename:join(TestDir, "test.log"),

            gen_event:add_handler(lager_event, lager_file_backend,
                [{TestLog, info}, {lager_default_formatter}]),
            lager:log(error, self(), "Test message"),
            {ok, Bin} = file:read_file(TestLog),
            Pid = pid_to_list(self()),
            ?assertMatch([_, _, "[error]", Pid, "Test message\n"],
                re:split(Bin, " ", [{return, list}, {parts, 5}]))
        end},
        {"don't choke on unicode",
        fun() ->
            {ok, TestDir} = lager_util:get_test_dir(),
            TestLog = filename:join(TestDir, "test.log"),

            gen_event:add_handler(lager_event, lager_file_backend,
                [{TestLog, info}, {lager_default_formatter}]),
            lager:log(error, self(),"~ts", [[20013,25991,27979,35797]]),
            {ok, Bin} = file:read_file(TestLog),
            Pid = pid_to_list(self()),
            ?assertMatch([_, _, "[error]", Pid,
                [228,184,173,230,150,135,230,181,139,232,175,149, $\n]],
                re:split(Bin, " ", [{return, list}, {parts, 5}]))
        end},
        {"don't choke on latin-1",
        fun() ->
            {ok, TestDir} = lager_util:get_test_dir(),
            TestLog = filename:join(TestDir, "test.log"),

            %% XXX if this test fails, check that this file is encoded latin-1, not utf-8!
            gen_event:add_handler(lager_event, lager_file_backend,
                [{TestLog, info}, {lager_default_formatter}]),
            lager:log(error, self(),"~ts", [[76, 198, 221, 206, 78, $-, 239]]),
            {ok, Bin} = file:read_file(TestLog),
            Pid = pid_to_list(self()),
            Res = re:split(Bin, " ", [{return, list}, {parts, 5}]),
            ?assertMatch([_, _, "[error]", Pid,
                [76,195,134,195,157,195,142,78,45,195,175,$\n]], Res)
        end},
        {"file can't be opened on startup triggers an error message",
        fun() ->
            {ok, TestDir} = lager_util:get_test_dir(),
            TestLog = filename:join(TestDir, "test.log"),
            ?assertEqual(ok, lager_util:safe_write_file(TestLog, [])),

            {ok, FInfo0} = file:read_file_info(TestLog, [raw]),
            FInfo1 = FInfo0#file_info{mode = 0},
            ?assertEqual(ok, file:write_file_info(TestLog, FInfo1)),

            gen_event:add_handler(lager_event, lager_file_backend,
                {TestLog, info, 10*1024*1024, "$D0", 5}),

            % Note: required on win32, do this early to prevent subsequent failures
            % from preventing cleanup
            ?assertEqual(ok, file:write_file_info(TestLog, FInfo0)),

            ?assertEqual(1, lager_test_backend:count()),
            {_Level, _Time, Message, _Metadata} = lager_test_backend:pop(),
            MessageFlat = lists:flatten(Message),
            ?assertEqual(
                "Failed to open log file " ++ TestLog ++ " with error permission denied",
                MessageFlat)
        end},
        {"file that becomes unavailable at runtime should trigger an error message",
        fun() ->
            case os:type() of
                {win32, _} ->
                    % Note: test is skipped on win32 due to the fact that a file can't be
                    % deleted or renamed while a process has an open file handle referencing it
                    ok;
                _ ->
                    {ok, TestDir} = lager_util:get_test_dir(),
                    TestLog = filename:join(TestDir, "test.log"),

                    gen_event:add_handler(lager_event, lager_file_backend,
                        [{file, TestLog}, {level, info}, {check_interval, 0}]),
                    ?assertEqual(0, lager_test_backend:count()),
                    lager:log(error, self(), "Test message"),
                    ?assertEqual(1, lager_test_backend:count()),
                    ?assertEqual(ok, file:delete(TestLog)),
                    ?assertEqual(ok, lager_util:safe_write_file(TestLog, "")),
                    {ok, FInfo0} = file:read_file_info(TestLog, [raw]),
                    FInfo1 = FInfo0#file_info{mode = 0},
                    ?assertEqual(ok, file:write_file_info(TestLog, FInfo1)),
                    lager:log(error, self(), "Test message"),
                    lager_test_backend:pop(),
                    lager_test_backend:pop(),
                    {_Level, _Time, Message, _Metadata} = lager_test_backend:pop(),
                    ?assertEqual(
                        "Failed to reopen log file " ++ TestLog ++ " with error permission denied",
                        lists:flatten(Message))
            end
        end},
        {"unavailable files that are fixed at runtime should start having log messages written",
        fun() ->
            {ok, TestDir} = lager_util:get_test_dir(),
            TestLog = filename:join(TestDir, "test.log"),
            ?assertEqual(ok, lager_util:safe_write_file(TestLog, [])),

            {ok, FInfo} = file:read_file_info(TestLog, [raw]),
            OldPerms = FInfo#file_info.mode,
            ?assertEqual(ok, file:write_file_info(TestLog, FInfo#file_info{mode = 0})),
            gen_event:add_handler(lager_event, lager_file_backend,
                [{file, TestLog},{check_interval, 0}]),
            ?assertEqual(1, lager_test_backend:count()),
            {_Level, _Time, Message, _Metadata} = lager_test_backend:pop(),
            ?assertEqual(
                "Failed to open log file " ++ TestLog ++ " with error permission denied",
                lists:flatten(Message)),
            ?assertEqual(ok, file:write_file_info(TestLog, FInfo#file_info{mode = OldPerms})),
            lager:log(error, self(), "Test message"),
            {ok, Bin} = file:read_file(TestLog),
            Pid = pid_to_list(self()),
            ?assertMatch([_, _, "[error]", Pid, "Test message\n"],
                re:split(Bin, " ", [{return, list}, {parts, 5}]))
        end},
        {"external logfile rotation/deletion should be handled",
        fun() ->
            case os:type() of
                {win32, _} ->
                    % Note: test is skipped on win32 due to the fact that a file can't be deleted or renamed
                    % while a process has an open file handle referencing it
                    ok;
                _ ->
                    {ok, TestDir} = lager_util:get_test_dir(),
                    TestLog = filename:join(TestDir, "test.log"),
                    TestLog0 = TestLog ++ ".0",

                    gen_event:add_handler(lager_event, lager_file_backend,
                        [{file, TestLog}, {level, info}, {check_interval, 0}]),
                    ?assertEqual(0, lager_test_backend:count()),
                    lager:log(error, self(), "Test message1"),
                    ?assertEqual(1, lager_test_backend:count()),
                    ?assertEqual(ok, file:delete(TestLog)),
                    ?assertEqual(ok, lager_util:safe_write_file(TestLog, "")),
                    lager:log(error, self(), "Test message2"),
                    ?assertEqual(2, lager_test_backend:count()),
                    {ok, Bin} = file:read_file(TestLog),
                    Pid = pid_to_list(self()),
                    ?assertMatch([_, _, "[error]", Pid, "Test message2\n"],
                        re:split(Bin, " ", [{return, list}, {parts, 5}])),
                    ?assertEqual(ok, file:rename(TestLog, TestLog0)),
                    lager:log(error, self(), "Test message3"),
                    ?assertEqual(3, lager_test_backend:count()),
                    {ok, Bin2} = file:read_file(TestLog),
                    ?assertMatch([_, _, "[error]", Pid, "Test message3\n"],
                        re:split(Bin2, " ", [{return, list}, {parts, 5}]))
            end
        end},
        {"internal size rotation should work",
        fun() ->
            {ok, TestDir} = lager_util:get_test_dir(),
            TestLog = filename:join(TestDir, "test.log"),
            TestLog0 = TestLog ++ ".0",

            gen_event:add_handler(lager_event, lager_file_backend,
                [{file, TestLog}, {level, info}, {check_interval, 0}, {size, 10}]),
            lager:log(error, self(), "Test message1"),
            lager:log(error, self(), "Test message1"),
            ?assert(filelib:is_regular(TestLog0))
        end},
        {"internal time rotation should work",
        fun() ->
            {ok, TestDir} = lager_util:get_test_dir(),
            TestLog = filename:join(TestDir, "test.log"),
            TestLog0 = TestLog ++ ".0",

            gen_event:add_handler(lager_event, lager_file_backend,
                [{file, TestLog}, {level, info}, {check_interval, 1000}]),
            lager:log(error, self(), "Test message1"),
            lager:log(error, self(), "Test message1"),
            whereis(lager_event) ! {rotate, TestLog},
            lager:log(error, self(), "Test message1"),
            ?assert(filelib:is_regular(TestLog0))
        end},
        {"rotation call should work",
        fun() ->
            {ok, TestDir} = lager_util:get_test_dir(),
            TestLog = filename:join(TestDir, "test.log"),
            TestLog0 = TestLog ++ ".0",

            gen_event:add_handler(lager_event, {lager_file_backend, TestLog},
                [{file, TestLog}, {level, info}, {check_interval, 1000}]),
            lager:log(error, self(), "Test message1"),
            lager:log(error, self(), "Test message1"),
            gen_event:call(lager_event, {lager_file_backend, TestLog}, rotate, infinity),
            lager:log(error, self(), "Test message1"),
            ?assert(filelib:is_regular(TestLog0))
        end},
        {"sync_on option should work",
        fun() ->
            {ok, TestDir} = lager_util:get_test_dir(),
            TestLog = filename:join(TestDir, "test.log"),

            gen_event:add_handler(lager_event, lager_file_backend, [{file, TestLog},
                {level, info}, {sync_on, "=info"}, {check_interval, 5000}, {sync_interval, 5000}]),
            lager:log(error, self(), "Test message1"),
            lager:log(error, self(), "Test message1"),
            ?assertEqual({ok, <<>>}, file:read_file(TestLog)),
            lager:log(info, self(), "Test message1"),
            {ok, Bin} = file:read_file(TestLog),
            ?assert(<<>> /= Bin)
        end},
        {"sync_on none option should work (also tests sync_interval)",
        fun() ->
            {ok, TestDir} = lager_util:get_test_dir(),
            TestLog = filename:join(TestDir, "test.log"),

            gen_event:add_handler(lager_event, lager_file_backend, [{file, TestLog},
                {level, info}, {sync_on, "none"}, {check_interval, 5000}, {sync_interval, 1000}]),
            lager:log(error, self(), "Test message1"),
            lager:log(error, self(), "Test message1"),
            ?assertEqual({ok, <<>>}, file:read_file(TestLog)),
            lager:log(info, self(), "Test message1"),
            ?assertEqual({ok, <<>>}, file:read_file(TestLog)),
            timer:sleep(2000),
            {ok, Bin} = file:read_file(TestLog),
            ?assert(<<>> /= Bin)
        end},
        {"sync_size option should work",
        fun() ->
            {ok, TestDir} = lager_util:get_test_dir(),
            TestLog = filename:join(TestDir, "test.log"),

            gen_event:add_handler(lager_event, lager_file_backend, [{file, TestLog}, {level, info},
                {sync_on, "none"}, {check_interval, 5001}, {sync_size, 640}, {sync_interval, 5001}]),
            lager:log(error, self(), "Test messageis64bytes"),
            lager:log(error, self(), "Test messageis64bytes"),
            lager:log(error, self(), "Test messageis64bytes"),
            lager:log(error, self(), "Test messageis64bytes"),
            lager:log(error, self(), "Test messageis64bytes"),
            ?assertEqual({ok, <<>>}, file:read_file(TestLog)),
            lager:log(error, self(), "Test messageis64bytes"),
            lager:log(error, self(), "Test messageis64bytes"),
            lager:log(error, self(), "Test messageis64bytes"),
            lager:log(error, self(), "Test messageis64bytes"),
            ?assertEqual({ok, <<>>}, file:read_file(TestLog)),
            %% now we've written enough bytes
            lager:log(error, self(), "Test messageis64bytes"),
            {ok, Bin} = file:read_file(TestLog),
            ?assert(<<>> /= Bin)
        end},
        {"runtime level changes",
        fun() ->
            {ok, TestDir} = lager_util:get_test_dir(),
            TestLog = filename:join(TestDir, "test.log"),

            gen_event:add_handler(lager_event, {lager_file_backend, TestLog}, {TestLog, info}),
            ?assertEqual(0, lager_test_backend:count()),
            lager:log(info, self(), "Test message1"),
            lager:log(error, self(), "Test message2"),
            {ok, Bin} = file:read_file(TestLog),
            Lines = length(re:split(Bin, "\n", [{return, list}, trim])),
            ?assertEqual(Lines, 2),
            ?assertEqual(ok, lager:set_loglevel(lager_file_backend, TestLog, warning)),
            lager:log(info, self(), "Test message3"), %% this won't get logged
            lager:log(error, self(), "Test message4"),
            {ok, Bin2} = file:read_file(TestLog),
            Lines2 = length(re:split(Bin2, "\n", [{return, list}, trim])),
            ?assertEqual(Lines2, 3)
        end},
        {"invalid runtime level changes",
        fun() ->
            {ok, TestDir} = lager_util:get_test_dir(),
            TestLog = filename:join(TestDir, "test.log"),
            TestLog3 = filename:join(TestDir, "test3.log"),

            gen_event:add_handler(lager_event, lager_file_backend,
                [{TestLog, info, 10*1024*1024, "$D0", 5}, {lager_default_formatter}]),
            gen_event:add_handler(lager_event, lager_file_backend, {TestLog3, info}),
            ?assertEqual({error, bad_module}, lager:set_loglevel(lager_file_backend, TestLog, warning))
        end},
        {"tracing should work",
        fun() ->
            {ok, TestDir} = lager_util:get_test_dir(),
            TestLog = filename:join(TestDir, "test.log"),

            gen_event:add_handler(lager_event, lager_file_backend, {TestLog, critical}),
            lager:error("Test message"),
            ?assertEqual({ok, <<>>}, file:read_file(TestLog)),
            {Level, _} = lager_config:get({lager_event, loglevel}),
            lager_config:set({lager_event, loglevel}, {Level,
                [{[{module, ?MODULE}], ?DEBUG, {lager_file_backend, TestLog}}]}),
            lager:error("Test message"),
            timer:sleep(1000),
            {ok, Bin} = file:read_file(TestLog),
            ?assertMatch([_, _, "[error]", _, "Test message\n"],
                re:split(Bin, " ", [{return, list}, {parts, 5}]))
        end},
        {"tracing should not duplicate messages",
        fun() ->
            case os:type() of
                {win32, _} ->
                    % Note: test is skipped on win32 due to the fact that a file can't be
                    % deleted or renamed while a process has an open file handle referencing it
                    ok;
                _ ->
                    {ok, TestDir} = lager_util:get_test_dir(),
                    TestLog = filename:join(TestDir, "test.log"),

                    gen_event:add_handler(lager_event, lager_file_backend,
                        [{file, TestLog}, {level, critical}, {check_interval, always}]),
                    timer:sleep(500),
                    lager:critical("Test message"),
                    {ok, Bin1} = file:read_file(TestLog),
                    ?assertMatch([_, _, "[critical]", _, "Test message\n"],
                        re:split(Bin1, " ", [{return, list}, {parts, 5}])),
                    ?assertEqual(ok, file:delete(TestLog)),
                    {Level, _} = lager_config:get({lager_event, loglevel}),
                    lager_config:set({lager_event, loglevel},
                        {Level, [{[{module, ?MODULE}], ?DEBUG, {lager_file_backend, TestLog}}]}),
                    lager:critical("Test message"),
                    {ok, Bin2} = file:read_file(TestLog),
                    ?assertMatch([_, _, "[critical]", _, "Test message\n"],
                        re:split(Bin2, " ", [{return, list}, {parts, 5}])),
                    ?assertEqual(ok, file:delete(TestLog)),
                    lager:error("Test message"),
                    {ok, Bin3} = file:read_file(TestLog),
                    ?assertMatch([_, _, "[error]", _, "Test message\n"],
                        re:split(Bin3, " ", [{return, list}, {parts, 5}]))
            end
        end},
        {"tracing to a dedicated file should work",
        fun() ->
            {ok, TestDir} = lager_util:get_test_dir(),
            TestLog = filename:join(TestDir, "foo.log"),

            {ok, _} = lager:trace_file(TestLog, [{module, ?MODULE}]),
            lager:error("Test message"),
            %% not eligible for trace
            lager:log(error, self(), "Test message"),
            {ok, Bin3} = file:read_file(TestLog),
            ?assertMatch([_, _, "[error]", _, "Test message\n"],
                re:split(Bin3, " ", [{return, list}, {parts, 5}]))
        end},
        {"tracing to a dedicated file should work even if root_log is set",
        fun() ->
            {ok, TestDir} = lager_util:get_test_dir(),
            LogName = "foo.log",
            LogPath = filename:join(TestDir, LogName),

            application:set_env(lager, log_root, TestDir),
            {ok, _} = lager:trace_file(LogName, [{module, ?MODULE}]),
            lager:error("Test message"),
            %% not eligible for trace
            lager:log(error, self(), "Test message"),
            {ok, Bin3} = file:read_file(LogPath),
            application:unset_env(lager, log_root),
            ?assertMatch([_, _, "[error]", _, "Test message\n"],
                re:split(Bin3, " ", [{return, list}, {parts, 5}]))
        end},
        {"tracing with options should work",
        fun() ->
            {ok, TestDir} = lager_util:get_test_dir(),
            TestLog = filename:join(TestDir, "foo.log"),
            TestLog0 = TestLog ++ ".0",

            {ok, _} = lager:trace_file(TestLog, [{module, ?MODULE}],
                [{size, 20}, {check_interval, 1}]),
            lager:error("Test message"),
            ?assertNot(filelib:is_regular(TestLog0)),
            %% rotation is sensitive to intervals between
            %% writes so we sleep to exceed the 1
            %% millisecond interval specified by
            %% check_interval above
            timer:sleep(2),
            lager:error("Test message"),
            timer:sleep(10),
            ?assert(filelib:is_regular(TestLog0))
        end},
        {"no silent hwm drops",
        fun() ->
            MsgCount = 15,
            {ok, TestDir} = lager_util:get_test_dir(),
            TestLog = filename:join(TestDir, "test.log"),
            gen_event:add_handler(lager_event, lager_file_backend, [{file, TestLog}, {level, info},
                {high_water_mark, 5}, {flush_queue, false}, {sync_on, "=warning"}]),
            {_, _, MS} = os:timestamp(),
            % start close to the beginning of a new second
            ?assertEqual(ok, timer:sleep((1000000 - MS) div 1000 + 1)),
            [lager:log(info, self(), "Foo ~p", [K]) || K <- lists:seq(1, MsgCount)],
            ?assertEqual(MsgCount, lager_test_backend:count()),
            % Note: bumped from 1000 to 1250 to ensure delayed write flushes to disk
            ?assertEqual(ok, timer:sleep(1250)),
            {ok, Bin} = file:read_file(TestLog),
            Last = lists:last(re:split(Bin, "\n", [{return, list}, trim])),
            ?assertMatch([_, _, _, _, "lager_file_backend dropped 10 messages in the last second that exceeded the limit of 5 messages/sec"],
                re:split(Last, " ", [{return, list}, {parts, 5}]))
        end}
    ]}.

trace_files_test_() ->
    {foreach,
        fun() ->
            {ok, TestDir} = lager_util:get_test_dir(),
            Log     = filename:join(TestDir, "test.log"),
            Debug   = filename:join(TestDir, "debug.log"),
            Events  = filename:join(TestDir, "events.log"),

            ok = error_logger:tty(false),
            ok = lager_util:safe_application_load(lager),
            ok = application:set_env(lager, handlers, [
                     {lager_file_backend, [
                         {file, Log},
                         {level, error},
                         {formatter, lager_default_formatter},
                         {formatter_config, [message, "\n"]}
                     ]}
                 ]),
            ok = application:set_env(lager, traces, [
                     { % get default level of debug
                         {lager_file_backend, Debug}, [{module, ?MODULE}]
                     },
                     { % Handler                       Filters              Level
                         {lager_file_backend, Events}, [{module, ?MODULE}], notice
                     }
                 ]),
            ok = application:set_env(lager, async_threshold, undefined),
            ok = lager:start(),
            {Log, Debug, Events}
        end,
        fun({_, _, _}) ->
            catch ets:delete(lager_config),
            ok = application:unset_env(lager, traces),
            ok = application:stop(lager),
            ok = lager_util:delete_test_dir(),
            ok = error_logger:tty(true)
        end, [
        fun({Log, Debug, Events}) ->
            {"a trace using file backend set up in configuration should work",
            fun() ->
                lager:error("trace test error message"),
                lager:info("info message"),
                %% not eligible for trace
                lager:log(error, self(), "Not trace test message"),
                {ok, BinInfo} = file:read_file(Events),
                ?assertMatch([_, _, "[error]", _, "trace test error message\n"],
                    re:split(BinInfo, " ", [{return, list}, {parts, 5}])),
                ?assert(filelib:is_regular(Log)),
                {ok, BinInfo2} = file:read_file(Log),
                ?assertMatch(["trace test error message", "Not trace test message\n"],
                    re:split(BinInfo2, "\n", [{return, list}, {parts, 2}])),
                ?assert(filelib:is_regular(Debug)),
                %% XXX Aughhhh, wish I could force this to flush somehow...
                % should take about 1 second, try for 3 ...
                ?assertEqual(2, count_lines_until(2, add_secs(os:timestamp(), 3), Debug, 0))
            end}
        end
    ]}.

count_lines_until(Lines, Timeout, File, Last) ->
    case timer:now_diff(Timeout, os:timestamp()) > 0 of
        true ->
            timer:sleep(333),
            {ok, Bin} = file:read_file(File),
            case erlang:length(re:split(Bin, "\n", [{return, list}, trim])) of
                Count when Count < Lines ->
                    count_lines_until(Lines, Timeout, File, Count);
                Count ->
                    Count
            end;
        _ ->
            Last
    end.

formatting_test_() ->
    {foreach,
        fun() ->
            {ok, TestDir} = lager_util:get_test_dir(),
            Log1 = filename:join(TestDir, "test.log"),
            Log2 = filename:join(TestDir, "test2.log"),
            ?assertEqual(ok, lager_util:safe_write_file(Log1, [])),
            ?assertEqual(ok, lager_util:safe_write_file(Log2, [])),
            ok = error_logger:tty(false),
            ok = lager_util:safe_application_load(lager),
            ok = application:set_env(lager, handlers, [{lager_test_backend, info}]),
            ok = application:set_env(lager, error_logger_redirect, false),
            ok = lager:start(),
            %% same race condition issue
            ok = timer:sleep(5),
            {ok, Log1, Log2}
        end,
        fun({ok, _, _}) ->
            ok = application:stop(lager),
            ok = application:stop(goldrush),
            ok = lager_util:delete_test_dir(),
            ok = error_logger:tty(true)
        end, [
        fun({ok, Log1, Log2}) ->
            {"Should have two log files, the second prefixed with 2>",
            fun() ->
                gen_event:add_handler(lager_event, lager_file_backend,
                    [{Log1, debug}, {lager_default_formatter, ["[",severity,"] ", message, "\n"]}]),
                gen_event:add_handler(lager_event, lager_file_backend,
                    [{Log2, debug}, {lager_default_formatter, ["2> [",severity,"] ", message, "\n"]}]),
                lager:log(error, self(), "Test message"),
                ?assertMatch({ok, <<"[error] Test message\n">>},file:read_file(Log1)),
                ?assertMatch({ok, <<"2> [error] Test message\n">>},file:read_file(Log2))
            end}
        end
    ]}.

config_validation_test_() ->
    [
        {"missing file",
            ?_assertEqual(false,
                validate_logfile_proplist([{level, info}, {size, 10}]))
        },
        {"bad level",
            ?_assertEqual(false,
                validate_logfile_proplist([{file, "test.log"}, {level, blah}, {size, 10}]))
        },
        {"bad size",
            ?_assertEqual(false,
                validate_logfile_proplist([{file, "test.log"}, {size, infinity}]))
        },
        {"bad count",
            ?_assertEqual(false,
                validate_logfile_proplist([{file, "test.log"}, {count, infinity}]))
        },
        {"bad high water mark",
            ?_assertEqual(false,
                validate_logfile_proplist([{file, "test.log"}, {high_water_mark, infinity}]))
        },
        {"bad date",
            ?_assertEqual(false,
                validate_logfile_proplist([{file, "test.log"}, {date, "midnight"}]))
        },
        {"blank date is ok",
            ?_assertMatch([_|_],
                validate_logfile_proplist([{file, "test.log"}, {date, ""}]))
        },
        {"bad sync_interval",
            ?_assertEqual(false,
                validate_logfile_proplist([{file, "test.log"}, {sync_interval, infinity}]))
        },
        {"bad sync_size",
            ?_assertEqual(false,
                validate_logfile_proplist([{file, "test.log"}, {sync_size, infinity}]))
        },
        {"bad check_interval",
            ?_assertEqual(false,
                validate_logfile_proplist([{file, "test.log"}, {check_interval, infinity}]))
        },
        {"bad sync_on level",
            ?_assertEqual(false,
                validate_logfile_proplist([{file, "test.log"}, {sync_on, infinity}]))
        },
        {"bad formatter module",
            ?_assertEqual(false,
                validate_logfile_proplist([{file, "test.log"}, {formatter, "io:format"}]))
        },
        {"bad formatter config",
            ?_assertEqual(false,
                validate_logfile_proplist([{file, "test.log"}, {formatter_config, blah}]))
        },
        {"unknown option",
            ?_assertEqual(false,
                validate_logfile_proplist([{file, "test.log"}, {rhubarb, spicy}]))
        }
    ].

-endif.
