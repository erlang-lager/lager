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
* Rewrites common OTP error messages into more readable messages
* Support for pretty printing records encountered at compile time
* Tolerant in the face of large or many log messages, won't out of memory the node
* Supports internal time and date based rotation, as well as external rotation tools
* Syslog style log level comparison flags
* Colored terminal output (requires R16+)
* Map support (requires 17+)

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

Included is `lager_default_formatter`.  This provides a generic, default formatting for log messages using a structure similar to Erlang's [iolist](http://learnyousomeerlang.com/buckets-of-sockets#io-lists) which we call "semi-iolist":

* Any traditional iolist elements in the configuration are printed verbatim.
* Atoms in the configuration are treated as placeholders for lager metadata and extracted from the log message.
    * The placeholders `date`, `time`, `message`, and `severity` will always exist.
    * The placeholders `pid`, `file`, `line`, `module`, `function`, and `node` will always exist if the parse transform is used.
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

The `error_logger` handler will also log more complete error messages (protected
with use of `trunc_io`) to a "crash log" which can be referred to for further
information. The location of the crash log can be specified by the crash_log
application variable. If set to `undefined` it is not written at all.

Messages in the crash log are subject to a maximum message size which can be
specified via the `crash_log_msg_size` application variable.

Overload Protection
-------------------

Prior to lager 2.0, the `gen_event` at the core of lager operated purely in
synchronous mode. Asynchronous mode is faster, but has no protection against
message queue overload. In lager 2.0, the `gen_event` takes a hybrid approach. it
polls its own mailbox size and toggles the messaging between synchronous and
asynchronous depending on mailbox size.

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

Tracing to an existing logfile is also supported, if you wanted to log
warnings from a particular function in a particular module to the default `error.log`:

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
