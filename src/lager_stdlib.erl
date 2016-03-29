%%
%% %CopyrightBegin%
%% 
%% Copyright Ericsson AB 1996-2009. All Rights Reserved.
%% 
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%% 
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%% 
%% %CopyrightEnd%
%%

%% @doc Functions from Erlang OTP distribution that are really useful
%% but aren't exported.
%%
%% All functions in this module are covered by the Erlang/OTP source
%% distribution's license, the Erlang Public License.  See
%% http://www.erlang.org/ for full details.

-module(lager_stdlib).

-export([string_p/1]).
-export([write_time/2, maybe_utc/1]).
-export([is_my_error_report/1, is_my_info_report/1]).
-export([sup_get/2]).
-export([proc_lib_format/2]).


%% from error_logger_file_h
string_p([]) ->
    false;
string_p(Term) ->
    string_p1(Term).

string_p1([H|T]) when is_integer(H), H >= $\s, H < 256 ->
    string_p1(T);
string_p1([$\n|T]) -> string_p1(T);
string_p1([$\r|T]) -> string_p1(T);
string_p1([$\t|T]) -> string_p1(T);
string_p1([$\v|T]) -> string_p1(T);
string_p1([$\b|T]) -> string_p1(T);
string_p1([$\f|T]) -> string_p1(T);
string_p1([$\e|T]) -> string_p1(T);
string_p1([H|T]) when is_list(H) ->
    case string_p1(H) of
        true -> string_p1(T);
        _    -> false
    end;
string_p1([]) -> true;
string_p1(_) ->  false.

%% From calendar
-type year1970() :: 1970..10000.  % should probably be 1970..
-type month()    :: 1..12.
-type day()      :: 1..31.
-type hour()     :: 0..23.
-type minute()   :: 0..59.
-type second()   :: 0..59.
-type t_time()         :: {hour(),minute(),second()}.
-type t_datetime1970() :: {{year1970(),month(),day()},t_time()}.

%% From OTP stdlib's error_logger_tty_h.erl ... These functions aren't
%% exported.
-spec write_time({utc, t_datetime1970()} | t_datetime1970(), string()) -> string().
write_time({utc,{{Y,Mo,D},{H,Mi,S}}},Type) ->
    io_lib:format("~n=~s==== ~p-~s-~p::~s:~s:~s UTC ===~n",
                  [Type,D,month(Mo),Y,t(H),t(Mi),t(S)]);
write_time({{Y,Mo,D},{H,Mi,S}},Type) ->
    io_lib:format("~n=~s==== ~p-~s-~p::~s:~s:~s ===~n",
                  [Type,D,month(Mo),Y,t(H),t(Mi),t(S)]).

-spec maybe_utc(t_datetime1970()) -> {utc, t_datetime1970()} | t_datetime1970().
maybe_utc(Time) ->
    UTC = case application:get_env(sasl, utc_log) of
        {ok, Val} ->
            Val;
        undefined ->
            %% Backwards compatible:
            lager_app:get_env(stdlib, utc_log, false)
    end,
    if
        UTC =:= true ->
            UTCTime = case calendar:local_time_to_universal_time_dst(Time) of
                []     -> calendar:local_time();
                [T0|_] -> T0
            end,
            {utc, UTCTime};
        true -> 
            Time
    end.

t(X) when is_integer(X) ->
    t1(integer_to_list(X));
t(_) ->
    "".
t1([X]) -> [$0,X];
t1(X)   -> X.

month(1) -> "Jan";
month(2) -> "Feb";
month(3) -> "Mar";
month(4) -> "Apr";
month(5) -> "May";
month(6) -> "Jun";
month(7) -> "Jul";
month(8) -> "Aug";
month(9) -> "Sep";
month(10) -> "Oct";
month(11) -> "Nov";
month(12) -> "Dec".

%% From OTP sasl's sasl_report.erl ... These functions aren't
%% exported.
-spec is_my_error_report(atom()) -> boolean().
is_my_error_report(supervisor_report)   -> true;
is_my_error_report(crash_report)        -> true;
is_my_error_report(_)                   -> false.

-spec is_my_info_report(atom()) -> boolean().
is_my_info_report(progress)  -> true;
is_my_info_report(_)         -> false.

