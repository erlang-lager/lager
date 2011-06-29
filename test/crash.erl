
%% a module that crashes in just about every way possible

-module(crash).

-behaviour(gen_server).

-compile([export_all]).

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
handle_call(case_clause, _, State) ->
		case State of
			goober ->
				{reply, ok, State}
		end;
handle_call(if_clause, _, State) ->
	if State == 1 ->
			{reply, ok, State}
	end;
handle_call(try_clause, _, State) ->
	Res = try tuple_to_list(State) of
		[A, B] -> ok
	catch
		_:_ -> ok
	end,
	{reply, Res, State};
handle_call(badmatch, _, State) ->
	{A, B, C} = State,
	{reply, [A, B, C], State};
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
handle_call(noproc, _, State) ->
	Res = gen_event:call(foo, bar, baz),
	{reply, Res, State};
handle_call(badarity, _, State) ->
	F = fun(A, B, C) -> A + B + C end,
	Res = F(State),
	{reply, Res, State};
handle_call(Call, From, State) ->
	{reply, ok, State}.

terminate(_, _) ->
	ok.

function(X) when is_list(X) ->
	ok.
