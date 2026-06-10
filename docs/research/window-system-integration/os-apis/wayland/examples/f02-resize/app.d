// F02 — resize correctness (Wayland). Implements
// ../../../features/f02-resize.md on top of the proven xdg-shell scaffold
// (../scaffold/app.d, findings in ../../scaffold.md).
//
// Wayland never *imposes* a size — it *negotiates* one: every
// xdg_surface.configure carries a serial; the client must ack_configure that
// exact serial and then commit a buffer matching the configured size. This
// demo proves that contract under a programmatic resize storm and records
// what the compositor does when the contract is broken on purpose.
//
// What F02 adds over the scaffold:
//   - EVERY configure is logged with its serial, suggested size, and the full
//     xdg_toplevel states array (`configure serial=N size=WxH states=[...]`);
//   - a larger storm: maximize → unmaximize → fullscreen (via
//     xdg_toplevel.set_fullscreen) → unfullscreen → maximize → unmaximize;
//   - buffer (re)allocation strategy is fully logged: `buffer_alloc`,
//     `buffer_destroy reason=stale_size`, and every `wl_buffer.release`;
//   - `--violate`: once, after acking a NEW-size maximized configure (where
//     the size is a hard constraint per the xdg_toplevel.maximized state),
//     commit a buffer of the OLD size and capture the compositor's reaction
//     (protocol error payload, or "tolerated" after a grace period). The
//     violation run is a separate invocation; normal runs stay clean.
//
// Under WSI_AUTO_EXIT=1 the storm is self-driven and the demo exits 0.
// Headless-safe: no compositor → SKIP, exit 0.
module app;

import c; // ImportC: <wayland-client.h> + xdg-shell glue + wsi_* wrappers
import instrument;
import core.stdc.errno : EPROTO;
import core.stdc.stdio : printf, snprintf;
import core.stdc.stdlib : getenv;
import core.stdc.string : strcmp;

// ----------------------------------------------------------------- tunables

enum int defaultWidth = 640; // used while the compositor lets us pick (0x0 configure)
enum int defaultHeight = 480;
// Auto-exit storm choreography (frame-callback numbers, ~60 Hz):
enum int maximizeAtFrame = 20;
enum int unmaximizeAtFrame = 40;
enum int fullscreenAtFrame = 60; // xdg_toplevel.set_fullscreen(null) — compositor picks output
enum int unfullscreenAtFrame = 80;
enum int maximize2AtFrame = 100; // second cycle: prove the machine is re-entrant
enum int unmaximize2AtFrame = 115;
enum int autoExitFrames = 140; // ≈ 2.3 s at 60 Hz
enum long autoExitUsCap = 3_500_000; // wall-clock backstop
enum long violationGraceUs = 1_000_000; // no error within this → "tolerated"

// -------------------------------------------------------------------- state

/// One wl_shm-backed ARGB8888 buffer. `busy` is owned by the compositor
/// between wl_surface.commit and the wl_buffer.release event.
struct Buffer
{
    wl_buffer* handle;
    uint* pixels; // mmap'ed, shared with the compositor
    size_t byteSize;
    int width, height;
    bool busy;
}

enum Outcome
{
    none, // normal run, or violation not yet resolved
    protocolError,
    tolerated,
}

