-module(lager_backend_throttle).

-include("lager.hrl").

-behaviour(gen_event).

-export([init/1, handle_call/2, handle_event/2, handle_info/2, terminate/2,
        code_change/3]).

-record(state, {
        hwm,
        async = true
    }).

init([Hwm]) ->
    lager_config:set(async, true),
    {ok, #state{hwm=Hwm}}.


handle_call(get_loglevel, State) ->
    {ok, {mask, ?LOG_NONE}, State};
handle_call({set_loglevel, _Level}, State) ->
    {ok, ok, State};
handle_call(_Request, State) ->
    {ok, ok, State}.

handle_event({log, _Message},State) ->
    {message_queue_len, Len} = erlang:process_info(self(), message_queue_len),
    case {Len > State#state.hwm, State#state.async} of
        {true, true} ->
            %% need to flip to sync mode
            lager_config:set(async, false),
            {ok, State#state{async=false}};
        {false, false} ->
            %% need to flip to async mode
            lager_config:set(async, true),
            {ok, State#state{async=true}};
        _ ->
            %% nothing needs to change
            {ok, State}
    end;
handle_event(_Event, State) ->
    {ok, State}.

handle_info(_Info, State) ->
    {ok, State}.

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

