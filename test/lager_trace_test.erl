-module(lager_trace_test).

-compile([{parse_transform, lager_transform}]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

% Our expectation is that the first log entry will appear so we won't actually
% wait out ?FIRST_LOG_ENTRY_TIMEOUT. On the other hand, the second log entry is
% expected never to arrive, so the test will wait out ?SECOND_LOG_ENTRY_TIMEOUT;
% that's why it is shorter.
-define(FIRST_LOG_ENTRY_TIMEOUT, (10 * 1000)). % 10 seconds
-define(SECOND_LOG_ENTRY_TIMEOUT, 1000). % 1 second

-define(FNAME, "test/test1.log").

trace_test_() ->
    {timeout,
     10,
     {foreach,
         fun() ->
                 file:write_file(?FNAME, ""),
                 error_logger:tty(false),
                 application:load(lager),
                 application:set_env(lager, log_root, "test"),
                 application:set_env(lager, handlers,
                                     [{lager_file_backend,
                                       [{file, "test1.log"},
                                        {level, none},
                                        {formatter, lager_default_formatter},
                                        {formatter_config, [message, "\n"]}
                                       ]}]),
                 application:set_env(lager, traces,
                                     [{{lager_file_backend, "test1.log"},
                                       [{tag, mytag}], info}]),
                 application:set_env(lager, error_logger_redirect, false),
                 application:set_env(lager, async_threshold, undefined),
                 lager:start()
         end,
         fun(_) ->
                 file:delete(?FNAME),
                 application:stop(lager),
                 application:stop(goldrush),
                 application:unset_env(lager, log_root),
                 application:unset_env(lager, handlers),
                 application:unset_env(lager, traces),
                 application:unset_env(lager, error_logger_redirect),
                 application:unset_env(lager, async_threshold),
                 error_logger:tty(true)
         end,
         [{"Trace combined with log_root",
             fun() ->
                 lager:info([{tag, mytag}], "Test message"),

                 % Wait until we have the expected log entry in the log file.
                 case wait_until(fun() ->
                                         count_lines(?FNAME) >= 1
                                 end, ?FIRST_LOG_ENTRY_TIMEOUT) of
                     ok ->
                         ok;
                     {error, timeout} ->
                         throw({file_empty, file:read_file(?FNAME)})
                 end,

                 % Let's wait a little to see that we don't get a duplicate log
                 % entry.
                 case wait_until(fun() ->
                                         count_lines(?FNAME) >= 2
                                 end, ?SECOND_LOG_ENTRY_TIMEOUT) of
                     ok ->
                         throw({too_many_entries, file:read_file(?FNAME)});
                     {error, timeout} ->
                         ok
                 end
             end}
          ]}}.

% Wait until Fun() returns true.
wait_until(Fun, Timeout) ->
    wait_until(Fun, Timeout, {8, 13}).

wait_until(_Fun, Timeout, {T1, _}) when T1 > Timeout ->
    {error, timeout};
wait_until(Fun, Timeout, {T1, T2}) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(T1),
            wait_until(Fun, Timeout, {T2, T1 + T2})
    end.

% Return the number of lines in a file. Return 0 for a non-existent file.
count_lines(Filename) ->
    case file:read_file(Filename) of
        {ok, Content} ->
            Lines = binary:split(Content, <<"\n">>, [global, trim]),
            length(Lines);
        {error, _} ->
            0
    end.

-endif.
