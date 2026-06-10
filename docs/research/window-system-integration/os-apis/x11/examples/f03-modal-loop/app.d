// F03 — modal-loop survival, X11 edition (../../../features/f03-modal-loop.md).
// Derived from the X11 scaffold (../scaffold/app.d) and the F02 demo
// (../f02-resize/app.d). On Win32, interactive resize/move traps the thread in
// a system modal loop (WM_ENTERSIZEMOVE) and the message pump stops being
// yours; the F03 spec asks each platform to prove animation survives that.
// X11's answer is that THERE IS NO MODAL LOOP TO SURVIVE: resize — self,
// external-client, or WM-mediated — is just more events in the same queue, and
// nothing ever takes the thread away from the app's own poll(2) loop. This
// demo makes that absence measurable:
//
//   * a ~2 Hz full-window color cycle, ticked by a TIMERFD polled alongside
//     the X connection fd — the animation clock is the app's own, exactly the
//     loop shape a framework owns; X11 never re-enters or blocks it;
//   * a `tick t=… n=… phase=… presented=0|1 gap_us=…` line per animation
//     frame, where gap_us is the delta to the previous tick — the modal-loop
//     symptom (animation freeze) would show as an unbounded gap;
//   * three instrumented phases: `calm` (baseline cadence), `self` (a resize
//     storm from the demo's own connection: XResizeWindow every other tick,
//     25 requests), `ext` (the same storm from a SECOND Display* connection —
//     what a WM or `xdotool` does), then a drain; per-phase
//     `gap_summary phase=… ticks=… resizes=… max_gap_us=…` lines at exit;
//   * every ConfigureNotify still triggers the naive realloc-the-SHM-segment
//     response from F02 — the worst-case per-resize work — and the tick
//     cadence must hold anyway;
//   * protocol errors via XSetErrorHandler; the run must end errors=0.
//
// Run it once on bare Xvfb and once with icewm inside the same Xvfb: under
// the WM every resize becomes a ConfigureRequest the WM mediates (see the
// F02 findings) — the closest X11 gets to "someone else is driving" — and the
// ticks must still flow. True interactive border-drag needs a human and a
// real session: Tier C, queued in ../../../manual-run-queue.md.
//
// WSI_AUTO_EXIT=1 bounds the run (~2.6 s, 156 ticks); otherwise it runs until
// WM_DELETE_WINDOW, ticking forever. Headless-safe: no display prints `SKIP:`
// and exits 0. Findings: ../../f03-modal-loop.md.
module app;

import c; // ImportC: Xlib + Xutil + Xatom + XShm + sys/ipc + sys/shm + timerfd + poll
import instrument;

import core.stdc.config : c_long, c_ulong;
import core.stdc.stdio : printf;
import core.stdc.stdlib : getenv;
import core.sys.posix.unistd : read;

// Constants Xlib/glibc expose only as macros (not ImportC-able); re-declared
// per the ImportC guide, same as the scaffold.
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
    ReparentNotify = 21,
    ConfigureNotify = 22,
    ClientMessage = 33,
}

enum ZPixmap = 2;
enum ShmCompletion = 0; // offset inside MIT-SHM's allocated event range
enum False = 0;
enum True = 1;
enum POLLIN = 0x001;
enum IPC_PRIVATE = 0;
enum IPC_CREAT = 0x200; // 01000 octal
enum IPC_RMID = 0;
enum CLOCK_MONOTONIC = 1;

// ---------------------------------------------------------------------------
// Protocol-error accounting, as in F02: Xlib reports errors asynchronously.

__gshared int g_xErrors = 0;

extern (C) int onXError(Display* dpy, XErrorEvent* e) @nogc nothrow
{
    char[128] text = 0;
    XGetErrorText(dpy, e.error_code, text.ptr, text.length);
    emitf("x_error", "code=%d request=%d.%d resource=0x%lx text=%s",
        e.error_code, e.request_code, e.minor_code, e.resourceid, text.ptr);
    ++g_xErrors;
    return 0;
}

// ---------------------------------------------------------------------------
// Backbuffer: MIT-SHM XImage with plain-XPutImage fallback (as the scaffold).

struct Backbuffer
{
    XImage* ximg;
    XShmSegmentInfo shminfo;
    bool usingShm;
    int width, height;
}

