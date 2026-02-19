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
import std.logger : Logger, LogLevel;

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
        import sparkles.core_cli.smallbuffer : SmallBuffer;
        import sparkles.core_cli.styled_template : writeStyled;
        import std.range.primitives : put;
        import std.stdio : stderr;

        auto nowTicks = MonoTime.currTime.ticks;
        auto prev = atomicExchange!(MemoryOrder.raw)(&prevTicks, nowTicks);

        SmallBuffer!(char, 8) timeBuf;
        auto dt = cast(DateTime) payload.timestamp;
        writeTimeHms(timeBuf, dt.hour, dt.minute, dt.second);

        auto w = () @trusted { return stderr.lockingTextWriter; }();
        writeLogPrefix!true(
            w,
            timeBuf[],
            durationFromTicks(nowTicks - startTicks),
            durationFromTicks(nowTicks - prev),
            payload.logLevel,
            payload.file,
            payload.line,
        );
        writeStyled(w, i"{bold $(payload.msg)}");
        put(w, '\n');
    }
}

/// Installs a [DeltaTimeLogger] as the process-wide logger.
///
/// Sets `std.logger.globalLogLevel` and replaces `std.logger.sharedLog` with a
/// new `DeltaTimeLogger` instance.
void initLogger(LogLevel level) @safe
{
    import std.logger : globalLogLevel, sharedLog;

    globalLogLevel = level;
    // @trusted: std.logger expects shared(Logger); DeltaTimeLogger manages its
    // own synchronization via atomics and does not expose mutable shared state.
    sharedLog = () @trusted { return cast(shared) new DeltaTimeLogger(level); }();
}

private:

@safe
void writeDuration(Writer)(ref Writer w, Duration d)
{
    import sparkles.core_cli.text_writers : writeInteger;
    import std.range.primitives : put;

    long ms = d.total!"msecs";
    bool negative = ms < 0;
    if (negative)
    {
        put(w, '-');
        ms = -ms;
    }

    if (ms < 1_000)
    {
        writeInteger(w, ms);
        put(w, 'm');
        put(w, 's');
        return;
    }

    if (ms < 60_000)
        return writeTenths(w, ms, 100, 's');
    if (ms < 3_600_000)
        return writeTenths(w, ms, 6_000, 'm');
    if (ms < 86_400_000)
        return writeTenths(w, ms, 360_000, 'h');
    return writeTenths(w, ms, 8_640_000, 'd');
}

string fmtDuration(Duration d) @safe
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 32) buf;
    writeDuration(buf, d);
    return buf[].idup;
}

@("fmtDuration.formatsMilliseconds")
@safe
unittest
{
    assert(dur!"msecs"(0).fmtDuration == "0ms");
    assert(dur!"msecs"(42).fmtDuration == "42ms");
    assert(dur!"msecs"(999).fmtDuration == "999ms");
}

@("fmtDuration.formatsSeconds")
@safe
unittest
{
    assert(dur!"msecs"(1_000).fmtDuration == "1.0s");
    assert(dur!"msecs"(5_500).fmtDuration == "5.5s");
    assert(dur!"msecs"(59_999).fmtDuration == "60.0s");
}

@("fmtDuration.formatsMinutes")
@safe
unittest
{
    assert(dur!"msecs"(60_000).fmtDuration == "1.0m");
    assert(dur!"msecs"(90_000).fmtDuration == "1.5m");
    assert(dur!"minutes"(45).fmtDuration == "45.0m");
}

@("fmtDuration.formatsHours")
@safe
unittest
{
    assert(dur!"hours"(1).fmtDuration == "1.0h");
    assert(dur!"msecs"(5_400_000).fmtDuration == "1.5h");
    assert(dur!"hours"(23).fmtDuration == "23.0h");
}

@("fmtDuration.formatsDays")
@safe
unittest
{
    assert(dur!"hours"(24).fmtDuration == "1.0d");
    assert(dur!"hours"(36).fmtDuration == "1.5d");
    assert(dur!"hours"(72).fmtDuration == "3.0d");
}

