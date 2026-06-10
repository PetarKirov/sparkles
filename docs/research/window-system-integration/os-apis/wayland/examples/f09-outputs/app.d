// F09 output enumeration & hotplug demo — what a Wayland window can know
// about the displays it lives on, on top of the xdg-shell scaffold
// (../scaffold/app.d; findings: ../../scaffold.md, ../../f09-outputs.md).
//
//   - Binds EVERY wl_output global at v4 (geometry/mode/scale + the v4
//     name/description events), logging one `output id=… geom=… scale=…
//     refresh=…` line per atomic `wl_output.done` batch.
//   - Binds zxdg_output_manager_v1 when offered and attaches a
//     zxdg_output_v1 to each output: the *logical* position/size (the
//     compositor-space rectangle after scaling/transform) vs wl_output's
//     physical mode — the logical-vs-physical split is the deliverable.
//   - Tracks surface↔output occupancy via wl_surface.enter/leave (Wayland is
//     the only platform that tells the surface directly) and logs
//     `surface_output enter|leave id=…` plus a running occupancy count.
//   - Handles hotplug: wl_registry.global → `output_added`,
//     wl_registry.global_remove → `output_removed` + zxdg_output_v1.destroy +
//     wl_output.release (v3+) — including the window's *current* output
//     vanishing mid-run (./run.sh choreographs that with swaymsg).
//
// Env knobs: WSI_AUTO_EXIT=1 + WSI_RUN_MS=<ms> bound the run. Headless-safe:
// no compositor → SKIP, exit 0.
module app;

import c; // ImportC: wayland-client + xdg-shell/xdg-output glue
import instrument;
import core.stdc.stdio : printf, snprintf;
import core.stdc.stdlib : atoi, getenv;
import core.stdc.string : strcmp;

enum int defaultWidth = 640;
enum int defaultHeight = 480;
enum int maxOutputs = 8;

// -------------------------------------------------------------------- state

/// Everything one wl_output global tells us, physical (wl_output) and
/// logical (zxdg_output_v1) halves side by side. Events accumulate into the
/// slot; `wl_output.done` makes the batch atomic and triggers the log line.
struct Output
{
    bool used;
    uint globalName; // the registry name — the hotplug identity
    wl_output* output;
    zxdg_output_v1* xdgOutput;
    // wl_output (physical) state
    int x, y; // geometry position, "within the global compositor space"
    int physMmW, physMmH; // physical size in millimetres
    int modeW, modeH, refreshMHz; // current mode, *buffer* pixels
    int scale = 1;
    char[64] name = '\0'; // v4 wl_output.name (e.g. HEADLESS-1)
    char[128] description = '\0';
    // zxdg_output_v1 (logical) state
    int logX, logY, logW, logH;
    bool haveLogical;
    bool announced; // first done already logged as part of output_added
    bool occupied; // surface currently on this output (enter/leave)
}

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
    zxdg_output_manager_v1* g_xdgOutMgr;
    wl_surface* g_surface;
    xdg_surface* g_xdgSurface;
    xdg_toplevel* g_toplevel;
    wl_callback* g_frameCb;

    Output[maxOutputs] g_outputs;
    Buffer[2] g_buffers;
    int g_width = defaultWidth, g_height = defaultHeight;
    int g_pendingWidth, g_pendingHeight;
    bool g_configured, g_running = true, g_autoExit, g_initialEnumDone;
    long g_runUsCap = 2_500_000;
    int g_frames, g_commits;
}

Output* slotByOutput(wl_output* o) nothrow @nogc
{
    foreach (ref s; g_outputs)
        if (s.used && s.output is o)
            return &s;
    return null;
}

int occupancyCount() nothrow @nogc
{
    int n;
    foreach (ref s; g_outputs)
        n += s.used && s.occupied;
    return n;
}

/// The per-enumeration line the F09 spec asks for, plus the logical rectangle
/// when xdg-output supplied one — the physical/logical split on one screen.
void logOutput(ref Output s) nothrow @nogc
{
    instrEvent("output", "id=%u name=%s geom=%dx%d+%d+%d scale=%d refresh_mhz=%d physical_mm=%dx%d",
        s.globalName, s.name.ptr, s.modeW, s.modeH, s.x, s.y, s.scale,
        s.refreshMHz, s.physMmW, s.physMmH);
    if (s.haveLogical)
        instrEvent("output_logical", "id=%u pos=%d,%d size=%dx%d (zxdg_output_v1)",
            s.globalName, s.logX, s.logY, s.logW, s.logH);
}

