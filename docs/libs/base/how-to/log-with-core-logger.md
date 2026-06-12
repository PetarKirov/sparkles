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

```[Output:ansi]
[90m[ 15:22:40[39m | Δt [33m46.7µs[39m | Δtᵢ [33m46.7µs[39m | [90mTRC[39m | [2mbase_core_logger.d:14[22m ]: [1mApplication starting up[22m
[90m[ 15:22:40[39m | Δt [33m119.7µs[39m | Δtᵢ [33m72.9µs[39m | [32mINF[39m | [2mbase_core_logger.d:15[22m ]: [1mListening on port [32m8080[39m[22m
[90m[ 15:22:40[39m | Δt [33m167.3µs[39m | Δtᵢ [33m47.5µs[39m | [33mWRN[39m | [2mbase_core_logger.d:16[22m ]: [1mDisk usage above [33m80%[39m[22m
[90m[ 15:22:40[39m | Δt [33m212.2µs[39m | Δtᵢ [33m44.9µs[39m | [31mERR[39m | [2mbase_core_logger.d:17[22m ]: [1mConnection to [31mdatabase[39m lost[22m
[90m[ 15:22:40[39m | Δt [33m257.9µs[39m | Δtᵢ [33m45.7µs[39m | [1m[31mCRT[39m[22m | [2mbase_core_logger.d:18[22m ]: [1m[1m[31mOut of memory[39m[22m[22m
[90m[ 15:22:40[39m | Δt [33m315.2µs[39m | Δtᵢ [33m57.2µs[39m | [32mINF[39m | [2mbase_core_logger.d:23[22m ]: [1mReconnected to [32mdb-01.prod[39m:[36m5432[39m[22m
[90m[ 15:22:40[39m | Δt [33m361.1µs[39m | Δtᵢ [33m45.9µs[39m | [33mWRN[39m | [2mbase_core_logger.d:26[22m ]: [1mLatency spike: [33m[1m230ms[22m[39m on [2mdb-01.prod[22m[22m
```

## Advanced Customization: Fatal Handlers

`fatal` log calls are also `@safe nothrow @nogc`. By default, the fatal handler throws a thread-local, recycled `FatalLogError` to avoid GC allocation.

If you want the process to exit immediately or panic instead of throwing, you can customize the handler by setting `coreFatalHandler` to `assertingFatalHandler` or `abortingFatalHandler`:

```d
import sparkles.base.logger : coreFatalHandler, assertingFatalHandler;

// Change the behavior of `fatal` logs to assert(0)
coreFatalHandler = &assertingFatalHandler;
```