Backbuffer createBackbuffer(Display* dpy, Visual* visual, int depth,
    int w, int h, bool wantShm) @nogc nothrow
{
    Backbuffer b;
    b.width = w;
    b.height = h;

    if (wantShm)
    {
        b.ximg = XShmCreateImage(dpy, visual, cast(uint) depth, ZPixmap,
            null, &b.shminfo, cast(uint) w, cast(uint) h);
        if (b.ximg !is null)
        {
            const nbytes = cast(size_t)(b.ximg.bytes_per_line * b.ximg.height);
            b.shminfo.shmid = shmget(IPC_PRIVATE, nbytes, IPC_CREAT | 0x180 /* 0600 */ );
            if (b.shminfo.shmid >= 0)
            {
                b.shminfo.shmaddr = cast(char*) shmat(b.shminfo.shmid, null, 0);
                if (b.shminfo.shmaddr !is cast(char*)-1)
                {
                    b.ximg.data = b.shminfo.shmaddr;
                    b.shminfo.readOnly = False;
                    XShmAttach(dpy, &b.shminfo);
                    XSync(dpy, False); // server attached before ...
                    shmctl(b.shminfo.shmid, IPC_RMID, null); // ... mark-for-delete
                    b.usingShm = true;
                    return b;
                }
                shmctl(b.shminfo.shmid, IPC_RMID, null);
            }
            b.ximg.f.destroy_image(b.ximg); // XDestroyImage is a macro
            b.ximg = null;
        }
        emit("step name=shm_fallback reason=alloc_or_attach_failed");
    }

    import core.stdc.stdlib : malloc;

    auto data = cast(char*) malloc(cast(size_t) w * h * 4);
    b.ximg = XCreateImage(dpy, visual, cast(uint) depth, ZPixmap, 0, data,
        cast(uint) w, cast(uint) h, 32, 0);
    b.usingShm = false;
    return b;
}

void destroyBackbuffer(Display* dpy, ref Backbuffer b) @nogc nothrow
{
    if (b.ximg is null)
        return;
    if (b.usingShm)
    {
        XSync(dpy, False); // let any in-flight XShmPutImage finish reading
        XShmDetach(dpy, &b.shminfo);
    }
    b.ximg.f.destroy_image(b.ximg);
    if (b.usingShm)
        shmdt(b.shminfo.shmaddr);
    b.ximg = null;
}

/// Full-window solid fill from an 8-bit hue phase: three 120°-offset triangle
/// waves (R/G/B). Phase advances 8 steps per ~16 ms tick — a full cycle every
/// 32 ticks, i.e. the spec's ~2 Hz color cycle at the 62.5 Hz tick rate.
void fillColorCycle(XImage* ximg, int phase) @nogc nothrow
{
    static uint tri(int p) @nogc nothrow // triangle wave, period 256, 0..255
    {
        const v = p & 0xff;
        return cast(uint)(v < 128 ? v * 2 : (255 - v) * 2);
    }

    const rgb = (tri(phase) << 16) | (tri(phase + 85) << 8) | tri(phase + 170);
    const w = ximg.width, h = ximg.height;
    if (ximg.bits_per_pixel != 32)
        return;
    foreach (y; 0 .. h)
    {
        auto row = cast(uint*)(ximg.data + y * ximg.bytes_per_line);
        row[0 .. w] = rgb;
    }
}

