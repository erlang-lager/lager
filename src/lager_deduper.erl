-module(lager_deduper).
-behaviour(gen_server).
-export([start_link/0, dedup_notify/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).

-define(SERVER, ?MODULE).
-define(DEFAULT_TIMEOUT, 1000).
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-record(state, {timer, db}).


start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

dedup_notify(Dest, Level, Timestamp, Msg) ->
    Hash = simhash:hash(iolist_to_binary(Msg)),
    Key = {Level, Hash},
    case gen_server:call(?SERVER, {seen, Key}) of
        yes ->
            ok;
        no when Dest =:= [] ->
            gen_server:cast(?SERVER, {set, Key, {log, lager_util:level_to_num(Level), Timestamp, Msg}});
        no ->
            gen_server:cast(?SERVER, {set, Key, {log, Dest, lager_util:level_to_num(Level), Timestamp, Msg}})
    end.

init([]) ->
    Ref = erlang:start_timer(delay(), self(), dump),
    {ok, #state{timer=Ref, db=empty()}}. % TODO: check for a decent DB format

handle_call({seen, Key}, _From, S = #state{db=DB}) ->
    case lookup(Key, DB) of
        {ok, _} ->
            {reply, yes, S#state{db=increment(Key, DB)}};
        undefined ->
            case {closest(Key, DB), treshold()} of
                {{Dist, MatchKey}, Treshold} when Dist =< Treshold ->
                    {reply, yes, S#state{db=increment(MatchKey, DB)}};
                _ ->
                    {reply, no, S#state{db=store(Key, undefined, DB)}}
            end
    end.

handle_cast({set, Key, Val}, S=#state{db=DB}) ->
    {noreply, S#state{db=store(Key, Val, DB)}}.

handle_info({timeout, _Ref, dump}, S=#state{db=DB}) ->
    NewRef = erlang:start_timer(delay(), self(), dump),
    NewDB = dump(DB),
    {noreply, S#state{timer=NewRef, db=NewDB}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_, _) -> ok.

delay() -> lager_mochiglobal:get(duplicate_dump, ?DEFAULT_TIMEOUT).
treshold() -> lager_mochiglobal:get(duplicate_treshold, 1).

%empty() -> [].
empty() -> dict:new().

lookup(Key, Dict) ->
    case dict:find(Key, Dict) of
        error -> undefined;
        X -> X
    end.

%% assumes the key is present
increment(Key, Dict) ->
    dict:update(Key, fun({Ct, Val}) -> {Ct+1, Val} end, Dict).

store(Key, Val, Dict) ->
    dict:update(Key, fun({Ct, _}) -> {Ct, Val} end, {1, Val}, Dict).

closest({Lvl, Hash}, Dict) ->
    dict:fold(
        fun({Level, H}, _Val, undefined) when Level =:= Lvl ->
            {simhash:distance(Hash, H), {Level, H}};
           ({Level, H}, _Val, Best) when Level =:= Lvl ->
            min({simhash:distance(Hash, H), {Level,H}}, Best);
           (_Key, _Val, Best) ->
            Best
        end,
        undefined,
        Dict).


dump(Dict) ->
    dict:fold(
        fun(Key, Val = {_, undefined}, D) ->
            %% race condition between hash seen and log, hash
            %% likely incoming
            dict:store(Key, Val, D);
           (_K, {1, Log = {log, _Lvl, _Ts, _Msg}}, D) ->
            safe_notify(Log),
            D;
           (_K, {Ct, {log, Lvl, Ts, [LvlStr, Loc, Msg]}}, D) ->
            safe_notify({log, Lvl, Ts, [LvlStr, Loc, [Msg, io_lib:format(" (~b times)", [Ct])]]}),
            D;
           (_K, {1, Log = {log, _Dest, _Lvl, _Ts, _Msg}}, D) ->
            safe_notify(Log),
            D;
           (_K, {Ct, {log, Dest, Lvl, Ts, [LvlStr, Loc, Msg]}}, D) ->
            safe_notify({log, Dest, Lvl, Ts, [LvlStr, Loc, [Msg, io_lib:format(" (~b times)", [Ct])]]}),
            D
        end,
        dict:new(),
        Dict).

safe_notify(Event) ->
    case whereis(lager_event) of
        undefined ->
            %% lager isn't running
            {error, lager_not_running};
        Pid ->
            gen_event:sync_notify(Pid, Event)
    end.


-ifdef(TEST).
setup(Treshold, Timer) ->
    lager_mochiglobal:put(duplicate_treshold, Treshold),
    lager_mochiglobal:put(duplicate_dump, Timer),
    application:start(simhash),
    {ok, DedupPid} = start_link(),
    unlink(DedupPid),
    DedupPid.

cleanup(Pid) ->
    exit(Pid, shutdown).

low_treshold_test_() ->
    {"Check that with low treshold, all messages are handled individually",
     {foreach,
      fun() -> setup(1, 100000) end,
      fun cleanup/1,
      [fun(Pid) ->
           warning_counter(
               Pid, 2,
               [{warning, <<"hello mr bond, how are you today?">>},
                {warning, <<"hella mr bond, how are you today?">>}])
       end]}}.

high_treshold_test_() ->
    {"Check that with high treshold, all messages are handled according to "
     "similarity. Super-high tresholds mean all messages get merged.",
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
           %% different levels won't mix, even with high tresholds.
           warning_counter(
               Pid, 2,
               [{warning, "hello mr bond, how are you today?"},
                {error,   "hello mr bond, how are you today?"}])
       end]}}.

-spec warning_counter(pid(), Expected::number(), [{Level::atom(),Msg::binary()}]) -> term().
warning_counter(Pid, Expected, Msgs) ->
    register(lager_event, self()),
    [dedup_notify([], Lvl, lager_util:format_time(lager_util:maybe_utc(lager_util:localtime_ms())), ["","",Msg])
     || {Lvl, Msg} <- Msgs],
    Pid ! {timeout, make_ref(), dump},
    Dump = receive_sync_notify(100),
    unregister(lager_event),
    ?_assertEqual(Expected, length(Dump)).

receive_sync_notify(Timeout) ->
    receive
        {_P, {From, Ref}, {sync_notify, {log, _, _, Msg}}} ->
            From ! {Ref,ok},
            [Msg | receive_sync_notify(Timeout)];
        X -> io:format(user, "unexpected: ~p~n", [X])
    after Timeout ->
        []
    end.

-endif.
