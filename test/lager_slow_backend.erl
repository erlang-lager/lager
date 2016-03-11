-module(lager_slow_backend).
-author("Sungjin Park <jinni.park@gmail.com>").
-behavior(gen_event).

-export([init/1, handle_call/2, handle_event/2, handle_info/2, terminate/2, code_change/3]).

-include("lager.hrl").

-record(state, {
  delay :: non_neg_integer()
}).

init([{delay, Delay}]) ->
  {ok, #state{delay=Delay}}.

handle_call(get_loglevel, State) ->
  {ok, lager_util:config_to_mask(debug), State};
handle_call(_Request, State) ->
  {ok, ok, State}.

handle_event({log, _Message}, State) ->
  timer:sleep(State#state.delay),
  {ok, State};
handle_event(_Event, State) ->
  {ok, State}.

handle_info(_Info, State) ->
  {ok, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.
