-module(lager_rotate).

-compile(export_all).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.


rotate_test_() ->
    {foreach,
        fun() ->
                file:write_file("test1.log", ""),
                file:write_file("test2.log", ""),
                file:write_file("test3.log", ""),
                file:delete("test1.log.0"),
                file:delete("test2.log.0"),
                file:delete("test3.log.0"),
                error_logger:tty(false),
                application:load(lager),
                application:set_env(lager, handlers, 
                    [{lager_file_backend, [{file, "test1.log"}, {level, info}]},
                     {lager_file_backend, [{file, "test2.log"}, {level, info}]}]),
                application:set_env(lager, extra_sinks,
                    [{sink_event, 
                        [{handlers, 
                            [{lager_file_backend, [{file, "test3.log"}, {level, info}]}]}
                        ]}]),
                application:set_env(lager, error_logger_redirect, false),
                application:set_env(lager, async_threshold, undefined),
                lager:start()
        end,
        fun(_) ->
                file:delete("test1.log"),
                file:delete("test2.log"),
                file:delete("test3.log"),
                file:delete("test1.log.0"),
                file:delete("test2.log.0"),
                file:delete("test3.log.0"),
                application:stop(lager),
                application:stop(goldrush),
                error_logger:tty(true)
        end,
        [{"Rotate single file",
            fun() ->
                lager:log(error, self(), "Test message 1"),
                lager:log(sink_event, error, self(), "Sink test message 1", []),
                lager:rotate_handler({lager_file_backend, "test1.log"}),
                timer:sleep(1000),
                true = filelib:is_regular("test1.log.0"),
                lager:log(error, self(), "Test message 2"),
                lager:log(sink_event, error, self(), "Sink test message 2", []),
                
                {ok, File1} = file:read_file("test1.log"),
                {ok, File2} = file:read_file("test2.log"),
                {ok, SinkFile} = file:read_file("test3.log"),
                {ok, File1Old} = file:read_file("test1.log.0"),

                have_no_log(File1, <<"Test message 1">>),
                have_log(File1, <<"Test message 2">>),

                have_log(File2, <<"Test message 1">>),
                have_log(File2, <<"Test message 2">>),

                have_log(File1Old, <<"Test message 1">>),
                have_no_log(File1Old, <<"Test message 2">>),

                have_log(SinkFile, <<"Sink test message 1">>),
                have_log(SinkFile, <<"Sink test message 2">>)
            end},
         {"Rotate sink",
            fun() ->
                lager:log(error, self(), "Test message 1"),
                lager:log(sink_event, error, self(), "Sink test message 1", []),
                lager:rotate_sink(sink_event),
                timer:sleep(1000),
                true = filelib:is_regular("test3.log.0"),
                lager:log(error, self(), "Test message 2"),
                lager:log(sink_event, error, self(), "Sink test message 2", []),
                {ok, File1} = file:read_file("test1.log"),
                {ok, File2} = file:read_file("test2.log"),
                {ok, SinkFile} = file:read_file("test3.log"),
                {ok, SinkFileOld} = file:read_file("test3.log.0"),

                have_log(File1, <<"Test message 1">>),
                have_log(File1, <<"Test message 2">>),

                have_log(File2, <<"Test message 1">>),
                have_log(File2, <<"Test message 2">>),

                have_log(SinkFileOld, <<"Sink test message 1">>),
                have_no_log(SinkFileOld, <<"Sink test message 2">>),

                have_no_log(SinkFile, <<"Sink test message 1">>),
                have_log(SinkFile, <<"Sink test message 2">>)
            end},
         {"Rotate all",
            fun() ->
                lager:log(error, self(), "Test message 1"),
                lager:log(sink_event, error, self(), "Sink test message 1", []),
                lager:rotate_all(),
                timer:sleep(1000),
                true = filelib:is_regular("test3.log.0"),
                lager:log(error, self(), "Test message 2"),
                lager:log(sink_event, error, self(), "Sink test message 2", []),
                {ok, File1} = file:read_file("test1.log"),
                {ok, File2} = file:read_file("test2.log"),
                {ok, SinkFile} = file:read_file("test3.log"),
                {ok, File1Old} = file:read_file("test1.log.0"),
                {ok, File2Old} = file:read_file("test2.log.0"),
                {ok, SinkFileOld} = file:read_file("test3.log.0"),

                have_no_log(File1, <<"Test message 1">>),
                have_log(File1, <<"Test message 2">>),

                have_no_log(File2, <<"Test message 1">>),
                have_log(File2, <<"Test message 2">>),

                have_no_log(SinkFile, <<"Sink test message 1">>),
                have_log(SinkFile, <<"Sink test message 2">>),

                have_log(SinkFileOld, <<"Sink test message 1">>),
                have_no_log(SinkFileOld, <<"Sink test message 2">>),

                have_log(File1Old, <<"Test message 1">>),
                have_no_log(File1Old, <<"Test message 2">>),

                have_log(File2Old, <<"Test message 1">>),
                have_no_log(File2Old, <<"Test message 2">>)

            end}]}.

have_log(Data, Log) ->
    {_,_} = binary:match(Data, Log).

have_no_log(Data, Log) ->
    nomatch = binary:match(Data, Log).

