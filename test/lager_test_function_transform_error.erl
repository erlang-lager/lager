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

-module(lager_test_function_transform_error).

-compile([
  {parse_transform, lager_transform}
]).

-lager_function_transforms([
  {returns_undefined, {not_real_module_fake, fake_not_real_function}}
]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

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

transform_function_error_test_() ->
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
      {"Testing a function transform for a undefined function errors",
        fun() ->
          ?assertError(undef, lager:warning("undefined message")),
          ok
        end
      }
    ]
  }.