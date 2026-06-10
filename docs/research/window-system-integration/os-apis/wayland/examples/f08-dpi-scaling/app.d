// F08 DPI / runtime-rescale demo — both Wayland scale paths in one binary,
// runtime-selected by the advertised globals, on top of the xdg-shell scaffold
// (../scaffold/app.d; findings: ../../scaffold.md, ../../f08-dpi-scaling.md).
//
//   (a) fractional path — wp_fractional_scale_v1.preferred_scale (units of
//       1/120) + wp_viewport.set_destination(logical size), buffer allocated
//       at physical size, wl_surface buffer scale left at 1. Buffer-size math
//       follows the fractional-scale-v1 XML: "the size is rounded halfway
//       away from zero" (round half up for positive sizes) — asserted at
//       compile time AND on every commit.
//   (b) integer path — wl_surface.set_buffer_scale driven by
//       wl_surface.preferred_buffer_scale (wl_compositor v6+), falling back
//       to wl_output.scale via wl_surface.enter for older compositors.
//
// Every change logs `scale_changed scale120=N scale=X.XXX path=…` plus
// `commit_info logical=WxH buffer=WxH …`, and the *first* commit logs the
// scale the surface believed before any compositor event arrived — the
// "created at the wrong scale, then rescaled" evidence. The frame is a
// checkerboard with 1-physical-px hairlines on all four buffer edges, so a
// scaling/filtering artifact is immediately visible in a screenshot.
//
// Env knobs: WSI_FORCE_PATH=fractional|buffer_scale overrides the selection;
// WSI_AUTO_EXIT=1 + WSI_RUN_MS=<ms> bound the run (./run.sh drives live
// `swaymsg output … scale` changes against it). Headless-safe: no compositor
// → SKIP, exit 0.
module app;

import c; // ImportC: wayland-client + xdg-shell/viewporter/fractional-scale glue
import instrument;
import core.stdc.stdio : printf;
import core.stdc.stdlib : atoi, getenv;
import core.stdc.string : strcmp;

// ----------------------------------------------------------------- tunables

enum int defaultWidth = 640;
enum int defaultHeight = 480;
enum int checkerPx = 16; // checkerboard cell, *physical* pixels

/// fractional-scale-v1 buffer math: logical size × (scale120/120), "rounded
/// halfway away from zero" (the protocol XML's words; sizes are positive, so
/// this is round half up).
int physSize(int logical, uint scale120) pure nothrow @nogc @safe
{
    return cast(int)((cast(long) logical * scale120 + 60) / 120);
}

static assert(physSize(640, 120) == 640); // 1.0  → identity
static assert(physSize(640, 180) == 960); // 1.5  → exact
static assert(physSize(101, 180) == 152); // 151.5 rounds *up* (away from zero)
static assert(physSize(33, 150) == 41); //  41.25 rounds down
static assert(physSize(640, 150) == 800); // 1.25 → exact

// -------------------------------------------------------------------- state

struct Buffer
{
    wl_buffer* handle;
    uint* pixels;
    size_t byteSize;
    int width, height;
    bool busy;
}

enum Path
{
    bufferScale, // wl_surface.set_buffer_scale (integer)
    fractional, // wp_fractional_scale_v1 + wp_viewport
}

__gshared
{
    wl_display* g_display;
    wl_registry* g_registry;
    wl_compositor* g_compositor;
    uint g_compositorVersion;
    wl_shm* g_shm;
    wl_output* g_output; // first advertised output (enough for headless runs)
    xdg_wm_base* g_wmBase;
    wl_surface* g_surface;
    xdg_surface* g_xdgSurface;
    xdg_toplevel* g_toplevel;
    wl_callback* g_frameCb;
    wp_viewporter* g_viewporter;
    wp_viewport* g_viewport;
    wp_fractional_scale_manager_v1* g_fracManager;
    wp_fractional_scale_v1* g_fracScale;

    Buffer[2] g_buffers;
    Path g_path;
    int g_logicalW = defaultWidth, g_logicalH = defaultHeight; // last acked
    int g_pendingWidth, g_pendingHeight;
    uint g_scale120 = 120; // current scale in 1/120ths (both paths normalize here)
    int g_outputScale = 1; // last wl_output.scale (the v5-and-older fallback)
    bool g_configured, g_running = true, g_autoExit, g_firstCommitDone;
    long g_runUsCap = 2_500_000;
    int g_frames, g_commits;
}

