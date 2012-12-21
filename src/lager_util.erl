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

-module(lager_util).

-include_lib("kernel/include/file.hrl").

-export([levels/0, level_to_num/1, num_to_level/1, config_to_mask/1, config_to_levels/1, mask_to_levels/1,
        open_logfile/2, ensure_logfile/4, rotate_logfile/2, format_time/0, format_time/1,
        localtime_ms/0, maybe_utc/1, parse_rotation_date_spec/1,
        calculate_next_rotation/1, validate_trace/1, check_traces/4, is_loggable/3]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("lager.hrl").

levels() ->
    [debug, info, notice, warning, error, critical, alert, emergency, none].

level_to_num(debug)     -> ?DEBUG;
level_to_num(info)      -> ?INFO;
level_to_num(notice)    -> ?NOTICE;
level_to_num(warning)   -> ?WARNING;
level_to_num(error)     -> ?ERROR;
level_to_num(critical)  -> ?CRITICAL;
level_to_num(alert)     -> ?ALERT;
level_to_num(emergency) -> ?EMERGENCY;
level_to_num(none)      -> ?LOG_NONE.

num_to_level(?DEBUG) -> debug;
num_to_level(?INFO) -> info;
num_to_level(?NOTICE) -> notice;
num_to_level(?WARNING) -> warning;
num_to_level(?ERROR) -> error;
num_to_level(?CRITICAL) -> critical;
num_to_level(?ALERT) -> alert;
num_to_level(?EMERGENCY) -> emergency;
num_to_level(?LOG_NONE) -> none.

-spec config_to_mask(atom()|string()) -> {'mask', integer()}.
config_to_mask(Conf) ->
    Levels = config_to_levels(Conf),
    {mask, lists:foldl(fun(Level, Acc) ->
                level_to_num(Level) bor Acc
            end, 0, Levels)}.

-spec mask_to_levels(non_neg_integer()) -> [lager:log_level()].
mask_to_levels(Mask) ->
    mask_to_levels(Mask, levels(), []).

mask_to_levels(_Mask, [], Acc) ->
    lists:reverse(Acc);
mask_to_levels(Mask, [Level|Levels], Acc) ->
    NewAcc = case (level_to_num(Level) band Mask) /= 0 of
        true ->
            [Level|Acc];
        false ->
            Acc
    end,
    mask_to_levels(Mask, Levels, NewAcc).

-spec config_to_levels(atom()|string()) -> [lager:log_level()].
config_to_levels(Conf) when is_atom(Conf) ->
    config_to_levels(atom_to_list(Conf));
config_to_levels([$! | Rest]) ->
    levels() -- config_to_levels(Rest);
config_to_levels([$=, $< | Rest]) ->
    [_|Levels] = config_to_levels_int(Rest),
    lists:filter(fun(E) -> not lists:member(E, Levels) end, levels());
config_to_levels([$<, $= | Rest]) ->
    [_|Levels] = config_to_levels_int(Rest),
    lists:filter(fun(E) -> not lists:member(E, Levels) end, levels());
config_to_levels([$>, $= | Rest]) ->
    config_to_levels_int(Rest);
config_to_levels([$=, $> | Rest]) ->
    config_to_levels_int(Rest);
config_to_levels([$= | Rest]) ->
    [level_to_atom(Rest)];
config_to_levels([$< | Rest]) ->
    Levels = config_to_levels_int(Rest),
    lists:filter(fun(E) -> not lists:member(E, Levels) end, levels());
config_to_levels([$> | Rest]) ->
    [_|Levels] = config_to_levels_int(Rest),
    lists:filter(fun(E) -> lists:member(E, Levels) end, levels());
config_to_levels(Conf) ->
    config_to_levels_int(Conf).

%% internal function to break the recursion loop
config_to_levels_int(Conf) ->
    Level = level_to_atom(Conf),
    lists:dropwhile(fun(E) -> E /= Level end, levels()).

level_to_atom(String) ->
    Levels = levels(),
    try list_to_existing_atom(String) of
        Atom ->
            case lists:member(Atom, Levels) of
                true ->
                    Atom;
                false ->
                    erlang:error(badarg)
            end
    catch
        _:_ ->
            erlang:error(badarg)
    end.

open_logfile(Name, Buffer) ->
    case filelib:ensure_dir(Name) of
        ok ->
            Options = [append, raw] ++
            if Buffer == true -> [delayed_write];
                true -> []
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

%% returns localtime with milliseconds included
localtime_ms() ->
    {_, _, Micro} = Now = os:timestamp(),
    {Date, {Hours, Minutes, Seconds}} = calendar:now_to_local_time(Now),
    {Date, {Hours, Minutes, Seconds, Micro div 1000 rem 1000}}.

maybe_utc({Date, {H, M, S, Ms}}) ->
    case lager_stdlib:maybe_utc({Date, {H, M, S}}) of
        {utc, {Date1, {H1, M1, S1}}} ->
            {utc, {Date1, {H1, M1, S1, Ms}}};
        {Date1, {H1, M1, S1}} ->
            {Date1, {H1, M1, S1, Ms}}
    end.

%% renames and deletes failing are OK
rotate_logfile(File, 0) ->
    _ = file:delete(File),
    ok;
rotate_logfile(File, 1) ->
    _ = file:rename(File, File++".0"),
    rotate_logfile(File, 0);
rotate_logfile(File, Count) ->
    _ =file:rename(File ++ "." ++ integer_to_list(Count - 2), File ++ "." ++
        integer_to_list(Count - 1)),
    rotate_logfile(File, Count - 1).

format_time() ->
    format_time(maybe_utc(localtime_ms())).

format_time({utc, {{Y, M, D}, {H, Mi, S, Ms}}}) ->
    {[integer_to_list(Y), $-, i2l(M), $-, i2l(D)],
     [i2l(H), $:, i2l(Mi), $:, i2l(S), $., i3l(Ms), $ , $U, $T, $C]};
format_time({{Y, M, D}, {H, Mi, S, Ms}}) ->
    {[integer_to_list(Y), $-, i2l(M), $-, i2l(D)],
     [i2l(H), $:, i2l(Mi), $:, i2l(S), $., i3l(Ms)]};
format_time({utc, {{Y, M, D}, {H, Mi, S}}}) ->
    {[integer_to_list(Y), $-, i2l(M), $-, i2l(D)],
     [i2l(H), $:, i2l(Mi), $:, i2l(S), $ , $U, $T, $C]};
format_time({{Y, M, D}, {H, Mi, S}}) ->
    {[integer_to_list(Y), $-, i2l(M), $-, i2l(D)],
     [i2l(H), $:, i2l(Mi), $:, i2l(S)]}.

parse_rotation_day_spec([], Res) ->
    {ok, Res ++ [{hour, 0}]};
parse_rotation_day_spec([$D, D1, D2], Res) ->
    case list_to_integer([D1, D2]) of
        X when X >= 0, X =< 23 ->
            {ok, Res ++ [{hour, X}]};
        _ ->
            {error, invalid_date_spec}
    end;
parse_rotation_day_spec([$D, D], Res)  when D >= $0, D =< $9 ->
    {ok, Res ++ [{hour, D - 48}]};
parse_rotation_day_spec(_, _) ->
    {error, invalid_date_spec}.

parse_rotation_date_spec([$$, $W, W|T]) when W >= $0, W =< $6 ->
    Week = W - 48,
    parse_rotation_day_spec(T, [{day, Week}]);
parse_rotation_date_spec([$$, $M, L|T]) when L == $L; L == $l ->
    %% last day in month.
    parse_rotation_day_spec(T, [{date, last}]);
parse_rotation_date_spec([$$, $M, M1, M2|[$D|_]=T]) ->
    case list_to_integer([M1, M2]) of
        X when X >= 1, X =< 31 ->
            parse_rotation_day_spec(T, [{date, X}]);
        _ ->
            {error, invalid_date_spec}
    end;
parse_rotation_date_spec([$$, $M, M|[$D|_]=T]) ->
    parse_rotation_day_spec(T, [{date, M - 48}]);
parse_rotation_date_spec([$$, $M, M1, M2]) ->
    case list_to_integer([M1, M2]) of
        X when X >= 1, X =< 31 ->
            {ok, [{date, X}, {hour, 0}]};
        _ ->
            {error, invalid_date_spec}
    end;
parse_rotation_date_spec([$$, $M, M]) ->
    {ok, [{date, M - 48}, {hour, 0}]};
parse_rotation_date_spec([$$|X]) when X /= [] ->
    parse_rotation_day_spec(X, []);
parse_rotation_date_spec(_) ->
    {error, invalid_date_spec}.

calculate_next_rotation(Spec) ->
    Now = calendar:local_time(),
    Later = calculate_next_rotation(Spec, Now),
    calendar:datetime_to_gregorian_seconds(Later) -
      calendar:datetime_to_gregorian_seconds(Now).

calculate_next_rotation([], Now) ->
    Now;
calculate_next_rotation([{hour, X}|T], {{_, _, _}, {Hour, _, _}} = Now) when Hour < X ->
    %% rotation is today, sometime
    NewNow = setelement(2, Now, {X, 0, 0}),
    calculate_next_rotation(T, NewNow);
calculate_next_rotation([{hour, X}|T], {{_, _, _}, _} = Now) ->
    %% rotation is not today
    Seconds = calendar:datetime_to_gregorian_seconds(Now) + 86400,
    DateTime = calendar:gregorian_seconds_to_datetime(Seconds),
    NewNow = setelement(2, DateTime, {X, 0, 0}),
    calculate_next_rotation(T, NewNow);
calculate_next_rotation([{day, Day}|T], {Date, _Time} = Now) ->
    DoW = calendar:day_of_the_week(Date),
    AdjustedDay = case Day of
        0 -> 7;
        X -> X
    end,
    case AdjustedDay of
        DoW -> %% rotation is today
            OldDate = element(1, Now),
            case calculate_next_rotation(T, Now) of
                {OldDate, _} = NewNow -> NewNow;
                {NewDate, _} ->
                    %% rotation *isn't* today! rerun the calculation
                    NewNow = {NewDate, {0, 0, 0}},
                    calculate_next_rotation([{day, Day}|T], NewNow)
            end;
        Y when Y > DoW -> %% rotation is later this week
            PlusDays = Y - DoW,
            Seconds = calendar:datetime_to_gregorian_seconds(Now) + (86400 * PlusDays),
            {NewDate, _} = calendar:gregorian_seconds_to_datetime(Seconds),
            NewNow = {NewDate, {0, 0, 0}},
            calculate_next_rotation(T, NewNow);
        Y when Y < DoW -> %% rotation is next week
            PlusDays = ((7 - DoW) + Y),
            Seconds = calendar:datetime_to_gregorian_seconds(Now) + (86400 * PlusDays),
            {NewDate, _} = calendar:gregorian_seconds_to_datetime(Seconds),
            NewNow = {NewDate, {0, 0, 0}},
            calculate_next_rotation(T, NewNow)
    end;
calculate_next_rotation([{date, last}|T], {{Year, Month, Day}, _} = Now) ->
    Last = calendar:last_day_of_the_month(Year, Month),
    case Last == Day of
        true -> %% doing rotation today
            OldDate = element(1, Now),
            case calculate_next_rotation(T, Now) of
                {OldDate, _} = NewNow -> NewNow;
                {NewDate, _} ->
                    %% rotation *isn't* today! rerun the calculation
                    NewNow = {NewDate, {0, 0, 0}},
                    calculate_next_rotation([{date, last}|T], NewNow)
            end;
        false ->
            NewNow = setelement(1, Now, {Year, Month, Last}),
            calculate_next_rotation(T, NewNow)
    end;
calculate_next_rotation([{date, Date}|T], {{_, _, Date}, _} = Now) ->
    %% rotation is today
    OldDate = element(1, Now),
    case calculate_next_rotation(T, Now) of
        {OldDate, _} = NewNow -> NewNow;
        {NewDate, _} ->
            %% rotation *isn't* today! rerun the calculation
            NewNow = setelement(1, Now, NewDate),
            calculate_next_rotation([{date, Date}|T], NewNow)
    end;
calculate_next_rotation([{date, Date}|T], {{Year, Month, Day}, _} = Now) ->
    PlusDays = case Date of
        X when X < Day -> %% rotation is next month
            Last = calendar:last_day_of_the_month(Year, Month),
            (Last - Day);
        X when X > Day -> %% rotation is later this month
            X - Day
    end,
    Seconds = calendar:datetime_to_gregorian_seconds(Now) + (86400 * PlusDays),
    NewNow = calendar:gregorian_seconds_to_datetime(Seconds),
    calculate_next_rotation(T, NewNow).

validate_trace({Filter, Level, {Destination, ID}}) when is_list(Filter), is_atom(Level), is_atom(Destination) ->
    case validate_trace({Filter, Level, Destination}) of
        {ok, {F, L, D}} ->
            {ok, {F, L, {D, ID}}};
        Error ->
            Error
    end;
validate_trace({Filter, Level, Destination}) when is_list(Filter), is_atom(Level), is_atom(Destination) ->
    try config_to_mask(Level) of
        L ->
            case lists:all(fun({Key, _Value}) when is_atom(Key) -> true; (_) ->
                            false end, Filter) of
                true ->
                    {ok, {Filter, L, Destination}};
                _ ->
                    {error, invalid_filter}
            end
    catch
        _:_ ->
            {error, invalid_level}
    end;
validate_trace(_) ->
    {error, invalid_trace}.


check_traces(_, _,  [], Acc) ->
    lists:flatten(Acc);
check_traces(Attrs, Level, [{_, {mask, FilterLevel}, _}|Flows], Acc) when (Level band FilterLevel) == 0 ->
    check_traces(Attrs, Level, Flows, Acc);
check_traces(Attrs, Level, [{Filter, _, _}|Flows], Acc) when length(Attrs) < length(Filter) ->
    check_traces(Attrs, Level, Flows, Acc);
check_traces(Attrs, Level, [Flow|Flows], Acc) ->
    check_traces(Attrs, Level, Flows, [check_trace(Attrs, Flow)|Acc]).

check_trace(Attrs, {Filter, _Level, Dest}) ->
    case check_trace_iter(Attrs, Filter) of
        true ->
            Dest;
        false ->
            []
    end.

check_trace_iter(_, []) ->
    true;
check_trace_iter(Attrs, [{Key, Match}|T]) ->
    case lists:keyfind(Key, 1, Attrs) of
        {Key, _} when Match == '*' ->
            check_trace_iter(Attrs, T);
        {Key, Match} ->
            check_trace_iter(Attrs, T);
        _ ->
            false
    end.

-spec is_loggable(lager_msg:lager_msg(), non_neg_integer()|{'mask', non_neg_integer()}, term()) -> boolean().
is_loggable(Msg, {mask, Mask}, MyName) ->
    %% using syslog style comparison flags
    %S = lager_msg:severity_as_int(Msg),
    %?debugFmt("comparing masks ~.2B and ~.2B -> ~p~n", [S, Mask, S band Mask]),
    (lager_msg:severity_as_int(Msg) band Mask) /= 0 orelse
    lists:member(MyName, lager_msg:destinations(Msg));
is_loggable(Msg ,SeverityThreshold,MyName) ->
    lager_msg:severity_as_int(Msg) =< SeverityThreshold orelse
    lists:member(MyName, lager_msg:destinations(Msg)).

i2l(I) when I < 10  -> [$0, $0+I];
i2l(I)              -> integer_to_list(I).
i3l(I) when I < 100 -> [$0 | i2l(I)];
i3l(I)              -> integer_to_list(I).

-ifdef(TEST).

parse_test() ->
    ?assertEqual({ok, [{hour, 0}]}, parse_rotation_date_spec("$D0")),
    ?assertEqual({ok, [{hour, 23}]}, parse_rotation_date_spec("$D23")),
    ?assertEqual({ok, [{day, 0}, {hour, 23}]}, parse_rotation_date_spec("$W0D23")),
    ?assertEqual({ok, [{day, 5}, {hour, 16}]}, parse_rotation_date_spec("$W5D16")),
    ?assertEqual({ok, [{date, 1}, {hour, 0}]}, parse_rotation_date_spec("$M1D0")),
    ?assertEqual({ok, [{date, 5}, {hour, 6}]}, parse_rotation_date_spec("$M5D6")),
    ?assertEqual({ok, [{date, 5}, {hour, 0}]}, parse_rotation_date_spec("$M5")),
    ?assertEqual({ok, [{date, 31}, {hour, 0}]}, parse_rotation_date_spec("$M31")),
    ?assertEqual({ok, [{date, 31}, {hour, 1}]}, parse_rotation_date_spec("$M31D1")),
    ?assertEqual({ok, [{date, last}, {hour, 0}]}, parse_rotation_date_spec("$ML")),
    ?assertEqual({ok, [{date, last}, {hour, 0}]}, parse_rotation_date_spec("$Ml")),
    ?assertEqual({ok, [{day, 5}, {hour, 0}]}, parse_rotation_date_spec("$W5")),
    ok.

parse_fail_test() ->
    ?assertEqual({error, invalid_date_spec}, parse_rotation_date_spec("$D")),
    ?assertEqual({error, invalid_date_spec}, parse_rotation_date_spec("$D24")),
    ?assertEqual({error, invalid_date_spec}, parse_rotation_date_spec("$W7")),
    ?assertEqual({error, invalid_date_spec}, parse_rotation_date_spec("$W7D1")),
    ?assertEqual({error, invalid_date_spec}, parse_rotation_date_spec("$M32")),
    ?assertEqual({error, invalid_date_spec}, parse_rotation_date_spec("$M32D1")),
    ?assertEqual({error, invalid_date_spec}, parse_rotation_date_spec("$")),
    ?assertEqual({error, invalid_date_spec}, parse_rotation_date_spec("")),
    ?assertEqual({error, invalid_date_spec}, parse_rotation_date_spec("$D15M5")),
    ?assertEqual({error, invalid_date_spec}, parse_rotation_date_spec("$M5W5")),
    ok.

rotation_calculation_test() ->
    ?assertMatch({{2000, 1, 2}, {0, 0, 0}},
        calculate_next_rotation([{hour, 0}], {{2000, 1, 1}, {12, 34, 43}})),
    ?assertMatch({{2000, 1, 1}, {16, 0, 0}},
        calculate_next_rotation([{hour, 16}], {{2000, 1, 1}, {12, 34, 43}})),
    ?assertMatch({{2000, 1, 2}, {12, 0, 0}},
        calculate_next_rotation([{hour, 12}], {{2000, 1, 1}, {12, 34, 43}})),
    ?assertMatch({{2000, 2, 1}, {12, 0, 0}},
        calculate_next_rotation([{date, 1}, {hour, 12}], {{2000, 1, 1}, {12, 34, 43}})),
    ?assertMatch({{2000, 2, 1}, {12, 0, 0}},
        calculate_next_rotation([{date, 1}, {hour, 12}], {{2000, 1, 15}, {12, 34, 43}})),
    ?assertMatch({{2000, 2, 1}, {12, 0, 0}},
        calculate_next_rotation([{date, 1}, {hour, 12}], {{2000, 1, 2}, {12, 34, 43}})),
    ?assertMatch({{2000, 2, 1}, {12, 0, 0}},
        calculate_next_rotation([{date, 1}, {hour, 12}], {{2000, 1, 31}, {12, 34, 43}})),
    ?assertMatch({{2000, 1, 1}, {16, 0, 0}},
        calculate_next_rotation([{date, 1}, {hour, 16}], {{2000, 1, 1}, {12, 34, 43}})),
    ?assertMatch({{2000, 1, 15}, {16, 0, 0}},
        calculate_next_rotation([{date, 15}, {hour, 16}], {{2000, 1, 1}, {12, 34, 43}})),
    ?assertMatch({{2000, 1, 31}, {16, 0, 0}},
        calculate_next_rotation([{date, last}, {hour, 16}], {{2000, 1, 1}, {12, 34, 43}})),
    ?assertMatch({{2000, 1, 31}, {16, 0, 0}},
        calculate_next_rotation([{date, last}, {hour, 16}], {{2000, 1, 31}, {12, 34, 43}})),
    ?assertMatch({{2000, 2, 29}, {16, 0, 0}},
        calculate_next_rotation([{date, last}, {hour, 16}], {{2000, 1, 31}, {17, 34, 43}})),
    ?assertMatch({{2001, 2, 28}, {16, 0, 0}},
        calculate_next_rotation([{date, last}, {hour, 16}], {{2001, 1, 31}, {17, 34, 43}})),

    ?assertMatch({{2000, 1, 1}, {16, 0, 0}},
        calculate_next_rotation([{day, 6}, {hour, 16}], {{2000, 1, 1}, {12, 34, 43}})),
    ?assertMatch({{2000, 1, 8}, {16, 0, 0}},
        calculate_next_rotation([{day, 6}, {hour, 16}], {{2000, 1, 1}, {17, 34, 43}})),
    ?assertMatch({{2000, 1, 7}, {16, 0, 0}},
        calculate_next_rotation([{day, 5}, {hour, 16}], {{2000, 1, 1}, {17, 34, 43}})),
    ?assertMatch({{2000, 1, 3}, {16, 0, 0}},
        calculate_next_rotation([{day, 1}, {hour, 16}], {{2000, 1, 1}, {17, 34, 43}})),
    ?assertMatch({{2000, 1, 2}, {16, 0, 0}},
        calculate_next_rotation([{day, 0}, {hour, 16}], {{2000, 1, 1}, {17, 34, 43}})),
    ?assertMatch({{2000, 1, 9}, {16, 0, 0}},
        calculate_next_rotation([{day, 0}, {hour, 16}], {{2000, 1, 2}, {17, 34, 43}})),
    ?assertMatch({{2000, 2, 3}, {16, 0, 0}},
        calculate_next_rotation([{day, 4}, {hour, 16}], {{2000, 1, 29}, {17, 34, 43}})),

    ?assertMatch({{2000, 1, 7}, {16, 0, 0}},
        calculate_next_rotation([{day, 5}, {hour, 16}], {{2000, 1, 3}, {17, 34, 43}})),
    
    ?assertMatch({{2000, 1, 3}, {16, 0, 0}},
        calculate_next_rotation([{day, 1}, {hour, 16}], {{1999, 12, 28}, {17, 34, 43}})),
    ok.

rotate_file_test() ->
    file:delete("rotation.log"),
    [file:delete(["rotation.log.", integer_to_list(N)]) || N <- lists:seq(0, 9)],
    [begin
                file:write_file("rotation.log", integer_to_list(N)),
                Count = case N > 10 of
                    true -> 10;
                    _ -> N
                end,
                [begin
                            FileName = ["rotation.log.", integer_to_list(M)],
                            ?assert(filelib:is_regular(FileName)),
                            %% check the expected value is in the file
                            Number = list_to_binary(integer_to_list(N - M - 1)),
                            ?assertEqual({ok, Number}, file:read_file(FileName))
                end
                || M <- lists:seq(0, Count-1)],
                rotate_logfile("rotation.log", 10)
    end || N <- lists:seq(0, 20)].

check_trace_test() ->
    %% match by module
    ?assertEqual([foo], check_traces([{module, ?MODULE}], ?EMERGENCY, [
                {[{module, ?MODULE}], config_to_mask(emergency), foo},
                {[{module, test}], config_to_mask(emergency), bar}], [])),
    %% match by module, but other unsatisfyable attribute
    ?assertEqual([], check_traces([{module, ?MODULE}], ?EMERGENCY, [
                {[{module, ?MODULE}, {foo, bar}], config_to_mask(emergency), foo},
                {[{module, test}], config_to_mask(emergency), bar}], [])),
    %% match by wildcard module
    ?assertEqual([bar], check_traces([{module, ?MODULE}], ?EMERGENCY, [
                {[{module, ?MODULE}, {foo, bar}], config_to_mask(emergency), foo},
                {[{module, '*'}], config_to_mask(emergency), bar}], [])),
    %% wildcard module, one trace with unsatisfyable attribute
    ?assertEqual([bar], check_traces([{module, ?MODULE}], ?EMERGENCY, [
                {[{module, '*'}, {foo, bar}], config_to_mask(emergency), foo},
                {[{module, '*'}], config_to_mask(emergency), bar}], [])),
    %% wildcard but not present custom trace attribute
    ?assertEqual([bar], check_traces([{module, ?MODULE}], ?EMERGENCY, [
                {[{module, '*'}, {foo, '*'}], config_to_mask(emergency), foo},
                {[{module, '*'}], config_to_mask(emergency), bar}], [])),
    %% wildcarding a custom attribute works when it is present
    ?assertEqual([bar, foo], check_traces([{module, ?MODULE}, {foo, bar}], ?EMERGENCY, [
                {[{module, '*'}, {foo, '*'}], config_to_mask(emergency), foo},
                {[{module, '*'}], config_to_mask(emergency), bar}], [])),
    %% denied by level
    ?assertEqual([], check_traces([{module, ?MODULE}, {foo, bar}], ?INFO, [
                {[{module, '*'}, {foo, '*'}], config_to_mask(emergency), foo},
                {[{module, '*'}], config_to_mask(emergency), bar}], [])),
    %% allowed by level
    ?assertEqual([foo], check_traces([{module, ?MODULE}, {foo, bar}], ?INFO, [
                {[{module, '*'}, {foo, '*'}], config_to_mask(debug), foo},
                {[{module, '*'}], config_to_mask(emergency), bar}], [])),
    ?assertEqual([anythingbutnotice, infoandbelow, infoonly], check_traces([{module, ?MODULE}], ?INFO, [
                {[{module, '*'}], config_to_mask('=debug'), debugonly},
                {[{module, '*'}], config_to_mask('=info'), infoonly},
                {[{module, '*'}], config_to_mask('<=info'), infoandbelow},
                {[{module, '*'}], config_to_mask('!=info'), anythingbutinfo},
                {[{module, '*'}], config_to_mask('!=notice'), anythingbutnotice}
                ], [])),

    ok.

is_loggable_test_() ->
    [
        {"Loggable by severity only", ?_assert(is_loggable(lager_msg:new("",{"",""}, alert, [], []),2,me))},
        {"Not loggable by severity only", ?_assertNot(is_loggable(lager_msg:new("",{"",""}, critical, [], []),1,me))},
        {"Loggable by severity with destination", ?_assert(is_loggable(lager_msg:new("",{"",""}, alert, [], [you]),2,me))},
        {"Not loggable by severity with destination", ?_assertNot(is_loggable(lager_msg:new("",{"",""}, critical, [], [you]),1,me))},
        {"Loggable by destination overriding severity", ?_assert(is_loggable(lager_msg:new("",{"",""}, critical, [], [me]),1,me))}
    ].

format_time_test_() ->
    [
        ?_assertEqual("2012-10-04 11:16:23.002",
            begin
                {D, T} = format_time({{2012,10,04},{11,16,23,2}}),
                lists:flatten([D,$ ,T])
            end),
        ?_assertEqual("2012-10-04 11:16:23.999",
            begin
                {D, T} = format_time({{2012,10,04},{11,16,23,999}}),
                lists:flatten([D,$ ,T])
            end),
        ?_assertEqual("2012-10-04 11:16:23",
            begin
                {D, T} = format_time({{2012,10,04},{11,16,23}}),
                lists:flatten([D,$ ,T])
            end),
        ?_assertEqual("2012-10-04 00:16:23.092 UTC",
            begin
                {D, T} = format_time({utc, {{2012,10,04},{0,16,23,92}}}),
                lists:flatten([D,$ ,T])
            end),
        ?_assertEqual("2012-10-04 11:16:23 UTC",
            begin
                {D, T} = format_time({utc, {{2012,10,04},{11,16,23}}}),
                lists:flatten([D,$ ,T])
            end)
    ].

config_to_levels_test() ->
    ?assertEqual([none], config_to_levels('none')),
    ?assertEqual({mask, 0}, config_to_mask('none')),
    ?assertEqual([debug], config_to_levels('=debug')),
    ?assertEqual([debug], config_to_levels('<info')),
    ?assertEqual(levels() -- [debug], config_to_levels('!=debug')),
    ?assertEqual(levels() -- [debug], config_to_levels('>debug')),
    ?assertEqual(levels() -- [debug], config_to_levels('>=info')),
    ?assertEqual(levels() -- [debug], config_to_levels('=>info')),
    ?assertEqual([debug, info, notice], config_to_levels('<=notice')),
    ?assertEqual([debug, info, notice], config_to_levels('=<notice')),
    ?assertEqual([debug], config_to_levels('<info')),
    ?assertEqual([debug], config_to_levels('!info')),
    ?assertError(badarg, config_to_levels(ok)),
    ?assertError(badarg, config_to_levels('<=>info')),
    ?assertError(badarg, config_to_levels('=<=info')),
    ?assertError(badarg, config_to_levels('<==>=<=>info')),
    %% double negatives DO work, however
    ?assertEqual([debug], config_to_levels('!!=debug')),
    ?assertEqual(levels() -- [debug], config_to_levels('!!!=debug')),
    ok.

config_to_mask_test() ->
    ?assertEqual({mask, 0}, config_to_mask('none')),
    ?assertEqual({mask, ?DEBUG bor ?INFO bor ?NOTICE bor ?WARNING bor ?ERROR bor ?CRITICAL bor ?ALERT bor ?EMERGENCY}, config_to_mask('debug')),
    ?assertEqual({mask, ?WARNING bor ?ERROR bor ?CRITICAL bor ?ALERT bor ?EMERGENCY}, config_to_mask('warning')),
    ?assertEqual({mask, ?DEBUG bor ?NOTICE bor ?WARNING bor ?ERROR bor ?CRITICAL bor ?ALERT bor ?EMERGENCY}, config_to_mask('!=info')),
    ok.

mask_to_levels_test() ->
    ?assertEqual([], mask_to_levels(0)),
    ?assertEqual([debug], mask_to_levels(2#10000000)),
    ?assertEqual([debug, info], mask_to_levels(2#11000000)),
    ?assertEqual([debug, info, emergency], mask_to_levels(2#11000001)),
    ?assertEqual([debug, notice, error], mask_to_levels(?DEBUG bor ?NOTICE bor ?ERROR)),
    ok.

-endif.
