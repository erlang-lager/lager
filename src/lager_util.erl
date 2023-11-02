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

-module(lager_util).

-export([
    levels/0, level_to_num/1, level_to_chr/1,
    num_to_level/1, config_to_mask/1, config_to_levels/1, mask_to_levels/1,
    format_time/0, format_time/1,
    localtime_ms/0, localtime_ms/1, maybe_utc/1, parse_rotation_date_spec/1,
    calculate_next_rotation/1, validate_trace/1, check_traces/4, is_loggable/3,
    trace_filter/1, trace_filter/2, expand_path/1, find_file/2, check_hwm/1, check_hwm/2,
    make_internal_sink_name/1, otp_version/0, maybe_flush/2,
    has_file_changed/3
]).

-ifdef(TEST).
-export([create_test_dir/0, get_test_dir/0, delete_test_dir/0,
         set_dir_permissions/2,
         safe_application_load/1,
         safe_write_file/2]).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("lager.hrl").

-include_lib("kernel/include/file.hrl").

levels() ->
    [debug, info, notice, warning, error, critical, alert, emergency, none].

level_to_num(debug)      -> ?DEBUG;
level_to_num(info)       -> ?INFO;
level_to_num(notice)     -> ?NOTICE;
level_to_num(warning)    -> ?WARNING;
level_to_num(error)      -> ?ERROR;
level_to_num(critical)   -> ?CRITICAL;
level_to_num(alert)      -> ?ALERT;
level_to_num(emergency)  -> ?EMERGENCY;
level_to_num(none)       -> ?LOG_NONE.

level_to_chr(debug)      -> $D;
level_to_chr(info)       -> $I;
level_to_chr(notice)     -> $N;
level_to_chr(warning)    -> $W;
level_to_chr(error)      -> $E;
level_to_chr(critical)   -> $C;
level_to_chr(alert)      -> $A;
level_to_chr(emergency)  -> $M;
level_to_chr(none)       -> $ .

num_to_level(?DEBUG)     -> debug;
num_to_level(?INFO)      -> info;
num_to_level(?NOTICE)    -> notice;
num_to_level(?WARNING)   -> warning;
num_to_level(?ERROR)     -> error;
num_to_level(?CRITICAL)  -> critical;
num_to_level(?ALERT)     -> alert;
num_to_level(?EMERGENCY) -> emergency;
num_to_level(?LOG_NONE)  -> none.

-spec config_to_mask(atom()|string()) -> {'mask', integer()}.
config_to_mask(silence) ->
    silence;
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

-spec config_to_levels(atom()|string()|[atom()]) -> [lager:log_level()].
config_to_levels(Conf) when is_atom(Conf) ->
    config_to_levels(atom_to_list(Conf));
config_to_levels([Level | _Rest] = Conf) when is_atom(Level) ->
    lists:filter(fun(E) -> lists:member(E, Conf) end, levels());
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

%% returns localtime with milliseconds included
localtime_ms() ->
    Now = os:timestamp(),
    localtime_ms(Now).

localtime_ms(Now) ->
    {_, _, Micro} = Now,
    {Date, {Hours, Minutes, Seconds}} = calendar:now_to_local_time(Now),
    {Date, {Hours, Minutes, Seconds, Micro div 1000 rem 1000}}.


maybe_utc({Date, {H, M, S, Ms}}) ->
    case lager_stdlib:maybe_utc({Date, {H, M, S}}) of
        {utc, {Date1, {H1, M1, S1}}} ->
            {utc, {Date1, {H1, M1, S1, Ms}}};
        {Date1, {H1, M1, S1}} ->
            {Date1, {H1, M1, S1, Ms}}
    end.

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

parse_rotation_hour_spec([], Res) ->
    {ok, Res};
parse_rotation_hour_spec([$H, M1, M2], Res) ->
    case list_to_integer([M1, M2]) of
        X when X >= 0, X =< 59 ->
            {ok, Res ++ [{minute, X}]};
        _ ->
            {error, invalid_date_spec}
    end;
