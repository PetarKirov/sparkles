// F01 — first pixel & init cost, X11 edition (../../../features/f01-first-pixel.md).
// Derived from the X11 scaffold (../scaffold/app.d), cut down to exactly the
// init-to-first-pixel path: connect, create + map a window, allocate a MIT-SHM
// backbuffer, draw one gradient, present it, and exit as soon as the present is
// confirmed.
//
// Every initialization API call emits one `step name=<call>` line, tagged
// `rt=1` when the call blocks on a server reply (a round-trip in Xlib's
// output-buffer model) and `rt=0` when it only appends to the output buffer.
// X11 is the platform where this distinction is the finding: most of "window
// creation" is free local marshalling, and the wall-clock cost concentrates in
// the handful of reply-bearing calls (XOpenDisplay, XShmQueryExtension,
// XInternAtom, the XSetWMProtocols hidden InternAtom, and the one deliberate
// XSync in the SHM attach dance).
//
//   WSI_SYNC_STEPS=1  brackets every *async* request with an XSync and logs
//                     `step name=XSync after=<call> us=<cost>` — measuring the
//                     server-side processing each fire-and-forget call hides.
//   WSI_NO_SHM=1      forces the plain XPutImage fallback; first pixel is then
//                     only `method=XPutImage_XSync` (server *processed* the
//                     put — core X11 cannot confirm presentation; without the
//                     Present extension that caveat is structural, and with
//                     MIT-SHM the completion event still only means "the
//                     server is done *reading* the segment").
//
// After `first_pixel_presented` the demo emits one summary line:
//   summary concepts=<N> loc=<N> init_to_pixel_us=<N>
// concepts = distinct platform object/handle types touched (the F01 concept
// count, itemized in ../../scaffold.md); loc = lines of this file (excluding
// instrument.d and c.c), kept in sync manually with `wc -l app.d`.
//
// Headless-safe: no reachable X server prints `SKIP:` and exits 0. Findings:
// ../../f01-first-pixel.md.
module app;

import c; // ImportC: Xlib + Xutil + Xatom + XShm + sys/ipc + sys/shm + poll
import instrument;

import core.stdc.config : c_long;
import core.stdc.stdio : printf;
import core.stdc.stdlib : getenv;

// Constants Xlib/glibc expose only as macros (not ImportC-able); re-declared
// per the ImportC guide, same as the scaffold.
enum : c_long
{
    ExposureMask = 1L << 15,
    StructureNotifyMask = 1L << 17,
}

enum // XEvent.type discriminators
{
    Expose = 12,
    MapNotify = 19,
    ConfigureNotify = 22,
}

enum ZPixmap = 2;
enum ShmCompletion = 0; // offset inside MIT-SHM's allocated event range
enum False = 0;
enum True = 1;
enum POLLIN = 0x001;
enum IPC_PRIVATE = 0;
enum IPC_CREAT = 0x200; // 01000 octal
enum IPC_RMID = 0;

/// This file's line count — the F01 LOC figure (excludes instrument.d / c.c).
/// Keep in sync with `wc -l app.d`.
enum locCount = 359;

__gshared bool g_syncSteps = false;

/// `step name=<call> rt=<0|1>` — one line per init API call. `rt=1` marks a
/// call that blocked on a server reply.
void step(Display* dpy, const(char)* name, bool roundTrip) @nogc nothrow
{
    emitf("step", "name=%s rt=%d", name, cast(int) roundTrip);
}

/// WSI_SYNC_STEPS=1: bracket an async request with XSync to surface the
/// server-side cost the fire-and-forget call hides.
void syncPoint(Display* dpy, const(char)* after) @nogc nothrow
{
    if (!g_syncSteps)
        return;
    const t0 = nowUs();
    XSync(dpy, False);
    emitf("step", "name=XSync after=%s us=%lld", after, nowUs() - t0);
}

/// Corner-anchored diagonal gradient (the scaffold's, phase 0 — one frame).
void drawGradient(XImage* ximg) @nogc nothrow
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
            row[x] = (r << 16) | (g << 8) | cast(uint)((x + y) & 0xff);
        }
    }
}

