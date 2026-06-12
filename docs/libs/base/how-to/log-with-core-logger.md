# Log through `CoreLogger`

Use `CoreLogger` to write fast, structured, and styled log messages. This guide demonstrates the default `DeltaTimeLogger` implementation and how to log using the styled Interpolated Expression Sequences (IES).

## Using the DeltaTimeLogger

By default, calling `initLogger` installs `DeltaTimeLogger` as both the Phobos `std.logger.sharedLog` and `sparkles.base.logger.sharedCoreLog`. `DeltaTimeLogger` formats logs in the following layout:
`[ Time | Δt (since start) | Δtᵢ (since last log) | Level | File:Line ]: Message`

Here is an example showing how to initialize the logger and output logs of various levels, using both static styled messages and dynamic interpolated values.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "base_core_logger"
    dependency "sparkles:base" version="*"
+/
import sparkles.base.logger : initLogger, info, warning, error, critical, log, trace, LogLevel;

void main()
{
    // Initialize the logger to output logs of TRACE level or higher
    initLogger(LogLevel.trace);

    // Standard log levels with static styled messages
    trace(i"Application starting up");
    info(i"Listening on port {green 8080}");
    warning(i"Disk usage above {yellow 80%}");
    error(i"Connection to {red database} lost");
    critical(i"{bold.red Out of memory}");

    // Styled IES with interpolated values
    immutable host = "db-01.prod";
    immutable port = 5432;
    info(i"Reconnected to {green $(host)}:{cyan $(port)}");

    // Explicit log level with styled IES
    log(LogLevel.warning, i"Latency spike: {yellow.bold 230ms} on {dim $(host)}");
}
```

<!-- md-example-expected
[ {{_}} | Δt {{_}} | Δtᵢ {{_}} | TRC | {{_}} ]: Application starting up
[ {{_}} | Δt {{_}} | Δtᵢ {{_}} | INF | {{_}} ]: Listening on port 8080
[ {{_}} | Δt {{_}} | Δtᵢ {{_}} | WRN | {{_}} ]: Disk usage above 80%
[ {{_}} | Δt {{_}} | Δtᵢ {{_}} | ERR | {{_}} ]: Connection to database lost
[ {{_}} | Δt {{_}} | Δtᵢ {{_}} | CRT | {{_}} ]: Out of memory
[ {{_}} | Δt {{_}} | Δtᵢ {{_}} | INF | {{_}} ]: Reconnected to db-01.prod:5432
[ {{_}} | Δt {{_}} | Δtᵢ {{_}} | WRN | {{_}} ]: Latency spike: 230ms on db-01.prod
-->

```[Output]
[ 14:32:01 | Δt 0ms   | Δtᵢ 0ms   | TRC | base_core_logger.d:13 ]: Application starting up
[ 14:32:01 | Δt 1ms   | Δtᵢ 1ms   | INF | base_core_logger.d:14 ]: Listening on port 8080
[ 14:32:01 | Δt 2ms   | Δtᵢ 1ms   | WRN | base_core_logger.d:15 ]: Disk usage above 80%
[ 14:32:01 | Δt 3ms   | Δtᵢ 1ms   | ERR | base_core_logger.d:16 ]: Connection to database lost
[ 14:32:01 | Δt 4ms   | Δtᵢ 1ms   | CRT | base_core_logger.d:17 ]: Out of memory
[ 14:32:01 | Δt 5ms   | Δtᵢ 1ms   | INF | base_core_logger.d:22 ]: Reconnected to db-01.prod:5432
[ 14:32:01 | Δt 6ms   | Δtᵢ 1ms   | WRN | base_core_logger.d:25 ]: Latency spike: 230ms on db-01.prod
```

## Advanced Customization: Fatal Handlers

`fatal` log calls are also `@safe nothrow @nogc`. By default, the fatal handler throws a thread-local, recycled `FatalLogError` to avoid GC allocation.

If you want the process to exit immediately or panic instead of throwing, you can customize the handler by setting `coreFatalHandler` to `assertingFatalHandler` or `abortingFatalHandler`:

```d
import sparkles.base.logger : coreFatalHandler, assertingFatalHandler;

// Change the behavior of `fatal` logs to assert(0)
coreFatalHandler = &assertingFatalHandler;
```
