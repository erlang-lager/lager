
%% a module that crashes in just about every way possible

-module(crash).

-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-export([start/0]).

-record(state, {
        host :: term(),
        port :: term()
    }).

start() ->
    gen_server:start({local, ?MODULE}, ?MODULE, [], []).

init(_) ->
    {ok, {}}.

handle_call(undef, _, State) ->
    {reply, ?MODULE:booger(), State};
handle_call(badfun, _, State) ->
    M = booger,
    {reply, M(), State};
handle_call(bad_return, _, _) ->
    bleh;
handle_call(bad_return_string, _, _) ->
    {tuple, {tuple, "string"}};
handle_call(case_clause, _, State) ->
    case State of
        goober ->
            {reply, ok, State}
    end;
handle_call(case_clause_string, _, State) ->
    Foo = atom_to_list(?MODULE),
    case Foo of
        State ->
            {reply, ok, State}
    end;
handle_call(if_clause, _, State) ->
    if State == 1 ->
            {reply, ok, State}
    end;
handle_call(try_clause, _, State) ->
    Res = try tuple_to_list(State) of
        [_A, _B] -> ok
    catch
        _:_ -> ok
    end,
    {reply, Res, State};
handle_call(badmatch, _, State) ->
    {A, B, C} = State,
    {reply, [A, B, C], State};
handle_call(badrecord, _, State) ->
    Host = State#state.host,
    {reply, Host, State};
handle_call(function_clause, _, State) ->
    {reply, function(State), State};
handle_call(badarith, _, State) ->
    Res = 1 / length(tuple_to_list(State)),
    {reply, Res, State};
handle_call(badarg1, _, State) ->
    Res = list_to_binary(["foo", bar]),
    {reply, Res, State};
handle_call(badarg2, _, State) ->
    Res = erlang:iolist_to_binary(["foo", bar]),
    {reply, Res, State};
handle_call(system_limit, _, State) ->
    Res = list_to_atom(lists:flatten(lists:duplicate(256, "a"))),
    {reply, Res, State};
handle_call(process_limit, _, State) ->
    %% run with +P 300 to make this crash
    [erlang:spawn(fun() -> timer:sleep(5000) end) || _ <- lists:seq(0, 500)],
    {reply, ok, State};
handle_call(port_limit, _, State) ->
    [erlang:open_port({spawn, "ls"}, []) || _ <- lists:seq(0, 1024)],
    {reply, ok, State};
handle_call(noproc, _, State) ->
    Res = gen_event:call(foo, bar, baz),
    {reply, Res, State};
handle_call(badarity, _, State) ->
    F = fun(A, B, C) -> A + B + C end,
    Res = F(State),
    {reply, Res, State};
handle_call(throw, _, _State) ->
    throw(a_ball);
handle_call(_Call, _From, State) ->
    {reply, ok, State}.

handle_cast(_Cast, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_, _) ->
    ok.

code_change(_, State, _) ->
    {ok, State}.

function(X) when is_list(X) ->
    ok.
