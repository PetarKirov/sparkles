// Shared instrumentation logger for the windowing feature demos (defined by
// the F01 spec, ../../../features/f01-first-pixel.md): one line per event on
// stderr in the format
//
//     <monotonic_us> <DEMO> <EVENT_KIND> key=value ...
//
// where <monotonic_us> is microseconds since `initInstrument` was called
// (core.time.MonoTime, so the clock is monotonic and immune to wall-clock
// jumps). Logging goes to stderr so a demo's stdout stays reserved for the
// `SKIP:` capability-gating contract.
module instrument;

import core.stdc.stdarg : va_end, va_list, va_start;
import core.stdc.stdio : fprintf, stderr, vfprintf;
import core.time : MonoTime;

private __gshared MonoTime g_t0;
private __gshared const(char)* g_demo = "demo";

/// Names the demo, starts the monotonic clock, and emits `init_start`.
/// Call this first, before any platform API call.
void initInstrument(const(char)* demoName) @nogc nothrow
{
    g_demo = demoName;
    g_t0 = MonoTime.currTime;
    emit("init_start");
}

/// Microseconds elapsed since `initInstrument`.
long nowUs() @nogc nothrow
{
    return (MonoTime.currTime - g_t0).total!"usecs";
}

/// Emit an event with no key=value payload.
void emit(scope const(char)* kind) @nogc nothrow
{
    fprintf(stderr, "%lld %s %s\n", nowUs(), g_demo, kind);
}

/// Emit an event with a printf-formatted `key=value ...` payload.
extern (C) void emitf(scope const(char)* kind, scope const(char)* fmt, ...) @nogc nothrow
{
    fprintf(stderr, "%lld %s %s ", nowUs(), g_demo, kind);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fprintf(stderr, "\n");
}
