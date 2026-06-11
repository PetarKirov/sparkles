// F10 pointer-capture demo — pointer lock (oneshot AND persistent), confine,
// and relative motion on top of the xdg-shell scaffold (../scaffold/app.d;
// findings: ../../scaffold.md, ../../f10-pointer-capture.md).
//
// Choreographed "mouselook" phase machine instead of a keyboard toggle — on a
// headless compositor the input that advances the phases is injected by
// ./run.sh through this binary's own `inject` mode (zwlr_virtual_pointer_v1,
// ./inject.d). Each injector invocation plugs/unplugs its device, so the seat
// pointer capability flaps (the F12 lesson: destroy/re-create wl_pointer on
// every capabilities edge). Compositor-initiated deactivation (`unlocked`) is
// NOT triggered by focus-leave or device-unplug on sway — only by a
// window-focus change — so ./run.sh runs a second, passive instance of this
// demo (WSI_PASSIVE=1, app id wsi-f10-passive) purely as a focus target and
// steals focus with `swaymsg [app_id=…] focus` whenever a phase needs its
// `unlocked`:
//
//   pre             abs motion + relative motion both flowing (unlocked)
//   lock-oneshot    lock_pointer(lifetime=ONESHOT) requested while the
//                   pointer has NO focus on the surface → `locked` must wait
//                   for entry (the async-failable contract); deactivation →
//                   `unlocked` → object DEFUNCT, destroy it
//   relock-oneshot  re-lock after a oneshot ends requires a brand-new object
//   lock-persistent same request with lifetime=PERSISTENT: after `unlocked`
//                   the object is kept and `locked` fires AGAIN on it; on the
//                   2nd activation the demo sets set_cursor_position_hint,
//                   commits, and destroys (client unlock) → the compositor
//                   may warp the cursor to the hint (verified by the next
//                   enter coordinates)
//   confine         confine_pointer(persistent) to the center-half wl_region;
//                   ./run.sh pushes the pointer at the region boundary and
//                   the demo records the clamped wl_pointer.motion stream
//
// While any lock is active, wl_pointer.motion must STOP (only
// zwp_relative_pointer_v1.relative_motion arrives) — the demo counts
// violations. Relative motion logs dx/dy AND dx_unaccel/dy_unaccel; with a
// wlrctl-injected virtual pointer they are expected 1:1 (no libinput accel) —
// logged honestly either way. Headless-safe: no compositor → SKIP, exit 0; a
// seat-less compositor (headless weston) still yields the registry probe.
module app;

import c; // ImportC: wayland-client + xdg-shell/pointer-constraints/relative-pointer glue
import instrument;
import core.stdc.stdio : printf;
import core.stdc.stdlib : atoi, getenv;
import core.stdc.string : strcmp;

enum int defaultWidth = 640;
enum int defaultHeight = 480;
enum int hintX = 400, hintY = 300; // set_cursor_position_hint target (surface-local)

enum Phase
{
    pre,
    lockOneshot,
    relockOneshot,
    lockPersistent,
    confine,
}

__gshared immutable(char*)[5] g_phaseNames = [
    "pre", "lock-oneshot", "relock-oneshot", "lock-persistent", "confine"
];

// -------------------------------------------------------------------- state

struct Buffer
{
    wl_buffer* handle;
    uint* pixels;
    size_t byteSize;
    int width, height;
    bool busy;
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
    zwp_pointer_constraints_v1* g_constraints;
    zwp_relative_pointer_manager_v1* g_relMgr;
    zwp_relative_pointer_v1* g_relPointer;
    zwp_locked_pointer_v1* g_locked;
    zwp_confined_pointer_v1* g_confined;
    wl_surface* g_surface;
    xdg_surface* g_xdgSurface;
    xdg_toplevel* g_toplevel;
    wl_callback* g_frameCb;

    Buffer[2] g_buffers;
    int g_width = defaultWidth, g_height = defaultHeight;
    int g_pendingWidth, g_pendingHeight;
    Phase g_phase = Phase.pre;
    bool g_lockActive, g_confineActive, g_haveFocus, g_hintSet;
    int g_lockObjects; // lock_pointer requests issued (== objects created)
    int g_lockActivations; // `locked` events on the CURRENT lock object
    int g_absMotions, g_absWhileLocked, g_relEvents, g_entersAfterHint;
    bool g_unaccelDiffered;
    double g_yaw = 0, g_pitch = 0; // the mouselook "angle readout"
    int[4] g_confineRect; // x,y,w,h as passed to confine_pointer
    double g_cMinX = 1e9, g_cMinY = 1e9, g_cMaxX = -1e9, g_cMaxY = -1e9;
    bool g_configured, g_running = true, g_autoExit, g_passive;
    long g_runUsCap = 2_500_000;
    int g_frames, g_commits;
}

