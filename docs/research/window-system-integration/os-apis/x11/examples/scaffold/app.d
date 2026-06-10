// X11 windowing-demo scaffold — the evolved form of ../../example/app.d (the
// irreducible Xlib window). On top of the minimal sequence it implements the
// full demo contract every feature demo (F01..F17) in this tree follows:
//
//   * WM_PROTOCOLS / WM_DELETE_WINDOW close handshake (graceful close)
//   * software gradient presented through MIT-SHM (XShmCreateImage /
//     XShmPutImage with a requested XShmCompletionEvent); when the extension
//     is absent (or attach fails) it logs `step name=shm_fallback` and uses
//     plain XPutImage + XSync instead
//   * readiness event loop: poll(2) on the connection fd
//     (ConnectionNumber(dpy), reached via its function form XConnectionNumber
//     since the macro is not ImportC-able), draining with XPending/XNextEvent
//     after readiness — never blocking inside XNextEvent
//   * redraw on Expose; image + SHM segment reallocation on ConfigureNotify
//     size changes; clean teardown (XShmDetach -> destroy_image -> shmdt)
//   * instrumentation per the F01 spec (../../../features/f01-first-pixel.md)
//     via instrument.d: init_start, step name=<api>, window_created,
//     first_configure, first_pixel_presented, resize, frame_callback,
//     close_requested
//   * WSI_AUTO_EXIT=1 -> bounded run (~120 redraws or ~2 s) including a
//     10-step programmatic XResizeWindow storm (F02 spec), then exit 0;
//     otherwise runs until the WM delivers WM_DELETE_WINDOW
//
// Headless-safe: if no X server is reachable, prints `SKIP:` to stdout and
// exits 0. See ../../index.md (the X11 OS-API survey) and ../../scaffold.md
// (the findings this program produced).
module app;

import c; // ImportC: Xlib + Xutil + Xatom + XShm + sys/ipc + sys/shm + poll
import instrument;

import core.stdc.config : c_long, c_ulong;
import core.stdc.stdio : printf;
import core.stdc.stdlib : getenv;

// ---------------------------------------------------------------------------
// Constants Xlib/glibc expose as macros that ImportC does not reliably import
// (expression macros like `(1L<<15)` and cast-expressions like IPC_PRIVATE).
// Re-declared per the ImportC guide; module-local declarations shadow any
// same-named enums the shim may have imported.

enum : c_long
{
    KeyPressMask = 1L << 0,
    ExposureMask = 1L << 15,
    StructureNotifyMask = 1L << 17,
}

enum // XEvent.type discriminators
{
    KeyPress = 2,
    MapNotify = 19,
    ConfigureNotify = 22,
    Expose = 12,
    ClientMessage = 33,
}

enum ZPixmap = 2; // XImage format
enum ShmCompletion = 0; // event offset inside MIT-SHM's allocated event range
enum False = 0;
enum True = 1;
enum POLLIN = 0x001;
enum IPC_PRIVATE = 0;
enum IPC_CREAT = 0x200; // 01000 octal
enum IPC_RMID = 0;

// ---------------------------------------------------------------------------
// The software framebuffer: an XImage either backed by a SysV shared-memory
// segment the X server attaches (MIT-SHM, zero protocol-stream copies) or by
// a malloc'd buffer pushed through the wire with XPutImage.

struct Backbuffer
{
    XImage* ximg;
    XShmSegmentInfo shminfo;
    bool usingShm;
    int width, height;
}

