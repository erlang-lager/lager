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

-export([string_p/1, maybe_utc/1]).

string_p([]) ->
    false;
string_p(Term) ->
    string_p1(Term).

string_p1([H|T]) when is_integer(H), H >= $\s, H < 255 ->
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

-spec maybe_utc(t_datetime1970()) -> {utc, t_datetime1970()} | t_datetime1970().
maybe_utc(Time) ->
    UTC = case application:get_env(sasl, utc_log) of
        {ok, Val} ->
            Val;
        undefined ->
            %% Backwards compatible:
            case application:get_env(stdlib, utc_log) of
                {ok, Val} ->
                    Val;
                undefined ->
                    false
            end
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


