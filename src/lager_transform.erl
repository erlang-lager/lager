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

%% @doc The parse transform used for lager messages.
%% This parse transform rewrites functions calls to lager:Severity/1,2 into
%% a more complicated function that captures module, function, line, pid and
%% time as well. The entire function call is then wrapped in a case that
%% checks the lager_config 'loglevel' value, so the code isn't executed if
%% nothing wishes to consume the message.

-module(lager_transform).

-include("lager.hrl").

-export([parse_transform/2]).

%% @private
parse_transform(AST, Options) ->
    TruncSize = proplists:get_value(lager_truncation_size, Options, ?DEFAULT_TRUNCATION),
    Enable = proplists:get_value(lager_print_records_flag, Options, true),
    Sinks = [lager] ++ proplists:get_value(lager_extra_sinks, Options, []),
    put(print_records_flag, Enable),
    put(truncation_size, TruncSize),
    put(sinks, Sinks),
    erlang:put(records, []),
    %% .app file should either be in the outdir, or the same dir as the source file
    guess_application(proplists:get_value(outdir, Options), hd(AST)),
    walk_ast([], AST).

walk_ast(Acc, []) ->
    case get(print_records_flag) of
        true ->
            insert_record_attribute(Acc);
        false ->
            lists:reverse(Acc)
    end;
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
walk_ast(Acc, [{attribute, _, record, {Name, Fields}}=H|T]) ->
    FieldNames = lists:map(fun record_field_name/1, Fields),
    stash_record({Name, FieldNames}),
    walk_ast([H|Acc], T);
walk_ast(Acc, [H|T]) ->
    walk_ast([H|Acc], T).

record_field_name({record_field, _, {atom, _, FieldName}}) ->
    FieldName;
record_field_name({record_field, _, {atom, _, FieldName}, _Default}) ->
    FieldName;
record_field_name({typed_record_field, Field, _Type}) ->
    record_field_name(Field).

walk_clauses(Acc, []) ->
    lists:reverse(Acc);
walk_clauses(Acc, [{clause, Line, Arguments, Guards, Body}|T]) ->
    walk_clauses([{clause, Line, Arguments, Guards, walk_body([], Body)}|Acc], T).

walk_body(Acc, []) ->
    lists:reverse(Acc);
walk_body(Acc, [H|T]) ->
    walk_body([transform_statement(H, get(sinks))|Acc], T).

transform_statement({call, Line, {remote, _Line1, {atom, _Line2, Module},
                                  {atom, _Line3, Function}}, Arguments0} = Stmt,
                    Sinks) ->
    case lists:member(Module, Sinks) of
        true ->
            case lists:member(Function, ?LEVELS) of
                true ->
                    SinkName = lager_util:make_internal_sink_name(Module),
                    do_transform(Line, SinkName, Function, Arguments0);
                false ->
                    case lists:keyfind(Function, 1, ?LEVELS_UNSAFE) of
                        {Function, Severity} ->
                            SinkName = lager_util:make_internal_sink_name(Module),
                            do_transform(Line, SinkName, Severity, Arguments0, unsafe);
                        false ->
                            Stmt
                    end
            end;
        false ->
            list_to_tuple(transform_statement(tuple_to_list(Stmt), Sinks))
    end;
transform_statement(Stmt, Sinks) when is_tuple(Stmt) ->
    list_to_tuple(transform_statement(tuple_to_list(Stmt), Sinks));
transform_statement(Stmt, Sinks) when is_list(Stmt) ->
    [transform_statement(S, Sinks) || S <- Stmt];
transform_statement(Stmt, _Sinks) ->
    Stmt.

do_transform(Line, SinkName, Severity, Arguments0) ->
    do_transform(Line, SinkName, Severity, Arguments0, safe).

