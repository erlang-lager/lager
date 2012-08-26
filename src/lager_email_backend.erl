-module(lager_email_backend).

-behaviour(gen_event).

-include("lager.hrl").


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-compile([{parse_transform, lager_transform}]).
-endif.

-export([init/1, handle_call/2, handle_event/2, handle_info/2, terminate/2,
        code_change/3]).

-record(state,{
          from :: string(),
          to :: string(),
          subject :: string(),
          username :: string(),
          password :: string(),
          level :: integer(),
          host  :: string(),
          port  :: integer(),
          counter :: integer()
         }).

% Config is a prop list
init([LogLevel, From, To, Username, Passwd, Host]) ->
    case lists:member(LogLevel, ?LEVELS) of
        true ->
            {ok, #state{
                    level = lager_util:level_to_num(LogLevel),
                    from = From,
                    to = To,
                    username = Username,
                    password = Passwd,
                    host = Host,
                    counter = 0
                   }};
        _ ->
            {error, bad_log_level}
    end.

%% @private
handle_call(get_loglevel, #state{level=LogLevel} = State) ->
    {ok, LogLevel, State};
handle_call({set_loglevel, LogLevel}, State) ->
    case lists:member(LogLevel, ?LEVELS) of
        true ->
            {ok, ok, State#state{level=lager_util:level_to_num(LogLevel)}};
        _ ->
            {ok, {error, bad_log_level}, State}
    end;
handle_call(_Request, State) ->
    {ok, ok, State}.

%% @private
handle_event({log, Level, {Date, Time}, [LevelStr, Location, Message]},
    #state{level=LogLevel, from = From, to = To, host = Host,
      username = Username, password = Password} = State) 
  when Level =< LogLevel ->

    Hostname = net_adm:localhost(),
    Subject = [atom_to_list(?NUM2LEVEL(LogLevel)), " on ", Hostname],
    Headers = [
        header("from: ", From),
        header("to: ", format_to(To)),
        header("subject: ", Subject),
        header("Content-Type: ", "text/plain; charset=utf-8"),
        header("Content-Transfer-Encoding: ", "7bit"),
        header("Content-Disposition: ", "inline"),
        "\r\n"
    ],
    EmailBody = [Date, " ", Time, " ", LevelStr, Location, Message],
    gen_smtp_client:send({From, To, [Headers, EmailBody]},
        [{relay, Host},
         {username, Username},
         {password, Password},
         {no_mx_lookups, true}]),
    {ok, State};
handle_event(_Event, State) ->
    {ok, State}.

%% @private
handle_info(_Info, State) ->
    {ok, State}.

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% @private
header(Key, Value) ->
    [Key, Value, "\r\n"].

%% @private
format_to([]) ->
    "";
format_to([H|T]) ->
    format_to2(T, [H]).

%% @private
format_to2([H|T], Acc) ->
    format_to2(T, [[H, ","] | Acc]);
format_to2([], Acc) ->
    Acc.
