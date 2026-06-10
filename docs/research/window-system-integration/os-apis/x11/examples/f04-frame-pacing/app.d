// F04 — vsync / frame pacing, X11 edition (../../../features/f04-frame-pacing.md).
// Derived from the X11 scaffold (../scaffold/app.d). Core X11 has no frame
// clock at all; the platform primitive is the PRESENT EXTENSION, which is
// xcb-only (no Xlib binding exists). This demo therefore uses the documented
// Xlib/XCB interop: the window/setup side stays Xlib like every other demo in
// this tree, XGetXCBConnection exposes the shared xcb_connection_t, and
// XSetEventQueueOwner(XCBOwnsEventQueue) — called immediately after
// XOpenDisplay, before any event-generating request — routes ALL events to
// xcb_poll_for_event so Present's GenericEvents can be read.
//
// The pacing chain (the "draw only when the display says so" contract):
//
//   xcb_present_select_input(eid, win, COMPLETE_NOTIFY)   — subscribe
//   xcb_present_notify_msc(win, serial, target_msc, 0, 0) — "wake me at msc"
//   PresentCompleteNotify(kind=NOTIFY_MSC) → ust,msc      — the frame clock
//   draw a trivially cheap solid-color flip, request msc+1, repeat
//
// Per frame: `frame_callback t=<ust> msc=<msc> mode=<mode>` (ust is the
// server's CLOCK_MONOTONIC microseconds; msc the media stream counter). After
// WSI_FRAMES frames (default 600): min/median/p99/max inter-frame delta and a
// coarse jitter histogram on STDOUT (the F04 contract), then an occlusion
// probe — XUnmapWindow for 3 s while the notify_msc chain keeps running, to
// answer "does the clock stop when hidden?" — then remap and exit.
//
// Fallback path (Present absent, or forced with WSI_NO_PRESENT=1): a 16.67 ms
// timerfd drives the same redraw + logging with mode=timer and msc=0 — the
// "no frame clock" degradation the F04 spec asks to be recorded as a finding.
//
// Headless-safe: no display prints `SKIP:` and exits 0. Under Xvfb there is
// no real vblank — Present still works, but its msc/ust come from a software
// fallback timer; the observed cadence IS the finding (../../f04-frame-pacing.md).
module app;

import c; // ImportC: Xlib + Xlib-xcb + xcb + xcb/present + timerfd + poll
import instrument;

import core.stdc.config : c_long, c_ulong;
import core.stdc.stdio : printf;
import core.stdc.stdlib : free, getenv, qsort;
import core.sys.posix.unistd : read;

// Constants Xlib/xcb expose only as macros (not ImportC-able); re-declared
// per the ImportC guide. The XCB_* event codes are #defines in xproto.h.
enum : c_long
{
    KeyPressMask = 1L << 0,
    ExposureMask = 1L << 15,
    StructureNotifyMask = 1L << 17,
}

enum // xcb response_type discriminators (#defines in xcb/xproto.h)
{
    XCB_KEY_PRESS = 2,
    XCB_EXPOSE = 12,
    XCB_UNMAP_NOTIFY = 18,
    XCB_MAP_NOTIFY = 19,
    XCB_CONFIGURE_NOTIFY = 22,
    XCB_CLIENT_MESSAGE = 33,
    XCB_GE_GENERIC = 35,
}

enum XCB_PRESENT_COMPLETE_NOTIFY_EVTYPE = 1; // #define XCB_PRESENT_COMPLETE_NOTIFY
enum False = 0;
enum POLLIN = 0x001;
enum CLOCK_MONOTONIC = 1;

// xcb declares xcb_present_complete_notify_event_t XCB_PACKED
// (__attribute__((__packed__))): on the wire `msc` sits at byte offset 36,
// unaligned for a uint64. ImportC (ldc 1.41) IGNORES the packed attribute —
// the imported struct is 48 bytes with msc naturally aligned to offset 40,
// so reading msc through it yields garbage. Re-declare the exact wire layout
// in D with align(1), the same re-declaration discipline as the macro
// constants above.
struct PresentCompleteNotify // = xcb_present_complete_notify_event_t, packed
{
align(1):
    ubyte response_type;
    ubyte extension;
    ushort sequence;
    uint length;
    ushort event_type;
    ubyte kind;
    ubyte mode;
    uint event;
    uint window;
    uint serial;
    ulong ust;
    uint full_sequence;
    ulong msc;
}

