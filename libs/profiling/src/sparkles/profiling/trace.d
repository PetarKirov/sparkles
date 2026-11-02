/**
A history of frames as Chrome trace event JSON (`PRF18`), the format
Perfetto (`ui.perfetto.dev`) and `chrome://tracing` open: a track of frames
and their CPU phases, a track of GPU scopes — on the CPU's timeline where they
were calibrated, after the frame's start where not — and instant events for
each frame's flags and its display.

Written through any output range, a field at a time.
*/
module sparkles.profiling.trace;

import core.time : Duration;
import std.range.primitives : put;

import sparkles.base.text : writeInteger;
import sparkles.profiling.frame : FrameFlags, FramePhase, FrameRecord, flagCount, flagName,
    phaseCount;

/// Track ids: the frames and their phases, the device, the display.
enum TraceTrack : ubyte
{
    cpu = 1,     ///
    gpu = 2,     ///
    display = 3, ///
}

/**
Writes `frames` (a range of `FrameRecord`, oldest first) to `w` as one
trace. `gpuNames[i]` names GPU scope `i`; `process` names the trace.
*/
void writeChromeTrace(Writer, Frames)(ref Writer w, Frames frames,
    scope const(string)[] gpuNames, string process = "sparkles")
{
    put(w, `{"displayTimeUnit":"ms","traceEvents":[`);
    bool first = true;
    void open()
    {
        put(w, first ? "\n" : ",\n");
        first = false;
    }
    void meta(string what, uint tid, string name)
    {
        open();
        put(w, `{"name":"`);
        put(w, what);
        put(w, `","ph":"M","pid":1,"tid":`);
        writeInteger(w, tid);
        put(w, `,"args":{"name":`);
        writeJsonString(w, name);
        put(w, `}}`);
    }
    meta("process_name", TraceTrack.cpu, process);
    meta("thread_name", TraceTrack.cpu, "CPU");
    meta("thread_name", TraceTrack.gpu, "GPU");
    meta("thread_name", TraceTrack.display, "Display");

    void span(uint tid, scope const(char)[] name, Duration start, Duration took,
        ulong frame, string cat)
    {
        open();
        put(w, `{"name":`);
        writeJsonString(w, name);
        put(w, `,"cat":"`);
        put(w, cat);
        put(w, `","ph":"X","pid":1,"tid":`);
        writeInteger(w, tid);
        put(w, `,"ts":`);
        writeMicros(w, start);
        put(w, `,"dur":`);
        writeMicros(w, took);
        put(w, `,"args":{"frame":`);
        writeInteger(w, frame);
        put(w, `}}`);
    }
    void instant(uint tid, scope const(char)[] name, Duration at, ulong frame)
    {
        open();
        put(w, `{"name":`);
        writeJsonString(w, name);
        put(w, `,"ph":"i","s":"t","pid":1,"tid":`);
        writeInteger(w, tid);
        put(w, `,"ts":`);
        writeMicros(w, at);
        put(w, `,"args":{"frame":`);
        writeInteger(w, frame);
        put(w, `}}`);
    }

    foreach (ref const FrameRecord r; frames)
    {
        Label label;
        put(label, "frame ");
        writeInteger(label, r.number);
        span(TraceTrack.cpu, label.text, r.start, r.cpu, r.number, "frame");
        static immutable string[phaseCount] phaseNames = [
            "wait", "build", "acquire", "record", "submit", "present", "rebuild",
        ];
        foreach (p; 0 .. phaseCount)
            if (r.phases[p].took > Duration.zero)
                span(TraceTrack.cpu, phaseNames[p], r.start + r.phases[p].start,
                    r.phases[p].took, r.number, "phase");
        foreach (ref s; r.scopes)
        {
            const name = s.name < gpuNames.length ? gpuNames[s.name] : "gpu";
            span(TraceTrack.gpu, name, s.calibrated ? s.start : r.start + s.start, s.took,
                r.number, s.calibrated ? "gpu" : "gpu-uncalibrated");
        }
        foreach (bit; 0 .. flagCount)
            if (r.flags & (1 << bit))
                instant(TraceTrack.cpu, flagName(bit), r.start, r.number);
        if (r.shownKnown)
            instant(TraceTrack.display, "shown", r.shown, r.number);
    }
    put(w, "\n]}\n");
}

