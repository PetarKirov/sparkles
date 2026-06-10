// X11 F05 demo — loop wakeup & external fds (../../../features/f05-loop-wakeup.md).
// Built on the scaffold (../scaffold/app.d): same ImportC binding style, same
// poll(2)-driven readiness loop, same instrument.d event log.
//
// What it measures (F05 requirements 1-3):
//
//   * Mechanism A (`mech=clientmessage`): a second thread with its OWN
//     Display* connection injects a ClientMessage into the main window via
//     XSendEvent + XFlush. This is the documented thread-safe injection
//     without XInitThreads: Xlib is only thread-unsafe when two threads share
//     one Display, so one-connection-per-thread sidesteps locking entirely.
//     The event makes a full round-trip through the X server (thread socket
//     -> server -> main-loop socket).
//   * Mechanism B (`mech=eventfd`): the same thread writes an eventfd(2) that
//     the main loop poll(2)s alongside ConnectionNumber(dpy) — no server
//     involvement, a pure kernel futex/wait wake.
//   * An arbitrary external fd: a periodic timerfd(2) in the same poll set,
//     logged as `fd_tick` interleaved with window events.
//
// Each mechanism fires 10x/second for 30 s (WSI_DURATION_MS overrides),
// offset by 50 ms so they interleave; every wakeup logs
// `wakeup latency_us=… mech=…` computed from a monotonic timestamp carried
// in the event (ClientMessage: split across two 32-bit data.l slots — the
// wire format truncates each slot to 32 bits) or in an atomic side-channel
// (eventfd is a counter, not a queue). min/p50/p99/max per mechanism at exit.
//
// Headless-safe: no X server -> prints `SKIP:` and exits 0. WSI_AUTO_EXIT=1
// bounds the run (exits after the wakeup phase completes). Findings:
// ../../f05-loop-wakeup.md.
module app;

import c; // ImportC: Xlib + poll + eventfd + timerfd + unistd
import instrument;

import core.atomic : atomicLoad, atomicStore;
import core.stdc.config : c_long, c_ulong;
import core.stdc.stdio : printf;
import core.stdc.stdlib : atoi, getenv, qsort;
import core.thread.osthread : Thread;
import core.time : msecs;

// ---------------------------------------------------------------------------
// Constants Xlib/glibc expose as macros that ImportC cannot import
// (expression macros like `(1L<<15)`); re-declared per the scaffold gotcha.

enum : c_long
{
    KeyPressMask = 1L << 0,
    ExposureMask = 1L << 15,
    StructureNotifyMask = 1L << 17,
}

enum // XEvent.type discriminators
{
    KeyPress = 2,
    Expose = 12,
    MapNotify = 19,
    ConfigureNotify = 22,
    ClientMessage = 33,
}

enum False = 0;
enum True = 1;
enum POLLIN = 0x001;
enum CLOCK_MONOTONIC = 1;
enum EFD_CLOEXEC = 0x80000; // 02000000
enum EFD_NONBLOCK = 0x800; // 00004000
enum TFD_CLOEXEC = 0x80000;
enum WAKE_MAGIC = 0x57414b45; // "WAKE" — data.l[0] tag of our ClientMessage

// ---------------------------------------------------------------------------
// Worker-thread <-> main-loop shared state. The worker owns its own Display;
// the only data crossing threads outside X are these atomics + the eventfd.

__gshared Window g_win; // injection target (XIDs are connection-independent)
__gshared Atom g_wakeAtom; // atoms are server-global ids, safe to share
__gshared int g_efd = -1;
__gshared long g_efdStamp; // nowUs() at the instant of the eventfd write
__gshared int g_wakeupsPerMech = 300; // 10/s for 30 s
__gshared bool g_workerDone;

