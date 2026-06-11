// F11 scroll-fidelity demo — every wl_pointer axis event with its FULL native
// payload, on top of the xdg-shell scaffold (../scaffold/app.d; findings:
// ../../scaffold.md, ../../f11-scroll.md).
//
// The wl_seat is bound at min(advertised, 9) so the whole axis vocabulary is
// on the table: `axis` (continuous length, wl_fixed), `axis_value120`
// (high-resolution wheel 120ths, seat v8+, replacing the deprecated
// `axis_discrete`), `axis_source` (wheel / finger / continuous / wheel_tilt),
// `axis_stop` (end of a scroll sequence — e.g. fingers lifted; the kinetic-
// scroll trigger), and `axis_relative_direction` (seat v9+, natural-scrolling
// signal). Every raw event is logged as it arrives, then `wl_pointer.frame`
// closes the group and a `frame` line summarizes it — the frame is the
// atomicity contract: all events since the last frame belong to one logical
// hardware event and must be interpreted together.
//
// On top of the raw stream the demo:
//   - accumulates axis_value120 into wheel DETENTS (carry the remainder —
//     truncating loses high-resolution sub-detent steps),
//   - scrolls a rendered ruler by the continuous `axis` length (over/under-
//     scroll would be visible as tick drift),
//   - emits per-gesture summaries (gesture = frames until axis_stop or a
//     400 ms idle gap): total value, total v120, detents, source.
//
// ./run.sh injects wheel scrolls via `wlrctl pointer scroll <dy> <dx>` under
// headless sway — what source/v120 a zwlr_virtual_pointer_v1 client produces
// is itself the finding about injection fidelity. The capability dance is the
// F12 lesson: headless sway's seat starts at capabilities=0, get_pointer
// before the capability ever existed is a fatal wlroots error, and each
// wlrctl invocation unplugs its device, so wl_pointer is destroyed/re-created
// on every capabilities edge. Headless-safe: no compositor → SKIP, exit 0; a
// seat-less compositor (headless weston) yields the registry probe only.
module app;

import c; // ImportC: wayland-client + xdg-shell glue
import instrument;
import core.stdc.stdio : printf;
import core.stdc.stdlib : atoi, getenv;
import core.stdc.string : strcmp;

enum int defaultWidth = 640;
enum int defaultHeight = 480;
enum long gestureGapUs = 400_000; // idle gap that closes a gesture

// -------------------------------------------------------------------- state

struct Buffer
{
    wl_buffer* handle;
    uint* pixels;
    size_t byteSize;
    int width, height;
    bool busy;
}

/// Everything that arrived for one axis since the last wl_pointer.frame.
struct AxisPending
{
    bool hasValue, hasV120, stop, hasDirection;
    double value = 0;
    int v120;
    uint direction;
}

__gshared
{
    wl_display* g_display;
    wl_registry* g_registry;
    wl_compositor* g_compositor;
    wl_shm* g_shm;
    xdg_wm_base* g_wmBase;
    wl_seat* g_seat;
    wl_pointer* g_pointer;
    wl_surface* g_surface;
    xdg_surface* g_xdgSurface;
    xdg_toplevel* g_toplevel;
    wl_callback* g_frameCb;

    Buffer[2] g_buffers;
    int g_width = defaultWidth, g_height = defaultHeight;
    int g_pendingWidth, g_pendingHeight;
    uint g_seatVerAdvertised, g_seatVerBound;

    // pending wl_pointer.frame group
    AxisPending[2] g_pend; // [0]=vertical, [1]=horizontal
    bool g_hasSource;
    uint g_source;
    int g_frameSeq;

    // gesture accumulation
    bool g_inGesture;
    int g_gestureFrames;
    double[2] g_gestureValue = [0, 0];
    long[2] g_gestureV120 = [0, 0];
    int g_gestureNum;
    bool g_gestureHasSource;
    uint g_gestureSource;
    long g_lastAxisUs;

    // detent accumulation + ruler
    long g_v120Carry; // vertical 120ths not yet a whole detent
    int g_detents; // signed net wheel detents (vertical)
    double g_scrollPx = 0; // continuous vertical scroll length → ruler offset

    bool g_configured, g_running = true, g_autoExit, g_keepPointer;
    long g_runUsCap = 2_500_000;
    int g_frames, g_commits, g_axisEvents;
}