int main()
{
    initInstrument("f03_x11");
    const envAuto = getenv("WSI_AUTO_EXIT");
    const autoExit = envAuto !is null && envAuto[0] == '1';

    XSetErrorHandler(&onXError);

    Display* dpy = XOpenDisplay(null);
    if (dpy is null)
    {
        printf("SKIP: no X11 display (XOpenDisplay returned null)\n");
        return 0;
    }
    emitf("step", "name=XOpenDisplay fd=%d", XConnectionNumber(dpy));

    const screen = XDefaultScreen(dpy);
    const root = XRootWindow(dpy, screen);
    Visual* visual = XDefaultVisual(dpy, screen);
    const depth = XDefaultDepth(dpy, screen);

    bool haveShm = XShmQueryExtension(dpy) != 0 && getenv("WSI_NO_SHM") is null;
    int shmCompletionType = haveShm ? XShmGetEventBase(dpy) + ShmCompletion : -1;
    emitf("step", "name=XShmQueryExtension using_shm=%d", cast(int) haveShm);

    int width = 480, height = 320;
    Window win = XCreateSimpleWindow(dpy, root, 0, 0, width, height, 1,
        XBlackPixel(dpy, screen), XWhitePixel(dpy, screen));
    emitf("step", "name=XCreateSimpleWindow xid=0x%lx", win);
    XStoreName(dpy, win, "Sparkles · X11 F03");

    Atom wmDelete = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
    XSetWMProtocols(dpy, win, &wmDelete, 1);
    XSelectInput(dpy, win, ExposureMask | KeyPressMask | StructureNotifyMask);
    XMapWindow(dpy, win);
    emitf("window_created", "xid=0x%lx size=%dx%d", win, width, height);

    GC gc = XDefaultGC(dpy, screen);
    auto buf = createBackbuffer(dpy, visual, depth, width, height, haveShm);

    // -- The animation heartbeat: a timerfd at 16 ms (62.5 Hz) ----------------
    // The clock the app OWNS — F03's point is that on X11 nothing the window
    // system does can stop this fd from firing or the loop from reading it.
    const tfd = timerfd_create(CLOCK_MONOTONIC, 0);
    itimerspec its;
    its.it_interval.tv_sec = 0;
    its.it_interval.tv_nsec = 16_000_000; // 16 ms
    its.it_value = its.it_interval;
    timerfd_settime(tfd, 0, &its, null);
    emitf("step", "name=timerfd_create fd=%d interval_ms=16", tfd);

    Display* dpy2 = null; // the "outside world" connection for the ext phase

    scope (exit)
    {
        if (dpy2 !is null)
            XCloseDisplay(dpy2);
        destroyBackbuffer(dpy, buf);
        XDestroyWindow(dpy, win);
        XCloseDisplay(dpy);
    }

    // -- Phase plan (auto-exit mode) ------------------------------------------
    //   calm   ticks   1..31   no resizes (baseline tick cadence)
    //   self   ticks  32..81   XResizeWindow on dpy every other tick (25 reqs)
    //   ext    ticks  82..131  XResizeWindow on dpy2 every other tick (25 reqs)
    //   drain  ticks 132..156  no resizes (recovery), then exit
    static immutable int[2][6] sizes = [
        [640, 400], [320, 240], [800, 520], [400, 300], [720, 480], [360, 260],
    ];
    enum calmEnd = 31, selfEnd = 81, extEnd = 131, lastTick = 156;

    static immutable string[4] phaseNames = ["calm", "self", "ext", "drain"];
    long[4] maxGap = 0;
    int[4] phaseTicks = 0, phaseResizes = 0;

    const xfd = XConnectionNumber(dpy);
    bool running = true, awaitingCompletion = false, sawFirstPixel = false;
    int ticks = 0, colorPhase = 0, sizeIdx = 0;
    long lastTickUs = 0;

    while (running)
    {
        while (XPending(dpy) > 0) // XPending also flushes the output buffer
        {
            XEvent ev;
            XNextEvent(dpy, &ev);
            switch (ev.type)
            {
            case MapNotify:
                emitf("map_notify", "serial=%lu", ev.xany.serial);
                break;

            case ReparentNotify: // a WM adopted us (never seen on bare Xvfb)
                emitf("reparent_notify", "parent=0x%lx", ev.xreparent.parent);
                break;

            case ConfigureNotify:
                const cw = ev.xconfigure.width, ch = ev.xconfigure.height;
                if (cw != width || ch != height)
                {
                    width = cw;
                    height = ch;
                    emitf("resize", "size=%dx%d scale=1", width, height);
                    destroyBackbuffer(dpy, buf);
                    buf = createBackbuffer(dpy, visual, depth, width, height, haveShm);
                    emitf("buffer_realloc", "size=%dx%d shm=%d", width, height,
                        cast(int) buf.usingShm);
                }
                break;

            case Expose:
                if (ev.xexpose.count == 0 && !sawFirstPixel)
                {
                    // Present the very first frame eagerly so the run is
                    // anchored; afterwards only ticks present.
                    fillColorCycle(buf.ximg, colorPhase);
                    if (buf.usingShm)
                    {
                        XShmPutImage(dpy, win, gc, buf.ximg, 0, 0, 0, 0,
                            cast(uint) buf.width, cast(uint) buf.height, True);
                        XFlush(dpy);
                        awaitingCompletion = true;
                    }
                    else
                    {
                        XPutImage(dpy, win, gc, buf.ximg, 0, 0, 0, 0,
                            cast(uint) buf.width, cast(uint) buf.height);
                        XSync(dpy, False);
                    }
                    sawFirstPixel = true;
                    emit("first_pixel_presented");
                }
                break;

            case ClientMessage:
                if (cast(Atom) ev.xclient.data.l[0] == wmDelete)
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
                if (buf.usingShm && ev.type == shmCompletionType)
                    awaitingCompletion = false;
                break;
            }
        }

        // -- Wait for either X traffic or the next animation tick -------------
        pollfd[2] pfds;
        pfds[0].fd = xfd;
        pfds[0].events = POLLIN;
        pfds[0].revents = 0;
        pfds[1].fd = tfd;
        pfds[1].events = POLLIN;
        pfds[1].revents = 0;
        poll(pfds.ptr, 2, -1);

        if (!(pfds[1].revents & POLLIN) || !sawFirstPixel)
            continue; // X traffic only — loop back to drain it

        ulong expirations;
        read(tfd, &expirations, expirations.sizeof);

        // -- One animation tick ------------------------------------------------
        ++ticks;
        colorPhase += 8; // 8/256 per 16 ms tick ≈ 2 full cycles per second
        const phaseIdx = ticks <= calmEnd ? 0 : ticks <= selfEnd ? 1
            : ticks <= extEnd ? 2 : 3;

        // The storm driver: during `self`/`ext`, fire a resize every other
        // tick while the animation must keep its cadence.
        if (autoExit && (phaseIdx == 1 || phaseIdx == 2) && (ticks & 1) == 0)
        {
            const s = sizes[sizeIdx % $];
            ++sizeIdx;
            if (phaseIdx == 1)
            {
                XResizeWindow(dpy, win, cast(uint) s[0], cast(uint) s[1]);
                emitf("step", "name=XResizeWindow conn=self n=%d size=%dx%d",
                    phaseResizes[1] + 1, s[0], s[1]);
            }
            else
            {
                if (dpy2 is null)
                {
                    dpy2 = XOpenDisplay(null);
                    emitf("step", "name=XOpenDisplay conn=external fd=%d",
                        dpy2 !is null ? XConnectionNumber(dpy2) : -1);
                }
                if (dpy2 !is null)
                {
                    XResizeWindow(dpy2, win, cast(uint) s[0], cast(uint) s[1]);
                    XSync(dpy2, False);
                    emitf("step", "name=XResizeWindow conn=external n=%d size=%dx%d",
                        phaseResizes[2] + 1, s[0], s[1]);
                }
            }
            ++phaseResizes[phaseIdx];
        }

        // Present this tick's color. With MIT-SHM the segment must not be
        // rewritten while the server still reads it; a tick that lands inside
        // that sub-millisecond window is logged presented=0 (the heartbeat
        // still beat — only the pixels waited one frame).
        bool presented = false;
        if (!awaitingCompletion && buf.ximg !is null)
        {
            fillColorCycle(buf.ximg, colorPhase);
            if (buf.usingShm)
            {
                XShmPutImage(dpy, win, gc, buf.ximg, 0, 0, 0, 0,
                    cast(uint) buf.width, cast(uint) buf.height, True);
                XFlush(dpy);
                awaitingCompletion = true;
            }
            else
            {
                XPutImage(dpy, win, gc, buf.ximg, 0, 0, 0, 0,
                    cast(uint) buf.width, cast(uint) buf.height);
                XSync(dpy, False);
            }
            presented = true;
        }

        const now = nowUs();
        const gap = lastTickUs == 0 ? 0 : now - lastTickUs;
        lastTickUs = now;
        ++phaseTicks[phaseIdx];
        if (gap > maxGap[phaseIdx])
            maxGap[phaseIdx] = gap;
        emitf("tick", "t=%lld n=%d phase=%s presented=%d gap_us=%lld",
            now, ticks, phaseNames[phaseIdx].ptr, cast(int) presented, gap);

        if (autoExit && ticks >= lastTick)
            break;
    }

    // -- The F03 verdict: per-phase tick cadence under resize fire -------------
    foreach (i, name; phaseNames)
        emitf("gap_summary", "phase=%s ticks=%d resizes=%d max_gap_us=%lld",
            name.ptr, phaseTicks[i], phaseResizes[i], maxGap[i]);
    const stormMax = maxGap[1] > maxGap[2] ? maxGap[1] : maxGap[2];
    emitf("finding", "modal_loop=absent max_gap_storm_us=%lld errors=%d",
        stormMax, g_xErrors);
    emit("teardown");
    return g_xErrors == 0 ? 0 : 1;
}