/// (Re)allocate the backbuffer at `w`x`h`. Tries MIT-SHM when `wantShm`;
/// falls back to a plain client-side XImage (and reports it) on any failure.
/// `logSteps` makes the first allocation emit one `step` line per API call.
Backbuffer createBackbuffer(Display* dpy, Visual* visual, int depth,
    int w, int h, bool wantShm, bool logSteps) @nogc nothrow
{
    Backbuffer b;
    b.width = w;
    b.height = h;

    if (wantShm)
    {
        b.ximg = XShmCreateImage(dpy, visual, cast(uint) depth, ZPixmap,
            null, &b.shminfo, cast(uint) w, cast(uint) h);
        if (logSteps && b.ximg !is null)
            emitf("step", "name=XShmCreateImage size=%dx%d bpl=%d bpp=%d",
                w, h, b.ximg.bytes_per_line, b.ximg.bits_per_pixel);
        if (b.ximg !is null)
        {
            const nbytes = cast(size_t)(b.ximg.bytes_per_line * b.ximg.height);
            b.shminfo.shmid = shmget(IPC_PRIVATE, nbytes, IPC_CREAT | 0x180 /* 0600 */ );
            if (logSteps)
                emitf("step", "name=shmget shmid=%d bytes=%zu", b.shminfo.shmid, nbytes);
            if (b.shminfo.shmid >= 0)
            {
                b.shminfo.shmaddr = cast(char*) shmat(b.shminfo.shmid, null, 0);
                if (logSteps)
                    emitf("step", "name=shmat ok=%d", cast(int)(b.shminfo.shmaddr !is cast(char*)-1));
                if (b.shminfo.shmaddr !is cast(char*)-1)
                {
                    b.ximg.data = b.shminfo.shmaddr;
                    b.shminfo.readOnly = False;
                    XShmAttach(dpy, &b.shminfo); // async request: server maps the segment
                    XSync(dpy, False); // round-trip so the server has attached ...
                    shmctl(b.shminfo.shmid, IPC_RMID, null); // ... before we mark-for-delete
                    if (logSteps)
                    {
                        emit("step name=XShmAttach");
                        emit("step name=XSync");
                        emit("step name=shmctl_IPC_RMID");
                    }
                    b.usingShm = true;
                    return b;
                }
                shmctl(b.shminfo.shmid, IPC_RMID, null);
            }
            b.ximg.f.destroy_image(b.ximg); // XDestroyImage is a macro; call its body
            b.ximg = null;
        }
        emitf("step", "name=shm_fallback reason=%s",
            b.ximg is null ? "alloc_failed".ptr : "attach_failed".ptr);
    }

    // Plain path: client-side buffer, pixels travel through the X byte stream.
    import core.stdc.stdlib : malloc;

    auto data = cast(char*) malloc(cast(size_t) w * h * 4);
    b.ximg = XCreateImage(dpy, visual, cast(uint) depth, ZPixmap, 0, data,
        cast(uint) w, cast(uint) h, 32, 0);
    if (logSteps)
        emitf("step", "name=XCreateImage size=%dx%d bpl=%d bpp=%d",
            w, h, b.ximg.bytes_per_line, b.ximg.bits_per_pixel);
    b.usingShm = false;
    return b;
}

/// Tear down in the order the MIT-SHM spec prescribes:
/// XShmDetach -> XDestroyImage -> shmdt (the segment id was already
/// IPC_RMID-marked at creation, so the kernel frees it once both detach).
void destroyBackbuffer(Display* dpy, ref Backbuffer b) @nogc nothrow
{
    if (b.ximg is null)
        return;
    if (b.usingShm)
    {
        XSync(dpy, False); // let any in-flight XShmPutImage finish reading
        XShmDetach(dpy, &b.shminfo);
    }
    b.ximg.f.destroy_image(b.ximg); // shm variant frees only the struct; plain variant frees data too
    if (b.usingShm)
        shmdt(b.shminfo.shmaddr);
    b.ximg = null;
}

