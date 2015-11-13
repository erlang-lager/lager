%% Copyright (c) 2011-2012 Basho Technologies, Inc.  All Rights Reserved.
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

-module(lager_default_formatter).

%%
%% Include files
%%
-include("lager.hrl").
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%%
%% Exported Functions
%%
-export([format/2, format/3]).

%%
%% API Functions
%%

%% @doc Provides a generic, default formatting for log messages using a semi-iolist as configuration.  Any iolist allowed
%% elements in the configuration are printed verbatim.  Atoms in the configuration are treated as metadata properties
%% and extracted from the log message.  Optionally, a tuple of {atom(),semi-iolist()} can be used.  The atom will look
%% up the property, but if not found it will use the semi-iolist() instead.  These fallbacks can be similarly nested
%% or refer to other properties, if desired. You can also use a {atom, semi-iolist(), semi-iolist()} formatter, which
%% acts like a ternary operator's true/false branches.
%%
%% The metadata properties date,time, message, severity, and sev will always exist.  
%% The properties pid, file, line, module, and function will always exist if the parser transform is used.
%%
%% Example:
%%
%%    `["Foo"]' -> "Foo", regardless of message content.
%%
%%    `[message]' -> The content of the logged message, alone.
%%
%%    `[{pid,"Unknown Pid"}]' -> "?.?.?" if pid is in the metadata, "Unknown Pid" if not.
%%
%%    `[{pid, ["My pid is ", pid], ["Unknown Pid"]}]' -> if pid is in the metada print "My pid is ?.?.?", otherwise print "Unknown Pid"
%% @end
-spec format(lager_msg:lager_msg(),list(),list()) -> any().
format(Msg,[], Colors) ->
    format(Msg, [{eol, "\n"}], Colors);
format(Msg,[{eol, EOL}], Colors) ->
    format(Msg,
        [date, " ", time, " ", color, "[", severity, "] ",
            {pid, ""},
            {module, [
                    {pid, ["@"], ""},
                    module,
                    {function, [":", function], ""},
                    {line, [":",line], ""}], ""},
            " ", message, EOL], Colors);
format(Message,Config,Colors) ->
    [ case V of
        color -> output_color(Message,Colors);
        _ -> output(V,Message) 
      end || V <- Config ].

-spec format(lager_msg:lager_msg(),list()) -> any().
format(Msg, Config) ->
    format(Msg, Config, []).

-spec output(term(),lager_msg:lager_msg()) -> iolist().
output(message,Msg) -> lager_msg:message(Msg);
output(date,Msg) ->
    {D, _T} = lager_msg:datetime(Msg),
    D;
output(time,Msg) ->
    {_D, T} = lager_msg:datetime(Msg),
    T;
output(severity,Msg) ->
    atom_to_list(lager_msg:severity(Msg));
output(blank,_Msg) ->
    output({blank," "},_Msg);
output({blank,Fill},_Msg) ->
    Fill;
output(sev,Msg) ->
    %% Write brief acronym for the severity level (e.g. debug -> $D)
    [lager_util:level_to_chr(lager_msg:severity(Msg))];
output(metadata, Msg) ->
    output({metadata, "=", " "}, Msg);
output({metadata, IntSep, FieldSep}, Msg) ->
    MD = lists:keysort(1, lager_msg:metadata(Msg)),
    string:join([io_lib:format("~s~s~p", [K, IntSep, V]) || {K, V} <- MD], FieldSep);
output(Prop,Msg) when is_atom(Prop) ->
    Metadata = lager_msg:metadata(Msg),
    make_printable(get_metadata(Prop,Metadata,<<"Undefined">>));
output({Prop,Default},Msg) when is_atom(Prop) ->
    Metadata = lager_msg:metadata(Msg),
    make_printable(get_metadata(Prop,Metadata,output(Default,Msg)));
output({Prop, Present, Absent}, Msg) when is_atom(Prop) ->
    %% sort of like a poor man's ternary operator
    Metadata = lager_msg:metadata(Msg),
    case get_metadata(Prop, Metadata) of
        undefined ->
            [ output(V, Msg) || V <- Absent];
        _ ->
            [ output(V, Msg) || V <- Present]
    end;
output({Prop, Present, Absent, Width}, Msg) when is_atom(Prop) ->
    %% sort of like a poor man's ternary operator
    Metadata = lager_msg:metadata(Msg),
    case get_metadata(Prop, Metadata) of
        undefined ->
            [ output(V, Msg, Width) || V <- Absent];
        _ ->
            [ output(V, Msg, Width) || V <- Present]
    end;
output(Other,_) -> make_printable(Other).

output(message, Msg, _Width) -> lager_msg:message(Msg);
output(date,Msg, _Width) ->
    {D, _T} = lager_msg:datetime(Msg),
    D;
output(time, Msg, _Width) ->
    {_D, T} = lager_msg:datetime(Msg),
    T;
