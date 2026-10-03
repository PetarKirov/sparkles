/**
The terminal's log seam (terminal `TPG7`): raylib's own `TraceLog` output,
routed into `sparkles.base.logger` so it lands in the same ring, file and
logcat/stderr sink as everything else.

Hand [routeTraceLog] to the host as its `RunConfig.traceSink` — installed
before the window opens, so the creation chatter is caught.

What the terminal logs is metadata only: never a byte the user typed, pasted
or copied (`TPG6`). The test below holds the component to that.
*/
module sparkles.terminal_view.log;

import core.stdc.stdarg : va_list;

import sparkles.base.logger : LogLevel;

/**
raylib's trace-log callback, bridged into the core logger: the line is
rendered into a stack buffer and logged as `raylib: <text>`, at the matching
level — trace and debug at `trace`, raylib's fatal at `critical` (raylib ends
the process itself; the logger's fatal handler must not race it).
*/
extern (C) void routeTraceLog(int level, const(char)* text, va_list args) @nogc nothrow
{
    import core.stdc.stdio : vsnprintf;
    import sparkles.base.logger : coreLogEnabled, log;

    const coreLevel = coreLevelOf(level);
    if (!coreLogEnabled(coreLevel))
        return;

    char[1024] buf = void;
    const written = () @trusted { return vsnprintf(buf.ptr, buf.length, text, args); }();
    if (written <= 0)
        return;
    const len = written < cast(int) buf.length ? cast(size_t) written : buf.length - 1;
    const msg = () @trusted { return cast(const(char)[]) buf[0 .. len]; }();

    // A face whose glyphs overshoot the requested size warns once per glyph
    // — thousands of lines that buried the log page. They become one line
    // with a count, written when the next message (the load's summary)
    // arrives.
    if (isTallGlyphWarning(msg))
    {
        if (tallGlyphs++ == 0)
        {
            // `[0x2320] 18 > 17`: the code point and the sizes, not the phrase.
            const sample = tallGlyphSample(msg, firstTall[]);
            firstTallLen = sample.length;
        }
        return;
    }
    if (tallGlyphs)
    {
        const first = firstTall[0 .. firstTallLen];
        const n = tallGlyphs;
        log(LogLevel.info, i"raylib: FONT: $(n) glyphs taller than asked (first $(first))");
        tallGlyphs = 0;
    }
    log(coreLevel, i"raylib: $(msg)");
}

// The run of glyph-height warnings `routeTraceLog` is collapsing (per thread:
// raylib loads fonts on the render thread).
private size_t tallGlyphs;
private char[96] firstTall;
private size_t firstTallLen;

/// Whether `msg` is raylib's per-glyph "taller than requested" warning.
bool isTallGlyphWarning(scope const(char)[] msg) @safe pure nothrow @nogc
{
    import std.algorithm.searching : canFind;

    return msg.canFind("Glyph height is bigger than requested font size");
}

/// The warning's code point and sizes (`[0x2573] 50 > 48`), written into
/// `buf`; what fits of them.
const(char)[] tallGlyphSample(scope const(char)[] msg, return scope char[] buf)
    @safe pure nothrow @nogc
{
    // Byte scans: `std.string`'s decode and may throw.
    static ptrdiff_t indexOf(scope const(char)[] s, char c)
    {
        foreach (i, x; s)
            if (x == c)
                return i;
        return -1;
    }

    static ptrdiff_t lastIndexOf(scope const(char)[] s, string pat)
    {
        foreach_reverse (i; 0 .. s.length >= pat.length ? s.length - pat.length + 1 : 0)
            if (s[i .. i + pat.length] == pat)
                return i;
        return -1;
    }

    size_t n;
    void put(scope const(char)[] s)
    {
        const k = s.length < buf.length - n ? s.length : buf.length - n;
        buf[n .. n + k] = s[0 .. k];
        n += k;
    }

    const open = indexOf(msg, '['), close = indexOf(msg, ']');
    if (open >= 0 && close > open)
        put(msg[open .. close + 1]);
    const sizes = lastIndexOf(msg, ": ");
    if (sizes >= 0)
    {
        put(" ");
        put(msg[sizes + 2 .. $]);
    }
    return buf[0 .. n];
}

@("terminal_view.log.tallGlyphWarnings")
@safe pure nothrow @nogc unittest
{
    enum warning = "FONT: [0x2573] Glyph height is bigger than requested font size: 50 > 48";
    assert(isTallGlyphWarning(warning));
    assert(!isTallGlyphWarning("FONT: Requested codepoints glyphs found: [2264/8480]"));
    char[32] buf;
    assert(tallGlyphSample(warning, buf[]) == "[0x2573] 50 > 48");
}