@safe
void writeTenths(Writer)(ref Writer w, long ms, long unitTenths, char suffix)
{
    import sparkles.core_cli.text_writers : writeInteger;
    import std.range.primitives : put;

    auto tenths = (ms + unitTenths / 2) / unitTenths;
    writeInteger(w, tenths / 10);
    put(w, '.');
    put(w, cast(char)('0' + tenths % 10));
    put(w, suffix);
}

@safe pure nothrow @nogc
Duration durationFromTicks(long ticks) =>
    dur!"hnsecs"(convClockFreq(ticks, MonoTime.ticksPerSecond, 10_000_000L));

@safe
void writeTimeHms(Writer)(ref Writer w, int hour, int minute, int second)
{
    import sparkles.core_cli.text_writers : writeInteger;
    import std.range.primitives : put;

    writePadded2(w, hour);
    put(w, ':');
    writePadded2(w, minute);
    put(w, ':');
    writePadded2(w, second);
}

@safe
void writePadded2(Writer)(ref Writer w, int value)
{
    import sparkles.core_cli.text_writers : writeInteger;
    import std.range.primitives : put;

    if (value < 10)
        put(w, '0');
    writeInteger(w, value);
}

@safe
void writeDurationPadded(Writer)(ref Writer w, Duration d, size_t width)
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;
    import std.range.primitives : put;

    SmallBuffer!(char, 16) buf;
    writeDuration(buf, d);
    auto text = buf[];
    put(w, text);
    if (text.length < width)
    {
        foreach (_; 0 .. width - text.length)
            put(w, ' ');
    }
}

@safe
void writeStyledLevel(bool colored = true, Writer)(ref Writer w, LogLevel level)
{
    import sparkles.core_cli.styled_template : writeStyled;

    switch (level)
    {
        case LogLevel.trace:    writeStyled!colored(w, i"{blue TRC}");     break;
        case LogLevel.info:     writeStyled!colored(w, i"{green INF}");    break;
        case LogLevel.warning:  writeStyled!colored(w, i"{yellow WRN}");   break;
        case LogLevel.error:    writeStyled!colored(w, i"{brightRed ERR}");      break;
        case LogLevel.critical: writeStyled!colored(w, i"{bold.red CRT}"); break;
        case LogLevel.fatal:    writeStyled!colored(w, i"{bold.red FTL}"); break;
        default: assert(0, "unexpected log level");
    }
}

@safe
void writeLogPrefix(bool colored = false, Writer)(
    ref Writer w,
    in char[] timeStr,
    Duration sinceStart,
    Duration sincePrev,
    LogLevel level,
    in char[] file,
    int line,
)
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;
    import sparkles.core_cli.styled_template : writeStyled;
    import std.path : baseName;

    SmallBuffer!(char, 16) startBuf;
    writeDurationPadded(startBuf, sinceStart, 5);
    SmallBuffer!(char, 16) prevBuf;
    writeDurationPadded(prevBuf, sincePrev, 5);
    auto loc = file.baseName;

    writeStyled!colored(w, i"{gray.dim [} {cyan $(timeStr)} {dim | Δt} {yellow $(startBuf[])} {dim | Δtᵢ} {yellow $(prevBuf[])} {dim |} ");
    writeStyledLevel!colored(w, level);
    writeStyled!colored(w, i" {gray.dim |}");
    static if (colored)
    {
        import sparkles.core_cli.source_uri : getEditor, resolveSourcePath, writeEditorUri;
        import sparkles.core_cli.ui.osc_link : oscLinkOpenSeq, oscLinkCloseSeq;
        import std.range.primitives : put;

        SmallBuffer!(char, 256) uriBuf;
        writeEditorUri(uriBuf, getEditor(), resolveSourcePath(file), line, 1);
        put(w, oscLinkOpenSeq(uri: uriBuf[]));
        writeStyled!colored(w, i" $(loc):$(line) ");
        put(w, oscLinkCloseSeq());
    }
    else
        writeStyled!colored(w, i" $(loc):$(line) ");
    writeStyled!colored(w, i"{gray.dim ]:} ");
}
