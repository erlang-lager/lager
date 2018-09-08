-module(crash_statem).
%% we're only going to compile this on OTP 19+
-ifdef(test_statem).
-behaviour(gen_statem).

-export([
         start/0,
         crash/0,
         stop/1,
         timeout/0,
         handle_event/4
]).

-export([terminate/3,code_change/4,init/1,callback_mode/0]).

start() ->
    gen_statem:start({local,?MODULE}, ?MODULE, [], []).

crash() ->
    gen_statem:call(?MODULE, boom).

stop(Reason) ->
    gen_statem:call(?MODULE, {stop, Reason}).

timeout() ->
    gen_statem:call(?MODULE, timeout).

%% Mandatory callback functions
terminate(_Reason, _State, _Data) -> ok.
code_change(_Vsn, State, Data, _Extra) -> {ok,State,Data}.
init([]) ->
    %% insert rant here about breaking changes in minor versions...
    case erlang:system_info(version) of
        "8.0" -> {callback_mode(),state1,undefined};
        _ -> {ok, state1, undefined}
    end.

callback_mode() -> handle_event_function.

%%% state callback(s)

handle_event(state_timeout, timeout, state1, _) ->
    {stop, timeout};
handle_event({call, _From}, timeout, _Arg, _Data) ->
    {keep_state_and_data, [{state_timeout, 0, timeout}]};
handle_event({call, _From}, {stop, Reason}, state1, _Data) ->
    {stop, Reason}.

-else.
-export([start/0, crash/0]).

start() -> ok.
crash() -> ok.

-endif.