-spec sup_get(term(), [proplists:property()]) -> term().
sup_get(Tag, Report) ->
    case lists:keysearch(Tag, 1, Report) of
        {value, {_, Value}} ->
            Value;
        _ ->
            ""
    end.

%% From OTP stdlib's proc_lib.erl ... These functions aren't exported.
-spec proc_lib_format([term()], pos_integer()) -> string().
proc_lib_format([OwnReport,LinkReport], FmtMaxBytes) ->
    OwnFormat = format_report(OwnReport, FmtMaxBytes),
    LinkFormat = format_report(LinkReport, FmtMaxBytes),
    %% io_lib:format here is OK because we're limiting max length elsewhere.
    Str = io_lib:format("  crasher:~n~s  neighbours:~n~s",[OwnFormat,LinkFormat]),
    lists:flatten(Str).

format_report(Rep, FmtMaxBytes) when is_list(Rep) ->
    format_rep(Rep, FmtMaxBytes);
format_report(Rep, FmtMaxBytes) ->
    {Str, _} = lager_trunc_io:print(Rep, FmtMaxBytes),
    io_lib:format("~p~n", [Str]).

format_rep([{initial_call,InitialCall}|Rep], FmtMaxBytes) ->
    [format_mfa(InitialCall, FmtMaxBytes)|format_rep(Rep, FmtMaxBytes)];
format_rep([{error_info,{Class,Reason,StackTrace}}|Rep], FmtMaxBytes) ->
    [format_exception(Class, Reason, StackTrace, FmtMaxBytes)|format_rep(Rep, FmtMaxBytes)];
format_rep([{Tag,Data}|Rep], FmtMaxBytes) ->
    [format_tag(Tag, Data, FmtMaxBytes)|format_rep(Rep, FmtMaxBytes)];
format_rep(_, _S) ->
    [].

format_exception(Class, Reason, StackTrace, FmtMaxBytes) ->
    PF = pp_fun(FmtMaxBytes),
    StackFun = fun(M, _F, _A) -> (M =:= erl_eval) or (M =:= ?MODULE) end,
    %% EI = "    exception: ",
    EI = "    ",
    [EI, lib_format_exception(1+length(EI), Class, Reason, 
                              StackTrace, StackFun, PF), "\n"].

format_mfa({M,F,Args}=StartF, FmtMaxBytes) ->
    try
        A = length(Args),
        ["    initial call: ",atom_to_list(M),$:,atom_to_list(F),$/,
         integer_to_list(A),"\n"]
    catch
        error:_ ->
            format_tag(initial_call, StartF, FmtMaxBytes)
    end.

pp_fun(FmtMaxBytes) ->
    fun(Term, _I) -> 
            {Str, _} = lager_trunc_io:print(Term, FmtMaxBytes),
            io_lib:format("~s", [Str]) 
    end.

format_tag(Tag, Data, FmtMaxBytes) ->
    {Str, _} = lager_trunc_io:print(Data, FmtMaxBytes),
    io_lib:format("    ~p: ~s~n", [Tag, Str]).

%% From OTP stdlib's lib.erl ... These functions aren't exported.

lib_format_exception(I, Class, Reason, StackTrace, StackFun, FormatFun) 
            when is_integer(I), I >= 1, is_function(StackFun, 3), 
                 is_function(FormatFun, 2) ->
    Str = n_spaces(I-1),
    {Term,Trace1,Trace} = analyze_exception(Class, Reason, StackTrace),
    Expl0 = explain_reason(Term, Class, Trace1, FormatFun, Str),
    Expl = io_lib:fwrite(<<"~s~s">>, [exited(Class), Expl0]),
    case format_stacktrace1(Str, Trace, FormatFun, StackFun) of
        [] -> Expl;
        Stack -> [Expl, $\n, Stack]
    end.

analyze_exception(error, Term, Stack) ->
    case {is_stacktrace(Stack), Stack, Term} of
        {true, [{_M,_F,As}=MFA|MFAs], function_clause} when is_list(As) -> 
            {Term,[MFA],MFAs};
        {true, [{shell,F,A}], function_clause} when is_integer(A) ->
            {Term, [{F,A}], []};
        {true, [{_M,_F,_AorAs}=MFA|MFAs], undef} ->
            {Term,[MFA],MFAs};
        {true, _, _} ->
            {Term,[],Stack};
        {false, _, _} ->
            {{Term,Stack},[],[]}
    end;
