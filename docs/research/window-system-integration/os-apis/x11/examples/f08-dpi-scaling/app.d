// X11 F08 demo — DPI / runtime rescale (../../../features/f08-dpi-scaling.md).
// Built on the scaffold (../scaffold/app.d): same ImportC binding style, same
// poll(2)-driven readiness loop, same instrument.d event log (plain XPutImage
// presentation — MIT-SHM is irrelevant to this row).
//
// X11's answer to "what happens when the scale changes under a live window"
// is THE deliverable: there is no runtime mechanism. The demo proves it by
// measurement rather than assertion:
//
//   * At startup it snapshots everything a toolkit can know: `Xft.dpi` from
//     the RESOURCE_MANAGER root property (XResourceManagerString +
//     XrmGetResource), the core screen's pixel + millimeter size (=> computed
//     DPI), and per-output RandR physical/pixel sizes (=> per-monitor DPI).
//   * It then keeps running while the run.sh driver changes everything that
//     is changeable (`xrdb -merge` a new Xft.dpi, `xrandr --dpi`), and logs
//     (a) every event delivered to its own window — expecting NONE related to
//     the change — and (b) the root-window PropertyNotify on RESOURCE_MANAGER
//     it gets ONLY because it explicitly selected PropertyChangeMask on the
//     root: the live channel some toolkits use, a convention, not a protocol.
//   * On that PropertyNotify it re-reads the property two ways:
//     XResourceManagerString (Xlib's snapshot, cached at connect time — stays
//     STALE) and XGetWindowProperty (fresh) — the trap is part of the proof.
//   * RandR change events (RRScreenChangeNotify) are selected too, so if the
//     server CAN signal a geometry/physical-size change, it is captured.
//
// Rendering: gradient + a crisp 1-px black hairline at the window edge and a
// horizontal bar sized `dpi` pixels (F08 requirement 1: scaling artifacts
// must be visible). WSI_AUTO_EXIT=1 bounds the run (WSI_DURATION_MS, default
// 10 s). Headless-safe: no X server -> prints `SKIP:` and exits 0.
// Findings: ../../f08-dpi-scaling.md.
module app;

import c; // ImportC: Xlib + Xutil + Xatom + Xresource + Xrandr + poll
import instrument;

import core.stdc.config : c_long, c_ulong;
import core.stdc.stdio : printf, snprintf;
import core.stdc.stdlib : atoi, free, getenv, malloc;
import core.stdc.string : strstr;

// ---------------------------------------------------------------------------
// Constants Xlib/Xatom/Xrandr expose as macros that ImportC cannot import;
// re-declared per the scaffold gotcha.

enum : c_long
{
    KeyPressMask = 1L << 0,
    ExposureMask = 1L << 15,
    StructureNotifyMask = 1L << 17,
    PropertyChangeMask = 1L << 22,
}

enum // XEvent.type discriminators
{
    KeyPress = 2,
    Expose = 12,
    MapNotify = 19,
    ConfigureNotify = 22,
    PropertyNotify = 28,
    ClientMessage = 33,
}

enum False = 0;
enum True = 1;
enum POLLIN = 0x001;
enum ZPixmap = 2;
enum AnyPropertyType = 0;
enum Atom XA_RESOURCE_MANAGER = 23; // Xatom.h cast-expression macro
enum Atom XA_STRING = 31;

enum // Xrandr.h
{
    RRScreenChangeNotify = 0, // event offset from the extension's event base
    RRScreenChangeNotifyMask = 1L << 0,
    RRCrtcChangeNotifyMask = 1L << 1,
    RROutputChangeNotifyMask = 1L << 2,
    RR_Connected = 0,
}

// ---------------------------------------------------------------------------
// Reading Xft.dpi out of a resource string ("Xft.dpi:\t144\n...").

/// Parse `Xft.dpi` from a RESOURCE_MANAGER-style resource string via the Xrm
/// machinery (XrmGetStringDatabase + XrmGetResource — the same lookup
/// toolkits do). Returns the value or -1 when the resource is absent.
/// `who` labels the source in the log (startup / stale / fresh).
double readXftDpi(const(char)* resStr, const(char)* who) @nogc nothrow
{
    if (resStr is null)
    {
        emitf("xft_dpi", "source=%s present=0 (no RESOURCE_MANAGER property)", who);
        return -1;
    }
    XrmDatabase db = XrmGetStringDatabase(resStr);
    char* type;
    XrmValue val;
    double dpi = -1;
    if (XrmGetResource(db, "Xft.dpi", "Xft.Dpi", &type, &val) && val.addr !is null)
    {
        import core.stdc.stdlib : strtod;

        dpi = strtod(cast(const char*) val.addr, null);
        emitf("xft_dpi", "source=%s present=1 value=%s scale_vs_96=%.2f",
            who, cast(const char*) val.addr, dpi / 96.0);
    }
    else
        emitf("xft_dpi", "source=%s present=0 (property exists, no Xft.dpi key)", who);
    XrmDestroyDatabase(db);
    return dpi;
}