parse_rotation_hour_spec([$H, M], Res) when M >= $0, M =< $9 ->
    {ok, Res ++ [{minute, M - 48}]};
parse_rotation_hour_spec(_,_) ->
    {error, invalid_date_spec}.

%% Default to 00:00:00 rotation
parse_rotation_day_spec([], Res) ->
    {ok, Res ++ [{hour ,0}]};
parse_rotation_day_spec([$D, D1, D2|T], Res) ->
    case list_to_integer([D1, D2]) of
        X when X >= 0, X =< 23 ->
            parse_rotation_hour_spec(T, Res ++ [{hour, X}]);
        _ ->
            {error, invalid_date_spec}
    end;
parse_rotation_day_spec([$D, D|T], Res)  when D >= $0, D =< $9 ->
    parse_rotation_hour_spec(T, Res ++ [{hour, D - 48 }]);
parse_rotation_day_spec(X, Res) ->
    parse_rotation_hour_spec(X, Res).

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
calculate_next_rotation([{minute, X}|T], {{_, _, _}, {Hour, Minute, _}} = Now) when Minute < X ->
    %% rotation is this hour
    NewNow = setelement(2, Now, {Hour, X, 0}),
    calculate_next_rotation(T, NewNow);
calculate_next_rotation([{minute, X}|T], Now) ->
    %% rotation is next hour
    Seconds = calendar:datetime_to_gregorian_seconds(Now) + 3600,
    DateTime = calendar:gregorian_seconds_to_datetime(Seconds),
    {_, {NewHour, _, _}} = DateTime,
    NewNow = setelement(2, DateTime, {NewHour, X, 0}),
    calculate_next_rotation(T, NewNow);
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
            case calculate_next_rotation(T, Now) of
                {Date, _} = NewNow -> NewNow;
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
            case calculate_next_rotation(T, Now) of
                {{Year, Month, Day}, _} = NewNow -> NewNow;
                {NewDate, _} ->
                    %% rotation *isn't* today! rerun the calculation
                    NewNow = {NewDate, {0, 0, 0}},
                    calculate_next_rotation([{date, last}|T], NewNow)
            end;
        false ->
            NewNow = setelement(1, Now, {Year, Month, Last}),
            calculate_next_rotation(T, NewNow)
    end;
calculate_next_rotation([{date, Date}|T], {{Year, Month, Date}, _} = Now) ->
    %% rotation is today
    case calculate_next_rotation(T, Now) of
        {{Year, Month, Date}, _} = NewNow -> NewNow;
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

-spec trace_filter(Query :: 'none' | [tuple()]) -> {ok, any()}.
trace_filter(Query) ->
    trace_filter(?DEFAULT_TRACER, Query).

%% TODO: Support multiple trace modules
%-spec trace_filter(Module :: atom(), Query :: 'none' | [tuple()]) -> {ok, any()}.
trace_filter(Module, Query) when Query == none; Query == [] ->
    {ok, _} = glc:compile(Module, glc:null(false));
trace_filter(Module, Query) when is_list(Query) ->
    {ok, _} = glc:compile(Module, glc_lib:reduce(trace_any(Query))).

validate_trace({Filter, Level, {Destination, ID}}) when is_tuple(Filter); is_list(Filter), is_atom(Level), is_atom(Destination) ->
    case validate_trace({Filter, Level, Destination}) of
        {ok, {F, L, D}} ->
            {ok, {F, L, {D, ID}}};
        Error ->
            Error
    end;
validate_trace({Filter, Level, Destination}) when is_tuple(Filter); is_list(Filter), is_atom(Level), is_atom(Destination) ->
    ValidFilter = validate_trace_filter(Filter),
    try config_to_mask(Level) of
        _ when not ValidFilter ->
            {error, invalid_trace};
        L when is_list(Filter)  ->
            {ok, {trace_all(Filter), L, Destination}};
        L ->
            {ok, {Filter, L, Destination}}
    catch
        _:_ ->
            {error, invalid_level}
    end;