/// raylib's `TraceLogLevel` numbering as a core [LogLevel].
LogLevel coreLevelOf(int raylibLevel) @safe pure nothrow @nogc
{
    import raylib : TraceLogLevel;

    switch (raylibLevel)
    {
        case TraceLogLevel.LOG_INFO:    return LogLevel.info;
        case TraceLogLevel.LOG_WARNING: return LogLevel.warning;
        case TraceLogLevel.LOG_ERROR:   return LogLevel.error;
        case TraceLogLevel.LOG_FATAL:   return LogLevel.critical;
        default:                        return LogLevel.trace;
    }
}

///
@("terminal_view.log.coreLevelOf")
@safe pure nothrow @nogc unittest
{
    import raylib : TraceLogLevel;

    assert(coreLevelOf(TraceLogLevel.LOG_DEBUG) == LogLevel.trace);
    assert(coreLevelOf(TraceLogLevel.LOG_INFO) == LogLevel.info);
    assert(coreLevelOf(TraceLogLevel.LOG_WARNING) == LogLevel.warning);
    assert(coreLevelOf(TraceLogLevel.LOG_FATAL) == LogLevel.critical);
}

/*
The secrets-stay-put oracle (`TPG6`): with the ring and the file recording
everything down to `trace`, a marker is typed into a live pane and another
pasted; both reach the screen (so the input paths really ran) and neither
reaches the ring or the file — while raylib's chatter and the build info do
(so the log was really listening).
*/
@("terminal_view.log.typedAndPastedTextNeverReachesTheLog")
@system unittest
{
    import core.thread : Thread;
    import core.time : msecs;
    import std.algorithm.searching : canFind;
    import std.conv : text;
    import std.file : exists, readText, rmdirRecurse, tempDir;
    import std.logger : sharedLog;
    import std.path : buildPath;
    import std.process : thisProcessID;

    import raylib : SetTraceLogCallback, TraceLog, TraceLogLevel;

    import sparkles.base.log_sinks : installFileLog, installRingLog, RingLogRecord;
    import sparkles.base.logger : coreGlobalLogLevel, sharedCoreLog;
    import sparkles.input : Key, KeyEvent;
    import sparkles.terminal_view.component : TerminalView, TerminalViewOptions;
    import sparkles.terminal_view.core : logBuildInfo;
    import sparkles.terminal_view.input : ExitBehavior;

    enum typed = "TYPEDMARKER7F3A";
    enum pasted = "PASTEDMARKER9C2E";

    auto oldCore = sharedCoreLog;
    auto oldShared = sharedLog;
    auto oldLevel = coreGlobalLogLevel;
    const dir = buildPath(tempDir, text("sparkles-terminal-log-", thisProcessID));
    scope (exit)
    {
        sharedCoreLog = oldCore;
        sharedLog = oldShared;
        coreGlobalLogLevel = oldLevel;
        SetTraceLogCallback(null);
        if (dir.exists)
            rmdirRecurse(dir);
    }

    sharedCoreLog = null;
    coreGlobalLogLevel = LogLevel.trace;
    auto file = installFileLog(buildPath(dir, "terminal.log"));
    auto ring = installRingLog(capacity: 1024);
    SetTraceLogCallback(&routeTraceLog);

    static immutable(char)*[2] argv = ["cat", null];
    static immutable(char)*[2] env = ["PATH=/usr/bin:/bin", null];
    auto tv = new TerminalView; // far larger than a test thread's stack
    tv.opts = TerminalViewOptions(
        program: "/bin/cat",
        argv: cast(const(char)*[]) argv[],
        env: cast(const(char)*[]) env[],
        exitBehavior: ExitBehavior.hold,
    );
    assert(tv.openCore(80, 4, 0, 0), "the pty and cat spawned");
    scope (exit) tv.close();

    foreach (char c; typed)
        tv.sendKey(KeyEvent(key: Key.char_, ch: c));
    tv.sendPaste(pasted);
    foreach (_; 0 .. 200)
    {
        tv.pump();
        const screen = tv.screenText();
        if (screen.canFind(typed) && screen.canFind(pasted))
            break;
        Thread.sleep(10.msecs);
    }
    const screen = tv.screenText();
    assert(screen.canFind(typed) && screen.canFind(pasted), screen);

    logBuildInfo();
    TraceLog(TraceLogLevel.LOG_WARNING, "probe %d", 42);
    file.close();

    string logged;
    ring.each((scope const ref RingLogRecord r) { logged ~= r.message; logged ~= '\n'; });
    assert(logged.canFind("raylib: probe 42"), logged);
    assert(logged.canFind("ghostty-vt"), logged);
    const onDisk = readText(file.path);
    assert(onDisk.canFind("raylib: probe 42"), onDisk);

    foreach (marker; [typed, pasted])
    {
        assert(!logged.canFind(marker), "the ring holds " ~ marker);
        assert(!onDisk.canFind(marker), "the file holds " ~ marker);
    }
}
