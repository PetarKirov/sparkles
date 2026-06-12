# Log through `CoreLogger`

Use `CoreLogger` when Sparkles code needs `std.logger` compatibility and a
Sparkles logging path that can be called from `@safe nothrow @nogc` code.

## Capture Sparkles log messages

This example installs a tiny logger that captures the rendered Sparkles
message. Real applications usually call `initLogger(LogLevel.info)`, which
installs `DeltaTimeLogger` as both `std.logger.sharedLog` and
`sparkles.base.logger.sharedCoreLog`.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "base_core_logger"
    dependency "sparkles:base" version="*"
+/
import std.logger : Logger;
import std.stdio : writeln;

import sparkles.base.logger :
    CoreLogEntry, CoreLogger, LogLevel, coreGlobalLogLevel, info, sharedCoreLog;

final class CaptureLogger : CoreLogger
{
    LogLevel lastLevel;
    char[128] storage;
    size_t length;

    this() @safe
    {
        super(LogLevel.trace);
    }

    override protected void writeCoreLog(
        const ref CoreLogEntry entry,
        scope const(char)[] message,
    ) @safe nothrow @nogc
    {
        lastLevel = entry.level;
        length = message.length < storage.length ? message.length : storage.length;
        storage[0 .. length] = message[0 .. length];
    }

    override protected void writeLogMsg(ref Logger.LogEntry) @safe
    {
    }

    const(char)[] text() const @safe nothrow @nogc
    {
        return storage[0 .. length];
    }
}

void main()
{
    auto logger = new CaptureLogger;
    sharedCoreLog = cast(shared) logger;
    coreGlobalLogLevel = LogLevel.trace;

    immutable host = "db-01";
    info(i"connected to $(host)");

    writeln(logger.lastLevel);
    writeln(logger.text);
}
```

```[Output]
info
connected to db-01
```

## Fatal handlers

`fatal` is also `@safe nothrow @nogc`. Its default handler throws a
recycled `FatalLogError`. Swap `coreFatalHandler` to
`assertingFatalHandler` or `abortingFatalHandler` when a process should
fail by assertion or abort instead.
