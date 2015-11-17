-module(pr_stacktrace_test).

-compile([{parse_transform, lager_transform}]).

-include_lib("eunit/include/eunit.hrl").

foo() ->
    throw(test).

pr_stacktrace_test() ->
    Result = try
        foo()
    catch
        _Class:_Error ->
            Stacktrace = lists:reverse(erlang:get_stacktrace()),
            lager:pr_stacktrace(Stacktrace)
    end,
ExpectedPart = <<"
    fun pr_stacktrace_test:pr_stacktrace_test/0
        file \"test/pr_stacktrace_test.erl\"
        line 12
    fun pr_stacktrace_test:foo/0
        file \"test/pr_stacktrace_test.erl\"
        line 8">>,

    ?assertNotEqual(nomatch, binary:match(Result, ExpectedPart, [])).
