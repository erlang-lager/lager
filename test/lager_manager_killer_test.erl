-module(lager_manager_killer_test).
-author("Sungjin Park <jinni.park@gmail.com>").

-compile([{parse_transform, lager_transform}]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-define(TEST_SINK_NAME, '__lager_test_sink').              %% <-- used by parse transform
-define(TEST_SINK_EVENT, '__lager_test_sink_lager_event'). %% <-- used by lager API calls and internals for gen_event

overload_test_() ->
    {timeout, 60,
     fun() ->
             application:stop(lager),
             application:load(lager),
             Delay = 1000, % sleep 1 sec on every log
             KillerHWM = 10, % kill the manager if there are more than 10 pending logs
             KillerReinstallAfter = 1000, % reinstall killer after 1 sec
             application:set_env(lager, handlers, [{lager_slow_backend, [{delay, Delay}]}]),
             application:set_env(lager, async_threshold, undefined),
             application:set_env(lager, error_logger_redirect, true),
             application:set_env(lager, killer_hwm, KillerHWM),
             application:set_env(lager, killer_reinstall_after, KillerReinstallAfter),
             ensure_started(lager),
             lager_config:set(async, true),
             Manager = whereis(lager_event),
             erlang:trace(all, true, [procs]),
             [lager:info("~p'th message", [N]) || N <- lists:seq(1,KillerHWM+2)],
             Margin = 100,
             ok = confirm_manager_exit(Manager, Delay+Margin),
             ok = confirm_sink_reregister(lager_event, Margin),
             erlang:trace(all, false, [procs]),
             wait_until(fun() ->
                                case proplists:get_value(lager_manager_killer, gen_event:which_handlers(lager_event)) of
                                    [] -> false;
                                    _ -> true
                                end
                        end, Margin, 15),
             wait_until(fun() ->
                                case gen_event:call(lager_event, lager_manager_killer, get_settings) of
                                    [KillerHWM, KillerReinstallAfter] -> true;
                                    _Other -> false
                                end
                        end, Margin, 15),
             application:stop(lager)
     end}.

overload_alternate_sink_test_() ->
    {timeout, 60,
     fun() ->
             application:stop(lager),
             application:load(lager),
             Delay = 1000, % sleep 1 sec on every log
             KillerHWM = 10, % kill the manager if there are more than 10 pending logs
             KillerReinstallAfter = 1000, % reinstall killer after 1 sec
             application:set_env(lager, handlers, []),
             application:set_env(lager, extra_sinks, [{?TEST_SINK_EVENT, [
                                                                          {handlers, [{lager_slow_backend, [{delay, Delay}]}]},
                                                                          {killer_hwm, KillerHWM},
                                                                          {killer_reinstall_after, KillerReinstallAfter},
                                                                          {async_threshold, undefined}
                                                                         ]}]),
             application:set_env(lager, error_logger_redirect, true),
             ensure_started(lager),
             lager_config:set({?TEST_SINK_EVENT, async}, true),
             Manager = whereis(?TEST_SINK_EVENT),
             erlang:trace(all, true, [procs]),
             [?TEST_SINK_NAME:info("~p'th message", [N]) || N <- lists:seq(1,KillerHWM+2)],
             Margin = 100,
             ok = confirm_manager_exit(Manager, Delay+Margin),
             ok = confirm_sink_reregister(?TEST_SINK_EVENT, Margin),
             erlang:trace(all, false, [procs]),
             wait_until(fun() ->
                                case proplists:get_value(lager_manager_killer, gen_event:which_handlers(?TEST_SINK_EVENT)) of
                                    [] -> false;
                                    _ -> true
                                end
                        end, Margin, 15),
             wait_until(fun() ->
                                case gen_event:call(?TEST_SINK_EVENT, lager_manager_killer, get_settings) of
                                    [KillerHWM, KillerReinstallAfter] -> true;
                                    _Other -> false
                                end
                        end, Margin, 15),
             application:stop(lager)
     end}.

ensure_started(App) ->
    case application:start(App) of
        ok ->
            ok;
        {error, {not_started, Dep}} ->
            ensure_started(Dep),
            ensure_started(App)
    end.

confirm_manager_exit(Manager, Delay) ->
    receive
        {trace, Manager, exit, killed} ->
            ?debugFmt("Manager ~p killed", [Manager]);
        Other ->
            ?debugFmt("OTHER MSG: ~p", [Other]),
            confirm_manager_exit(Manager, Delay)
    after Delay ->
            ?assert(false)
    end.

confirm_sink_reregister(Sink, Delay) ->
    receive
        {trace, _Pid, register, Sink} ->
            ?assertNot(lists:member(lager_manager_killer, gen_event:which_handlers(Sink)))
    after Delay ->
            ?assert(false)
    end.

wait_until(_Fun, _Delay, 0) ->
    {error, too_many_retries};
wait_until(Fun, Delay, Retries) ->
    case Fun() of
        true -> ok;
        false -> timer:sleep(Delay), wait_until(Fun, Delay, Retries-1)
    end.

-endif.