analyze_exception(_Class, Term, Stack) ->
    case is_stacktrace(Stack) of
        true ->
            {Term,[],Stack};
        false ->
            {{Term,Stack},[],[]}
    end.

is_stacktrace([]) ->
    true;
is_stacktrace([{M,F,A}|Fs]) when is_atom(M), is_atom(F), is_integer(A) ->
    is_stacktrace(Fs);
is_stacktrace([{M,F,As}|Fs]) when is_atom(M), is_atom(F), length(As) >= 0 ->
    is_stacktrace(Fs);
is_stacktrace(_) ->
    false.

%% ERTS exit codes (some of them are also returned by erl_eval):
explain_reason(badarg, error, [], _PF, _Str) ->
    <<"bad argument">>;
explain_reason({badarg,V}, error=Cl, [], PF, Str) -> % orelse, andalso
    format_value(V, <<"bad argument: ">>, Cl, PF, Str);
explain_reason(badarith, error, [], _PF, _Str) ->
    <<"bad argument in an arithmetic expression">>;
explain_reason({badarity,{Fun,As}}, error, [], _PF, _Str) 
                                      when is_function(Fun) ->
    %% Only the arity is displayed, not the arguments As.
    io_lib:fwrite(<<"~s called with ~s">>, 
                  [format_fun(Fun), argss(length(As))]);
explain_reason({badfun,Term}, error=Cl, [], PF, Str) ->
    format_value(Term, <<"bad function ">>, Cl, PF, Str);
explain_reason({badmatch,Term}, error=Cl, [], PF, Str) ->
    format_value(Term, <<"no match of right hand side value ">>, Cl, PF, Str);
explain_reason({case_clause,V}, error=Cl, [], PF, Str) ->
    %% "there is no case clause with a true guard sequence and a
    %% pattern matching..."
    format_value(V, <<"no case clause matching ">>, Cl, PF, Str);
explain_reason(function_clause, error, [{F,A}], _PF, _Str) ->
    %% Shell commands
    FAs = io_lib:fwrite(<<"~w/~w">>, [F, A]),
    [<<"no function clause matching call to ">> | FAs];
explain_reason(function_clause, error=Cl, [{M,F,As}], PF, Str) ->
    String = <<"no function clause matching ">>,
    format_errstr_call(String, Cl, {M,F}, As, PF, Str);
explain_reason(if_clause, error, [], _PF, _Str) ->
    <<"no true branch found when evaluating an if expression">>;
explain_reason(noproc, error, [], _PF, _Str) ->
    <<"no such process or port">>;
explain_reason(notalive, error, [], _PF, _Str) ->
    <<"the node cannot be part of a distributed system">>;
explain_reason(system_limit, error, [], _PF, _Str) ->
    <<"a system limit has been reached">>;
explain_reason(timeout_value, error, [], _PF, _Str) ->
    <<"bad receive timeout value">>;
explain_reason({try_clause,V}, error=Cl, [], PF, Str) ->
    %% "there is no try clause with a true guard sequence and a
    %% pattern matching..."
    format_value(V, <<"no try clause matching ">>, Cl, PF, Str);
explain_reason(undef, error, [{M,F,A}], _PF, _Str) ->
    %% Only the arity is displayed, not the arguments, if there are any.
    io_lib:fwrite(<<"undefined function ~s">>, 
                  [mfa_to_string(M, F, n_args(A))]);
explain_reason({shell_undef,F,A}, error, [], _PF, _Str) ->
    %% Give nicer reports for undefined shell functions
    %% (but not when the user actively calls shell_default:F(...)).
    io_lib:fwrite(<<"undefined shell command ~s/~w">>, [F, n_args(A)]);
%% Exit codes returned by erl_eval only:
explain_reason({argument_limit,_Fun}, error, [], _PF, _Str) ->
    io_lib:fwrite(<<"limit of number of arguments to interpreted function"
                    " exceeded">>, []);
explain_reason({bad_filter,V}, error=Cl, [], PF, Str) ->
    format_value(V, <<"bad filter ">>, Cl, PF, Str);
explain_reason({bad_generator,V}, error=Cl, [], PF, Str) ->
    format_value(V, <<"bad generator ">>, Cl, PF, Str);
