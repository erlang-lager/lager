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


-define(DEFAULT_TRUNCATION, 4096).
-define(DEFAULT_TRACER, lager_default_tracer).
-define(DEFAULT_SINK, lager_event).
-define(ERROR_LOGGER_SINK, error_logger_lager_event).


-define(LEVELS,
    [all, trace, debug, info, notice, warning, error, critical, alert, emergency, none]).

%% Use of these "functions" means that the argument list will not be
%% truncated for safety
-define(LEVELS_UNSAFE,
    [{all_unsafe, all}, {trace_unsafe, trace},{debug_unsafe, debug}, {info_unsafe, info}, {notice_unsafe, notice}, {warning_unsafe, warning}, {error_unsafe, error}, {critical_unsafe, critical}, {alert_unsafe, alert}, {emergency_unsafe, emergency}]).

-define(ALL, 2147483647).
-define(TRACE, 256).
-define(DEBUG, 128).
-define(INFO, 64).
-define(NOTICE, 32).
-define(WARNING, 16).
-define(ERROR, 8).
-define(CRITICAL, 4).
-define(ALERT, 2).
-define(EMERGENCY, 1).
-define(LOG_NONE, 0).

-define(LEVEL2NUM(Level),
    case Level of
        all -> ?ALL;
        trace -> ?TRACE;
        debug -> ?DEBUG;
        info -> ?INFO;
        notice -> ?NOTICE;
        warning -> ?WARNING;
        error -> ?ERROR;
        critical -> ?CRITICAL;
        alert -> ?ALERT;
        emergency -> ?EMERGENCY
    end).

-define(NUM2LEVEL(Num),
    case Num of
        ?ALL -> all;
        ?TRACE -> trace;
        ?DEBUG -> debug;
        ?INFO -> info;
        ?NOTICE -> notice;
        ?WARNING -> warning;
        ?ERROR -> error;
        ?CRITICAL -> critical;
        ?ALERT -> alert;
        ?EMERGENCY -> emergency
    end).

-define(SHOULD_LOG(Sink, Level),
    (lager_util:level_to_num(Level) band element(1, lager_config:get({Sink, loglevel}, {?LOG_NONE, []}))) /= 0).

-define(SHOULD_LOG(Level),
    (lager_util:level_to_num(Level) band element(1, lager_config:get(loglevel, {?LOG_NONE, []}))) /= 0).

-define(NOTIFY(Level, Pid, Format, Args),
    gen_event:notify(lager_event, {log, lager_msg:new(io_lib:format(Format, Args),
            Level,
            [{pid,Pid},{line,?LINE},{file,?FILE},{module,?MODULE}],
            [])}
        )).

%% FOR INTERNAL USE ONLY
%% internal non-blocking logging call
%% there's some special handing for when we try to log (usually errors) while
%% lager is still starting.
-ifdef(TEST).
-define(INT_LOG(Level, Format, Args),
    case ?SHOULD_LOG(Level) of
        true ->
            ?NOTIFY(Level, self(), Format, Args);
        _ ->
            ok
    end).
-else.
-define(INT_LOG(Level, Format, Args),
    Self = self(),
    %% do this in a spawn so we don't cause a deadlock calling gen_event:which_handlers
    %% from a gen_event handler
    spawn(fun() ->
            case catch(gen_event:which_handlers(lager_event)) of
                X when X == []; X == {'EXIT', noproc}; X == [lager_backend_throttle] ->
                    %% there's no handlers yet or lager isn't running, try again
                    %% in half a second.
                    timer:sleep(500),
                    ?NOTIFY(Level, Self, Format, Args);
                _ ->
                    case ?SHOULD_LOG(Level) of
                        true ->
                            ?NOTIFY(Level, Self, Format, Args);
                        _ ->
                            ok
                    end
            end
    end)).
-endif.

-record(lager_shaper, {
                  %% how many messages per second we try to deliver
                  hwm = undefined :: 'undefined' | pos_integer(),
                  %% how many messages we've received this second
                  mps = 0 :: non_neg_integer(),
                  %% the current second
                  lasttime = os:timestamp() :: erlang:timestamp(),
                  %% count of dropped messages this second
                  dropped = 0 :: non_neg_integer()
                 }).

-type lager_shaper() :: #lager_shaper{}.
