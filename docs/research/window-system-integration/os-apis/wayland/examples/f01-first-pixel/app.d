// F01 — first pixel & init cost (Wayland). Implements
// ../../../features/f01-first-pixel.md on top of the proven xdg-shell
// scaffold (../scaffold/app.d, findings in ../../scaffold.md):
//
//   wl_display → wl_registry → bind {wl_compositor, wl_shm, xdg_wm_base}
//   → wl_surface → xdg_surface → xdg_toplevel → initial *no-buffer* commit
//   → xdg_surface.configure → ack_configure → wl_shm ARGB gradient
//   → wl_surface.attach/damage_buffer/commit → first wl_surface.frame
//   callback = first pixel CONFIRMED.
//
// What F01 adds over the scaffold:
//   - one `step name=<api-call>` instrumentation event per init API call,
//     with `rt=1` on the two calls that block on the compositor
//     (wl_display_roundtrip, and the wl_display_dispatch that waits for the
//     first configure after the no-buffer commit);
//   - a `concept n=<i> name=<object-type>` event at the first touch of each
//     distinct protocol object type, and a `summary concepts=N loc=N` line;
//   - LOC is computed at compile time from this very file (string import),
//     so the number can never go stale; instrument.d and the c.c shim are
//     excluded per the spec;
//   - the demo presents exactly one confirmed frame, holds a few frame
//     callbacks to prove the loop is live, prints the F01 checklist to
//     stdout, and exits 0 (Tier-A runnable; no resize storm — that is F02).
//
// "Presented" means what Wayland can actually confirm: the first `done`
// event on a wl_surface.frame callback requested with the first post-ack
// buffer commit. Headless-safe: no compositor → SKIP, exit 0.
module app;

import c; // ImportC: <wayland-client.h> + xdg-shell glue + wsi_* wrappers
import instrument;
import core.stdc.stdio : printf;
import core.stdc.string : strcmp;

// ----------------------------------------------------------------- tunables

enum int defaultWidth = 640; // used while the compositor lets us pick (0x0 configure)
enum int defaultHeight = 480;
enum int holdFrames = 10; // frame callbacks to observe after first_pixel_presented
enum long hardStopUs = 5_000_000; // wall-clock backstop if the frame clock stalls

// ----------------------------------------------- compile-time LOC (F01 §5)

private struct Loc
{
    int total;
    int code; // non-blank, non-`//` lines
}

private Loc countLoc()(string src)
{
    Loc r;
    size_t i = 0;
    while (i < src.length)
    {
        size_t j = i;
        while (j < src.length && src[j] != '\n')
            ++j;
        auto line = src[i .. j];
        size_t k = 0;
        while (k < line.length && (line[k] == ' ' || line[k] == '\t'))
            ++k;
        line = line[k .. $];
        r.total++;
        if (line.length > 0 && !(line.length >= 2 && line[0] == '/' && line[1] == '/'))
            r.code++;
        i = j + 1;
    }
    return r;
}

/// LOC of this demo, excluding `instrument.d` and the `c.c` shim (the spec's
/// definition). CTFE over the string import keeps it accurate by construction.
enum Loc demoLoc = countLoc(import("app.d"));

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
    int g_frames; // frame callbacks received
    int g_commits; // buffer commits sent

    // F01 counters, all frozen at first_pixel_presented:
    int g_concepts; // distinct protocol object types touched
    int g_initSteps; // `step` events emitted
    int g_roundTrips; // steps that blocked on the compositor (rt=1)
    long g_firstPixelUs = -1; // init_start → first_pixel_presented
}

// ------------------------------------------------------ F01 instrumentation

// The counters freeze at first_pixel_presented: later events still log, but
// only pre-presentation work counts as "init" (F01 measures init cost only).

/// First touch of a distinct protocol object type (F01 §4 "concepts").
void logConcept(const(char)* name) nothrow @nogc
{
    if (g_presented)
        return;
    g_concepts++;
    instrEvent("concept", "n=%d name=%s", g_concepts, name);
}

/// An init API call that completed locally (no compositor wait).
void step(const(char)* api) nothrow @nogc
{
    if (!g_presented)
        g_initSteps++;
    instrStep(api);
}

