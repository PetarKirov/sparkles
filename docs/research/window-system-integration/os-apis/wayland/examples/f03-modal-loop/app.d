// F03 modal-loop survival on Wayland (../../f03-modal-loop.md): there is no
// modal loop to survive — that asymmetry IS the finding.
//
// On Win32, interactive resize/move traps the thread in a system modal loop
// (WM_ENTERSIZEMOVE → DefWindowProc owns the pump until WM_EXITSIZEMOVE) and
// a naive animation freezes. Wayland has no equivalent: window-state changes
// of every kind — maximize, unmaximize, fullscreen, and (on a real desktop)
// interactive resize/move — arrive as ordinary xdg_toplevel.configure events
// on the one event loop the client already runs. Nothing ever takes the loop
// away from the client; there is no protocol event that could play the role
// of `modal_enter`/`modal_exit`.
//
// The demo proves it: a full-window color-cycle animation (~2 Hz hue rotation)
// driven purely by wl_surface.frame callbacks, logging `tick t=<cb-ms>
// dt_us=<inter-tick delta>` per frame, runs THROUGH a storm of programmatic
// state transitions (maximize → unmaximize → fullscreen → unfullscreen, three
// full cycles, one transition every 10 frames) — the closest headless analog
// of interactive resize, since each transition is just more configure events
// on the same loop. The exit summary reports the max inter-tick gap inside
// and outside the storm window plus `modal_enter=0 modal_exit=0`.
//
// Interactive title-bar drag on a real compositor (mutter/kwin/sway) is the
// Tier C half: run without WSI_AUTO_EXIT, drag the window, and watch the
// color cycle — and the tick log — continue uninterrupted.
//
// Based on the scaffold (../scaffold/app.d, findings ../../scaffold.md);
// instrumentation contract: ./instrument.d. Headless-safe: no compositor →
// SKIP, exit 0.
module app;

import c; // ImportC: <wayland-client.h> + xdg-shell glue + wsi_* wrappers
import instrument;
import core.stdc.stdio : printf;
import core.stdc.stdlib : getenv;
import core.stdc.string : strcmp;

// ----------------------------------------------------------------- tunables

enum int defaultWidth = 640; // used while the compositor lets us pick (0x0 configure)
enum int defaultHeight = 480;
enum int stormStartFrame = 30; // settle first, then storm …
enum int stormStrideFrames = 10; // … one state transition every N frames …
enum int stormTransitions = 12; // … 3 full max/unmax/fs/unfs cycles
enum int autoExitFrames = 200; // ≈ 3.3 s at 60 Hz (storm ends at frame 150)
enum long autoExitUsCap = 5_000_000; // wall-clock backstop
enum long hueDegreesPerSecond = 720; // 2 full color cycles per second (~2 Hz)

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
    int g_pendingWidth; // from xdg_toplevel.configure (0 = client's choice)
    int g_pendingHeight;
    bool g_configured; // first configure acked (may attach buffers from now on)
    bool g_presented; // first frame callback after the first buffer commit
    bool g_running = true;
    bool g_autoExit;
    int g_frames; // frame callbacks received (= animation ticks)
    int g_commits; // buffer commits sent
    int g_configures; // xdg_surface.configure events seen

    // Modal-loop bookkeeping. On Win32 these would count WM_ENTERSIZEMOVE /
    // WM_EXITSIZEMOVE; on Wayland no protocol event maps to either, so they
    // stay 0 by construction — there is nothing to hook.
    int g_modalEnters = 0;
    int g_modalExits = 0;

    // Inter-tick gap tracking (monotonic µs between consecutive frame
    // callbacks), split into "inside the state storm" and "outside".
    long g_lastTickUs = -1;
    long g_maxGapUs = 0; // outside the storm window
    long g_maxGapStormUs = 0; // inside the storm window
    int g_transitionsSent = 0;
}

bool inStorm() nothrow @nogc
{
    return g_frames >= stormStartFrame
        && g_frames <= stormStartFrame + stormStrideFrames * stormTransitions;
}

// ---------------------------------------------------------- shm buffer pool

/// (Re)allocate `b` so it matches `w`×`h`. Only ever called on non-busy
/// buffers, so destroying a stale-sized wl_buffer here is race-free.
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
    immutable size = cast(size_t)(stride) * h;
    immutable fd = memfd_create("wsi-f03", MFD_CLOEXEC);
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
    instrEvent("buffer_alloc", "size=%dx%d bytes=%zu", w, h, size);
    return true;
}