const(char)* axisName(uint axis) nothrow @nogc
{
    return axis == WL_POINTER_AXIS_VERTICAL_SCROLL ? "vertical".ptr : "horizontal".ptr;
}

const(char)* sourceName(uint src) nothrow @nogc
{
    switch (src)
    {
    case WL_POINTER_AXIS_SOURCE_WHEEL: return "wheel".ptr;
    case WL_POINTER_AXIS_SOURCE_FINGER: return "finger".ptr;
    case WL_POINTER_AXIS_SOURCE_CONTINUOUS: return "continuous".ptr;
    case WL_POINTER_AXIS_SOURCE_WHEEL_TILT: return "wheel_tilt".ptr;
    default: return "?".ptr;
    }
}

// ----------------------------------------------------------------- gestures

void endGesture(const(char)* reason) nothrow @nogc
{
    if (!g_inGesture)
        return;
    g_inGesture = false;
    instrEvent("gesture_summary",
        "num=%d frames=%d value_v=%.3f value_h=%.3f v120_v=%lld v120_h=%lld detents_total=%d source=%s reason=%s",
        g_gestureNum, g_gestureFrames, g_gestureValue[0], g_gestureValue[1],
        g_gestureV120[0], g_gestureV120[1], g_detents,
        g_gestureHasSource ? sourceName(g_gestureSource) : "none".ptr, reason);
    g_gestureFrames = 0;
    g_gestureValue = [0, 0];
    g_gestureV120 = [0, 0];
    g_gestureHasSource = false;
}

// ---------------------------------------------------------------- listeners

extern (C) void onPointerEnter(void* data, wl_pointer* p, uint serial,
    wl_surface* surf, int sx, int sy) nothrow @nogc
{
    instrEvent("pointer_enter", "serial=%u pos=%.2f,%.2f", serial, sx / 256.0, sy / 256.0);
}

extern (C) void onPointerLeave(void* data, wl_pointer* p, uint serial, wl_surface* surf) nothrow @nogc
{
    instrEvent("pointer_leave", "serial=%u", serial);
    endGesture("leave");
}

extern (C) void onPointerMotion(void* data, wl_pointer* p, uint time, int sx, int sy) nothrow @nogc {}

extern (C) void onPointerButton(void* data, wl_pointer* p, uint serial, uint time,
    uint button, uint state) nothrow @nogc {}

extern (C) void onPointerAxis(void* data, wl_pointer* p, uint time, uint axis, int value) nothrow @nogc
{
    g_axisEvents++;
    immutable v = value / 256.0;
    instrEvent("axis", "axis=%s value=%.3f time=%u", axisName(axis), v, time);
    if (axis > 1)
        return;
    g_pend[axis].hasValue = true;
    g_pend[axis].value += v;
}

extern (C) void onPointerAxisSource(void* data, wl_pointer* p, uint src) nothrow @nogc
{
    instrEvent("axis_source", "source=%s raw=%u", sourceName(src), src);
    g_hasSource = true;
    g_source = src;
}

extern (C) void onPointerAxisStop(void* data, wl_pointer* p, uint time, uint axis) nothrow @nogc
{
    instrEvent("axis_stop", "axis=%s time=%u", axisName(axis), time);
    if (axis <= 1)
        g_pend[axis].stop = true;
}

extern (C) void onPointerAxisDiscrete(void* data, wl_pointer* p, uint axis, int discrete) nothrow @nogc
{
    // Deprecated with seat v8: a v8+ bind must receive axis_value120 instead.
    // Logged so a compositor that still sends it on a high bind is caught.
    instrEvent("axis_discrete", "axis=%s discrete=%d note=DEPRECATED-pre-v8", axisName(axis), discrete);
}

