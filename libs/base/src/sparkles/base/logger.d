/**
Core Sparkles logging interface.

This module provides [CoreLogger], a [Logger](std.logger.Logger) subclass
for compatibility with Phobos, plus allocation-conscious IES wrappers that
route through the Sparkles-owned [sharedCoreLog] global.
*/
module sparkles.base.logger;

import core.atomic : MemoryOrder, atomicExchange, atomicLoad, atomicOp, atomicStore, cas;
import core.interpolation : InterpolationFooter, InterpolationHeader;
import core.stdc.stdio : FILE;
import core.time : Duration, MonoTime, convClockFreq, dur;

import std.datetime : DateTime;
public import std.logger : LogLevel;
import std.logger : Logger;

/**
Metadata captured for a Sparkles log call.
*/
struct CoreLogEntry
{
    /// Log severity.
    LogLevel level;

    /// Source file reported by the call site.
    string file;

    /// Source line reported by the call site.
    int line;

    /// Function name reported by the call site.
    string funcName;

    /// Pretty function name reported by the call site.
    string prettyFuncName;

    /// Module name reported by the call site.
    string moduleName;

    /// Monotonic clock ticks captured for this log call.
    long monotonicTicks;

    /// Wall-clock hour in local time.
    int hour;

    /// Wall-clock minute in local time.
    int minute;

    /// Wall-clock second in local time.
    int second;
}

/// Fatal-log policy hook.
alias CoreFatalHandler = void function(
    scope const ref CoreLogEntry entry,
    scope const(char)[] message,
) @safe nothrow @nogc;

/**
Base class for Sparkles loggers.

`CoreLogger` remains assignable to `std.logger.sharedLog`, while exposing a
`@safe nothrow @nogc` entry point used by the Sparkles module-level logging
wrappers.
*/
abstract class CoreLogger : Logger
{
    private shared LogLevel _coreLogLevel;

    this(LogLevel level) @safe
    {
        super(level);
        atomicStore!(MemoryOrder.raw)(_coreLogLevel, level);
    }

    /// Sparkles-specific filtering level used by the `@nogc` logging path.
    @property final LogLevel coreLogLevel() @safe nothrow @nogc
    {
        return atomicLoad!(MemoryOrder.raw)(_coreLogLevel);
    }

    /// ditto
    @property final void coreLogLevel(LogLevel level) @safe nothrow @nogc
    {
        atomicStore!(MemoryOrder.raw)(_coreLogLevel, level);
    }

    /**
    Writes a pre-rendered Sparkles log message if this logger and the global
    Sparkles filter both allow it.
    */
    final void forwardCoreLog(
        const ref CoreLogEntry entry,
        scope const(char)[] message,
    ) @safe nothrow @nogc
    {
        if (isCoreLoggingEnabled(entry.level, coreLogLevel, coreGlobalLogLevel))
            writeCoreLog(entry, message);
    }

    /**
    Writes a pre-rendered Sparkles log message.
    */
    protected abstract void writeCoreLog(
        const ref CoreLogEntry entry,
        scope const(char)[] message,
    ) @safe nothrow @nogc;
}

/// Error thrown by [throwingFatalHandler].
class FatalLogError : Error
{
    this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
        @safe pure nothrow @nogc
    {
        super(msg, file, line, next);
    }
}

private shared CoreLogger currentCoreLog;
private shared LogLevel currentCoreGlobalLogLevel = LogLevel.all;
private shared CoreFatalHandler currentCoreFatalHandler = &throwingFatalHandler;

/**
Gets or sets the process-wide Sparkles logger.
*/
@property shared(CoreLogger) sharedCoreLog() @safe nothrow @nogc
{
    return atomicLoad!(MemoryOrder.seq)(currentCoreLog);
}

/// ditto
@property void sharedCoreLog(shared(CoreLogger) logger) @safe nothrow @nogc
{
    atomicStore!(MemoryOrder.seq)(currentCoreLog, logger);
}

/**
Gets or sets the process-wide Sparkles log-level filter.
*/
@property LogLevel coreGlobalLogLevel() @safe nothrow @nogc
{
    return atomicLoad!(MemoryOrder.seq)(currentCoreGlobalLogLevel);
}

