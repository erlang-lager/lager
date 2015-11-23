%% -------------------------------------------------------------------
%%
%% trunc_io_eqc: QuickCheck test for trunc_io:format with maxlen
%%
%% Copyright (c) 2011-2012 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
-module(trunc_io_eqc).

-ifdef(TEST).
-ifdef(EQC).
-export([test/0, test/1, check/0, prop_format/0, prop_equivalence/0]).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(QC_OUT(P),
        eqc:on_output(fun(Str, Args) -> io:format(user, Str, Args) end, P)).

%%====================================================================
%% eunit test 
%%====================================================================

eqc_test_() ->
    {timeout, 60,
     {spawn, 
      [
                {timeout, 30, ?_assertEqual(true, eqc:quickcheck(eqc:testing_time(14, ?QC_OUT(prop_format()))))},
                {timeout, 30, ?_assertEqual(true, eqc:quickcheck(eqc:testing_time(14, ?QC_OUT(prop_equivalence()))))}
                ]
     }}.

%%====================================================================
%% Shell helpers 
%%====================================================================
    
test() ->
    test(100).

test(N) ->
    quickcheck(numtests(N, prop_format())).

check() ->
    check(prop_format(), current_counterexample()).

%%====================================================================
%% Generators
%%====================================================================

gen_fmt_args() ->
    list(oneof([gen_print_str(),
                "~~",
                {"~10000000.p", gen_any(5)},
                {"~w", gen_any(5)},
                {"~s", oneof([gen_print_str(), gen_atom(), gen_quoted_atom(), gen_print_bin(), gen_iolist(5)])},
                {"~1000000.P", gen_any(5), 4},
                {"~W", gen_any(5), 4},
                {"~i", gen_any(5)},
                {"~B", nat()},
                {"~b", nat()},
                {"~X", nat(), "0x"},
                {"~x", nat(), "0x"},
                {"~.10#", nat()},
                {"~.10+", nat()},
                {"~.36B", nat()},
                {"~1000000.62P", gen_any(5), 4},
                {"~c", gen_char()},
                {"~tc", gen_char()},
                {"~f", real()},
                {"~10.f", real()},
                {"~g", real()},
                {"~10.g", real()},
                {"~e", real()},
                {"~10.e", real()}
               ])).
             

%% Generates a printable string
gen_print_str() ->
    ?LET(Xs, list(char()), [X || X <- Xs, io_lib:printable_list([X]), X /= $~, X < 256]).

gen_print_bin() ->
    ?LET(Xs, gen_print_str(), list_to_binary(Xs)).

gen_any(MaxDepth) ->
    oneof([largeint(),
           gen_atom(),
           gen_quoted_atom(),
           nat(),
           %real(),
           binary(),
           gen_bitstring(),
           gen_pid(),
           gen_port(),
           gen_ref(),
           gen_fun()] ++
           [?LAZY(list(gen_any(MaxDepth - 1))) || MaxDepth /= 0] ++
           [?LAZY(gen_tuple(gen_any(MaxDepth - 1))) || MaxDepth /= 0]).

gen_iolist(0) ->
    [];
gen_iolist(Depth) ->
    list(oneof([gen_char(), gen_print_str(), gen_print_bin(), gen_iolist(Depth-1)])).

gen_atom() ->
    elements([abc, def, ghi]).

gen_quoted_atom() ->
    elements(['abc@bar', '@bar', '10gen']).

gen_bitstring() ->
    ?LET(XS, binary(), <<XS/binary, 1:7>>).

gen_tuple(Gen) ->
    ?LET(Xs, list(Gen), list_to_tuple(Xs)). 

gen_max_len() -> %% Generate length from 3 to whatever.  Needs space for ... in output
    ?LET(Xs, int(), 3 + abs(Xs)).

gen_pid() ->
    ?LAZY(spawn(fun() -> ok end)).

gen_port() ->
    ?LAZY(begin
              Port = erlang:open_port({spawn, "true"}, []),
              catch(erlang:port_close(Port)),
              Port
          end).

gen_ref() ->
    ?LAZY(make_ref()).

gen_fun() ->
    ?LAZY(fun() -> ok end).

gen_char() ->
    oneof(lists:seq($A, $z)).
               
%%====================================================================
%% Property
%%====================================================================
    