validate_trace(_) ->
    {error, invalid_trace}.

validate_trace_filter(Filter) when is_tuple(Filter), is_atom(element(1, Filter)) =:= false ->
    false;
validate_trace_filter(Filter) when is_list(Filter) ->
    lists:all(fun validate_trace_filter/1, Filter);
validate_trace_filter({Key, '*'}) when is_atom(Key) -> true;
validate_trace_filter({any, L}) when is_list(L) -> lists:all(fun validate_trace_filter/1, L);
validate_trace_filter({all, L}) when is_list(L) -> lists:all(fun validate_trace_filter/1, L);
validate_trace_filter({null, Bool}) when is_boolean(Bool) -> true;
validate_trace_filter({Key, _Value})      when is_atom(Key) -> true;
validate_trace_filter({Key, '=', _Value}) when is_atom(Key) -> true;
validate_trace_filter({Key, '!=', _Value}) when is_atom(Key) -> true;
validate_trace_filter({Key, '<', _Value}) when is_atom(Key) -> true;
validate_trace_filter({Key, '=<', _Value}) when is_atom(Key) -> true;
validate_trace_filter({Key, '>', _Value}) when is_atom(Key) -> true;
validate_trace_filter({Key, '>=', _Value}) when is_atom(Key) -> true;
validate_trace_filter(_) -> false.

trace_all(Query) ->
    glc:all(trace_acc(Query)).

trace_any(Query) ->
    glc:any(Query).

trace_acc(Query) ->
    trace_acc(Query, []).

trace_acc([], Acc) ->
    lists:reverse(Acc);
trace_acc([{any, L}|T], Acc) ->
    trace_acc(T, [glc:any(L)|Acc]);
trace_acc([{all, L}|T], Acc) ->
    trace_acc(T, [glc:all(L)|Acc]);
trace_acc([{null, Bool}|T], Acc) ->
    trace_acc(T, [glc:null(Bool)|Acc]);
trace_acc([{Key, '*'}|T], Acc) ->
    trace_acc(T, [glc:wc(Key)|Acc]);
trace_acc([{Key, '!'}|T], Acc) ->
    trace_acc(T, [glc:nf(Key)|Acc]);
trace_acc([{Key, Val}|T], Acc) ->
    trace_acc(T, [glc:eq(Key, Val)|Acc]);
trace_acc([{Key, '=', Val}|T], Acc) ->
    trace_acc(T, [glc:eq(Key, Val)|Acc]);
trace_acc([{Key, '!=', Val}|T], Acc) ->
    trace_acc(T, [glc:neq(Key, Val)|Acc]);
trace_acc([{Key, '>', Val}|T], Acc) ->
    trace_acc(T, [glc:gt(Key, Val)|Acc]);
trace_acc([{Key, '>=', Val}|T], Acc) ->
    trace_acc(T, [glc:gte(Key, Val)|Acc]);
trace_acc([{Key, '=<', Val}|T], Acc) ->
    trace_acc(T, [glc:lte(Key, Val)|Acc]);
trace_acc([{Key, '<', Val}|T], Acc) ->
    trace_acc(T, [glc:lt(Key, Val)|Acc]).

check_traces(_, _,  [], Acc) ->
    lists:flatten(Acc);
check_traces(Attrs, Level, [{_, silence, _} = Flow|Flows], Acc) ->
    check_traces(Attrs, Level, Flows, [check_trace(Attrs, Flow)|Acc]);
check_traces(Attrs, Level, [{_, {mask, FilterLevel}, _}|Flows], Acc) when (Level band FilterLevel) == 0 ->
    check_traces(Attrs, Level, Flows, Acc);
