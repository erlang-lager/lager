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

-compile([{nowarn_deprecated_function, [{erlang, now, 0}]}]).

-lager_function_transforms([
  {returns_static_emit, on_emit, {lager_test_function_transform, transform_static}},
  {returns_dynamic_emit, on_emit, {lager_test_function_transform, transform_dynamic}},
  {returns_undefined_emit, on_emit, {not_real_module_fake, fake_not_real_function}},

  {returns_static_log, on_log, {lager_test_function_transform, transform_static}},
  {returns_dynamic_log, on_log, {lager_test_function_transform, transform_dynamic}}
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
  case lager_util:otp_version() >= 18 of
    true ->
      erlang:monotonic_time();
    false ->
      erlang:now()
  end.

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
      {"Testing calling a function returns the same content on emit",
        fun() ->
          lager:warning("static message"),
          ?assertEqual(1, lager_test_backend:count()),
          {_Level, _Time, _Message, Metadata} = lager_test_backend:pop(),
          Function = proplists:get_value(returns_static_emit, Metadata),
          ?assertEqual(transform_static(), Function()),
          ok
        end
      },
      {"Testing calling a function which returns content which can change on emit",
        fun() ->
          lager:warning("dynamic message"),
          ?assertEqual(1, lager_test_backend:count()),
          {_Level, _Time, _Message, Metadata} = lager_test_backend:pop(),
          Function = proplists:get_value(returns_dynamic_emit, Metadata),
          ?assert(Function() < Function()),
          ?assert(Function() < Function()),
          ?assert(Function() < Function()),
          ?assert(Function() < Function()),
          ok
        end
      },
      {"Testing a undefined function returns undefined on emit",
        fun() ->
          lager:warning("Undefined error"),
          ?assertEqual(1, lager_test_backend:count()),
          {_Level, _Time, _Message, Metadata} = lager_test_backend:pop(),
          Function = proplists:get_value(returns_undefined_emit, Metadata),
          [{module, Module}, {name, Name}|_] = erlang:fun_info(Function),
          ?assertNot(erlang:function_exported(Module, Name, 0)),
          ok
        end
      },
      {"Testing calling a function returns the same content on log",
        fun() ->
          lager:warning("static message"),
          ?assertEqual(1, lager_test_backend:count()),
          {_Level, _Time, _Message, Metadata} = lager_test_backend:pop(),
          ?assertEqual(transform_static(), proplists:get_value(returns_static_log, Metadata)),
          ok
        end
      },
      {"Testing calling a dynamic function on log which returns the same value",
        fun() ->
          lager:warning("dynamic message"),
          ?assertEqual(1, lager_test_backend:count()),
          {_Level, _Time, _Message, Metadata} = lager_test_backend:pop(),
          Value = proplists:get_value(returns_dynamic_log, Metadata),
          ?assert(Value < transform_dynamic()),
          ?assert(Value < transform_dynamic()),
          ?assert(Value < transform_dynamic()),
          ?assert(Value < transform_dynamic()),
          ?assert(Value < transform_dynamic()),
          ok
        end
      },
      {"Testing differences in results for on_log vs on emit from dynamic function",
        fun() ->
          lager:warning("on_log vs on emit"),
          ?assertEqual(1, lager_test_backend:count()),
          {_Level, _Time, _Message, Metadata} = lager_test_backend:pop(),
          Value = proplists:get_value(returns_dynamic_log, Metadata),
          Function = proplists:get_value(returns_dynamic_emit, Metadata),
          FunctionResult = Function(),
          ?assert(Value < FunctionResult),
          ?assert(Value < Function()),
          ?assert(FunctionResult < Function()),
          ok
        end
      },
      {"Testing a function provided via metadata",
        fun()->
          Provided = fun()->
            provided_metadata
          end,
          lager:md([{provided, Provided}]),
          lager:warning("Provided metadata"),
          ?assertEqual(1, lager_test_backend:count()),
          {_Level, _Time, _Message, Metadata} = lager_test_backend:pop(),
          Function = proplists:get_value(provided, Metadata),
          ?assertEqual(Provided(), Function()),
          ok
        end
      }
    ]
  }.

-endif.