__gshared
{
    wl_display* g_display;
    wl_registry* g_registry;
    wl_compositor* g_compositor;
    wl_shm* g_shm;
    wl_seat* g_seat;
    xdg_wm_base* g_wmBase;
    wl_surface* g_surface;
    xdg_surface* g_xdgSurface;
    xdg_toplevel* g_toplevel;
    wl_callback* g_frameCb; // at most one outstanding frame callback

    Buffer[2] g_buffers; // double buffering: paint one while the other is on screen

    int g_width = defaultWidth; // last *acked* size — buffers must match it
    int g_height = defaultHeight;
    int g_floatingWidth = defaultWidth; // remembered for 0x0 ("you pick") configures
    int g_floatingHeight = defaultHeight;
    int g_pendingWidth; // from xdg_toplevel.configure (0 = client's choice)
    int g_pendingHeight;
    bool g_pendingMaximized; // latched from the xdg_toplevel.configure states array
    bool g_pendingFullscreen;
    bool g_configured; // first configure acked (may attach buffers from now on)
    bool g_presented; // first frame callback after the first buffer commit
    bool g_running = true;
    bool g_autoExit;
    int g_frames; // frame callbacks received
    int g_commits; // buffer commits sent
    int g_configures; // xdg_surface.configure events seen (== acks sent)
    int g_sizeChanges; // configures that changed the acked size
    int g_allocs; // wl_buffer allocations
    int g_reallocs; // stale-size buffer destroys

    // --violate machinery:
    bool g_violate; // armed by the CLI flag
    bool g_violationDone; // the wrong-sized commit went out
    Outcome g_outcome;
    long g_violationDeadlineUs;
    uint g_errCode; // wl_display_get_protocol_error payload
    uint g_errObjectId;
    const(char)* g_errInterface = "?";

    char[160] g_statesBuf = "\0"; // last states array, formatted
}

// -------------------------------------------------- states-array formatting

/// xdg_toplevel.state enum names (wayland-protocols 1.47, xdg-shell v6).
const(char)* stateName(uint s) nothrow @nogc
{
    switch (s)
    {
    case XDG_TOPLEVEL_STATE_MAXIMIZED:
        return "maximized";
    case XDG_TOPLEVEL_STATE_FULLSCREEN:
        return "fullscreen";
    case XDG_TOPLEVEL_STATE_RESIZING:
        return "resizing";
    case XDG_TOPLEVEL_STATE_ACTIVATED:
        return "activated";
    case XDG_TOPLEVEL_STATE_TILED_LEFT:
        return "tiled_left";
    case XDG_TOPLEVEL_STATE_TILED_RIGHT:
        return "tiled_right";
    case XDG_TOPLEVEL_STATE_TILED_TOP:
        return "tiled_top";
    case XDG_TOPLEVEL_STATE_TILED_BOTTOM:
        return "tiled_bottom";
    case XDG_TOPLEVEL_STATE_SUSPENDED:
        return "suspended";
    default:
        return "unknown";
    }
}

/// Format the configure states wl_array as `a,b,c` into g_statesBuf (also
/// latches maximized/fullscreen for the xdg_surface.configure handler).
void latchStates(const(wl_array)* states) nothrow @nogc
{
    g_pendingMaximized = false;
    g_pendingFullscreen = false;
    size_t off = 0;
    g_statesBuf[0] = '\0';
    const start = cast(const(uint)*) states.data;
    immutable n = states.size / uint.sizeof;
    foreach (i; 0 .. n)
    {
        immutable s = start[i];
        if (s == XDG_TOPLEVEL_STATE_MAXIMIZED)
            g_pendingMaximized = true;
        if (s == XDG_TOPLEVEL_STATE_FULLSCREEN)
            g_pendingFullscreen = true;
        if (off + 1 >= g_statesBuf.length)
            break;
        immutable wrote = snprintf(g_statesBuf.ptr + off, g_statesBuf.length - off,
            "%s%s", i ? ",".ptr : "".ptr, stateName(s));
        if (wrote <= 0)
            break;
        off += wrote;
    }
}

// ---------------------------------------------------------- shm buffer pool

