// F04 vsync / frame pacing on Wayland (../../f04-frame-pacing.md): how steady
// is the native frame clock, and what happens to it when the window goes away?
//
// Wayland's "draw now, in sync with the display" primitive is the
// wl_surface.frame callback: request one before commit, and the compositor
// fires `done(callback_data)` when it is "a good time to start drawing a new
// frame". The demo drives a trivially cheap redraw (solid color flip, two
// alternating colors) from NOTHING but that callback — no sleep, no timer, no
// busy loop — and:
//
//   1. logs `frame_callback t=<callback_data>` for 600 consecutive measured
//      frames, then computes min/median/p99/max inter-frame delta and a
//      coarse 1 ms histogram (printed to stdout at exit). Deltas are measured
//      on the client's own MonoTime µs clock; the callback's ms-resolution
//      time argument is logged alongside for clock-identity comparison.
//   2. probes occlusion: requests xdg_toplevel.set_minimized, keeps a frame
//      callback requested, and measures — against an independent poll(2)
//      timeout clock, so a callback that never comes cannot deadlock the
//      demo — how long the frame clock simply STOPS. After ~3 s it restores
//      via set_maximized + a fresh attach/commit and logs the resumption gap.
//   3. dumps every registry global (`global iface=… version=…`), which
//      answers whether wp_presentation (the protocol that adds real
//      presentation timestamps to this "draw now" signal) is advertised.
//
// Headless caveat, prominently: under `weston --backend=headless` the repaint
// clock is synthetic (default 60 Hz; `--refresh-rate=N` overrides). The
// numbers characterize the protocol's delivery jitter, not hardware vsync.
//
// Event-loop note: instead of the scaffold's blocking wl_display_dispatch,
// this demo runs the libwayland prepare_read/poll/read_events/dispatch_pending
// pattern so the poll timeout doubles as the independent clock for phase 2.
//
// Based on the scaffold (../scaffold/app.d, findings ../../scaffold.md);
// instrumentation contract: ./instrument.d. Headless-safe: no compositor →
// SKIP, exit 0.
module app;

import c; // ImportC: <wayland-client.h> + xdg-shell glue + wsi_* wrappers
import instrument;
import core.stdc.stdio : printf;
import core.stdc.stdlib : getenv, qsort;
import core.stdc.string : strcmp;

// ----------------------------------------------------------------- tunables

enum int defaultWidth = 640; // used while the compositor lets us pick (0x0 configure)
enum int defaultHeight = 480;
enum int measuredFrames = 600; // inter-frame deltas to collect (601 callbacks)
enum long minimizedProbeUs = 3_000_000; // hold the minimized state ~3 s
enum long restoreTimeoutUs = 3_000_000; // give up if no callback after restore
enum int pollTimeoutMs = 50; // the independent clock's tick
enum long hardCapUs = 30_000_000; // absolute wall-clock backstop
enum int histBuckets = 40; // 1 ms histogram buckets: 0..38 ms + overflow

// -------------------------------------------------------------------- state

enum Phase
{
    measure, // collecting the 600 inter-frame deltas
    minimized, // set_minimized sent; counting the silence
    restoring, // set_maximized + commit sent; waiting for the clock to resume
    done,
}

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
    int g_frames; // frame callbacks received, total
    int g_commits; // buffer commits sent
    bool g_sawPresentation; // wp_presentation in the registry?

    Phase g_phase = Phase.measure;

    // Phase 1: pacing measurement.
    long[measuredFrames] g_deltasUs; // inter-callback deltas, client MonoTime µs
    int g_deltaCount;
    long g_lastCbUs = -1; // arrival time of the previous callback (µs)
    uint g_lastCbArgMs; // previous callback's own time argument (ms)
    uint g_firstCbArgMs, g_finalCbArgMs; // for the callback-arg clock identity

    // Phase 2: occlusion probe (all µs on the client MonoTime clock).
    long g_minimizeReqUs = -1; // when set_minimized was requested
    long g_lastTickBeforeMinUs = -1; // last callback before the minimize
    int g_cbWhileMinimized; // callbacks that fired during the silence
    long g_restoreReqUs = -1; // when set_maximized + commit was sent
    long g_resumeCbUs = -1; // first callback after the restore
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
    immutable fd = memfd_create("wsi-f04", MFD_CLOEXEC);
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

