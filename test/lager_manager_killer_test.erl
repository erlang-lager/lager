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
  receive
    {trace, Manager, exit, killed} ->
      ?debugFmt("Manager ~p killed", [Manager])
  after Delay+Margin ->
    ?assert(false)
  end,
  receive
    {trace, _Sup, spawn, Pid, Fun} ->
      ?assert(process_info(Pid, registered_name) =:= {registered_name, lager_event}),
      ?debugFmt("Manager ~p start with ~p", [Pid, Fun]),
      ?assertNot(lists:member(lager_manager_killer, gen_event:which_handlers(lager_event)))
  after Margin ->
      ?assert(false)
  end,
  erlang:trace(all, false, [procs]),
  timer:sleep(KillerReinstallAfter),
  ?assert(proplists:get_value(lager_manager_killer, gen_event:which_handlers(lager_event))),
  ?assert(gen_event:call(lager_event, lager_manager_killer, get_settings) =:= [KillerHWM, KillerReinstallAfter]),
  ?debugFmt("Killer reinstalled with [~p, ~p]", [KillerHWM, KillerReinstallAfter]),
  application:stop(lager).

ensure_started(App) ->
  case application:start(App) of
    ok ->
      ok;
    {error, {not_started, Dep}} ->
      ensure_started(Dep),
      ensure_started(App)
  end.

-endif.