void setPhase(Phase p) nothrow @nogc
{
    g_phase = p;
    instrEvent("phase", "name=%s", g_phaseNames[p]);
}

// ------------------------------------------------------------- constraints

/// Request a pointer lock for the current phase. Called right after the
/// wl_pointer is (re)created on a capability gain — i.e. while the pointer
/// has no focus on the surface yet, which is the async-failable contract
/// under test: `locked` may only fire once the pointer enters the surface.
void createLock(uint lifetime, const(char)* label) nothrow @nogc
{
    g_locked = wsi_lock_pointer(g_constraints, g_surface, g_pointer, null, lifetime);
    wsi_locked_add_listener(g_locked, &g_lockedListener, null);
    g_lockObjects++;
    g_lockActivations = 0;
    instrEvent("lock_request", "lifetime=%s object=%d focus=%d note=%s",
        lifetime == ZWP_POINTER_CONSTRAINTS_V1_LIFETIME_ONESHOT
        ? "oneshot".ptr : "persistent".ptr,
        g_lockObjects, g_haveFocus ? 1 : 0, label);
}

/// Confine to the center half of the window — a real wl_region, destroyed
/// right after the request (the compositor copies the region contents).
void createConfine() nothrow @nogc
{
    g_confineRect = [g_width / 4, g_height / 4, g_width / 2, g_height / 2];
    wl_region* region = wsi_compositor_create_region(g_compositor);
    wsi_region_add(region, g_confineRect[0], g_confineRect[1],
        g_confineRect[2], g_confineRect[3]);
    g_confined = wsi_confine_pointer(g_constraints, g_surface, g_pointer,
        region, ZWP_POINTER_CONSTRAINTS_V1_LIFETIME_PERSISTENT);
    wsi_confined_add_listener(g_confined, &g_confinedListener, null);
    wsi_region_destroy(region);
    instrEvent("confine_request", "rect=%d,%d %dx%d lifetime=persistent focus=%d",
        g_confineRect[0], g_confineRect[1], g_confineRect[2], g_confineRect[3],
        g_haveFocus ? 1 : 0);
}

/// (Re)arm the constraint the current phase needs. Called on every pointer
/// (re)creation; persistent objects survive the flap, so only create when
/// none exists.
void ensureConstraint() nothrow @nogc
{
    if (g_constraints is null || g_passive)
        return;
    final switch (g_phase)
    {
    case Phase.pre:
        break;
    case Phase.lockOneshot:
        if (g_locked is null)
            createLock(ZWP_POINTER_CONSTRAINTS_V1_LIFETIME_ONESHOT, "first-oneshot");
        break;
    case Phase.relockOneshot:
        if (g_locked is null)
            createLock(ZWP_POINTER_CONSTRAINTS_V1_LIFETIME_ONESHOT, "new-object-after-oneshot");
        break;
    case Phase.lockPersistent:
        if (g_locked is null)
            createLock(ZWP_POINTER_CONSTRAINTS_V1_LIFETIME_PERSISTENT, "persistent");
        break;
    case Phase.confine:
        if (g_confined is null)
            createConfine();
        break;
    }
}

extern (C) void onLocked(void* data, zwp_locked_pointer_v1* lp) nothrow @nogc
{
    g_lockActive = true;
    g_lockActivations++;
    instrEvent("locked", "phase=%s object=%d activation=%d",
        g_phaseNames[g_phase], g_lockObjects, g_lockActivations);
    if (g_phase == Phase.lockPersistent && g_lockActivations >= 2)
    {
        // The persistent lifetime is proven (a 2nd `locked` on the SAME
        // object, no new request). Now the unlock-restoration test: hint a
        // cursor position, commit (the hint is double-buffered state), and
        // destroy while active — "when unlocking, the compositor may warp
        // the cursor position to the set cursor position hint".
        wsi_locked_set_cursor_position_hint(g_locked, hintX * 256, hintY * 256);
        wsi_surface_commit(g_surface);
        g_hintSet = true;
        instrEvent("cursor_position_hint", "x=%d y=%d note=committed-then-client-unlock",
            hintX, hintY);
        wsi_locked_destroy(g_locked);
        g_locked = null;
        g_lockActive = false;
        instrEvent("lock_destroyed", "reason=client-unlock-with-hint");
        setPhase(Phase.confine);
        ensureConstraint(); // pointer is alive and focused right now
    }
}