/// The trivially cheap frame: a full-window solid fill alternating between
/// two colors, so every presented frame is distinguishable but costs only a
/// memset-grade loop.
void paint(ref Buffer b, int frame) nothrow @nogc
{
    immutable uint color = (frame & 1) ? 0xff20_6080 : 0xff80_4020;
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
    paint(*buf, g_frames);

    // F02 contract: the buffer we are about to commit matches the acked size.
    assert(buf.width == g_width && buf.height == g_height,
        "committed buffer size does not match the acked configure size");

    wsi_surface_attach(g_surface, buf.handle, 0, 0);
    wsi_surface_damage_buffer(g_surface, 0, 0, buf.width, buf.height);
    requestFrameCallback();
    wsi_surface_commit(g_surface);
    buf.busy = true;
    g_commits++;
    if (g_commits == 1)
        instrEvent("first_commit", "size=%dx%d", buf.width, buf.height);
}

void requestFrameCallback() nothrow @nogc
{
    if (g_frameCb !is null) // keep exactly one in flight
        return;
    g_frameCb = wsi_surface_frame(g_surface);
    wsi_callback_add_listener(g_frameCb, &g_frameListener, null);
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

    // Full registry dump: F04 needs to know whether wp_presentation — the
    // protocol that upgrades "draw now" to real presentation timestamps — is
    // among the advertised globals.
    instrEvent("global", "iface=%s version=%u", iface, ver);
    if (strcmp(iface, "wp_presentation") == 0)
        g_sawPresentation = true;

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
}

extern (C) void onSeatName(void* data, wl_seat* s, const(char)* name) nothrow @nogc
{
}

/// xdg_toplevel.configure: latch the suggested size; applied at
/// xdg_surface.configure.
extern (C) void onToplevelConfigure(void* data, xdg_toplevel* t, int w, int h,
    wl_array* states) nothrow @nogc
{
    g_pendingWidth = w;
    g_pendingHeight = h;
    instrEvent("xdg_toplevel_configure", "size=%dx%d", w, h);
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
        render(); // the first buffer commit — the window becomes visible
    }
    else if (resized && g_phase != Phase.minimized)
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
    if (g_running && g_configured && g_frameCb is null && g_phase != Phase.minimized)
        render();
}