int main()
{
    initInstrument("f01_x11");
    g_syncSteps = getenv("WSI_SYNC_STEPS") !is null;

    // -- 1. Connect (concept 1: Display*) — the one unavoidable round-trip:
    //    socket connect + authentication + the connection-setup reply.
    Display* dpy = XOpenDisplay(null);
    if (dpy is null)
    {
        printf("SKIP: no X11 display (XOpenDisplay returned null)\n");
        return 0;
    }
    step(dpy, "XOpenDisplay", true);
    emitf("step", "name=XConnectionNumber fd=%d rt=0", XConnectionNumber(dpy));

    const screen = XDefaultScreen(dpy); // local: reads connection-setup data
    const root = XRootWindow(dpy, screen);
    Visual* visual = XDefaultVisual(dpy, screen); // concept 4: Visual*
    const depth = XDefaultDepth(dpy, screen);
    step(dpy, "XDefaultScreen/Root/Visual/Depth", false);

    // -- 2. MIT-SHM availability — QueryExtension is reply-bearing.
    bool haveShm = XShmQueryExtension(dpy) != 0;
    emitf("step", "name=XShmQueryExtension available=%d rt=1", cast(int) haveShm);
    int shmCompletionType = -1;
    if (haveShm && getenv("WSI_NO_SHM") !is null)
    {
        haveShm = false;
        emit("step name=shm_fallback reason=WSI_NO_SHM");
    }
    else if (haveShm)
    {
        // Local: libXext cached the extension info during the query above.
        shmCompletionType = XShmGetEventBase(dpy) + ShmCompletion;
        emitf("step", "name=XShmGetEventBase completion_event=%d rt=0", shmCompletionType);
    }
    else
        emit("step name=shm_fallback reason=extension_absent");

    // -- 3. Window (concept 2: Window, an XID minted client-side) ------------
    const width = 480, height = 320;
    Window win = XCreateSimpleWindow(dpy, root, 0, 0, width, height, 1,
        XBlackPixel(dpy, screen), XWhitePixel(dpy, screen));
    emitf("step", "name=XCreateSimpleWindow xid=0x%lx rt=0", win);
    syncPoint(dpy, "XCreateSimpleWindow");

    XStoreName(dpy, win, "Sparkles · X11 F01");
    step(dpy, "XStoreName", false);
    syncPoint(dpy, "XStoreName");

    // -- 4. Close handshake (concept 3: Atom). XInternAtom carries a reply;
    //    XSetWMProtocols additionally interns WM_PROTOCOLS itself — a *hidden*
    //    second InternAtom round-trip (xtrace-confirmed in ../../scaffold.md).
    Atom wmDelete = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
    emitf("step", "name=XInternAtom atom=%lu rt=1", wmDelete);
    XSetWMProtocols(dpy, win, &wmDelete, 1);
    emit("step name=XSetWMProtocols rt=1 note=hidden_InternAtom");

    XSelectInput(dpy, win, ExposureMask | StructureNotifyMask);
    step(dpy, "XSelectInput", false);
    XMapWindow(dpy, win);
    step(dpy, "XMapWindow", false);
    syncPoint(dpy, "XMapWindow");
    emitf("window_created", "xid=0x%lx size=%dx%d", win, width, height);

    GC gc = XDefaultGC(dpy, screen); // concept 5: GC (the default one)

    // -- 5. Backbuffer: concepts 6 (XImage*), 7 (ShmSeg XID), 9 (SysV shm
    //    segment, a kernel handle — not an X concept at all).
    XImage* ximg;
    XShmSegmentInfo shminfo;
    bool usingShm = false;
    if (haveShm)
    {
        ximg = XShmCreateImage(dpy, visual, cast(uint) depth, ZPixmap,
            null, &shminfo, width, height);
        if (ximg !is null)
        {
            emitf("step", "name=XShmCreateImage size=%dx%d bpl=%d bpp=%d rt=0",
                width, height, ximg.bytes_per_line, ximg.bits_per_pixel);
            const nbytes = cast(size_t)(ximg.bytes_per_line * ximg.height);
            shminfo.shmid = shmget(IPC_PRIVATE, nbytes, IPC_CREAT | 0x180 /* 0600 */ );
            emitf("step", "name=shmget shmid=%d bytes=%zu rt=kernel", shminfo.shmid, nbytes);
            if (shminfo.shmid >= 0)
            {
                shminfo.shmaddr = cast(char*) shmat(shminfo.shmid, null, 0);
                emitf("step", "name=shmat ok=%d rt=kernel",
                    cast(int)(shminfo.shmaddr !is cast(char*)-1));
                if (shminfo.shmaddr !is cast(char*)-1)
                {
                    ximg.data = shminfo.shmaddr;
                    shminfo.readOnly = False;
                    XShmAttach(dpy, &shminfo);
                    emit("step name=XShmAttach rt=0");
                    // The one deliberate round-trip of SHM setup: the server
                    // must have attached before we mark-for-delete, so the
                    // kernel reclaims the segment even if we crash.
                    const t0 = nowUs();
                    XSync(dpy, False);
                    emitf("step", "name=XSync rt=1 us=%lld", nowUs() - t0);
                    shmctl(shminfo.shmid, IPC_RMID, null);
                    emit("step name=shmctl_IPC_RMID rt=kernel");
                    usingShm = true;
                }
                else
                    shmctl(shminfo.shmid, IPC_RMID, null);
            }
            if (!usingShm)
            {
                ximg.f.destroy_image(ximg); // XDestroyImage is a macro
                ximg = null;
            }
        }
        if (!usingShm)
            emit("step name=shm_fallback reason=alloc_or_attach_failed");
    }
    if (!usingShm)
    {
        import core.stdc.stdlib : malloc;

        auto data = cast(char*) malloc(cast(size_t) width * height * 4);
        ximg = XCreateImage(dpy, visual, cast(uint) depth, ZPixmap, 0, data,
            width, height, 32, 0);
        emitf("step", "name=XCreateImage size=%dx%d bpl=%d bpp=%d rt=0",
            width, height, ximg.bytes_per_line, ximg.bits_per_pixel);
    }

    scope (exit)
    {
        if (usingShm)
        {
            XSync(dpy, False); // drain the in-flight put before detaching
            XShmDetach(dpy, &shminfo);
        }
        ximg.f.destroy_image(ximg);
        if (usingShm)
            shmdt(shminfo.shmaddr);
        XDestroyWindow(dpy, win);
        XCloseDisplay(dpy);
    }

    // -- 6. Wait for Expose (the server's "draw now" signal), present once,
    //    and wait for the confirmation event. concept 8: XEvent.
    const fd = XConnectionNumber(dpy);
    bool exposed = false, presented = false, confirmed = false;
    bool sawFirstConfigure = false;

    while (!confirmed)
    {
        while (XPending(dpy) > 0) // XPending flushes the output buffer
        {
            XEvent ev;
            XNextEvent(dpy, &ev);
            switch (ev.type)
            {
            case MapNotify:
                // No WM: MapNotify (not ConfigureNotify) is the first
                // structure event — waiting for ConfigureNotify deadlocks.
                if (!sawFirstConfigure)
                {
                    sawFirstConfigure = true;
                    emitf("first_configure", "kind=MapNotify size=%dx%d", width, height);
                }
                else
                    emit("map_notify");
                break;

            case ConfigureNotify: // only under a WM (reparent/placement)
                if (!sawFirstConfigure)
                {
                    sawFirstConfigure = true;
                    emitf("first_configure", "kind=ConfigureNotify size=%dx%d send_event=%d",
                        ev.xconfigure.width, ev.xconfigure.height,
                        cast(int) ev.xany.send_event);
                }
                else
                    emitf("configure_notify", "size=%dx%d send_event=%d",
                        ev.xconfigure.width, ev.xconfigure.height,
                        cast(int) ev.xany.send_event);
                break;

            case Expose:
                emitf("expose", "count=%d area=%dx%d+%d+%d", ev.xexpose.count,
                    ev.xexpose.width, ev.xexpose.height, ev.xexpose.x, ev.xexpose.y);
                if (ev.xexpose.count == 0)
                    exposed = true;
                break;

            default:
                if (usingShm && ev.type == shmCompletionType)
                {
                    // The server finished *reading* the segment. This is the
                    // strongest confirmation core X11 + MIT-SHM offers; it is
                    // still not "on glass" — that needs the Present extension.
                    const sh = cast(const XShmCompletionEvent*)&ev;
                    emitf("first_pixel_presented",
                        "method=XShmCompletionEvent drawable=0x%lx", sh.drawable);
                    confirmed = true;
                }
                break;
            }
        }

        if (exposed && !presented)
        {
            drawGradient(ximg);
            if (usingShm)
            {
                XShmPutImage(dpy, win, gc, ximg, 0, 0, 0, 0,
                    width, height, True); // send_event=True -> completion event
                XFlush(dpy); // push the put before sleeping in poll()
                emit("step name=XShmPutImage rt=0 send_event=1");
            }
            else
            {
                XPutImage(dpy, win, gc, ximg, 0, 0, 0, 0, width, height);
                emit("step name=XPutImage rt=0");
                const t0 = nowUs();
                XSync(dpy, False); // no completion contract: round-trip instead
                emitf("step", "name=XSync rt=1 us=%lld", nowUs() - t0);
                // Proves the server *processed* the put — nothing more.
                emit("first_pixel_presented method=XPutImage_XSync");
                confirmed = true;
            }
            presented = true;
            emitf("frame_callback", "t=%lld frame=1 size=%dx%d", nowUs(), width, height);
        }

        if (!confirmed)
        {
            pollfd pfd;
            pfd.fd = fd;
            pfd.events = POLLIN;
            pfd.revents = 0;
            poll(&pfd, 1, 1000); // bounded: a silent server can't hang the demo
            if (nowUs() > 5_000_000)
            {
                emit("auto_exit reason=timeout");
                return 1;
            }
        }
    }

    // concepts: Display*, Window, Atom, Visual*, GC, XImage*, XEvent = 7;
    // MIT-SHM adds the ShmSeg XID and the kernel shm segment = 9.
    emitf("summary", "concepts=%d loc=%d init_to_pixel_us=%lld",
        usingShm ? 9 : 7, locCount, nowUs());
    emit("teardown");
    return 0;
}