extern (C) void onUnlocked(void* data, zwp_locked_pointer_v1* lp) nothrow @nogc
{
    g_lockActive = false;
    instrEvent("unlocked", "phase=%s object=%d activations=%d",
        g_phaseNames[g_phase], g_lockObjects, g_lockActivations);
    final switch (g_phase)
    {
    case Phase.lockOneshot:
        // "If this is a oneshot pointer lock this object is now defunct and
        // should be destroyed."
        wsi_locked_destroy(g_locked);
        g_locked = null;
        instrEvent("lock_destroyed", "reason=oneshot-defunct");
        setPhase(Phase.relockOneshot);
        break;
    case Phase.relockOneshot:
        wsi_locked_destroy(g_locked);
        g_locked = null;
        instrEvent("lock_destroyed", "reason=oneshot-defunct");
        setPhase(Phase.lockPersistent);
        break;
    case Phase.lockPersistent:
        // Persistent: the object stays valid and "may again reactivate".
        instrEvent("lock_kept", "note=persistent-object-retained-for-reactivation");
        break;
    case Phase.pre:
    case Phase.confine:
        break;
    }
}

extern (C) void onConfined(void* data, zwp_confined_pointer_v1* cp) nothrow @nogc
{
    g_confineActive = true;
    instrEvent("confined", "rect=%d,%d %dx%d", g_confineRect[0], g_confineRect[1],
        g_confineRect[2], g_confineRect[3]);
}

extern (C) void onUnconfined(void* data, zwp_confined_pointer_v1* cp) nothrow @nogc
{
    g_confineActive = false;
    instrEvent("unconfined", "note=persistent-object-retained");
}

extern (C) void onRelativeMotion(void* data, zwp_relative_pointer_v1* rp,
    uint utimeHi, uint utimeLo, int dx, int dy, int dxUnaccel, int dyUnaccel) nothrow @nogc
{
    g_relEvents++;
    if (dx != dxUnaccel || dy != dyUnaccel)
        g_unaccelDiffered = true;
    g_yaw += dx / 256.0 * 0.25; // the mouselook angle readout the deltas drive
    g_pitch += dy / 256.0 * 0.25;
    instrEvent("relative_motion",
        "dx=%.2f dy=%.2f dx_unaccel=%.2f dy_unaccel=%.2f locked=%d yaw=%.1f pitch=%.1f",
        dx / 256.0, dy / 256.0, dxUnaccel / 256.0, dyUnaccel / 256.0,
        g_lockActive ? 1 : 0, g_yaw, g_pitch);
}

__gshared zwp_locked_pointer_v1_listener g_lockedListener = {&onLocked, &onUnlocked};
__gshared zwp_confined_pointer_v1_listener g_confinedListener = {&onConfined, &onUnconfined};
__gshared zwp_relative_pointer_v1_listener g_relativeListener = {&onRelativeMotion};

// ---------------------------------------------------------------- listeners

extern (C) void onPointerEnter(void* data, wl_pointer* p, uint serial,
    wl_surface* surf, int sx, int sy) nothrow @nogc
{
    g_haveFocus = true;
    instrEvent("pointer_enter", "serial=%u pos=%.2f,%.2f phase=%s",
        serial, sx / 256.0, sy / 256.0, g_phaseNames[g_phase]);
}

extern (C) void onPointerLeave(void* data, wl_pointer* p, uint serial, wl_surface* surf) nothrow @nogc
{
    g_haveFocus = false;
    instrEvent("pointer_leave", "serial=%u", serial);
}

extern (C) void onPointerMotion(void* data, wl_pointer* p, uint time, int sx, int sy) nothrow @nogc
{
    g_absMotions++;
    immutable x = sx / 256.0, y = sy / 256.0;
    if (g_lockActive)
    {
        // The contract under test: "while a pointer is locked, the wl_pointer
        // objects of the corresponding seat will not emit any
        // wl_pointer.motion events". Any line here is a violation.
        g_absWhileLocked++;
        instrEvent("motion_while_locked", "x=%.2f y=%.2f note=CONTRACT-VIOLATION", x, y);
        return;
    }
    if (g_hintSet && g_entersAfterHint == 0)
    {
        g_entersAfterHint = 1;
        // The position-hint verification: the cursor was at the lock position
        // when the lock was destroyed; if the compositor warped it to
        // (hintX, hintY), the first post-unlock motion lands at hint + the
        // injected delta.
        instrEvent("hint_verify", "hint=%d,%d first_motion=%.2f,%.2f note=expect-hint-plus-one-delta",
            hintX, hintY, x, y);
    }
    instrEvent("motion", "x=%.2f y=%.2f phase=%s confined=%d", x, y,
        g_phaseNames[g_phase], g_confineActive ? 1 : 0);
    if (g_phase == Phase.confine && g_confineActive)
    {
        if (x < g_cMinX) g_cMinX = x;
        if (y < g_cMinY) g_cMinY = y;
        if (x > g_cMaxX) g_cMaxX = x;
        if (y > g_cMaxY) g_cMaxY = y;
    }
}

