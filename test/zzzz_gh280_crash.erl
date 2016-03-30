%% @doc This test is named zzzz_gh280_crash because it has to be run first and tests are run in 
%% reverse alphabetical order.
%%
%% The problem we are attempting to detect here is when log_mf_h is installed as a handler for error_logger
%% and lager starts up to replace the current handlers with its own.  This causes a start up crash because
%% OTP error logging modules do not have any notion of a lager-style log level.
-module(zzzz_gh280_crash).
-compile(export_all).

-include_lib("eunit/include/eunit.hrl").

gh280_crash_test() ->
    {timeout, 30, fun() -> gh280_impl() end}.

gh280_impl() ->
    application:stop(lager),
    application:stop(goldrush),

    error_logger:tty(false),
    %% see https://github.com/erlang/otp/blob/maint/lib/stdlib/src/log_mf_h.erl#L81
    %% for an explanation of the init arguments to log_mf_h
    ok = gen_event:add_sup_handler(error_logger, log_mf_h, log_mf_h:init("/tmp", 10000, 5)),
    lager:start(),
    Result = receive
        {gen_event_EXIT,log_mf_h,normal} -> 
            true;
        {gen_event_EXIT,Handler,Reason} ->
            {Handler,Reason};
        X -> 
            X
    after 10000 ->
        timeout
    end,
    ?assert(Result),
    application:stop(lager),
    application:stop(goldrush).
