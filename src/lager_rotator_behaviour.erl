-module(lager_rotator_behaviour).

%% @doc Create a log file
-callback(create_logfile(Name::list(), Buffer::{integer(), integer()} | any()) ->
    {ok, {file:io_device(), integer(), integer()}} | {error, any()}).

%% @doc Open a log file
-callback(open_logfile(Name::list(), Buffer::{integer(), integer()} | any()) ->
    {ok, {file:io_device(), integer(), integer()}} | {error, any()}).

%% @doc Ensure reference to current target, could be rotated
-callback(ensure_logfile(Name::list(), FD::file:io_device(), Inode::integer(),
                         Buffer::{integer(), integer()} | any()) ->
    {ok, {file:io_device(), integer(), integer()}} | {error, any()}).

%% @doc Rotate the log file
-callback(rotate_logfile(Name::list(), Count::integer()) ->
    ok).
