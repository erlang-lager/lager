-module(lager_logger_formatter).

%% convert logger formatter calls into lager formatter ones

-export([report_cb/1, format/2]).%, check_config/1]).

report_cb(#{label := {gen_server, terminate}, name := Name, reason := Reason}) ->
    {_Md, Formatted} = error_logger_lager_h:format_reason_md(Reason),
    {"gen_server ~w terminated with reason: ~s", [Name, Formatted]};
report_cb(#{label := {gen_fsm, terminate}, name := Name, state_name := StateName, reason := Reason}) ->
    {_Md, Formatted} = error_logger_lager_h:format_reason_md(Reason),
    {"gen_fsm ~w in state ~w terminated with reason: ~s", [Name, StateName, Formatted]};
report_cb(#{label := {gen_event, terminate}, name := Name, handler := Handler, reason := Reason}) ->
    {_Md, Formatted} = error_logger_lager_h:format_reason_md(Reason),
    {"gen_event ~w installed in ~w terminated with reason: ~s", [Handler, Name, Formatted]};
report_cb(#{label := {gen_statem, terminate}, name := Name, reason := Reason}) ->
    {_Md, Formatted} = error_logger_lager_h:format_reason_md(Reason),
    %% XXX I can't find the FSM statename in the error report, maybe it should be added
    {"gen_statem ~w terminated with reason: ~s", [Name, Formatted]};
report_cb(#{msg := {report, #{label := {Behaviour, no_handle_info}, mod := Mod, msg := Msg}}}) ->
    {"undefined handle_info for ~p in ~s ~p", [Msg, Behaviour, Mod]};
report_cb(#{label := {supervisor, progress}, report := Report}) ->
    case application:get_env(lager, suppress_supervisor_start_stop, false) of
        true ->
            {"", []};
        false ->
            {supervisor, Name} = lists:keyfind(supervisor, 1, Report),
            {started, Started} = lists:keyfind(started, 1, Report),
            case lists:keyfind(id, 1, Started) of
                false ->
                    %% supervisor itself starting
                    {mfa, {Module, Function, Args}} = lists:keyfind(mfa, 1, Started),
                    {pid, Pid} = lists:keyfind(pid, 1, Started),
                    {"Supervisor ~w started as ~p at pid ~w", [Name, error_logger_lager_h:format_mfa({Module, Function, Args}), Pid]};
                {id, ChildID} ->
                    case lists:keyfind(pid, 1, Started) of
                        {pid, Pid} ->
                            {"Supervisor ~w started child ~p at pid ~w", [Name, ChildID, Pid]};
                        false ->
                            %% children is a list of pids for some reason? and we only get the count
                            {nb_children, ChildCount} = lists:keyfind(nb_children, 1, Started),
                            {"Supervisor ~w started ~b children ~p", [Name, ChildCount, ChildID]}
                    end
            end
    end;
report_cb(#{label := {supervisor, _Error}, report := Report}) ->
    {supervisor, Name} = lists:keyfind(supervisor, 1, Report),
    {reason, Reason} = lists:keyfind(reason, 1, Report),
    {_Md, Formatted} = error_logger_lager_h:format_reason_md(Reason),
    {errorContext, ErrorContext} = lists:keyfind(errorContext, 1, Report),
    {offender, Offender} = lists:keyfind(offender, 1, Report),
    case lists:keyfind(mod, 1, Offender) of
        {mod, _Mod} ->
            {pid, Pid} = lists:keyfind(pid, 1, Offender),
            %% this comes from supervisor_bridge
            {"Supervisor ~w had ~p ~p with reason ~s", [Name, Pid, ErrorContext, Formatted]};
        false ->
            {id, ChildID} = lists:keyfind(id, 1, Offender),
            case lists:keyfind(pid, 1, Offender) of
                {pid, Pid} ->
                    {"Supervisor ~w had ~p ~p ~p with reason ~s", [Name, ChildID, Pid, ErrorContext, Formatted]};
                false ->
                    {"Supervisor ~w had ~p ~p with reason ~s", [Name, ChildID, ErrorContext, Formatted]}
            end
    end;
report_cb(#{label := {application_controller, progress}, report := Report}) ->
    case application:get_env(lager, suppress_application_start_stop, false) of
        true -> {"", []};
        false ->
            {application, Name} = lists:keyfind(application, 1, Report),
            {started_at, Node} = lists:keyfind(started_at, 1, Report),
            {"Application ~w started on node ~w", [Name, Node]}
    end;
report_cb(#{label := {application_controller, exit}, report := Report}) ->
    {exited, Reason} = lists:keyfind(exited, 1, Report),
    case application:get_env(lager, suppress_application_start_stop) of
        {ok, true} when Reason == stopped ->
            {"", []};
        _ ->
            {application, Name} = lists:keyfind(application, 1, Report),
            {_Md, Formatted} = error_logger_lager_h:format_reason_md(Reason),
            {"Application ~w exited with reason: ~s", [Name, Formatted]}
    end.
%% TODO handle proc_lib crash

format(#{msg := {report, _Report}, meta := Metadata} = Event, #{report_cb := Fun} = Config) when is_function(Fun, 1); is_function(Fun, 2) ->
    format(Event#{meta => Metadata#{report_cb => Fun}}, maps:remove(report_cb, Config));
format(#{level := _Level, msg := {report, Report}, meta := #{report_cb := Fun}} = Event, Config) when is_function(Fun, 1) ->
    case Fun(Report) of
        {Format, Args} when is_list(Format), is_list(Args) ->
            format(Event#{msg => {Format, Args}}, Config)
    end;
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
    {Colors, End} = case maps:get(colors, Config, false) of
        true ->
                            {application:get_env(lager, colors, []), "\e[0m"};
                        false ->
                            {[], ""}
                    end,
    [FormatModule:format(lager_msg:new(Msg, {MegaSecs, Secs, MicroSecs}, Level, convert_metadata(Metadata), []), maps:get(formatter_config, Config, []), Colors), End].

convert_metadata(Metadata) ->
    maps:fold(fun(mfa, {Module, Function, Arity}, Acc) ->
                      [{module, Module}, {function, Function}, {arity, Arity}|Acc];
                 (K, V, Acc) ->
                      [{K, V}|Acc]
              end, [], Metadata).
