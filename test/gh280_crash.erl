-module(gh280_crash).

-include_lib("eunit/include/eunit.hrl").

gh280_crash_test() ->
    error_logger:tty(false),
    %% see https://github.com/erlang/otp/blob/maint/lib/stdlib/src/log_mf_h.erl#L81
    %% for an explanation of the init arguments to log_mf_h
    ok = gen_event:add_sup_handler(error_logger, log_mf_h, log_mf_h:init("/tmp", 10000, 5)),
    lager:start(),
    receive
        {gen_event_EXIT,Handler,Reason} ->
            throw({Handler,Reason});
        X -> 
            throw(X)
    after 2000 ->
            throw(timeout)
    end.