static assert(PresentCompleteNotify.sizeof == 44);
static assert(PresentCompleteNotify.msc.offsetof == 36);
static assert(xcb_present_complete_notify_event_t.sizeof == 48); // the ImportC trap

// ---------------------------------------------------------------------------
// Inter-frame-delta bookkeeping + the exit report the F04 spec mandates.

enum maxFrames = 4096;
__gshared long[maxFrames] g_deltas;
__gshared int g_nDeltas = 0;

extern (C) int cmpLong(const void* a, const void* b) @nogc nothrow
{
    const x = *cast(const long*) a, y = *cast(const long*) b;
    return x < y ? -1 : x > y ? 1 : 0;
}

void recordDelta(long d) @nogc nothrow
{
    if (g_nDeltas < maxFrames)
        g_deltas[g_nDeltas++] = d;
}

/// min/median/p99/max + coarse histogram, printed to STDOUT (spec req. 2).
void printStats(const(char)* path, int frames) @nogc nothrow
{
    if (g_nDeltas == 0)
        return;
    qsort(g_deltas.ptr, g_nDeltas, long.sizeof, &cmpLong);
    const lo = g_deltas[0], hi = g_deltas[g_nDeltas - 1];
    const med = g_deltas[g_nDeltas / 2];
    const p99 = g_deltas[(g_nDeltas * 99) / 100 < g_nDeltas
            ? (g_nDeltas * 99) / 100 : g_nDeltas - 1];
    printf("stats path=%s frames=%d deltas=%d min_us=%lld median_us=%lld p99_us=%lld max_us=%lld\n",
        path, frames, g_nDeltas, lo, med, p99, hi);

    static immutable long[8] edges = [1_000, 4_000, 8_000, 12_000, 16_000,
        20_000, 33_000, 100_000];
    static immutable string[9] labels = [
        "<1ms", "1-4ms", "4-8ms", "8-12ms", "12-16ms", "16-20ms", "20-33ms",
        "33-100ms", ">=100ms",
    ];
    int[9] counts = 0;
    foreach (i; 0 .. g_nDeltas)
    {
        size_t b = edges.length; // overflow bucket
        foreach (j, e; edges)
            if (g_deltas[i] < e)
            {
                b = j;
                break;
            }
        ++counts[b];
    }
    foreach (j, label; labels)
        if (counts[j] > 0)
            printf("histogram bucket=%s count=%d\n", label.ptr, counts[j]);
}