/// wl_surface.frame `done` — the frame clock tick under measurement.
/// `timeMs` is the callback's own time argument: milliseconds, "with an
/// undefined base" per the spec — its clock identity is an F04 finding.
extern (C) void onFrameDone(void* data, wl_callback* cb, uint timeMs) nothrow @nogc
{
    wsi_callback_destroy(cb); // one-shot object
    g_frameCb = null;
    g_frames++;
    immutable now = instrNowUs();
    instrEvent("frame_callback", "t=%u", timeMs);

    if (!g_presented)
    {
        g_presented = true;
        g_firstCbArgMs = timeMs;
        instrFirstPixelPresented();
    }

    final switch (g_phase)
    {
    case Phase.measure:
        if (g_lastCbUs >= 0 && g_deltaCount < measuredFrames)
        {
            g_deltasUs[g_deltaCount] = now - g_lastCbUs;
            g_deltaCount++;
        }
        g_lastCbUs = now;
        g_lastCbArgMs = timeMs;
        if (g_deltaCount >= measuredFrames)
        {
            // Phase 1 complete → start the occlusion probe. Keep a frame
            // callback requested across the minimize so any tick the
            // compositor did deliver to a minimized surface would be seen.
            g_finalCbArgMs = timeMs;
            g_lastTickBeforeMinUs = now;
            g_phase = Phase.minimized;
            g_minimizeReqUs = now;
            wsi_toplevel_set_minimized(g_toplevel);
            requestFrameCallback();
            wsi_surface_commit(g_surface); // commit makes the frame request current
            instrEvent("vis_change", "state=minimized_requested");
        }
        else
            render();
        break;

    case Phase.minimized:
        // The probe's point: does this ever fire while minimized?
        g_cbWhileMinimized++;
        instrEvent("frame_callback_while_minimized", "t=%u n=%d", timeMs, g_cbWhileMinimized);
        requestFrameCallback();
        wsi_surface_commit(g_surface);
        break;

    case Phase.restoring:
        g_resumeCbUs = now;
        instrEvent("vis_change", "state=restored resume_after_us=%lld silence_us=%lld",
            now - g_restoreReqUs, now - g_lastTickBeforeMinUs);
        g_phase = Phase.done;
        g_running = false;
        break;

    case Phase.done:
        break;
    }
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

// ----------------------------------------------- poll-based event pump
// The libwayland prepare_read/read_events pattern (thread-safe variant of
// wl_display_dispatch) with a poll(2) timeout — the timeout is the
// *independent clock* that lets phase 2 measure a frame clock that has
// stopped without deadlocking on a callback that never comes.

/// Pump once: dispatch pending events, flush, wait up to `timeoutMs`.
/// Returns false on connection error.
bool pumpOnce(int timeoutMs) nothrow @nogc
{
    while (wl_display_prepare_read(g_display) != 0)
        if (wl_display_dispatch_pending(g_display) < 0)
            return false;
    wl_display_flush(g_display);

    pollfd pfd;
    pfd.fd = wl_display_get_fd(g_display);
    pfd.events = POLLIN;
    immutable r = poll(&pfd, 1, timeoutMs);
    if (r <= 0) // timeout (the independent clock ticked) or error
    {
        wl_display_cancel_read(g_display);
        return r == 0;
    }
    if (wl_display_read_events(g_display) < 0)
        return false;
    return wl_display_dispatch_pending(g_display) >= 0;
}

// ------------------------------------------------------------------ stats

extern (C) int cmpLong(const(void)* a, const(void)* b) nothrow @nogc
{
    immutable x = *cast(const(long)*) a;
    immutable y = *cast(const(long)*) b;
    return (x > y) - (x < y);
}

/// min/median/p99/max + 1 ms histogram over the recorded deltas, to stdout.
void printStats() nothrow @nogc
{
    if (g_deltaCount == 0)
    {
        printf("stats: no deltas recorded\n");
        return;
    }
    qsort(g_deltasUs.ptr, g_deltaCount, long.sizeof, &cmpLong);
    immutable long min = g_deltasUs[0];
    immutable long max = g_deltasUs[g_deltaCount - 1];
    immutable long median = g_deltasUs[g_deltaCount / 2];
    immutable size_t p99Idx = cast(size_t)(g_deltaCount - 1) * 99 / 100;
    immutable long p99 = g_deltasUs[p99Idx];
    printf("stats source=monotonic_us n=%d min_us=%lld median_us=%lld p99_us=%lld max_us=%lld\n",
        g_deltaCount, min, median, p99, max);
    // The callback's own ms-resolution argument, as a cross-check of the
    // measurement window: (last - first) / n ≈ the same mean period.
    printf("stats source=callback_arg_ms first=%u last=%u span_ms=%u mean_period_ms=%.3f\n",
        g_firstCbArgMs, g_finalCbArgMs, g_finalCbArgMs - g_firstCbArgMs,
        cast(double)(g_finalCbArgMs - g_firstCbArgMs) / g_deltaCount);

    int[histBuckets] hist;
    foreach (i; 0 .. g_deltaCount)
    {
        auto bucket = g_deltasUs[i] / 1000; // 1 ms buckets
        if (bucket >= histBuckets)
            bucket = histBuckets - 1;
        hist[cast(size_t) bucket]++;
    }
    foreach (i; 0 .. histBuckets)
        if (hist[i] != 0)
        {
            if (i == histBuckets - 1)
                printf("hist bucket_ms=%d+ count=%d\n", i, hist[i]);
            else
                printf("hist bucket_ms=%d-%d count=%d ", i, i + 1, hist[i]);
            if (i < histBuckets - 1)
            {
                foreach (_; 0 .. hist[i] / 10 + 1)
                    printf("#");
                printf("\n");
            }
        }
}

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
    instrInit("f04_wayland");
    // The pacing demo is meaningless without its bounded run; WSI_AUTO_EXIT
    // is accepted for runner symmetry but the demo always auto-terminates.
    cast(void) getenv("WSI_AUTO_EXIT");

    // 1. Connect (SKIP cleanly on headless hosts without a compositor).
    g_display = wl_display_connect(null);
    if (g_display is null)
    {
        printf("SKIP: no Wayland compositor (wl_display_connect returned null)\n");
        return 0;
    }

    // 2. Registry: dump every global (the wp_presentation question) and bind
    //    the ones a window needs.
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
    wsi_toplevel_set_title(g_toplevel, "wsi-f04-frame-pacing");
    wsi_toplevel_set_app_id(g_toplevel, "wsi-f04-frame-pacing");
    instrWindowCreated();

    // 4. The mandatory initial no-buffer commit; first pixel happens in the
    //    configure handler.
    wsi_surface_commit(g_surface);

    // 5. Poll-pumped event loop. The poll timeout is the independent clock:
    //    when the frame clock stops (phase 2), the loop still ticks every
    //    pollTimeoutMs and the wall-clock checks below run.
    while (g_running)
    {
        if (!pumpOnce(pollTimeoutMs))
            break;
        immutable now = instrNowUs();

        if (g_phase == Phase.minimized && now - g_minimizeReqUs >= minimizedProbeUs)
        {
            // ~3 s of silence measured — restore. xdg-shell has no
            // unset_minimized; un-minimizing is the compositor's (user's)
            // call. set_maximized + a fresh attach/commit is the strongest
            // client-side "make me visible again" available.
            g_phase = Phase.restoring;
            g_restoreReqUs = now;
            instrEvent("vis_change",
                "state=restore_requested minimized_for_us=%lld cb_while_minimized=%d",
                now - g_minimizeReqUs, g_cbWhileMinimized);
            wsi_toplevel_set_maximized(g_toplevel);
            render(); // fresh attach + damage + frame request + commit
        }
        else if (g_phase == Phase.restoring && now - g_restoreReqUs >= restoreTimeoutUs)
        {
            instrEvent("vis_change", "state=restore_timeout silence_us=%lld",
                now - g_lastTickBeforeMinUs);
            g_running = false;
        }

        if (now > hardCapUs)
        {
            instrEvent("hard_cap_hit");
            g_running = false;
        }
    }

    // 6. Teardown + the numbers.
    teardown();
    printStats();
    printf("occlusion: minimized_for_us=%lld frame_callbacks_while_minimized=%d ",
        g_restoreReqUs >= 0 ? g_restoreReqUs - g_minimizeReqUs : -1, g_cbWhileMinimized);
    if (g_resumeCbUs >= 0)
        printf("resumed_after_restore_us=%lld total_silence_us=%lld\n",
            g_resumeCbUs - g_restoreReqUs, g_resumeCbUs - g_lastTickBeforeMinUs);
    else
        printf("resume=NEVER\n");
    printf("wp_presentation advertised: %s\n", g_sawPresentation ? "yes".ptr : "no".ptr);
    printf("ok: %d frame callbacks, %d commits, %d measured deltas\n",
        g_frames, g_commits, g_deltaCount);
    return g_deltaCount == measuredFrames ? 0 : 1;
}
