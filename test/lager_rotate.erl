%% -------------------------------------------------------------------
%%
%% Copyright (c) 2016-2017 Basho Technologies, Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(lager_rotate).

-compile(export_all).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-record(state, {
    dir     :: string(),
    log1    :: string(),
    log1r   :: string(),
    log2    :: string(),
    log2r   :: string(),
    sink    :: string(),
    sinkr   :: string()
}).

rotate_test_() ->
    {foreach,
        fun() ->
            Dir = lager_util:create_test_dir(),
            Log1 = filename:join(Dir, "test1.log"),
            Log2 = filename:join(Dir, "test2.log"),
            Sink = filename:join(Dir, "sink.log"),
            State = #state{
                dir     = Dir,
                log1    = Log1,
                log1r   = Log1 ++ ".0",
                log2    = Log2,
                log2r   = Log2 ++ ".0",
                sink    = Sink,
                sinkr   = Sink ++ ".0"
            },
            file:write_file(Log1, []),
            file:write_file(Log2, []),
            file:write_file(Sink, []),

            error_logger:tty(false),
            application:load(lager),
            application:set_env(lager, handlers, [
                {lager_file_backend, [{file, Log1}, {level, info}]},
                {lager_file_backend, [{file, Log2}, {level, info}]} ]),
            application:set_env(lager, extra_sinks, [
                {sink_event,
                    [{handlers,
                        [{lager_file_backend, [{file, Sink}, {level, info}]}]}
                    ]}]),
            application:set_env(lager, error_logger_redirect, false),
            application:set_env(lager, async_threshold, undefined),
            lager:start(),
            State
        end,
        fun(#state{dir = Dir}) ->
            application:stop(lager),
            application:stop(goldrush),
            lager_util:delete_test_dir(Dir),
            error_logger:tty(true)
        end, [
        fun(State) ->
            {"Rotate single file",
            fun() ->
                lager:log(error, self(), "Test message 1"),
                lager:log(sink_event, error, self(), "Sink test message 1", []),
                lager:rotate_handler({lager_file_backend, State#state.log1}),
                ok = wait_until(fun() -> filelib:is_regular(State#state.log1r) end, 10),
                lager:log(error, self(), "Test message 2"),
                lager:log(sink_event, error, self(), "Sink test message 2", []),

                {ok, File1} = file:read_file(State#state.log1),
                {ok, File2} = file:read_file(State#state.log2),
                {ok, SinkFile} = file:read_file(State#state.sink),
                {ok, File1Old} = file:read_file(State#state.log1r),

                have_no_log(File1, <<"Test message 1">>),
                have_log(File1, <<"Test message 2">>),

                have_log(File2, <<"Test message 1">>),
                have_log(File2, <<"Test message 2">>),

                have_log(File1Old, <<"Test message 1">>),
                have_no_log(File1Old, <<"Test message 2">>),

                have_log(SinkFile, <<"Sink test message 1">>),
                have_log(SinkFile, <<"Sink test message 2">>)
            end}
        end,
        fun(State) ->
            {"Rotate sink",
            fun() ->
                lager:log(error, self(), "Test message 1"),
                lager:log(sink_event, error, self(), "Sink test message 1", []),
                lager:rotate_sink(sink_event),
                ok = wait_until(fun() -> filelib:is_regular(State#state.sinkr) end, 10),
                lager:log(error, self(), "Test message 2"),
                lager:log(sink_event, error, self(), "Sink test message 2", []),
                {ok, File1} = file:read_file(State#state.log1),
                {ok, File2} = file:read_file(State#state.log2),
                {ok, SinkFile} = file:read_file(State#state.sink),
                {ok, SinkFileOld} = file:read_file(State#state.sinkr),

                have_log(File1, <<"Test message 1">>),
                have_log(File1, <<"Test message 2">>),

                have_log(File2, <<"Test message 1">>),
                have_log(File2, <<"Test message 2">>),

                have_log(SinkFileOld, <<"Sink test message 1">>),
                have_no_log(SinkFileOld, <<"Sink test message 2">>),

                have_no_log(SinkFile, <<"Sink test message 1">>),
                have_log(SinkFile, <<"Sink test message 2">>)
            end}
        end,
        fun(State) ->
            {"Rotate all",
            fun() ->
                lager:log(error, self(), "Test message 1"),
                lager:log(sink_event, error, self(), "Sink test message 1", []),
                lager:rotate_all(),
                ok = wait_until(fun() -> filelib:is_regular(State#state.sinkr) end, 10),
                lager:log(error, self(), "Test message 2"),
                lager:log(sink_event, error, self(), "Sink test message 2", []),
                {ok, File1} = file:read_file(State#state.log1),
                {ok, File2} = file:read_file(State#state.log2),
                {ok, SinkFile} = file:read_file(State#state.sink),
                {ok, File1Old} = file:read_file(State#state.log1r),
                {ok, File2Old} = file:read_file(State#state.log2r),
                {ok, SinkFileOld} = file:read_file(State#state.sinkr),

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

            end}
        end
    ]}.

have_log(Data, Log) ->
    {_,_} = binary:match(Data, Log).

have_no_log(Data, Log) ->
    nomatch = binary:match(Data, Log).

wait_until(_Fun, 0) -> {error, too_many_retries};
wait_until(Fun, Retry) ->
    case Fun() of
        true -> ok;
        false ->
            timer:sleep(500),
            wait_until(Fun, Retry-1)
    end.
