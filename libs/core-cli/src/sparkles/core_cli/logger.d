/**
Delta-time-prefixed logger for CLI output.

Provides [DeltaTimeLogger], a [Logger](std.logger.Logger) subclass that
prints formatted log lines with wall-clock time, elapsed time since start,
and elapsed time since the previous log entry. Use [initLogger] to install
it as the global logger.
*/
module sparkles.core_cli.logger;

import core.atomic : MemoryOrder, atomicExchange, atomicStore;
import core.time : Duration, MonoTime, convClockFreq, dur;

import std.datetime : DateTime;
import std.logger : globalLogLevel, Logger, LogLevel, sharedLog;
import std.stdio : stderr;

import sparkles.core_cli.smallbuffer : SmallBuffer;
import sparkles.core_cli.styled_template : writeStyled;
import sparkles.core_cli.text_writers : OutputSpan, OutputSpanWriter, writeInteger, writeTimeHms;

/// Thread-safe delta-time logger.
///
/// Writes formatted log lines to `stderr` in the format:
/// `[ HH:MM:SS | Δt <total> | Δtᵢ <delta> | <level> | <file>:<line> ]: <message>`
///
/// Time deltas are tracked via `core.atomic` with relaxed memory ordering,
/// making this class safe to use as a `shared` global logger.
class DeltaTimeLogger : Logger
{
    private immutable long startTicks;
    private shared long prevTicks;

    this(LogLevel level) @safe
    {
        super(level);
        startTicks = MonoTime.currTime.ticks;
        atomicStore!(MemoryOrder.raw)(prevTicks, startTicks);
    }

    override void writeLogMsg(ref Logger.LogEntry payload) @safe
    {
        auto nowTicks = MonoTime.currTime.ticks;
        auto prev = atomicExchange!(MemoryOrder.raw)(&prevTicks, nowTicks);

        auto w = () @trusted { return stderr.lockingTextWriter; }();
        writeLogPrefix!true(
            w,
            cast(DateTime) payload.timestamp,
            durationFromTicks(nowTicks - startTicks),
            durationFromTicks(nowTicks - prev),
            payload.logLevel,
            payload.file,
            payload.line,
        );
        writeStyled(w, i"{bold $(payload.msg)\n}");
    }
}

/// Installs a [DeltaTimeLogger] as the process-wide logger.
///
/// Sets `std.logger.globalLogLevel` and replaces `std.logger.sharedLog` with a
/// new `DeltaTimeLogger` instance.
void initLogger(LogLevel level) @safe
{
    globalLogLevel = level;
    // @trusted: std.logger expects shared(Logger); DeltaTimeLogger manages its
    // own synchronization via atomics and does not expose mutable shared state.
    sharedLog = () @trusted { return cast(shared) new DeltaTimeLogger(level); }();
}

private:

@safe
OutputSpan writeLogPrefix(bool colored = false, Writer)(
    ref Writer w,
    DateTime timestamp,
    Duration sinceStart,
    Duration sincePrev,
    LogLevel level,
    in char[] file,
    int line,
)
{
    SmallBuffer!(char, 512) tempBuffer;
    auto timeSpan = writeTimeHms(tempBuffer, timestamp.timeOfDay);
    auto sinceStartSpan = writeDurationPadded(tempBuffer, sinceStart, 5);
    auto sincePrevSpan = writeDurationPadded(tempBuffer, sincePrev, 5);
    auto levelSpan = writeStyledLevel!colored(tempBuffer, level);
    auto locationSpan = writeLogLocation!colored(tempBuffer, file, line);

    auto writer = OutputSpanWriter!Writer(w);
    return writeStyled!colored(writer,
        i"{dim [ {cyan $(timeSpan[tempBuffer])} | Δt {yellow $(sinceStartSpan[tempBuffer])} | Δtᵢ {yellow $(sincePrevSpan[tempBuffer])} | }$(levelSpan[tempBuffer]){dim  | $(locationSpan[tempBuffer]) ]:} ");
}

/+

    return writer.writeComponent(
        Link(
            uri: EditorUri(editor: getEditor(), file),
            text: Text(i"$(file.baseName):$(line)")
        )
    );
+/

@safe
OutputSpan writeLogLocation(bool colored = false, Writer)(
    ref Writer w,
    in char[] file,
    int line,
)
{
    import sparkles.core_cli.source_uri : getEditor, resolveSourcePath, writeEditorUri;
    import sparkles.core_cli.ui.osc_link : oscLinkCloseSeq, oscLinkOpenSeq;
    import std.path : baseName;

    auto writer = OutputSpanWriter!Writer(w);

    static if (colored)
    {
        SmallBuffer!(char, 256) uriBuf;
        uriBuf.writeEditorUri(getEditor(), resolveSourcePath(file), line, 1);
        writer.put(oscLinkOpenSeq(uri: uriBuf[]));
    }

    writer.writeStyled(i"$(file.baseName):$(line)");

    static if (colored)
        writer.put(oscLinkCloseSeq());

    return writer.release();
}

@safe
OutputSpan writeStyledLevel(bool colored = true, Writer)(ref Writer w, LogLevel level)
{
    switch (level)
    {
        case LogLevel.trace:    return writeStyled!colored(w, i"{blue TRC}");
        case LogLevel.info:     return writeStyled!colored(w, i"{green INF}");
        case LogLevel.warning:  return writeStyled!colored(w, i"{yellow WRN}");
        case LogLevel.error:    return writeStyled!colored(w, i"{brightRed ERR}");
        case LogLevel.critical: return writeStyled!colored(w, i"{bold.red CRT}");
        case LogLevel.fatal:    return writeStyled!colored(w, i"{bold.red FTL}");
        default: assert(0, "unexpected log level");
    }
}

@safe
OutputSpan writeDurationPadded(Writer)(ref Writer w, Duration d, size_t width)
{
    auto writer = OutputSpanWriter!Writer(w);
    auto durationSpan = writeDuration(writer, d);
    if (durationSpan.length < width)
    {
        foreach (_; 0 .. width - durationSpan.length)
            writer.put(' ');
    }
    return writer.release();
}

@safe
OutputSpan writeDuration(Writer)(ref Writer w, Duration d)
{
    auto writer = OutputSpanWriter!Writer(w);

    if (d.isNegative)
    {
        writer.put('-');
        d = -d;
    }

    auto s = d.split!("days", "hours", "minutes", "seconds", "msecs");

    if (s.days > 0)
        writeRoundedTenths(writer, d.total!"minutes", 24 * 60, 'd');
    else if (s.hours > 0)
        writeRoundedTenths(writer, d.total!"seconds", 3_600, 'h');
    else if (s.minutes > 0)
        writeRoundedTenths(writer, d.total!"seconds", 60, 'm');
    else if (s.seconds > 0)
        writeRoundedTenths(writer, d.total!"msecs", 1_000, 's');
    else
    {
        writeInteger(writer, s.msecs);
        writer.put('m');
        writer.put('s');
    }

    return writer.release();
}

@safe
OutputSpan writeRoundedTenths(Writer)(ref Writer w, long total, long unitSize, char suffix)
{
    auto writer = OutputSpanWriter!Writer(w);
    long tenths = (total * 10 + unitSize / 2) / unitSize;
    writeInteger(writer, tenths / 10);
    writer.put('.');
    writer.put(cast(char)('0' + tenths % 10));
    writer.put(suffix);
    return writer.release();
}

@safe pure nothrow @nogc
Duration durationFromTicks(long ticks) =>
    dur!"hnsecs"(convClockFreq(ticks, MonoTime.ticksPerSecond, 10_000_000L));