extern (C) void onPointerButton(void* data, wl_pointer* p, uint serial, uint time,
    uint button, uint state) nothrow @nogc {}

extern (C) void onPointerAxis(void* data, wl_pointer* p, uint time, uint axis, int value) nothrow @nogc {}

extern (C) void onPointerFrame(void* data, wl_pointer* p) nothrow @nogc {}

extern (C) void onPointerAxisSource(void* data, wl_pointer* p, uint src) nothrow @nogc {}

extern (C) void onPointerAxisStop(void* data, wl_pointer* p, uint time, uint axis) nothrow @nogc {}

extern (C) void onPointerAxisDiscrete(void* data, wl_pointer* p, uint axis, int discrete) nothrow @nogc {}

extern (C) void onPointerAxisValue120(void* data, wl_pointer* p, uint axis, int v120) nothrow @nogc {}

extern (C) void onPointerAxisRelDir(void* data, wl_pointer* p, uint axis, uint dir) nothrow @nogc {}

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
        if (g_relMgr !is null)
        {
            // One relative pointer per wl_pointer; it "shares the same focus
            // as wl_pointer objects of the same seat" and reports deltas
            // locked or not.
            g_relPointer = wsi_get_relative_pointer(g_relMgr, g_pointer);
            wsi_relative_add_listener(g_relPointer, &g_relativeListener, null);
        }
        // The constraint is requested NOW — before any enter, i.e. while the
        // pointer is outside/unfocused. `locked` must wait for entry.
        ensureConstraint();
    }
    else if (!hasPointer && g_pointer !is null)
    {
        // Capability flap (the wlrctl device unplugged): destroy and
        // re-create per the wl_seat.capabilities contract. The constraint
        // objects are NOT destroyed here — whether they survive the flap is
        // a finding (persistent should; oneshot is already defunct).
        if (g_relPointer !is null)
            wsi_relative_destroy(g_relPointer);
        g_relPointer = null;
        wsi_pointer_destroy(g_pointer);
        g_pointer = null;
        g_haveFocus = false;
        instrEvent("pointer_dropped", "note=capability removed; wl_pointer+relative destroyed");
        if (g_phase == Phase.pre && g_absMotions > 0)
            setPhase(Phase.lockOneshot); // next plug requests the first lock
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
        g_seat = cast(wl_seat*) wsi_registry_bind(reg, name, &wl_seat_interface, capped(ver, 5));
        wsi_seat_add_listener(g_seat, &g_seatListener, null);
    }
    else if (strcmp(iface, zwp_pointer_constraints_v1_interface.name) == 0)
        g_constraints = cast(zwp_pointer_constraints_v1*) wsi_registry_bind(reg, name,
            &zwp_pointer_constraints_v1_interface, 1);
    else if (strcmp(iface, zwp_relative_pointer_manager_v1_interface.name) == 0)
        g_relMgr = cast(zwp_relative_pointer_manager_v1*) wsi_registry_bind(reg, name,
            &zwp_relative_pointer_manager_v1_interface, 1);
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
    immutable fd = memfd_create("wsi-f10", MFD_CLOEXEC);
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

