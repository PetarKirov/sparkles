// X11 F09 demo — output enumeration & hotplug (../../../features/f09-outputs.md).
// Built on the scaffold (../scaffold/app.d): same ImportC binding style, same
// poll(2)-driven readiness loop, same instrument.d event log. Rendering is a
// plain background-pixel window — pixels are irrelevant to this row.
//
// The deliverable is the DISTINCTION between RandR's two enumeration APIs:
//
//   * `XRRGetMonitors` (RandR >= 1.5) — the "modern" per-monitor view: logical
//     rectangles a desktop is tiled into (name atom, geometry, primary flag,
//     physical mm). No modes, no refresh — that lives a level below.
//   * `XRRGetScreenResources` + `XRRGetOutputInfo`/`XRRGetCrtcInfo` (1.2) —
//     the wiring-level object model: outputs (connectors) -> crtcs (scanout
//     engines) -> modes (timing blocks). Refresh is not a stored field; it is
//     COMPUTED from the mode timings: refresh = dotClock / (hTotal * vTotal),
//     and the demo logs that math term by term.
//
// Window<->output occupancy is DERIVED (X11 has no equivalent of Wayland's
// `wl_surface.enter/leave`): on every ConfigureNotify the demo translates its
// origin to root coordinates (XTranslateCoordinates) and intersects its rect
// with each monitor rect, emitting `surface_output enter/leave` on changes.
// Under WSI_AUTO_EXIT it proves the derivation with an XMoveWindow storm that
// slides the window half off, fully off, and back onto the only monitor.
//
// Hotplug: XRRSelectInput(RRScreenChangeNotifyMask | RRCrtcChangeNotifyMask |
// RROutputChangeNotifyMask | RROutputPropertyNotifyMask) on the root; every
// RRScreenChangeNotify / RRNotify is logged and answered by a re-enumeration
// that diffs the output set (`output_added`/`output_removed`). Xvfb's output
// set is static, so the run.sh driver exercises what IS reachable (xrandr
// --dpi, output property writes / non-desktop soft-unplug, and real pixel-size
// switches on a nested Xephyr); a true connector unplug is a Tier C item —
// see ../../f09-outputs.md.
//
// WSI_AUTO_EXIT=1 bounds the run (WSI_DURATION_MS, default 6 s). Headless-
// safe: no X server -> prints `SKIP:` and exits 0.
module app;

import c; // ImportC: Xlib + Xrandr + poll
import instrument;

import core.stdc.config : c_long, c_ulong;
import core.stdc.stdio : printf, snprintf;
import core.stdc.stdlib : atoi, getenv;

// ---------------------------------------------------------------------------
// Constants Xlib/Xrandr expose as macros that ImportC cannot import;
// re-declared per the scaffold gotcha (../../scaffold.md).

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

enum // Xrandr.h: event codes (offsets from the extension event base) ...
{
    RRScreenChangeNotify = 0,
    RRNotify = 1,
    RRNotify_CrtcChange = 0, // ... XRRNotifyEvent.subtype values ...
    RRNotify_OutputChange = 1,
    RRNotify_OutputProperty = 2,
}

enum : c_long // ... XRRSelectInput masks ...
{
    RRScreenChangeNotifyMask = 1L << 0,
    RRCrtcChangeNotifyMask = 1L << 1,
    RROutputChangeNotifyMask = 1L << 2,
    RROutputPropertyNotifyMask = 1L << 3,
}

enum // ... and Connection states.
{
    RR_Connected = 0,
    RR_Disconnected = 1,
    RR_UnknownConnection = 2,
}

// ---------------------------------------------------------------------------
// Modern view: XRRGetMonitors. Monitors are kept in a fixed table so the
// occupancy derivation can intersect against them on every ConfigureNotify.

struct MonitorRect
{
    char[64] name;
    int x, y, w, h;
    int primary;
}

__gshared MonitorRect[16] g_monitors;
__gshared int g_nMonitors = 0;