/// An init API call that *blocked* on the compositor (F01: round-trip).
void stepRoundTrip(const(char)* api) nothrow @nogc
{
    if (!g_presented)
    {
        g_initSteps++;
        g_roundTrips++;
    }
    instrEvent("step", "name=%s rt=1", api);
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
    immutable fd = memfd_create("wsi-f01", MFD_CLOEXEC);
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
    step("memfd_create+mmap");

    // The pool can be destroyed right after create_buffer: the buffer keeps
    // the backing memory alive, and the compositor has dup'ed the fd.
    wl_shm_pool* pool = wsi_shm_create_pool(g_shm, fd, cast(int) size);
    if (g_commits == 0)
        logConcept("wl_shm_pool");
    step("wl_shm_create_pool");
    b.handle = wsi_shm_pool_create_buffer(pool, 0, w, h, stride, WL_SHM_FORMAT_ARGB8888);
    if (g_commits == 0)
        logConcept("wl_buffer");
    step("wl_shm_pool_create_buffer");
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

/// Corner-anchored diagonal gradient with a frame-driven blue channel so each
/// redraw is observable in a screen capture.
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

    assert(buf.width == g_width && buf.height == g_height,
        "committed buffer size does not match the acked configure size");

    immutable firstCommit = g_commits == 0;
    wsi_surface_attach(g_surface, buf.handle, 0, 0);
    if (firstCommit)
        step("wl_surface_attach");
    wsi_surface_damage_buffer(g_surface, 0, 0, buf.width, buf.height);
    if (firstCommit)
        step("wl_surface_damage_buffer");
    if (g_frameCb is null) // keep exactly one frame callback in flight
    {
        g_frameCb = wsi_surface_frame(g_surface);
        if (firstCommit)
            step("wl_surface_frame");
        wsi_callback_add_listener(g_frameCb, &g_frameListener, null);
    }
    wsi_surface_commit(g_surface);
    if (firstCommit)
        step("wl_surface_commit(buffer)");
    buf.busy = true;
    g_commits++;
    if (firstCommit)
        instrEvent("first_commit", "size=%dx%d", buf.width, buf.height);
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
            capped(ver, 2)); // v2: name event (headless weston has no seat at all)
    else
        return;
    logConcept(iface);
    instrEvent("step", "name=wl_registry_bind iface=%s version=%u", iface, ver);
    g_initSteps++;
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
/// pick"). Only latched here; it takes effect at xdg_surface.configure.
extern (C) void onToplevelConfigure(void* data, xdg_toplevel* t, int w, int h,
    wl_array* states) nothrow @nogc
{
    g_pendingWidth = w;
    g_pendingHeight = h;
    instrEvent("xdg_toplevel_configure", "size=%dx%d", w, h);
}

/// xdg_surface.configure: the atomic "apply everything" event. ack_configure
/// (with the event's serial) goes out *before* the buffer commit.
extern (C) void onXdgSurfaceConfigure(void* data, xdg_surface* s, uint serial) nothrow @nogc
{
    immutable w = g_pendingWidth > 0 ? g_pendingWidth : defaultWidth;
    immutable h = g_pendingHeight > 0 ? g_pendingHeight : defaultHeight;
    instrEvent("configure", "serial=%u size=%dx%d", serial, w, h);

    wsi_xdg_surface_ack_configure(s, serial);
    step("xdg_surface_ack_configure");

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
    if (g_running && g_configured && g_frameCb is null)
        render();
}

