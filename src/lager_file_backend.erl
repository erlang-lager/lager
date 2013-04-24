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

-behaviour(gen_event).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").
-compile([{parse_transform, lager_transform}]).
-endif.

-export([init/1, handle_call/2, handle_event/2, handle_info/2, terminate/2,
        code_change/3]).

-export([config_to_id/1]).

-define(DEFAULT_LOG_LEVEL, info).
-define(DEFAULT_ROTATION_SIZE, 10485760). %% 10mb
-define(DEFAULT_ROTATION_DATE, "$D0"). %% midnight
-define(DEFAULT_ROTATION_COUNT, 5).
-define(DEFAULT_SYNC_LEVEL, error).
-define(DEFAULT_SYNC_INTERVAL, 1000).
-define(DEFAULT_SYNC_SIZE, 1024*64). %% 64kb
-define(DEFAULT_CHECK_INTERVAL, 1000).

-record(state, {
        name :: string(),
        level :: {'mask', integer()},
        fd :: file:io_device(),
        inode :: integer(),
        flap=false :: boolean(),
        size = 0 :: integer(),
        date,
        count = 10,
        formatter,
        formatter_config,
        sync_on,
        check_interval = ?DEFAULT_CHECK_INTERVAL,
        sync_interval = ?DEFAULT_SYNC_INTERVAL,
        sync_size = ?DEFAULT_SYNC_SIZE,
        last_check = os:timestamp()
    }).

-type option() :: {file, string()} | {level, lager:log_level()} |
                  {size, non_neg_integer()} | {date, string()} |
                  {count, non_neg_integer()} | {sync_interval, non_neg_integer()} |
                  {sync_size, non_neg_integer()} | {sync_on, lager:log_level()} |
                  {check_interval, non_neg_integer()} | {formatter, atom()} |
                  {formatter_config, term()}.

-spec init([option(),...]) -> {ok, #state{}} | {error, bad_config}.
init({FileName, LogLevel}) when is_list(FileName), is_atom(LogLevel) ->
    %% backwards compatability hack
    init([{file, FileName}, {level, LogLevel}]);
init({FileName, LogLevel, Size, Date, Count}) when is_list(FileName), is_atom(LogLevel) ->
    %% backwards compatability hack
    init([{file, FileName}, {level, LogLevel}, {size, Size}, {date, Date}, {count, Count}]);
init([{FileName, LogLevel, Size, Date, Count}, {Formatter,FormatterConfig}]) when is_list(FileName), is_atom(LogLevel), is_atom(Formatter) ->
    %% backwards compatability hack
    init([{file, FileName}, {level, LogLevel}, {size, Size}, {date, Date}, {count, Count}, {formatter, Formatter}, {formatter_config, FormatterConfig}]);
init([LogFile,{Formatter}]) ->
    %% backwards compatability hack
    init([LogFile,{Formatter,[]}]);
init([{FileName, LogLevel}, {Formatter,FormatterConfig}]) when is_list(FileName), is_atom(LogLevel), is_atom(Formatter) ->
    %% backwards compatability hack
    init([{file, FileName}, {level, LogLevel}, {formatter, Formatter}, {formatter_config, FormatterConfig}]);
init(LogFileConfig) when is_list(LogFileConfig) ->
    case validate_logfile_proplist(LogFileConfig) of
        false ->
            %% falied to validate config
            {error, {fatal, bad_config}};
        Config ->
            %% probabably a better way to do this, but whatever
            [Name, Level, Date, Size, Count, SyncInterval, SyncSize, SyncOn, CheckInterval, Formatter, FormatterConfig] =
              [proplists:get_value(Key, Config) || Key <- [file, level, date, size, count, sync_interval, sync_size, sync_on, check_interval, formatter, formatter_config]],
            schedule_rotation(Name, Date),
            State0 = #state{name=Name, level=Level, size=Size, date=Date, count=Count, formatter=Formatter,
                formatter_config=FormatterConfig, sync_on=SyncOn, sync_interval=SyncInterval, sync_size=SyncSize,
                check_interval=CheckInterval},
            State = case lager_util:open_logfile(Name, {SyncSize, SyncInterval}) of
                {ok, {FD, Inode, _}} ->
                    State0#state{fd=FD, inode=Inode};
                {error, Reason} ->
                    ?INT_LOG(error, "Failed to open log file ~s with error ~s", [Name, file:format_error(Reason)]),
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
handle_call(_Request, State) ->
    {ok, ok, State}.

