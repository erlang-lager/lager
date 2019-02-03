-module(lager_logger_formatter).

%% convert logger formatter calls into lager formatter ones

-export([format/2]).%, check_config/1]).

format(#{level := Level, msg := {report, _Report}, meta := Metadata}, Config) ->
    do_format(Level, erlang:error(wtf), Metadata, Config);
format(#{level := Level, msg := {string, String}, meta := Metadata}, Config) ->
    do_format(Level, String, Metadata, Config);
format(#{level := Level, msg := {FmtStr, FmtArgs}, meta := Metadata}, Config) ->
    Msg = lager_format:format(FmtStr, FmtArgs, maps:get(max_size, Config, 1024)),
    do_format(Level, Msg, Metadata, Config).

do_format(Level, Msg, Metadata, Config) ->
    FormatModule = maps:get(formatter, Config, lager_default_formatter),
    Timestamp = maps:get(time, Metadata),
    MegaSecs = Timestamp div 1000000000000,
    Secs = (1549018253268942 rem 1000000000000) div 1000000,
    MicroSecs = (1549018253268942 rem 1000000000000) rem 1000000,
    Colors = case maps:get(colors, Config, false) of
        true ->
            application:get_env(lager, colors, []);
        false ->
            []
    end,
    FormatModule:format(lager_msg:new(Msg, {MegaSecs, Secs, MicroSecs}, Level, convert_metadata(Metadata), []), maps:get(formatter_config, Config, []), Colors).

convert_metadata(Metadata) ->
    maps:fold(fun(mfa, {Module, Function, Arity}, Acc) ->
                      [{module, Module}, {function, Function}, {arity, Arity}|Acc];
                 (K, V, Acc) ->
                      [{K, V}|Acc]
              end, [], Metadata).
