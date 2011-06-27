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

-module(lager_test_backend).

-behaviour(gen_event).

-export([init/1, handle_call/2, handle_event/2, handle_info/2, terminate/2,
        code_change/3]).

-record(state, {level, buffer}).
-compile([{parse_transform, lager_transform}]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

init([Level]) ->
    {ok, #state{level=lager_util:level_to_num(Level), buffer=[]}}.

handle_call(count, #state{buffer=Buffer} = State) ->
    {ok, length(Buffer), State};
handle_call(pop, #state{buffer=Buffer} = State) ->
    case Buffer of
        [] ->
            {ok, undefined, State};
        [H|T] ->
            {ok, H, State#state{buffer=T}}
    end;
handle_call(get_loglevel, #state{level=Level} = State) ->
    {ok, Level, State};
handle_call({set_loglevel, Level}, State) ->
    {ok, ok, State#state{level=lager_util:level_to_num(Level)}};
handle_call(_Request, State) ->
    {ok, ok, State}.

handle_event({log, Level, Time, Message}, #state{level=LogLevel,
        buffer=Buffer} = State) when Level >= LogLevel ->
    {ok, State#state{buffer=Buffer ++ [{Level, Time, Message}]}};
handle_event(_Event, State) ->
    {ok, State}.

handle_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

-ifdef(TEST).

pop() ->
    gen_event:call(lager_event, lager_test_backend, pop).

count() ->
    gen_event:call(lager_event, lager_test_backend, count).

lager_test_() ->
    {foreach,
        fun setup/0,
        fun cleanup/1,
        [
            {"observe that there is nothing up my sleeve",
                fun() ->
                        ?assertEqual(undefined, pop()),
                        ?assertEqual(0, count())
                end
            },
            {"test logging works",
                fun() ->
                        lager:warning("test message"),
                        ?assertEqual(1, count()),
                        {Level, Time, Message}  = pop(),
                        ?assertMatch(Level, lager_util:level_to_num(warning)),
                        [LevelStr, LocStr, MsgStr] = re:split(Message, " ", [{return, list}, {parts, 3}]),
                        ?assertEqual("[warning]", LevelStr),
                        ?assertEqual("test message", MsgStr),
                        ok
                end
            },
            {"test logging with arguments works",
                fun() ->
                        lager:warning("test message ~p", [self()]),
                        ?assertEqual(1, count()),
                        {Level, Time, Message}  = pop(),
                        ?assertMatch(Level, lager_util:level_to_num(warning)),
                        [LevelStr, LocStr, MsgStr] = re:split(Message, " ", [{return, list}, {parts, 3}]),
                        ?assertEqual("[warning]", LevelStr),
                        ?assertEqual(lists:flatten(io_lib:format("test message ~p", [self()])), MsgStr),
                        ok
                end
            },

            {"test logging works from inside a begin/end block",
                fun() ->
                        ?assertEqual(0, count()),
                        begin
                                lager:warning("test message 2")
                        end,
                        ?assertEqual(1, count()),
                        ok
                end
            },
            {"test logging works from inside a list comprehension",
                fun() ->
                        ?assertEqual(0, count()),
                        [lager:warning("test message") || N <- lists:seq(1, 10)],
                        ?assertEqual(10, count()),
                        ok
                end
            },
            {"test logging works from a begin/end block inside a list comprehension",
                fun() ->
                        ?assertEqual(0, count()),
                        [ begin lager:warning("test message") end || N <- lists:seq(1, 10)],
                        ?assertEqual(10, count()),
                        ok
                end
            },
            {"test logging works from a nested list comprehension",
                fun() ->
                        ?assertEqual(0, count()),
                        [ [lager:warning("test message") || N <- lists:seq(1, 10)] ||
                            I <- lists:seq(1, 10)],
                        ?assertEqual(100, count()),
                        ok
                end
            }
        ]
    }.

setup() ->
    application:load(lager),
    application:set_env(lager, handlers, [{lager_test_backend, [info]}]),
    application:start(lager).

cleanup(_) ->
    application:stop(lager),
    application:unload(lager).

-endif.


