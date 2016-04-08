-module(lager_manager_killer).
-author("Sungjin Park <jinni.park@gmail.com>").
-behavior(gen_event).

-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2, code_change/3]).

-export([kill_me/0]).

-include("lager.hrl").

-record(state, {
          killer_hwm :: non_neg_integer(),
          killer_reinstall_after :: non_neg_integer()
         }).

kill_me() ->
    gen_event:call(lager_event, ?MODULE, kill_self).

init([KillerHWM, KillerReinstallAfter]) ->
    {ok, #state{killer_hwm=KillerHWM, killer_reinstall_after=KillerReinstallAfter}}.

handle_call(get_loglevel, State) ->
    {ok, {mask, ?LOG_NONE}, State};
handle_call({set_loglevel, _Level}, State) ->
    {ok, ok, State};
handle_call(get_settings, State = #state{killer_hwm=KillerHWM, killer_reinstall_after=KillerReinstallAfter}) ->
    {ok, [KillerHWM, KillerReinstallAfter], State};
handle_call(kill_self, #state{killer_hwm=KillerHWM, killer_reinstall_after=KillerReinstallAfter}) ->
    exit({kill_me, [KillerHWM, KillerReinstallAfter]});
handle_call(_Request, State) ->
    {ok, ok, State}.
%% It's not the best idea in the world to check the queue length for every
%% log message.  We can make this operation work on a poll timer in the
%% future.
handle_event({log, _Message}, State = #state{killer_hwm=KillerHWM, killer_reinstall_after=KillerReinstallAfter}) ->
    {message_queue_len, Len} = process_info(self(), message_queue_len),
    case Len > KillerHWM of
        true ->
            exit({kill_me, [KillerHWM, KillerReinstallAfter]});
        _ ->
            {ok, State}
    end;
handle_event(_Event, State) ->
    {ok, State}.

handle_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
