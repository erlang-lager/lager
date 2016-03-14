-module(lager_manager_killer_test).
-author("Sungjin Park <jinni.park@gmail.com>").

-compile([{parse_transform, lager_transform}]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

overload_test() ->
    application:stop(lager),
    application:load(lager),
    Delay = 1000, % sleep 1 sec on every log
    KillerHWM = 10, % kill the manager if there are more than 10 pending logs
    KillerReinstallAfter = 1000, % reinstall killer after 1 sec
    application:set_env(lager, handlers, [{lager_slow_backend, [{delay, Delay}]}]),
    application:set_env(lager, async_threshold, undefined),
    application:set_env(lager, killer_hwm, KillerHWM),
    application:set_env(lager, killer_reinstall_after, KillerReinstallAfter),
    ensure_started(lager),
    lager_config:set(async, true),
    Manager = whereis(lager_event),
    erlang:trace(all, true, [procs]),
    [lager:info("~p'th message", [N]) || N <- lists:seq(1,KillerHWM+2)],
    Margin = 100,
    ok = confirm_manager_exit(Manager, Delay+Margin),
    ok = confirm_sink_reregister(Margin),
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
    application:stop(lager).

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

confirm_sink_reregister(Delay) ->
    receive
        {trace, _Pid, register, lager_event} ->
            ?assertNot(lists:member(lager_manager_killer, gen_event:which_handlers(lager_event)))
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
