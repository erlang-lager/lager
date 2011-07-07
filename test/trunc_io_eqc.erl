%% -------------------------------------------------------------------
%%
%% trunc_io_eqc: QuickCheck test for trunc_io:format with maxlen
%%
%% Copyright (c) 2007-2011 Basho Technologies, Inc.  All Rights Reserved.
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
-export([test/0, test/1, check/0]).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(QC_OUT(P),
        eqc:on_output(fun(Str, Args) -> io:format(user, Str, Args) end, P)).

%%====================================================================
%% eunit test 
%%====================================================================

eqc_test_() ->
    {timeout, 300,
     {spawn, 
      [?_assertEqual(true, quickcheck(numtests(500, ?QC_OUT(prop_format()))))]
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
                {"~p", gen_any(5)},
                {"~w", gen_any(5)},
                {"~s", gen_print_str()}
               ])).
             

%% Generates a printable string
gen_print_str() ->
    ?LET(Xs, list(char()), [X || X <- Xs, io_lib:printable_list([X]), X /= $~]).

gen_any(MaxDepth) ->
    oneof([largeint(),
           gen_atom(),
           nat(),
           binary(),
           gen_pid(),
           gen_port(),
           gen_ref(),
           gen_fun()] ++
           [?LAZY(list(gen_any(MaxDepth - 1))) || MaxDepth /= 0] ++
           [?LAZY(gen_tuple(gen_any(MaxDepth - 1))) || MaxDepth /= 0]).
          
gen_atom() ->
    elements([abc, def, ghi]).

gen_tuple(Gen) ->
    ?LET(Xs, list(Gen), list_to_tuple(Xs)). 

gen_max_len() -> %% Generate length from 3 to whatever.  Needs space for ... in output
    ?LET(Xs, int(), 3 + abs(Xs)).

gen_pid() ->
    ?LAZY(spawn(fun() -> ok end)).

gen_port() ->
    ?LAZY(begin
              Port = erlang:open_port({spawn, "true"}, []),
              erlang:port_close(Port),
              Port
          end).

gen_ref() ->
    ?LAZY(make_ref()).

gen_fun() ->
    ?LAZY(fun() -> ok end).
               
%%====================================================================
%% Property
%%====================================================================
    
%% Checks that trunc_io:format produces output less than or equal to MaxLen
prop_format() ->
    ?FORALL({FmtArgs, MaxLen}, {gen_fmt_args(), gen_max_len()},
            begin
                FudgeLen = 31, %% trunc_io does not correctly calc safe size of pid/port/numbers
                {FmtStr, Args} = build_fmt_args(FmtArgs),
                try
                    Str = lists:flatten(trunc_io:format(FmtStr, Args, MaxLen)),
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

%%====================================================================
%% Internal helpers 
%%====================================================================

%% Build a tuple of {Fmt, Args} from a gen_fmt_args() return
build_fmt_args(FmtArgs) ->
    F = fun({Fmt, Arg}, {FmtStr0, Args0}) ->
                {FmtStr0 ++ Fmt, Args0 ++ [Arg]};
           (Str, {FmtStr0, Args0}) ->
                {FmtStr0 ++ Str, Args0}
        end,
    lists:foldl(F, {"", []}, FmtArgs).

-endif. % (TEST).
-endif. % (EQC).
