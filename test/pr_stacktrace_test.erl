-module(pr_stacktrace_test).

-compile([{parse_transform, lager_transform}]).

-include_lib("eunit/include/eunit.hrl").

make_throw() ->
    throw({test, exception}).

bad_arity() ->
    lists:concat([], []).

bad_arg() ->
    integer_to_list(1.0).

pr_stacktrace_throw_test() ->
    Result = try
        make_throw()
    catch
        Class:Reason ->
            lager:pr_stacktrace(erlang:get_stacktrace(), {Class, Reason})
    end,
ExpectedPart = "
    pr_stacktrace_test:pr_stacktrace_throw_test/0 line 18
    pr_stacktrace_test:make_throw/0 line 8
throw:{test,exception}",
    ?assertNotEqual(0, string:str(Result, ExpectedPart)).


pr_stacktrace_bad_arg_test() ->
    Result = try
        bad_arg()
    catch
        Class:Reason ->
            lager:pr_stacktrace(erlang:get_stacktrace(), {Class, Reason})
    end,
ExpectedPart = "
    pr_stacktrace_test:pr_stacktrace_bad_arg_test/0 line 32
    pr_stacktrace_test:bad_arg/0 line 14
error:badarg",
    ?assertNotEqual(0, string:str(Result, ExpectedPart)).


pr_stacktrace_bad_arity_test() ->
    Result = try
        bad_arity()
    catch
        Class:Reason ->
            lager:pr_stacktrace(erlang:get_stacktrace(), {Class, Reason})
    end,
ExpectedPart = "
    pr_stacktrace_test:pr_stacktrace_bad_arity_test/0 line 46
    lists:concat([], [])
error:undef",
    ?assertNotEqual(0, string:str(Result, ExpectedPart)).