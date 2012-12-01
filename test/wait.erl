%% @doc Provides 'wait-for' primitive. It should be used for syncing
%% tests with some specific-to-backend quality changes. Because the
%% logging behaviour is now asynchronous and there is no warranty that
%% the event will be logged by a backend after the log event provider
%% process returns to its execution.
-module(wait).

%% API
-export([wait/2, wait/3]).

%% private
-export([waiter/3]).

-type predicate() :: fun(() -> true | false).

-spec wait(Pred :: predicate(),
	   Timeout :: timer:time()) -> ok | 'timed-out'.
wait(Pred, Timeout) ->
    wait(Pred, Timeout, 500).

-spec wait(Pred :: predicate(),
	   Timeout :: timer:time(),
	   Interval :: integer()) -> ok | 'timed-out'.
wait(Pred, Timeout, Interval) when is_integer(Timeout) andalso Timeout > 0 ->
    Ref = make_ref(),
    {ok, TRef} = timer:apply_interval(Interval, ?MODULE, waiter, [self(), Ref, Pred]),
    Result =
	receive
	    {waiter, Ref} ->
		ok
    after Timeout ->
	    'timed-out'
    end,
    timer:cancel(TRef),
    Result.

-spec waiter(Pid :: pid(), Ref :: reference(), Pred :: predicate()) -> true | false.
waiter(Pid, Ref, Pred) ->
    case Pred() of
	true ->
	    Pid ! {waiter, Ref},
	    true;
	false ->
	    false
    end.