/// ditto
@property void coreGlobalLogLevel(LogLevel level) @safe nothrow @nogc
{
    atomicStore!(MemoryOrder.seq)(currentCoreGlobalLogLevel, level);
}

/**
Gets or sets the process-wide fatal-log handler.
*/
@property CoreFatalHandler coreFatalHandler() @safe nothrow @nogc
{
    auto handler = atomicLoad!(MemoryOrder.seq)(currentCoreFatalHandler);
    return handler is null ? &throwingFatalHandler : handler;
}

/// ditto
@property void coreFatalHandler(CoreFatalHandler handler) @safe nothrow @nogc
{
    if (handler is null)
        handler = &throwingFatalHandler;
    atomicStore!(MemoryOrder.seq)(currentCoreFatalHandler, handler);
}

/**
Fatal handler that throws [FatalLogError] from recycled storage.
*/
void throwingFatalHandler(
    scope const ref CoreLogEntry entry,
    scope const(char)[] message,
) @safe nothrow @nogc
{
    import sparkles.base.lifetime : recycledErrorInstance;

    () @trusted {
        throw recycledErrorInstance!FatalLogError(cast(string) message, entry.file, entry.line);
    }();
}

/**
Fatal handler that fails with an assertion.
*/
void assertingFatalHandler(
    scope const ref CoreLogEntry,
    scope const(char)[] message,
) @safe nothrow @nogc
{
    () @trusted nothrow @nogc { assert(0, cast(string) message); }();
}

/**
Fatal handler that aborts the process.
*/
void abortingFatalHandler(
    scope const ref CoreLogEntry,
    scope const(char)[],
) @safe nothrow @nogc
{
    import core.stdc.stdlib : abort;

    () @trusted { abort(); }();
}

/**
Thread-safe delta-time logger.

Writes formatted log lines to `stderr` in the format:
`[ HH:MM:SS | Δt <total> | Δtᵢ <delta> | <level> | <file>:<line> ]: <message>`.
*/
class DeltaTimeLogger : CoreLogger
{
    private immutable long startTicks;
    private shared long prevTicks;

    this(LogLevel level) @safe
    {
        super(level);
        startTicks = MonoTime.currTime.ticks;
        atomicStore!(MemoryOrder.raw)(prevTicks, startTicks);
    }

    override protected void writeLogMsg(ref Logger.LogEntry payload) @safe
    {
        auto nowTicks = MonoTime.currTime.ticks;
        auto dt = cast(DateTime) payload.timestamp;
        auto entry = CoreLogEntry(
            level: payload.logLevel,
            file: payload.file,
            line: payload.line,
            funcName: payload.funcName,
            prettyFuncName: payload.prettyFuncName,
            moduleName: payload.moduleName,
            monotonicTicks: nowTicks,
            hour: dt.hour,
            minute: dt.minute,
            second: dt.second,
        );

        writeCoreLog(entry, payload.msg);
    }

    override protected void writeCoreLog(
        const ref CoreLogEntry entry,
        scope const(char)[] message,
    ) @safe nothrow @nogc
    {
        import sparkles.base.smallbuffer : SmallBuffer;
        import sparkles.base.styled_template : writeStyled;
        import std.range.primitives : put;

        auto prev = atomicExchange!(MemoryOrder.raw)(&prevTicks, entry.monotonicTicks);

        SmallBuffer!(char, 8) timeBuf;
        writeTimeHms(timeBuf, entry.hour, entry.minute, entry.second);

        CFileWriter w = CFileWriter.stderr();
        writeLogPrefix!true(
            w,
            timeBuf[],
            durationFromTicks(entry.monotonicTicks - startTicks),
            durationFromTicks(entry.monotonicTicks - prev),
            entry.level,
            entry.file,
            entry.line,
        );
        writeStyled(w, i"{bold $(message)}");
        put(w, '\n');
        w.flush();
    }
}