check_traces(Attrs, Level, [{Filter, _, _}|Flows], Acc) when length(Attrs) < length(Filter) ->
    check_traces(Attrs, Level, Flows, Acc);
check_traces(Attrs, Level, [Flow|Flows], Acc) ->
    check_traces(Attrs, Level, Flows, [check_trace(Attrs, Flow)|Acc]).

check_trace(Attrs, {Filter, _Level, Dest}) when is_list(Filter) ->
    check_trace(Attrs, {trace_all(Filter), _Level, Dest});

check_trace(Attrs, {Filter, Level, Dest} = F) when is_tuple(Filter) ->
    Made = gre:make(Attrs, [list]),
    glc:handle(?DEFAULT_TRACER, Made),
    Match = glc_lib:matches(Filter, Made),
    case Match of
        true ->
            case Level of
                silence -> {silence, Dest};
                _        -> Dest
            end;
        false ->
            []
    end.

-spec is_loggable(lager_msg:lager_msg(), non_neg_integer()|{'mask', non_neg_integer()}, term()) -> boolean().
is_loggable(Msg, {mask, Mask}, MyName) ->
    %% using syslog style comparison flags
    %S = lager_msg:severity_as_int(Msg),
    %?debugFmt("comparing masks ~.2B and ~.2B -> ~p~n", [S, Mask, S band Mask]),
    (not lists:member({silence, MyName}, lager_msg:destinations(Msg)))
        andalso
          ((lager_msg:severity_as_int(Msg) band Mask) /= 0 orelse
           lists:member(MyName, lager_msg:destinations(Msg)));
is_loggable(Msg, SeverityThreshold, MyName) when is_atom(SeverityThreshold) ->
    is_loggable(Msg, level_to_num(SeverityThreshold), MyName);
is_loggable(Msg, SeverityThreshold, MyName) when is_integer(SeverityThreshold) ->
    (not lists:member({silence, MyName}, lager_msg:destinations(Msg)))
        andalso
        (lager_msg:severity_as_int(Msg) =< SeverityThreshold orelse
         lists:member(MyName, lager_msg:destinations(Msg))).

i2l(I) when I < 10  -> [$0, $0+I];
i2l(I)              -> integer_to_list(I).
i3l(I) when I < 100 -> [$0 | i2l(I)];
i3l(I)              -> integer_to_list(I).

%% When log_root option is provided, get the real path to a file
expand_path(LogPath) ->
    LogRoot = application:get_env(lager, log_root, undefined),
    RealPath = case filename:absname(LogPath) =:= LogPath of
                   false when LogRoot =/= undefined ->
                       filename:join(LogRoot, LogPath);
                   _ ->
                       LogPath
               end,
    %% see #534 make sure c:cd can't change file path, trans filename to abs name
    filename:absname(RealPath).

%% Find a file among the already installed handlers.
%%
%% The file is already expanded (i.e. lager_util:expand_path already added the
%% "log_root"), but the file paths inside Handlers are not.
find_file(_File1, _Handlers = []) ->
    false;
find_file(File1, [{{lager_file_backend, File2}, _Handler, _Sink} = HandlerInfo | Handlers]) ->
    File1Abs = File1,
    File2Abs = lager_util:expand_path(File2),
    case File1Abs =:= File2Abs of
        true ->
            % The file inside HandlerInfo is the same as the file we are looking
            % for, so we are done.
            HandlerInfo;
        false ->
            find_file(File1, Handlers)
    end;
find_file(File1, [_HandlerInfo | Handlers]) ->
    find_file(File1, Handlers).

