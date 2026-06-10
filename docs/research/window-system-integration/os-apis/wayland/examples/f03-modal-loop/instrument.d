// Shared instrumentation for the windowing demos (see features/f01-first-pixel.md
// § Instrumentation). Every demo logs one line per event to **stderr** in the
// format
//
//     <monotonic_us> <DEMO> <EVENT_KIND> key=value ...
//
// where `<monotonic_us>` is microseconds since `instrInit` (core.time.MonoTime,
// so the clock is monotonic and immune to wall-clock jumps). stderr is chosen so
// the lines interleave with libwayland's `WAYLAND_DEBUG=1` protocol trace (also
// stderr) — the combined stream is the evidence the findings docs quote.
//
// This file is the canonical copy; other demo packages copy it verbatim.
// Everything is `nothrow @nogc` so event-loop callbacks (which platform shims
// commonly stamp `nothrow @nogc`, e.g. via ImportC `#pragma attribute`) can log
// without relaxing their attributes.
//
// Conventions:
//   - `instrStep` is emitted immediately *after* the named API call returns, so
//     the delta between consecutive `step` lines is the cost of the later call.
//   - The mandatory event kinds are `init_start`, `step name=<api>`,
//     `window_created`, `first_configure`, `first_pixel_presented`,
//     `resize size=WxH scale=S`, `frame_callback t=..`, `close_requested`.
//     Demos may add extra kinds (e.g. `configure serial=N size=WxH` for F02).
module instrument;

import core.stdc.stdio : fprintf, fputc, stderr;
import core.time : MonoTime;

nothrow @nogc @system:

private __gshared MonoTime g_t0;
private __gshared const(char)* g_demo = "demo";

/// Record the process epoch and emit `init_start`. Call first thing in `main`.
void instrInit(const(char)* demoName)
{
    g_t0 = MonoTime.currTime;
    g_demo = demoName;
    instrEvent("init_start");
}

/// Microseconds elapsed since `instrInit` (the timestamp every line carries).
long instrNowUs()
{
    return (MonoTime.currTime - g_t0).total!"usecs";
}

/// Core emitter: `<monotonic_us> <DEMO> <kind>` plus an optional
/// printf-formatted `key=value ...` tail.
void instrEvent(Args...)(const(char)* kind, const(char)* fmt = null, Args args)
{
    fprintf(stderr, "%lld %s %s", instrNowUs(), g_demo, kind);
    if (fmt !is null)
    {
        fputc(' ', stderr);
        fprintf(stderr, fmt, args);
    }
    fputc('\n', stderr);
}

/// One initialization API call completed (emit right after the call returns).
void instrStep(const(char)* api)
{
    instrEvent("step", "name=%s", api);
}

/// All window objects exist client-side (nothing is on screen yet).
void instrWindowCreated()
{
    instrEvent("window_created");
}

/// The first server-driven configure/geometry negotiation completed.
void instrFirstConfigure()
{
    instrEvent("first_configure");
}

/// The platform confirmed the first software-drawn frame is presented.
void instrFirstPixelPresented()
{
    instrEvent("first_pixel_presented");
}

/// The window size (and/or scale) changed.
void instrResize(int width, int height, int scale)
{
    instrEvent("resize", "size=%dx%d scale=%d", width, height, scale);
}

/// A frame/vsync callback fired; `t` is the platform's presentation-time hint.
void instrFrameCallback(uint t)
{
    instrEvent("frame_callback", "t=%u", t);
}

/// The user/compositor asked the window to close.
void instrCloseRequested()
{
    instrEvent("close_requested");
}