// A duration in microseconds, to a tenth: `ts` and `dur` take fractions. A
// negative one (a calibrated scope a little before the run's origin) keeps
// its sign in front, as JSON needs: `-1.5`, not `-1.-5`.
private void writeMicros(Writer)(ref Writer w, Duration d)
{
    const h = d.total!"hnsecs";
    if (h < 0)
        put(w, '-');
    const ulong magnitude = h < 0 ? -cast(ulong) h : h;
    writeInteger(w, magnitude / 10);
    put(w, '.');
    writeInteger(w, magnitude % 10);
}

// A frame's name, written into a fixed buffer.
private struct Label
{
    char[32] buf;
    size_t n;

    void put(char c) @safe pure nothrow @nogc { buf[n++] = c; }
    void put(scope const(char)[] s) @safe pure nothrow @nogc
    {
        buf[n .. n + s.length] = s;
        n += s.length;
    }
    const(char)[] text() const return @safe pure nothrow @nogc => buf[0 .. n];
}

/// `s` as a JSON string: quotes, backslashes and control characters escaped.
void writeJsonString(Writer)(ref Writer w, scope const(char)[] s)
{
    static immutable hex = "0123456789abcdef";
    put(w, '"');
    foreach (char c; s)
    {
        if (c == '"' || c == '\\')
        {
            const char[2] e = ['\\', c];
            put(w, e[]);
        }
        else if (c < 0x20)
        {
            const char[6] e = ['\\', 'u', '0', '0', hex[c >> 4], hex[c & 0xf]];
            put(w, e[]);
        }
        else
        {
            const char[1] u = c;
            put(w, u[]);
        }
    }
    put(w, '"');
}

///
@("profiling.trace.writesChromeTraceEvents")
@system unittest
{
    import core.time : msecs, usecs;
    import std.algorithm.searching : canFind;
    import std.array : appender;
    import std.json : parseJSON;
    import sparkles.profiling.frame : GpuScope;
    import sparkles.profiling.history : FrameHistory;

    FrameHistory!4 h;
    FrameRecord r;
    r.number = 12;
    r.start = 100.msecs;
    r.cpu = 5.msecs;
    r.phases[FramePhase.record].start = 1.msecs;
    r.phases[FramePhase.record].took = 2500.usecs;
    r.flags = FrameFlags.rebuilt;
    r.addGpuScope(GpuScope(name: 1, calibrated: true, start: 103.msecs, took: 1.msecs));
    r.addGpuScope(GpuScope(name: 0, calibrated: true, start: -1500.usecs + 1.usecs / 2,
        took: 1.msecs));
    r.shown = 116.msecs;
    r.shownKnown = true;
    h.add(r);

    auto w = appender!string;
    writeChromeTrace(w, h[], ["frame", "canvas \"main\""]);
    const text = w[];
    const json = parseJSON(text);
    const events = json["traceEvents"].array;
    assert(events.length == 4 + 1 + 1 + 2 + 1 + 1, text);
    assert(text.canFind(`"cat":"gpu","ph":"X","pid":1,"tid":2,"ts":-1499.5,`), "a sign in front");
    assert(text.canFind(`{"name":"frame 12","cat":"frame","ph":"X","pid":1,"tid":1,"ts":100000.0,"dur":5000.0`));
    assert(text.canFind(`{"name":"record","cat":"phase","ph":"X","pid":1,"tid":1,"ts":101000.0,"dur":2500.0`));
    assert(text.canFind(`"name":"canvas \"main\"","cat":"gpu","ph":"X","pid":1,"tid":2,"ts":103000.0`));
    assert(text.canFind(`"name":"rebuilt","ph":"i"`));
    assert(text.canFind(`"name":"shown","ph":"i","s":"t","pid":1,"tid":3,"ts":116000.0`));
}
