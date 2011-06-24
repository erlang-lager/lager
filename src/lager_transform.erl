%% Copyright (c) 2011 Basho Technologies, Inc.  All Rights Reserved.
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

-module(lager_transform).
-export([parse_transform/2]).

-define(LEVELS, [debug, info, notice, warning, error, critical, alert,
        emergency]).

%% This parse transform rewrites functions calls to lager:Severity/1,2 into
%% a more complicated function that captures module, function, line, pid and
%% time as well. The entire function call is then wrapped in a case that
%$ checks the mochiglobal 'loglevel' value, so the code isn't executed if
%% nothing wishes to consume the message.

parse_transform(AST, _Options) ->
    %io:format("~n~p~n", [AST]),
    walk_ast([], AST).

walk_ast(Acc, []) ->
    lists:reverse(Acc);
walk_ast(Acc, [{attribute, _, module, Module}=H|T]) ->
    put(module, Module),
    walk_ast([H|Acc], T);
walk_ast(Acc, [{function, Line, Name, Arity, Clauses}|T]) ->
    put(function, Name),
    walk_ast([{function, Line, Name, Arity,
                walk_clauses([], Clauses)}|Acc], T);
walk_ast(Acc, [H|T]) ->
    walk_ast([H|Acc], T).

walk_clauses(Acc, []) ->
    lists:reverse(Acc);
walk_clauses(Acc, [{clause, Line, Arguments, Guards, Body}|T]) ->
    walk_clauses([{clause, Line, Arguments, Guards, walk_body([], Body)}|Acc], T).

walk_body(Acc, []) ->
    lists:reverse(Acc);
walk_body(Acc, [H|T]) ->
    walk_body([transform_statement(H)|Acc], T).

transform_statement({call, Line, {remote, Line1, {atom, Line2, lager},
            {atom, Line3, Severity}}, Arguments} = Stmt) ->
    case lists:member(Severity, ?LEVELS) of
        true ->
            %io:format("call to lager ~p on line ~p in function ~p in module ~p~n",
                %[Severity, Line, get(function), get(module)]),
            %% a case to check the mochiglobal 'loglevel' key against the
            %% message we're trying to log
            {'case',Line,
                    {op,Line,'=<',
                        {call,Line,
                            {remote,Line,{atom,Line,lager_util},{atom,Line,level_to_num}},
                            [{call,Line,
                                    {remote,Line,{atom,Line,lager_mochiglobal},{atom,Line,get}},
                                    [{atom,Line,loglevel}]}]},
                        {call,Line,
                            {remote,Line,{atom,Line,lager_util},{atom,Line,level_to_num}},
                            [{atom,Line,Severity}]}},
                    [{clause,Line,
                            [{atom,Line,true}], %% yes, we log!
                            [],
                            [{call, Line, {remote, Line1, {atom, Line2, lager},
                                        {atom, Line3, log}}, [
                                        {atom, Line3, Severity},
                                        {atom, Line3, get(module)},
                                        {atom, Line3, get(function)},
                                        {integer, Line3, Line},
                                        {call, Line3, {atom, Line3 ,self}, []},
                                        {call, Line3, {remote, Line3,
                                                {atom, Line3 ,riak_err_stdlib},
                                                {atom,Line3,maybe_utc}},
                                            [{call,Line3,{remote,Line3,
                                                        {atom,Line3,erlang},
                                                        {atom,Line3,localtime}},[]}]}
                                        | Arguments
                                    ]}]},
                        %% No, don't log
                        {clause,Line3,[{var,Line3,'_'}],[],[{atom,Line3,ok}]}]};
            false ->
                %io:format("skipping non-log lager call ~p~n", [Severity]),
                Stmt
        end;
transform_statement({call, Line, {remote, Line1, {atom, Line2, boston_lager},
            {atom, Line3, Severity}}, Arguments}) ->
        NewArgs = case Arguments of
          [{string, L, Msg}] -> [{string, L, re:replace(Msg, "r", "h", [{return, list}, global])}];
          [{string, L, Format}, Args] -> [{string, L, re:replace(Format, "r", "h", [{return, list}, global])}, Args];
          Other -> Other
        end,
        transform_statement({call, Line, {remote, Line1, {atom, Line2, lager},
              {atom, Line3, Severity}}, NewArgs});
transform_statement(Stmt) when is_tuple(Stmt) ->
    list_to_tuple(transform_statement(tuple_to_list(Stmt)));
transform_statement(Stmt) when is_list(Stmt) ->
    [transform_statement(S) || S <- Stmt];
transform_statement(Stmt) ->
    %io:format("Statement ~p~n", [Stmt]),
    Stmt.