/// Enumerate via XRRGetMonitors (RandR >= 1.5): the per-monitor logical view.
/// Note what is and is NOT here: name/geometry/primary/physical-mm — but no
/// mode and no refresh; those belong to the object model below.
void enumerateMonitors(Display* dpy, Window root) @nogc nothrow
{
    int n = 0;
    XRRMonitorInfo* mons = XRRGetMonitors(dpy, root, True, &n);
    g_nMonitors = 0;
    if (mons is null)
    {
        emit("monitors api=XRRGetMonitors result=null");
        return;
    }
    foreach (i; 0 .. n)
    {
        auto m = &mons[i];
        char* name = XGetAtomName(dpy, m.name);
        emitf("output", "api=XRRGetMonitors id=%s geom=%dx%d+%d+%d mm=%dx%d "
                ~ "primary=%d automatic=%d noutput=%d refresh=NOT_EXPOSED_HERE",
            name, m.width, m.height, m.x, m.y, m.mwidth, m.mheight,
            cast(int) m.primary, cast(int) m.automatic, m.noutput);
        if (g_nMonitors < g_monitors.length)
        {
            auto slot = &g_monitors[g_nMonitors++];
            snprintf(slot.name.ptr, slot.name.length, "%s", name);
            slot.x = m.x;
            slot.y = m.y;
            slot.w = m.width;
            slot.h = m.height;
            slot.primary = cast(int) m.primary;
        }
        XFree(name);
    }
    XRRFreeMonitors(mons);
}

/// Fallback monitor table when the server has no RandR 1.5 (e.g. Xephyr,
/// RandR 1.1): treat the whole core screen as one monitor rect, so the
/// occupancy derivation still works. The log says which source was used.
void coreScreenAsMonitor(Display* dpy, int screen) @nogc nothrow
{
    g_nMonitors = 1;
    auto slot = &g_monitors[0];
    snprintf(slot.name.ptr, slot.name.length, "core-screen");
    slot.x = 0;
    slot.y = 0;
    slot.w = XDisplayWidth(dpy, screen);
    slot.h = XDisplayHeight(dpy, screen);
    slot.primary = 1;
    emitf("output", "api=core_screen_fallback id=core-screen geom=%dx%d+0+0",
        slot.w, slot.h);
}

// ---------------------------------------------------------------------------
// Wiring-level view: screen resources -> outputs -> crtcs -> modes.
// The hotplug diff state is the OUTPUT set (connector list + connection).

struct OutputState
{
    c_ulong xid; // RROutput
    int connected;
    char[64] name;
}

__gshared OutputState[32] g_outputs;
__gshared int g_nOutputs = 0;

/// refresh = dotClock / (hTotal * vTotal) — the field RandR does NOT store.
double modeRefresh(const(XRRModeInfo)* m) @nogc nothrow
{
    if (m is null || m.hTotal == 0 || m.vTotal == 0)
        return 0;
    return cast(double) m.dotClock / (cast(double) m.hTotal * m.vTotal);
}