/// Hue (degrees) → packed 0xffRRGGBB, saturation/value = 1 (the classic HSV
/// hexcone, integer math only).
uint hueToArgb(long hueDeg) nothrow @nogc
{
    immutable h = cast(int)(hueDeg % 360);
    immutable sector = h / 60; // 0..5
    immutable ramp = cast(uint)((h % 60) * 255 / 59); // 0..255 within the sector
    uint r, g, b;
    switch (sector)
    {
    case 0:
        r = 255;
        g = ramp;
        break;
    case 1:
        r = 255 - ramp;
        g = 255;
        break;
    case 2:
        g = 255;
        b = ramp;
        break;
    case 3:
        g = 255 - ramp;
        b = 255;
        break;
    case 4:
        r = ramp;
        b = 255;
        break;
    case 5:
        r = 255;
        b = 255 - ramp;
        break;
    default:
        assert(0);
    }
    return 0xff00_0000 | (r << 16) | (g << 8) | b;
}

/// Full-window solid fill from the wall-clock hue — a ~2 Hz color cycle.
/// Deriving the hue from elapsed time (not the frame counter) means a frozen
/// loop would be visible as a color jump, not just a missing log line.
void paint(ref Buffer b) nothrow @nogc
{
    immutable color = hueToArgb(instrNowUs() * hueDegreesPerSecond / 1_000_000);
    immutable n = cast(size_t) b.width * b.height;
    foreach (i; 0 .. n)
        b.pixels[i] = color;
}

/// Paint into a free buffer and commit it, requesting the next frame callback.
void render() nothrow @nogc
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
    if (!ensureBuffer(*buf, g_width, g_height))
    {
        g_running = false;
        return;
    }
    paint(*buf);

    // F02 contract: the buffer we are about to commit matches the acked size.
    assert(buf.width == g_width && buf.height == g_height,
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
}

// ----------------------------------------------------------- the state storm

/// One programmatic window-state transition — the headless stand-in for
/// interactive resize/move. Each is a single request; everything the
/// compositor does in response is configure events on the normal loop.
void stormTransition(int n) nothrow @nogc
{
    switch (n % 4)
    {
    case 0:
        wsi_toplevel_set_maximized(g_toplevel);
        instrEvent("storm", "n=%d request=set_maximized", n);
        break;
    case 1:
        wsi_toplevel_unset_maximized(g_toplevel);
        instrEvent("storm", "n=%d request=unset_maximized", n);
        break;
    case 2:
        wsi_toplevel_set_fullscreen(g_toplevel);
        instrEvent("storm", "n=%d request=set_fullscreen", n);
        break;
    case 3:
        wsi_toplevel_unset_fullscreen(g_toplevel);
        instrEvent("storm", "n=%d request=unset_fullscreen", n);
        break;
    default:
        assert(0);
    }
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
}

extern (C) void onSeatCapabilities(void* data, wl_seat* s, uint caps) nothrow @nogc
{
    instrEvent("seat_capabilities", "caps=0x%x", caps);
}

extern (C) void onSeatName(void* data, wl_seat* s, const(char)* name) nothrow @nogc
{
}

/// xdg_toplevel.configure: the compositor *suggests* a size plus the state
/// array (maximized/fullscreen/resizing/…). Note `resizing`: interactive
/// resize on a real compositor announces itself HERE, as a state bit on an
/// ordinary event — not by hijacking the loop.
extern (C) void onToplevelConfigure(void* data, xdg_toplevel* t, int w, int h,
    wl_array* states) nothrow @nogc
{
    g_pendingWidth = w;
    g_pendingHeight = h;
    int maximized = 0, fullscreen = 0, resizing = 0;
    const start = cast(const(uint)*) states.data;
    foreach (i; 0 .. states.size / uint.sizeof)
    {
        if (start[i] == XDG_TOPLEVEL_STATE_MAXIMIZED)
            maximized = 1;
        if (start[i] == XDG_TOPLEVEL_STATE_FULLSCREEN)
            fullscreen = 1;
        if (start[i] == XDG_TOPLEVEL_STATE_RESIZING)
            resizing = 1;
    }
    instrEvent("xdg_toplevel_configure", "size=%dx%d maximized=%d fullscreen=%d resizing=%d",
        w, h, maximized, fullscreen, resizing);
}

