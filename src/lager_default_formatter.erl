%% Copyright (c) 2011 Basho Technologies, Inc.  All Rights Reserved.
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
-include_lib("lager/include/lager.hrl").
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%%
%% Exported Functions
%%
-export([format/2]).

%%
%% API Functions
%%

%% @doc Provides a generic, default formatting for log messages using a semi-iolist as configuration.  Any iolist allowed
%% elements in the configuration are printed verbatim.  Atoms in the configuration are treated as metadata properties
%% and extracted from the log message.  Optionally, a tuple of {atom(),semi-iolist()} can be used.  The atom will look
%% up the property, but if not found it will use the semi-iolist() instead.  These fallbacks can be similarly nested
%% or refer to other properties, if desired.
%%
%% The metadata properties date,time, message, and severity will always exist.  
%% The properties pid, file, line, module, and function will always exist if the parser transform is used.
%%
%% Example:
%%    ["Foo"] -> "Foo", regardless of message content.
%%    [message] -> The content of the logged message, alone.
%%    [{pid,"Unknown Pid"}] -> "<?.?.?>" if pid is in the metadata, "Unknown Pid" if not.
%%    [date, " ", time," [",severity,"] ",pid, " ", message, "\n"] -> default formatting if none is provided
%% @end
-spec format(#lager_log_message{},list()) -> any().
format(#lager_log_message{}=Msg,[]) ->
    format(Msg, [{eol, "\n"}]);
format(#lager_log_message{}=Msg,[{eol, EOL}]) ->
    format(Msg,
        [date, " ", time, " [", severity, "] ",
            {pid, ""},
            {module, [
                    {pid, ["@"], ""},
                    module,
                    {function, [":", function], ""},
                    {line, [":",line], ""}], ""},
            " ", message, EOL]);
format(Message,Config) ->
    [ output(V,Message) || V <- Config ].


-spec output(term(),#lager_log_message{}) -> iolist().
output(message,#lager_log_message{message=M}) -> M;
output(date,#lager_log_message{timestamp={D,_T}}) -> D;
output(time,#lager_log_message{timestamp={_D,T}}) -> T;
output(severity,#lager_log_message{severity_as_int=S}) ->
    atom_to_list(lager_util:num_to_level(S));
output(Prop,#lager_log_message{metadata=Metadata}) when is_atom(Prop) ->
    make_printable(get_metadata(Prop,Metadata,<<"Undefined">>));
output({Prop,Default},#lager_log_message{metadata=Metadata}=L) when is_atom(Prop) ->
    make_printable(get_metadata(Prop,Metadata,output(Default,L)));
output({Prop, Present, Absent}, #lager_log_message{metadata=Metadata}=L) when is_atom(Prop) ->
    %% sort of like a poor man's ternary operator
    case get_metadata(Prop, Metadata) of
        undefined ->
            [ output(V, L) || V <- Absent];
        _ ->
            [ output(V, L) || V <- Present]
    end;
output(Other,_) -> make_printable(Other).

-spec make_printable(any()) -> iolist().
make_printable(A) when is_atom(A) -> atom_to_list(A);
make_printable(P) when is_pid(P) -> pid_to_list(P);
make_printable(L) when is_list(L) orelse is_binary(L) -> L; 
make_printable(Other) -> io_lib:format("~p",[Other]).

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
basic_test_() ->
    [{"Default formatting test",
            ?_assertEqual(iolist_to_binary([<<"Day Time [error] ">>, pid_to_list(self()), <<" Message\n">>]),
                iolist_to_binary(format(#lager_log_message{timestamp={"Day","Time"},
                            message="Message",
                            severity_as_int=lager_util:level_to_num(error),
                            metadata=[{pid,self()}]},
                        [])))
        },
        {"Basic Formatting",
            ?_assertEqual(<<"Simplist Format">>,
                iolist_to_binary(format(#lager_log_message{timestamp={"Day","Time"},
                            message="Message",
                            severity_as_int=lager_util:level_to_num(error),
                            metadata=[{pid,self()}]},
                        ["Simplist Format"])))
        },
        {"Default equivalent formatting test",
            ?_assertEqual(iolist_to_binary([<<"Day Time [error] ">>, pid_to_list(self()), <<" Message\n">>]),
                iolist_to_binary(format(#lager_log_message{timestamp={"Day","Time"},
                            message="Message",
                            severity_as_int=lager_util:level_to_num(error),
                            metadata=[{pid,self()}]},
                        [date, " ", time," [",severity,"] ",pid, " ", message, "\n"]
                    )))
        },
        {"Non existant metadata can default to string",
            ?_assertEqual(iolist_to_binary([<<"Day Time [error] Fallback Message\n">>]),
                iolist_to_binary(format(#lager_log_message{timestamp={"Day","Time"},
                            message="Message",
                            severity_as_int=lager_util:level_to_num(error),
                            metadata=[]},
                        [date, " ", time," [",severity,"] ",{does_not_exist,"Fallback"}, " ", message, "\n"]
                    )))
        },
        {"Non existant metadata can default to other metadata",
            ?_assertEqual(iolist_to_binary([<<"Day Time [error] Fallback Message\n">>]),
                iolist_to_binary(format(#lager_log_message{timestamp={"Day","Time"},
                            message="Message",
                            severity_as_int=lager_util:level_to_num(error),
                            metadata=[{pid,"Fallback"}]},
                        [date, " ", time," [",severity,"] ",{does_not_exist,pid}, " ", message, "\n"]
                    )))
        }
    ].

-endif.
