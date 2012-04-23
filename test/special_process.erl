-module(special_process).
-export([start/0, init/1]).

start() ->
    proc_lib:start_link(?MODULE, init, [self()]).

init(Parent) ->
    proc_lib:init_ack(Parent, {ok, self()}),
    loop().

loop() ->
    receive
        function_clause ->
            foo(bar),
            loop();
        exit ->
            exit(byebye),
            loop();
        error ->
            erlang:error(mybad),
            loop();
        {case_clause, X} ->
            case X of
                notgonnamatch ->
                    ok;
                notthiseither ->
                    error
            end,
            loop();
        _ ->
            loop()
    end.

foo(baz) ->
    ok.