/// The injector thread (F05 requirement 1). Opens its own connection — the
/// documented no-XInitThreads-needed pattern — and alternates the two
/// mechanisms on a 50 ms grid, so each one fires 10x/s.
void injectorThread()
{
    Display* d2 = XOpenDisplay(null);
    if (d2 is null)
    {
        atomicStore(g_workerDone, true);
        return;
    }
    emitf("step", "name=XOpenDisplay conn=injector fd=%d", XConnectionNumber(d2));

    const t0 = nowUs();
    foreach (i; 0 .. 2 * g_wakeupsPerMech)
    {
        const target = t0 + (i + 1) * 50_000L;
        const wait = target - nowUs();
        if (wait > 0)
            Thread.sleep((wait / 1000).msecs);

        if (i % 2 == 0) // mechanism A: ClientMessage through the server
        {
            XEvent ev;
            ev.xclient.type = ClientMessage;
            ev.xclient.window = g_win;
            ev.xclient.message_type = g_wakeAtom;
            ev.xclient.format = 32;
            const ts = nowUs();
            ev.xclient.data.l[0] = WAKE_MAGIC;
            ev.xclient.data.l[1] = cast(c_long)(ts >> 32); // wire slots are
            ev.xclient.data.l[2] = cast(c_long)(ts & 0xffff_ffffL); // 32-bit
            // event_mask=0: deliver to the client that created g_win.
            XSendEvent(d2, g_win, False, 0, &ev);
            XFlush(d2); // scaffold gotcha: nothing moves until the flush
        }
        else // mechanism B: eventfd, kernel-only
        {
            atomicStore(g_efdStamp, nowUs());
            ulong one = 1;
            write(g_efd, &one, one.sizeof);
        }
    }
    XCloseDisplay(d2);
    atomicStore(g_workerDone, true);
}

// ---------------------------------------------------------------------------
// Latency bookkeeping.

struct Series
{
    long[4096] v;
    int n;

    void record(long x) @nogc nothrow
    {
        if (n < v.length)
            v[n++] = x;
    }

    long at(double q) @nogc nothrow // q in [0,1] on the sorted array
    {
        auto i = cast(int)(q * (n - 1) + 0.5);
        return v[i < 0 ? 0 : (i >= n ? n - 1 : i)];
    }
}

extern (C) int cmpLong(const void* a, const void* b) @nogc nothrow
{
    const x = *cast(const long*) a, y = *cast(const long*) b;
    return (x > y) - (x < y);
}

void emitStats(const(char)* mech, ref Series s) @nogc nothrow
{
    if (s.n == 0)
        return;
    qsort(s.v.ptr, s.n, long.sizeof, &cmpLong);
    emitf("stats", "mech=%s n=%d min=%lld p50=%lld p99=%lld max=%lld",
        mech, s.n, s.v[0], s.at(0.50), s.at(0.99), s.v[s.n - 1]);
}