/**
Installs a [DeltaTimeLogger] as both the Phobos and Sparkles global logger.
*/
void initLogger(LogLevel level) @safe
{
    import std.logger : globalLogLevel, sharedLog;

    globalLogLevel = level;
    coreGlobalLogLevel = level;

    auto logger = () @trusted { return cast(shared) new DeltaTimeLogger(level); }();
    sharedLog = cast(shared Logger) logger;
    sharedCoreLog = logger;
}

// ─────────────────────────────────────────────────────────────────────────────
// Styled IES Log Wrappers
// ─────────────────────────────────────────────────────────────────────────────

/**
Logs a styled IES message at the given log level.
*/
void log(int line = __LINE__, string file = __FILE__,
    string funcName = __FUNCTION__, string prettyFuncName = __PRETTY_FUNCTION__,
    string moduleName = __MODULE__, Args...)(
    LogLevel level,
    InterpolationHeader header,
    Args args,
    InterpolationFooter footer,
) @safe nothrow @nogc
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.base.styled_template : writeStyled;

    SmallBuffer!(char, 4 * 1024) message;
    writeStyled(message, header, args, footer);

    auto entry = makeCoreLogEntry!(line, file, funcName, prettyFuncName, moduleName)(level);

    if (auto logger = sharedCoreLog)
    {
        () @trusted nothrow @nogc {
            (cast(CoreLogger) logger).forwardCoreLog(entry, message[]);
        }();
    }

    if (level == LogLevel.fatal)
    {
        auto handler = coreFatalHandler;
        handler(entry, message[]);
    }
}

/// Logs a styled IES message at [LogLevel.trace].
void trace(int line = __LINE__, string file = __FILE__,
    string funcName = __FUNCTION__, string prettyFuncName = __PRETTY_FUNCTION__,
    string moduleName = __MODULE__, Args...)(
    InterpolationHeader header,
    Args args,
    InterpolationFooter footer,
) @safe nothrow @nogc
{
    log!(line, file, funcName, prettyFuncName, moduleName)(LogLevel.trace, header, args, footer);
}

/// Logs a styled IES message at [LogLevel.info].
void info(int line = __LINE__, string file = __FILE__,
    string funcName = __FUNCTION__, string prettyFuncName = __PRETTY_FUNCTION__,
    string moduleName = __MODULE__, Args...)(
    InterpolationHeader header,
    Args args,
    InterpolationFooter footer,
) @safe nothrow @nogc
{
    log!(line, file, funcName, prettyFuncName, moduleName)(LogLevel.info, header, args, footer);
}

/// Logs a styled IES message at [LogLevel.warning].
void warning(int line = __LINE__, string file = __FILE__,
    string funcName = __FUNCTION__, string prettyFuncName = __PRETTY_FUNCTION__,
    string moduleName = __MODULE__, Args...)(
    InterpolationHeader header,
    Args args,
    InterpolationFooter footer,
) @safe nothrow @nogc
{
    log!(line, file, funcName, prettyFuncName, moduleName)(LogLevel.warning, header, args, footer);
}

/// Logs a styled IES message at [LogLevel.error].
void error(int line = __LINE__, string file = __FILE__,
    string funcName = __FUNCTION__, string prettyFuncName = __PRETTY_FUNCTION__,
    string moduleName = __MODULE__, Args...)(
    InterpolationHeader header,
    Args args,
    InterpolationFooter footer,
) @safe nothrow @nogc
{
    log!(line, file, funcName, prettyFuncName, moduleName)(LogLevel.error, header, args, footer);
}

/// Logs a styled IES message at [LogLevel.critical].
void critical(int line = __LINE__, string file = __FILE__,
    string funcName = __FUNCTION__, string prettyFuncName = __PRETTY_FUNCTION__,
    string moduleName = __MODULE__, Args...)(
    InterpolationHeader header,
    Args args,
    InterpolationFooter footer,
) @safe nothrow @nogc
{
    log!(line, file, funcName, prettyFuncName, moduleName)(LogLevel.critical, header, args, footer);
}

/// Logs a styled IES message at [LogLevel.fatal].
void fatal(int line = __LINE__, string file = __FILE__,
    string funcName = __FUNCTION__, string prettyFuncName = __PRETTY_FUNCTION__,
    string moduleName = __MODULE__, Args...)(
    InterpolationHeader header,
    Args args,
    InterpolationFooter footer,
) @safe nothrow @nogc
{
    log!(line, file, funcName, prettyFuncName, moduleName)(LogLevel.fatal, header, args, footer);
}

