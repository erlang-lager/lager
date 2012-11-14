-module(lager_deduper).
-behaviour(gen_server).
-export([start_link/0, dedup_notify/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).

-define(SERVER, ?MODULE).
-define(TABLE, ?MODULE).
-define(DEFAULT_TIMEOUT, 1000).
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-record(state, {timer, db}).


start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

dedup_notify({log, Log}) ->
    Hash = hash(Log),
    Level = lager_msg:severity_as_int(Log),
    Key = {Level, Hash},
    case limit() of
        undefined -> ask_seen(Key, Log);
        0 -> ask_seen(Key, Log);
        Limit ->
            case ets:lookup(?TABLE, Key) of
                [] -> % not seen
                    ask_seen(Key, Log);
                [{_,X,_}] when X < Limit -> % seen, but not too often
                    ask_seen(Key, Log);
                [_] ->  % seen too many times
                    ok
            end
    end.

ask_seen(Key, Log) ->
    case gen_server:call(?SERVER, {seen, Key}, infinity) of
        yes ->
            ok;
        no ->
            gen_server:cast(?SERVER, {set, Key, {log, Log}})
    end.

hash(Log) ->
    %% The location can be important, but not always -- depends on
    %% where error logging takes place. We give it a weight equivalent
    %% to 25% of the total hash, which seemed to strike a fair balance.
    %% For partial data (Mod:Fun) we give a weight of 10% (still arbitrary)
    %% and under this, we let it be as is.
    %% If no location data is found, only the message is used.
    %% Note that we use a term_to_binary representation of the MFA data
    %% given it is as relevent as strings, but likely quicker to obtain.
    Res = shingle(lager_msg:message(Log)),
    Meta = lager_msg:metadata(Log),
    ToHash = case {proplists:get_value(module, Meta),
          proplists:get_value(function, Meta),
          proplists:get_value(line, Meta)} of
        {undefined,undefined,undefined} ->
            Res;
        {_Mod,undefined,undefined} ->
            Res;
        {Mod,Fun,undefined} ->
            Weight = round(length(Res) * 0.1),
            [{Weight, term_to_binary({Mod,Fun})} | Res];
        {Mod,Fun,Line} ->
            Weight = round(length(Res) * 0.25),
            [{Weight, term_to_binary({Mod,Fun,Line})} | Res]
    end,
    lager_simhash:hash(ToHash, fun erlang:md5/1, 128).

shingle(IoList) ->
    %% Equivalent to "\s|,|\\.", or \s|,|\. as a non-escaped regex
    Pattern = {re_pattern,0,0,
               <<69,82,67,80,67,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,48,0,
                 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,93,0,5,27,32,
                 83,0,5,27,44,83,0,5,27,46,84,0,15,0>>},
    Shingles = [{1, X} || X <- re:split(IoList, Pattern, [{return, binary}]), X =/= <<>>],
    case Shingles of
        [] ->
            %% pathological case, message is only whitespace and punctuation.
            %% We do it by taking things byte by byte instead. This is sub-optimal,
            %% but better than crashing and burning!
            [{1, <<Byte:8>>} || <<Byte:8>> <= iolist_to_binary(IoList)];
        _ ->
            Shingles
    end.

init([]) ->
    Ref = erlang:start_timer(delay(), self(), dump),
    {ok, #state{timer=Ref, db=empty()}}.

handle_call({seen, Key}, _From, S = #state{db=DB}) ->
    case lookup(Key, DB) of
        {ok, _} ->
            {reply, yes, S#state{db=increment(Key, DB)}};
        undefined ->
            case close_enough(Key, DB, threshold()) of
                {_Dist, MatchKey} ->
                    {reply, yes, S#state{db=increment(MatchKey, DB)}};
                _ ->
                    {reply, no, S#state{db=store(Key, undefined, DB)}}
            end
    end;
%% hidden call, mostly useful for tests where we need to
%% synchronously dump the messages.
handle_call(dump, _From, S=#state{timer=Ref}) ->
    erlang:cancel_timer(Ref),
    {noreply, NewState} = handle_info({timeout, Ref, dump}, S),
    {reply, ok, NewState}.

handle_cast({set, Key, Val}, S=#state{db=DB}) ->
    case quick() of
        true -> safe_notify(Val);
        false -> ok
    end,
    {noreply, S#state{db=store(Key, Val, DB)}}.

handle_info({timeout, _Ref, dump}, S=#state{db=DB}) ->
    NewRef = erlang:start_timer(delay(), self(), dump),
    NewDB = dump(DB),
    {noreply, S#state{timer=NewRef, db=NewDB}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_, _) -> ok.

delay() -> lager_config:get(duplicate_dump, ?DEFAULT_TIMEOUT).
threshold() -> lager_config:get(duplicate_threshold, 1).
limit() -> lager_config:get(duplicate_limit, undefined).
quick() -> lager_config:get(duplicate_quick_notification, false).

empty() -> ets:new(?TABLE, [protected,named_table]).

lookup(Key, Tab) ->
    case ets:lookup(Tab, Key) of
        [] -> undefined;
        [{_,Ct,Val}] -> {ok,{Ct,Val}}
    end.

%% assumes the key is present
increment(Key, Tab) ->
    ets:update_counter(Tab, Key, 1),
    Tab.

store(Key, Val, Tab) ->
    case ets:update_element(Tab, Key, {3,Val}) of
        false ->
            case quick() of
                false ->
                    ets:insert(Tab, {Key, 1, Val});
                true ->
                    ets:insert(Tab, {Key, 0, Val})
            end;
        true -> ok
    end,
    Tab.

close_enough(Key, Tab, Limit) ->
    close_enough(Key, Tab, Limit, ets:first(Tab)).

close_enough({Level, Hash}, Tab, Limit, Current = {Level, H}) ->
    case lager_simhash:distance(Hash, H) of
        X when X =< Limit ->
            {X, {Level, H}};
        _ ->
            close_enough({Level, Hash}, Tab, Limit, ets:next(Tab, Current))
    end;
close_enough(_, _, _, '$end_of_table') ->
    undefined;
close_enough(Key, Tab, Limit, Current) ->
    close_enough(Key, Tab, Limit, ets:next(Tab, Current)).

dump(Tab) ->
    dump(Tab, ets:first(Tab)).

dump(Tab, '$end_of_table') ->
    Tab;
dump(Tab, Current) ->
    case ets:lookup(Tab, Current) of
        [{_,_,undefined}] -> % may occur between hash set and log
            dump(Tab, ets:next(Tab, Current));
        [{Key, 0, _Log}] -> % handled with quick notification, discard
            Next = ets:next(Tab, Current),
            ets:delete(Tab, Key),
            dump(Tab, Next);
        [{Key, 1, Log = {log, _}}] ->
            safe_notify(Log),
            Next = ets:next(Tab, Current),
            ets:delete(Tab, Key),
            dump(Tab, Next);
        [{Key, Ct, {log, Log}}] ->
            Msg = lager_msg:message(Log),
            TS = lager_msg:timestamp(Log),
            Lvl = lager_msg:severity(Log),
            Meta = lager_msg:metadata(Log),
            Dest = lager_msg:destinations(Log),
            NewLog = lager_msg:new(
                [Msg | io_lib:format(" (~b times~s)", [Ct, plus(Ct)])],
                TS, Lvl, Meta, Dest
            ),
            safe_notify({log, NewLog}),
            Next = ets:next(Tab, Current),
            ets:delete(Tab,Key),
            dump(Tab, Next)
    end.

%% helper to display log count
plus(Ct) ->
    Limit = limit(),
    if Limit =/= undefined, Limit > 0, Ct >= Limit -> "+";
       true -> ""
    end.

safe_notify(Event) ->
    case whereis(lager_event) of
        undefined ->
            %% lager isn't running
            {error, lager_not_running};
        Pid ->
            gen_event:sync_notify(Pid, Event)
    end.


-ifdef(TEST_CANCELLED).
setup(Threshold, Timer) ->
    {ok, DedupPid} = start_link(),
    unlink(DedupPid),
    lager_config:new(),
    lager_config:set(duplicate_threshold, Threshold),
    lager_config:set(duplicate_dump, Timer),
    lager_config:set(duplicate_limit, undefined),
    lager_config:set(duplicate_quick_notification, false),
    DedupPid.

cleanup(Pid) ->
    lager_config:set(duplicate_threshold, 0),
    lager_config:set(duplicate_limit, undefined),
    lager_config:set(duplicate_quick_notification, false),
    exit(Pid, shutdown).

low_threshold_test_() ->
    {"Check that with low threshold, all messages are handled individually",
     {foreach,
      fun() -> setup(1, 100000) end,
      fun cleanup/1,
      [fun(Pid) ->
           warning_counter(
               Pid, 2,
               [{warning, <<"hello mr bond, how are you today?">>},
                {warning, <<"hella mr bond, how are you today?">>}])
       end]}}.

high_threshold_test_() ->
    {"Check that with high threshold, all messages are handled according to "
     "similarity. Super-high thresholds mean all messages get merged.",
     {foreach,
      fun() -> setup(100000, 100000) end,
      fun cleanup/1,
      [fun(Pid) ->
           warning_counter(
               Pid, 1,
               [{warning, "hello mr bond, how are you today?"},
                {warning, "hella mr bond, how are you today?"},
                {warning, "my cat is blue."}])
       end,
       fun(Pid) ->
           %% different levels won't mix, even with high thresholds.
           warning_counter(
               Pid, 2,
               [{warning, "hello mr bond, how are you today?"},
                {error,   "hello mr bond, how are you today?"}])
       end]}}.

-spec warning_counter(pid(), Expected::number(), [{Level::atom(),Msg::binary()}]) -> term().
warning_counter(Pid, Expected, Msgs) ->
    register(lager_event, self()),
    [dedup_notify({log, lager_msg:new(
                    Msg, lager_util:format_time(),
                    Lvl, [{pid, self()}], []
                )}) || {Lvl, Msg} <- Msgs],
    Pid ! {timeout, make_ref(), dump},
    Dump = receive_sync_notify(1000),
    unregister(lager_event),
    ?_assertEqual(Expected, length(Dump)).

receive_sync_notify(Timeout) ->
    receive
        {_P, {From, Ref}, {sync_notify, {log, Log}}} ->
            From ! {Ref,ok},
            [lager_msg:message(Log) | receive_sync_notify(Timeout)];
        X -> io:format(user, "unexpected: ~p~n", [X])
    after Timeout ->
        []
    end.

-endif.