output(severity, Msg, Width) ->
    make_printable(atom_to_list(lager_msg:severity(Msg)), Width);
output(sev,Msg, _Width) ->
    %% Write brief acronym for the severity level (e.g. debug -> $D)
    [lager_util:level_to_chr(lager_msg:severity(Msg))];
output(blank,_Msg, _Width) ->
    output({blank, " "},_Msg, _Width);
output({blank, Fill},_Msg, _Width) ->
    Fill;
output(metadata, Msg, _Width) ->
    output({metadata, "=", " "}, Msg, _Width);
output({metadata, IntSep, FieldSep}, Msg, _Width) ->
    MD = lists:keysort(1, lager_msg:metadata(Msg)),
    [string:join([io_lib:format("~s~s~p", [K, IntSep, V]) || {K, V} <- MD], FieldSep)];

output(Prop, Msg, Width) when is_atom(Prop) ->
    Metadata = lager_msg:metadata(Msg),
    make_printable(get_metadata(Prop,Metadata,<<"Undefined">>), Width);
output({Prop,Default},Msg, Width) when is_atom(Prop) ->
    Metadata = lager_msg:metadata(Msg),
    make_printable(get_metadata(Prop,Metadata,output(Default,Msg)), Width);
output(Other,_, Width) -> make_printable(Other, Width).

output_color(_Msg,[]) -> [];
output_color(Msg,Colors) ->
    Level = lager_msg:severity(Msg),
    case lists:keyfind(Level, 1, Colors) of
        {_, Color} -> Color;
        _ -> []
    end.

-spec make_printable(any()) -> iolist().
make_printable(A) when is_atom(A) -> atom_to_list(A);
make_printable(P) when is_pid(P) -> pid_to_list(P);
make_printable(L) when is_list(L) orelse is_binary(L) -> L; 
make_printable(Other) -> io_lib:format("~p",[Other]).

make_printable(A,W) when is_integer(W)-> string:left(make_printable(A),W);
make_printable(A,{Align,W}) when is_integer(W) ->
    case Align of
        left ->
            string:left(make_printable(A),W);
        centre ->
            string:centre(make_printable(A),W);
        right ->
            string:right(make_printable(A),W);
        _ ->
            string:left(make_printable(A),W)
    end;

make_printable(A,_W) -> make_printable(A).

get_metadata(Key, Metadata) ->
    get_metadata(Key, Metadata, undefined).

get_metadata(Key, Metadata, Default) ->
    case lists:keyfind(Key, 1, Metadata) of
        false ->
            Default;
        {Key, Value} ->
            Value
    end.

-ifdef(TEST).
date_time_now() ->
    Now = os:timestamp(),
    {Date, Time} = lager_util:format_time(lager_util:maybe_utc(lager_util:localtime_ms(Now))),
    {Date, Time, Now}.