/// Enumerate via the RandR 1.2 object model and rebuild the output table.
/// `diff=true` compares against the previous table and emits
/// `output_added` / `output_removed` / `output_connection` events.
void enumerateResources(Display* dpy, Window root, bool diff) @nogc nothrow
{
    XRRScreenResources* res = XRRGetScreenResources(dpy, root);
    if (res is null)
    {
        emit("resources api=XRRGetScreenResources result=null");
        return;
    }
    emitf("resources", "api=XRRGetScreenResources noutput=%d ncrtc=%d nmode=%d",
        res.noutput, res.ncrtc, res.nmode);

    OutputState[32] prev = g_outputs;
    const nPrev = g_nOutputs;
    g_nOutputs = 0;

    foreach (i; 0 .. res.noutput)
    {
        XRROutputInfo* oi = XRRGetOutputInfo(dpy, res, res.outputs[i]);
        if (oi is null)
            continue;
        if (oi.crtc != 0)
        {
            XRRCrtcInfo* ci = XRRGetCrtcInfo(dpy, res, oi.crtc);
            // Find the XRRModeInfo the crtc's mode XID names, for the timings.
            const(XRRModeInfo)* mi = null;
            if (ci !is null)
                foreach (k; 0 .. res.nmode)
                    if (res.modes[k].id == ci.mode)
                        mi = &res.modes[k];
            if (ci !is null && mi !is null)
                emitf("output", "api=resources id=%s output=0x%lx crtc=0x%lx "
                        ~ "geom=%ux%u+%d+%d mm=%lux%lu mode=%s "
                        ~ "refresh=dotClock/(hTotal*vTotal)=%lu/(%u*%u)=%.2fHz",
                    oi.name, cast(c_ulong) res.outputs[i], cast(c_ulong) oi.crtc,
                    ci.width, ci.height, ci.x, ci.y, oi.mm_width, oi.mm_height,
                    mi.name, cast(c_ulong) mi.dotClock, mi.hTotal, mi.vTotal,
                    modeRefresh(mi));
            else
                emitf("output", "api=resources id=%s output=0x%lx crtc=0x%lx mode=unresolved",
                    oi.name, cast(c_ulong) res.outputs[i], cast(c_ulong) oi.crtc);
            if (ci !is null)
                XRRFreeCrtcInfo(ci);
        }
        else
            emitf("output", "api=resources id=%s output=0x%lx crtc=none connection=%d "
                    ~ "(connected-but-off or disconnected connector)",
                oi.name, cast(c_ulong) res.outputs[i], cast(int) oi.connection);

        if (g_nOutputs < g_outputs.length)
        {
            auto slot = &g_outputs[g_nOutputs++];
            slot.xid = cast(c_ulong) res.outputs[i];
            slot.connected = oi.connection == RR_Connected;
            snprintf(slot.name.ptr, slot.name.length, "%s", oi.name);
        }
        XRRFreeOutputInfo(oi);
    }
    XRRFreeScreenResources(res);

    if (!diff)
        return;
    foreach (i; 0 .. g_nOutputs) // added / reconnected
    {
        bool found = false;
        foreach (j; 0 .. nPrev)
            if (prev[j].xid == g_outputs[i].xid)
            {
                found = true;
                if (prev[j].connected != g_outputs[i].connected)
                    emitf("output_connection", "id=%s connected=%d",
                        g_outputs[i].name.ptr, g_outputs[i].connected);
            }
        if (!found)
            emitf("output_added", "id=%s output=0x%lx",
                g_outputs[i].name.ptr, g_outputs[i].xid);
    }
    foreach (j; 0 .. nPrev) // removed
    {
        bool found = false;
        foreach (i; 0 .. g_nOutputs)
            if (g_outputs[i].xid == prev[j].xid)
                found = true;
        if (!found)
            emitf("output_removed", "id=%s output=0x%lx", prev[j].name.ptr, prev[j].xid);
    }
}

// ---------------------------------------------------------------------------
// Occupancy: which monitor rect(s) does the window's root-space rect overlap?
// X11 never tells a window this — it is derived geometry, recomputed on every
// ConfigureNotify and after every monitor-layout change. (Wayland instead
// delivers `wl_surface.enter/leave` to the surface directly.)

__gshared uint g_occupied = 0; // bitmask over g_monitors

void computeOccupancy(Display* dpy, Window win, Window root, int w, int h) @nogc nothrow
{
    // ConfigureNotify's x/y are relative to the parent; translate to root
    // coordinates so the rect lives in the same space as the monitor rects.
    int rx, ry;
    Window child;
    XTranslateCoordinates(dpy, win, root, 0, 0, &rx, &ry, &child);

    uint now = 0;
    foreach (i; 0 .. g_nMonitors)
    {
        const m = &g_monitors[i];
        const ix = (rx + w < m.x + m.w ? rx + w : m.x + m.w) - (rx > m.x ? rx : m.x);
        const iy = (ry + h < m.y + m.h ? ry + h : m.y + m.h) - (ry > m.y ? ry : m.y);
        if (ix > 0 && iy > 0)
        {
            now |= 1u << i;
            if (!(g_occupied & (1u << i)))
                emitf("surface_output", "enter id=%s overlap=%dx%d of=%dx%d "
                        ~ "derived=window_rect(%d,%d,%dx%d)_vs_monitor_rect",
                    m.name.ptr, ix, iy, w, h, rx, ry, w, h);
        }
    }
    foreach (i; 0 .. g_nMonitors)
        if ((g_occupied & (1u << i)) && !(now & (1u << i)))
            emitf("surface_output", "leave id=%s", g_monitors[i].name.ptr);
    if (now == 0 && g_occupied != 0)
        emitf("surface_output", "none window=(%d,%d,%dx%d) outside all monitors "
                ~ "(window keeps running; nothing tells it)", rx, ry, w, h);
    g_occupied = now;
}