/// Fetch the RESOURCE_MANAGER property *fresh* off the root window.
/// XResourceManagerString does NOT do this — it returns the value Xlib
/// snapshotted inside XOpenDisplay; this is the live read.
char* fetchResourceManager(Display* dpy, Window root) @nogc nothrow
{
    Atom actualType;
    int actualFormat;
    c_ulong nitems, bytesAfter;
    ubyte* prop;
    const r = XGetWindowProperty(dpy, root, XA_RESOURCE_MANAGER, 0, 1 << 20,
        False, XA_STRING, &actualType, &actualFormat, &nitems, &bytesAfter, &prop);
    if (r != 0 /*Success*/ || prop is null)
        return null;
    return cast(char*) prop; // NUL-terminated by Xlib; caller XFree()s
}

/// Log the core screen + every RandR output's pixel/physical size and the
/// DPI each implies. This is the complete startup snapshot a toolkit gets.
void logDpiSnapshot(Display* dpy, int screen, Window root, bool haveRandr) @nogc nothrow
{
    // Core protocol: one screen-wide size in pixels and millimeters, fixed at
    // connection setup (Xlib caches it; DisplayWidthMM is the function form
    // XDisplayWidthMM since the macro is not ImportC-able).
    const px = XDisplayWidth(dpy, screen), py = XDisplayHeight(dpy, screen);
    const mmx = XDisplayWidthMM(dpy, screen), mmy = XDisplayHeightMM(dpy, screen);
    emitf("core_screen", "px=%dx%d mm=%dx%d dpi=%.1fx%.1f", px, py, mmx, mmy,
        mmx > 0 ? px * 25.4 / mmx : -1.0, mmy > 0 ? py * 25.4 / mmy : -1.0);

    if (!haveRandr)
        return;
    XRRScreenResources* res = XRRGetScreenResourcesCurrent(dpy, root);
    if (res is null)
        return;
    foreach (i; 0 .. res.noutput)
    {
        XRROutputInfo* oi = XRRGetOutputInfo(dpy, res, res.outputs[i]);
        if (oi is null)
            continue;
        int cw = 0, ch = 0;
        if (oi.crtc != 0)
        {
            XRRCrtcInfo* ci = XRRGetCrtcInfo(dpy, res, oi.crtc);
            if (ci !is null)
            {
                cw = ci.width;
                ch = ci.height;
                XRRFreeCrtcInfo(ci);
            }
        }
        emitf("randr_output", "name=%s connected=%d px=%dx%d mm=%lux%lu dpi=%.1fx%.1f",
            oi.name, cast(int)(oi.connection == RR_Connected), cw, ch,
            oi.mm_width, oi.mm_height,
            oi.mm_width > 0 ? cw * 25.4 / oi.mm_width : -1.0,
            oi.mm_height > 0 ? ch * 25.4 / oi.mm_height : -1.0);
        XRRFreeOutputInfo(oi);
    }
    XRRFreeScreenResources(res);
}

// ---------------------------------------------------------------------------
// Rendering: gradient, 1-px hairline border, and a dpi-length bar.

void draw(XImage* img, double xftDpi) @nogc nothrow
{
    const w = img.width, h = img.height;
    if (img.bits_per_pixel != 32)
        return;
    foreach (y; 0 .. h)
    {
        auto row = cast(uint*)(img.data + y * img.bytes_per_line);
        const g = cast(uint)(h > 1 ? (y * 255) / (h - 1) : 0);
        foreach (x; 0 .. w)
        {
            const r = cast(uint)(w > 1 ? (x * 255) / (w - 1) : 0);
            uint pixel = (r << 16) | (g << 8) | 0xc0;
            // 1-physical-px black hairline at the very edge (F08 req 1):
            // under any kind of scaling/stretching it stops being 1 px.
            if (x == 0 || y == 0 || x == w - 1 || y == h - 1)
                pixel = 0;
            // The dpi bar: a white bar `xftDpi` pixels long (96 -> short,
            // 144 -> visibly longer) so a live Xft.dpi change WOULD be
            // visible — it never is, because no event triggers a redraw.
            if (y >= 10 && y < 26 && x >= 8 && x < 8 + cast(int)(xftDpi > 0 ? xftDpi : 0))
                pixel = 0xffffff;
            row[x] = pixel;
        }
    }
}