int main()
{
    initInstrument("f04_x11");
    const envFrames = getenv("WSI_FRAMES");
    int targetFrames = 600;
    if (envFrames !is null)
    {
        import core.stdc.stdlib : atoi;

        const v = atoi(envFrames);
        if (v > 0 && v < maxFrames)
            targetFrames = v;
    }

    // -- Connect; hand the event queue to xcb BEFORE any other Xlib call ------
    Display* dpy = XOpenDisplay(null);
    if (dpy is null)
    {
        printf("SKIP: no X11 display (XOpenDisplay returned null)\n");
        return 0;
    }
    XSetEventQueueOwner(dpy, XCBOwnsEventQueue);
    xcb_connection_t* conn = XGetXCBConnection(dpy);
    emitf("step", "name=XGetXCBConnection fd=%d queue_owner=xcb",
        xcb_get_file_descriptor(conn));

    const screen = XDefaultScreen(dpy);
    const root = XRootWindow(dpy, screen);

    // -- Present availability + version (round-trips) -------------------------
    auto extData = xcb_get_extension_data(conn, &xcb_present_id);
    const havePresentExt = extData !is null && extData.present != 0;
    emitf("step", "name=xcb_get_extension_data ext=Present present=%d major_opcode=%d first_event=%d",
        cast(int) havePresentExt,
        havePresentExt ? extData.major_opcode : -1,
        havePresentExt ? extData.first_event : -1);

    uint presentMajor = 0, presentMinor = 0;
    if (havePresentExt)
    {
        auto ck = xcb_present_query_version(conn, 1, 4);
        auto reply = xcb_present_query_version_reply(conn, ck, null);
        if (reply !is null)
        {
            presentMajor = reply.major_version;
            presentMinor = reply.minor_version;
            free(reply);
        }
        emitf("step", "name=xcb_present_query_version version=%u.%u",
            presentMajor, presentMinor);
    }

    bool usePresent = havePresentExt;
    if (usePresent && getenv("WSI_NO_PRESENT") !is null)
    {
        usePresent = false;
        emit("step name=fallback reason=WSI_NO_PRESENT");
    }
    else if (!usePresent)
        emit("step name=fallback reason=present_absent");

    // -- Window (Xlib side, scaffold-style) ------------------------------------
    int width = 480, height = 320;
    Window win = XCreateSimpleWindow(dpy, root, 0, 0, width, height, 1,
        XBlackPixel(dpy, screen), XWhitePixel(dpy, screen));
    emitf("step", "name=XCreateSimpleWindow xid=0x%lx", win);
    XStoreName(dpy, win, "Sparkles · X11 F04");

    Atom wmDelete = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
    XSetWMProtocols(dpy, win, &wmDelete, 1);
    XSelectInput(dpy, win, ExposureMask | KeyPressMask | StructureNotifyMask);
    XMapWindow(dpy, win);
    // Interop gotcha: with the queue owned by xcb the event loop below reads
    // via xcb_poll_for_event, which — unlike XPending — does NOT flush Xlib's
    // output buffer. Without this flush the MapWindow request never leaves
    // the client on the fallback path and the demo deadlocks waiting for its
    // first Expose. (On the Present path the first xcb_present_* call rescues
    // it by accident: xcb takes the socket back from libX11, forcing a flush.)
    XFlush(dpy);
    emitf("window_created", "xid=0x%lx size=%dx%d", win, width, height);

    GC gc = XDefaultGC(dpy, screen);

    // -- Present event subscription --------------------------------------------
    if (usePresent)
    {
        const eid = xcb_generate_id(conn);
        xcb_present_select_input(conn, eid, cast(uint) win,
            XCB_PRESENT_EVENT_MASK_COMPLETE_NOTIFY);
        emitf("step", "name=xcb_present_select_input eid=0x%x mask=COMPLETE_NOTIFY", eid);
    }

    // -- Fallback clock: 16.67 ms timerfd (armed only on the fallback path) ----
    const tfd = timerfd_create(CLOCK_MONOTONIC, 0);
    if (!usePresent)
    {
        itimerspec its;
        its.it_interval.tv_sec = 0;
        its.it_interval.tv_nsec = 16_666_667;
        its.it_value = its.it_interval;
        timerfd_settime(tfd, 0, &its, null);
        emitf("step", "name=timerfd_create fd=%d interval_us=16667", tfd);
    }

    scope (exit)
    {
        XDestroyWindow(dpy, win);
        XCloseDisplay(dpy); // owns conn: closes the shared xcb connection too
    }

    /// One trivially cheap frame: a solid-color flip (alternating fill).
    int frames = 0;
    void drawFrame() @nogc nothrow
    {
        const c_ulong color = (frames & 1) ? 0xff_60_30 : 0x20_50_c0;
        XSetForeground(dpy, gc, color);
        XFillRectangle(dpy, win, gc, 0, 0, cast(uint) width, cast(uint) height);
    }

    const fd = xcb_get_file_descriptor(conn);
    bool running = true, chainStarted = false, exposed = false;
    bool occluding = false, occlusionDone = false;
    long lastUst = 0, occlusionEndUs = 0;
    ulong lastMsc = 0;
    uint notifySerial = 0;
    int occlFrames = 0;

    /// Schedule the next frame-clock wakeup. target=0 means "at the current
    /// msc" (used once to seed the chain); afterwards we ask for lastMsc+1.
    void requestNotify(ulong targetMsc) @nogc nothrow
    {
        xcb_present_notify_msc(conn, cast(uint) win, ++notifySerial,
            targetMsc, 0, 0);
        xcb_flush(conn);
    }

    while (running)
    {
        // Drain everything xcb has already read or can read without blocking.
        for (;;)
        {
            xcb_generic_event_t* ev = xcb_poll_for_event(conn);
            if (ev is null)
                break;
            scope (exit)
                free(ev); // xcb events are malloc'd; the caller frees

            const rt = ev.response_type & 0x7f;
            switch (rt)
            {
            case XCB_EXPOSE:
                const xe = cast(xcb_expose_event_t*) ev;
                if (xe.count == 0 && !exposed)
                {
                    exposed = true;
                    drawFrame();
                    XFlush(dpy);
                    emit("first_pixel_presented method=XFillRectangle note=no_confirmation_without_Present");
                    if (usePresent && !chainStarted)
                    {
                        chainStarted = true;
                        requestNotify(0); // seed: complete at the current msc
                        emit("step name=xcb_present_notify_msc target=current note=chain_seed");
                    }
                }
                break;

            case XCB_GE_GENERIC:
                const ge = cast(xcb_present_generic_event_t*) ev;
                if (!havePresentExt || ge.extension != extData.major_opcode)
                    break;
                if (ge.evtype != XCB_PRESENT_COMPLETE_NOTIFY_EVTYPE)
                    break;
                const cn = cast(PresentCompleteNotify*) ev;
                if (cn.kind != XCB_PRESENT_COMPLETE_KIND_NOTIFY_MSC)
                    break;
                // The frame clock tick: ust/msc straight from the server.
                lastMsc = cn.msc;
                if (occluding)
                {
                    ++occlFrames;
                    emitf("frame_callback", "t=%llu msc=%llu mode=%d occluded=1",
                        cast(ulong) cn.ust, cast(ulong) cn.msc, cast(int) cn.mode);
                    requestNotify(cn.msc + 1);
                    break;
                }
                ++frames;
                if (lastUst != 0)
                    recordDelta(cast(long)(cn.ust - lastUst));
                lastUst = cast(long) cn.ust;
                emitf("frame_callback", "t=%llu msc=%llu mode=%d frame=%d",
                    cast(ulong) cn.ust, cast(ulong) cn.msc, cast(int) cn.mode, frames);
                if (frames < targetFrames)
                {
                    drawFrame();
                    XFlush(dpy);
                    requestNotify(cn.msc + 1);
                }
                break;

            case XCB_UNMAP_NOTIFY:
                emit("vis_change state=unmapped");
                break;

            case XCB_MAP_NOTIFY:
                emit("vis_change state=mapped");
                break;

            case XCB_CLIENT_MESSAGE:
                const cm = cast(xcb_client_message_event_t*) ev;
                if (cm.data.data32[0] == cast(uint) wmDelete)
                {
                    emit("close_requested via=WM_DELETE_WINDOW");
                    running = false;
                }
                break;

            case XCB_KEY_PRESS:
                emit("close_requested via=KeyPress");
                running = false;
                break;

            default:
                break;
            }
        }

        if (xcb_connection_has_error(conn))
        {
            emit("x_error connection_lost=1");
            return 1;
        }

        // -- Occlusion probe (spec req. 3): unmap for 3 s, keep the chain up --
        if (frames >= targetFrames && !occluding && !occlusionDone)
        {
            occluding = true;
            occlusionEndUs = nowUs() + 3_000_000;
            XUnmapWindow(dpy, win);
            XFlush(dpy);
            emit("step name=XUnmapWindow note=occlusion_probe_3s");
            if (usePresent)
                requestNotify(lastMsc + 1); // does the clock still tick?
        }
        if (occluding && nowUs() >= occlusionEndUs)
        {
            occluding = false;
            occlusionDone = true;
            XMapWindow(dpy, win);
            XFlush(dpy);
            emitf("occlusion", "frames_while_unmapped=%d duration_ms=3000 clock=%s",
                occlFrames, usePresent ? "present".ptr : "timer".ptr);
            running = false; // measured + probed: done
        }

        if (running)
        {
            pollfd[2] pfds;
            pfds[0].fd = fd;
            pfds[0].events = POLLIN;
            pfds[0].revents = 0;
            pfds[1].fd = tfd;
            pfds[1].events = POLLIN;
            pfds[1].revents = 0;
            // Bounded sleep so the occlusion deadline fires even when the
            // (unmapped, Present-less) connection goes silent.
            poll(pfds.ptr, 2, 200);

            if (!usePresent && (pfds[1].revents & POLLIN))
            {
                ulong expirations;
                read(tfd, &expirations, expirations.sizeof);
                if (exposed && (frames < targetFrames || occluding))
                {
                    const now = nowUs();
                    if (occluding)
                    {
                        ++occlFrames;
                        emitf("frame_callback", "t=%lld msc=0 mode=timer occluded=1", now);
                    }
                    else
                    {
                        ++frames;
                        if (lastUst != 0)
                            recordDelta(now - lastUst);
                        lastUst = now;
                        drawFrame();
                        XFlush(dpy);
                        emitf("frame_callback", "t=%lld msc=0 mode=timer frame=%d", now, frames);
                    }
                }
            }
        }
    }

    printStats(usePresent ? "present".ptr : "timer".ptr, frames);
    emit("teardown");
    return 0;
}
