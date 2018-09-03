-module(lager_rotator_default).

-include_lib("kernel/include/file.hrl").

-behaviour(lager_rotator_behaviour).

-export([
    create_logfile/2, open_logfile/2, ensure_logfile/4, rotate_logfile/2
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
            case  Buffer of
                {Size, Interval} when is_integer(Interval), Interval >= 0, is_integer(Size), Size >= 0 ->
                    [{delayed_write, Size, Interval}];
                _ -> []
            end,
            case file:open(Name, Options) of
                {ok, FD} ->
                    case file:read_file_info(Name) of
                        {ok, FInfo} ->
                            Inode = FInfo#file_info.inode,
                            {ok, {FD, Inode, FInfo#file_info.size}};
                        X -> X
                    end;
                Y -> Y
            end;
        Z -> Z
    end.

ensure_logfile(Name, FD, Inode, Buffer) ->
    case file:read_file_info(Name) of
        {ok, FInfo} ->
            Inode2 = FInfo#file_info.inode,
            case Inode == Inode2 of
                true ->
                    {ok, {FD, Inode, FInfo#file_info.size}};
                false ->
                    %% delayed write can cause file:close not to do a close
                    _ = file:close(FD),
                    _ = file:close(FD),
                    case open_logfile(Name, Buffer) of
                        {ok, {FD2, Inode3, Size}} ->
                            %% inode changed, file was probably moved and
                            %% recreated
                            {ok, {FD2, Inode3, Size}};
                        Error ->
                            Error
                    end
            end;
        _ ->
            %% delayed write can cause file:close not to do a close
            _ = file:close(FD),
            _ = file:close(FD),
            case open_logfile(Name, Buffer) of
                {ok, {FD2, Inode3, Size}} ->
                    %% file was removed
                    {ok, {FD2, Inode3, Size}};
                Error ->
                    Error
            end
    end.

%% renames failing are OK
rotate_logfile(File, 0) ->
    %% open the file in write-only mode to truncate/create it
    case file:open(File, [write]) of
        {ok, FD} ->
            file:close(FD),
            ok;
        Error ->
            Error
    end;
rotate_logfile(File, 1) ->
    _ = file:rename(File, File++".0"),
    rotate_logfile(File, 0);
rotate_logfile(File, Count) ->
    _ = file:rename(File ++ "." ++ integer_to_list(Count - 2), File ++ "." ++ integer_to_list(Count - 1)),
    rotate_logfile(File, Count - 1).

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
    os:cmd("chmod -R u+rwx " ++ TestDir),
    %% write a file
    file:write_file(TestLog, "hello"),
    %% hose up the permissions
    os:cmd("chmod -R u-w " ++ TestDir),
    ?assertMatch({error, _}, rotate_logfile(TestLog, 10)),
    %% check we still only have one file, rotation.log
    ?assertEqual([TestLog], filelib:wildcard(TestLog++"*")),
    ?assert(filelib:is_regular(TestLog)),
    %% fix the permissions
    os:cmd("chmod -R u+w " ++ TestDir),
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