explain_reason({unbound,V}, error, [], _PF, _Str) ->
    io_lib:fwrite(<<"variable ~w is unbound">>, [V]);
%% Exit codes local to the shell module (restricted shell):
explain_reason({restricted_shell_bad_return, V}, exit=Cl, [], PF, Str) ->
    String = <<"restricted shell module returned bad value ">>,
    format_value(V, String, Cl, PF, Str);
explain_reason({restricted_shell_disallowed,{ForMF,As}}, 
               exit=Cl, [], PF, Str) ->
    %% ForMF can be a fun, but not a shell fun.
    String = <<"restricted shell does not allow ">>,
    format_errstr_call(String, Cl, ForMF, As, PF, Str);
explain_reason(restricted_shell_started, exit, [], _PF, _Str) ->
    <<"restricted shell starts now">>;
explain_reason(restricted_shell_stopped, exit, [], _PF, _Str) ->
    <<"restricted shell stopped">>;
%% Other exit code:
explain_reason(Reason, Class, [], PF, Str) ->
    PF(Reason, (iolist_size(Str)+1) + exited_size(Class)).

n_spaces(N) ->
    lists:duplicate(N, $\s).

exited_size(Class) ->
    iolist_size(exited(Class)).

exited(error) ->
    <<"exception error: ">>;
exited(exit) ->
    <<"exception exit: ">>;
exited(throw) ->
    <<"exception throw: ">>.

format_stacktrace1(S0, Stack0, PF, SF) ->
    Stack1 = lists:dropwhile(fun({M,F,A}) -> SF(M, F, A)
                             end, lists:reverse(Stack0)),
    S = ["  " | S0],
    Stack = lists:reverse(Stack1),
    format_stacktrace2(S, Stack, 1, PF).

format_stacktrace2(S, [{M,F,A}|Fs], N, PF) when is_integer(A) ->
    [io_lib:fwrite(<<"~s~s ~s">>, 
                   [sep(N, S), origin(N, M, F, A), mfa_to_string(M, F, A)])
     | format_stacktrace2(S, Fs, N + 1, PF)];
format_stacktrace2(S, [{M,F,As}|Fs], N, PF) when is_list(As) ->
    A = length(As),
    CalledAs = [S,<<"   called as ">>],
    C = format_call("", CalledAs, {M,F}, As, PF),
    [io_lib:fwrite(<<"~s~s ~s\n~s~s">>,
                   [sep(N, S), origin(N, M, F, A), mfa_to_string(M, F, A),
                    CalledAs, C])
     | format_stacktrace2(S, Fs, N + 1, PF)];
format_stacktrace2(_S, [], _N, _PF) ->
    "".

argss(0) ->
    <<"no arguments">>;
argss(1) ->
    <<"one argument">>;
argss(2) ->
    <<"two arguments">>;
argss(I) ->
    io_lib:fwrite(<<"~w arguments">>, [I]).

format_value(V, ErrStr, Class, PF, Str) ->
    Pre1Sz = exited_size(Class),
    Str1 = PF(V, Pre1Sz + iolist_size([Str, ErrStr])+1),
    [ErrStr | case count_nl(Str1) of
                  N1 when N1 > 1 ->
                      Str2 = PF(V, iolist_size(Str) + 1 + Pre1Sz),
                      case count_nl(Str2) < N1 of
                          true ->
                              [$\n, Str, n_spaces(Pre1Sz) | Str2];
                          false ->
                              Str1
                      end;
                  _ ->
                      Str1
              end].

format_fun(Fun) when is_function(Fun) ->
    {module, M} = erlang:fun_info(Fun, module),
    {name, F} = erlang:fun_info(Fun, name),
    {arity, A} = erlang:fun_info(Fun, arity),
    case erlang:fun_info(Fun, type) of
        {type, local} when F =:= "" ->
            io_lib:fwrite(<<"~w">>, [Fun]);
        {type, local} when M =:= erl_eval ->
            io_lib:fwrite(<<"interpreted function with arity ~w">>, [A]);
        {type, local} ->
            mfa_to_string(M, F, A);
        {type, external} ->
            mfa_to_string(M, F, A)
    end.