extern (C) void onPointerAxisValue120(void* data, wl_pointer* p, uint axis, int v120) nothrow @nogc
{
    instrEvent("axis_value120", "axis=%s v120=%d detent_fraction=%.3f",
        axisName(axis), v120, v120 / 120.0);
    if (axis > 1)
        return;
    g_pend[axis].hasV120 = true;
    g_pend[axis].v120 += v120;
}

extern (C) void onPointerAxisRelDir(void* data, wl_pointer* p, uint axis, uint dir) nothrow @nogc
{
    instrEvent("axis_relative_direction", "axis=%s direction=%s", axisName(axis),
        dir == WL_POINTER_AXIS_RELATIVE_DIRECTION_INVERTED ? "inverted".ptr : "identical".ptr);
    if (axis <= 1)
    {
        g_pend[axis].hasDirection = true;
        g_pend[axis].direction = dir;
    }
}

/// The frame boundary: everything since the previous frame is ONE logical
/// event group. Only groups that carried axis state are logged/accumulated
/// (enter/leave/motion also arrive frame-terminated).
extern (C) void onPointerFrame(void* data, wl_pointer* p) nothrow @nogc
{
    immutable hadAxis = g_pend[0].hasValue || g_pend[1].hasValue
        || g_pend[0].hasV120 || g_pend[1].hasV120
        || g_pend[0].stop || g_pend[1].stop || g_hasSource;
    if (!hadAxis)
        return;
    g_frameSeq++;
    instrEvent("frame",
        "seq=%d source=%s v=[value=%.3f%s v120=%d%s stop=%d dir=%s] h=[value=%.3f%s v120=%d%s stop=%d dir=%s]",
        g_frameSeq, g_hasSource ? sourceName(g_source) : "none".ptr,
        g_pend[0].value, g_pend[0].hasValue ? "".ptr : "(absent)".ptr,
        g_pend[0].v120, g_pend[0].hasV120 ? "".ptr : "(absent)".ptr,
        g_pend[0].stop ? 1 : 0,
        g_pend[0].hasDirection
        ? (g_pend[0].direction ? "inverted".ptr : "identical".ptr) : "-".ptr,
        g_pend[1].value, g_pend[1].hasValue ? "".ptr : "(absent)".ptr,
        g_pend[1].v120, g_pend[1].hasV120 ? "".ptr : "(absent)".ptr,
        g_pend[1].stop ? 1 : 0,
        g_pend[1].hasDirection
        ? (g_pend[1].direction ? "inverted".ptr : "identical".ptr) : "-".ptr);

    // gesture bookkeeping
    if (!g_inGesture && (g_pend[0].hasValue || g_pend[1].hasValue))
    {
        g_inGesture = true;
        g_gestureNum++;
        instrEvent("gesture_begin", "num=%d source=%s", g_gestureNum,
            g_hasSource ? sourceName(g_source) : "none".ptr);
    }
    if (g_inGesture)
    {
        g_gestureFrames++;
        foreach (a; 0 .. 2)
        {
            g_gestureValue[a] += g_pend[a].value;
            g_gestureV120[a] += g_pend[a].v120;
        }
        // First VALUE-carrying frame names the gesture source — wlrctl's
        // trailing stop frame arrives with source=finger even when the value
        // frame said wheel, and must not overwrite it.
        if (g_hasSource && !g_gestureHasSource
            && (g_pend[0].hasValue || g_pend[1].hasValue))
        {
            g_gestureHasSource = true;
            g_gestureSource = g_source;
        }
        g_lastAxisUs = instrNowUs();
    }

    // detent accumulation (vertical): carry the remainder — truncating each
    // event would lose sub-detent precision from high-resolution wheels.
    if (g_pend[0].hasV120)
    {
        g_v120Carry += g_pend[0].v120;
        while (g_v120Carry >= 120 || g_v120Carry <= -120)
        {
            immutable step = g_v120Carry > 0 ? 1 : -1;
            g_detents += step;
            g_v120Carry -= step * 120;
            instrEvent("detent", "step=%d detents=%d carry=%lld", step, g_detents, g_v120Carry);
        }
    }
    g_scrollPx += g_pend[0].value; // continuous length drives the ruler

    immutable wasStop = g_pend[0].stop || g_pend[1].stop;
    g_pend[0] = AxisPending.init;
    g_pend[1] = AxisPending.init;
    g_hasSource = false;
    if (wasStop)
        endGesture("axis_stop");
}

