-module(lager_app_tests).

-compile([{parse_transform, lager_transform}]).

-include_lib("eunit/include/eunit.hrl").


get_env_default_test() ->
    ?assertEqual(<<"Some">>,  lager_app:get_env_default(undefined,         <<"Some">>)),
    ?assertEqual(<<"Value">>, lager_app:get_env_default({ok, <<"Value">>}, <<"Some">>)),
    ok.

get_env_test() ->
    application:set_env(myapp, mykey1, <<"Value">>),

    ?assertEqual(<<"Some">>,  lager_app:get_env(myapp, mykey0, <<"Some">>)),
    ?assertEqual(<<"Value">>, lager_app:get_env(myapp, mykey1, <<"Some">>)),

    ?assertEqual(undefined,   lager_app:get_env(myapp, mykey0)),
    ?assertEqual(<<"Value">>, lager_app:get_env(myapp, mykey1)),
    ok.

