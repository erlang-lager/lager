%% ``The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with your Erlang distribution. If not, it can be
%% retrieved via the world wide web at http://www.erlang.org/.
%% 
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%% 
%% The Initial Developer of the Original Code is Corelatus AB.
%% Portions created by Corelatus are Copyright 2003, Corelatus
%% AB. All Rights Reserved.''
%%
%% @doc Module to print out terms for logging. Limits by length rather than depth.
%%
%% The resulting string may be slightly larger than the limit; the intention
%% is to provide predictable CPU and memory consumption for formatting
%% terms, not produce precise string lengths.
%%
%% Typical use:
%%
%%   trunc_io:print(Term, 500).
%%
%% Source license: Erlang Public License.
%% Original author: Matthias Lang, <tt>matthias@corelatus.se</tt>
%%
%% Various changes to this module, most notably the format/3 implementation
%% were added by Andrew Thompson `<andrew@basho.com>'. The module has been renamed
%% to avoid conflicts with the vanilla module.

-module(lager_trunc_io).
-author('matthias@corelatus.se').
%% And thanks to Chris Newcombe for a bug fix 
-export([format/3, print/2, print/3, fprint/2, fprint/3, safe/2]). % interface functions
-version("$Id: trunc_io.erl,v 1.11 2009-02-23 12:01:06 matthias Exp $").

-ifdef(TEST).
-export([perf/0, perf/3, perf1/0, test/0, test/2]). % testing functions
-include_lib("eunit/include/eunit.hrl").
-endif.

-record(print_options, {
        %% negative depth means no depth limiting
        depth = -1 :: integer(),
        %% whether to print lists as strings, if possible
        lists_as_strings = false :: boolean(),
        %% force strings, or binaries to be printed as a string,
        %% even if they're not printable
        force_strings = false :: boolean()
    }).

format(Fmt, Args, Max) ->
    try lager_format:format(Fmt, Args, Max) of
        Result -> Result
    catch
        _:_ ->
            erlang:error(badarg, [Fmt, Args])
    end.

%% @doc Returns an flattened list containing the ASCII representation of the given
%% term.
-spec fprint(term(), pos_integer()) -> string().
fprint(Term, Max) ->
    fprint(Term, Max, []).


%% @doc Returns an flattened list containing the ASCII representation of the given
%% term.
-spec fprint(term(), pos_integer(), #print_options{}) -> string().
fprint(T, Max, Options) -> 
    {L, _} = print(T, Max, prepare_options(Options, #print_options{})),
    lists:flatten(L).

%% @doc Same as print, but never crashes. 
%%
%% This is a tradeoff. Print might conceivably crash if it's asked to
%% print something it doesn't understand, for example some new data
%% type in a future version of Erlang. If print crashes, we fall back
%% to io_lib to format the term, but then the formatting is
%% depth-limited instead of length limited, so you might run out
%% memory printing it. Out of the frying pan and into the fire.
%% 
-spec safe(term(), pos_integer()) -> {string(), pos_integer()} | {string()}.
safe(What, Len) ->
    case catch print(What, Len) of
	{L, Used} when is_list(L) -> {L, Used};
	_ -> {"unable to print" ++ io_lib:write(What, 99)}
    end.	     

%% @doc Returns {List, Length}
-spec print(term(), pos_integer()) -> {iolist(), pos_integer()}.
print(Term, Max) ->
    print(Term, Max, []).

%% @doc Returns {List, Length}
-spec print(term(), pos_integer(), #print_options{}) -> {iolist(), pos_integer()}.
print(Term, Max, Options) when is_list(Options) ->
    %% need to convert the proplist to a record
    print(Term, Max, prepare_options(Options, #print_options{}));
print(_, Max, _Options) when Max < 0 -> {"...", 3};
print(_, _, #print_options{depth=0}) -> {"...", 3};
print(Tuple, Max, Options) when is_tuple(Tuple) -> 
    {TC, Len} = tuple_contents(Tuple, Max-2, Options),
    {[${, TC, $}], Len + 2};

%% @doc We assume atoms, floats, funs, integers, PIDs, ports and refs never need 
%% to be truncated. This isn't strictly true, someone could make an 
%% arbitrarily long bignum. Let's assume that won't happen unless someone
%% is being malicious.
%%
print(Atom, _Max, #print_options{force_strings=NoQuote}) when is_atom(Atom) ->
    L = atom_to_list(Atom),
    R = case atom_needs_quoting_start(L) andalso not NoQuote of
        true -> lists:flatten([$', L, $']);
        false -> L
    end,
    {R, length(R)};

print(<<>>, _Max, _Options) ->
    {"<<>>", 4};

print(Binary, 0, _Options) when is_binary(Binary) ->
    {"<<..>>", 6};

print(Binary, Max, Options) when is_binary(Binary) ->
    B = binary_to_list(Binary, 1, lists:min([Max, size(Binary)])),
    {L, Len} = case Options#print_options.lists_as_strings orelse
        Options#print_options.force_strings of
        true ->
            alist_start(B, Max-4, Options);
        _ ->
            list_body(B, Max-4, Options, false)
    end,
    {Res, Length} = case L of
        [91, X, 93] ->
            {X, Len - 2};
        X ->
            {X, Len}
    end,
    case Options#print_options.force_strings of
        true ->
            {Res, Length};
        _ ->
            {["<<", Res, ">>"], Length+4}
    end;

print(Float, _Max, _Options) when is_float(Float) ->
    %% use the same function io_lib:format uses to print floats
    %% float_to_list is way too verbose.
    L = io_lib_format:fwrite_g(Float),
    {L, length(L)};

print(Fun, Max, _Options) when is_function(Fun) ->
    L = erlang:fun_to_list(Fun),
    case length(L) > Max of
        true ->
            S = erlang:max(5, Max),
            Res = string:substr(L, 1, S) ++ "..>",
            {Res, length(Res)};
        _ ->
            {L, length(L)}
    end;

print(Integer, _Max, _Options) when is_integer(Integer) ->
    L = integer_to_list(Integer),
    {L, length(L)};

print(Pid, _Max, _Options) when is_pid(Pid) ->
    L = pid_to_list(Pid),
    {L, length(L)};

print(Ref, _Max, _Options) when is_reference(Ref) ->
    L = erlang:ref_to_list(Ref),
    {L, length(L)};

print(Port, _Max, _Options) when is_port(Port) ->
    L = erlang:port_to_list(Port),
    {L, length(L)};

print(List, Max, Options) when is_list(List) ->
    alist_start(List, Max, dec_depth(Options)).

%% Returns {List, Length}
tuple_contents(Tuple, Max, Options) ->
    L = tuple_to_list(Tuple),
    list_body(L, Max, dec_depth(Options), true).

%% Format the inside of a list, i.e. do not add a leading [ or trailing ].
%% Returns {List, Length}
list_body([], _Max, _Options, _Tuple) -> {[], 0};
list_body(_, Max, _Options, _Tuple) when Max < 4 -> {"...", 3};
list_body(_, _Max, #print_options{depth=0}, _Tuple) -> {"...", 3};
list_body([H|T], Max, Options, Tuple) -> 
    {List, Len} = print(H, Max, Options),
    {Final, FLen} = list_bodyc(T, Max - Len, Options, Tuple),
    {[List|Final], FLen + Len};
list_body(X, Max, Options, _Tuple) ->  %% improper list
    {List, Len} = print(X, Max - 1, Options),
    {[$|,List], Len + 1}.

list_bodyc([], _Max, _Options, _Tuple) -> {[], 0};
list_bodyc(_, Max, _Options, _Tuple) when Max < 4 -> {"...", 3};
list_bodyc([H|T], Max, #print_options{depth=Depth} = Options, Tuple) -> 
    {List, Len} = print(H, Max, dec_depth(Options)),
    {Final, FLen} = list_bodyc(T, Max - Len - 1, Options, Tuple),
    Sep = case Depth == 1 andalso not Tuple of
        true -> $|;
        _ -> $,
    end,
    {[Sep, List|Final], FLen + Len + 1};
list_bodyc(X, Max, Options, _Tuple) ->  %% improper list
    {List, Len} = print(X, Max - 1, Options),
    {[$|,List], Len + 1}.

%% The head of a list we hope is ascii. Examples:
%%
%% [65,66,67] -> "ABC"
%% [65,0,67] -> "A"[0,67]
%% [0,65,66] -> [0,65,66]
%% [65,b,66] -> "A"[b,66]
%%
alist_start([], _Max, _Options) -> {"[]", 2};
alist_start(_, Max, _Options) when Max < 4 -> {"...", 3};
alist_start(_, _Max, #print_options{depth=0}) -> {"[...]", 3};
alist_start(L, Max, #print_options{force_strings=true} = Options) ->
    alist(L, Max, Options);
alist_start([H|T], Max, Options) when is_integer(H), H >= 16#20, H =< 16#7e ->  % definitely printable
    try alist([H|T], Max -1, Options) of
        {L, Len} ->
            {[$"|L], Len + 1}
    catch
        throw:unprintable ->
            {R, Len} = list_body([H|T], Max-2, Options, false),
            {[$[, R, $]], Len + 2}
    end;
alist_start([H|T], Max, Options) when H =:= 9; H =:= 10; H =:= 13 ->
    try alist([H|T], Max -1, Options) of
        {L, Len} ->
            {[$"|L], Len + 1}
    catch
        throw:unprintable ->
            {R, Len} = list_body([H|T], Max-2, Options, false),
            {[$[, R, $]], Len + 2}
    end;
alist_start(L, Max, Options) ->
    {R, Len} = list_body(L, Max-2, Options, false),
    {[$[, R, $]], Len + 2}.

alist([], _Max, #print_options{force_strings=true}) -> {"", 0};
alist([], _Max, _Options) -> {"\"", 1};
alist(_, Max, #print_options{force_strings=true}) when Max < 4 -> {"...", 3};
alist(_, Max, #print_options{force_strings=false}) when Max < 5 -> {"...\"", 4};
alist([H|T], Max, Options) when is_integer(H), H >= 16#20, H =< 16#7e ->     % definitely printable
    {L, Len} = alist(T, Max-1, Options),
    {[H|L], Len + 1};
alist([H|T], Max, Options) when H =:= 9; H =:= 10; H =:= 13 ->
    {L, Len} = alist(T, Max-1, Options),
    {[H|L], Len + 1};
alist([H|T], Max, #print_options{force_strings=true} = Options) when is_integer(H) ->
    {L, Len} = alist(T, Max-1, Options),
    {[H|L], Len + 1};
alist(_, _, #print_options{force_strings=true}) ->
    error(badarg);
alist(_L, _Max, _Options) ->
    throw(unprintable).

%% is the first character in the atom alphabetic & lowercase?
atom_needs_quoting_start([H|T]) when H >= $a, H =< $z ->
    atom_needs_quoting(T);
atom_needs_quoting_start(_) ->
    true.

atom_needs_quoting([]) ->
    false;
atom_needs_quoting([H|T]) when (H >= $a andalso H =< $z);
                        (H >= $A andalso H =< $Z);
                         H == $@; H == $_ ->
    atom_needs_quoting(T);
atom_needs_quoting(_) ->
    true.

prepare_options([], Options) ->
    Options;
prepare_options([{depth, Depth}|T], Options) when is_integer(Depth) ->
    prepare_options(T, Options#print_options{depth=Depth});
prepare_options([{lists_as_strings, Bool}|T], Options) when is_boolean(Bool) ->
    prepare_options(T, Options#print_options{lists_as_strings = Bool});
prepare_options([{force_strings, Bool}|T], Options) when is_boolean(Bool) ->
    prepare_options(T, Options#print_options{force_strings = Bool}).

dec_depth(#print_options{depth=Depth} = Options) when Depth > 0 ->
    Options#print_options{depth=Depth-1};
dec_depth(Options) ->
    Options.

-ifdef(TEST).
%%--------------------
%% The start of a test suite. So far, it only checks for not crashing.
-spec test() -> ok.
test() ->
    test(trunc_io, print).

-spec test(atom(), atom()) -> ok.
test(Mod, Func) ->
    Simple_items = [atom, 1234, 1234.0, {tuple}, [], [list], "string", self(),
		    <<1,2,3>>, make_ref(), fun() -> ok end],
    F = fun(A) ->
		Mod:Func(A, 100),
		Mod:Func(A, 2),
		Mod:Func(A, 20)
	end,

    G = fun(A) ->
		case catch F(A) of
		    {'EXIT', _} -> exit({failed, A});
		    _ -> ok
		end
	end,
    
    lists:foreach(G, Simple_items),
    
    Tuples = [ {1,2,3,a,b,c}, {"abc", def, 1234},
	       {{{{a},b,c,{d},e}},f}],
    
    Lists = [ [1,2,3,4,5,6,7], lists:seq(1,1000),
	      [{a}, {a,b}, {a, [b,c]}, "def"], [a|b], [$a|$b] ],
    
    
    lists:foreach(G, Tuples),
    lists:foreach(G, Lists).

-spec perf() -> ok.
perf() ->
    {New, _} = timer:tc(trunc_io, perf, [trunc_io, print, 1000]),
    {Old, _} = timer:tc(trunc_io, perf, [io_lib, write, 1000]),
    io:fwrite("New code took ~p us, old code ~p\n", [New, Old]).

-spec perf(atom(), atom(), integer()) -> done.
perf(M, F, Reps) when Reps > 0 ->
    test(M,F),
    perf(M,F,Reps-1);
perf(_,_,_) ->
    done.    

%% Performance test. Needs a particularly large term I saved as a binary...
-spec perf1() -> {non_neg_integer(), non_neg_integer()}.
perf1() ->
    {ok, Bin} = file:read_file("bin"),
    A = binary_to_term(Bin),
    {N, _} = timer:tc(trunc_io, print, [A, 1500]),
    {M, _} = timer:tc(io_lib, write, [A]),
    {N, M}.

format_test() ->
    %% simple format strings
    ?assertEqual("foobar", lists:flatten(format("~s", [["foo", $b, $a, $r]], 50))),
    ?assertEqual("[\"foo\",98,97,114]", lists:flatten(format("~p", [["foo", $b, $a, $r]], 50))),
    ?assertEqual("[\"foo\",98,97,114]", lists:flatten(format("~P", [["foo", $b, $a, $r], 10], 50))),
    ?assertEqual("[\"foo\",98,97,114]", lists:flatten(format("~w", [["foo", $b, $a, $r]], 50))),
    
    %% complex ones
    ?assertEqual("    foobar", lists:flatten(format("~10s", [["foo", $b, $a, $r]], 50))),
    ?assertEqual("     [\"foo\",98,97,114]", lists:flatten(format("~22p", [["foo", $b, $a, $r]], 50))),
    ?assertEqual("     [\"foo\",98,97,114]", lists:flatten(format("~22P", [["foo", $b, $a, $r], 10], 50))),
    ?assertEqual("**********", lists:flatten(format("~10W", [["foo", $b, $a, $r], 10], 50))),
    ?assertEqual("   [\"foo\",98,97,114]", lists:flatten(format("~20W", [["foo", $b, $a, $r], 10], 50))),
    ok.

atom_quoting_test() ->
    ?assertEqual("hello", lists:flatten(format("~p", [hello], 50))),
    ?assertEqual("'hello world'", lists:flatten(format("~p", ['hello world'], 50))),
    ?assertEqual("hello_world", lists:flatten(format("~p", ['hello_world'], 50))),
    ?assertEqual("'node@127.0.0.1'", lists:flatten(format("~p", ['node@127.0.0.1'], 50))),
    ?assertEqual("node@nohost", lists:flatten(format("~p", [node@nohost], 50))),
    ok.

sane_float_printing_test() ->
    ?assertEqual("1.0", lists:flatten(format("~p", [1.0], 50))),
    ?assertEqual("1.23456789", lists:flatten(format("~p", [1.23456789], 50))),
    ?assertEqual("1.23456789", lists:flatten(format("~p", [1.234567890], 50))),
    ?assertEqual("0.3333333333333333", lists:flatten(format("~p", [1/3], 50))),
    ?assertEqual("0.1234567", lists:flatten(format("~p", [0.1234567], 50))),
    ok.

float_inside_list_test() ->
    ?assertEqual("[97,38.233913133184835,99]", lists:flatten(format("~p", [[$a, 38.233913133184835, $c]], 50))),
    ?assertError(badarg, lists:flatten(format("~s", [[$a, 38.233913133184835, $c]], 50))),
    ok.

quote_strip_test() ->
    ?assertEqual("\"hello\"", lists:flatten(format("~p", ["hello"], 50))),
    ?assertEqual("hello", lists:flatten(format("~s", ["hello"], 50))),
    ?assertEqual("hello", lists:flatten(format("~s", [hello], 50))),
    ?assertEqual("hello", lists:flatten(format("~p", [hello], 50))),
    ?assertEqual("'hello world'", lists:flatten(format("~p", ['hello world'], 50))),
    ?assertEqual("hello world", lists:flatten(format("~s", ['hello world'], 50))),
    ok.

binary_printing_test() ->
    ?assertEqual("<<\"hello\">>", lists:flatten(format("~p", [<<$h, $e, $l, $l, $o>>], 50))),
    ?assertEqual("<<\"hello\">>", lists:flatten(format("~p", [<<"hello">>], 50))),
    ?assertEqual("<<1,2,3,4>>", lists:flatten(format("~p", [<<1, 2, 3, 4>>], 50))),
    ?assertEqual([1,2,3,4], lists:flatten(format("~s", [<<1, 2, 3, 4>>], 50))),
    ?assertEqual("hello", lists:flatten(format("~s", [<<"hello">>], 50))),
    ?assertEqual("     hello", lists:flatten(format("~10s", [<<"hello">>], 50))),
    ok.

list_printing_test() ->
    ?assertEqual("[13,11,10,8,5,4]", lists:flatten(format("~p", [[13,11,10,8,5,4]], 50))),
    ?assertEqual("[1,2,3|4]", lists:flatten(format("~p", [[1, 2, 3|4]], 50))),
    ?assertEqual("[1|4]", lists:flatten(format("~p", [[1|4]], 50))),
    ?assertError(badarg, lists:flatten(format("~s", [[1|4]], 50))),
    ?assertEqual("\"hello...\"", lists:flatten(format("~p", ["hello world"], 10))),
    ?assertEqual("hello w...", lists:flatten(format("~s", ["hello world"], 10))),
    ?assertEqual("hello world\r\n", lists:flatten(format("~s", ["hello world\r\n"], 50))),
    ?assertEqual("\rhello world\r\n", lists:flatten(format("~s", ["\rhello world\r\n"], 50))),
    ?assertEqual("...", lists:flatten(format("~s", ["\rhello world\r\n"], 3))),
    ?assertEqual("[]", lists:flatten(format("~s", [[]], 50))),
    ok.

unicode_test() ->
    ?assertEqual([231,167,129], lists:flatten(format("~s", [<<231,167,129>>], 50))),
    ?assertEqual([31169], lists:flatten(format("~ts", [<<231,167,129>>], 50))),
    ok.

depth_limit_test() ->
    ?assertEqual("{...}", lists:flatten(format("~P", [{a, [b, [c, [d]]]}, 1], 50))),
    ?assertEqual("{a,...}", lists:flatten(format("~P", [{a, [b, [c, [d]]]}, 2], 50))),
    ?assertEqual("{a,[...]}", lists:flatten(format("~P", [{a, [b, [c, [d]]]}, 3], 50))),
    ?assertEqual("{a,[b|...]}", lists:flatten(format("~P", [{a, [b, [c, [d]]]}, 4], 50))),
    ?assertEqual("{a,[b,[...]]}", lists:flatten(format("~P", [{a, [b, [c, [d]]]}, 5], 50))),
    ?assertEqual("{a,[b,[c|...]]}", lists:flatten(format("~P", [{a, [b, [c, [d]]]}, 6], 50))),
    ?assertEqual("{a,[b,[c,[...]]]}", lists:flatten(format("~P", [{a, [b, [c, [d]]]}, 7], 50))),
    ?assertEqual("{a,[b,[c,[d]]]}", lists:flatten(format("~P", [{a, [b, [c, [d]]]}, 8], 50))),
    ?assertEqual("{a,[b,[c,[d]]]}", lists:flatten(format("~P", [{a, [b, [c, [d]]]}, 9], 50))),

    ?assertEqual("{a,{...}}", lists:flatten(format("~P", [{a, {b, {c, {d}}}}, 3], 50))),
    ?assertEqual("{a,{b,...}}", lists:flatten(format("~P", [{a, {b, {c, {d}}}}, 4], 50))),
    ?assertEqual("{a,{b,{...}}}", lists:flatten(format("~P", [{a, {b, {c, {d}}}}, 5], 50))),
    ?assertEqual("{a,{b,{c,...}}}", lists:flatten(format("~P", [{a, {b, {c, {d}}}}, 6], 50))),
    ?assertEqual("{a,{b,{c,{...}}}}", lists:flatten(format("~P", [{a, {b, {c, {d}}}}, 7], 50))),
    ?assertEqual("{a,{b,{c,{d}}}}", lists:flatten(format("~P", [{a, {b, {c, {d}}}}, 8], 50))),

    ?assertEqual("{\"a\",[...]}", lists:flatten(format("~P", [{"a", ["b", ["c", ["d"]]]}, 3], 50))),
    ?assertEqual("{\"a\",[\"b\",[[...]|...]]}", lists:flatten(format("~P", [{"a", ["b", ["c", ["d"]]]}, 6], 50))),
    ?assertEqual("{\"a\",[\"b\",[\"c\",[\"d\"]]]}", lists:flatten(format("~P", [{"a", ["b", ["c", ["d"]]]}, 9], 50))),
    ok.

-endif.
