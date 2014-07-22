-module(lager_common_test_backend).

-behavior(gen_event).

%% gen_event callbacks
-export([init/1,
         handle_call/2,
         handle_event/2,
         handle_info/2,
         terminate/2,
         code_change/3]).
-export([get_logs/0,
        bounce/0,
        bounce/1]).

%% holds the log messages for retreival on terminate
-record(state, {level :: {mask, integer()},
                verbose :: boolean(),
                log = [] :: list()}).

-include_lib("lager/include/lager.hrl").

-spec get_logs() -> [iolist()] | {error, term()}.
get_logs() ->
    gen_event:call(lager_event, ?MODULE, get_logs, infinity).

bounce() ->
    bounce(error).

bounce(Level) ->
    application:stop(lager),
    lager:start(),
    gen_event:add_handler(lager_event, lager_common_test_backend, [error, false]),
    lager:set_loglevel(lager_common_test_backend, Level),
    ok.

-spec(init(integer()|atom()|[term()]) -> {ok, #state{}} | {error, atom()}).
%% @private
%% @doc Initializes the event handler
init(Level) when is_atom(Level) ->
    case lists:member(Level, ?LEVELS) of
        true ->
            {ok, #state{level=lager_util:level_to_num(Level), verbose=false}};
        _ ->
            {error, bad_log_level}
    end;
init([Level, Verbose]) ->
    case lists:member(Level, ?LEVELS) of
        true ->
            {ok, #state{level=lager_util:level_to_num(Level), verbose=Verbose}};
        _ ->
            {error, bad_log_level}
    end.

-spec(handle_event(tuple(), #state{}) -> {ok, #state{}}).
%% @private
%% @doc handles the event, adding the log message to the gen_event's state.
%%      this function attempts to handle logging events in both the simple tuple
%%      and new record (introduced after lager 1.2.1) formats.
handle_event({log, Dest, Level, {Date, Time}, [LevelStr, Location, Message]}, %% lager 1.2.1
    #state{level=L, verbose=Verbose, log = Logs} = State) when Level > L ->
    case lists:member(lager_common_test_backend, Dest) of
        true ->
            Log = case Verbose of
                true ->
                    [Date, " ", Time, " ", LevelStr, Location, Message];
                _ ->
                    [Time, " ", LevelStr, Message]
            end,
            ct:pal(Log),
            {ok, State#state{log=[Log|Logs]}};
        false ->
            {ok, State}
    end;
handle_event({log, Level, {Date, Time}, [LevelStr, Location, Message]}, %% lager 1.2.1
  #state{level=LogLevel, verbose=Verbose, log = Logs} = State) when Level =< LogLevel ->
    Log = case Verbose of
        true ->
            [Date, " ", Time, " ", LevelStr, Location, Message];
        _ ->
            [Time, " ", LevelStr, Message]
        end,
    ct:pal(Log),
    {ok, State#state{log=[Log|Logs]}};
handle_event({log, {lager_msg, Dest, _Meta, Level, DateTime, _Timestamp, Message}},
             State) -> %% lager 2.0.0
    case lager_util:level_to_num(Level) of
        L when L =< State#state.level ->
            handle_event({log, L, DateTime,
                          [["[",atom_to_list(Level),"] "], " ", Message]},
                         State);
        L ->
            handle_event({log, Dest, L, DateTime,
                          [["[",atom_to_list(Level),"] "], " ", Message]},
                         State)
    end;
handle_event(Event, State) ->
    ct:pal(Event),
    {ok, State#state{log = [Event|State#state.log]}}.

-spec(handle_call(any(), #state{}) -> {ok, any(), #state{}}).
%% @private
%% @doc gets and sets loglevel. This is part of the lager backend api.
handle_call(get_loglevel, #state{level=Level} = State) ->
    {ok, Level, State};
handle_call({set_loglevel, Level}, State) ->
    case lists:member(Level, ?LEVELS) of
        true ->
            {ok, ok, State#state{level=lager_util:level_to_num(Level)}};
        _ ->
            {ok, {error, bad_log_level}, State}
    end;
handle_call(get_logs, #state{log = Logs} = State) ->
    {ok, lists:reverse(Logs), State};
handle_call(_, State) ->
    {ok, ok, State}.

-spec(handle_info(any(), #state{}) -> {ok, #state{}}).
%% @private
%% @doc gen_event callback, does nothing.
handle_info(_, State) ->
    {ok, State}.

-spec(code_change(any(), #state{}, any()) -> {ok, #state{}}).
%% @private
%% @doc gen_event callback, does nothing.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

-spec(terminate(any(), #state{}) -> {ok, list()}).
%% @doc gen_event callback, does nothing.
terminate(_Reason, #state{log=Logs}) ->
    {ok, lists:reverse(Logs)}.