private:

@safe pure nothrow @nogc
bool isCoreLoggingEnabled(LogLevel level, LogLevel loggerLevel, LogLevel globalLevel)
{
    return level >= globalLevel
        && level >= loggerLevel
        && level != LogLevel.off
        && globalLevel != LogLevel.off
        && loggerLevel != LogLevel.off;
}

CoreLogEntry makeCoreLogEntry(int line, string file, string funcName,
    string prettyFuncName, string moduleName)(
    LogLevel level,
) @safe nothrow @nogc
{
    auto hms = currentWallClockHms();
    return CoreLogEntry(
        level: level,
        file: file,
        line: line,
        funcName: funcName,
        prettyFuncName: prettyFuncName,
        moduleName: moduleName,
        monotonicTicks: MonoTime.currTime.ticks,
        hour: hms.hour,
        minute: hms.minute,
        second: hms.second,
    );
}

private struct WallClockHms
{
    int hour;
    int minute;
    int second;
}

WallClockHms currentWallClockHms() @safe nothrow @nogc
{
    import core.stdc.time : time, time_t, tm;

    time_t raw;
    time(&raw);

    version (Posix)
    {
        import core.sys.posix.time : localtime_r;

        tm parts;
        auto ok = () @trusted { return localtime_r(&raw, &parts); }();
        if (ok is null)
            return WallClockHms.init;
        return WallClockHms(parts.tm_hour, parts.tm_min, parts.tm_sec);
    }
    else
    {
        static assert(0, "Unsupported system");
    }
}

private struct CFileWriter
{
    FILE* file;

    static CFileWriter stderr() @safe nothrow @nogc
    {
        import core.stdc.stdio : stderr;

        return CFileWriter(stderr);
    }

    void put(scope const(char)[] data) @safe nothrow @nogc
    {
        fwriteAll(file, data);
    }

    void put(char c) @safe nothrow @nogc
    {
        char[1] buf = c;
        fwriteAll(file, buf[]);
    }

    void flush() @safe nothrow @nogc
    {
        import core.stdc.stdio : fflush;

        () @trusted { fflush(file); }();
    }
}

void fwriteAll(
    FILE* file,
    scope const(char)[] data,
) @safe nothrow @nogc
{
    import core.stdc.stdio : fwrite;

    size_t written = 0;
    while (written < data.length)
    {
        const remaining = data.length - written;
        auto n = () @trusted {
            return fwrite(data.ptr + written, char.sizeof, remaining, file);
        }();
        if (n == 0)
            return;
        written += n;
    }
}


@safe pure nothrow @nogc
Duration durationFromTicks(long ticks) =>
    dur!"hnsecs"(convClockFreq(ticks, MonoTime.ticksPerSecond, 10_000_000L));

void writeTimeHms(Writer)(ref Writer w, int hour, int minute, int second)
{
    import sparkles.base.text.writers : writeIntegerPadded;
    import std.range.primitives : put;

    writeIntegerPadded(w, hour, 2);
    put(w, ':');
    writeIntegerPadded(w, minute, 2);
    put(w, ':');
    writeIntegerPadded(w, second, 2);
}

void writeStyledLevel(bool colored = true, Writer)(ref Writer w, LogLevel level)
{
    import sparkles.base.styled_template : writeStyled;

    switch (level)
    {
        case LogLevel.trace:    writeStyled!colored(w, i"{gray TRC}");     break;
        case LogLevel.info:     writeStyled!colored(w, i"{green INF}");    break;
        case LogLevel.warning:  writeStyled!colored(w, i"{yellow WRN}");   break;
        case LogLevel.error:    writeStyled!colored(w, i"{red ERR}");      break;
        case LogLevel.critical: writeStyled!colored(w, i"{bold.red CRT}"); break;
        case LogLevel.fatal:    writeStyled!colored(w, i"{bold.red FTL}"); break;
        default:                writeStyled!colored(w, i"{dim ???}");      break;
    }
}

