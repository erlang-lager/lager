%% -------------------------------------------------------------------
%%
%% Copyright (c) 2011-2017 Basho Technologies, Inc.
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

-module(lager_test_function_transform).

-include("lager.hrl").

-lager_function_transforms([
  {returns_static, {lager_test_function_transform, transform_static}},
  {returns_dynamic, {lager_test_function_transform, transform_dynamic}}
]).

-compile({parse_transform, lager_transform}).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-export([
  transform_static/0,
  transform_dynamic/0
]).
-endif.

-ifdef(TEST).

transform_static() ->
  static_result.

transform_dynamic() ->
  rand:uniform(10).

not_running_test() ->
  ?assertEqual({error, lager_not_running}, lager:log(info, self(), "not running")).

setup() ->
  error_logger:tty(false),
  application:load(lager),
  application:set_env(lager, handlers, [{lager_test_backend, info}]),
  application:set_env(lager, error_logger_redirect, false),
  application:unset_env(lager, traces),
  lager:start(),
  %% There is a race condition between the application start up, lager logging its own
  %% start up condition and several tests that count messages or parse the output of
  %% tests.  When the lager start up message wins the race, it causes these tests
  %% which parse output or count message arrivals to fail.
  %%
  %% We introduce a sleep here to allow `flush' to arrive *after* the start up
  %% message has been received and processed.
  %%
  %% This race condition was first exposed during the work on
  %% 4b5260c4524688b545cc12da6baa2dfa4f2afec9 which introduced the lager
  %% manager killer PR.
  timer:sleep(5),
  gen_event:call(lager_event, lager_test_backend, flush).


cleanup(_) ->
  catch ets:delete(lager_config), %% kill the ets config table with fire
  application:stop(lager),
  application:stop(goldrush),
  error_logger:tty(true).

transform_function_test_() ->
  {foreach,
    fun setup/0,
    fun cleanup/1,
    [
      {"observe that there is nothing up my sleeve",
        fun() ->
          ?assertEqual(undefined, lager_test_backend:pop()),
          ?assertEqual(0, lager_test_backend:count())
        end
      },
      {"logging works",
        fun() ->
          lager:warning("test message"),
          ?assertEqual(1, lager_test_backend:count()),
          {Level, _Time, Message, _Metadata}  = lager_test_backend:pop(),
          ?assertMatch(Level, lager_util:level_to_num(warning)),
          ?assertEqual("test message", Message),
          ok
        end
      },
      {"Test calling a function returns the same content",
        fun() ->
          lager:warning("static message"),
          ?assertEqual(1, lager_test_backend:count()),
          {_Level, _Time, _Message, Metadata} = lager_test_backend:pop(),
          ?assertEqual(transform_static(), proplists:get_value(returns_static, Metadata)),
          ok
        end
      },
      {"Test calling a function which returns content which can change",
        fun() ->
          lager:warning("dynamic message 1"),
          lager:warning("dynamic message 2"),
          lager:warning("dynamic message 3"),
          lager:warning("dynamic message 4"),
          lager:warning("dynamic message 5"),
          lager:warning("dynamic message 6"),
          ?assertEqual(6, lager_test_backend:count()),
          {_Level1, _Time1, _Message1, Metadata1} = lager_test_backend:pop(),
          Replacement1 = proplists:get_value(returns_dynamic, Metadata1),
          ?assert((1 =< Replacement1) and (Replacement1 =< 10)),
          {_Level2, _Time2, _Message2, Metadata2} = lager_test_backend:pop(),
          Replacement2 = proplists:get_value(returns_dynamic, Metadata2),
          ?assert((1 =< Replacement2) and (Replacement2 =< 10)),
          {_Level3, _Time3, _Message3, Metadata3} = lager_test_backend:pop(),
          Replacement3 = proplists:get_value(returns_dynamic, Metadata3),
          ?assert((1 =< Replacement3) and (Replacement3 =< 10)),
          {_Level4, _Time4, _Message4, Metadata4} = lager_test_backend:pop(),
          Replacement4 = proplists:get_value(returns_dynamic, Metadata4),
          ?assert((1 =< Replacement4) and (Replacement4 =< 10)),
          {_Level5, _Time5, _Message5, Metadata5} = lager_test_backend:pop(),
          Replacement5 = proplists:get_value(returns_dynamic, Metadata5),
          ?assert((1 =< Replacement5) and (Replacement5 =< 10)),
          {_Level6, _Time6, _Message6, Metadata6} = lager_test_backend:pop(),
          Replacement6 = proplists:get_value(returns_dynamic, Metadata6),
          ?assert((1 =< Replacement6) and (Replacement6 =< 10)),
          ok
        end
      }
    ]
  }.

-endif.