/// xdg_surface.configure: the atomic "apply everything" event — including
/// every storm transition. Handled inline on the same loop the animation
/// runs on; nothing blocks.
extern (C) void onXdgSurfaceConfigure(void* data, xdg_surface* s, uint serial) nothrow @nogc
{
    immutable w = g_pendingWidth > 0 ? g_pendingWidth : defaultWidth;
    immutable h = g_pendingHeight > 0 ? g_pendingHeight : defaultHeight;
    g_configures++;
    instrEvent("configure", "serial=%u size=%dx%d", serial, w, h);

    wsi_xdg_surface_ack_configure(s, serial);

    immutable resized = w != g_width || h != g_height;
    g_width = w;
    g_height = h;

    if (!g_configured)
    {
        g_configured = true;
        instrFirstConfigure();
        render(); // the first buffer commit — the window becomes visible
    }
    else if (resized)
    {
        instrResize(w, h, 1);
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
extern (C) void onBufferRelease(void* data, wl_buffer* b) nothrow @nogc
{
    auto buf = cast(Buffer*) data;
    buf.busy = false;
    // If a frame was dropped because both buffers were busy, recover here.
    if (g_running && g_configured && g_frameCb is null)
        render();
}

/// wl_surface.frame `done` — one animation tick. The inter-tick delta is the
/// quantity F03 bounds: it must stay in the same ballpark inside the state
/// storm as outside it.
extern (C) void onFrameDone(void* data, wl_callback* cb, uint timeMs) nothrow @nogc
{
    wsi_callback_destroy(cb); // one-shot object
    g_frameCb = null;
    g_frames++;

    immutable now = instrNowUs();
    long dt = 0;
    if (g_lastTickUs >= 0)
    {
        dt = now - g_lastTickUs;
        if (inStorm())
        {
            if (dt > g_maxGapStormUs)
                g_maxGapStormUs = dt;
        }
        else if (dt > g_maxGapUs)
            g_maxGapUs = dt;
    }
    g_lastTickUs = now;
    instrEvent("tick", "t=%u dt_us=%lld", timeMs, dt);

    if (!g_presented)
    {
        g_presented = true;
        instrFirstPixelPresented();
    }

    if (g_autoExit)
    {
        if (g_frames >= stormStartFrame && g_transitionsSent < stormTransitions
            && (g_frames - stormStartFrame) % stormStrideFrames == 0)
        {
            stormTransition(g_transitionsSent);
            g_transitionsSent++;
        }
        if (g_frames >= autoExitFrames || instrNowUs() > autoExitUsCap)
        {
            g_running = false;
            return;
        }
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

// ----------------------------------------------------------------- teardown

void teardown() nothrow @nogc
{
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
}

// --------------------------------------------------------------------- main

int main()
{
    instrInit("f03_wayland");
    const autoEnv = getenv("WSI_AUTO_EXIT");
    g_autoExit = autoEnv !is null && *autoEnv == '1';

    // 1. Connect (SKIP cleanly on headless hosts without a compositor).
    g_display = wl_display_connect(null);
    if (g_display is null)
    {
        printf("SKIP: no Wayland compositor (wl_display_connect returned null)\n");
        return 0;
    }

    // 2. Registry: discover and bind the globals a window needs.
    g_registry = wsi_display_get_registry(g_display);
    wsi_registry_add_listener(g_registry, &g_registryListener, null);
    wl_display_roundtrip(g_display); // blocks; onGlobal binds during this

    if (g_compositor is null || g_shm is null || g_wmBase is null)
    {
        printf("SKIP: compositor lacks a required global (wl_compositor/wl_shm/xdg_wm_base)\n");
        teardown();
        return 0;
    }
    wsi_wm_base_add_listener(g_wmBase, &g_wmBaseListener, null);
    if (g_seat !is null)
        wsi_seat_add_listener(g_seat, &g_seatListener, null);

    // 3. Window object tree: wl_surface → xdg_surface → xdg_toplevel.
    g_surface = wsi_compositor_create_surface(g_compositor);
    g_xdgSurface = wsi_wm_base_get_xdg_surface(g_wmBase, g_surface);
    wsi_xdg_surface_add_listener(g_xdgSurface, &g_xdgSurfaceListener, null);
    g_toplevel = wsi_xdg_surface_get_toplevel(g_xdgSurface);
    wsi_toplevel_add_listener(g_toplevel, &g_toplevelListener, null);
    wsi_toplevel_set_title(g_toplevel, "wsi-f03-modal-loop");
    wsi_toplevel_set_app_id(g_toplevel, "wsi-f03-modal-loop");
    instrWindowCreated();

    // 4. The mandatory initial no-buffer commit; first pixel happens in the
    //    configure handler.
    wsi_surface_commit(g_surface);

    // 5. THE event loop — singular, client-owned, never preempted. Every
    //    storm transition above is absorbed as configure events dispatched
    //    right here, between two animation ticks. There is no API by which
    //    the compositor could trap this loop the way Win32's
    //    WM_ENTERSIZEMOVE modal loop traps the pumping thread.
    while (g_running && wl_display_dispatch(g_display) != -1)
    {
        if (g_autoExit && instrNowUs() > autoExitUsCap + 2_000_000)
            g_running = false; // hard backstop if frame callbacks ever stall
    }

    // 6. Teardown + verdict.
    instrEvent("summary",
        "ticks=%d transitions=%d configures=%d max_gap_us=%lld storm_max_gap_us=%lld "
            ~ "modal_enter=%d modal_exit=%d",
        g_frames, g_transitionsSent, g_configures, g_maxGapUs, g_maxGapStormUs,
        g_modalEnters, g_modalExits);
    teardown();
    printf("ok: %d ticks through %d state transitions; max inter-tick gap %lld us "
            ~ "(storm) / %lld us (calm); modal_enter=%d modal_exit=%d — "
            ~ "no modal-loop concept exists in the protocol\n",
        g_frames, g_transitionsSent, g_maxGapStormUs, g_maxGapUs,
        g_modalEnters, g_modalExits);
    return 0;
}
