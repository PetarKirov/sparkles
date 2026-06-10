// F02 — resize correctness, X11 edition (../../../features/f02-resize.md).
// Derived from the X11 scaffold (../scaffold/app.d). A continuously refreshed
// corner-anchored gradient survives an aggressive programmatic resize storm
// driven over BOTH paths a real X11 window experiences:
//
//   1. self-resize  — XResizeWindow on the demo's own connection (an app
//      resizing itself), including one burst of three back-to-back requests;
//   2. external resize — a SECOND Display* connection (opened mid-run, same
//      process) resizes the window by XID, exactly what a window manager or
//      `xdotool` does. The window is a server-side resource: any
//      authenticated client may configure it.
//
// Logged per the F02 spec, with everything needed to compare the two paths:
//   * every ConfigureNotify:  configure_notify size=WxH pos=X+Y serial=N
//     send_event=0|1 override=0|1  (send_event=1 marks an ICCCM *synthetic*
//     ConfigureNotify, the kind WMs send on move; serial ties the event to
//     the last request the server processed *on this connection* — external
//     resizes arrive under a stale serial)
//   * every Expose (`expose count=… area=…`), every buffer (re)allocation
//     (`buffer_realloc`), every resize request (`step name=XResizeWindow…`)
//   * `stale_frame` — a frame presented at the old size between a resize
//     request and its ConfigureNotify; XResizeWindow is asynchronous, so one
//     such frame per resize is structural on X11 (the artifact window that
//     Wayland's configure/ack protocol closes)
//   * `quirk name=beyond_screen` — ConfigureNotify reporting a size larger
//     than the screen (the storm includes 900x560 on Xvfb's 640x480) while
//     the matching Expose stays clipped to the visible region
//   * `x_error` — every protocol error, via XSetErrorHandler; the run must
//     end `errors=0`
//
// WSI_AUTO_EXIT=1 bounds the run (storm + drain, then exit 0); otherwise it
// runs until WM_DELETE_WINDOW. Headless-safe: no display prints `SKIP:` and
// exits 0. Findings: ../../f02-resize.md.
module app;

import c; // ImportC: Xlib + Xutil + Xatom + XShm + sys/ipc + sys/shm + poll
import instrument;

import core.stdc.config : c_long, c_ulong;
import core.stdc.stdio : printf;
import core.stdc.stdlib : getenv;

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
    UnmapNotify = 18,
    MapNotify = 19,
    ReparentNotify = 21,
    ConfigureNotify = 22,
    GravityNotify = 24,
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

// ---------------------------------------------------------------------------
// Protocol-error accounting (F02: "no protocol errors"). Xlib reports errors
// asynchronously through this handler; the demo logs each and tallies them.

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

/// Corner-anchored diagonal gradient: red tracks x/width, green tracks
/// y/height, so the geometry visibly re-anchors at every size (F02 req. 1);
/// `phase` animates the blue channel so successive frames are distinguishable.
void drawGradient(XImage* ximg, int phase) @nogc nothrow
{
    const w = ximg.width, h = ximg.height;
    if (ximg.bits_per_pixel != 32)
        return;
    foreach (y; 0 .. h)
    {
        auto row = cast(uint*)(ximg.data + y * ximg.bytes_per_line);
        const g = cast(uint)(h > 1 ? (y * 255) / (h - 1) : 0);
        foreach (x; 0 .. w)
        {
            const r = cast(uint)(w > 1 ? (x * 255) / (w - 1) : 0);
            const bl = cast(uint)((x + y + phase) & 0xff);
            row[x] = (r << 16) | (g << 8) | bl;
        }
    }
}

