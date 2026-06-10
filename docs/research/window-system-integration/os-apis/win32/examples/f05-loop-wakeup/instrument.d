// instrument.d — shared stderr instrumentation for the windowing feature demos.
//
// Implements the log contract from the F01 spec
// (../../../features/f01-first-pixel.md): one line per event, formatted as
//
//     <monotonic_us> <DEMO> <EVENT_KIND> key=value ...
//
// where <monotonic_us> is microseconds since instrumentInit() measured with
// core.time.MonoTime (a monotonic clock, so wall-clock jumps cannot corrupt
// deltas). Every fXX feature demo copies this file verbatim from the scaffold.
//
// Deliberately @nogc + nothrow: it must be callable from an extern(Windows)
// WndProc (which may not let a D exception unwind into OS code) and must not
// perturb the timings it measures with GC pauses.
module instrument;

import core.stdc.stdarg : va_end, va_list, va_start;
import core.stdc.stdio : fflush, fprintf, stderr, vfprintf;
import core.time : MonoTime;

private __gshared MonoTime startTime;
private __gshared const(char)* demoName = "demo";

/// Start the monotonic clock and set the `<DEMO>` field of every log line.
void instrumentInit(const(char)* name) nothrow @nogc
{
    startTime = MonoTime.currTime;
    demoName = name;
}

/// Microseconds elapsed since `instrumentInit`.
long nowUs() nothrow @nogc
{
    return (MonoTime.currTime - startTime).total!"usecs";
}

/// Log one event line: `<monotonic_us> <DEMO> ` + the printf expansion of
/// `fmt`, which starts with the EVENT_KIND followed by `key=value` pairs,
/// e.g. `logEvent("resize size=%dx%d scale=%d.%02d", w, h, si, sf)`.
extern (C) pragma(printf)
void logEvent(const(char)* fmt, ...) nothrow @nogc
{
    fprintf(stderr, "%lld %s ", nowUs(), demoName);
    va_list args;
    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args);
    fprintf(stderr, "\n");
    fflush(stderr); // demos can die mid-pump; never lose the tail of the log
}