/// wl_surface.frame `done`: the compositor presented the surface — this is
/// the only confirmation Wayland gives that the pixels reached the screen.
extern (C) void onFrameDone(void* data, wl_callback* cb, uint timeMs) nothrow @nogc
{
    wsi_callback_destroy(cb); // one-shot object
    g_frameCb = null;
    g_frames++;
    instrFrameCallback(timeMs);

    if (!g_presented)
    {
        g_presented = true;
        g_firstPixelUs = instrNowUs();
        // First pixel confirmed: a post-ack buffer commit has been presented.
        instrFirstPixelPresented();
        instrEvent("summary",
            "concepts=%d loc=%d loc_code=%d steps=%d roundtrips=%d first_pixel_us=%lld",
            g_concepts, demoLoc.total, demoLoc.code, g_initSteps, g_roundTrips, g_firstPixelUs);
    }

    // Hold a few more frames to prove the redraw loop is live, then exit
    // (F01 §1: exit cleanly shortly after presentation is confirmed).
    if (g_frames >= 1 + holdFrames)
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

int main()
{
    instrInit("f01-wayland");

    // 1. Connect (SKIP cleanly on headless hosts without a compositor).
    g_display = wl_display_connect(null);
    if (g_display is null)
    {
        printf("SKIP: no Wayland compositor (wl_display_connect returned null)\n");
        return 0;
    }
    logConcept("wl_display");
    step("wl_display_connect");

    // 2. Registry: discover and bind the globals a window needs. The
    //    roundtrip is the first of the two compositor waits (rt=1) — it
    //    internally creates a wl_callback via wl_display.sync.
    g_registry = wsi_display_get_registry(g_display);
    logConcept("wl_registry");
    step("wl_display_get_registry");
    wsi_registry_add_listener(g_registry, &g_registryListener, null);
    logConcept("wl_callback"); // first touch: wl_display_roundtrip's internal sync
    wl_display_roundtrip(g_display); // blocks; onGlobal binds during this
    stepRoundTrip("wl_display_roundtrip");

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
    logConcept("wl_surface");
    step("wl_compositor_create_surface");
    g_xdgSurface = wsi_wm_base_get_xdg_surface(g_wmBase, g_surface);
    logConcept("xdg_surface");
    step("xdg_wm_base_get_xdg_surface");
    wsi_xdg_surface_add_listener(g_xdgSurface, &g_xdgSurfaceListener, null);
    g_toplevel = wsi_xdg_surface_get_toplevel(g_xdgSurface);
    logConcept("xdg_toplevel");
    step("xdg_surface_get_toplevel");
    wsi_toplevel_add_listener(g_toplevel, &g_toplevelListener, null);
    wsi_toplevel_set_title(g_toplevel, "wsi-f01-first-pixel");
    step("xdg_toplevel_set_title");
    wsi_toplevel_set_app_id(g_toplevel, "wsi-f01-first-pixel");
    step("xdg_toplevel_set_app_id");
    instrWindowCreated();

    // 4. The mandatory initial commit *without* a buffer (attaching one before
    //    the first configure is a protocol error). The compositor answers with
    //    the first xdg_surface.configure; the first pixel happens in its handler.
    wsi_surface_commit(g_surface);
    step("wl_surface_commit(no-buffer)");

    // 5. Block until the first configure arrives — the second compositor wait
    //    (rt=1). The configure handler acks and commits the first buffer, so
    //    by the time this step line is emitted the first frame is in flight.
    while (g_running && !g_configured && wl_display_dispatch(g_display) != -1)
    {
    }
    stepRoundTrip("wl_display_dispatch(first_configure)");

    // 6. Event loop until the post-presentation hold expires.
    while (g_running && wl_display_dispatch(g_display) != -1)
    {
        if (instrNowUs() > hardStopUs)
            g_running = false; // backstop if the frame clock ever stalls
    }

    // 7. Clean teardown: buffers → frame callback → role objects → surface →
    //    globals → registry → disconnect (children before parents).
    teardown();

    // F01 checklist (spec: features/f01-first-pixel.md § Findings to record).
    immutable presented = g_presented ? 'x' : ' ';
    printf("F01 checklist (wayland):\n");
    printf("  [%c] one frame presented, confirmed by wl_surface.frame callback\n", presented);
    printf("  [x] init steps logged: %d (round-trips rt=1: %d)\n", g_initSteps, g_roundTrips);
    printf("  [x] concepts to first pixel: %d\n", g_concepts);
    printf("  [x] loc: %d total, %d code (instrument.d and c.c excluded)\n",
        demoLoc.total, demoLoc.code);
    printf("  [%c] init_start -> first_pixel_presented: %lld us\n", presented, g_firstPixelUs);
    printf("  [x] held %d extra frames, clean teardown, exit 0\n", g_frames - 1);
    printf("ok: presented %d frames in %d commits, final size %dx%d\n",
        g_frames, g_commits, g_width, g_height);
    return g_presented ? 0 : 1;
}