__gshared wl_pointer_listener g_pointerListener = {
    &onPointerEnter, &onPointerLeave, &onPointerMotion, &onPointerButton,
    &onPointerAxis, &onPointerFrame, &onPointerAxisSource, &onPointerAxisStop,
    &onPointerAxisDiscrete, &onPointerAxisValue120, &onPointerAxisRelDir
};

extern (C) void onSeatCapabilities(void* data, wl_seat* s, uint caps) nothrow @nogc
{
    immutable hasPointer = (caps & WL_SEAT_CAPABILITY_POINTER) != 0;
    instrEvent("seat_capabilities", "caps=%u pointer=%d", caps, hasPointer ? 1 : 0);
    if (hasPointer && g_pointer is null)
    {
        g_pointer = wsi_seat_get_pointer(g_seat);
        wsi_pointer_add_listener(g_pointer, &g_pointerListener, null);
    }
    else if (!hasPointer && g_pointer !is null)
    {
        // Capability flap (the wlrctl device unplugged). The conformant move
        // is destroy + re-create (the F12 lesson) — but the re-created
        // wl_pointer needs a get_pointer round-trip, and a wlrctl scroll
        // burst is fully delivered before that completes: every axis event
        // would be dropped. WSI_KEEP_POINTER=1 keeps the proxy across the
        // flap instead so the next burst lands on an existing resource —
        // which behaviour actually receives events is itself a finding.
        if (g_keepPointer)
        {
            instrEvent("pointer_kept", "note=capability removed; wl_pointer retained (WSI_KEEP_POINTER)");
            return;
        }
        wsi_pointer_destroy(g_pointer);
        g_pointer = null;
        instrEvent("pointer_dropped", "note=capability removed; wl_pointer destroyed");
    }
}

extern (C) void onSeatName(void* data, wl_seat* s, const(char)* name) nothrow @nogc {}

extern (C) void onGlobal(void* data, wl_registry* reg, uint name,
    const(char)* iface, uint ver) nothrow @nogc
{
    static uint capped(uint advertised, uint want) nothrow @nogc
    {
        return advertised < want ? advertised : want;
    }

    if (strcmp(iface, wl_compositor_interface.name) == 0)
        g_compositor = cast(wl_compositor*) wsi_registry_bind(reg, name,
            &wl_compositor_interface, capped(ver, 6));
    else if (strcmp(iface, wl_shm_interface.name) == 0)
        g_shm = cast(wl_shm*) wsi_registry_bind(reg, name, &wl_shm_interface, 1);
    else if (strcmp(iface, xdg_wm_base_interface.name) == 0)
        g_wmBase = cast(xdg_wm_base*) wsi_registry_bind(reg, name, &xdg_wm_base_interface, 1);
    else if (strcmp(iface, wl_seat_interface.name) == 0 && g_seat is null)
    {
        // v8 brings axis_value120 (and retires axis_discrete); v9 brings
        // axis_relative_direction. Bind as high as the compositor offers.
        g_seatVerAdvertised = ver;
        g_seatVerBound = capped(ver, 9);
        g_seat = cast(wl_seat*) wsi_registry_bind(reg, name, &wl_seat_interface, g_seatVerBound);
        wsi_seat_add_listener(g_seat, &g_seatListener, null);
    }
}

extern (C) void onGlobalRemove(void* data, wl_registry* reg, uint name) nothrow @nogc {}

// ------------------------------------------------ window plumbing (scaffold)