/// (Re)allocate `b` so it matches `w`×`h`. Only ever called on non-busy
/// buffers, so destroying a stale-sized wl_buffer here is race-free. The
/// strategy — a finding F02 asks for — is per-resize realloc, lazily: a
/// stale-sized buffer lives until it is *picked* for reuse, never while the
/// compositor holds it.
bool ensureBuffer(ref Buffer b, int w, int h) nothrow @nogc
{
    if (b.handle !is null && (b.width != w || b.height != h))
    {
        instrEvent("buffer_destroy", "size=%dx%d reason=stale_size", b.width, b.height);
        g_reallocs++;
        wsi_buffer_destroy(b.handle);
        munmap(b.pixels, b.byteSize);
        b = Buffer.init;
    }
    if (b.handle !is null)
        return true;

    immutable stride = w * 4;
    immutable size = cast(size_t)(stride) * h;
    immutable fd = memfd_create("wsi-f02", MFD_CLOEXEC);
    if (fd < 0)
        return false;
    if (ftruncate(fd, cast(long) size) != 0)
    {
        close(fd);
        return false;
    }
    void* mem = mmap(null, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (mem is cast(void*)-1)
    {
        close(fd);
        return false;
    }

    // The pool can be destroyed right after create_buffer: the buffer keeps
    // the backing memory alive, and the compositor has dup'ed the fd.
    wl_shm_pool* pool = wsi_shm_create_pool(g_shm, fd, cast(int) size);
    b.handle = wsi_shm_pool_create_buffer(pool, 0, w, h, stride, WL_SHM_FORMAT_ARGB8888);
    wsi_shm_pool_destroy(pool);
    close(fd);
    wsi_buffer_add_listener(b.handle, &g_bufferListener, &b);

    b.pixels = cast(uint*) mem;
    b.byteSize = size;
    b.width = w;
    b.height = h;
    b.busy = false;
    g_allocs++;
    instrEvent("buffer_alloc", "size=%dx%d bytes=%zu", w, h, size);
    return true;
}

/// Corner-anchored diagonal gradient (F02 §1: geometry must visibly track the
/// window size) with a frame-driven blue channel so each redraw is observable.
void paint(ref Buffer b, int frame) nothrow @nogc
{
    immutable maxX = b.width > 1 ? b.width - 1 : 1;
    immutable maxY = b.height > 1 ? b.height - 1 : 1;
    immutable uint blue = (frame * 2) & 0xff;
    foreach (y; 0 .. b.height)
    {
        uint* row = b.pixels + cast(size_t) y * b.width;
        immutable uint g = cast(uint)(y * 255 / maxY) << 8;
        foreach (x; 0 .. b.width)
            row[x] = 0xff00_0000 | (cast(uint)(x * 255 / maxX) << 16) | g | blue;
    }
}

/// Paint a `w`×`h` buffer and commit it. `violation=true` bypasses the F02
/// size assertion — that is the single deliberate wrong-sized commit.
void renderAt(int w, int h, bool violation) nothrow @nogc
{
    Buffer* buf = null;
    foreach (ref b; g_buffers)
        if (!b.busy)
        {
            buf = &b;
            break;
        }
    if (buf is null)
    {
        // Both buffers held by the compositor: drop this frame. The
        // wl_buffer.release handler re-renders as soon as one comes back.
        instrEvent("frame_skipped", "reason=all_buffers_busy");
        return;
    }
    if (!ensureBuffer(*buf, w, h))
    {
        g_running = false;
        return;
    }
    paint(*buf, g_frames);

    // F02 contract: the committed buffer matches the acked configure size.
    assert(violation || (buf.width == g_width && buf.height == g_height),
        "committed buffer size does not match the acked configure size");

    wsi_surface_attach(g_surface, buf.handle, 0, 0);
    wsi_surface_damage_buffer(g_surface, 0, 0, buf.width, buf.height);
    if (g_frameCb is null) // keep exactly one frame callback in flight
    {
        g_frameCb = wsi_surface_frame(g_surface);
        wsi_callback_add_listener(g_frameCb, &g_frameListener, null);
    }
    wsi_surface_commit(g_surface);
    buf.busy = true;
    g_commits++;
    if (g_commits == 1)
        instrEvent("first_commit", "size=%dx%d", buf.width, buf.height);
    if (violation)
        instrEvent("violation_commit", "size=%dx%d acked=%dx%d", buf.width, buf.height,
            g_width, g_height);
}

/// Commit a buffer matching the current acked size.
void render() nothrow @nogc
{
    renderAt(g_width, g_height, false);
}

// ---------------------------------------------------------------- listeners
// All callbacks are `extern (C) nothrow @nogc` to match the listener
// function-pointer types the ImportC `#pragma attribute` stamped in c.c.

extern (C) void onGlobal(void* data, wl_registry* reg, uint name,
    const(char)* iface, uint ver) nothrow @nogc
{
    static uint capped(uint advertised, uint want) nothrow @nogc
    {
        return advertised < want ? advertised : want;
    }

    if (strcmp(iface, wl_compositor_interface.name) == 0)
        g_compositor = cast(wl_compositor*) wsi_registry_bind(reg, name,
            &wl_compositor_interface, capped(ver, 4)); // v4: wl_surface.damage_buffer
    else if (strcmp(iface, wl_shm_interface.name) == 0)
        g_shm = cast(wl_shm*) wsi_registry_bind(reg, name, &wl_shm_interface, 1);
    else if (strcmp(iface, xdg_wm_base_interface.name) == 0)
        g_wmBase = cast(xdg_wm_base*) wsi_registry_bind(reg, name, &xdg_wm_base_interface, 1);
    else if (strcmp(iface, wl_seat_interface.name) == 0)
        g_seat = cast(wl_seat*) wsi_registry_bind(reg, name, &wl_seat_interface,
            capped(ver, 2)); // v2: name event
    else
        return;
    instrEvent("step", "name=wl_registry_bind iface=%s version=%u", iface, ver);
}

extern (C) void onGlobalRemove(void* data, wl_registry* reg, uint name) nothrow @nogc
{
}

extern (C) void onWmBasePing(void* data, xdg_wm_base* b, uint serial) nothrow @nogc
{
    wsi_wm_base_pong(b, serial); // liveness check — answer or be killed
    instrEvent("ping_pong", "serial=%u", serial);
}

extern (C) void onSeatCapabilities(void* data, wl_seat* s, uint caps) nothrow @nogc
{
    instrEvent("seat_capabilities", "caps=0x%x", caps);
}

extern (C) void onSeatName(void* data, wl_seat* s, const(char)* name) nothrow @nogc
{
    instrEvent("seat_name", "name=%s", name);
}

/// xdg_toplevel.configure: the compositor *suggests* a size (0×0 = "you
/// pick") plus the full states array. Only latched here; everything takes
/// effect atomically at the following xdg_surface.configure.
extern (C) void onToplevelConfigure(void* data, xdg_toplevel* t, int w, int h,
    wl_array* states) nothrow @nogc
{
    g_pendingWidth = w;
    g_pendingHeight = h;
    latchStates(states);
    instrEvent("xdg_toplevel_configure", "size=%dx%d states=[%s]", w, h, g_statesBuf.ptr);
}

/// xdg_surface.configure: the atomic "apply everything" event. Protocol
/// order proven in the WAYLAND_DEBUG trace: ack_configure(serial) *then* the
/// commit of a buffer matching the new size — except for the single armed
/// `--violate` commit, which deliberately commits the OLD size after acking.
extern (C) void onXdgSurfaceConfigure(void* data, xdg_surface* s, uint serial) nothrow @nogc
{
    // 0x0 means "client picks": a robust client restores its remembered
    // floating size, not a hardcoded default.
    immutable w = g_pendingWidth > 0 ? g_pendingWidth : g_floatingWidth;
    immutable h = g_pendingHeight > 0 ? g_pendingHeight : g_floatingHeight;
    g_configures++;
    instrEvent("configure", "serial=%u size=%dx%d states=[%s]", serial, w, h, g_statesBuf.ptr);

    wsi_xdg_surface_ack_configure(s, serial);
    instrStep("xdg_surface_ack_configure");

    immutable resized = w != g_width || h != g_height;

    // --violate: maximized makes the configured size a hard constraint
    // (xdg-shell: "the surface ... must have the configured size") — exactly
    // the case where a wrong-sized commit is unambiguous. Ack was correct;
    // the commit below is the one deliberate lie.
    if (g_violate && !g_violationDone && g_configured && g_pendingMaximized && resized)
    {
        g_violationDone = true;
        immutable oldW = g_width;
        immutable oldH = g_height;
        instrEvent("violation", "acked_serial=%u acked_size=%dx%d committing=%dx%d",
            serial, w, h, oldW, oldH);
        g_width = w; // record what we *should* be at, for the recovery path
        g_height = h;
        renderAt(oldW, oldH, true); // OLD size, on purpose
        g_violationDeadlineUs = instrNowUs() + violationGraceUs;
        return;
    }

    g_width = w;
    g_height = h;
    if (!g_pendingMaximized && !g_pendingFullscreen)
    {
        g_floatingWidth = w; // remember the floating size for 0x0 configures
        g_floatingHeight = h;
    }

    if (!g_configured)
    {
        g_configured = true;
        instrFirstConfigure();
        render(); // the first buffer commit — the window becomes visible
    }
    else if (resized)
    {
        g_sizeChanges++;
        instrResize(w, h, 1); // no fractional-scale binding in this demo
        render(); // commit a matching buffer right away, don't wait a frame
    }
}

extern (C) void onToplevelClose(void* data, xdg_toplevel* t) nothrow @nogc
{
    instrCloseRequested();
    g_running = false;
}

// Bound at xdg_wm_base v1, so these v4/v5 events never arrive; the listener
// struct generated from wayland-protocols 1.47 still has the slots to fill.
extern (C) void onToplevelConfigureBounds(void* data, xdg_toplevel* t, int w, int h) nothrow @nogc
{
}

extern (C) void onToplevelWmCapabilities(void* data, xdg_toplevel* t, wl_array* caps) nothrow @nogc
{
}

/// wl_buffer.release: the compositor no longer reads the buffer; reuse it.
/// Logged because *when* this fires is the buffer-lifetime finding (weston
/// copies shm pixels at repaint and releases almost immediately).
extern (C) void onBufferRelease(void* data, wl_buffer* b) nothrow @nogc
{
    auto buf = cast(Buffer*) data;
    buf.busy = false;
    instrEvent("buffer_release", "size=%dx%d", buf.width, buf.height);
    // If a frame was dropped because both buffers were busy, recover here.
    if (g_running && g_configured && g_frameCb is null)
        render();
}

/// wl_surface.frame `done`: the compositor presented the surface and is
/// ready for the next frame. Drives the redraw loop, the resize storm, and
/// the violation grace-period check.
extern (C) void onFrameDone(void* data, wl_callback* cb, uint timeMs) nothrow @nogc
{
    wsi_callback_destroy(cb); // one-shot object
    g_frameCb = null;
    g_frames++;
    instrFrameCallback(timeMs);

    if (!g_presented)
    {
        g_presented = true;
        instrFirstPixelPresented();
    }

    // Violation epilogue: no protocol error within the grace period means
    // the compositor tolerated the wrong-sized buffer.
    if (g_violationDone && g_outcome == Outcome.none
        && instrNowUs() > g_violationDeadlineUs)
    {
        g_outcome = Outcome.tolerated;
        instrEvent("violation_outcome", "result=tolerated grace_us=%lld frames_after=%d",
            violationGraceUs, g_frames);
        g_running = false;
        return;
    }

    if (g_autoExit && !g_violationDone)
    {
        switch (g_frames)
        {
        case maximizeAtFrame:
        case maximize2AtFrame:
            wsi_toplevel_set_maximized(g_toplevel);
            instrStep("xdg_toplevel_set_maximized");
            break;
        case unmaximizeAtFrame:
        case unmaximize2AtFrame:
            wsi_toplevel_unset_maximized(g_toplevel);
            instrStep("xdg_toplevel_unset_maximized");
            break;
        case fullscreenAtFrame:
            wsi_toplevel_set_fullscreen(g_toplevel, null); // compositor picks the output
            instrStep("xdg_toplevel_set_fullscreen");
            break;
        case unfullscreenAtFrame:
            wsi_toplevel_unset_fullscreen(g_toplevel);
            instrStep("xdg_toplevel_unset_fullscreen");
            break;
        default:
            break;
        }
    }
    if (g_autoExit && g_outcome == Outcome.none
        && (g_frames >= autoExitFrames || instrNowUs() > autoExitUsCap))
    {
        g_running = false;
        return;
    }
    render();
}

__gshared wl_registry_listener g_registryListener = {&onGlobal, &onGlobalRemove};
__gshared xdg_wm_base_listener g_wmBaseListener = {&onWmBasePing};
__gshared wl_seat_listener g_seatListener = {&onSeatCapabilities, &onSeatName};
__gshared xdg_surface_listener g_xdgSurfaceListener = {&onXdgSurfaceConfigure};
__gshared xdg_toplevel_listener g_toplevelListener = {
    &onToplevelConfigure, &onToplevelClose,
    &onToplevelConfigureBounds, &onToplevelWmCapabilities
};
__gshared wl_buffer_listener g_bufferListener = {&onBufferRelease};
__gshared wl_callback_listener g_frameListener = {&onFrameDone};

// ------------------------------------------------------------ error capture

/// wl_display_dispatch returned -1: pull the error off the display. For a
/// protocol error, wl_display_get_protocol_error yields the interface, error
/// code, and object id (the violation run's headline data; the human-readable
/// message only exists in libwayland's stderr log / WAYLAND_DEBUG trace).
void captureDisplayError() nothrow @nogc
{
    immutable err = wl_display_get_error(g_display);
    if (err == EPROTO)
    {
        wl_interface* iface;
        uint id;
        immutable code = wl_display_get_protocol_error(g_display, &iface, &id);
        g_errCode = code;
        g_errObjectId = id;
        g_errInterface = iface !is null ? iface.name : "?";
        if (g_violationDone && g_outcome == Outcome.none)
            g_outcome = Outcome.protocolError;
        instrEvent("protocol_error", "interface=%s code=%u object_id=%u",
            g_errInterface, code, id);
    }
    else
        instrEvent("display_error", "errno=%d", err);
}

// ----------------------------------------------------------------- teardown

void teardown() nothrow @nogc
{
    instrEvent("teardown_start");
    foreach (ref b; g_buffers)
        if (b.handle !is null)
        {
            wsi_buffer_destroy(b.handle);
            munmap(b.pixels, b.byteSize);
            b = Buffer.init;
        }
    if (g_frameCb !is null)
        wsi_callback_destroy(g_frameCb);
    if (g_toplevel !is null)
        wsi_toplevel_destroy(g_toplevel);
    if (g_xdgSurface !is null)
        wsi_xdg_surface_destroy(g_xdgSurface);
    if (g_surface !is null)
        wsi_surface_destroy(g_surface);
    if (g_wmBase !is null)
        wsi_wm_base_destroy(g_wmBase);
    // The remaining globals have no destructor request at the bound versions;
    // destroying the client-side proxy is the correct cleanup.
    if (g_seat !is null)
        wl_proxy_destroy(cast(wl_proxy*) g_seat);
    if (g_shm !is null)
        wl_proxy_destroy(cast(wl_proxy*) g_shm);
    if (g_compositor !is null)
        wl_proxy_destroy(cast(wl_proxy*) g_compositor);
    if (g_registry !is null)
        wl_proxy_destroy(cast(wl_proxy*) g_registry);
    wl_display_disconnect(g_display);
    instrEvent("teardown_done");
}

// --------------------------------------------------------------------- main

int main(string[] args)
{
    instrInit("f02-wayland");
    const autoEnv = getenv("WSI_AUTO_EXIT");
    g_autoExit = autoEnv !is null && *autoEnv == '1';
    foreach (arg; args[1 .. $])
        if (arg == "--violate")
            g_violate = true;
    if (g_violate)
        instrEvent("violate_armed");

    // 1. Connect (SKIP cleanly on headless hosts without a compositor).
    g_display = wl_display_connect(null);
    if (g_display is null)
    {
        printf("SKIP: no Wayland compositor (wl_display_connect returned null)\n");
        return 0;
    }
    instrStep("wl_display_connect");

    // 2. Registry: discover and bind the globals a window needs.
    g_registry = wsi_display_get_registry(g_display);
    instrStep("wl_display_get_registry");
    wsi_registry_add_listener(g_registry, &g_registryListener, null);
    wl_display_roundtrip(g_display); // blocks; onGlobal binds during this
    instrStep("wl_display_roundtrip");

    if (g_compositor is null || g_shm is null || g_wmBase is null)
    {
        printf("SKIP: compositor lacks a required global (wl_compositor/wl_shm/xdg_wm_base)\n");
        teardown();
        return 0;
    }
    wsi_wm_base_add_listener(g_wmBase, &g_wmBaseListener, null);
    if (g_seat !is null)
        wsi_seat_add_listener(g_seat, &g_seatListener, null);

    // 3. Build the window object tree: wl_surface → xdg_surface → xdg_toplevel.
    g_surface = wsi_compositor_create_surface(g_compositor);
    instrStep("wl_compositor_create_surface");
    g_xdgSurface = wsi_wm_base_get_xdg_surface(g_wmBase, g_surface);
    instrStep("xdg_wm_base_get_xdg_surface");
    wsi_xdg_surface_add_listener(g_xdgSurface, &g_xdgSurfaceListener, null);
    g_toplevel = wsi_xdg_surface_get_toplevel(g_xdgSurface);
    instrStep("xdg_surface_get_toplevel");
    wsi_toplevel_add_listener(g_toplevel, &g_toplevelListener, null);
    wsi_toplevel_set_title(g_toplevel, "wsi-f02-resize");
    instrStep("xdg_toplevel_set_title");
    wsi_toplevel_set_app_id(g_toplevel, "wsi-f02-resize");
    instrStep("xdg_toplevel_set_app_id");
    instrWindowCreated();

    // 4. The mandatory initial commit *without* a buffer (attaching one before
    //    the first configure is a protocol error). The compositor answers with
    //    the first xdg_surface.configure; the first pixel happens in its handler.
    wsi_surface_commit(g_surface);
    instrStep("wl_surface_commit");

    // 5. Event loop. wl_display_dispatch flushes requests, blocks on the
    //    socket, and dispatches a batch of events; the listeners above do all
    //    the work. A -1 return after the violation is the compositor killing
    //    the connection — capture the protocol-error payload.
    while (g_running)
    {
        if (wl_display_dispatch(g_display) == -1)
        {
            captureDisplayError();
            break;
        }
        if (g_autoExit && instrNowUs() > autoExitUsCap + 2_000_000)
            g_running = false; // hard backstop if frame callbacks ever stall
    }

    // 6. Clean teardown: buffers → frame callback → role objects → surface →
    //    globals → registry → disconnect (children before parents).
    teardown();

    if (g_violate)
    {
        final switch (g_outcome)
        {
        case Outcome.protocolError:
            printf("violation outcome: protocol error — interface=%s code=%u object_id=%u "
                ~ "(connection killed by the compositor)\n",
                g_errInterface, g_errCode, g_errObjectId);
            break;
        case Outcome.tolerated:
            printf("violation outcome: tolerated — no protocol error within %lld ms; "
                ~ "compositor accepted a wrong-sized buffer against a maximized configure\n",
                violationGraceUs / 1000);
            break;
        case Outcome.none:
            printf("violation outcome: NOT CAPTURED (violation never triggered)\n");
            return 1;
        }
        // Both reactions are a successfully captured experiment → exit 0.
        return 0;
    }

    printf("ok: %d frames, %d commits, %d configures acked, %d size changes, "
        ~ "%d buffer allocs (%d stale-size reallocs), final size %dx%d\n",
        g_frames, g_commits, g_configures, g_sizeChanges, g_allocs, g_reallocs,
        g_width, g_height);
    return 0;
}