void writeLogPrefix(bool colored = false, Writer)(
    ref Writer w,
    const(char)[] timeStr,
    Duration sinceStart,
    Duration sincePrev,
    LogLevel level,
    scope const(char)[] file,
    int line,
)
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.base.styled_template : writeStyled;
    import sparkles.base.text.writers : writeDurationPadded;

    SmallBuffer!(char, 16) startBuf;
    writeDurationPadded(startBuf, sinceStart, 5);
    SmallBuffer!(char, 16) prevBuf;
    writeDurationPadded(prevBuf, sincePrev, 5);
    auto loc = baseNameSlice(file);

    writeStyled!colored(w, i"{gray [ $(timeStr)} | Δt {yellow $(startBuf[])} | Δtᵢ {yellow $(prevBuf[])} | ");
    writeStyledLevel!colored(w, level);
    writeStyled!colored(w, i" | {dim $(loc):$(line)} ]: ");
}

@safe pure nothrow @nogc
const(char)[] baseNameSlice(return scope const(char)[] file)
{
    size_t start = 0;
    foreach (i, c; file)
        if (c == '/' || c == '\\')
            start = i + 1;
    return file[start .. $];
}

private shared uint loggerGlobalTestLock;

void lockLoggerGlobalTests() @safe nothrow @nogc
{
    while (!cas(&loggerGlobalTestLock, 0u, 1u))
    {
    }
}

void unlockLoggerGlobalTests() @safe nothrow @nogc
{
    atomicStore!(MemoryOrder.rel)(loggerGlobalTestLock, 0u);
}

@("logger.coreWrappers.compileSafeNothrowNogc")
@safe nothrow @nogc
unittest
{
    lockLoggerGlobalTests();
    auto oldLogger = sharedCoreLog;
    auto oldLevel = coreGlobalLogLevel;
    auto oldFatalHandler = coreFatalHandler;
    scope (exit)
    {
        sharedCoreLog = oldLogger;
        coreGlobalLogLevel = oldLevel;
        coreFatalHandler = oldFatalHandler;
        unlockLoggerGlobalTests();
    }

    sharedCoreLog = null;
    coreGlobalLogLevel = LogLevel.trace;
    coreFatalHandler = &noopFatalHandler;

    trace(i"trace $(42)");
    info(i"info {green $(42)}");
    warning(i"warning");
    error(i"error");
    critical(i"critical");
    fatal(i"fatal");
    log(LogLevel.info, i"explicit $(true)");
}

private void noopFatalHandler(
    scope const ref CoreLogEntry,
    scope const(char)[],
) @safe nothrow @nogc
{
}

private final class RecordingCoreLogger : CoreLogger
{
    CoreLogEntry lastEntry;
    char[512] lastMessage;
    size_t lastMessageLength;
    uint writeCount;

    this(LogLevel level) @safe
    {
        super(level);
    }

    override protected void writeCoreLog(
        const ref CoreLogEntry entry,
        scope const(char)[] message,
    ) @safe nothrow @nogc
    {
        lastEntry = entry;
        lastMessageLength = message.length < lastMessage.length
            ? message.length
            : lastMessage.length;
        lastMessage[0 .. lastMessageLength] = message[0 .. lastMessageLength];
        writeCount++;
    }

    override protected void writeLogMsg(ref Logger.LogEntry) @safe
    {
    }

    const(char)[] message() const @safe nothrow @nogc
    {
        return lastMessage[0 .. lastMessageLength];
    }
}