basic_test_() ->
    {Date, Time, Now} = date_time_now(),
    [{"Default formatting test",
            ?_assertEqual(iolist_to_binary([Date, " ", Time,  " [error] ", pid_to_list(self()), " Message\n"]),
                iolist_to_binary(format(lager_msg:new("Message",
                            Now,
                            error,
                            [{pid, self()}],
                            []),
                        [])))
        },
        {"Basic Formatting",
            ?_assertEqual(<<"Simplist Format">>,
                iolist_to_binary(format(lager_msg:new("Message",
                            Now,
                            error,
                            [{pid, self()}],
                            []),
                        ["Simplist Format"])))
        },
        {"Default equivalent formatting test",
            ?_assertEqual(iolist_to_binary([Date, " ", Time, " [error] ", pid_to_list(self()), " Message\n"]),
                iolist_to_binary(format(lager_msg:new("Message",
                            Now,
                            error,
                            [{pid, self()}],
                            []),
                        [date, " ", time," [",severity,"] ",pid, " ", message, "\n"]
                    )))
        },
        {"Non existent metadata can default to string",
            ?_assertEqual(iolist_to_binary([Date, " ", Time, " [error] Fallback Message\n"]),
                iolist_to_binary(format(lager_msg:new("Message",
                            Now,
                            error,
                            [{pid, self()}],
                            []),
                        [date, " ", time," [",severity,"] ",{does_not_exist,"Fallback"}, " ", message, "\n"]
                    )))
        },
        {"Non existent metadata can default to other metadata",
            ?_assertEqual(iolist_to_binary([Date, " ", Time, " [error] Fallback Message\n"]),
                iolist_to_binary(format(lager_msg:new("Message",
                            Now,
                            error,
                            [{pid, "Fallback"}],
                            []),
                        [date, " ", time," [",severity,"] ",{does_not_exist,pid}, " ", message, "\n"]
                    )))
        },
        {"Non existent metadata can default to a string2",
            ?_assertEqual(iolist_to_binary(["Unknown Pid"]),
                iolist_to_binary(format(lager_msg:new("Message",
                            Now,
                            error,
                            [],
                            []),
                        [{pid, ["My pid is ", pid], ["Unknown Pid"]}]
                    )))
        },
        {"Metadata can have extra formatting",
            ?_assertEqual(iolist_to_binary(["My pid is hello"]),
                iolist_to_binary(format(lager_msg:new("Message",
                            Now,
                            error,
                            [{pid, hello}],
                            []),
                        [{pid, ["My pid is ", pid], ["Unknown Pid"]}]
                    )))
        },
        {"Metadata can have extra formatting1",
            ?_assertEqual(iolist_to_binary(["servername"]),
                iolist_to_binary(format(lager_msg:new("Message",
                            Now,
                            error,
                            [{pid, hello}, {server, servername}],
                            []),
                        [{server,{pid, ["(", pid, ")"], ["(Unknown Server)"]}}]
                    )))
        },
        {"Metadata can have extra formatting2",
            ?_assertEqual(iolist_to_binary(["(hello)"]),
                iolist_to_binary(format(lager_msg:new("Message",
                            Now,
                            error,
                            [{pid, hello}],
                            []),
                        [{server,{pid, ["(", pid, ")"], ["(Unknown Server)"]}}]
                    )))
        },
        {"Metadata can have extra formatting3",
            ?_assertEqual(iolist_to_binary(["(Unknown Server)"]),
                iolist_to_binary(format(lager_msg:new("Message",
                            Now,
                            error,
                            [],
                            []),
                        [{server,{pid, ["(", pid, ")"], ["(Unknown Server)"]}}]
                    )))
        },
        {"Metadata can be printed in its enterity",
            ?_assertEqual(iolist_to_binary(["bar=2 baz=3 foo=1"]),
                iolist_to_binary(format(lager_msg:new("Message",
                            Now,
                            error,
                            [{foo, 1}, {bar, 2}, {baz, 3}],
                            []),
                        [metadata]
                    )))
        },
        {"Metadata can be printed in its enterity with custom seperators",
            ?_assertEqual(iolist_to_binary(["bar->2, baz->3, foo->1"]),
                iolist_to_binary(format(lager_msg:new("Message",
                            Now,
                            error,
                            [{foo, 1}, {bar, 2}, {baz, 3}],
                            []),
                        [{metadata, "->", ", "}]
                    )))
        },
        {"Metadata can have extra formatting with width 1",
            ?_assertEqual(iolist_to_binary(["(hello     )(hello     )(hello)(hello)(hello)"]),
                iolist_to_binary(format(lager_msg:new("Message",
                    Now,
                    error,
                    [{pid, hello}],
                    []),
                    ["(",{pid, [pid], "", 10},")",
                        "(",{pid, [pid], "", {bad_align,10}},")",
                        "(",{pid, [pid], "", bad10},")",
                        "(",{pid, [pid], "", {right,bad20}},")",
                        "(",{pid, [pid], "", {bad_align,bad20}},")"]
                )))
        },
        {"Metadata can have extra formatting with width 2",
            ?_assertEqual(iolist_to_binary(["(hello     )"]),
                iolist_to_binary(format(lager_msg:new("Message",
                    Now,
                    error,
                    [{pid, hello}],
                    []),
                    ["(",{pid, [pid], "", {left,10}},")"]
                )))
        },
        {"Metadata can have extra formatting with width 3",
            ?_assertEqual(iolist_to_binary(["(     hello)"]),
                iolist_to_binary(format(lager_msg:new("Message",
                    Now,
                    error,
                    [{pid, hello}],
                    []),
                    ["(",{pid, [pid], "", {right,10}},")"]
                )))
        },
        {"Metadata can have extra formatting with width 4",
            ?_assertEqual(iolist_to_binary(["(  hello   )"]),
                iolist_to_binary(format(lager_msg:new("Message",
                    Now,
                    error,
                    [{pid, hello}],
                    []),
                    ["(",{pid, [pid], "", {centre,10}},")"]
                )))
        },
        {"Metadata can have extra formatting with width 5",
            ?_assertEqual(iolist_to_binary(["error     |hello     ! (  hello   )"]),
                iolist_to_binary(format(lager_msg:new("Message",
                    Now,
                    error,
                    [{pid, hello}],
                    []),
                    [{x,"",[severity,{blank,"|"},pid], 10},"!",blank,"(",{pid, [pid], "", {centre,10}},")"]
                )))
        },
        {"Metadata can have extra formatting with width 6",
            ?_assertEqual(iolist_to_binary([Time,Date," bar=2 baz=3 foo=1 pid=hello EMessage"]),
                iolist_to_binary(format(lager_msg:new("Message",
                    Now,
                    error,
                    [{pid, hello},{foo, 1}, {bar, 2}, {baz, 3}],
                    []),
                    [{x,"",[time]}, {x,"",[date],20},blank,{x,"",[metadata],30},blank,{x,"",[sev],10},message, {message,message,"", {right,20}}]
                )))
        }




    ].

-endif.
