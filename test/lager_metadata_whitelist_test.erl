
-module(lager_metadata_whitelist_test).


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

setup() ->
    ok = error_logger:tty(false),
    ok = lager_util:safe_application_load(lager),
    ok = application:set_env(lager, handlers, [{lager_common_test_backend, info}]),
    ok = application:set_env(lager, error_logger_redirect, false),
    ok = application:unset_env(lager, traces),
    ok = lager:start(),
    ok = timer:sleep(250),
    ok.

cleanup(_) ->
    ok = application:unset_env(lager, metadata_whitelist),
    catch ets:delete(lager_config), %% kill the ets config table with fire
    ok = application:stop(lager),
    ok = application:stop(goldrush),
    ok = error_logger:tty(true).

date_time_now() ->
    Now = os:timestamp(),
    {Date, Time} = lager_util:format_time(lager_util:maybe_utc(lager_util:localtime_ms(Now))),
    {Date, Time, Now}.

basic_test_() ->
    {Date, Time, Now} = date_time_now(),
    {
        foreach,
        fun setup/0,
        fun cleanup/1,
        [{"Meta", fun() ->
             Whitelist = [meta0],
            ok = application:set_env(lager, metadata_whitelist, Whitelist),
            Msg = lager_msg:new("Message", Now, error, [], []),
            Expected = iolist_to_binary([Date, " ", Time,  " [error]  Message\n"]),
            Got = iolist_to_binary(lager_default_formatter:format(Msg, [])),
            ?assertEqual(Expected, Got)
         end},
            {"Meta1", fun() ->
            Whitelist = [meta1],
            ok = application:set_env(lager, metadata_whitelist, Whitelist),
            Msg = lager_msg:new("Message", Now, error, [{meta1, "value1"}], []),
            Expected = iolist_to_binary([Date, " ", Time,  " [error]  meta1=value1 Message\n"]),
            Got = iolist_to_binary(lager_default_formatter:format(Msg, [])),
            ?assertEqual(Expected, Got)
         end},
         {"Meta2", fun() ->
            Whitelist = [meta1, meta2],
            ok = application:set_env(lager, metadata_whitelist, Whitelist),
            Msg = lager_msg:new("Message", Now, error, [{meta1, "value1"}, {meta2, 2}], []),
            Expected = iolist_to_binary([Date, " ", Time,  " [error]  meta1=value1 meta2=2 Message\n"]),
            Got = iolist_to_binary(lager_default_formatter:format(Msg, [])),
            ?assertEqual(Expected, Got)
         end},
         {"Meta3", fun() ->
            Whitelist = [meta1, meta2],
            ok = application:set_env(lager, metadata_whitelist, Whitelist),
            Msg = lager_msg:new("Message", Now, error, [{meta1, "value1"}, {meta3, 3}], []),
            Expected = iolist_to_binary([Date, " ", Time,  " [error]  meta1=value1 Message\n"]),
            Got = iolist_to_binary(lager_default_formatter:format(Msg, [])),
            ?assertEqual(Expected, Got)
         end}
        ]
    }.


-endif.