int main()
{
    initInstrument("f08_x11");
    const envAuto = getenv("WSI_AUTO_EXIT");
    const autoExit = envAuto !is null && envAuto[0] == '1';
    const envDur = getenv("WSI_DURATION_MS");
    const durationMs = envDur !is null ? atoi(envDur) : 10_000;

    XrmInitialize();

    Display* dpy = XOpenDisplay(null);
    if (dpy is null)
    {
        printf("SKIP: no X11 display (XOpenDisplay returned null)\n");
        return 0;
    }
    emitf("step", "name=XOpenDisplay fd=%d", XConnectionNumber(dpy));

    const screen = XDefaultScreen(dpy);
    Window root = XRootWindow(dpy, screen);
    Visual* visual = XDefaultVisual(dpy, screen);
    const depth = XDefaultDepth(dpy, screen);

    // -- RandR availability ----------------------------------------------------
    int rrEventBase = -1, rrErrorBase = -1, rrMajor = 0, rrMinor = 0;
    const haveRandr = XRRQueryExtension(dpy, &rrEventBase, &rrErrorBase) != 0;
    if (haveRandr)
        XRRQueryVersion(dpy, &rrMajor, &rrMinor);
    emitf("step", "name=XRRQueryExtension available=%d version=%d.%d event_base=%d",
        cast(int) haveRandr, rrMajor, rrMinor, rrEventBase);

    // -- The startup snapshot: everything a toolkit can ever know -------------
    const(char)* rmSnapshot = XResourceManagerString(dpy); // cached at connect
    double xftDpi = readXftDpi(rmSnapshot, "startup_XResourceManagerString");
    logDpiSnapshot(dpy, screen, root, haveRandr);

    // -- Subscribe to the only live channels that exist ------------------------
    // (a) PropertyNotify on the ROOT window: RESOURCE_MANAGER is a root
    //     property, so a client that explicitly selects PropertyChangeMask on
    //     the root sees `xrdb -merge` happen. No standard says it must look.
    XSelectInput(dpy, root, PropertyChangeMask);
    emit("step name=XSelectInput window=root mask=PropertyChangeMask");
    // (b) RandR change events (screen size / output / crtc changes).
    if (haveRandr)
    {
        XRRSelectInput(dpy, root, RRScreenChangeNotifyMask
                | RRCrtcChangeNotifyMask | RROutputChangeNotifyMask);
        emit("step name=XRRSelectInput mask=screen_change|crtc|output");
    }

    // -- Window + backbuffer (plain XPutImage; SHM is noise here) -------------
    int width = 480, height = 320;
    Window win = XCreateSimpleWindow(dpy, root, 0, 0, width, height, 1,
        XBlackPixel(dpy, screen), XWhitePixel(dpy, screen));
    XStoreName(dpy, win, "Sparkles · X11 F08 dpi");
    Atom wmDelete = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
    XSetWMProtocols(dpy, win, &wmDelete, 1);
    XSelectInput(dpy, win, ExposureMask | KeyPressMask | StructureNotifyMask
            | PropertyChangeMask); // PropertyChangeMask on the WINDOW too — to
    // prove nothing DPI-ish ever arrives there either.
    XMapWindow(dpy, win);
    emitf("window_created", "xid=0x%lx size=%dx%d scale=assumed_1", win, width, height);

    GC gc = XDefaultGC(dpy, screen);
    XImage* img = XCreateImage(dpy, visual, cast(uint) depth, ZPixmap, 0,
        cast(char*) malloc(cast(size_t) width * height * 4),
        cast(uint) width, cast(uint) height, 32, 0);

    const fd = XConnectionNumber(dpy);
    bool running = true, needsRedraw = false, snapshotDone = false;
    int windowEventsAfterStartup = 0, rootPropertyNotifies = 0, randrNotifies = 0;

    while (running)
    {
        while (XPending(dpy) > 0)
        {
            XEvent ev;
            XNextEvent(dpy, &ev);

            // RandR's RRScreenChangeNotify arrives at a dynamic type code.
            if (haveRandr && ev.type == rrEventBase + RRScreenChangeNotify)
            {
                ++randrNotifies;
                auto rr = cast(XRRScreenChangeNotifyEvent*)&ev;
                emitf("randr_screen_change", "px=%dx%d mm=%dx%d dpi=%.1fx%.1f",
                    rr.width, rr.height, rr.mwidth, rr.mheight,
                    rr.mwidth > 0 ? rr.width * 25.4 / rr.mwidth : -1.0,
                    rr.mheight > 0 ? rr.height * 25.4 / rr.mheight : -1.0);
                // Refresh Xlib's cached core-screen values (they are a connect-
                // time snapshot too) and log what the core API now reports.
                XRRUpdateConfiguration(&ev);
                emitf("core_screen_after_update", "px=%dx%d mm=%dx%d",
                    XDisplayWidth(dpy, screen), XDisplayHeight(dpy, screen),
                    XDisplayWidthMM(dpy, screen), XDisplayHeightMM(dpy, screen));
                continue;
            }

            // Root-window events: the RESOURCE_MANAGER live channel.
            if (ev.xany.window == root && ev.type == PropertyNotify)
            {
                ++rootPropertyNotifies;
                char* name = XGetAtomName(dpy, ev.xproperty.atom);
                emitf("root_property_notify", "atom=%s state=%s", name,
                    ev.xproperty.state == 0 ? "NewValue".ptr : "Deleted".ptr);
                XFree(name);
                if (ev.xproperty.atom == XA_RESOURCE_MANAGER)
                {
                    // The trap: Xlib's own accessor still returns the value
                    // cached at XOpenDisplay time ...
                    readXftDpi(XResourceManagerString(dpy),
                        "stale_XResourceManagerString");
                    // ... a fresh XGetWindowProperty sees the new one.
                    char* fresh = fetchResourceManager(dpy, root);
                    xftDpi = readXftDpi(fresh, "fresh_XGetWindowProperty");
                    if (fresh !is null)
                        XFree(fresh);
                    needsRedraw = true; // ONLY because we chose to watch root
                }
                continue;
            }

            // Everything else is addressed to our window. After startup
            // settles, each one is logged — the absence of any DPI-related
            // event here is the finding.
            if (ev.xany.window == win && snapshotDone)
            {
                ++windowEventsAfterStartup;
                emitf("window_event", "type=%d", ev.type);
            }

            switch (ev.type)
            {
            case Expose:
                if (ev.xexpose.count == 0)
                    needsRedraw = true;
                break;
            case ConfigureNotify:
                if (ev.xconfigure.width != width || ev.xconfigure.height != height)
                {
                    width = ev.xconfigure.width;
                    height = ev.xconfigure.height;
                    emitf("resize", "size=%dx%d scale=still_assumed_1", width, height);
                    img.f.destroy_image(img); // XDestroyImage macro's body
                    img = XCreateImage(dpy, visual, cast(uint) depth, ZPixmap, 0,
                        cast(char*) malloc(cast(size_t) width * height * 4),
                        cast(uint) width, cast(uint) height, 32, 0);
                    needsRedraw = true;
                }
                break;
            case MapNotify:
                snapshotDone = true;
                emit("startup_snapshot_complete (window events are counted from here)");
                break;
            case ClientMessage:
                if (cast(Atom) ev.xclient.data.l[0] == wmDelete)
                {
                    emit("close_requested via=WM_DELETE_WINDOW");
                    running = false;
                }
                break;
            case KeyPress:
                running = false;
                break;
            default:
                break;
            }
        }

        if (needsRedraw && img !is null)
        {
            draw(img, xftDpi);
            XPutImage(dpy, win, gc, img, 0, 0, 0, 0,
                cast(uint) width, cast(uint) height);
            XFlush(dpy); // push the put before sleeping in poll()
            needsRedraw = false;
        }

        if (autoExit && nowUs() > cast(long) durationMs * 1000)
        {
            emit("auto_exit");
            break;
        }

        pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLIN;
        pfd.revents = 0;
        poll(&pfd, 1, autoExit ? 100 : -1);
    }

    emitf("summary", "root_property_notifies=%d randr_notifies=%d "
            ~ "window_events_after_startup=%d final_xft_dpi=%.1f",
        rootPropertyNotifies, randrNotifies, windowEventsAfterStartup, xftDpi);

    img.f.destroy_image(img);
    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
    emit("teardown");
    return 0;
}
