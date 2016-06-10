Overview
--------
Lager (as in the beer) is a logging framework for Erlang. Its purpose is
to provide a more traditional way to perform logging in an erlang application
that plays nicely with traditional UNIX logging tools like logrotate and
syslog.

  [Travis-CI](http://travis-ci.org/basho/lager) :: ![Travis-CI](https://secure.travis-ci.org/basho/lager.png)

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
    {lager_console_backend, info},
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
                      {lager_console_backend, info},
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
    {lager_console_backend, [info, {lager_default_formatter, [time," [",severity,"] ", message, "\n"]}]},
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
    * Applications can define their own metadata placeholder.
    * A tuple of `{atom(), semi-iolist()}` allows for a fallback for
      the atom placeholder. If the value represented by the atom
      cannot be found, the semi-iolist will be interpreted instead.
    * A tuple of `{atom(), semi-iolist(), semi-iolist()}` represents a
      conditional operator: if a value for the atom placeholder can be
      found, the first semi-iolist will be output; otherwise, the
      second will be used.

Examples:

```
["Foo"] -> "Foo", regardless of message content.
[message] -> The content of the logged message, alone.
[{pid,"Unknown Pid"}] -> "<?.?.?>" if pid is in the metadata, "Unknown Pid" if not.
[{pid, ["My pid is ", pid], ["Unknown Pid"]}] -> if pid is in the metadata print "My pid is <?.?.?>", otherwise print "Unknown Pid"
[{server,{pid, ["(", pid, ")"], ["(Unknown Server)"]}}] -> user provided server metadata, otherwise "(<?.?.?>)", otherwise "(Unknown Server)"
```

Error logger integration
------------------------
Lager is also supplied with a `error_logger` handler module that translates
traditional erlang error messages into a friendlier format and sends them into
lager itself to be treated like a regular lager log call. To disable this, set
the lager application variable `error_logger_redirect` to `false`.
You can also disable reformatting for OTP and Cowboy messages by setting variable
`error_logger_format_raw` to `true`.

The `error_logger` handler will also log more complete error messages (protected
with use of `trunc_io`) to a "crash log" which can be referred to for further
information. The location of the crash log can be specified by the crash_log
application variable. If set to `undefined` it is not written at all.

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

If you wish to disable this behaviour, simply set it to `undefined`. It defaults
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

To configure the crash log rotation, the following application variables are
used:
* `crash_log_size`
* `crash_log_date`
* `crash_log_count`

See the `.app.src` file for further details.

Syslog Support
--------------
Lager syslog output is provided as a separate application:
[lager_syslog](https://github.com/basho/lager_syslog). It is packaged as a
separate application so lager itself doesn't have an indirect dependency on a
port driver. Please see the `lager_syslog` README for configuration information.

Older Backends
--------------
Lager 2.0 changed the backend API, there are various 3rd party backends for
lager available, but they may not have been updated to the new API. As they
are updated, links to them can be re-added here.

Exception Pretty Printing
----------------------

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
{lager_console_backend, [info, {lager_default_formatter, [time, color, " [",severity,"] ", message, "\e[0m\r\n"]}]}
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
value.

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

As of lager 2.0, you can also use a 3 tuple while tracing, where the second
element is a comparison operator. The currently supported comparison operators
are:

* `<` - less than
* `=` - equal to
* `>` - greater than

```erlang
lager:trace_console([{request, '>', 117}, {request, '<', 120}])
```

Using `=` is equivalent to the 2-tuple form.

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

3.x Changelog
-------------
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