const(char)* pathName() nothrow @nogc
{
    return g_path == Path.fractional ? "fractional".ptr : "buffer_scale".ptr;
}

/// Log `scale_changed` in the canonical format (scale as a decimal, plus the
/// raw 120ths so fractional values stay exact).
void logScaleChanged() nothrow @nogc
{
    instrEvent("scale_changed", "scale120=%u scale=%u.%03u path=%s",
        g_scale120, g_scale120 / 120, (g_scale120 % 120) * 1000 / 120, pathName());
}

void bufferDims(out int w, out int h) nothrow @nogc
{
    if (g_path == Path.fractional)
    {
        w = physSize(g_logicalW, g_scale120);
        h = physSize(g_logicalH, g_scale120);
    }
    else
    {
        immutable s = cast(int) g_scale120 / 120;
        w = g_logicalW * s;
        h = g_logicalH * s;
    }
}

// ------------------------------------------------------------ shm + drawing

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
    immutable fd = memfd_create("wsi-f08", MFD_CLOEXEC);
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
    instrEvent("buffer_alloc", "size=%dx%d bytes=%zu", w, h, size);
    return true;
}

/// Checkerboard at physical resolution + 1-physical-px hairlines on all four
/// buffer edges. If the compositor resamples (wrong buffer size for the
/// scale), the hairlines blur or vanish — the artifact detector.
void paint(ref Buffer b) nothrow @nogc
{
    foreach (y; 0 .. b.height)
    {
        uint* row = b.pixels + cast(size_t) y * b.width;
        foreach (x; 0 .. b.width)
            row[x] = ((x / checkerPx + y / checkerPx) & 1) ? 0xff707070 : 0xff383838;
    }
    foreach (x; 0 .. b.width) // top/bottom hairlines, exactly 1 physical px
    {
        b.pixels[x] = 0xffffffff;
        b.pixels[cast(size_t)(b.height - 1) * b.width + x] = 0xffff2020;
    }
    foreach (y; 0 .. b.height) // left/right hairlines
    {
        b.pixels[cast(size_t) y * b.width] = 0xff20ff20;
        b.pixels[cast(size_t) y * b.width + b.width - 1] = 0xff40a0ff;
    }
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
    int bw, bh;
    bufferDims(bw, bh);
    if (!ensureBuffer(*buf, bw, bh))
        return;
    paint(*buf);

    // The committed buffer must match the spec math for the current scale.
    assert(buf.width == bw && buf.height == bh,
        "committed buffer size does not match the scale math");

    if (g_path == Path.fractional)
    {
        // Buffer at physical size, destination at logical size, buffer scale 1.
        wsi_viewport_set_destination(g_viewport, g_logicalW, g_logicalH);
    }
    else
        wsi_surface_set_buffer_scale(g_surface, cast(int) g_scale120 / 120);
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
    if (!g_firstCommitDone)
    {
        g_firstCommitDone = true;
        // The created-at-wrong-scale evidence: this is the scale the surface
        // believed at its very first commit, before/after compositor events.
        instrEvent("first_commit", "logical=%dx%d buffer=%dx%d scale120=%u path=%s",
            g_logicalW, g_logicalH, buf.width, buf.height, g_scale120, pathName());
    }
}

/// Re-render right away on any scale/size change and log the new geometry.
void applyChange(const(char)* why) nothrow @nogc
{
    int bw, bh;
    bufferDims(bw, bh);
    instrEvent("commit_info", "reason=%s logical=%dx%d buffer=%dx%d scale120=%u path=%s",
        why, g_logicalW, g_logicalH, bw, bh, g_scale120, pathName());
    if (g_configured)
        render();
}

// ---------------------------------------------------------------- listeners

extern (C) void onFracPreferredScale(void* data, wp_fractional_scale_v1* f, uint scale) nothrow @nogc
{
    instrEvent("preferred_scale", "scale120=%u (wp_fractional_scale_v1)", scale);
    if (g_path == Path.fractional && scale != g_scale120)
    {
        g_scale120 = scale;
        logScaleChanged();
        applyChange("preferred_scale");
    }
}

extern (C) void onSurfaceEnter(void* data, wl_surface* s, wl_output* o) nothrow @nogc
{
    instrEvent("surface_enter", "output_scale=%d", g_outputScale);
    // pre-v6 integer fallback: adopt the entered output's scale.
    if (g_path == Path.bufferScale && g_compositorVersion < 6
        && g_outputScale * 120 != g_scale120)
    {
        g_scale120 = g_outputScale * 120;
        logScaleChanged();
        applyChange("wl_output.scale");
    }
}

