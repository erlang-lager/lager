-module(crash_fsm).
-behaviour(gen_fsm).

-export([start/0, crash/0, state1/2]).

%% gen_fsm callbacks
-export([init/1, handle_event/3, handle_sync_event/4, handle_info/3,
         terminate/3, code_change/4]).

-record(state, {}).

start() ->
    gen_fsm:start({local, ?MODULE}, ?MODULE, [], []).

crash() ->
    gen_fsm:sync_send_event(?MODULE, crash).

%% gen_fsm callbacks
init([]) ->
    {ok, state1, #state{}}.

handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.
handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.
handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.
terminate(_Reason, _StateName, _State) ->
    ok.
code_change(_OldVersion, StateName, State, _Extra) ->
    {ok, StateName, State}.

state1(_Event, S) -> {next_state, state1, S}.
