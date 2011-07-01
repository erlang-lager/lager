-module(lager_handler_watcher).

-behaviour(gen_server).

%% callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
        code_change/3]).

-export([start_link/3, start/3]).

-record(state, {
        module,
        config,
        event
    }).

start_link(Event, Module, Config) ->
    gen_server:start_link(?MODULE, [Event, Module, Config], []).

start(Event, Module, Config) ->
    gen_server:start(?MODULE, [Event, Module, Config], []).

init([Event, Module, Config]) ->
    install_handler(Event, Module, Config),
    {ok, #state{event=Event, module=Module, config=Config}}.

handle_call(_Call, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({gen_event_EXIT, Module, normal}, #state{module=Module} = State) ->
    {stop, normal, State};
handle_info({gen_event_EXIT, Module, shutdown}, #state{module=Module} = State) ->
    {stop, normal, State};
handle_info({gen_event_EXIT, Module, Reason}, #state{module=Module,
        config=Config, event=Event} = State) ->
    lager:log(error, self(), "Lager event handler ~p exited with reason ~s",
        [Module, error_logger_lager_h:format_reason(Reason)]),
    install_handler(Event, Module, Config),
    {noreply, State};
handle_info(reinstall_handler, #state{module=Module, config=Config, event=Event} = State) ->
    install_handler(Event, Module, Config),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% internal

install_handler(Event, Module, Config) ->
    case gen_event:add_sup_handler(Event, Module, Config) of
        ok ->
            lager:log(info, self(), "Lager installed handler ~p into ~p", [Module, Event]),
            ok;
        _ ->
            %% try to reinstall it later
            lager:log(error, self(), "Lager failed to install handler ~p into ~p, retrying later", [Module, Event]),
            erlang:send_after(5000, self(), reinstall_handler)
    end.