%% conditionally check the HWM if the event would not have been filtered
check_hwm(Shaper = #lager_shaper{filter = Filter}, Event) ->
    case Filter(Event) of
        true ->
            {true, 0, Shaper};
        false ->
            check_hwm(Shaper)
    end.

%% Log rate limit, i.e. high water mark for incoming messages

check_hwm(Shaper = #lager_shaper{hwm = undefined}) ->
    {true, 0, Shaper};
check_hwm(Shaper = #lager_shaper{mps = Mps, hwm = Hwm, lasttime = Last}) when Mps < Hwm ->
    {M, S, _} = Now = os:timestamp(),
    case Last of
        {M, S, _} ->
            {true, 0, Shaper#lager_shaper{mps=Mps+1}};
        _ ->
            %different second - reset mps
            {true, 0, Shaper#lager_shaper{mps=1, lasttime = Now}}
    end;
check_hwm(Shaper = #lager_shaper{lasttime = Last, dropped = Drop}) ->
    %% are we still in the same second?
    {M, S, _} = Now = os:timestamp(),
    case Last of
        {M, S, N} ->
            %% still in same second, but have exceeded the high water mark
            NewDrops = case should_flush(Shaper) of
                           true ->
                               discard_messages(Now, Shaper#lager_shaper.filter, 0);
                           false ->
                               0
                       end,
            Timer = case erlang:read_timer(Shaper#lager_shaper.timer) of
                        false ->
                            erlang:send_after(trunc((1000000 - N)/1000), self(), {shaper_expired, Shaper#lager_shaper.id});
                        _ ->
                            Shaper#lager_shaper.timer
                    end,
            {false, 0, Shaper#lager_shaper{dropped=Drop+NewDrops, timer=Timer}};
        _ ->
            _ = erlang:cancel_timer(Shaper#lager_shaper.timer),
            %% different second, reset all counters and allow it
            {true, Drop, Shaper#lager_shaper{dropped = 0, mps=0, lasttime = Now}}
    end.

should_flush(#lager_shaper{flush_queue = true, flush_threshold = 0}) ->
    true;
should_flush(#lager_shaper{flush_queue = true, flush_threshold = T}) ->
    {_, L} = process_info(self(), message_queue_len),
    L > T;
should_flush(_) ->
    false.

discard_messages(Second, Filter, Count) ->
    {M, S, _} = os:timestamp(),
    case Second of
        {M, S, _} ->
            receive
                %% we only discard gen_event notifications, because
                %% otherwise we might discard gen_event internal
                %% messages, such as trapped EXITs
                {notify, Event} ->
                    NewCount = case Filter(Event) of
                                   false -> Count+1;
                                   true -> Count
                               end,
                    discard_messages(Second, Filter, NewCount)
            after 0 ->
                    Count
            end;
        _ ->
            Count
    end.

%% @private Build an atom for the gen_event process based on a sink name.
%% For historical reasons, the default gen_event process for lager itself is named
%% `lager_event'. For all other sinks, it is SinkName++`_lager_event'
make_internal_sink_name(lager) ->
    ?DEFAULT_SINK;
make_internal_sink_name(Sink) ->
    list_to_atom(atom_to_list(Sink) ++ "_lager_event").

-spec otp_version() -> pos_integer().
%% @doc Return the major version of the current Erlang/OTP runtime as an integer.
otp_version() ->
    {Vsn, _} = string:to_integer(
        case erlang:system_info(otp_release) of
            [$R | Rel] ->
                Rel;
            Rel ->
                Rel
        end),
    Vsn.

maybe_flush(undefined, #lager_shaper{} = S) ->
    S;
maybe_flush(Flag, #lager_shaper{} = S) when is_boolean(Flag) ->
    S#lager_shaper{flush_queue = Flag}.

-spec has_file_changed(Name :: file:name_all(),
                       Inode0 :: pos_integer(),
                       Ctime0 :: file:date_time()) -> {boolean(), file:file_info() | undefined}.
has_file_changed(Name, Inode0, Ctime0) ->
    {OsType, _} = os:type(),
    F = file:read_file_info(Name, [raw]),
    case {OsType, F} of
        {win32, {ok, #file_info{ctime=Ctime1}=FInfo}} ->
            % Note: on win32, Inode is always zero
            % So check the file's ctime to see if it
            % needs to be re-opened
            Changed = Ctime0 =/= Ctime1,
            {Changed, FInfo};
        {_, {ok, #file_info{inode=Inode1}=FInfo}} ->
            Changed = Inode0 =/= Inode1,
            {Changed, FInfo};
        {_, _} ->
            {true, undefined}
    end.

-ifdef(TEST).

parse_test() ->
    ?assertEqual({ok, [{minute, 0}]}, parse_rotation_date_spec("$H0")),
    ?assertEqual({ok, [{minute, 59}]}, parse_rotation_date_spec("$H59")),
    ?assertEqual({ok, [{hour, 0}]}, parse_rotation_date_spec("$D0")),
    ?assertEqual({ok, [{hour, 23}]}, parse_rotation_date_spec("$D23")),
    ?assertEqual({ok, [{day, 0}, {hour, 23}]}, parse_rotation_date_spec("$W0D23")),
    ?assertEqual({ok, [{day, 5}, {hour, 16}]}, parse_rotation_date_spec("$W5D16")),
    ?assertEqual({ok, [{day, 0}, {hour, 12}, {minute, 30}]}, parse_rotation_date_spec("$W0D12H30")),
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
    ?assertEqual({error, invalid_date_spec}, parse_rotation_date_spec("$H")),
    ?assertEqual({error, invalid_date_spec}, parse_rotation_date_spec("$H60")),
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
    ?assertMatch({{2000, 1, 1}, {13, 0, 0}},
        calculate_next_rotation([{minute, 0}], {{2000, 1, 1}, {12, 34, 43}})),
    ?assertMatch({{2000, 1, 1}, {12, 45, 0}},
        calculate_next_rotation([{minute, 45}], {{2000, 1, 1}, {12, 34, 43}})),
    ?assertMatch({{2000, 1, 2}, {0, 0, 0}},
        calculate_next_rotation([{minute, 0}], {{2000, 1, 1}, {23, 45, 43}})),
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

check_trace_test() ->
    lager:start(),
    trace_filter(none),
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
    application:stop(lager),
    application:stop(goldrush),
    ok.

is_loggable_test_() ->
    [
        {"Loggable by severity only", ?_assert(is_loggable(lager_msg:new("", alert, [], []),2,me))},
        {"Not loggable by severity only", ?_assertNot(is_loggable(lager_msg:new("", critical, [], []),1,me))},
        {"Loggable by severity with destination", ?_assert(is_loggable(lager_msg:new("", alert, [], [you]),2,me))},
        {"Not loggable by severity with destination", ?_assertNot(is_loggable(lager_msg:new("", critical, [], [you]),1,me))},
        {"Loggable by destination overriding severity", ?_assert(is_loggable(lager_msg:new("", critical, [], [me]),1,me))}
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

expand_path_test() ->
    OldRootVal = application:get_env(lager, log_root),

    ok = application:unset_env(lager, log_root),
    ?assertEqual(filename:absname("/foo/bar"), expand_path("/foo/bar")),
    ?assertEqual(filename:absname("foo/bar"), expand_path("foo/bar")),

    ok = application:set_env(lager, log_root, "log/dir"),
    ?assertEqual(filename:absname("/foo/bar"), expand_path("/foo/bar")), % Absolute path should not be changed
    ?assertEqual(filename:absname("log/dir/foo/bar"), expand_path("foo/bar")),

    case OldRootVal of
        undefined -> application:unset_env(lager, log_root);
        {ok, Root} -> application:set_env(lager, log_root, Root)
    end,
    ok.

sink_name_test_() ->
    [
        ?_assertEqual(lager_event, make_internal_sink_name(lager)),
        ?_assertEqual(audit_lager_event, make_internal_sink_name(audit))
    ].

create_test_dir() ->
    {ok, Tmp} = get_temp_dir(),
    Dir = filename:join([Tmp, "lager_test",
        erlang:integer_to_list(erlang:phash2(os:timestamp()))]),
    ?assertEqual(ok, filelib:ensure_dir(Dir)),
    TestDir = case file:make_dir(Dir) of
                  ok ->
                      Dir;
                  Err ->
                      ?assertEqual({error, eexist}, Err),
                      create_test_dir()
                  end,
    ok = application:set_env(lager, test_dir, TestDir),
    {ok, TestDir}.

get_test_dir() ->
    case application:get_env(lager, test_dir) of
        undefined ->
            create_test_dir();
        {ok, _}=Res ->
            Res
    end.

get_temp_dir() ->
    Tmp = case os:getenv("TEMP") of
              false ->
                  case os:getenv("TMP") of
                      false -> "/tmp";
                      Dir1 -> Dir1
                  end;
               Dir0 -> Dir0
          end,
    ?assertEqual(true, filelib:is_dir(Tmp)),
    {ok, Tmp}.

delete_test_dir() ->
    {ok, TestDir} = get_test_dir(),
    ok = delete_test_dir(TestDir).

delete_test_dir(TestDir) ->
    ok = application:unset_env(lager, test_dir),
    {OsType, _} = os:type(),
    ok = case {OsType, otp_version()} of
             {win32, _} ->
                 application:stop(lager),
                 do_delete_test_dir(TestDir);
             {unix, 15} ->
                 os:cmd("rm -rf " ++ TestDir);
             {unix, _} ->
                 do_delete_test_dir(TestDir)
         end.

do_delete_test_dir(Dir) ->
    ListRet = file:list_dir_all(Dir),
    ?assertMatch({ok, _}, ListRet),
    {_, Entries} = ListRet,
    lists:foreach(
        fun(Entry) ->
            FsElem = filename:join(Dir, Entry),
            case filelib:is_dir(FsElem) of
                true ->
                    delete_test_dir(FsElem);
                _ ->
                    case file:delete(FsElem) of
                        ok -> ok;
                        Error ->
                            io:format(standard_error, "[ERROR]: error deleting file ~p~n", [FsElem]),
                            ?assertEqual(ok, Error)
                    end
            end
        end, Entries),
    ?assertEqual(ok, file:del_dir(Dir)).

do_delete_file(_FsElem, 0) ->
    ?assert(false);
do_delete_file(FsElem, Attempts) ->
    case file:delete(FsElem) of
        ok -> ok;
        _Error ->
            do_delete_file(FsElem, Attempts - 1)
    end.

set_dir_permissions(Perms, Dir) ->
    do_set_dir_permissions(os:type(), Perms, Dir).

do_set_dir_permissions({win32, _}, _Perms, _Dir) ->
    ok;
do_set_dir_permissions({unix, _}, Perms, Dir) ->
    os:cmd("chmod -R " ++ Perms ++ " " ++ Dir),
    ok.

safe_application_load(App) ->
    case application:load(App) of
        ok ->
            ok;
        {error, {already_loaded, App}} ->
            ok;
        Error ->
            ?assertEqual(ok, Error)
    end.

safe_write_file(File, Content) ->
    % Note: ensures that the new creation time is at least one second
    % in the future
    ?assertEqual(ok, file:write_file(File, Content)),
    Ctime0 = calendar:local_time(),
    Ctime0Sec = calendar:datetime_to_gregorian_seconds(Ctime0),
    Ctime1Sec = Ctime0Sec + 1,
    Ctime1 = calendar:gregorian_seconds_to_datetime(Ctime1Sec),
    {ok, FInfo0} = file:read_file_info(File, [raw]),
    FInfo1 = FInfo0#file_info{ctime = Ctime1},
    ?assertEqual(ok, file:write_file_info(File, FInfo1, [raw])).

-endif.