/// Corner-anchored diagonal gradient so stretching / stale buffers during the
/// resize storm are visible (F02 requirement 1). `phase` animates the blue
/// channel so successive frames are distinguishable.
void drawGradient(XImage* ximg, int phase) @nogc nothrow
{
    const w = ximg.width, h = ximg.height;
    if (ximg.bits_per_pixel == 32)
    {
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
    else // unexpected visual: visible flat fill rather than garbage
    {
        import core.stdc.string : memset;

        memset(ximg.data, 0x55, cast(size_t)(ximg.bytes_per_line * h));
    }
}

int main()
{
    initInstrument("x11_scaffold");
    const envAuto = getenv("WSI_AUTO_EXIT");
    const autoExit = envAuto !is null && envAuto[0] == '1';

    // -- Connect ------------------------------------------------------------
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

    // -- MIT-SHM availability (this query is a round-trip) -------------------
    // WSI_NO_SHM=1 forces the plain-XPutImage path (what a TCP/remote display
    // would get: MIT-SHM only works when client and server share a kernel).
    bool haveShm = XShmQueryExtension(dpy) != 0;
    emitf("step", "name=XShmQueryExtension available=%d", cast(int) haveShm);
    int shmCompletionType = -1;
    if (haveShm && getenv("WSI_NO_SHM") !is null)
    {
        haveShm = false;
        emit("step name=shm_fallback reason=WSI_NO_SHM");
    }
    else if (haveShm)
    {
        shmCompletionType = XShmGetEventBase(dpy) + ShmCompletion;
        emitf("step", "name=XShmGetEventBase completion_event=%d", shmCompletionType);
    }
    else
        emit("step name=shm_fallback reason=extension_absent");

    // -- Window + WM close handshake -----------------------------------------
    int width = 480, height = 320;
    Window win = XCreateSimpleWindow(dpy, root, 0, 0, width, height, 1,
        XBlackPixel(dpy, screen), XWhitePixel(dpy, screen));
    emitf("step", "name=XCreateSimpleWindow xid=0x%lx", win);
    XStoreName(dpy, win, "Sparkles · X11 scaffold");
    emit("step name=XStoreName");

    Atom wmDelete = XInternAtom(dpy, "WM_DELETE_WINDOW", False); // round-trip
    emitf("step", "name=XInternAtom atom=%lu", wmDelete);
    XSetWMProtocols(dpy, win, &wmDelete, 1);
    emit("step name=XSetWMProtocols");

    XSelectInput(dpy, win, ExposureMask | KeyPressMask | StructureNotifyMask);
    emit("step name=XSelectInput");
    XMapWindow(dpy, win);
    emit("step name=XMapWindow");
    emitf("window_created", "xid=0x%lx size=%dx%d", win, width, height);

    GC gc = XDefaultGC(dpy, screen);

    // -- Backbuffer -----------------------------------------------------------
    auto buf = createBackbuffer(dpy, visual, depth, width, height, haveShm, true);
    scope (exit)
    {
        destroyBackbuffer(dpy, buf);
        XDestroyWindow(dpy, win);
        XCloseDisplay(dpy);
    }

    // -- Event loop: poll(2) the connection fd, drain with XPending -----------
    // The resize storm the F02 spec asks for: 10 XResizeWindow calls of
    // varying sizes, one every ~10 frames, so event-loop turns interleave.
    static immutable int[2][10] storm = [
        [640, 400], [320, 240], [800, 520], [400, 300], [720, 480],
        [360, 260], [900, 560], [480, 300], [560, 380], [640, 420],
    ];

    const fd = XConnectionNumber(dpy);
    bool running = true, needsRedraw = false, awaitingCompletion = false;
    bool sawFirstConfigure = false, sawFirstPixel = false;
    int frames = 0, phase = 0, resizesIssued = 0;

    while (running)
    {
        // Drain everything already queued / readable. XPending flushes the
        // output buffer as a side effect, so buffered requests always reach
        // the server before we sleep in poll().
        while (XPending(dpy) > 0)
        {
            XEvent ev;
            XNextEvent(dpy, &ev); // does not block: an event is pending
            switch (ev.type)
            {
            case MapNotify:
                if (!sawFirstConfigure)
                {
                    sawFirstConfigure = true;
                    emitf("first_configure", "kind=MapNotify size=%dx%d", width, height);
                }
                break;

            case ConfigureNotify:
                const cw = ev.xconfigure.width, ch = ev.xconfigure.height;
                if (!sawFirstConfigure)
                {
                    sawFirstConfigure = true;
                    emitf("first_configure", "kind=ConfigureNotify size=%dx%d", cw, ch);
                }
                if (cw != width || ch != height)
                {
                    width = cw;
                    height = ch;
                    emitf("resize", "size=%dx%d scale=1", width, height);
                    destroyBackbuffer(dpy, buf);
                    buf = createBackbuffer(dpy, visual, depth, width, height, haveShm, false);
                    emitf("buffer_realloc", "size=%dx%d shm=%d bytes=%d", width, height,
                        cast(int) buf.usingShm, buf.ximg.bytes_per_line * buf.ximg.height);
                    needsRedraw = true;
                }
                break;

            case Expose:
                emitf("expose", "count=%d area=%dx%d+%d+%d", ev.xexpose.count,
                    ev.xexpose.width, ev.xexpose.height, ev.xexpose.x, ev.xexpose.y);
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
                {
                    awaitingCompletion = false;
                    if (!sawFirstPixel)
                    {
                        sawFirstPixel = true;
                        const sh = cast(const XShmCompletionEvent*)&ev;
                        emitf("first_pixel_presented",
                            "method=XShmCompletionEvent drawable=0x%lx", sh.drawable);
                    }
                }
                break;
            }
        }

        // Auto-exit drive: animate continuously and feed the resize storm.
        if (autoExit && sawFirstPixel && !awaitingCompletion)
        {
            if (resizesIssued < storm.length && frames >= (resizesIssued + 1) * 10)
            {
                const s = storm[resizesIssued];
                XResizeWindow(dpy, win, cast(uint) s[0], cast(uint) s[1]);
                emitf("step", "name=XResizeWindow n=%d size=%dx%d",
                    resizesIssued + 1, s[0], s[1]);
                ++resizesIssued;
            }
            ++phase;
            needsRedraw = true;
        }

        // Present a frame. With MIT-SHM the segment must not be rewritten
        // until the server is done reading it, so we request a completion
        // event (send_event=True) and gate the next draw on it.
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
                XSync(dpy, False); // no completion contract: round-trip instead
                if (!sawFirstPixel)
                {
                    sawFirstPixel = true;
                    emit("first_pixel_presented method=XPutImage_XSync");
                }
            }
            ++frames;
            emitf("frame_callback", "t=%lld frame=%d size=%dx%d",
                nowUs(), frames, buf.width, buf.height);
            needsRedraw = false;
        }

        if (autoExit && (frames >= 120 || nowUs() > 2_000_000))
        {
            emitf("auto_exit", "frames=%d resizes=%d", frames, resizesIssued);
            break;
        }

        // Readiness wait on the X connection fd — the loop a real app would
        // multiplex with its own timers/sockets. Auto mode ticks at ~5 ms so
        // animation frames keep flowing even when the queue is silent.
        pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLIN;
        pfd.revents = 0;
        poll(&pfd, 1, autoExit ? 5 : -1);
    }

    emit("teardown");
    return 0;
}