%% @private
handle_event({log, Message},
    #state{name=Name, level=L,formatter=Formatter,formatter_config=FormatConfig} = State) ->
    case lager_util:is_loggable(Message,L,{lager_file_backend, Name}) of
        true ->
            {ok,write(State, lager_msg:timestamp(Message), lager_msg:severity_as_int(Message), Formatter:format(Message,FormatConfig)) };
        false ->
            {ok, State}
    end;
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

%% @private convert the config into a gen_event handler ID
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


write(#state{name=Name, fd=FD, inode=Inode, flap=Flap, size=RotSize,
        count=Count} = State, Timestamp, Level, Msg) ->
    LastCheck = timer:now_diff(Timestamp, State#state.last_check) div 1000,
    case LastCheck >= State#state.check_interval orelse FD == undefined of
        true ->
            %% need to check for rotation
            case lager_util:ensure_logfile(Name, FD, Inode, {State#state.sync_size, State#state.sync_interval}) of
                {ok, {_, _, Size}} when RotSize /= 0, Size > RotSize ->
                    lager_util:rotate_logfile(Name, Count),
                    %% go around the loop again, we'll do another rotation check and hit the next clause here
                    write(State, Timestamp, Level, Msg);
                {ok, {NewFD, NewInode, _}} ->
                    %% update our last check and try again
                    do_write(State#state{last_check=Timestamp, fd=NewFD, inode=NewInode}, Level, Msg);
                {error, Reason} ->
                    case Flap of
                        true ->
                            State;
                        _ ->
                            ?INT_LOG(error, "Failed to reopen log file ~s with error ~s", [Name, file:format_error(Reason)]),
                            State#state{flap=true}
                    end
            end;
        false ->
            do_write(State, Level, Msg)
    end.

do_write(#state{fd=FD, name=Name, flap=Flap} = State, Level, Msg) ->
    %% delayed_write doesn't report errors
    _ = file:write(FD, unicode:characters_to_binary(Msg)),
    {mask, SyncLevel} = State#state.sync_on,
    case (Level band SyncLevel) /= 0 of
        true ->
            %% force a sync on any message that matches the 'sync_on' bitmask
            Flap2 = case file:datasync(FD) of
                {error, Reason2} when Flap == false ->
                    ?INT_LOG(error, "Failed to write log message to file ~s: ~s",
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
                            {sync_on, validate_loglevel(?DEFAULT_SYNC_LEVEL)}, {sync_interval, ?DEFAULT_SYNC_INTERVAL},
                            {sync_size, ?DEFAULT_SYNC_SIZE}, {check_interval, ?DEFAULT_CHECK_INTERVAL},
                            {formatter, lager_default_formatter}, {formatter_config, []}
                        ]))
            end
    catch
        {bad_config, Msg, Value} ->
            ?INT_LOG(error, "~s ~p for file ~p",
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
validate_logfile_proplist([{date, Date}|Tail], Acc) ->
    case lager_util:parse_rotation_date_spec(Date) of
        {ok, Spec} ->
            validate_logfile_proplist(Tail, [{date, Spec}|Acc]);
        {error, _} when Date == "" ->
            %% legacy config allowed blanks
            validate_logfile_proplist(Tail, Acc);
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
validate_logfile_proplist([Other|_Tail], _Acc) ->
    throw({bad_config, "Invalid option", Other}).

schedule_rotation(_, undefined) ->
    ok;
schedule_rotation(Name, Date) ->
    erlang:send_after(lager_util:calculate_next_rotation(Date) * 1000, self(), {rotate, Name}),
    ok.

-ifdef(TEST).

get_loglevel_test() ->
    {ok, Level, _} = handle_call(get_loglevel,
        #state{name="bar", level=lager_util:config_to_mask(info), fd=0, inode=0}),
    ?assertEqual(Level, lager_util:config_to_mask(info)),
    {ok, Level2, _} = handle_call(get_loglevel,
        #state{name="foo", level=lager_util:config_to_mask(warning), fd=0, inode=0}),
    ?assertEqual(Level2, lager_util:config_to_mask(warning)).

rotation_test_() ->
    {foreach,
     fun() ->
             [file:delete(F)||F <- filelib:wildcard("test.log*")],
             SyncLevel = validate_loglevel(?DEFAULT_SYNC_LEVEL),
             SyncSize = ?DEFAULT_SYNC_SIZE,
             SyncInterval = ?DEFAULT_SYNC_INTERVAL,
             CheckInterval = 0, %% hard to test delayed mode

             #state{name="test.log", level=?DEBUG, sync_on=SyncLevel,
                    sync_size=SyncSize, sync_interval=SyncInterval, check_interval=CheckInterval}

     end,
     fun(_) ->
             [file:delete(F)||F <- filelib:wildcard("test.log*")]
     end,
     [fun(DefaultState = #state{sync_size=SyncSize, sync_interval = SyncInterval}) ->
          {"External rotation should work",
           fun() ->
                   {ok, {FD, Inode, _}} = lager_util:open_logfile("test.log", {SyncSize, SyncInterval}),
                   State0 = DefaultState#state{fd=FD, inode=Inode},
                   ?assertMatch(#state{name="test.log", level=?DEBUG, fd=FD, inode=Inode},
                                write(State0, os:timestamp(), ?DEBUG, "hello world")),
                   file:delete("test.log"),
                   Result = write(State0, os:timestamp(), ?DEBUG, "hello world"),
                   %% assert file has changed
                   ?assert(#state{name="test.log", level=?DEBUG, fd=FD, inode=Inode} =/= Result),
                   ?assertMatch(#state{name="test.log", level=?DEBUG}, Result),
                   file:rename("test.log", "test.log.1"),
                   Result2 = write(Result, os:timestamp(), ?DEBUG, "hello world"),
                   %% assert file has changed
                   ?assert(Result =/= Result2),
                   ?assertMatch(#state{name="test.log", level=?DEBUG}, Result2),
                   ok
           end}
      end,
      fun(DefaultState = #state{sync_size=SyncSize, sync_interval = SyncInterval}) ->
          {"Internal rotation and delayed write",
           fun() ->
                   CheckInterval = 3000, % 3 sec
                   RotationSize = 15,
                   PreviousCheck = os:timestamp(),

                   {ok, {FD, Inode, _}} = lager_util:open_logfile("test.log", {SyncSize, SyncInterval}),
                   State0 = DefaultState#state{
                              fd=FD, inode=Inode, size=RotationSize,
                              check_interval=CheckInterval, last_check=PreviousCheck},

                   %% new message within check interval with sync_on level
                   Msg1Timestamp = add_secs(PreviousCheck, 1),
                   State0 = State1 = write(State0, Msg1Timestamp, ?ERROR, "big big message 1"),

                   %% new message within check interval under sync_on level
                   %% not written to disk yet
                   Msg2Timestamp = add_secs(PreviousCheck, 2),
                   State0 = State2 = write(State1, Msg2Timestamp, ?DEBUG, "buffered message 2"),

                   %% although file size is big enough...
                   {ok, FInfo} = file:read_file_info("test.log"),
                   ?assert(RotationSize < FInfo#file_info.size),
                   %% ...no rotation yet
                   ?assertEqual(PreviousCheck, State2#state.last_check),
                   ?assertNot(filelib:is_regular("test.log.0")),

                   %% new message after check interval
                   Msg3Timestamp = add_secs(PreviousCheck, 4),
                   _State3 = write(State2, Msg3Timestamp, ?DEBUG, "message 3"),

                   %% rotation happened
                   ?assert(filelib:is_regular("test.log.0")),

                   {ok, Bin1} = file:read_file("test.log.0"),
                   {ok, Bin2} = file:read_file("test.log"),
                   %% message 1-3 written to file
                   ?assertEqual(<<"big big message 1buffered message 2">>, Bin1),
                   %% message 4 buffered, not yet written to file
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
                file:write_file("test.log", ""),
                error_logger:tty(false),
                application:load(lager),
                application:set_env(lager, handlers, [{lager_test_backend, info}]),
                application:set_env(lager, error_logger_redirect, false),
                application:set_env(lager, async_threshold, undefined),
                application:start(lager)
        end,
        fun(_) ->
                file:delete("test.log"),
                file:delete("test.log.0"),
                file:delete("test.log.1"),
                application:stop(lager),
                error_logger:tty(true)
        end,
        [
            {"under normal circumstances, file should be opened",
                fun() ->
                        gen_event:add_handler(lager_event, lager_file_backend, [{"test.log", info}, {lager_default_formatter}]),
                        lager:log(error, self(), "Test message"),
                        {ok, Bin} = file:read_file("test.log"),
                        Pid = pid_to_list(self()),
                        ?assertMatch([_, _, "[error]", Pid, "Test message\n"], re:split(Bin, " ", [{return, list}, {parts, 5}]))
                end
            },
            {"don't choke on unicode",
                fun() ->
                        gen_event:add_handler(lager_event, lager_file_backend, [{"test.log", info}, {lager_default_formatter}]),
                        lager:log(error, self(),"~ts", [[20013,25991,27979,35797]]),
                        {ok, Bin} = file:read_file("test.log"),
                        Pid = pid_to_list(self()),
                        ?assertMatch([_, _, "[error]", Pid,  [228,184,173,230,150,135,230,181,139,232,175,149, $\n]], re:split(Bin, " ", [{return, list}, {parts, 5}]))
                end
            },
            {"don't choke on latin-1",
                fun() ->
                        %% XXX if this test fails, check that this file is encoded latin-1, not utf-8!
                        gen_event:add_handler(lager_event, lager_file_backend, [{"test.log", info}, {lager_default_formatter}]),
                        lager:log(error, self(),"~ts", ["L���N-�"]),
                        {ok, Bin} = file:read_file("test.log"),
                        Pid = pid_to_list(self()),
                        Res = re:split(Bin, " ", [{return, list}, {parts, 5}]),
                        ?assertMatch([_, _, "[error]", Pid,  [76,195,134,195,157,195,142,78,45,195,175,$\n]], Res)
                end
            },
            {"file can't be opened on startup triggers an error message",
                fun() ->
                        {ok, FInfo} = file:read_file_info("test.log"),
                        file:write_file_info("test.log", FInfo#file_info{mode = 0}),
                        gen_event:add_handler(lager_event, lager_file_backend, {"test.log", info, 10*1024*1024, "$D0", 5}),
                        ?assertEqual(1, lager_test_backend:count()),
                        {_Level, _Time,Message,_Metadata} = lager_test_backend:pop(),
                        ?assertEqual("Failed to open log file test.log with error permission denied", lists:flatten(Message))
                end
            },
            {"file that becomes unavailable at runtime should trigger an error message",
                fun() ->
                        gen_event:add_handler(lager_event, lager_file_backend, [{file, "test.log"}, {level, info}, {check_interval, 0}]),
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
                        {_Level, _Time, Message,_Metadata} = lager_test_backend:pop(),
                        ?assertEqual("Failed to reopen log file test.log with error permission denied", lists:flatten(Message))
                end
            },
            {"unavailable files that are fixed at runtime should start having log messages written",
                fun() ->
                        {ok, FInfo} = file:read_file_info("test.log"),
                        OldPerms = FInfo#file_info.mode,
                        file:write_file_info("test.log", FInfo#file_info{mode = 0}),
                        gen_event:add_handler(lager_event, lager_file_backend, [{file, "test.log"},{check_interval, 0}]),
                        ?assertEqual(1, lager_test_backend:count()),
                        {_Level, _Time, Message,_Metadata} = lager_test_backend:pop(),
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
                        gen_event:add_handler(lager_event, lager_file_backend, [{file, "test.log"}, {level, info}, {check_interval, 0}]),
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
            {"internal size rotation should work",
                fun() ->
                        gen_event:add_handler(lager_event, lager_file_backend, [{file, "test.log"}, {level, info}, {check_interval, 0}, {size, 10}]),
                        lager:log(error, self(), "Test message1"),
                        lager:log(error, self(), "Test message1"),
                        ?assert(filelib:is_regular("test.log.0"))
                end
            },
            {"internal time rotation should work",
                fun() ->
                        gen_event:add_handler(lager_event, lager_file_backend, [{file, "test.log"}, {level, info}, {check_interval, 1000}]),
                        lager:log(error, self(), "Test message1"),
                        lager:log(error, self(), "Test message1"),
                        whereis(lager_event) ! {rotate, "test.log"},
                        lager:log(error, self(), "Test message1"),
                        ?assert(filelib:is_regular("test.log.0"))
                end
            },
            {"sync_on option should work",
                fun() ->
                        gen_event:add_handler(lager_event, lager_file_backend, [{file, "test.log"}, {level, info}, {sync_on, "=info"}, {check_interval, 5000}, {sync_interval, 5000}]),
                        lager:log(error, self(), "Test message1"),
                        lager:log(error, self(), "Test message1"),
                        ?assertEqual({ok, <<>>}, file:read_file("test.log")),
                        lager:log(info, self(), "Test message1"),
                        {ok, Bin} = file:read_file("test.log"),
                        ?assert(<<>> /= Bin)
                end
            },
            {"sync_on none option should work (also tests sync_interval)",
                fun() ->
                        gen_event:add_handler(lager_event, lager_file_backend, [{file, "test.log"}, {level, info}, {sync_on, "none"}, {check_interval, 5000}, {sync_interval, 1000}]),
                        lager:log(error, self(), "Test message1"),
                        lager:log(error, self(), "Test message1"),
                        ?assertEqual({ok, <<>>}, file:read_file("test.log")),
                        lager:log(info, self(), "Test message1"),
                        ?assertEqual({ok, <<>>}, file:read_file("test.log")),
                        timer:sleep(1000),
                        {ok, Bin} = file:read_file("test.log"),
                        ?assert(<<>> /= Bin)
                end
            },
            {"sync_size option should work",
                fun() ->
                        gen_event:add_handler(lager_event, lager_file_backend, [{file, "test.log"}, {level, info}, {sync_on, "none"}, {check_interval, 5001}, {sync_size, 640}, {sync_interval, 5001}]),
                        lager:log(error, self(), "Test messageis64bytes"),
                        lager:log(error, self(), "Test messageis64bytes"),
                        lager:log(error, self(), "Test messageis64bytes"),
                        lager:log(error, self(), "Test messageis64bytes"),
                        lager:log(error, self(), "Test messageis64bytes"),
                        ?assertEqual({ok, <<>>}, file:read_file("test.log")),
                        lager:log(error, self(), "Test messageis64bytes"),
                        lager:log(error, self(), "Test messageis64bytes"),
                        lager:log(error, self(), "Test messageis64bytes"),
                        lager:log(error, self(), "Test messageis64bytes"),
                        ?assertEqual({ok, <<>>}, file:read_file("test.log")),
                        %% now we've written enough bytes
                        lager:log(error, self(), "Test messageis64bytes"),
                        {ok, Bin} = file:read_file("test.log"),
                        ?assert(<<>> /= Bin)
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
                        gen_event:add_handler(lager_event, lager_file_backend, [{"test.log", info, 10*1024*1024, "$D0", 5}, {lager_default_formatter}]),
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
                        {Level, _} = lager_config:get(loglevel),
                        lager_config:set(loglevel, {Level, [{[{module,
                                                ?MODULE}], ?DEBUG,
                                        {lager_file_backend, "test.log"}}]}),
                        lager:error("Test message"),
                        timer:sleep(1000),
                        {ok, Bin} = file:read_file("test.log"),
                        ?assertMatch([_, _, "[error]", _, "Test message\n"], re:split(Bin, " ", [{return, list}, {parts, 5}]))
                end
            },
            {"tracing should not duplicate messages",
                fun() ->
                        gen_event:add_handler(lager_event, lager_file_backend,
                            [{file, "test.log"}, {level, critical}, {check_interval, always}]),
                        lager:critical("Test message"),
                        {ok, Bin1} = file:read_file("test.log"),
                        ?assertMatch([_, _, "[critical]", _, "Test message\n"], re:split(Bin1, " ", [{return, list}, {parts, 5}])),
                        ok = file:delete("test.log"),
                        {Level, _} = lager_config:get(loglevel),
                        lager_config:set(loglevel, {Level, [{[{module,
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
                        %% not elegible for trace
                        lager:log(error, self(), "Test message"),
                        {ok, Bin3} = file:read_file("foo.log"),
                        ?assertMatch([_, _, "[error]", _, "Test message\n"], re:split(Bin3, " ", [{return, list}, {parts, 5}]))
                end
            }
        ]
    }.

formatting_test_() ->
    {foreach,
        fun() ->
                file:write_file("test.log", ""),
                file:write_file("test2.log", ""),
                error_logger:tty(false),
                application:load(lager),
                application:set_env(lager, handlers, [{lager_test_backend, info}]),
                application:set_env(lager, error_logger_redirect, false),
                application:start(lager)
        end,
        fun(_) ->
                file:delete("test.log"),
                file:delete("test2.log"),
                application:stop(lager),
                error_logger:tty(true)
        end,
            [{"Should have two log files, the second prefixed with 2>",
                fun() ->
                       gen_event:add_handler(lager_event, lager_file_backend,[{"test.log", debug},{lager_default_formatter,["[",severity,"] ", message, "\n"]}]),
                       gen_event:add_handler(lager_event, lager_file_backend,[{"test2.log", debug},{lager_default_formatter,["2> [",severity,"] ", message, "\n"]}]),
                       lager:log(error, self(), "Test message"),
                       ?assertMatch({ok, <<"[error] Test message\n">>},file:read_file("test.log")),
                       ?assertMatch({ok, <<"2> [error] Test message\n">>},file:read_file("test2.log"))
                end
            }
        ]}.

config_validation_test_() ->
    [
        {"missing file",
            ?_assertEqual(false,
                validate_logfile_proplist([{level, info},{size, 10}]))
        },
        {"bad level",
            ?_assertEqual(false,
                validate_logfile_proplist([{file, "test.log"}, {level, blah},{size, 10}]))
        },
        {"bad size",
            ?_assertEqual(false,
                validate_logfile_proplist([{file, "test.log"}, {size, infinity}]))
        },
        {"bad count",
            ?_assertEqual(false,
                validate_logfile_proplist([{file, "test.log"}, {count, infinity}]))
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

