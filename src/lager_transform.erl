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

%% @doc The parse transform used for lager messages.
%% This parse transform rewrites functions calls to lager:Severity/1,2 into
%% a more complicated function that captures module, function, line, pid and
%% time as well. The entire function call is then wrapped in a case that
%% checks the mochiglobal 'loglevel' value, so the code isn't executed if
%% nothing wishes to consume the message.

-module(lager_transform).

-include("lager.hrl").

-export([parse_transform/2]).

%% @private
parse_transform(AST, _Options) ->
    walk_ast([], AST).

walk_ast(Acc, []) ->
    lists:reverse(Acc);
walk_ast(Acc, [{attribute, _, module, {Module, _PmodArgs}}=H|T]) ->
    %% A wild parameterized module appears!
    put(module, Module),
    walk_ast([H|Acc], T);
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
            {atom, Line3, Severity}}, Arguments0} = Stmt) ->
    case lists:member(Severity, ?LEVELS) of
        true ->
            DefaultAttrs = {cons, Line, {tuple, Line, [
                        {atom, Line, module}, {atom, Line, get(module)}]},
                    {cons, Line, {tuple, Line, [
                                {atom, Line, function}, {atom, Line, get(function)}]},
                        {cons, Line, {tuple, Line, [
                                    {atom, Line, line},
                                    {integer, Line, Line}]},
                        {cons, Line, {tuple, Line, [
                                    {atom, Line, pid},
                                    {call, Line, {atom, Line, pid_to_list}, [
                                            {call, Line, {atom, Line ,self}, []}]}]},
                            {nil, Line}}}}},
            {Traces, Message, Arguments} = case Arguments0 of
                [Format] ->
                    {DefaultAttrs, Format, {nil, Line}};
                [Arg1, Arg2] ->
                    %% some ambiguity here, figure out if these arguments are
                    %% [Format, Args] or [Attr, Format].
                    %% The trace attributes will be a list of tuples, so check
                    %% for that.
                    case Arg1 of
                        {cons, _, {tuple, _, _}, _} ->
                            {concat_lists(Arg1, DefaultAttrs),
                                Arg2, {nil,Line}};
                        _ ->
                            {DefaultAttrs, Arg1, Arg2}
                    end;
                [Attrs, Format, Args] ->
                    {concat_lists(Attrs, DefaultAttrs), Format, Args}
            end,
            {block, Line, 
                [
                    {call, Line, {remote, Line, {atom,Line1,lager},{atom,Line2,dispatch_log}},
                            [
                                {atom, Line3, Severity},
                                {atom, Line3, get(module)},
                                {atom, Line3, get(function)},
                                {integer, Line3, Line},
                                {call, Line3, {atom, Line3 ,self}, []},
                                Traces,
                                Message,
                                Arguments
                            ]
                    }
                ]}; % block contents
            false ->
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
    Stmt.

%% concat 2 list ASTs by replacing the terminating [] in A with the contents of B
concat_lists({nil, _Line}, B) ->
    B;
concat_lists({cons, Line, Element, Tail}, B) ->
    {cons, Line, Element, concat_lists(Tail, B)}.