extern (C) void onSurfaceLeave(void* data, wl_surface* s, wl_output* o) nothrow @nogc
{
    instrEvent("surface_leave");
}

extern (C) void onPreferredBufferScale(void* data, wl_surface* s, int factor) nothrow @nogc
{
    instrEvent("preferred_buffer_scale", "factor=%d (wl_surface v6)", factor);
    if (g_path == Path.bufferScale && cast(uint)(factor * 120) != g_scale120)
    {
        g_scale120 = factor * 120;
        logScaleChanged();
        applyChange("preferred_buffer_scale");
    }
}

extern (C) void onPreferredBufferTransform(void* data, wl_surface* s, uint transform) nothrow @nogc
{
}

extern (C) void onOutputGeometry(void* data, wl_output* o, int x, int y, int physW,
    int physH, int subpixel, const(char)* make, const(char)* model, int transform) nothrow @nogc
{
    instrEvent("output_geometry", "physical_mm=%dx%d", physW, physH);
}

extern (C) void onOutputMode(void* data, wl_output* o, uint flags, int w, int h, int refresh) nothrow @nogc
{
    instrEvent("output_mode", "size=%dx%d refresh_mhz=%d", w, h, refresh);
}

extern (C) void onOutputDone(void* data, wl_output* o) nothrow @nogc
{
}

extern (C) void onOutputScale(void* data, wl_output* o, int factor) nothrow @nogc
{
    instrEvent("output_scale", "scale=%d (wl_output v2)", factor);
    g_outputScale = factor;
}

extern (C) void onOutputName(void* data, wl_output* o, const(char)* name) nothrow @nogc
{
    instrEvent("output_name", "name=%s", name);
}

extern (C) void onOutputDescription(void* data, wl_output* o, const(char)* desc) nothrow @nogc
{
}

extern (C) void onGlobal(void* data, wl_registry* reg, uint name,
    const(char)* iface, uint ver) nothrow @nogc
{
    instrEvent("global", "iface=%s version=%u", iface, ver); // the registry dump
    static uint capped(uint advertised, uint want) nothrow @nogc
    {
        return advertised < want ? advertised : want;
    }

    if (strcmp(iface, wl_compositor_interface.name) == 0)
    {
        g_compositorVersion = capped(ver, 6); // v6: wl_surface.preferred_buffer_scale
        g_compositor = cast(wl_compositor*) wsi_registry_bind(reg, name,
            &wl_compositor_interface, g_compositorVersion);
    }
    else if (strcmp(iface, wl_shm_interface.name) == 0)
        g_shm = cast(wl_shm*) wsi_registry_bind(reg, name, &wl_shm_interface, 1);
    else if (strcmp(iface, xdg_wm_base_interface.name) == 0)
        g_wmBase = cast(xdg_wm_base*) wsi_registry_bind(reg, name, &xdg_wm_base_interface, 1);
    else if (strcmp(iface, wl_output_interface.name) == 0 && g_output is null)
        g_output = cast(wl_output*) wsi_registry_bind(reg, name,
            &wl_output_interface, capped(ver, 4)); // v2: scale, v4: name
    else if (strcmp(iface, wp_viewporter_interface.name) == 0)
        g_viewporter = cast(wp_viewporter*) wsi_registry_bind(reg, name,
            &wp_viewporter_interface, 1);
    else if (strcmp(iface, wp_fractional_scale_manager_v1_interface.name) == 0)
        g_fracManager = cast(wp_fractional_scale_manager_v1*) wsi_registry_bind(reg, name,
            &wp_fractional_scale_manager_v1_interface, 1);
}

extern (C) void onGlobalRemove(void* data, wl_registry* reg, uint name) nothrow @nogc
{
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
    instrEvent("xdg_toplevel_configure", "size=%dx%d (logical)", w, h);
}

