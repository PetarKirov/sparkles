/**
The logcat sink. In a NativeActivity stdout and stderr go nowhere, so every
process logger is replaced by one that writes `__android_log_write` lines under
the app's tag.
*/
module sparkles.android.log;

version (Android):

import std.logger : Logger;

import sparkles.base.buffer : SharedBuffer;
import sparkles.base.logger : CoreLogEntry, CoreLogger, LogLevel, sharedCoreLog;
import sparkles.base.text.writers : writeInteger;

// <android/log.h>
extern (C) int __android_log_write(
    int prio, const(char)* tag, const(char)* text) @nogc nothrow;

private enum int logPrioInfo = 4;
private enum int logPrioWarn = 5;
private enum int logPrioError = 6;

/**
Replace the process loggers (Phobos `sharedLog` and the IES `sharedCoreLog`)
with the logcat sink, tagged `tag`. Call after any CLI-driven logger setup —
this overrides that sink.
*/
void installLogcatSink(LogLevel level, string tag) @safe
{
    import std.logger : globalLogLevel, sharedLog;
    import sparkles.base.logger : coreGlobalLogLevel;

    globalLogLevel = level;
    coreGlobalLogLevel = level; // the IES wrappers filter on the core level
    auto logger = new shared LogcatLogger(level, tag);
    sharedLog = logger;
    sharedCoreLog = logger;
}

/// Write one line straight to logcat — for the moments before (or without)
/// a logger, such as a fatal startup error.
void logcatWrite(LogLevel level, string tag, scope const(char)[] message) @safe nothrow @nogc
{
    write(level, tag, message);
}

private final class LogcatLogger : CoreLogger
{
    private string tag;

    this(this Q)(LogLevel level, string tag) @safe
    {
        super(level);
        this.tag = tag;
    }

    override protected void writeLogMsg(ref Logger.LogEntry payload) @safe
    {
        const entry = CoreLogEntry(level: payload.logLevel, file: payload.file,
            line: payload.line);
        writeCoreLog(entry, payload.msg);
    }

    override protected void writeCoreLog(
        const ref CoreLogEntry entry,
        scope const(char)[] message,
    ) @safe nothrow @nogc
    {
        // file:line preserves the DeltaTimeLogger's most useful context.
        SharedBuffer!(char, 512) buf;
        buf ~= entry.file;
        buf ~= ':';
        writeInteger(buf, entry.line);
        buf ~= ": ";
        buf ~= message;
        write(entry.level, tag, buf[]);
    }
}

private void write(LogLevel level, string tag, scope const(char)[] message) @safe nothrow @nogc
{
    const prio = level >= LogLevel.error ? logPrioError
        : level >= LogLevel.warning ? logPrioWarn : logPrioInfo;

    // logcat wants NUL-terminated strings; neither slice carries one.
    SharedBuffer!(char, 32) z;
    z ~= tag;
    z ~= '\0';
    SharedBuffer!(char, 512) line;
    line ~= message;
    line ~= '\0';
    (() @trusted => __android_log_write(prio, z[].ptr, line[].ptr))();
}
