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
                formatter :: atom(),
                format_config :: any(),
                log = [] :: list()}).

-include("lager.hrl").
-define(TERSE_FORMAT,[time, " ", color, "[", severity,"] ", message]).

%% @doc Before every test, just
%% lager_common_test_backend:bounce(Level) with the log level of your
%% choice. Every message will be passed along to ct:pal for your
%% viewing in the common_test reports. Also, you can call
%% lager_common_test_backend:get_logs/0 to get a list of all log
%% messages this backend has received during your test. You can then
%% search that list for expected log messages.


-spec get_logs() -> [iolist()] | {error, term()}.
get_logs() ->
    gen_event:call(lager_event, ?MODULE, get_logs, infinity).

bounce() ->
    bounce(error).

bounce(Level) ->
    _ = application:stop(lager),
    application:set_env(lager, suppress_application_start_stop, true),
    application:set_env(lager, handlers,
                        [
                         {lager_common_test_backend, [Level, false]}
                        ]),
    ok = lager:start(),
    %% we care more about getting all of our messages here than being
    %% careful with the amount of memory that we're using.
    error_logger_lager_h:set_high_water(100000),
    ok.

-spec(init(integer()|atom()|[term()]) -> {ok, #state{}} | {error, atom()}).
%% @private
%% @doc Initializes the event handler
init([Level, true]) -> % for backwards compatibility
    init([Level,{lager_default_formatter,[{eol, "\n"}]}]);
init([Level,false]) -> % for backwards compatibility
    init([Level,{lager_default_formatter,?TERSE_FORMAT ++ ["\n"]}]);
init([Level,{Formatter,FormatterConfig}]) when is_atom(Formatter) ->
    case lists:member(Level, ?LEVELS) of
        true ->
            {ok, #state{level=lager_util:config_to_mask(Level),
                    formatter=Formatter,
                    format_config=FormatterConfig}};
        _ ->
            {error, bad_log_level}
    end;
init(Level) ->
    init([Level,{lager_default_formatter,?TERSE_FORMAT ++ ["\n"]}]).

-spec(handle_event(tuple(), #state{}) -> {ok, #state{}}).
%% @private
handle_event({log, Message},
    #state{level=L,formatter=Formatter,format_config=FormatConfig,log=Logs} = State) ->
    case lager_util:is_loggable(Message,L,?MODULE) of
        true ->
            Log = Formatter:format(Message,FormatConfig),
            ct:pal(Log),
            {ok, State#state{log=[Log|Logs]}};
        false ->
            {ok, State}
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
            {ok, ok, State#state{level=lager_util:config_to_mask(Level)}};
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