int main()
{
    initInstrument("f02_x11");
    const envAuto = getenv("WSI_AUTO_EXIT");
    const autoExit = envAuto !is null && envAuto[0] == '1';

    XSetErrorHandler(&onXError);

    // -- Connection #1: the app's own ----------------------------------------
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
    const screenW = XDisplayWidth(dpy, screen), screenH = XDisplayHeight(dpy, screen);
    emitf("step", "name=XDisplayWidth/Height screen=%dx%d", screenW, screenH);

    bool haveShm = XShmQueryExtension(dpy) != 0 && getenv("WSI_NO_SHM") is null;
    int shmCompletionType = haveShm ? XShmGetEventBase(dpy) + ShmCompletion : -1;
    emitf("step", "name=XShmQueryExtension using_shm=%d", cast(int) haveShm);

    int width = 480, height = 320;
    Window win = XCreateSimpleWindow(dpy, root, 0, 0, width, height, 1,
        XBlackPixel(dpy, screen), XWhitePixel(dpy, screen));
    emitf("step", "name=XCreateSimpleWindow xid=0x%lx", win);
    XStoreName(dpy, win, "Sparkles · X11 F02");

    Atom wmDelete = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
    XSetWMProtocols(dpy, win, &wmDelete, 1);
    XSelectInput(dpy, win, ExposureMask | KeyPressMask | StructureNotifyMask);
    XMapWindow(dpy, win);
    emitf("window_created", "xid=0x%lx size=%dx%d", win, width, height);

    GC gc = XDefaultGC(dpy, screen);
    auto buf = createBackbuffer(dpy, visual, depth, width, height, haveShm);
    emitf("buffer_realloc", "size=%dx%d shm=%d bytes=%d", width, height,
        cast(int) buf.usingShm, buf.ximg.bytes_per_line * buf.ximg.height);

    // -- Connection #2: the "outside world" (WM / xdotool stand-in) ----------
    // Opened lazily when the external phase starts, closed when it ends.
    Display* dpy2 = null;

    scope (exit)
    {
        if (dpy2 !is null)
            XCloseDisplay(dpy2);
        destroyBackbuffer(dpy, buf);
        XDestroyWindow(dpy, win);
        XCloseDisplay(dpy);
    }

    // -- The storm ------------------------------------------------------------
    // Phase "self": 6 spaced XResizeWindow calls on dpy, then one burst of 3
    // back-to-back requests (aggressive: queued faster than frames present).
    // Phase "ext": 4 XResizeWindow calls on dpy2 — including 900x560, larger
    // than Xvfb's default 640x480 screen (the beyond-screen quirk).
    static immutable int[2][6] selfStorm = [
        [640, 400], [320, 240], [800, 520], [400, 300], [720, 480], [360, 260],
    ];
    static immutable int[2][3] burst = [[600, 380], [440, 300], [560, 360]];
    static immutable int[2][4] extStorm = [
        [500, 340], [900, 560], [300, 200], [480, 320],
    ];

    const fd = XConnectionNumber(dpy);
    bool running = true, needsRedraw = false, awaitingCompletion = false;
    bool sawFirstPixel = false, burstIssued = false;
    int frames = 0, phase = 0, selfIssued = 0, extIssued = 0;
    int pendingW = 0, pendingH = 0; // last size we *requested*, any connection
    int staleFrames = 0, reallocs = 1, configures = 0;

    while (running)
    {
        while (XPending(dpy) > 0) // XPending also flushes the output buffer
        {
            XEvent ev;
            XNextEvent(dpy, &ev);
            switch (ev.type)
            {
            case MapNotify:
                emitf("map_notify", "serial=%lu send_event=%d",
                    ev.xany.serial, cast(int) ev.xany.send_event);
                break;

            case ReparentNotify: // a WM adopted us (never seen on bare Xvfb)
                emitf("reparent_notify", "parent=0x%lx serial=%lu",
                    ev.xreparent.parent, ev.xany.serial);
                break;

            case UnmapNotify:
                emitf("unmap_notify", "serial=%lu", ev.xany.serial);
                break;

            case GravityNotify:
                emitf("gravity_notify", "pos=%d+%d", ev.xgravity.x, ev.xgravity.y);
                break;

            case ConfigureNotify:
                const cw = ev.xconfigure.width, ch = ev.xconfigure.height;
                ++configures;
                emitf("configure_notify",
                    "size=%dx%d pos=%d+%d serial=%lu send_event=%d override=%d",
                    cw, ch, ev.xconfigure.x, ev.xconfigure.y,
                    ev.xany.serial, cast(int) ev.xany.send_event,
                    cast(int) ev.xconfigure.override_redirect);
                if (cw > screenW || ch > screenH)
                    emitf("quirk", "name=beyond_screen configure=%dx%d screen=%dx%d",
                        cw, ch, screenW, screenH);
                if (cw == pendingW && ch == pendingH)
                    pendingW = pendingH = 0; // our request landed
                if (cw != width || ch != height)
                {
                    width = cw;
                    height = ch;
                    emitf("resize", "size=%dx%d scale=1", width, height);
                    destroyBackbuffer(dpy, buf);
                    buf = createBackbuffer(dpy, visual, depth, width, height, haveShm);
                    ++reallocs;
                    emitf("buffer_realloc", "size=%dx%d shm=%d bytes=%d", width, height,
                        cast(int) buf.usingShm, buf.ximg.bytes_per_line * buf.ximg.height);
                    needsRedraw = true;
                }
                break;

            case Expose:
                emitf("expose", "count=%d area=%dx%d+%d+%d serial=%lu", ev.xexpose.count,
                    ev.xexpose.width, ev.xexpose.height, ev.xexpose.x, ev.xexpose.y,
                    ev.xany.serial);
                if (ev.xexpose.count == 0) // last Expose of the batch
                    needsRedraw = true;
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

        // Storm driver (auto-exit mode): self resizes every ~6 frames, then
        // the burst, then external resizes from the second connection.
        if (autoExit && sawFirstPixel && !awaitingCompletion)
        {
            if (selfIssued < selfStorm.length && frames >= 6 * (selfIssued + 1))
            {
                const s = selfStorm[selfIssued];
                XResizeWindow(dpy, win, cast(uint) s[0], cast(uint) s[1]);
                emitf("step", "name=XResizeWindow conn=self n=%d size=%dx%d",
                    selfIssued + 1, s[0], s[1]);
                pendingW = s[0];
                pendingH = s[1];
                ++selfIssued;
            }
            else if (selfIssued == selfStorm.length && !burstIssued
                && frames >= 6 * (selfIssued + 1))
            {
                foreach (i, s; burst) // three requests, no frame in between
                {
                    XResizeWindow(dpy, win, cast(uint) s[0], cast(uint) s[1]);
                    emitf("step", "name=XResizeWindow conn=self_burst n=%zu size=%dx%d",
                        i + 1, s[0], s[1]);
                }
                pendingW = burst[$ - 1][0];
                pendingH = burst[$ - 1][1];
                burstIssued = true;
            }
            else if (burstIssued && extIssued < extStorm.length
                && frames >= 6 * (selfIssued + 2 + extIssued))
            {
                if (dpy2 is null)
                {
                    dpy2 = XOpenDisplay(null);
                    emitf("step", "name=XOpenDisplay conn=external fd=%d",
                        dpy2 !is null ? XConnectionNumber(dpy2) : -1);
                }
                if (dpy2 !is null)
                {
                    const s = extStorm[extIssued];
                    XResizeWindow(dpy2, win, cast(uint) s[0], cast(uint) s[1]);
                    XSync(dpy2, False); // make the external client synchronous
                    emitf("step", "name=XResizeWindow conn=external n=%d size=%dx%d",
                        extIssued + 1, s[0], s[1]);
                    pendingW = s[0];
                    pendingH = s[1];
                }
                ++extIssued;
                if (extIssued == extStorm.length && dpy2 !is null)
                {
                    XCloseDisplay(dpy2);
                    dpy2 = null;
                    emit("step name=XCloseDisplay conn=external");
                }
            }
            ++phase;
            needsRedraw = true;
        }

        // Present. A frame drawn while a resize request is still in flight is
        // the structural X11 stale-frame artifact — log it as such.
        if (needsRedraw && !awaitingCompletion && buf.ximg !is null)
        {
            drawGradient(buf.ximg, phase);
            if (buf.usingShm)
            {
                XShmPutImage(dpy, win, gc, buf.ximg, 0, 0, 0, 0,
                    cast(uint) buf.width, cast(uint) buf.height, True);
                XFlush(dpy); // push the put before sleeping in poll()
                awaitingCompletion = true;
            }
            else
            {
                XPutImage(dpy, win, gc, buf.ximg, 0, 0, 0, 0,
                    cast(uint) buf.width, cast(uint) buf.height);
                XSync(dpy, False);
            }
            if (!sawFirstPixel)
            {
                sawFirstPixel = true;
                emit("first_pixel_presented");
            }
            ++frames;
            if (pendingW != 0 && (buf.width != pendingW || buf.height != pendingH))
            {
                ++staleFrames;
                emitf("stale_frame", "frame=%d size=%dx%d pending=%dx%d",
                    frames, buf.width, buf.height, pendingW, pendingH);
            }
            emitf("frame_callback", "t=%lld frame=%d size=%dx%d",
                nowUs(), frames, buf.width, buf.height);
            needsRedraw = false;
        }

        if (autoExit && (frames >= 140 || nowUs() > 8_000_000))
        {
            emitf("auto_exit", "frames=%d self=%d burst=%d ext=%d", frames,
                selfIssued, cast(int) burstIssued * 3, extIssued);
            break;
        }

        pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLIN;
        pfd.revents = 0;
        poll(&pfd, 1, autoExit ? 5 : -1);
    }

    // The F02 verdict line: zero protocol errors, zero size mismatches at exit.
    emitf("summary", "configures=%d reallocs=%d stale_frames=%d errors=%d final=%dx%d",
        configures, reallocs, staleFrames, g_xErrors, width, height);
    emit("teardown");
    return g_xErrors == 0 ? 0 : 1;
}