@("logger.coreWrappers.metadataAndFiltering")
@safe
unittest
{
    lockLoggerGlobalTests();
    auto oldLogger = sharedCoreLog;
    auto oldLevel = coreGlobalLogLevel;
    auto oldFatalHandler = coreFatalHandler;
    scope (exit)
    {
        sharedCoreLog = oldLogger;
        coreGlobalLogLevel = oldLevel;
        coreFatalHandler = oldFatalHandler;
        unlockLoggerGlobalTests();
    }

    auto logger = new RecordingCoreLogger(LogLevel.trace);
    auto sharedLogger = () @trusted { return cast(shared) logger; }();
    sharedCoreLog = sharedLogger;
    coreGlobalLogLevel = LogLevel.trace;
    coreFatalHandler = &noopFatalHandler;

    info!(123, "logger_test.d", "fn", "pretty fn", "sparkles.test")(i"{green ok} $(42)");
    assert(logger.writeCount == 1);
    assert(logger.lastEntry.level == LogLevel.info);
    assert(logger.lastEntry.file == "logger_test.d");
    assert(logger.lastEntry.line == 123);
    assert(logger.lastEntry.funcName == "fn");
    assert(logger.lastEntry.prettyFuncName == "pretty fn");
    assert(logger.lastEntry.moduleName == "sparkles.test");
    assert(logger.message == "\x1b[32mok\x1b[39m 42");

    logger.coreLogLevel = LogLevel.error;
    info(i"filtered");
    assert(logger.writeCount == 1);

    error(i"visible");
    assert(logger.writeCount == 2);

    coreGlobalLogLevel = LogLevel.fatal;
    error(i"globally filtered");
    assert(logger.writeCount == 2);
}

private shared uint fatalHandlerCallCount;

void countingFatalHandler(
    scope const ref CoreLogEntry,
    scope const(char)[],
) @safe nothrow @nogc
{
    atomicOp!"+="(fatalHandlerCallCount, 1);
}

@("logger.coreWrappers.fatalHandler")
@safe
unittest
{
    lockLoggerGlobalTests();
    auto oldLogger = sharedCoreLog;
    auto oldLevel = coreGlobalLogLevel;
    auto oldFatalHandler = coreFatalHandler;
    scope (exit)
    {
        sharedCoreLog = oldLogger;
        coreGlobalLogLevel = oldLevel;
        coreFatalHandler = oldFatalHandler;
        unlockLoggerGlobalTests();
    }

    fatalHandlerCallCount = 0;
    sharedCoreLog = null;
    coreGlobalLogLevel = LogLevel.trace;
    coreFatalHandler = &countingFatalHandler;

    fatal(i"fatal message");
    assert(atomicLoad(fatalHandlerCallCount) == 1);
}

@("logger.throwingFatalHandler.throws")
@system
unittest
{
    import std.exception : assertThrown;

    lockLoggerGlobalTests();
    auto oldLogger = sharedCoreLog;
    auto oldFatalHandler = coreFatalHandler;
    scope (exit)
    {
        sharedCoreLog = oldLogger;
        coreFatalHandler = oldFatalHandler;
        unlockLoggerGlobalTests();
    }

    sharedCoreLog = null;
    coreFatalHandler = &throwingFatalHandler;

    assertThrown!FatalLogError(fatal!(456, "fatal_file.d")(i"boom"));
}

@("logger.sharedCoreLog.atomicAccessors")
@safe
unittest
{
    lockLoggerGlobalTests();
    auto oldLogger = sharedCoreLog;
    auto oldLevel = coreGlobalLogLevel;
    scope (exit)
    {
        sharedCoreLog = oldLogger;
        coreGlobalLogLevel = oldLevel;
        unlockLoggerGlobalTests();
    }

    auto logger = new RecordingCoreLogger(LogLevel.warning);
    auto sharedLogger = () @trusted { return cast(shared) logger; }();
    sharedCoreLog = sharedLogger;
    coreGlobalLogLevel = LogLevel.error;

    assert(sharedCoreLog is sharedLogger);
    assert(coreGlobalLogLevel == LogLevel.error);
}

@("logger.deltaTimeLogger.stdLoggerCompatible")
@safe
unittest
{
    import std.logger : sharedLog;

    lockLoggerGlobalTests();
    auto oldSharedLog = sharedLog;
    auto oldCoreLog = sharedCoreLog;
    scope (exit)
    {
        sharedLog = oldSharedLog;
        sharedCoreLog = oldCoreLog;
        unlockLoggerGlobalTests();
    }

    auto logger = () @trusted { return cast(shared) new DeltaTimeLogger(LogLevel.info); }();
    sharedLog = cast(shared Logger) logger;
    sharedCoreLog = logger;

    assert(sharedLog !is null);
    assert(sharedCoreLog is logger);
}