%% Checks that trunc_io:format produces output less than or equal to MaxLen
prop_format() ->
    ?FORALL({FmtArgs, MaxLen}, {gen_fmt_args(), gen_max_len()},
            begin
                %% Because trunc_io will print '...' when its running out of
                %% space, even if the remaining space is less than 3, it
                %% doesn't *exactly* stick to the specified limit.

                %% Also, since we don't truncate terms not printed with
                %% ~p/~P/~w/~W/~s, we also need to calculate the wiggle room
                %% for those. Hence the fudge factor calculated below.
                FudgeLen = calculate_fudge(FmtArgs, 50),
                {FmtStr, Args} = build_fmt_args(FmtArgs),
                try
                    Str = lists:flatten(lager_trunc_io:format(FmtStr, Args, MaxLen)),
                    ?WHENFAIL(begin
                                  io:format(user, "FmtStr:   ~p\n", [FmtStr]),
                                  io:format(user, "Args:     ~p\n", [Args]),
                                  io:format(user, "FudgeLen: ~p\n", [FudgeLen]),
                                  io:format(user, "MaxLen:   ~p\n", [MaxLen]),
                                  io:format(user, "ActLen:   ~p\n", [length(Str)]),
                                  io:format(user, "Str:      ~p\n", [Str])
                              end,
                              %% Make sure the result is a printable list
                              %% and if the format string is less than the length, 
                              %% the result string is less than the length.
                              conjunction([{printable, Str == "" orelse 
                                                       io_lib:printable_list(Str)},
                                           {length, length(FmtStr) > MaxLen orelse 
                                                    length(Str) =< MaxLen + FudgeLen}]))
                catch
                    _:Err ->
                        io:format(user, "\nException: ~p\n", [Err]),
                        io:format(user, "FmtStr: ~p\n", [FmtStr]),
                        io:format(user, "Args:   ~p\n", [Args]),
                        false
                end
            end).

%% Checks for equivalent formatting to io_lib
prop_equivalence() ->
    ?FORALL(FmtArgs, gen_fmt_args(),
            begin
            {FmtStr, Args} = build_fmt_args(FmtArgs),
            Expected = lists:flatten(io_lib:format(FmtStr, Args)),
            Actual = lists:flatten(lager_trunc_io:format(FmtStr, Args, 10485760)),
            ?WHENFAIL(begin
                io:format(user, "FmtStr:   ~p\n", [FmtStr]),
                io:format(user, "Args:     ~p\n", [Args]),
                io:format(user, "Expected: ~p\n", [Expected]),
                io:format(user, "Actual:   ~p\n", [Actual])
            end,
                      Expected == Actual)
        end).


%%====================================================================
%% Internal helpers 
%%====================================================================

%% Build a tuple of {Fmt, Args} from a gen_fmt_args() return
build_fmt_args(FmtArgs) ->
    F = fun({Fmt, Arg}, {FmtStr0, Args0}) ->
                {FmtStr0 ++ Fmt, Args0 ++ [Arg]};
           ({Fmt, Arg1, Arg2}, {FmtStr0, Args0}) ->
                {FmtStr0 ++ Fmt, Args0 ++ [Arg1, Arg2]};
           (Str, {FmtStr0, Args0}) ->
                {FmtStr0 ++ Str, Args0}
        end,
    lists:foldl(F, {"", []}, FmtArgs).

calculate_fudge([], Acc) ->
    Acc;
calculate_fudge([{"~62P", _Arg, _Depth}|T], Acc) ->
    calculate_fudge(T, Acc+62);
calculate_fudge([{Fmt, Arg}|T], Acc) when
        Fmt == "~f"; Fmt == "~10.f";
        Fmt == "~g"; Fmt == "~10.g";
        Fmt == "~e"; Fmt == "~10.e";
        Fmt == "~x"; Fmt == "~X";
        Fmt == "~B"; Fmt == "~b"; Fmt == "~36B";
        Fmt == "~.10#"; Fmt == "~10+" ->
    calculate_fudge(T, Acc + length(lists:flatten(io_lib:format(Fmt, [Arg]))));
calculate_fudge([_|T], Acc) ->
    calculate_fudge(T, Acc).

-endif. % (EQC).
-endif. % (TEST).