// --------------------------------------------------- wl_output / xdg_output

extern (C) void onOutputGeometry(void* data, wl_output* o, int x, int y, int physW,
    int physH, int subpixel, const(char)* make, const(char)* model, int transform) nothrow @nogc
{
    auto s = cast(Output*) data;
    s.x = x;
    s.y = y;
    s.physMmW = physW;
    s.physMmH = physH;
}

extern (C) void onOutputMode(void* data, wl_output* o, uint flags, int w, int h, int refresh) nothrow @nogc
{
    auto s = cast(Output*) data;
    if (flags & WL_OUTPUT_MODE_CURRENT)
    {
        s.modeW = w;
        s.modeH = h;
        s.refreshMHz = refresh;
    }
}

extern (C) void onOutputScale(void* data, wl_output* o, int factor) nothrow @nogc
{
    (cast(Output*) data).scale = factor;
}

extern (C) void onOutputName(void* data, wl_output* o, const(char)* name) nothrow @nogc
{
    auto s = cast(Output*) data;
    snprintf(s.name.ptr, s.name.length, "%s", name);
}

extern (C) void onOutputDescription(void* data, wl_output* o, const(char)* desc) nothrow @nogc
{
    auto s = cast(Output*) data;
    snprintf(s.description.ptr, s.description.length, "%s", desc);
}

extern (C) void onOutputDone(void* data, wl_output* o) nothrow @nogc
{
    auto s = cast(Output*) data;
    if (!s.announced)
    {
        s.announced = true;
        // Initial enumeration vs runtime hotplug, distinguished by whether the
        // first registry roundtrip has completed yet.
        instrEvent(g_initialEnumDone ? "output_added" : "output_enumerated",
            "id=%u name=%s", s.globalName, s.name.ptr);
    }
    logOutput(*s);
}

extern (C) void onXdgOutLogicalPos(void* data, zxdg_output_v1* xo, int x, int y) nothrow @nogc
{
    auto s = cast(Output*) data;
    s.logX = x;
    s.logY = y;
    s.haveLogical = true;
}

extern (C) void onXdgOutLogicalSize(void* data, zxdg_output_v1* xo, int w, int h) nothrow @nogc
{
    auto s = cast(Output*) data;
    s.logW = w;
    s.logH = h;
    s.haveLogical = true;
}

extern (C) void onXdgOutDone(void* data, zxdg_output_v1* xo) nothrow @nogc
{
    // Only sent when bound below v3 (weston offers v2); at v3+ the protocol
    // deprecates it and latches logical updates to wl_output.done instead.
    auto s = cast(Output*) data;
    instrEvent("output_logical", "id=%u pos=%d,%d size=%dx%d (zxdg_output_v1 v2 done)",
        s.globalName, s.logX, s.logY, s.logW, s.logH);
}

extern (C) void onXdgOutName(void* data, zxdg_output_v1* xo, const(char)* name) nothrow @nogc
{
}

extern (C) void onXdgOutDescription(void* data, zxdg_output_v1* xo, const(char)* d) nothrow @nogc
{
}

__gshared wl_output_listener g_outputListener = {
    &onOutputGeometry, &onOutputMode, &onOutputDone, &onOutputScale,
    &onOutputName, &onOutputDescription
};
__gshared zxdg_output_v1_listener g_xdgOutputListener = {
    &onXdgOutLogicalPos, &onXdgOutLogicalSize, &onXdgOutDone,
    &onXdgOutName, &onXdgOutDescription
};

void attachXdgOutput(ref Output s) nothrow @nogc
{
    if (g_xdgOutMgr is null || s.xdgOutput !is null)
        return;
    s.xdgOutput = wsi_xdg_output_manager_get_xdg_output(g_xdgOutMgr, s.output);
    wsi_xdg_output_add_listener(s.xdgOutput, &g_xdgOutputListener, &s);
}

// ------------------------------------------------------- surface enter/leave