bool ensureBuffer(ref Buffer b, int w, int h) nothrow @nogc
{
    if (b.handle !is null && (b.width != w || b.height != h))
    {
        wsi_buffer_destroy(b.handle);
        munmap(b.pixels, b.byteSize);
        b = Buffer.init;
    }
    if (b.handle !is null)
        return true;
    immutable stride = w * 4;
    immutable size = cast(size_t) stride * h;
    immutable fd = memfd_create("wsi-f11", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, cast(long) size) != 0)
        return false;
    void* mem = mmap(null, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (mem is cast(void*)-1)
    {
        close(fd);
        return false;
    }
    wl_shm_pool* pool = wsi_shm_create_pool(g_shm, fd, cast(int) size);
    b.handle = wsi_shm_pool_create_buffer(pool, 0, w, h, stride, WL_SHM_FORMAT_ARGB8888);
    wsi_shm_pool_destroy(pool);
    close(fd);
    wsi_buffer_add_listener(b.handle, &g_bufferListener, &b);
    b.pixels = cast(uint*) mem;
    b.byteSize = size;
    b.width = w;
    b.height = h;
    return true;
}

/// The scrollable ruler: a tick every 40 px (major every 200) offset by the
/// accumulated continuous scroll, plus a left-edge detent gauge. Over/under-
/// scroll bugs would be visible as ruler drift against the detent gauge.
void render() nothrow @nogc
{
    Buffer* buf = null;
    foreach (ref b; g_buffers)
        if (!b.busy)
        {
            buf = &b;
            break;
        }
    if (buf is null || !ensureBuffer(*buf, g_width, g_height))
        return;
    immutable off = cast(int) g_scrollPx;
    foreach (y; 0 .. buf.height)
    {
        immutable ry = y + off; // ruler-space row
        immutable m = ((ry % 200) + 200) % 200;
        immutable isMajor = m < 3;
        immutable isMinor = (((ry % 40) + 40) % 40) < 2;
        foreach (x; 0 .. buf.width)
        {
            uint c = 0xff181c28;
            if (isMajor)
                c = 0xffe0e0e0;
            else if (isMinor && x > 40)
                c = 0xff707888;
            if (x < 24) // detent gauge: one 8-px notch per accumulated detent
            {
                immutable notch = g_detents * 8;
                c = (notch >= 0 && y >= buf.height / 2 - notch && y < buf.height / 2)
                    || (notch < 0 && y < buf.height / 2 - notch && y >= buf.height / 2)
                    ? 0xff60c060 : 0xff101010;
            }
            buf.pixels[cast(size_t) y * buf.width + x] = c;
        }
    }
    wsi_surface_attach(g_surface, buf.handle, 0, 0);
    wsi_surface_damage_buffer(g_surface, 0, 0, buf.width, buf.height);
    if (g_frameCb is null)
    {
        g_frameCb = wsi_surface_frame(g_surface);
        wsi_callback_add_listener(g_frameCb, &g_frameListener, null);
    }
    wsi_surface_commit(g_surface);
    buf.busy = true;
    g_commits++;
}

extern (C) void onWmBasePing(void* data, xdg_wm_base* b, uint serial) nothrow @nogc
{
    wsi_wm_base_pong(b, serial);
}

extern (C) void onToplevelConfigure(void* data, xdg_toplevel* t, int w, int h,
    wl_array* states) nothrow @nogc
{
    g_pendingWidth = w;
    g_pendingHeight = h;
}

extern (C) void onXdgSurfaceConfigure(void* data, xdg_surface* s, uint serial) nothrow @nogc
{
    immutable w = g_pendingWidth > 0 ? g_pendingWidth : defaultWidth;
    immutable h = g_pendingHeight > 0 ? g_pendingHeight : defaultHeight;
    instrEvent("configure", "serial=%u size=%dx%d", serial, w, h);
    wsi_xdg_surface_ack_configure(s, serial);
    immutable resized = w != g_width || h != g_height;
    g_width = w;
    g_height = h;
    if (!g_configured)
    {
        g_configured = true;
        instrFirstConfigure();
        render();
    }
    else if (resized)
        render();
}

