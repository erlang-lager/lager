Overview
--------
Lager (as in the beer) is a logging framework for Erlang. Its purpose is
to provide a more traditional way to perform logging in an erlang application
that plays nicely with traditional UNIX logging tools like logrotate and
syslog.

[Travis-CI](http://travis-ci.org/erlang-lager/lager) :: [![Build Status](https://travis-ci.org/erlang-lager/lager.svg?branch=master)]
[![Hex pm](https://img.shields.io/hexpm/v/lager)](https://hex.pm/packages/lager)

Features
--------
* Finer grained log levels (debug, info, notice, warning, error, critical,
  alert, emergency)
* Logger calls are transformed using a parse transform to allow capturing
  Module/Function/Line/Pid information
* When no handler is consuming a log level (eg. debug) no event is sent
  to the log handler
* Supports multiple backends, including console and file.
* Supports multiple sinks
* Rewrites common OTP error messages into more readable messages
* Support for pretty printing records encountered at compile time
* Tolerant in the face of large or many log messages, won't out of memory the node
* Optional feature to bypass log size truncation ("unsafe")
* Supports internal time and date based rotation, as well as external rotation tools
* Syslog style log level comparison flags
* Colored terminal output (requires R16+)
* Map support (requires 17+)
* Optional load shedding by setting a high water mark to kill (and reinstall)
  a sink after a configurable cool down timer

Contributing
------------
We welcome contributions from the community. We are always excited to get ideas
for improving lager.

If you are looking for an idea to help out, please take a look at our open
issues - a number of them are tagged with [Help Wanted](https://github.com/erlang-lager/lager/issues?q=is%3Aopen+is%3Aissue+label%3A%22Help+Wanted%22)
and [Easy](https://github.com/erlang-lager/lager/issues?q=is%3Aopen+is%3Aissue+label%3AEasy) - some
of them are tagged as both! We are happy to mentor people get started with any
of these issues, and they don't need prior discussion.

That being said, before you send large changes please open an issue first to
discuss the change you'd like to make along with an idea of your proposal to
implement that change.

### PR guidelines ###

* Large changes without prior discussion are likely to be rejected.
* Changes without test cases are likely to be rejected.
* Please use the style of the existing codebase when submitting PRs.

We review PRs and issues at least once a month as described below.

OTP Support Policy
------------------
The lager maintainers intend to support the past three OTP releases from
current on the main 3.x branch of the project. As of August 2019 that includes
22, 21 20

Lager may or may not run on older OTP releases but it will only be guaranteed
tested on the previous three OTP releases. If you need a version of lager
which runs on older OTP releases, we recommend you use either the 3.4.0 release
or the 2.x branch.

Monthly triage cadence
----------------------
We have (at least) monthly issue and PR triage for lager in the #lager room on the
[freenode](https://freenode.net) IRC network every third Thursday at 2 pm US/Pacific,
10 pm UTC. You are welcome to join us there to ask questions about lager or
participate in the triage.

Usage
-----
To use lager in your application, you need to define it as a rebar dep or have
some other way of including it in Erlang's path. You can then add the
following option to the erlang compiler flags:

```erlang
{parse_transform, lager_transform}
```

Alternately, you can add it to the module you wish to compile with logging
enabled:

```erlang
-compile([{parse_transform, lager_transform}]).
```

Before logging any messages, you'll need to start the lager application. The
lager module's `start` function takes care of loading and starting any dependencies
lager requires.

```erlang
lager:start().
```

You can also start lager on startup with a switch to `erl`:

```erlang
erl -pa path/to/lager/ebin -s lager
```

Once you have built your code with lager and started the lager application,
you can then generate log messages by doing the following:

```erlang
lager:error("Some message")
```

  Or:

```erlang
lager:warning("Some message with a term: ~p", [Term])
```

The general form is `lager:Severity()` where `Severity` is one of the log levels
mentioned above.

Configuration
-------------
To configure lager's backends, you use an application variable (probably in
your app.config):

```erlang
{lager, [
  {log_root, "/var/log/hello"},
  {handlers, [
    {lager_console_backend, [{level, info}]},
    {lager_file_backend, [{file, "error.log"}, {level, error}]},
    {lager_file_backend, [{file, "console.log"}, {level, info}]}
  ]}
]}.
```

```log_root``` variable is optional, by default file paths are relative to CWD.

The available configuration options for each backend are listed in their
module's documentation.

Sinks
-----
Lager has traditionally supported a single sink (implemented as a
`gen_event` manager) named `lager_event` to which all backends were
connected.

Lager now supports extra sinks; each sink can have different
sync/async message thresholds and different backends.

### Sink configuration

To use multiple sinks (beyond the built-in sink of lager and lager_event), you
need to:

1. Setup rebar.config
2. Configure the backends in app.config

#### Names

Each sink has two names: one atom to be used like a module name for
sending messages, and that atom with `_lager_event` appended for backend
configuration.

This reflects the legacy behavior: `lager:info` (or `critical`, or
`debug`, etc) is a way of sending a message to a sink named
`lager_event`. Now developers can invoke `audit:info` or
`myCompanyName:debug` so long as the corresponding `audit_lager_event` or
`myCompanyName_lager_event` sinks are configured.

#### rebar.config

In `rebar.config` for the project that requires lager, include a list
of sink names (without the `_lager_event` suffix) in `erl_opts`:

`{lager_extra_sinks, [audit]}`

#### Runtime requirements

To be useful, sinks must be configured at runtime with backends.

In `app.config` for the project that requires lager, for example,
extend the lager configuration to include an `extra_sinks` tuple with
backends (aka "handlers") and optionally `async_threshold` and
`async_threshold_window` values (see **Overload Protection**
below). If async values are not configured, no overload protection
will be applied on that sink.

```erlang
[{lager, [
          {log_root, "/tmp"},

          %% Default handlers for lager/lager_event
          {handlers, [
                      {lager_console_backend, [{level, info}]},
                      {lager_file_backend, [{file, "error.log"}, {level, error}]},
                      {lager_file_backend, [{file, "console.log"}, {level, info}]}
                     ]},

          %% Any other sinks
          {extra_sinks,
           [
            {audit_lager_event,
             [{handlers,
               [{lager_file_backend,
                 [{file, "sink1.log"},
                  {level, info}
                 ]
                }]
              },
              {async_threshold, 500},
              {async_threshold_window, 50}]
            }]
          }
         ]
 }
].
```

Custom Formatting
-----------------
All loggers have a default formatting that can be overriden.  A formatter is any module that
exports `format(#lager_log_message{},Config#any())`.  It is specified as part of the configuration
for the backend:

```erlang
{lager, [
  {handlers, [
    {lager_console_backend, [{level, info}, {formatter, lager_default_formatter},
      {formatter_config, [time," [",severity,"] ", message, "\n"]}]},
    {lager_file_backend, [{file, "error.log"}, {level, error}, {formatter, lager_default_formatter},
      {formatter_config, [date, " ", time," [",severity,"] ",pid, " ", message, "\n"]}]},
    {lager_file_backend, [{file, "console.log"}, {level, info}]}
  ]}
]}.
```

Included is `lager_default_formatter`.  This provides a generic, default
formatting for log messages using a structure similar to Erlang's
[iolist](http://learnyousomeerlang.com/buckets-of-sockets#io-lists) which we
call "semi-iolist":

* Any traditional iolist elements in the configuration are printed verbatim.
* Atoms in the configuration are treated as placeholders for lager metadata and
  extracted from the log message.
    * The placeholders `date`, `time`, `message`, `sev` and `severity` will always exist.
    * `sev` is an abbreviated severity which is interpreted as a capitalized
      single letter encoding of the severity level (e.g. `'debug'` -> `$D`)
    * The placeholders `pid`, `file`, `line`, `module`, `function`, and `node`
      will always exist if the parse transform is used.
    * The placeholder `application` may exist if the parse transform is used.
      It is dependent on finding the applications `app.src` file.
    * If the error logger integration is used, the placeholder `pid`
      will always exist and the placeholder `name` may exist.
    * Applications can define their own metadata placeholder.
    * A tuple of `{atom(), semi-iolist()}` allows for a fallback for
      the atom placeholder. If the value represented by the atom
      cannot be found, the semi-iolist will be interpreted instead.
    * A tuple of `{atom(), semi-iolist(), semi-iolist()}` represents a
      conditional operator: if a value for the atom placeholder can be
      found, the first semi-iolist will be output; otherwise, the
      second will be used.
    * A tuple of `{pterm, atom()}` will attempt to lookup
      the value of the specified atom from the
      [persistent_term](http://erlang.org/doc/man/persistent_term.html)
      feature added in OTP 21.2. The default value is `""`. The
      default value will be used if the key cannot be found or
      if this formatting term is specified on an OTP release before
      OTP 21.
    * A tuple of `{pterm, atom(), semi-iolist()}` will attempt to
      lookup the value of the specified atom from the persistent_term
      feature added in OTP 21.2. The default value is the specified
      semi-iolist(). The default value will be used if the key cannot
      be found or the if this formatting term is specified on an OTP
      release before OTP 21.

Examples:

```
["Foo"] -> "Foo", regardless of message content.
[message] -> The content of the logged message, alone.
[{pid,"Unknown Pid"}] -> "<?.?.?>" if pid is in the metadata, "Unknown Pid" if not.
[{pid, ["My pid is ", pid], ["Unknown Pid"]}] -> if pid is in the metadata print "My pid is <?.?.?>", otherwise print "Unknown Pid"
[{server,{pid, ["(", pid, ")"], ["(Unknown Server)"]}}] -> user provided server metadata, otherwise "(<?.?.?>)", otherwise "(Unknown Server)"
[{pterm, pterm_key, <<"undefined">>}] -> if a value for 'pterm_key' is found in OTP 21 (or later) persistent_term storage it is used, otherwise "undefined"
```

Universal time
--------------
By default, lager formats timestamps as local time for whatever computer
generated the log message.

To make lager use UTC timestamps, you can set the `sasl` application's
`utc_log` configuration parameter to `true` in your application configuration
file.

Example:

```
%% format log timestamps as UTC
[{sasl, [{utc_log, true}]}].
```

Error logger integration
------------------------
Lager is also supplied with a `error_logger` handler module that translates
traditional erlang error messages into a friendlier format and sends them into
lager itself to be treated like a regular lager log call. To disable this, set
the lager application variable `error_logger_redirect` to `false`.
You can also disable reformatting for OTP and Cowboy messages by setting variable
`error_logger_format_raw` to `true`.

If you installed your own handler(s) into `error_logger`, you can tell
lager to leave it alone by using the `error_logger_whitelist` environment
variable with a list of handlers to allow.

```
{error_logger_whitelist, [my_handler]}
```

The `error_logger` handler will also log more complete error messages (protected
with use of `trunc_io`) to a "crash log" which can be referred to for further
information. The location of the crash log can be specified by the `crash_log`
application variable. If set to `false` it is not written at all.

Messages in the crash log are subject to a maximum message size which can be
specified via the `crash_log_msg_size` application variable.

Messages from `error_logger` will be redirected to `error_logger_lager_event` sink
if it is defined so it can be redirected to another log file.

For example:

```
[{lager, [
         {extra_sinks,
          [
           {error_logger_lager_event, 
            [{handlers, [
              {lager_file_backend, [{file, "error_logger.log"}, {level, info}]}]
              }]
           }]
           }]
}].
```
will send all `error_logger` messages to `error_logger.log` file.

Overload Protection
-------------------

### Asynchronous mode

Prior to lager 2.0, the `gen_event` at the core of lager operated purely in
synchronous mode. Asynchronous mode is faster, but has no protection against
message queue overload. As of lager 2.0, the `gen_event` takes a hybrid
approach. it polls its own mailbox size and toggles the messaging between
synchronous and asynchronous depending on mailbox size.

```erlang
{async_threshold, 20},
{async_threshold_window, 5}
```

This will use async messaging until the mailbox exceeds 20 messages, at which
point synchronous messaging will be used, and switch back to asynchronous, when
size reduces to `20 - 5 = 15`.

If you wish to disable this behaviour, simply set `async_threshold` to `undefined`. It defaults
to a low number to prevent the mailbox growing rapidly beyond the limit and causing
problems. In general, lager should process messages as fast as they come in, so getting
20 behind should be relatively exceptional anyway.

If you want to limit the number of messages per second allowed from `error_logger`,
which is a good idea if you want to weather a flood of messages when lots of
related processes crash, you can set a limit:

```erlang
{error_logger_hwm, 50}
```

It is probably best to keep this number small.

### Event queue flushing

When the high-water mark is exceeded, lager can be configured to flush all
event notifications in the message queue. This can have unintended consequences
for other handlers in the same event manager (in e.g. the `error_logger`), as
events they rely on may be wrongly discarded. By default, this behavior is enabled,
but can be controlled, for the `error_logger` via:

```erlang
{error_logger_flush_queue, true | false}
```

or for a specific sink, using the option:

```erlang
{flush_queue, true | false}
```

If `flush_queue` is true, a message queue length threshold can be set, at which
messages will start being discarded. The default threshold is `0`, meaning that
if `flush_queue` is true, messages will be discarded if the high-water mark is
exceeded, regardless of the length of the message queue. The option to control
the threshold is, for `error_logger`:

```erlang
{error_logger_flush_threshold, 1000}
```

and for sinks:

```erlang
{flush_threshold, 1000}
```

### Sink Killer

In some high volume situations, it may be preferable to drop all pending log
messages instead of letting them drain over time.

If you prefer, you may choose to use the sink killer to shed load. In this
operational mode, if the `gen_event` mailbox exceeds a configurable
high water mark, the sink will be killed and reinstalled after a
configurable cool down time.

You can configure this behavior by using these configuration directives:

```erlang
{killer_hwm, 1000},
{killer_reinstall_after, 5000}
```

This means if the sink's mailbox size exceeds 1000 messages, kill the
entire sink and reload it after 5000 milliseconds. This behavior can
also be installed into alternative sinks if desired.

By default, the manager killer *is not installed* into any sink. If
the `killer_reinstall_after` cool down time is not specified it defaults
to 5000.

"Unsafe"
--------
The unsafe code pathway bypasses the normal lager formatting code and uses the
same code as error_logger in OTP. This provides a marginal speedup to your logging
code (we measured between 0.5-1.3% improvement during our benchmarking; others have
reported better improvements.)

This is a **dangerous** feature. It *will not* protect you against
large log messages - large messages can kill your application and even your
Erlang VM dead due to memory exhaustion as large terms are copied over and
over in a failure cascade.  We strongly recommend that this code pathway
only be used by log messages with a well bounded upper size of around 500 bytes.

If there's any possibility the log messages could exceed that limit, you should
use the normal lager message formatting code which will provide the appropriate
size limitations and protection against memory exhaustion.

If you want to format an unsafe log message, you may use the severity level (as
usual) followed by `_unsafe`. Here's an example:

```erlang
lager:info_unsafe("The quick brown ~s jumped over the lazy ~s", ["fox", "dog"]).
```

Runtime loglevel changes
------------------------
You can change the log level of any lager backend at runtime by doing the
following:

```erlang
lager:set_loglevel(lager_console_backend, debug).
```

  Or, for the backend with multiple handles (files, mainly):

```erlang
lager:set_loglevel(lager_file_backend, "console.log", debug).
```

Lager keeps track of the minimum log level being used by any backend and
suppresses generation of messages lower than that level. This means that debug
log messages, when no backend is consuming debug messages, are effectively
free. A simple benchmark of doing 1 million debug log messages while the
minimum threshold was above that takes less than half a second.

Syslog style loglevel comparison flags
--------------------------------------
In addition to the regular log level names, you can also do finer grained masking
of what you want to log:

```
info - info and higher (>= is implicit)
=debug - only the debug level
!=info - everything but the info level
<=notice - notice and below
<warning - anything less than warning
```

These can be used anywhere a loglevel is supplied, although they need to be either
a quoted atom or a string.

Internal log rotation
---------------------
Lager can rotate its own logs or have it done via an external process. To
use internal rotation, use the `size`, `date` and `count` values in the file
backend's config:

```erlang
[{file, "error.log"}, {level, error}, {size, 10485760}, {date, "$D0"}, {count, 5}]
```

This tells lager to log error and above messages to `error.log` and to
rotate the file at midnight or when it reaches 10mb, whichever comes first,
and to keep 5 rotated logs in addition to the current one. Setting the
count to 0 does not disable rotation, it instead rotates the file and keeps
no previous versions around. To disable rotation set the size to 0 and the
date to "".

The `$D0` syntax is taken from the syntax newsyslog uses in newsyslog.conf.
The relevant extract follows:

```
Day, week and month time format: The lead-in character
for day, week and month specification is a `$'-sign.
The particular format of day, week and month
specification is: [Dhh], [Ww[Dhh]] and [Mdd[Dhh]],
respectively.  Optional time fields default to
midnight.  The ranges for day and hour specifications
are:

  hh      hours, range 0 ... 23
  w       day of week, range 0 ... 6, 0 = Sunday
  dd      day of month, range 1 ... 31, or the
          letter L or l to specify the last day of
          the month.

Some examples:
  $D0     rotate every night at midnight
  $D23    rotate every day at 23:00 hr
  $W0D23  rotate every week on Sunday at 23:00 hr
  $W5D16  rotate every week on Friday at 16:00 hr
  $M1D0   rotate on the first day of every month at
          midnight (i.e., the start of the day)
  $M5D6   rotate on every 5th day of the month at
          6:00 hr
```

On top of the day, week and month time format from newsyslog,
hour specification is added from PR [#420](https://github.com/erlang-lager/lager/pull/420)

```
Format of hour specification is : [Hmm]
The range for minute specification is:

  mm      minutes, range 0 ... 59

Some examples:

  $H00    rotate every hour at HH:00
  $D12H30 rotate every day at 12:30
  $W0D0H0 rotate every week on Sunday at 00:00
```

To configure the crash log rotation, the following application variables are
used:
* `crash_log_size`
* `crash_log_date`
* `crash_log_count`
* `crash_log_rotator`

See the `.app.src` file for further details.

Custom Log Rotation
-------------------
Custom log rotator could be configured with option for `lager_file_backend`
```erlang
{rotator, lager_rotator_default}
```

The module should provide the following callbacks as `lager_rotator_behaviour`

```erlang
%% @doc Create a log file
-callback(create_logfile(Name::list(), Buffer::{integer(), integer()} | any()) ->
    {ok, {FD::file:io_device(), Inode::integer(), Size::integer()}} | {error, any()}).

%% @doc Open a log file
-callback(open_logfile(Name::list(), Buffer::{integer(), integer()} | any()) ->
    {ok, {FD::file:io_device(), Inode::integer(), Size::integer()}} | {error, any()}).

%% @doc Ensure reference to current target, could be rotated
-callback(ensure_logfile(Name::list(), FD::file:io_device(), Inode::integer(),
                         Buffer::{integer(), integer()} | any()) ->
    {ok, {FD::file:io_device(), Inode::integer(), Size::integer()}} | {error, any()}).

%% @doc Rotate the log file
-callback(rotate_logfile(Name::list(), Count::integer()) ->
    ok).
```

Syslog Support
--------------
Lager syslog output is provided as a separate application:
[lager_syslog](https://github.com/erlang-lager/lager_syslog). It is packaged as a
separate application so lager itself doesn't have an indirect dependency on a
port driver. Please see the `lager_syslog` README for configuration information.

Other Backends
--------------
There are lots of them! Some connect log messages to AMQP, various logging
analytic services ([bunyan](https://github.com/Vagabond/lager_bunyan_formatter),
[loggly](https://github.com/kivra/lager_loggly), etc), and more. [Looking on
hex](https://hex.pm/packages?_utf8=✓&search=lager&sort=recent_downloads) or
using "lager BACKEND" where "BACKEND" is your preferred log solution
on your favorite search engine is a good starting point.

Exception Pretty Printing
----------------------
Up to OTP 20:

```erlang
try
    foo()
catch
    Class:Reason ->
        lager:error(
            "~nStacktrace:~s",
            [lager:pr_stacktrace(erlang:get_stacktrace(), {Class, Reason})])
end.
```

On OTP 21+:

```erlang
try
    foo()
catch
    Class:Reason:Stacktrace ->
        lager:error(
            "~nStacktrace:~s",
            [lager:pr_stacktrace(Stacktrace, {Class, Reason})])
end.
```

Record Pretty Printing
----------------------
Lager's parse transform will keep track of any record definitions it encounters
and store them in the module's attributes. You can then, at runtime, print any
record a module compiled with the lager parse transform knows about by using the
`lager:pr/2` function, which takes the record and the module that knows about the record:

```erlang
lager:info("My state is ~p", [lager:pr(State, ?MODULE)])
```

Often, `?MODULE` is sufficent, but you can obviously substitute that for a literal module name.
`lager:pr` also works from the shell.

Colored terminal output
-----------------------
If you have Erlang R16 or higher, you can tell lager's console backend to be colored. Simply
add to lager's application environment config:

```erlang
{colored, true}
```

If you don't like the default colors, they are also configurable; see
the `.app.src` file for more details.

The output will be colored from the first occurrence of the atom color
in the formatting configuration. For example:

```erlang
{lager_console_backend, [{level, info}, {formatter, lager_default_formatter},
  {formatter_config, [time, color, " [",severity,"] ", message, "\e[0m\r\n"]}]]}
```

This will make the entire log message, except time, colored. The
escape sequence before the line break is needed in order to reset the
color after each log message.

Tracing
-------
Lager supports basic support for redirecting log messages based on log message
attributes. Lager automatically captures the pid, module, function and line at the
log message callsite. However, you can add any additional attributes you wish:

```erlang
lager:warning([{request, RequestID},{vhost, Vhost}], "Permission denied to ~s", [User])
```

Then, in addition to the default trace attributes, you'll be able to trace
based on request or vhost:

```erlang
lager:trace_file("logs/example.com.error", [{vhost, "example.com"}], error)
```

To persist metadata for the life of a process, you can use `lager:md/1` to store metadata
in the process dictionary:

```erlang
lager:md([{zone, forbidden}])
```

Note that `lager:md` will *only* accept a list of key/value pairs keyed by atoms.

You can also omit the final argument, and the loglevel will default to
`debug`.

Tracing to the console is similar:

```erlang
lager:trace_console([{request, 117}])
```

In the above example, the loglevel is omitted, but it can be specified as the
second argument if desired.

You can also specify multiple expressions in a filter, or use the `*` atom as
a wildcard to match any message that has that attribute, regardless of its
value. You may also use the special value `!` to mean, only select if this
key is **not** present.

Tracing to an existing logfile is also supported (but see **Multiple
sink support** below):

```erlang
lager:trace_file("log/error.log", [{module, mymodule}, {function, myfunction}], warning)
```

To view the active log backends and traces, you can use the `lager:status()`
function. To clear all active traces, you can use `lager:clear_all_traces()`.

To delete a specific trace, store a handle for the trace when you create it,
that you later pass to `lager:stop_trace/1`:

```erlang
{ok, Trace} = lager:trace_file("log/error.log", [{module, mymodule}]),
...
lager:stop_trace(Trace)
```

Tracing to a pid is somewhat of a special case, since a pid is not a
data-type that serializes well. To trace by pid, use the pid as a string:

```erlang
lager:trace_console([{pid, "<0.410.0>"}])
```

### Filter expressions
As of lager 3.3.1, you can also use a 3 tuple while tracing where the second
element is a comparison operator. The currently supported comparison operators
are:

* `<` - less than
* `=<` - less than or equal
* `=` - equal to
* `!=` - not equal to
* `>` - greater than
* `>=` - greater than or equal

```erlang
lager:trace_console([{request, '>', 117}, {request, '<', 120}])
```

Using `=` is equivalent to the 2-tuple form.

### Filter composition
As of lager 3.3.1 you may also use the special filter composition keys of
`all` or `any`. For example the filter example above could be
expressed as:

```erlang
lager:trace_console([{all, [{request, '>', 117}, {request, '<', 120}]}])
```

`any` has the effect of "OR style" logical evaluation between filters; `all`
means "AND style" logical evaluation between filters. These compositional filters
expect a list of additional filter expressions as their values.

### Null filters
The `null` filter has a special meaning.  A filter of `{null, false}` acts as
a black hole; nothing is passed through.  A filter of `{null, true}` means
*everything* passes through. No other values for the null filter are valid and
will be rejected.

### Multiple sink support

If using multiple sinks, there are limitations on tracing that you
should be aware of.

Traces are specific to a sink, which can be specified via trace
filters:

```erlang
lager:trace_file("log/security.log", [{sink, audit_event}, {function, myfunction}], warning)
```

If no sink is thus specified, the default lager sink will be used.

This has two ramifications:

* Traces cannot intercept messages sent to a different sink.
* Tracing to a file already opened via `lager:trace_file` will only be
  successful if the same sink is specified.

The former can be ameliorated by opening multiple traces; the latter
can be fixed by rearchitecting lager's file backend, but this has not
been tackled.

### Traces from configuration

Lager supports starting traces from its configuration file. The keyword
to define them is `traces`, followed by a proplist of tuples that define
a backend handler and zero or more filters in a required list,
followed by an optional message severity level.

An example looks like this:

```erlang
{lager, [
  {handlers, [...]},
  {traces, [
    %% handler,                         filter,                message level (defaults to debug if not given)
    {lager_console_backend,             [{module, foo}],       info },
    {{lager_file_backend, "trace.log"}, [{request, '>', 120}], error},
    {{lager_file_backend, "event.log"}, [{module, bar}]             } %% implied debug level here
  ]}
]}.
```

In this example, we have three traces. One using the console backend, and two
using the file backend. If the message severity level is left out, it defaults
to `debug` as in the last file backend example.

The `traces` keyword works on alternative sinks too but the same limitations
and caveats noted above apply.

**IMPORTANT**: You **must** define a severity level in all lager releases
up to and including 3.1.0 or previous. The 2-tuple form wasn't added until
3.2.0.

Setting dynamic metadata at compile-time
----------------------------------------
Lager supports supplying metadata from external sources by registering a 
callback function. This metadata is also persistent across processes even if 
the process dies.

In general use you won't need to use this feature. However it is useful in 
situations such as:
 * Tracing information provided by 
   [seq_trace](http://erlang.org/doc/man/seq_trace.html)
 * Contextual information about your application
 * Persistent information which isn't provided by the default placeholders
 * Situations where you would have to set the metadata before every logging call 

You can add the callbacks by using the `{lager_parse_transform_functions, X}` 
option.  It is only available when using `parse_transform`. In rebar, you can 
add it to `erl_opts` as below:

```erlang
{erl_opts, [{parse_transform, lager_transform}, 
            {lager_function_transforms, 
              [
                 %% Placeholder              Resolve type  Callback tuple
                {metadata_placeholder,       on_emit,      {module_name, function_name}},
                {other_metadata_placeholder, on_log,       {module_name, function_name}}
              ]}]}.
```

The first atom is the placeholder atom used for the substitution in your custom
 formatter. See [Custom Formatting](#custom-formatting) for more information.

The second atom is the resolve type. This specify the callback to resolve at 
the time of the message being emitted or at the time of the logging call. You 
have to specify either the atom `on_emit` or `on_log`. There is not a 'right' 
resolve type to use, so please read the uses/caveats of each and pick the option 
which fits your requirements best.
 
`on_emit`:
  * The callback functions are not resolved until the message is emitted by the
    backend.
  * If the callback function cannot be resolved, not loaded or produces 
    unhandled errors then `undefined` will be returned.
  * Since the callback function is dependent on a process, there is the 
    chance that message will be emitted after the dependent process has died 
    resulting in `undefined` being returned. This process can also be your own
    process
 
`on_log`:
  * The callback functions are resolved regardless whether the message is  
    emitted or not
  * If the callback function cannot be resolved or not loaded the errors are 
    not handled by lager itself.
  * Any potential errors in callback should be handled in the callback function
    itself.
  * Because the function is resolved at log time there should be less chance
    of the dependent process dying before you can resolve it, especially if
    you are logging from the app which contains the callback.

The third element is the callback to your function consisting of a tuple in the
form `{Module Function}`. The callback should look like the following 
regardless if using `on_emit` or `on_log`:  
  * It should be exported
  * It should takes no arguments e.g. has an arity of 0
  * It should return any traditional iolist elements or the atom `undefined`
  * For errors generated within your callback see the resolve type documentation
    above.

If the callback returns `undefined` then it will follow the same fallback and
conditional operator rules as documented in the 
[Custom Formatting](#custom-formatting) section. 

This example would work with `on_emit` but could be unsafe to use with 
`on_log`. If the call failed in `on_emit` it would default to `undefined`, 
however with `on_log` it would error.

```erlang
-export([my_callback/0]).

my_callback() ->
  my_app_serv:call('some options').
```

This example would be to safe to work with both `on_emit` and `on_log`

```erlang
-export([my_callback/0]).

my_callback() ->
  try my_app_serv:call('some options') of
    Result ->
      Result
  catch
    _ ->
      %% You could define any traditional iolist elements you wanted here
      undefined
  end.
```

Note that the callback can be any Module:Function/0. It does not have be part 
of your application. For example you could use `cpu_sup:avg1/0` as your  
callback function like so `{cpu_avg1, on_emit, {cpu_sup, avg1}}`


Examples:

```erlang
-export([reductions/0]).

reductions() ->
  proplists:get_value(reductions, erlang:process_info(self())).
```

```erlang
-export([seq_trace/0]).

seq_trace() ->
  case seq_trace:get_token(label) of
    {label, TraceLabel} ->
      TraceLabel;
    _ ->
      undefined
  end.
```

**IMPORTANT**: Since `on_emit` relies on function calls injected at the
point where a log message is emitted, your logging performance (ops/sec)
will be impacted by what the functions you call do and how much latency they
may introduce. This impact will even greater with `on_log` since the calls
are injected at the point a message is logged.

Setting the truncation limit at compile-time
--------------------------------------------
Lager defaults to truncating messages at 4096 bytes, you can alter this by
using the `{lager_truncation_size, X}` option. In rebar, you can add it to
`erl_opts`:

```erlang
{erl_opts, [{parse_transform, lager_transform}, {lager_truncation_size, 1024}]}.
```

You can also pass it to `erlc`, if you prefer:

```
erlc -pa lager/ebin +'{parse_transform, lager_transform}' +'{lager_truncation_size, 1024}' file.erl
```

Suppress applications and supervisors start/stop logs
-----------------------------------------------------
If you don't want to see supervisors and applications start/stop logs in debug
level of your application, you can use these configs to turn it off:

```erlang
{lager, [{suppress_application_start_stop, true},
         {suppress_supervisor_start_stop, true}]}
```

Sys debug functions
--------------------

Lager provides an integrated way to use sys 'debug functions'. You can install a debug
function in a target process by doing

```erlang
lager:install_trace(Pid, notice).
```

You can also customize the tracing somewhat:

```erlang
lager:install_trace(Pid, notice, [{count, 100}, {timeout, 5000}, {format_string, "my trace event ~p ~p"]}).
```

The trace options are currently:

* timeout - how long the trace stays installed: `infinity` (the default) or a millisecond timeout
* count - how many trace events to log: `infinity` (default) or a positive number
* format_string - the format string to log the event with. *Must* have 2 format specifiers for the 2 parameters supplied.

This will, on every 'system event' for an OTP process (usually inbound messages, replies
and state changes) generate a lager message at the specified log level.

You can remove the trace when you're done by doing:

```erlang
lager:remove_trace(Pid).
```

If you want to start an OTP process with tracing enabled from the very beginning, you can do something like this:

```erlang
gen_server:start_link(mymodule, [], [{debug, [{install, {fun lager:trace_func/3, lager:trace_state(undefined, notice, [])}}]}]).
```

The third argument to the trace_state function is the Option list documented above.

Console output to another group leader process
----------------------------------------------

If you want to send your console output to another group_leader (typically on
another node) you can provide a `{group_leader, Pid}` argument to the console
backend. This can be combined with another console config option, `id` and
gen_event's `{Module, ID}` to allow remote tracing of a node to standard out via
nodetool:

```erlang
    GL = erlang:group_leader(),
    Node = node(GL),
    lager_app:start_handler(lager_event, {lager_console_backend, Node},
         [{group_leader, GL}, {level, none}, {id, {lager_console_backend, Node}}]),
    case lager:trace({lager_console_backend, Node}, Filter, Level) of
         ...
```

In the above example, the code is assumed to be running via a `nodetool rpc`
invocation so that the code is executing on the Erlang node, but the
group_leader is that of the reltool node (eg. appname_maint_12345@127.0.0.1).

If you intend to use tracing with this feature, make sure the second parameter
to start_handler and the `id` parameter match. Thus when the custom group_leader
process exits, lager will remove any associated traces for that handler.

Elixir Support
--------------

There are 2 ways in which Lager can be leveraged in an Elixir project:

1. Lager Backend for Elixir Logger
2. Directly

### Lager Backend for Elixir Logger

[Elixir's Logger](https://hexdocs.pm/logger/Logger.html) is the idiomatic way
to add logging into elixir code. Logger has a plug-in model,
allowing for different logging [Backends](https://hexdocs.pm/logger/Logger.html#module-backends)
to be used without the need to change the logging code within your project.

This approach will benefit from the fact that most elixir libs and frameworks
are likely to use the elixir Logger and as such logging will all flow via the
same logging mechanism.

In [elixir 1.5 support for parse transforms was deprecated](https://github.com/elixir-lang/elixir/issues/5762).
Taking the "Lager as a Logger Backend" approach is likely bypass any related 
regression issues that would be introduced into a project which is using lager 
directly when updating to elixir 1.5.

There are open source elixir Logger backends for Lager available:
- [LagerLogger](https://github.com/PSPDFKit-labs/lager_logger)
- [LoggerLagerBackend](https://github.com/jonathanperret/logger_lager_backend)

### Directly

It is fully possible prior to elixir 1.5 to use lager and all its features
directly.

After elixir 1.5 there is no support for parse transforms, and it is
recommended to use an elixir wrapper for the lager api that provides compile time
log level exclusion via elixir macros when opting for direct use of lager.

Including Lager as a dependency:
``` elixir
# mix.exs
def application do
  [
    applications: [:lager],
    erl_opts: [parse_transform: "lager_transform"]
  ]
end

defp deps do
  [{:lager, "~> 3.2"}]
end
```

Example Configuration:
``` elixir
# config.exs
use Mix.Config

# Stop lager writing a crash log
config :lager, :crash_log, false

config :lager,
  log_root: '/var/log/hello',
  handlers: [
    lager_console_backend: :info,
    lager_file_backend: [file: "error.log", level: :error],
    lager_file_backend: [file: "console.log", level: :info]
  ]
```

There is a known issue where Elixir's Logger and Lager both contest for the
Erlang `error_logger` handle if used side by side.

If using both add the following to your `config.exs`:
```elixir
# config.exs
use Mix.Config

# Stop lager redirecting :error_logger messages
config :lager, :error_logger_redirect, false

# Stop lager removing Logger's :error_logger handler
config :lager, :error_logger_whitelist, [Logger.ErrorHandler]
```

Example Usage:
``` elixir
:lager.error('Some message')
:lager.warning('Some message with a term: ~p', [term])
```

3.x Changelog
-------------

3.8.2 - 4 February 2021

    * Bugfix: Make directory expansion return an absolute path (#535)
    * Feature: Write crash.log under the log_root location (#536)
    * Bugfix: Handle line numbering correctly in forthcoming OTP 24 release (#537)

3.8.1 - 28 August 2020

    * Feature: Allow metadata fields to be whitelisted in log formatting (#514)
    * Feature: Enable a persistent_term log formatter (#530) (#531)
    * Bugfix: Handle gen_statem crashes in newer OTP releases correctly (#523)
    * Cleanup: Add a hex badge (#525)
    * Cleanup: Fix Travis CI badge link
    * Policy: Officially ending support for OTP 20 (Support OTP 21, 22, 23)

3.8.0 - 9 August 2019

    * Breaking API change: Modify the `lager_rotator_behaviour` to pass in a
      file's creation time to `ensure_logfile/5` to be used to determine if
      file has changed on systems where inodes are not available (i.e.
      `win32`). The return value from `create_logfile/2`, `open_logfile/2` and
      `ensure_logfile/5` now requires ctime to be returned (#509)
    * Bugfix: ensure log file rotation works on `win32` (#509)
    * Bugfix: ensure test suite passes on `win32` (#509)
    * Bugfix: ensure file paths with Unicode are formatted properly (#510)

3.7.0 - 24 May 2019

    * Policy: Officially ending support for OTP 19 (Support OTP 20, 21, 22)
    * Cleanup: Fix all dialyzer errors
    * Bugfix: Minor changes to FSM/statem exits in OTP 22.

3.6.10 - 30 April 2019

    * Documentation: Fix pr_stacktrace invocation example (#494)
    * Bugfix: Do not count suppressed messages for message drop counts (#499)

3.6.9 - 13 March 2019

    * Bugfix: Fix file rotation on windows (#493)

3.6.8 - 21 December 2018

    * Documentation: Document the error_logger_whitelist environment variable. (#489)
    * Bugfix: Remove the built in handler inside of OTP 21 `logger` system. (#488)
    * Bugfix: Cleanup unneeded check for is_map (#486)
    * Bugfix: Cleanup ranch errors treated as cowboy errors (#485)
    * Testing: Remove OTP 18 from TravisCI testing matrix

3.6.7 - 14 October 2018

    * Bugfix: fix tracing to work with OTP21 #480

3.6.6 - 24 September 2018

    * Bugfix: When printing records, handle an improper list correctly. #478
    * Bugfix: Fix various tests and make some rotation code more explicit. #476
    * Bugfix: Make sure not to miscount messages during high-water mark check. #475

3.6.5 - 3 September 2018

    * Feature: Allow the console backend to redirect output to a remote node #469
    * Feature: is_loggble - support for severity as atom #472
    * Bugfix: Prevent silent dropping of messages when hwm is exceeded #467
    * Bugfix: rotation - default log file not deleted #474
    * Bugfix: Handle strange crash report from gen_statem #473
    * Documentation: Various markup fixes: #468 #470

3.6.4 - 11 July 2018

    * Bugfix: Reinstall handlers after a sink is killed #459
    * Bugfix: Fix platform_define matching not to break on OSX Mojave #461
    * Feature: Add support for installing a sys trace function #462

3.6.3 - 6 June 2018

    * OTP 21 support

3.6.2 - 26 April 2018

    * Bugfix: flush_threshold not working (#449)
    * Feature: Add `node` as a formatting option (#447)
    * Documentation: Update Elixir section with information about parse_transform (#446)
    * Bugfix: Correct default console configuation to use "[{level,info}]" instead (#445)
    * Feature: Pretty print lists of records at top level and field values with lager:pr (#442)
    * Bugfix: Ignore return value of lager:dispatch_log in lager.hrl (#441)

3.6.1 - 1 February 2018

    * Bugfix: Make a few corrections to the recent mailbox flushing changes (#436)
    * Bugfix: add flush options to proplist validation (#439)
    * Bugfix: Don't log when we dropped 0 messages (#440)

3.6.0 - 16 January 2018

    * Feature: Support logging with macros per level (#419)
    * Feature: Support custom file rotation handler; support hourly file
               rotation (#420)
    * Feature: Optionally reverse pretty stacktraces (so errors are
               at the top and the failed function call is at the bottom.)
               (#424)
    * Bugfix:  Handle OTP 20 gen_server failure where client pid
               is dead. (#426)
    * Feature: Optionally don't flush notify messages at
               high water mark. (#427)
    * Bugfix:  Handle another stacktrace format (#429)
    * Bugfix:  Fix test failure using macros on OTP 18 (#430)
    * Policy:  Remove all code which supports R15 (#432)

3.5.2 - 19 October 2017

    * Bugfix: Properly check for unicode characters in potentially deep
              character list. (#417)

3.5.1 - 15 June 2017

    * Doc fix: Missed a curly brace in an example. (#412)
    * Feature: Dynamic metadata functions (#392) - It is now possible to
               dynamically add metadata to lager messages. See the "dynamic
               metadata" section above for more information.
    * Doc fix: Add information about the "application" placeholder. (#414)

3.5.0 - 28 May 2017

    * Bugfix: Support OTP 20 gen_event messages (#410)
    * Feature: Enable console output to standard_error.
               Convert to proplist configuration style (like file handler)
               Deprecate previous configuration directives (#409)
    * Bugfix: Enable the event shaper to filter messages before they're
              counted; do not count application/supervisor start/stops
              toward high water mark. (#411)
    * Docs: Add PR guidelines; add info about the #lager chat room on freenode.

3.4.2 - 26 April 2017

    * Docs: Document how to make lager use UTC timestamps (#405)
    * Docs: Add a note about our triage cadence.
    * Docs: Update lager_syslog URL
    * Docs: Document placeholders for error_logger integration (#404)
    * Feature: Add hex.pm metadata and full rebar3 support.

3.4.1 - 28 March 2017

    * Docs: Added documentation around using lager in the context of elixir applications (#398)
    * Bugfix: Properly expand paths when log_root is set. (#386)
    * Policy: Removed R15 from Travis configuration

3.4.0 - 16 March 2017

    * Policy: Adopt official OTP support policy. (This is the **last** lager 3.x release
      that will support R15.)
    * Test: Fix timeouts, R15 missing functions on possibly long-running tests in Travis. (#394, #395)
    * Feature: capture and log metadata from error_logger messages (#397)
    * Feature: Expose new trace filters and enable filter composition (#389)
    * Feature: Log crashes from gen_fsm and gen_statem correctly (#391)
    * Docs: Typo in badge URL (#390)

3.3.0 - 16 February 2017

    * Docs: Fix documentation to make 'it' unambiguous when discussing asychronous
      operation. (#387)
    * Test: Fix test flappiness due to insufficient sanitation between test runs (#384, #385)
    * Feature: Allow metadata only logging. (#380)
    * Feature: Add an upper case severity formatter (#372)
    * Feature: Add support for suppressing start/stop messages from supervisors (#368)
    * Bugfix: Fix ranch crash messages (#366)
    * Test: Update Travis config for 18.3 and 19.0 (#365)

3.2.4 - 11 October 2016

    * Test: Fix dialyzer warnings.

3.2.3 - 29 September 2016

    * Dependency: Update to goldrush 0.19

3.2.2 - 22 September 2016

    * Bugfix: Backwards-compatibility fix for `{crash_log, undefined}` (#371)
    * Fix documentation/README to reflect the preference for using `false`
      as the `crash_log` setting value rather than `undefined` to indicate
      that the crash log should not be written (#364)
    * Bugfix: Backwards-compatibility fix for `lager_file_backend` "legacy"
      configuration format (#374)

3.2.1 - 10 June 2016

    * Bugfix: Recent `get_env` changes resulted in launch failure (#355)
    * OTP: Support typed records for Erlang 19.0 (#361)

3.2.0 - 08 April 2016

    * Feature: Optional sink killer to shed load when mailbox size exceeds a
      configurable high water mark (#346)
    * Feature: Export `configure_sink/2` so users may dynamically configure
      previously setup and parse transformed sinks from their own code. (#342)
    * Feature: Re-enable Travis CI and update .travis.yml (#340)
    * Bugfix: Fix test race conditions for Travis CI (#344)
    * Bugfix: Add the atom 'none' to the log_level() type so downstream
      users won't get dialyzer failures if they use the 'none' log level. (#343)
    * Bugfix: Fix typo in documentation. (#341)
    * Bugfix: Fix OTP 18 test failures due to `warning_map/0` response
      change. (#337)
    * Bugfix: Make sure traces that use the file backend work correctly
      when specified in lager configuration. (#336)
    * Bugfix: Use `lager_app:get_env/3` for R15 compatibility. (#335)
    * Bugfix: Make sure lager uses `id` instead of `name` when reporting
      supervisor children failures. (The atom changed in OTP in 2014.) (#334)
    * Bugfix: Make lager handle improper iolists (#327)

3.1.0 - 27 January 2016

    * Feature: API calls to a rotate handler, sink or all.  This change
      introduces a new `rotate` message for 3rd party lager backends; that's
      why this is released as a new minor version number. (#311)

3.0.3 - 27 January 2016

    * Feature: Pretty printer for human readable stack traces (#298)
    * Feature: Make error reformatting optional (#305)
    * Feature: Optional and explicit sink for error_logger messages (#303)
    * Bugfix: Always explicitly close a file after its been rotated (#316)
    * Bugfix: If a relative path already contains the log root, do not add it again (#317)
    * Bugfix: Configure and start extra sinks before traces are evaluated (#307)
    * Bugfix: Stop and remove traces correctly (#306)
    * Bugfix: A byte value of 255 is valid for Unicode (#300)
    * Dependency: Bump to goldrush 0.1.8 (#313)
