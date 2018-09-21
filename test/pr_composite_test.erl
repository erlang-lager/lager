-module(pr_composite_test).

-compile([{parse_transform, lager_transform}]).

-record(a, {field1 :: term(), field2 :: term()}).
-record(b, {field1 :: term() , field2 :: term()}).


-include_lib("eunit/include/eunit.hrl").

nested_record_test() ->
    A = #a{field1 = x, field2 = y}, 
    B = #b{field1 = A, field2 = {}},
    Pr_B = lager:pr(B, ?MODULE),
    ?assertEqual({'$lager_record', b,
                    [{field1, {'$lager_record', a,
                                    [{field1, x},{field2, y}]}},
                     {field2, {}}]}, 
                   Pr_B).

list_field_test() ->
    As = [#a{field1 = 1, field2 = a2},
          #a{field1 = 2, field2 = a2}],
    B = #b{field1 = As, field2 = b2},
    Pr_B = lager:pr(B, ?MODULE),
    ?assertEqual({'$lager_record', b,
                  [{field1, [{'$lager_record', a,
                              [{field1, 1},{field2, a2}]},
                             {'$lager_record', a,
                              [{field1, 2},{field2, a2}]}]},
                   {field2, b2}]},
                 Pr_B).

list_of_records_test() ->
    As = [#a{field1 = 1, field2 = a2},
          #a{field1 = 2, field2 = a2}],
    Pr_As = lager:pr(As, ?MODULE),
    ?assertEqual([{'$lager_record', a, [{field1, 1},{field2, a2}]},
                  {'$lager_record', a, [{field1, 2},{field2, a2}]}],
                 Pr_As).

improper_list_test() ->
    A = #a{field1 = [1|2], field2 = a2},
    Pr_A = lager:pr(A, ?MODULE),
    ?assertEqual({'$lager_record',a,
                  [{field1,[1|2]},{field2,a2}]},
                 Pr_A).
