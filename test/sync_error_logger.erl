%%
%% %CopyrightBegin%
%% 
%% Copyright Ericsson AB 1996-2009. All Rights Reserved.
%% 
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%% 
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%% 
%% %CopyrightEnd%
%%
-module(sync_error_logger).

%% The error_logger API, but synchronous!
%% This is helpful for tests, otherwise you need lots of nasty timer:sleep.
%% Additionally, the warning map can be set on a per-process level, for
%% convienience, via the process dictionary value `warning_map'.

-export([
        info_msg/1, info_msg/2,
        warning_msg/1, warning_msg/2,
        error_msg/1,error_msg/2
    ]).

-export([
        info_report/1, info_report/2,
        warning_report/1, warning_report/2,
        error_report/1, error_report/2
    ]).

info_msg(Format) ->
    info_msg(Format, []).

info_msg(Format, Args) ->
    gen_event:sync_notify(error_logger, {info_msg, group_leader(), {self(), Format, Args}}).

warning_msg(Format) ->
    warning_msg(Format, []).

warning_msg(Format, Args) ->
    gen_event:sync_notify(error_logger, {warning_msg_tag(), group_leader(), {self(), Format, Args}}).

error_msg(Format) ->
    error_msg(Format, []).

error_msg(Format, Args) ->
    gen_event:sync_notify(error_logger, {error, group_leader(), {self(), Format, Args}}).

info_report(Report) ->
    info_report(std_info, Report).

info_report(Type, Report) ->
    gen_event:sync_notify(error_logger, {info_report, group_leader(), {self(), Type, Report}}).

warning_report(Report) ->
    warning_report(std_warning, Report).

warning_report(Type, Report) ->
    {Tag, NType} = warning_report_tag(Type),
    gen_event:sync_notify(error_logger, {Tag, group_leader(), {self(), NType, Report}}).

error_report(Report) ->
    error_report(std_error, Report).

error_report(Type, Report) ->
    gen_event:sync_notify(error_logger, {error_report, group_leader(), {self(), Type, Report}}).

warning_msg_tag() ->
    case get(warning_map) of
        warning -> warning_msg;
        info -> info_msg;
        _ -> error
    end.

warning_report_tag(Type) ->
    case {get(warning_map), Type == std_warning} of
        {warning, _} -> {warning_report, Type};
        {info, true} -> {info_report, std_info};
        {info, false} -> {info_report, Type};
        {_, true} -> {error_report, std_error};
        {_, false} -> {error_report, Type}
    end.
