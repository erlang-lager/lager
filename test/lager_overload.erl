%%% A modules that tries to crash stuff *a lot* to test how long it may
%%% take to overload a given node with log messages, and then compare
%%% that value with what log deduplication may do.
-module(lager_overload).
-compile([{parse_transform, lager_transform}]).
-compile(export_all).

init_regular() ->
    error_logger:tty(false),
    application:load(lager),
    application:set_env(lager, handlers, [{lager_console_backend, [info,true]}]),
    application:set_env(lager, error_logger_redirect, false),
    application:start(crypto),
    ok=application:start(simhash),
    application:start(compiler),
    application:start(syntax_tools),
    application:set_env(lager, duplicate_threshold, 0),
    application:set_env(lager, duplicate_dump, infinity),
    ok=application:start(lager).


init_dedup() ->
    error_logger:tty(false),
    application:load(lager),
    application:set_env(lager, handlers, [{lager_console_backend, [info,true]}]),
    application:set_env(lager, error_logger_redirect, false),
    application:start(crypto),
    application:load(simhash),
    application:start(simhash),
    application:start(compiler),
    application:start(syntax_tools),
    application:set_env(lager, duplicate_threshold, 3),
    application:set_env(lager, duplicate_dump, 1000),
    ok=application:start(lager).

regular(N) ->
    init_regular(),
    spawn(fun() -> spawn_errs(N) end).

dedup(N) ->
    init_dedup(),
    spawn(fun() -> spawn_errs(N) end).

spawn_errs(N) ->
    [spawn(fun() -> err(X) end) || X <- lists:seq(1,N)],
    spawn_errs(N).

err(_) ->
    %% 8: 1a 1b 2b 2c 3b 
    %% 6: 1b 1c 1d 2b 2c 3c 3b
    Str = element(erlang:phash2(self(), 3)+1,
        {"1 my error has the following stacktrace: ~p"
        ,"2 module X failed with reason ~p"
        ,"3 Some other different error message (~p) told me things failed."
    }),
    Stack = element(erlang:phash2(self(),4)+1,
        {{a,'EXIT',{badarith,[{erlang,'/',[1,0],[]},
                        {erl_eval,do_apply,6,[{file,"erl_eval.erl"},{line,576}]},
                        {erl_eval,expr,5,[{file,"erl_eval.erl"},{line,360}]},
                        {shell,exprs,7,[{file,"shell.erl"},{line,668}]},
                        {shell,eval_exprs,7,[{file,"shell.erl"},{line,623}]},
                        {shell,eval_loop,3,[{file,"shell.erl"},{line,608}]}]}}
        ,{b,badarg,[{erlang,atom_to_list,["y"],[]}]}
        ,{c,{badarity,{"#Fun<erl_eval.20.82930912>",[1]}},[{lists,map,2,[{file,"lists.erl"},{line,1173}]}]}
        ,{d,{shell_undef,apply,1,[]},[{shell,shell_undef,2,[{file,"shell.erl"},{line,1092}]},{erl_eval,local_func,5,[{file,"erl_eval.erl"},{line,475}]}]}
    }),
    lager:error(Str, [Stack]).