int main()
{
    initInstrument("f05_x11");
    const envAuto = getenv("WSI_AUTO_EXIT");
    const autoExit = envAuto !is null && envAuto[0] == '1';
    const envDur = getenv("WSI_DURATION_MS");
    const durationMs = envDur !is null ? atoi(envDur) : 30_000;
    g_wakeupsPerMech = durationMs / 100; // each mechanism fires every 100 ms

    // -- Connect + window (scaffold sequence, minus the SHM backbuffer) ------
    Display* dpy = XOpenDisplay(null);
    if (dpy is null)
    {
        printf("SKIP: no X11 display (XOpenDisplay returned null)\n");
        return 0;
    }
    emitf("step", "name=XOpenDisplay conn=main fd=%d", XConnectionNumber(dpy));

    const screen = XDefaultScreen(dpy);
    Window win = XCreateSimpleWindow(dpy, XRootWindow(dpy, screen), 0, 0,
        480, 320, 1, XBlackPixel(dpy, screen), XWhitePixel(dpy, screen));
    XStoreName(dpy, win, "Sparkles · X11 F05 loop wakeup");
    Atom wmDelete = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
    XSetWMProtocols(dpy, win, &wmDelete, 1);
    Atom wakeAtom = XInternAtom(dpy, "SPARKLES_WSI_WAKEUP", False);
    XSelectInput(dpy, win, ExposureMask | KeyPressMask | StructureNotifyMask);
    XMapWindow(dpy, win);
    emitf("window_created", "xid=0x%lx size=480x320", win);

    // -- The two external fds (F05 requirement 2) -----------------------------
    const efd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    emitf("step", "name=eventfd fd=%d", efd);
    const tfd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC);
    itimerspec its;
    its.it_interval.tv_sec = 0;
    its.it_interval.tv_nsec = 250_000_000; // 4 Hz probe tick
    its.it_value = its.it_interval;
    timerfd_settime(tfd, 0, &its, null);
    emitf("step", "name=timerfd fd=%d period_ms=250", tfd);

    g_win = win;
    g_wakeAtom = wakeAtom;
    g_efd = efd;

    auto worker = new Thread(&injectorThread);
    worker.start();
    emitf("step", "name=thread_start wakeups_per_mech=%d period_ms=100", g_wakeupsPerMech);

    Series latClientMsg, latEventfd;
    int fdTicks = 0, frames = 0;
    bool running = true, sawFirstPixel = false;
    long doneAtUs = 0;

    // -- Readiness loop: ConnectionNumber fd + eventfd + timerfd in one poll --
    while (running)
    {
        while (XPending(dpy) > 0) // also flushes the output buffer
        {
            XEvent ev;
            XNextEvent(dpy, &ev);
            switch (ev.type)
            {
            case Expose:
                if (ev.xexpose.count == 0)
                {
                    XFillRectangle(dpy, win, XDefaultGC(dpy, screen), 20, 20, 440, 280);
                    XFlush(dpy);
                    ++frames;
                    if (!sawFirstPixel)
                    {
                        sawFirstPixel = true;
                        emit("first_pixel_presented method=XFillRectangle");
                    }
                }
                break;

            case ClientMessage:
                if (ev.xclient.message_type == wakeAtom
                    && ev.xclient.data.l[0] == WAKE_MAGIC)
                {
                    // Reassemble the 64-bit monotonic stamp from the two
                    // sign-extended 32-bit wire slots.
                    const ts = (cast(long) ev.xclient.data.l[1] << 32)
                        | cast(uint) ev.xclient.data.l[2];
                    const lat = nowUs() - ts;
                    latClientMsg.record(lat);
                    emitf("wakeup", "latency_us=%lld mech=clientmessage", lat);
                }
                else if (cast(Atom) ev.xclient.data.l[0] == wmDelete)
                {
                    emit("close_requested via=WM_DELETE_WINDOW");
                    running = false;
                }
                break;

            case KeyPress:
                emit("close_requested via=KeyPress");
                running = false;
                break;

            default:
                break;
            }
        }

        if (atomicLoad(g_workerDone))
        {
            if (doneAtUs == 0)
                doneAtUs = nowUs();
            else if (autoExit && nowUs() - doneAtUs > 300_000) // drain grace
            {
                emitf("auto_exit", "frames=%d", frames);
                break;
            }
        }

        pollfd[3] pfds;
        pfds[0].fd = XConnectionNumber(dpy);
        pfds[1].fd = efd;
        pfds[2].fd = tfd;
        foreach (ref p; pfds)
        {
            p.events = POLLIN;
            p.revents = 0;
        }
        poll(pfds.ptr, 3, 50);

        if (pfds[1].revents & POLLIN) // mechanism B fired
        {
            ulong count;
            read(efd, &count, count.sizeof);
            const lat = nowUs() - atomicLoad(g_efdStamp);
            latEventfd.record(lat);
            emitf("wakeup", "latency_us=%lld mech=eventfd coalesced=%llu", lat, count);
        }
        if (pfds[2].revents & POLLIN) // the arbitrary-fd probe
        {
            ulong expirations;
            read(tfd, &expirations, expirations.sizeof);
            ++fdTicks;
            emitf("fd_tick", "t=%lld expirations=%llu src=timerfd", nowUs(), expirations);
        }
    }

    // -- Stats + teardown (F05 requirement 3) ---------------------------------
    emitStats("clientmessage", latClientMsg);
    emitStats("eventfd", latEventfd);
    emitf("stats", "mech=timerfd ticks=%d period_ms=250", fdTicks);

    worker.join();
    close(efd);
    close(tfd);
    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
    emit("teardown");
    return 0;
}