extern (C) void onToplevelClose(void* data, xdg_toplevel* t) nothrow @nogc
{
    instrCloseRequested();
    g_running = false;
}

extern (C) void onToplevelConfigureBounds(void* data, xdg_toplevel* t, int w, int h) nothrow @nogc {}

extern (C) void onToplevelWmCapabilities(void* data, xdg_toplevel* t, wl_array* caps) nothrow @nogc {}

extern (C) void onBufferRelease(void* data, wl_buffer* b) nothrow @nogc
{
    (cast(Buffer*) data).busy = false;
    if (g_running && g_configured && g_frameCb is null)
        render();
}

extern (C) void onFrameDone(void* data, wl_callback* cb, uint timeMs) nothrow @nogc
{
    wsi_callback_destroy(cb);
    g_frameCb = null;
    g_frames++;
    if (g_frames == 1)
        instrFirstPixelPresented();
    render();
}

__gshared wl_registry_listener g_registryListener = {&onGlobal, &onGlobalRemove};
__gshared wl_seat_listener g_seatListener = {&onSeatCapabilities, &onSeatName};
__gshared xdg_wm_base_listener g_wmBaseListener = {&onWmBasePing};
__gshared xdg_surface_listener g_xdgSurfaceListener = {&onXdgSurfaceConfigure};
__gshared xdg_toplevel_listener g_toplevelListener = {
    &onToplevelConfigure, &onToplevelClose,
    &onToplevelConfigureBounds, &onToplevelWmCapabilities
};
__gshared wl_buffer_listener g_bufferListener = {&onBufferRelease};
__gshared wl_callback_listener g_frameListener = {&onFrameDone};

// --------------------------------------------------------------------- main