format_errstr_call(ErrStr, Class, ForMForFun, As, PF, Pre0) ->
    Pre1 = [Pre0 | n_spaces(exited_size(Class))],
    format_call(ErrStr, Pre1, ForMForFun, As, PF).

format_call(ErrStr, Pre1, ForMForFun, As, PF) ->
    Arity = length(As),
    [ErrStr |
     case is_op(ForMForFun, Arity) of
         {yes,Op} -> 
             format_op(ErrStr, Pre1, Op, As, PF);
         no ->
             MFs = mf_to_string(ForMForFun, Arity),
             I1 = iolist_size([Pre1,ErrStr|MFs]),
             S1 = pp_arguments(PF, As, I1),
             S2 = pp_arguments(PF, As, iolist_size([Pre1|MFs])),
             Long = count_nl(pp_arguments(PF, [a2345,b2345], I1)) > 0,
             case Long or (count_nl(S2) < count_nl(S1)) of
                 true ->
                     [$\n, Pre1, MFs, S2];
                 false ->
                     [MFs, S1]
             end
    end].

mfa_to_string(M, F, A) ->
    io_lib:fwrite(<<"~s/~w">>, [mf_to_string({M, F}, A), A]).

mf_to_string({M, F}, A) ->
    case erl_internal:bif(M, F, A) of
        true ->
            io_lib:fwrite(<<"~w">>, [F]);
        false ->
            case is_op({M, F}, A) of
                {yes, '/'} ->
                    io_lib:fwrite(<<"~w">>, [F]);
                {yes, F} ->
                    atom_to_list(F);
                no ->
                    io_lib:fwrite(<<"~w:~w">>, [M, F])
            end
    end;
mf_to_string(Fun, _A) when is_function(Fun) ->
    format_fun(Fun);
mf_to_string(F, _A) ->
    io_lib:fwrite(<<"~w">>, [F]).

n_args(A) when is_integer(A) ->
    A;
n_args(As) when is_list(As) ->
    length(As).

origin(1, M, F, A) ->
    case is_op({M, F}, n_args(A)) of
        {yes, F} -> <<"in operator ">>;
        no -> <<"in function ">>
    end;
origin(_N, _M, _F, _A) ->
    <<"in call from">>.

sep(1, S) -> S;
sep(_, S) -> [$\n | S].

count_nl([E | Es]) ->
    count_nl(E) + count_nl(Es);
count_nl($\n) ->
    1;
count_nl(Bin) when is_binary(Bin) ->
    count_nl(binary_to_list(Bin));
count_nl(_) ->
    0.

is_op(ForMForFun, A) ->
    try 
        {erlang,F} = ForMForFun,
        _ = erl_internal:op_type(F, A), 
        {yes,F}
    catch error:_ -> no
    end.

format_op(ErrStr, Pre, Op, [A1, A2], PF) ->
    I1 = iolist_size([ErrStr,Pre]),
    S1 = PF(A1, I1+1),
    S2 = PF(A2, I1+1),
    OpS = atom_to_list(Op),
    Pre1 = [$\n | n_spaces(I1)],
    case count_nl(S1) > 0 of
        true -> 
            [S1,Pre1,OpS,Pre1|S2];
        false ->
            OpS2 = io_lib:fwrite(<<" ~s ">>, [Op]),
            S2_2 = PF(A2, iolist_size([ErrStr,Pre,S1|OpS2])+1),
            case count_nl(S2) < count_nl(S2_2) of
                true ->
                    [S1,Pre1,OpS,Pre1|S2];
                false ->
                    [S1,OpS2|S2_2]
            end
    end.

pp_arguments(PF, As, I) ->
    case {As, io_lib:printable_list(As)} of
        {[Int | T], true} ->
            L = integer_to_list(Int),
            Ll = length(L),
            A = list_to_atom(lists:duplicate(Ll, $a)),
            S0 = binary_to_list(iolist_to_binary(PF([A | T], I+1))),
            brackets_to_parens([$[,L,string:sub_string(S0, 2+Ll)]);
        _ -> 
            brackets_to_parens(PF(As, I+1))
    end.

brackets_to_parens(S) ->
    B = iolist_to_binary(S),
    Sz = byte_size(B) - 2,
    <<$[,R:Sz/binary,$]>> = B,
    [$(,R,$)].