do_transform(Line, SinkName, Severity, Arguments0, Safety) ->
    SeverityAsInt=lager_util:level_to_num(Severity),
    DefaultAttrs0 = {cons, Line, {tuple, Line, [
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
                        {cons, Line, {tuple, Line, [
                                                    {atom, Line, node},
                                                    {call, Line, {atom, Line, node}, []}]},
                         %% get the metadata with lager:md(), this will always return a list so we can use it as the tail here
                         {call, Line, {remote, Line, {atom, Line, lager}, {atom, Line, md}}, []}}}}}},
                                                %{nil, Line}}}}}}},
    DefaultAttrs = case erlang:get(application) of
                       undefined ->
                           DefaultAttrs0;
                       App ->
                           %% stick the application in the attribute list
                           concat_lists({cons, Line, {tuple, Line, [
                                                                    {atom, Line, application},
                                                                    {atom, Line, App}]},
                                         {nil, Line}}, DefaultAttrs0)
                   end,
    {Meta, Message, Arguments} = case Arguments0 of
                                       [Format] ->
                                           {DefaultAttrs, Format, {atom, Line, none}};
                                       [Arg1, Arg2] ->
                                           %% some ambiguity here, figure out if these arguments are
                                           %% [Format, Args] or [Attr, Format].
                                           %% The trace attributes will be a list of tuples, so check
                                           %% for that.
                                           case {element(1, Arg1), Arg1} of
                                               {_, {cons, _, {tuple, _, _}, _}} ->
                                                   {concat_lists(Arg1, DefaultAttrs),
                                                    Arg2, {atom, Line, none}};
                                               {Type, _} when Type == var;
                                                              Type == lc;
                                                              Type == call;
                                                              Type == record_field ->
                                                   %% crap, its not a literal. look at the second
                                                   %% argument to see if it is a string
                                                   case Arg2 of
                                                       {string, _, _} ->
                                                           {concat_lists(Arg1, DefaultAttrs),
                                                            Arg2, {atom, Line, none}};
                                                       _ ->
                                                           %% not a string, going to have to guess
                                                           %% it's the argument list
                                                           {DefaultAttrs, Arg1, Arg2}
                                                   end;
                                               _ ->
                                                   {DefaultAttrs, Arg1, Arg2}
                                           end;
                                       [Attrs, Format, Args] ->
                                           {concat_lists(Attrs, DefaultAttrs), Format, Args}
                                   end,
    %% Generate some unique variable names so we don't accidentally export from case clauses.
    %% Note that these are not actual atoms, but the AST treats variable names as atoms.
    LevelVar = make_varname("__Level", Line),
    TracesVar = make_varname("__Traces", Line),
    PidVar = make_varname("__Pid", Line),
    LogFun = case Safety of
                 safe ->
                     do_log;
                 unsafe ->
                     do_log_unsafe
             end,
    %% Wrap the call to lager:dispatch_log/6 in case that will avoid doing any work if this message is not elegible for logging
    %% See lager.erl (lines 89-100) for lager:dispatch_log/6
    %% case {whereis(Sink), whereis(?DEFAULT_SINK), lager_config:get({Sink, loglevel}, {?LOG_NONE, []})} of
    {'case',Line,
         {tuple,Line,
                [{call,Line,{atom,Line,whereis},[{atom,Line,SinkName}]},
                 {call,Line,{atom,Line,whereis},[{atom,Line,?DEFAULT_SINK}]}, 
                 {call,Line,
                       {remote,Line,{atom,Line,lager_config},{atom,Line,get}},
                       [{tuple,Line,[{atom,Line,SinkName},{atom,Line,loglevel}]},
                        {tuple,Line,[{integer,Line,0},{nil,Line}]}]}]},
         %% {undefined, undefined, _} -> {error, lager_not_running};
         [{clause,Line,
                  [{tuple,Line,
                          [{atom,Line,undefined},{atom,Line,undefined},{var,Line,'_'}]}],
                  [],
                  %% trick the linter into avoiding a 'term constructed but not used' error:
                  %% (fun() -> {error, lager_not_running} end)()
                  [{call, Line, {'fun', Line, {clauses, [{clause, Line, [],[], [{tuple, Line, [{atom, Line, error},{atom, Line, lager_not_running}]}]}]}}, []}]
          },
          %% {undefined, _, _} -> {error, {sink_not_configured, Sink}};
          {clause,Line,
                  [{tuple,Line,
                          [{atom,Line,undefined},{var,Line,'_'},{var,Line,'_'}]}],
                  [],
                  %% same trick as above to avoid linter error
                  [{call, Line, {'fun', Line, {clauses, [{clause, Line, [],[], [{tuple,Line, [{atom,Line,error}, {tuple,Line,[{atom,Line,sink_not_configured},{atom,Line,SinkName}]}]}]}]}}, []}] 
          },
          %% {SinkPid, _, {Level, Traces}} when ... -> lager:do_log/9;
          {clause,Line,
                  [{tuple,Line,
                          [{var,Line,PidVar},
                           {var,Line,'_'},
                           {tuple,Line,[{var,Line,LevelVar},{var,Line,TracesVar}]}]}],
                  [[{op, Line, 'orelse',
                    {op, Line, '/=', {op, Line, 'band', {var, Line, LevelVar}, {integer, Line, SeverityAsInt}}, {integer, Line, 0}},
                    {op, Line, '/=', {var, Line, TracesVar}, {nil, Line}}}]],
                  [{call,Line,{remote, Line, {atom, Line, lager}, {atom, Line, LogFun}},
                         [{atom,Line,Severity},
                          Meta,
                          Message,
                          Arguments,
                          {integer, Line, get(truncation_size)},
                          {integer, Line, SeverityAsInt},
                          {var, Line, LevelVar},
                          {var, Line, TracesVar},
                          {atom, Line, SinkName},
                          {var, Line, PidVar}]}]},
          %% _ -> ok
          {clause,Line,[{var,Line,'_'}],[],[{atom,Line,ok}]}]}.

