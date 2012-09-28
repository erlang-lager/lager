-module(lager_msg).

-export([new/5]).
-export([message/1]).
-export([timestamp/1]).
-export([severity/1]).
-export([severity_as_int/1]).
-export([metadata/1]).
-export([destinations/1]).

-record(lager_msg,{
        destinations :: list(),
        metadata :: [tuple()],
        severity :: lager:log_level(),
        timestamp :: {string(), string()},
        message :: list()
    }).

-opaque lager_msg() :: #lager_msg{}.
-export_type([lager_msg/0]).

-spec new(list(), {string(), string()}, atom(), [tuple()], list()) -> lager_msg().
new(Msg, Timestamp, Severity, Metadata, Destinations) ->
    #lager_msg{message=Msg, timestamp=Timestamp, severity=Severity,
        metadata=Metadata, destinations=Destinations}.

-spec message(lager_msg()) -> list().
message(Msg) ->
    Msg#lager_msg.message.

-spec timestamp(lager_msg()) -> {string(), string()}.
timestamp(Msg) ->
    Msg#lager_msg.timestamp.

-spec severity(lager_msg()) -> lager:log_level().
severity(Msg) ->
    Msg#lager_msg.severity.

-spec severity_as_int(lager_msg()) -> lager:log_level_number().
severity_as_int(Msg) ->
    lager_util:level_to_num(Msg#lager_msg.severity).

-spec metadata(lager_msg()) -> [tuple()].
metadata(Msg) ->
    Msg#lager_msg.metadata.

-spec destinations(lager_msg()) -> list().
destinations(Msg) ->
    Msg#lager_msg.destinations.