/// Phase-tinted background + the confine region outlined + a crosshair the
/// relative deltas drive — the minimal "visible angle readout".
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
    immutable uint tint = g_lockActive ? 0xff602020
        : (g_confineActive ? 0xff206020 : 0xff202840);
    immutable cx = g_width / 2 + cast(int)(g_yaw * 4) % (g_width / 2);
    immutable cy = g_height / 2 + cast(int)(g_pitch * 4) % (g_height / 2);
    foreach (y; 0 .. buf.height)
        foreach (x; 0 .. buf.width)
        {
            uint c = tint;
            if (g_phase == Phase.confine
                && (x == g_confineRect[0] || x == g_confineRect[0] + g_confineRect[2] - 1
                    || y == g_confineRect[1] || y == g_confineRect[1] + g_confineRect[3] - 1)
                && x >= g_confineRect[0] && x < g_confineRect[0] + g_confineRect[2]
                && y >= g_confineRect[1] && y < g_confineRect[1] + g_confineRect[3])
                c = 0xff80ff80; // confine region outline
            if ((y == cy && x >= cx - 8 && x <= cx + 8)
                || (x == cx && y >= cy - 8 && y <= cy + 8))
                c = 0xffffffff; // crosshair
            buf.pixels[cast(size_t) y * buf.width + x] = c;
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
    // Self-contained input injection: `f10_pointer_capture inject …` plugs a
    // zwlr_virtual_pointer_v1 device in and streams motions (see ./inject.d).
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

    if (args.length == 7 && args[1] == "inject")
    {
        import inject : injectMain;

        return injectMain(parseInt(args[2]), parseInt(args[3]),
            parseInt(args[4]), parseInt(args[5]), parseInt(args[6]));
    }

    // WSI_PASSIVE=1: be a plain window only (no constraints) — ./run.sh runs
    // one as the focus-steal target that triggers compositor deactivation.
    const passiveEnv = getenv("WSI_PASSIVE");
    g_passive = passiveEnv !is null && *passiveEnv == '1';
    instrInit(g_passive ? "f10_passive" : "f10_wayland");
    const autoEnv = getenv("WSI_AUTO_EXIT");
    g_autoExit = autoEnv !is null && *autoEnv == '1';
    const runMs = getenv("WSI_RUN_MS");
    if (runMs !is null)
        g_runUsCap = atoi(runMs) * 1000L;

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

    // The per-compositor capability answer, logged before anything else runs.
    instrEvent("globals", "pointer_constraints=%d relative_pointer_manager=%d seat=%d",
        g_constraints !is null ? 1 : 0, g_relMgr !is null ? 1 : 0,
        g_seat !is null ? 1 : 0);

    if (g_seat is null)
    {
        // headless weston: no seat at all → no pointer, no constraints to
        // exercise; the registry probe above is the Tier-A evidence.
        printf("ok: no seat on this compositor; registry probe only\n");
        wl_display_disconnect(g_display);
        return 0;
    }
    // Headless sway: the seat starts at capabilities=0 and get_pointer before
    // the capability ever existed is a fatal wlroots protocol error — the
    // demo strictly waits for a capabilities event (./run.sh plugs a wlrctl
    // virtual pointer in).

    wsi_wm_base_add_listener(g_wmBase, &g_wmBaseListener, null);
    g_surface = wsi_compositor_create_surface(g_compositor);
    g_xdgSurface = wsi_wm_base_get_xdg_surface(g_wmBase, g_surface);
    wsi_xdg_surface_add_listener(g_xdgSurface, &g_xdgSurfaceListener, null);
    g_toplevel = wsi_xdg_surface_get_toplevel(g_xdgSurface);
    wsi_toplevel_add_listener(g_toplevel, &g_toplevelListener, null);
    const appId = g_passive ? "wsi-f10-passive".ptr : "wsi-f10-pointer-capture".ptr;
    wsi_toplevel_set_title(g_toplevel, appId);
    wsi_toplevel_set_app_id(g_toplevel, appId);
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
        if (g_autoExit && instrNowUs() > g_runUsCap)
            g_running = false;
    }

    instrEvent("summary",
        "phase_reached=%s lock_objects=%d abs_motions=%d abs_while_locked=%d rel_events=%d unaccel_differed=%d",
        g_phaseNames[g_phase], g_lockObjects, g_absMotions, g_absWhileLocked,
        g_relEvents, g_unaccelDiffered ? 1 : 0);
    if (g_cMaxX > -1e9)
        instrEvent("confine_summary", "rect=%d,%d %dx%d min=%.2f,%.2f max=%.2f,%.2f",
            g_confineRect[0], g_confineRect[1], g_confineRect[2], g_confineRect[3],
            g_cMinX, g_cMinY, g_cMaxX, g_cMaxY);

    // Teardown: children before parents.
    foreach (ref b; g_buffers)
        if (b.handle !is null)
        {
            wsi_buffer_destroy(b.handle);
            munmap(b.pixels, b.byteSize);
        }
    if (g_frameCb !is null)
        wsi_callback_destroy(g_frameCb);
    if (g_locked !is null)
        wsi_locked_destroy(g_locked);
    if (g_confined !is null)
        wsi_confined_destroy(g_confined);
    if (g_relPointer !is null)
        wsi_relative_destroy(g_relPointer);
    if (g_constraints !is null)
        wsi_constraints_destroy(g_constraints);
    if (g_relMgr !is null)
        wsi_relative_manager_destroy(g_relMgr);
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

    printf("ok: frames=%d commits=%d phase=%s lock_objects=%d abs_while_locked=%d\n",
        g_frames, g_commits, g_phaseNames[g_phase], g_lockObjects, g_absWhileLocked);
    return 0;
}