make_varname(Prefix, Line) ->
    list_to_atom(Prefix ++ atom_to_list(get(module)) ++ integer_to_list(Line)).

%% concat 2 list ASTs by replacing the terminating [] in A with the contents of B
concat_lists({var, Line, _Name}=Var, B) ->
    %% concatenating a var with a cons
    {call, Line, {remote, Line, {atom, Line, lists},{atom, Line, flatten}},
        [{cons, Line, Var, B}]};
concat_lists({lc, Line, _Body, _Generator} = LC, B) ->
    %% concatenating a LC with a cons
    {call, Line, {remote, Line, {atom, Line, lists},{atom, Line, flatten}},
        [{cons, Line, LC, B}]};
concat_lists({call, Line, _Function, _Args} = Call, B) ->
    %% concatenating a call with a cons
    {call, Line, {remote, Line, {atom, Line, lists},{atom, Line, flatten}},
        [{cons, Line, Call, B}]};
concat_lists({record_field, Line, _Var, _Record, _Field} = Rec, B) ->
    %% concatenating a record_field with a cons
    {call, Line, {remote, Line, {atom, Line, lists},{atom, Line, flatten}},
        [{cons, Line, Rec, B}]};
concat_lists({nil, _Line}, B) ->
    B;
concat_lists({cons, Line, Element, Tail}, B) ->
    {cons, Line, Element, concat_lists(Tail, B)}.

stash_record(Record) ->
    Records = case erlang:get(records) of
        undefined ->
            [];
        R ->
            R
    end,
    erlang:put(records, [Record|Records]).

insert_record_attribute(AST) ->
    lists:foldl(fun({attribute, Line, module, _}=E, Acc) ->
                [E, {attribute, Line, lager_records, erlang:get(records)}|Acc];
            (E, Acc) ->
                [E|Acc]
        end, [], AST).

guess_application(Dirname, Attr) when Dirname /= undefined ->
    case find_app_file(Dirname) of
        no_idea ->
            %% try it based on source file directory (app.src most likely)
            guess_application(undefined, Attr);
        _ ->
            ok
    end;
guess_application(undefined, {attribute, _, file, {Filename, _}}) ->
    Dir = filename:dirname(Filename),
    find_app_file(Dir);
guess_application(_, _) ->
    ok.

find_app_file(Dir) ->
    case filelib:wildcard(Dir++"/*.{app,app.src}") of
        [] ->
            no_idea;
        [File] ->
            case file:consult(File) of
                {ok, [{application, Appname, _Attributes}|_]} ->
                    erlang:put(application, Appname);
                _ ->
                    no_idea
            end;
        _ ->
            %% multiple files, uh oh
            no_idea
    end.