extern (C) void onSurfaceEnter(void* data, wl_surface* surf, wl_output* o) nothrow @nogc
{
    auto s = slotByOutput(o);
    if (s !is null)
    {
        s.occupied = true;
        instrEvent("surface_output", "enter id=%u name=%s", s.globalName, s.name.ptr);
    }
    else // an output this client never bound (or already released)
        instrEvent("surface_output", "enter id=? (unknown wl_output proxy)");
    instrEvent("occupancy", "count=%d", occupancyCount());
}

extern (C) void onSurfaceLeave(void* data, wl_surface* surf, wl_output* o) nothrow @nogc
{
    auto s = slotByOutput(o);
    if (s !is null)
    {
        s.occupied = false;
        instrEvent("surface_output", "leave id=%u name=%s", s.globalName, s.name.ptr);
    }
    else
        instrEvent("surface_output", "leave id=? (unknown wl_output proxy)");
    instrEvent("occupancy", "count=%d", occupancyCount());
}

extern (C) void onPreferredBufferScale(void* data, wl_surface* s, int factor) nothrow @nogc
{
}

extern (C) void onPreferredBufferTransform(void* data, wl_surface* s, uint t) nothrow @nogc
{
}

// ------------------------------------------------------------------ registry

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
    else if (strcmp(iface, zxdg_output_manager_v1_interface.name) == 0)
    {
        g_xdgOutMgr = cast(zxdg_output_manager_v1*) wsi_registry_bind(reg, name,
            &zxdg_output_manager_v1_interface, capped(ver, 3));
        instrEvent("xdg_output_manager", "version=%u (logical geometry available)", ver);
    }
    else if (strcmp(iface, wl_output_interface.name) == 0)
    {
        foreach (ref s; g_outputs)
            if (!s.used)
            {
                s = Output.init;
                s.used = true;
                s.globalName = name;
                // v4 = name/description events; release (the destroy request)
                // needs only v3.
                s.output = cast(wl_output*) wsi_registry_bind(reg, name,
                    &wl_output_interface, capped(ver, 4));
                wsi_output_add_listener(s.output, &g_outputListener, &s);
                attachXdgOutput(s);
                return;
            }
        instrEvent("output_ignored", "id=%u (more than %d outputs)", name, maxOutputs);
    }
}

extern (C) void onGlobalRemove(void* data, wl_registry* reg, uint name) nothrow @nogc
{
    foreach (ref s; g_outputs)
        if (s.used && s.globalName == name)
        {
            instrEvent("output_removed", "id=%u name=%s occupied=%d",
                name, s.name.ptr, s.occupied ? 1 : 0);
            // The destroyed-global contract: the server already destroyed the
            // global; the client must drop its proxies. zxdg_output_v1 first
            // (child), then wl_output.release (v3+).
            if (s.xdgOutput !is null)
                wsi_xdg_output_destroy(s.xdgOutput);
            wsi_output_release(s.output);
            s = Output.init;
            instrEvent("occupancy", "count=%d", occupancyCount());
            return;
        }
}

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
    immutable fd = memfd_create("wsi-f09", MFD_CLOEXEC);
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
        return; // recovered by the wl_buffer.release handler
    if (!ensureBuffer(*buf, g_width, g_height))
        return;
    foreach (y; 0 .. buf.height) // simple gradient; pixels are not the point here
        foreach (x; 0 .. buf.width)
            buf.pixels[cast(size_t) y * buf.width + x] =
                0xff000000 | ((x * 255 / buf.width) << 16) | ((y * 255 / buf.height) << 8);
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
        render();
    }
    else if (resized)
    {
        instrResize(w, h, 1);
        render();
    }
}

extern (C) void onToplevelClose(void* data, xdg_toplevel* t) nothrow @nogc
{
    instrCloseRequested();
    g_running = false;
}

extern (C) void onToplevelConfigureBounds(void* data, xdg_toplevel* t, int w, int h) nothrow @nogc
{
}

extern (C) void onToplevelWmCapabilities(void* data, xdg_toplevel* t, wl_array* caps) nothrow @nogc
{
}

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
__gshared xdg_wm_base_listener g_wmBaseListener = {&onWmBasePing};
__gshared wl_surface_listener g_surfaceListener = {
    &onSurfaceEnter, &onSurfaceLeave, &onPreferredBufferScale, &onPreferredBufferTransform
};
__gshared xdg_surface_listener g_xdgSurfaceListener = {&onXdgSurfaceConfigure};
__gshared xdg_toplevel_listener g_toplevelListener = {
    &onToplevelConfigure, &onToplevelClose,
    &onToplevelConfigureBounds, &onToplevelWmCapabilities
};
__gshared wl_buffer_listener g_bufferListener = {&onBufferRelease};
__gshared wl_callback_listener g_frameListener = {&onFrameDone};

