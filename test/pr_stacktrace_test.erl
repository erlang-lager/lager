-module(pr_stacktrace_test).

-compile([{parse_transform, lager_transform}]).

-ifdef(OTP_RELEASE). %% this implies 21 or higher
-define(EXCEPTION(Class, Reason, Stacktrace), Class:Reason:Stacktrace).
-define(GET_STACK(Stacktrace), Stacktrace).
-else.
-define(EXCEPTION(Class, Reason, _), Class:Reason).
-define(GET_STACK(_), erlang:get_stacktrace()).
-endif.

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
        ?EXCEPTION(Class, Reason, Stacktrace) ->
            lager:pr_stacktrace(?GET_STACK(Stacktrace), {Class, Reason})
    end,
ExpectedPart = "
    pr_stacktrace_test:pr_stacktrace_throw_test/0 line 26
    pr_stacktrace_test:make_throw/0 line 16
throw:{test,exception}",
    ?assertNotEqual(0, string:str(Result, ExpectedPart)).


pr_stacktrace_bad_arg_test() ->
    Result = try
        bad_arg()
    catch
        ?EXCEPTION(Class, Reason, Stacktrace) ->
            lager:pr_stacktrace(?GET_STACK(Stacktrace), {Class, Reason})
    end,
ExpectedPart = "
    pr_stacktrace_test:pr_stacktrace_bad_arg_test/0 line 40
    pr_stacktrace_test:bad_arg/0 line 22
error:badarg",
    ?assertNotEqual(0, string:str(Result, ExpectedPart)).


pr_stacktrace_bad_arity_test() ->
    Result = try
        bad_arity()
    catch
        ?EXCEPTION(Class, Reason, Stacktrace) ->
            lager:pr_stacktrace(?GET_STACK(Stacktrace), {Class, Reason})
    end,
ExpectedPart = "
    pr_stacktrace_test:pr_stacktrace_bad_arity_test/0 line 54
    lists:concat([], [])
error:undef",
    ?assertNotEqual(0, string:str(Result, ExpectedPart)).

pr_stacktrace_no_reverse_test() ->
    application:set_env(lager, reverse_pretty_stacktrace, false),
    Result = try
        bad_arity()
    catch
        ?EXCEPTION(Class, Reason, Stacktrace) ->
            lager:pr_stacktrace(?GET_STACK(Stacktrace), {Class, Reason})
    end,
ExpectedPart = "error:undef
    lists:concat([], [])
    pr_stacktrace_test:pr_stacktrace_bad_arity_test/0 line 68",

    ?assertEqual(0, string:str(Result, ExpectedPart)).