extern (C) void onXdgSurfaceConfigure(void* data, xdg_surface* s, uint serial) nothrow @nogc
{
    immutable w = g_pendingWidth > 0 ? g_pendingWidth : defaultWidth;
    immutable h = g_pendingHeight > 0 ? g_pendingHeight : defaultHeight;
    instrEvent("configure", "serial=%u size=%dx%d", serial, w, h);
    wsi_xdg_surface_ack_configure(s, serial);
    immutable resized = w != g_logicalW || h != g_logicalH;
    g_logicalW = w;
    g_logicalH = h;
    if (!g_configured)
    {
        g_configured = true;
        instrFirstConfigure();
        render();
    }
    else if (resized)
    {
        instrEvent("resize", "size=%dx%d scale120=%u", w, h, g_scale120);
        applyChange("configure");
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
    // sway/wlroots holds shm buffers until the *next* commit replaces them, so
    // both buffers can be busy when a frame callback fires; recover here.
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
__gshared wl_output_listener g_outputListener = {
    &onOutputGeometry, &onOutputMode, &onOutputDone, &onOutputScale,
    &onOutputName, &onOutputDescription
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
    instrInit("f08_wayland");
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
    wl_display_roundtrip(g_display);
    if (g_compositor is null || g_shm is null || g_wmBase is null)
    {
        printf("SKIP: compositor lacks a required global\n");
        wl_display_disconnect(g_display);
        return 0;
    }

    // Path selection: fractional when both fractional-scale-v1 AND viewporter
    // are advertised (the former is useless without the latter), else integer.
    const force = getenv("WSI_FORCE_PATH");
    g_path = g_fracManager !is null && g_viewporter !is null ? Path.fractional : Path.bufferScale;
    if (force !is null && strcmp(force, "buffer_scale") == 0)
        g_path = Path.bufferScale;
    if (force !is null && strcmp(force, "fractional") == 0 && g_path != Path.fractional)
    {
        printf("SKIP: fractional path forced but wp_fractional_scale_v1/wp_viewporter missing\n");
        wl_display_disconnect(g_display);
        return 0;
    }
    instrEvent("path_selected", "path=%s fractional_scale_v1=%d viewporter=%d compositor_version=%u",
        pathName(), g_fracManager !is null ? 1 : 0, g_viewporter !is null ? 1 : 0,
        g_compositorVersion);

    wsi_wm_base_add_listener(g_wmBase, &g_wmBaseListener, null);
    if (g_output !is null)
        wsi_output_add_listener(g_output, &g_outputListener, null);

    g_surface = wsi_compositor_create_surface(g_compositor);
    wsi_surface_add_listener(g_surface, &g_surfaceListener, null);
    if (g_path == Path.fractional)
    {
        g_fracScale = wsi_fractional_scale_manager_get(g_fracManager, g_surface);
        __gshared wp_fractional_scale_v1_listener fracListener = {&onFracPreferredScale};
        wsi_fractional_scale_add_listener(g_fracScale, &fracListener, null);
        g_viewport = wsi_viewporter_get_viewport(g_viewporter, g_surface);
    }
    g_xdgSurface = wsi_wm_base_get_xdg_surface(g_wmBase, g_surface);
    wsi_xdg_surface_add_listener(g_xdgSurface, &g_xdgSurfaceListener, null);
    g_toplevel = wsi_xdg_surface_get_toplevel(g_xdgSurface);
    wsi_toplevel_add_listener(g_toplevel, &g_toplevelListener, null);
    wsi_toplevel_set_title(g_toplevel, "wsi-f08-dpi-scaling");
    wsi_toplevel_set_app_id(g_toplevel, "wsi-f08-dpi-scaling");
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
    if (g_fracScale !is null)
        wsi_fractional_scale_destroy(g_fracScale);
    if (g_fracManager !is null)
        wsi_fractional_scale_manager_destroy(g_fracManager);
    if (g_viewport !is null)
        wsi_viewport_destroy(g_viewport);
    if (g_viewporter !is null)
        wsi_viewporter_destroy(g_viewporter);
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
    if (g_output !is null)
        wl_proxy_destroy(cast(wl_proxy*) g_output);
    wl_proxy_destroy(cast(wl_proxy*) g_shm);
    wl_proxy_destroy(cast(wl_proxy*) g_compositor);
    wl_proxy_destroy(cast(wl_proxy*) g_registry);
    wl_display_disconnect(g_display);

    int bw, bh;
    bufferDims(bw, bh);
    printf("ok: frames=%d commits=%d path=%s final logical=%dx%d buffer=%dx%d scale120=%u\n",
        g_frames, g_commits, pathName(), g_logicalW, g_logicalH, bw, bh, g_scale120);
    return 0;
}