// --------------------------------------------------------------------- main

int main()
{
    instrInit("f09_wayland");
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
    // Roundtrip 1: globals (outputs bound, xdg_outputs attached where the
    // manager arrived before the outputs). Roundtrip 2: the per-output event
    // batches — enumeration needs a connection but NO window.
    wl_display_roundtrip(g_display);
    foreach (ref s; g_outputs) // manager may have arrived after the outputs
        if (s.used)
            attachXdgOutput(s);
    wl_display_roundtrip(g_display);
    g_initialEnumDone = true;
    {
        int n;
        foreach (ref s; g_outputs)
            n += s.used;
        instrEvent("enumeration_done", "outputs=%d xdg_output_manager=%d",
            n, g_xdgOutMgr !is null ? 1 : 0);
    }
    if (g_compositor is null || g_shm is null || g_wmBase is null)
    {
        printf("SKIP: compositor lacks a required global\n");
        wl_display_disconnect(g_display);
        return 0;
    }

    wsi_wm_base_add_listener(g_wmBase, &g_wmBaseListener, null);
    g_surface = wsi_compositor_create_surface(g_compositor);
    wsi_surface_add_listener(g_surface, &g_surfaceListener, null);
    g_xdgSurface = wsi_wm_base_get_xdg_surface(g_wmBase, g_surface);
    wsi_xdg_surface_add_listener(g_xdgSurface, &g_xdgSurfaceListener, null);
    g_toplevel = wsi_xdg_surface_get_toplevel(g_xdgSurface);
    wsi_toplevel_add_listener(g_toplevel, &g_toplevelListener, null);
    wsi_toplevel_set_title(g_toplevel, "wsi-f09-outputs");
    wsi_toplevel_set_app_id(g_toplevel, "wsi-f09-outputs");
    instrWindowCreated();
    wsi_surface_commit(g_surface); // mandatory no-buffer first commit

    // Poll-based pump (the F04 lesson) so the wall-clock auto-exit stays live
    // even when the compositor throttles frame callbacks.
    immutable dispFd = wl_display_get_fd(g_display);
    while (g_running)
    {
        while (wl_display_prepare_read(g_display) != 0)
            wl_display_dispatch_pending(g_display);
        wl_display_flush(g_display);
        pollfd pfd = {dispFd, POLLIN, 0};
        if (poll(&pfd, 1, 100) > 0)
            wl_display_read_events(g_display);
        else
            wl_display_cancel_read(g_display);
        if (wl_display_dispatch_pending(g_display) == -1)
            break;
        if (g_autoExit && instrNowUs() > g_runUsCap)
            g_running = false;
    }

    // Teardown: children before parents.
    foreach (ref b; g_buffers)
        if (b.handle !is null)
        {
            wsi_buffer_destroy(b.handle);
            munmap(b.pixels, b.byteSize);
        }
    if (g_frameCb !is null)
        wsi_callback_destroy(g_frameCb);
    wsi_toplevel_destroy(g_toplevel);
    wsi_xdg_surface_destroy(g_xdgSurface);
    wsi_surface_destroy(g_surface);
    wsi_wm_base_destroy(g_wmBase);
    foreach (ref s; g_outputs)
        if (s.used)
        {
            if (s.xdgOutput !is null)
                wsi_xdg_output_destroy(s.xdgOutput);
            wsi_output_release(s.output);
        }
    if (g_xdgOutMgr !is null)
        wsi_xdg_output_manager_destroy(g_xdgOutMgr);
    wl_proxy_destroy(cast(wl_proxy*) g_shm);
    wl_proxy_destroy(cast(wl_proxy*) g_compositor);
    wl_proxy_destroy(cast(wl_proxy*) g_registry);
    wl_display_disconnect(g_display);

    int finalOutputs;
    foreach (ref s; g_outputs)
        finalOutputs += s.used;
    printf("ok: frames=%d commits=%d outputs_final=%d\n",
        g_frames, g_commits, finalOutputs);
    return 0;
}
