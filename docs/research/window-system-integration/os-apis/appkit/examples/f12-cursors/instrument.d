// instrument.d — shared stderr instrumentation logger for the WSI scaffolds/demos.
// Defined by the F01 first-pixel demo (../../features/f01-first-pixel.md); the
// other demos copy this file verbatim.
//
// Line format (one event per line, to stderr):
//
//     <monotonic_us> <DEMO> <EVENT_KIND> key=value ...
//
// `<monotonic_us>` is microseconds since `instrInit` (core.time.MonoTime, so it
// is immune to wall-clock jumps). `<DEMO>` is a per-demo tag (e.g. "APPKIT").
// Everything after the event kind is a printf-formatted `key=value` payload.
module instrument;

import core.stdc.stdio : fprintf, fflush, stderr;
import core.time : MonoTime;

private __gshared MonoTime g_epoch;
private __gshared bool g_epochSet = false;
private __gshared const(char)* g_demoTag = "DEMO";

/// Set the demo tag and the monotonic epoch. Call first thing in `main`.
void instrInit(const(char)* demoTag) @trusted nothrow @nogc
{
    g_demoTag = demoTag;
    g_epoch = MonoTime.currTime;
    g_epochSet = true;
}

/// Microseconds since `instrInit` (lazily self-initializing).
ulong instrNowUs() @trusted nothrow @nogc
{
    if (!g_epochSet)
        instrInit(g_demoTag);
    return cast(ulong) (MonoTime.currTime - g_epoch).total!"usecs";
}

/// Emit one event line. `fmt`/`args` are an optional printf-style
/// `key=value ...` payload, e.g. `instr("resize", "size=%dx%d scale=%.1f", w, h, s)`.
void instr(Args...)(const(char)* eventKind, const(char)* fmt = null, Args args)
{
    immutable us = instrNowUs();
    if (fmt is null)
        fprintf(stderr, "%llu %s %s\n", us, g_demoTag, eventKind);
    else
    {
        fprintf(stderr, "%llu %s %s ", us, g_demoTag, eventKind);
        fprintf(stderr, fmt, args);
        fprintf(stderr, "\n");
    }
    fflush(stderr);
}