// ---------------------------------------------------------------------------

int main()
{
    initInstrument("f09_x11");
    const envAuto = getenv("WSI_AUTO_EXIT");
    const autoExit = envAuto !is null && envAuto[0] == '1';
    const envDur = getenv("WSI_DURATION_MS");
    const durationMs = envDur !is null ? atoi(envDur) : 6_000;

    Display* dpy = XOpenDisplay(null);
    if (dpy is null)
    {
        printf("SKIP: no X11 display (XOpenDisplay returned null)\n");
        return 0;
    }
    emitf("step", "name=XOpenDisplay fd=%d", XConnectionNumber(dpy));

    const screen = XDefaultScreen(dpy);
    Window root = XRootWindow(dpy, screen);

    // -- RandR availability gates which of the two APIs exist ----------------
    int rrEventBase = -1, rrErrorBase = -1, rrMajor = 0, rrMinor = 0;
    const haveRandr = XRRQueryExtension(dpy, &rrEventBase, &rrErrorBase) != 0;
    if (haveRandr)
        XRRQueryVersion(dpy, &rrMajor, &rrMinor);
    emitf("step", "name=XRRQueryExtension available=%d version=%d.%d event_base=%d",
        cast(int) haveRandr, rrMajor, rrMinor, rrEventBase);
    const haveResources = haveRandr && (rrMajor > 1 || rrMinor >= 2);
    const haveMonitors = haveRandr && (rrMajor > 1 || rrMinor >= 5);

    // -- Enumeration, both ways (no window needed — only the connection) -----
    if (haveMonitors)
        enumerateMonitors(dpy, root);
    else
        coreScreenAsMonitor(dpy, screen);
    if (haveResources)
        enumerateResources(dpy, root, false);
    else
        emitf("resources", "api=XRRGetScreenResources unavailable (server randr %d.%d < 1.2)",
            rrMajor, rrMinor);

    // -- Subscribe to change events; only 1.0's screen-change bit is safe on
    //    an old server, the 1.2+ bits would be a BadValue there. -------------
    if (haveRandr)
    {
        c_long mask = RRScreenChangeNotifyMask;
        if (haveResources)
            mask |= RRCrtcChangeNotifyMask | RROutputChangeNotifyMask
                | RROutputPropertyNotifyMask;
        XRRSelectInput(dpy, root, cast(int) mask);
        emitf("step", "name=XRRSelectInput mask=0x%lx", mask);
    }

    // -- Window (background-pixel rendering; pixels are not this row's job) --
    int width = 320, height = 240;
    Window win = XCreateSimpleWindow(dpy, root, 40, 40, width, height, 1,
        XBlackPixel(dpy, screen), XWhitePixel(dpy, screen));
    XStoreName(dpy, win, "Sparkles · X11 F09 outputs");
    Atom wmDelete = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
    XSetWMProtocols(dpy, win, &wmDelete, 1);
    XSelectInput(dpy, win, ExposureMask | KeyPressMask | StructureNotifyMask);
    XMapWindow(dpy, win);
    emitf("window_created", "xid=0x%lx size=%dx%d pos=40,40", win, width, height);

    const fd = XConnectionNumber(dpy);
    bool running = true;
    int rrScreenChanges = 0, rrNotifies = 0, moveStep = 0;
    // The auto-exit move storm: half off the monitor, fully off, back on.
    static immutable int[2][3] moves = [[-160, 40], [-1000, 40], [40, 40]];

    while (running)
    {
        while (XPending(dpy) > 0)
        {
            XEvent ev;
            XNextEvent(dpy, &ev);

            if (haveRandr && ev.type == rrEventBase + RRScreenChangeNotify)
            {
                ++rrScreenChanges;
                auto rr = cast(XRRScreenChangeNotifyEvent*)&ev;
                emitf("randr_screen_change", "px=%dx%d mm=%dx%d size_index=%d rotation=%d",
                    rr.width, rr.height, rr.mwidth, rr.mheight,
                    cast(int) rr.size_index, cast(int) rr.rotation);
                XRRUpdateConfiguration(&ev); // refresh Xlib's cached screen size
                if (haveMonitors)
                    enumerateMonitors(dpy, root);
                else
                    coreScreenAsMonitor(dpy, screen);
                if (haveResources)
                    enumerateResources(dpy, root, true);
                computeOccupancy(dpy, win, root, width, height);
                continue;
            }
            if (haveRandr && ev.type == rrEventBase + RRNotify)
            {
                ++rrNotifies;
                auto nev = cast(XRRNotifyEvent*)&ev;
                if (nev.subtype == RRNotify_OutputChange)
                {
                    auto oev = cast(XRROutputChangeNotifyEvent*)&ev;
                    emitf("randr_notify", "subtype=OutputChange output=0x%lx crtc=0x%lx "
                            ~ "mode=0x%lx connection=%d",
                        cast(c_ulong) oev.output, cast(c_ulong) oev.crtc,
                        cast(c_ulong) oev.mode, cast(int) oev.connection);
                }
                else if (nev.subtype == RRNotify_OutputProperty)
                {
                    auto pev = cast(XRROutputPropertyNotifyEvent*)&ev;
                    char* prop = XGetAtomName(dpy, pev.property);
                    emitf("randr_notify", "subtype=OutputProperty output=0x%lx property=%s state=%d",
                        cast(c_ulong) pev.output, prop, pev.state);
                    XFree(prop);
                }
                else
                    emitf("randr_notify", "subtype=%d", nev.subtype);
                if (haveMonitors)
                    enumerateMonitors(dpy, root);
                if (haveResources)
                    enumerateResources(dpy, root, true);
                computeOccupancy(dpy, win, root, width, height);
                continue;
            }

            switch (ev.type)
            {
            case MapNotify:
                computeOccupancy(dpy, win, root, width, height);
                break;
            case ConfigureNotify:
                width = ev.xconfigure.width;
                height = ev.xconfigure.height;
                emitf("configure", "pos=%d,%d size=%dx%d",
                    ev.xconfigure.x, ev.xconfigure.y, width, height);
                computeOccupancy(dpy, win, root, width, height);
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

        if (autoExit)
        {
            const elapsedMs = nowUs() / 1000;
            // One move per second starting at t=1s: exercises the occupancy
            // derivation against the (single) monitor without any driver.
            if (moveStep < moves.length && elapsedMs > 1000 * (moveStep + 1))
            {
                emitf("step", "name=XMoveWindow n=%d pos=%d,%d",
                    moveStep + 1, moves[moveStep][0], moves[moveStep][1]);
                XMoveWindow(dpy, win, moves[moveStep][0], moves[moveStep][1]);
                XFlush(dpy); // push the request before sleeping in poll()
                ++moveStep;
            }
            if (elapsedMs > durationMs)
            {
                emit("auto_exit");
                break;
            }
        }

        pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLIN;
        pfd.revents = 0;
        poll(&pfd, 1, autoExit ? 100 : -1);
    }

    emitf("summary", "monitors=%d outputs=%d randr_screen_changes=%d randr_notifies=%d",
        g_nMonitors, g_nOutputs, rrScreenChanges, rrNotifies);

    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
    emit("teardown");
    return 0;
}
