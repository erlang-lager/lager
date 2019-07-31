-module(lager_rotator_default).

-include_lib("kernel/include/file.hrl").

-behaviour(lager_rotator_behaviour).

-export([
    create_logfile/2, open_logfile/2, ensure_logfile/5, rotate_logfile/2
]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

create_logfile(Name, Buffer) ->
    open_logfile(Name, Buffer).

open_logfile(Name, Buffer) ->
    case filelib:ensure_dir(Name) of
        ok ->
            Options = [append, raw] ++
            case Buffer of
                {Size0, Interval} when is_integer(Interval), Interval >= 0, is_integer(Size0), Size0 >= 0 ->
                    [{delayed_write, Size0, Interval}];
                _ -> []
            end,
            case file:open(Name, Options) of
                {ok, FD} ->
                    case file:read_file_info(Name) of
                        {ok, FInfo} ->
                            Inode = FInfo#file_info.inode,
                            Ctime = FInfo#file_info.ctime,
                            Size1 = FInfo#file_info.size,
                            {ok, {FD, Inode, Ctime, Size1}};
                        X -> X
                    end;
                Y -> Y
            end;
        Z -> Z
    end.

ensure_logfile(Name, undefined, _Inode, _Ctime, Buffer) ->
    open_logfile(Name, Buffer);
ensure_logfile(Name, FD, Inode0, Ctime0, Buffer) ->
    case file:read_file_info(Name) of
        {ok, FInfo} ->
            {OsType, _} = os:type(),
            Inode1 = FInfo#file_info.inode,
            Ctime1 = FInfo#file_info.ctime,
            case {OsType, Inode0 =:= Inode1, Ctime0 =:= Ctime1} of
                % Note: on win32, Inode is always zero
                % So check the file's ctime to see if it
                % needs to be re-opened
                {win32, _, false} ->
                    reopen_logfile(Name, FD, Buffer);
                {win32, _, true} ->
                    {ok, {FD, Inode0, Ctime0, FInfo#file_info.size}};
                {unix, true, _} ->
                    {ok, {FD, Inode0, Ctime0, FInfo#file_info.size}};
                {unix, false, _} ->
                    reopen_logfile(Name, FD, Buffer)
            end;
        _ ->
            reopen_logfile(Name, FD, Buffer)
    end.

reopen_logfile(Name, FD0, Buffer) ->
    %% delayed write can cause file:close not to do a close
    _ = file:close(FD0),
    _ = file:close(FD0),
    case open_logfile(Name, Buffer) of
        {ok, {_FD1, _Inode, _Size, _Ctime}=FileInfo} ->
            %% inode changed, file was probably moved and
            %% recreated
            {ok, FileInfo};
        Error ->
            Error
    end.

%% renames failing are OK
rotate_logfile(File, 0) ->
    %% open the file in write-only mode to truncate/create it
    case file:open(File, [write]) of
        {ok, FD} ->
            _ = file:close(FD),
            ok;
        Error ->
            Error
    end;
rotate_logfile(File0, 1) ->
    File1 = File0 ++ ".0",
    _ = file:rename(File0, File1),
    rotate_logfile(File0, 0);
rotate_logfile(File0, Count) ->
    File1 = File0 ++ "." ++ integer_to_list(Count - 2),
    File2 = File0 ++ "." ++ integer_to_list(Count - 1),
    _ = file:rename(File1, File2),
    rotate_logfile(File0, Count - 1).

-ifdef(TEST).

rotate_file_test() ->
    RotCount = 10,
    TestDir = lager_util:create_test_dir(),
    TestLog = filename:join(TestDir, "rotation.log"),
    Outer = fun(N) ->
        ?assertEqual(ok, file:write_file(TestLog, erlang:integer_to_list(N))),
        Inner = fun(M) ->
            File = lists:flatten([TestLog, $., erlang:integer_to_list(M)]),
            ?assert(filelib:is_regular(File)),
            %% check the expected value is in the file
            Number = erlang:list_to_binary(integer_to_list(N - M - 1)),
            ?assertEqual({ok, Number}, file:read_file(File))
        end,
        Count = erlang:min(N, RotCount),
        % The first time through, Count == 0, so the sequence is empty,
        % effectively skipping the inner loop so a rotation can occur that
        % creates the file that Inner looks for.
        % Don't shoot the messenger, it was worse before this refactoring.
        lists:foreach(Inner, lists:seq(0, Count-1)),
        rotate_logfile(TestLog, RotCount)
    end,
    lists:foreach(Outer, lists:seq(0, (RotCount * 2))),
    lager_util:delete_test_dir(TestDir).

rotate_file_zero_count_test() ->
    %% Test that a rotation count of 0 simply truncates the file
    TestDir = lager_util:create_test_dir(),
    TestLog = filename:join(TestDir, "rotation.log"),
    ?assertMatch(ok, rotate_logfile(TestLog, 0)),
    ?assertNot(filelib:is_regular(TestLog ++ ".0")),
    ?assertEqual(true, filelib:is_regular(TestLog)),
    ?assertEqual(1, length(filelib:wildcard(TestLog++"*"))),
    %% assert the new file is 0 size:
    case file:read_file_info(TestLog) of
        {ok, FInfo} ->
            ?assertEqual(0, FInfo#file_info.size);
        _ ->
            ?assert(false)
    end,
    lager_util:delete_test_dir(TestDir).

rotate_file_fail_test() ->
    TestDir = lager_util:create_test_dir(),
    TestLog = filename:join(TestDir, "rotation.log"),

    %% set known permissions on it
    ok = lager_util:set_dir_permissions("u+rwx", TestDir),

    %% write a file
    file:write_file(TestLog, "hello"),

    case os:type() of
        {win32, _} -> ok;
        _ ->
            %% hose up the permissions
            ok = lager_util:set_dir_permissions("u-w", TestDir),
            ?assertMatch({error, _}, rotate_logfile(TestLog, 10))
    end,

    %% check we still only have one file, rotation.log
    ?assertEqual([TestLog], filelib:wildcard(TestLog++"*")),
    ?assert(filelib:is_regular(TestLog)),

    %% fix the permissions
    ok = lager_util:set_dir_permissions("u+w", TestDir),

    ?assertMatch(ok, rotate_logfile(TestLog, 10)),
    ?assert(filelib:is_regular(TestLog ++ ".0")),
    ?assertEqual(true, filelib:is_regular(TestLog)),
    ?assertEqual(2, length(filelib:wildcard(TestLog++"*"))),

    %% assert the new file is 0 size:
    case file:read_file_info(TestLog) of
        {ok, FInfo} ->
            ?assertEqual(0, FInfo#file_info.size);
        _ ->
            ?assert(false)
    end,

    %% check that the .0 file now has the contents "hello"
    ?assertEqual({ok, <<"hello">>}, file:read_file(TestLog++".0")),
    lager_util:delete_test_dir(TestDir).

-endif.
