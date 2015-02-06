-module(compress_pr_record_test).

-compile([{parse_transform, lager_transform}]).

-record(a, {field1, field2, foo, bar, baz, zyu, zix}).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

nested_record_test() ->
    A = #a{field1 = "Notice me senpai"},
    Pr_A = lager:pr(A, ?MODULE),
    Pr_A_Comp = lager:pr(A, ?MODULE, [compress]),
    ?assertMatch({'$lager_record', a, [{field1, "Notice me senpai"}, {field2, undefined} | _]}, Pr_A),
    ?assertEqual({'$lager_record', a, [{field1, "Notice me senpai"}]}, Pr_A_Comp).