int main(string[] args)
{
    // `f11_scroll inject <hold_ms> <steps> <dx> <dy> <interval_ms>` plugs a
    // zwlr_virtual_pointer_v1 device in (see ./inject.d). ./run.sh uses it
    // with steps=0 as a pure capability HOLD: while the held device keeps the
    // seat's pointer capability up, the demo's wl_pointer survives and the
    // transient `wlrctl pointer scroll` bursts land on a live resource —
    // without the hold, every burst is fully delivered before the demo's
    // get_pointer round-trip completes and ALL axis events are dropped.
    // NB: druntime packs main's args into one contiguous buffer WITHOUT NUL
    // terminators between them — atoi(args[i].ptr) reads the neighbours too.
    static int parseInt(in char[] s) nothrow @nogc
    {
        int v;
        bool neg;
        foreach (i, ch; s)
        {
            if (i == 0 && ch == '-')
                neg = true;
            else if (ch >= '0' && ch <= '9')
                v = v * 10 + (ch - '0');
        }
        return neg ? -v : v;
    }

    if (args.length >= 7 && args[1] == "inject")
    {
        import inject : injectMain;

        return injectMain(parseInt(args[2]), parseInt(args[3]),
            parseInt(args[4]), parseInt(args[5]), parseInt(args[6]),
            args.length > 7 && args[7] == "wheel");
    }

    instrInit("f11_wayland");
    const autoEnv = getenv("WSI_AUTO_EXIT");
    g_autoExit = autoEnv !is null && *autoEnv == '1';
    const runMs = getenv("WSI_RUN_MS");
    if (runMs !is null)
        g_runUsCap = atoi(runMs) * 1000L;
    const keepEnv = getenv("WSI_KEEP_POINTER");
    g_keepPointer = keepEnv !is null && *keepEnv == '1';

    g_display = wl_display_connect(null);
    if (g_display is null)
    {
        printf("SKIP: no Wayland compositor (wl_display_connect returned null)\n");
        return 0;
    }
    g_registry = wsi_display_get_registry(g_display);
    wsi_registry_add_listener(g_registry, &g_registryListener, null);
    wl_display_roundtrip(g_display); // globals
    wl_display_roundtrip(g_display); // seat capabilities
    if (g_compositor is null || g_shm is null || g_wmBase is null)
    {
        printf("SKIP: compositor lacks a required global\n");
        wl_display_disconnect(g_display);
        return 0;
    }

    instrEvent("seat", "present=%d advertised=%u bound=%u v120=%s direction=%s",
        g_seat !is null ? 1 : 0, g_seatVerAdvertised, g_seatVerBound,
        g_seatVerBound >= 8 ? "yes".ptr : "no-pre-v8".ptr,
        g_seatVerBound >= 9 ? "yes".ptr : "no-pre-v9".ptr);

    if (g_seat is null)
    {
        // headless weston: no seat at all → no pointer, no axis events; the
        // registry probe above is the Tier-A evidence.
        printf("ok: no seat on this compositor; registry probe only\n");
        wl_display_disconnect(g_display);
        return 0;
    }

    wsi_wm_base_add_listener(g_wmBase, &g_wmBaseListener, null);
    g_surface = wsi_compositor_create_surface(g_compositor);
    g_xdgSurface = wsi_wm_base_get_xdg_surface(g_wmBase, g_surface);
    wsi_xdg_surface_add_listener(g_xdgSurface, &g_xdgSurfaceListener, null);
    g_toplevel = wsi_xdg_surface_get_toplevel(g_xdgSurface);
    wsi_toplevel_add_listener(g_toplevel, &g_toplevelListener, null);
    wsi_toplevel_set_title(g_toplevel, "wsi-f11-scroll");
    wsi_toplevel_set_app_id(g_toplevel, "wsi-f11-scroll");
    instrWindowCreated();
    wsi_surface_commit(g_surface); // mandatory no-buffer first commit

    immutable dispFd = wl_display_get_fd(g_display);
    while (g_running)
    {
        while (wl_display_prepare_read(g_display) != 0)
            wl_display_dispatch_pending(g_display);
        wl_display_flush(g_display);
        pollfd pfd = {dispFd, POLLIN, 0};
        if (poll(&pfd, 1, 50) > 0)
            wl_display_read_events(g_display);
        else
            wl_display_cancel_read(g_display);
        if (wl_display_dispatch_pending(g_display) == -1)
            break;
        if (g_inGesture && instrNowUs() - g_lastAxisUs > gestureGapUs)
            endGesture("idle_gap"); // momentum is NOT delivered: the app owns kinetics
        if (g_autoExit && instrNowUs() > g_runUsCap)
            g_running = false;
    }

    endGesture("shutdown");
    instrEvent("summary",
        "axis_events=%d frames_with_axis=%d gestures=%d detents=%d v120_carry=%lld scroll_px=%.2f",
        g_axisEvents, g_frameSeq, g_gestureNum, g_detents, g_v120Carry, g_scrollPx);

    // Teardown: children before parents.
    foreach (ref b; g_buffers)
        if (b.handle !is null)
        {
            wsi_buffer_destroy(b.handle);
            munmap(b.pixels, b.byteSize);
        }
    if (g_frameCb !is null)
        wsi_callback_destroy(g_frameCb);
    if (g_pointer !is null)
        wsi_pointer_destroy(g_pointer);
    if (g_seat !is null)
        wsi_seat_destroy(g_seat);
    wsi_toplevel_destroy(g_toplevel);
    wsi_xdg_surface_destroy(g_xdgSurface);
    wsi_surface_destroy(g_surface);
    wsi_wm_base_destroy(g_wmBase);
    wl_proxy_destroy(cast(wl_proxy*) g_shm);
    wl_proxy_destroy(cast(wl_proxy*) g_compositor);
    wl_proxy_destroy(cast(wl_proxy*) g_registry);
    wl_display_disconnect(g_display);

    printf("ok: frames=%d commits=%d axis_events=%d gestures=%d detents=%d\n",
        g_frames, g_commits, g_axisEvents, g_gestureNum, g_detents);
    return 0;
}
