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

-module(error_logger_lager_h).

-behaviour(gen_event).

-export([init/1, handle_call/2, handle_event/2, handle_info/2, terminate/2,
        code_change/3]).

init(_) ->
    {ok, {}}.

handle_call(_Request, State) ->
    {ok, ok, State}.

handle_event(Event, State) ->
    case Event of
        {error, _GL, {Pid, Fmt, Args}} ->
            lager:log(error, Pid, Fmt, Args);
        {info_msg, _GL, {Pid, Fmt, Args}} ->
            lager:log(info, Pid, Fmt, Args);
        {error_report, _GL, {Pid, std_error, D}} ->
            lager:log(error, Pid, print_silly_list(D));
        {error_report, _GL, {Pid, supervisor_report, D}} ->
            case lists:sort(D) of
                [{errorContext, Ctx}, {offender, Off}, {reason, Reason}, {supervisor, Name}] ->
                    Offender = format_offender(Off),
                    lager:log(error, Pid, "Supervisor ~p had child ~s exit with reason ~p in context ~p", [element(2, Name), Offender, Reason, Ctx]);
                _ ->
                    lager:log(error, Pid, "SUPERVISOR REPORT" ++ print_silly_list(D))
            end;
        {info_report, _GL, {Pid, std_info, D}} ->
            Details = lists:sort(D),
            case Details of
                [{application, App}, {exited, Reason}, {type, _Type}] ->
                    lager:log(info, Pid, "Application ~p exited with reason: ~p", [App, Reason]);
                _ ->
                    lager:log(info, Pid, print_silly_list(D))
            end;
        {info_report, _GL, {P, progress, D}} ->
            Details = lists:sort(D),
            case Details of
                [{application, App}, {started_at, Node}] ->
                    lager:log(info, P, "Application ~p started on node ~p",
                        [App, Node]);
                [{started, Started}, {supervisor, Name}] ->
                    MFA = format_mfa(proplists:get_value(mfargs, Started)),
                    Pid = proplists:get_value(pid, Started),
                    lager:log(info, P, "Supervisor ~p started ~s at pid ~p", [element(2, Name), MFA, Pid]);
                _ ->
                    lager:log(info, P, "PROGRESS REPORT" ++ print_silly_list(D))
            end;
        _ ->
            io:format("Event ~p~n", [Event])
    end,
    {ok, State}.

handle_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% internal functions

print_silly_list(L) ->
    case lager_stdlib:string_p(L) of
        true -> L;
        _ -> print_silly_list(L, [], [])
    end.

format_offender(Off) ->
    case proplists:get_value(name, Off) of
        undefined ->
            %% supervisor_bridge
            io_lib:format("at module ~p at ~p", [proplists:get_value(mod, Off), proplists:get_value(pid, Off)]);
        Name ->
            %% regular supervisor
            MFA = format_mfa(proplists:get_value(mfargs, Off)),
            io_lib:format("with name ~p started with ~s at ~p", [Name, MFA, proplists:get_value(pid, Off)])
    end.

format_mfa({M, F, A}) ->
    %% TODO pretty-print args better
    io_lib:format("~p:~p(~p)", [M, F, A]);
format_mfa(Other) ->
    io_lib:format("~p", [Other]).

print_silly_list([], Fmt, Acc) ->
    io_lib:format(string:join(lists:reverse(Fmt), " "), lists:reverse(Acc));
print_silly_list([{K,V}|T], Fmt, Acc) ->
    print_silly_list(T, ["~p: ~p" | Fmt], [V, K | Acc]);
print_silly_list([H|T], Fmt, Acc) ->
    print_silly_list(T, ["~p" | Fmt], [H | Acc]).
