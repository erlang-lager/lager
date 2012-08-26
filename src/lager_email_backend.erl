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
          username :: string(),
          password :: string(),
          level :: integer(),
          host  :: string(),
          count :: integer(),
          emails_per_min :: integer(),
          last_sent_at
         }).

init([LogLevel, From, To, Username, Passwd, Host, EmailsPerMin]) ->
    case lists:member(LogLevel, ?LEVELS) of
        true ->
            {ok, #state{
                    level = lager_util:level_to_num(LogLevel),
                    from = From,
                    to = To,
                    username = Username,
                    password = Passwd,
                    host = Host,
                    emails_per_min = EmailsPerMin,
                    count = 0,
                    last_sent_at = 0
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
handle_event({log, Level, DateTime, Log},
  #state{level = LogLevel, emails_per_min = EmailsPerMin} = State)
  when EmailsPerMin =:= 0, Level =< LogLevel -> 
    send_email(DateTime, Log, State),
    {ok, State};

handle_event({log, Level, DateTime, Log},
  #state{level = LogLevel, last_sent_at = LastSentAt,
         count = Count, emails_per_min = EmailsPerMin} = State)
  when Level =< LogLevel ->
    Now = timestamp(),
    State2 = case Now - LastSentAt > 60 of
        true ->
            send_email(DateTime, Log, State),
            State#state{last_sent_at = Now, count = 1};
        false ->
            case Count < EmailsPerMin of
                true ->
                    send_email(DateTime, Log, State),
                    State#state{count = Count + 1};
                false ->
                    State
            end
        end,
    {ok, State2};

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

%% @private
timestamp() ->
    calendar:datetime_to_gregorian_seconds(
      calendar:now_to_universal_time(now())).

%% @private
send_email({Date, Time}, [LevelStr, Location, Message],
    #state{from = From, to = To, host = Host, username = Username, 
        password = Password}) ->
    Hostname = net_adm:localhost(),
    Subject = [LevelStr, " on ", Hostname],
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
         {no_mx_lookups, true}]).
