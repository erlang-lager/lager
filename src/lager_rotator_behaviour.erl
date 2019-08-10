-module(lager_rotator_behaviour).

%% Create a log file
-callback(create_logfile(Name::list(), Buffer::{integer(), integer()} | any()) ->
    {ok, {file:io_device(), integer(), file:date_time(), integer()}} | {error, any()}).

%% Open a log file
-callback(open_logfile(Name::list(), Buffer::{integer(), integer()} | any()) ->
    {ok, {file:io_device(), integer(), file:date_time(), integer()}} | {error, any()}).

%% Ensure reference to current target, could be rotated
-callback(ensure_logfile(Name::list(), FD::file:io_device(), Inode::integer(), Ctime::file:date_time(),
                         Buffer::{integer(), integer()} | any()) ->
    {ok, {file:io_device(), integer(), file:date_time(), integer()}} | {error, any()}).

%% Rotate the log file
-callback(rotate_logfile(Name::list(), Count::integer()) ->
    ok).
