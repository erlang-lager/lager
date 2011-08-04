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

-define(LEVELS,
    [debug, info, notice, warning, error, critical, alert, emergency]).

-define(DEBUG, 7).
-define(INFO, 6).
-define(NOTICE, 5).
-define(WARNING, 4).
-define(ERROR, 3).
-define(CRITICAL, 2).
-define(ALERT, 1).
-define(EMERGENCY, 0).
-define(LOG_NONE, -1).

-define(LEVEL2NUM(Level),
    case Level of
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
        ?DEBUG -> debug;
        ?INFO -> info;
        ?NOTICE -> notice;
        ?WARNING -> warning;
        ?ERROR -> error;
        ?CRITICAL -> critical;
        ?ALERT -> alert;
        ?EMERGENCY -> emergency
    end).

-define(SHOULD_LOG(Level),
    lager_util:level_to_num(Level) =< lager_mochiglobal:get(loglevel, ?LOG_NONE)).

%% internal non-blocking logging call
-define(INT_LOG(Level, Format, Args),
    case ?SHOULD_LOG(Level) of
        true ->
            gen_event:notify(lager_event, {log, lager_util:level_to_num(Level),
                    lager_util:format_time(), [io_lib:format("[~p] ", [Level]), io_lib:format("~p ", [self()]), io_lib:format(Format, Args)]});
        _ -> ok
    end).

