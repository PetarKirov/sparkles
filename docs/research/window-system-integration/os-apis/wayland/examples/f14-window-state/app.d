// F14 — window state & vetoable close (see ../../f14-window-state.md and
// ../../../features/f14-window-state.md). One binary, two stories:
//
//   State storm (WSI_AUTO_EXIT=1)   a timed choreography issues the full
//       request quartet plus the asymmetric fifth —
//           set_maximized → unset_maximized → set_fullscreen →
//           unset_fullscreen → set_minimized
//       — and decodes the *complete* states array of every
//       xdg_toplevel.configure (maximized/fullscreen/resizing/activated/
//       tiled_*/suspended/constrained_*). xdg_wm_base is bound at
//       min(advertised, 6) so the v6 `suspended` state is delivered when the
//       compositor has it; advertised vs bound is logged. After
//       set_minimized the demo keeps polling (frame callbacks may stop —
//       F04's occlusion finding) and reports how many frame callbacks
//       arrived in the post-minimize window.
//
//   Vetoable close (always armed)   the document is permanently "dirty":
//       the first WSI_VETO_CLOSE (default 1) xdg_toplevel.close events are
//       *ignored* — that is the entire veto mechanism, close is an event,
//       not a question, and there is nothing to return — and the next one
//       exits. A dispatch error (compositor died while we lingered) is
//       captured as errno (EPIPE).
//
// Headless-safe: no compositor → SKIP, exit 0.
module app;

import c; // ImportC: wayland-client + xdg-shell glue (wsi_*)
import instrument;
import core.stdc.stdio : printf, snprintf;
import core.stdc.stdlib : getenv, atoi;
import core.stdc.string : strcmp;

enum int defaultWidth = 640, defaultHeight = 480;

// The timed choreography (µs since init). Time-based, not frame-based: after
// set_minimized there may be no frame callbacks left to count with.
enum long tMaximize = 700_000;
enum long tUnmaximize = 1_400_000;
enum long tFullscreen = 2_100_000;
enum long tUnfullscreen = 2_800_000;
enum long tMinimize = 3_500_000;
enum long tReport = 4_700_000; // frame-callback census for the minimized span

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
    wl_surface* g_surface;
    xdg_surface* g_xdgSurface;
    xdg_toplevel* g_toplevel;
    wl_callback* g_frameCb;
    Buffer[2] g_buffers;

    uint g_wmBaseAdvertised, g_wmBaseBound;
    int g_width = defaultWidth, g_height = defaultHeight;
    int g_pendingWidth, g_pendingHeight;
    char[160] g_pendingStates; // decoded states array of the latest configure
    bool g_configured, g_running = true, g_autoExit;
    long g_runUsCap = 5_200_000;
    int g_frames, g_configures;
    int g_phase; // next choreography step to fire (0..5)
    int g_framesAtMinimize = -1;
    bool g_reported;
    int g_vetoesLeft = 1; // the "dirty document": ignore this many closes
    int g_closesSeen;
}

// ------------------------------------------------------------ states decode

/// Decode a configure states wl_array into "[a,b,c]" — every value the v6
/// protocol can deliver, plus raw numbers for anything newer.
void decodeStates(const(wl_array)* states, char[] outBuf) nothrow @nogc
{
    static immutable string[10] names = [
        "?0", "maximized", "fullscreen", "resizing", "activated",
        "tiled_left", "tiled_right", "tiled_top", "tiled_bottom", "suspended",
    ];
    size_t pos = 0;
    void putc(char c) nothrow @nogc
    {
        if (pos + 1 < outBuf.length)
            outBuf[pos++] = c;
    }

    putc('[');
    const vals = cast(const(uint)*) states.data;
    foreach (i; 0 .. states.size / uint.sizeof)
    {
        if (i > 0)
            putc(',');
        immutable v = vals[i];
        if (v < names.length)
            foreach (ch; names[v])
                putc(ch);
        else // constrained_* (v7) or future states
        {
            char[12] num = void;
            immutable n = snprintf(num.ptr, num.length, "%u", v);
            foreach (ch; num[0 .. n])
                putc(ch);
        }
    }
    putc(']');
    outBuf[pos] = '\0';
}

// ---------------------------------------------------------- shm buffer pool

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
    immutable fd = memfd_create("wsi-f14", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, cast(long) size) != 0)
        return false;
    void* mem = mmap(null, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (mem is cast(void*)-1)
    {
        close(fd);
        return false;
    }
    wl_shm_pool* pool = wsi_shm_create_pool(g_shm, fd, cast(int) size);
    b.handle = wsi_shm_pool_create_buffer(pool, 0, w, h, stride, WL_SHM_FORMAT_XRGB8888);
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
        return; // both held; wl_buffer.release re-renders
    if (!ensureBuffer(*buf, g_width, g_height))
    {
        g_running = false;
        return;
    }
    foreach (y; 0 .. buf.height) // gradient (scaffold pattern)
    {
        uint* row = buf.pixels + cast(size_t) y * buf.width;
        immutable uint g = cast(uint)(y * 255 / (buf.height > 1 ? buf.height - 1 : 1)) << 8;
        foreach (x; 0 .. buf.width)
            row[x] = 0xff00_0000
                | (cast(uint)(x * 255 / (buf.width > 1 ? buf.width - 1 : 1)) << 16) | g;
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
}

// ---------------------------------------------------------------- listeners

extern (C) void onGlobal(void* data, wl_registry* reg, uint name,
    const(char)* iface, uint ver) nothrow @nogc
{
    if (strcmp(iface, wl_compositor_interface.name) == 0)
        g_compositor = cast(wl_compositor*) wsi_registry_bind(reg, name,
            &wl_compositor_interface, ver < 4 ? ver : 4);
    else if (strcmp(iface, wl_shm_interface.name) == 0)
        g_shm = cast(wl_shm*) wsi_registry_bind(reg, name, &wl_shm_interface, 1);
    else if (strcmp(iface, xdg_wm_base_interface.name) == 0)
    {
        // Bind up to v6: the `suspended` state exists "since 6" — at v1..5 the
        // compositor is *forbidden* from sending it, whatever it knows.
        g_wmBaseAdvertised = ver;
        g_wmBaseBound = ver < 6 ? ver : 6;
        g_wmBase = cast(xdg_wm_base*) wsi_registry_bind(reg, name,
            &xdg_wm_base_interface, g_wmBaseBound);
        instrEvent("wm_base", "advertised=%u bound=%u suspended_possible=%d",
            g_wmBaseAdvertised, g_wmBaseBound, g_wmBaseBound >= 6 ? 1 : 0);
    }
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
    decodeStates(states, g_pendingStates[]);
}

extern (C) void onXdgSurfaceConfigure(void* data, xdg_surface* s, uint serial) nothrow @nogc
{
    immutable w = g_pendingWidth > 0 ? g_pendingWidth : defaultWidth;
    immutable h = g_pendingHeight > 0 ? g_pendingHeight : defaultHeight;
    g_configures++;
    instrEvent("configure", "serial=%u size=%dx%d states=%s",
        serial, w, h, g_pendingStates.ptr);
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

/// xdg_toplevel.close — "a one-way *event*, not a request/response pair. The
/// client decides; ignoring it IS the veto" (no reply exists to send).
extern (C) void onToplevelClose(void* data, xdg_toplevel* t) nothrow @nogc
{
    g_closesSeen++;
    if (g_vetoesLeft > 0)
    {
        g_vetoesLeft--;
        instrEvent("close_requested", "n=%d verdict=vetoed dirty=1 note=event ignored, no reply sent",
            g_closesSeen);
        return; // the whole veto: do nothing
    }
    instrEvent("close_requested", "n=%d verdict=accepted", g_closesSeen);
    instrCloseRequested();
    g_running = false;
}

extern (C) void onToplevelConfigureBounds(void* data, xdg_toplevel* t, int w, int h) nothrow @nogc
{
}

extern (C) void onToplevelWmCapabilities(void* data, xdg_toplevel* t, wl_array* caps) nothrow @nogc
{
    char[160] buf = void;
    decodeCaps(caps, buf[]);
    instrEvent("wm_capabilities", "caps=%s", buf.ptr);
}

/// xdg_toplevel.wm_capabilities (v5): does the compositor even *do* minimize?
void decodeCaps(const(wl_array)* caps, char[] outBuf) nothrow @nogc
{
    static immutable string[5] names = ["?0", "window_menu", "maximize", "fullscreen", "minimize"];
    size_t pos = 0;
    const vals = cast(const(uint)*) caps.data;
    outBuf[pos++] = '[';
    foreach (i; 0 .. caps.size / uint.sizeof)
    {
        if (i > 0)
            outBuf[pos++] = ',';
        immutable v = vals[i];
        foreach (ch; v < names.length ? names[v] : "?")
            if (pos + 2 < outBuf.length)
                outBuf[pos++] = ch;
    }
    outBuf[pos++] = ']';
    outBuf[pos] = '\0';
}

extern (C) void onBufferRelease(void* data, wl_buffer* b) nothrow @nogc
{
    (cast(Buffer*) data).busy = false;
}

extern (C) void onFrameDone(void* data, wl_callback* cb, uint timeMs) nothrow @nogc
{
    wsi_callback_destroy(cb);
    g_frameCb = null;
    g_frames++;
    if (g_frames == 1)
        instrFirstPixelPresented();
    if (g_running && g_configured)
        render();
}

__gshared wl_registry_listener g_registryListener = {&onGlobal, &onGlobalRemove};
__gshared xdg_wm_base_listener g_wmBaseListener = {&onWmBasePing};
__gshared xdg_surface_listener g_xdgSurfaceListener = {&onXdgSurfaceConfigure};
__gshared xdg_toplevel_listener g_toplevelListener = {
    &onToplevelConfigure, &onToplevelClose,
    &onToplevelConfigureBounds, &onToplevelWmCapabilities
};
__gshared wl_buffer_listener g_bufferListener = {&onBufferRelease};
__gshared wl_callback_listener g_frameListener = {&onFrameDone};

// -------------------------------------------------------------- choreography

void step(int phase) nothrow @nogc
{
    final switch (phase)
    {
    case 0:
        instrEvent("state_request", "kind=set_maximized frames=%d", g_frames);
        wsi_toplevel_set_maximized(g_toplevel);
        break;
    case 1:
        instrEvent("state_request", "kind=unset_maximized frames=%d", g_frames);
        wsi_toplevel_unset_maximized(g_toplevel);
        break;
    case 2:
        instrEvent("state_request", "kind=set_fullscreen frames=%d", g_frames);
        wsi_toplevel_set_fullscreen(g_toplevel);
        break;
    case 3:
        instrEvent("state_request", "kind=unset_fullscreen frames=%d", g_frames);
        wsi_toplevel_unset_fullscreen(g_toplevel);
        break;
    case 4:
        // No unset_minimized exists, no `minimized` state will ever appear in
        // a configure — only the user (or compositor IPC) can bring it back.
        instrEvent("state_request", "kind=set_minimized frames=%d note=no unset twin, no state feedback", g_frames);
        wsi_toplevel_set_minimized(g_toplevel);
        g_framesAtMinimize = g_frames;
        break;
    }
}

__gshared immutable long[5] g_stepAt = [
    tMaximize, tUnmaximize, tFullscreen, tUnfullscreen, tMinimize,
];

// --------------------------------------------------------------------- main

int main()
{
    instrInit("f14-state");
    bool env(const(char)* n)
    {
        const v = getenv(n);
        return v !is null && *v == '1';
    }

    g_autoExit = env("WSI_AUTO_EXIT");
    if (const ms = getenv("WSI_RUN_MS"))
        g_runUsCap = atoi(ms) * 1000L;
    if (const v = getenv("WSI_VETO_CLOSE"))
        g_vetoesLeft = atoi(v);

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
    wsi_wm_base_add_listener(g_wmBase, &g_wmBaseListener, null);

    g_surface = wsi_compositor_create_surface(g_compositor);
    g_xdgSurface = wsi_wm_base_get_xdg_surface(g_wmBase, g_surface);
    wsi_xdg_surface_add_listener(g_xdgSurface, &g_xdgSurfaceListener, null);
    g_toplevel = wsi_xdg_surface_get_toplevel(g_xdgSurface);
    wsi_toplevel_add_listener(g_toplevel, &g_toplevelListener, null);
    wsi_toplevel_set_title(g_toplevel, "wsi-f14-window-state");
    const appId = getenv("WSI_APP_ID");
    wsi_toplevel_set_app_id(g_toplevel, appId !is null ? appId : "wsi-f14-window-state");
    instrWindowCreated();
    wsi_surface_commit(g_surface); // mandatory no-buffer commit

    // Poll-driven loop: dispatch when the fd is readable, otherwise tick the
    // clock. Blocking in wl_display_dispatch would hang the choreography the
    // moment frame callbacks stop (minimized/occluded — F04).
    immutable fd = wl_display_get_fd(g_display);
    while (g_running)
    {
        if (wl_display_dispatch_pending(g_display) == -1)
            break;
        wl_display_flush(g_display);
        pollfd pfd = {fd: fd, events: POLLIN};
        if (poll(&pfd, 1, 50) > 0 && (pfd.revents & POLLIN))
        {
            if (wl_display_dispatch(g_display) == -1)
                break;
        }
        immutable now = instrNowUs();
        if (g_autoExit && g_configured)
        {
            while (g_phase < g_stepAt.length && now > g_stepAt[g_phase])
                step(g_phase++);
            if (!g_reported && g_framesAtMinimize >= 0 && now > tReport)
            {
                g_reported = true;
                instrEvent("minimize_census",
                    "frames_in_%dms_after_set_minimized=%d total_frames=%d",
                    cast(int)((tReport - tMinimize) / 1000), g_frames - g_framesAtMinimize,
                    g_frames);
            }
            if (now > g_runUsCap)
                g_running = false;
        }
    }

    immutable err = wl_display_get_error(g_display);
    if (err != 0) // the compositor died while we lingered (the EPIPE capture)
        instrEvent("dispatch_error", "errno=%d note=%s", err,
            err == 32 ? "EPIPE - compositor gone, veto moot".ptr : "connection error".ptr);

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
    wl_proxy_destroy(cast(wl_proxy*) g_shm);
    wl_proxy_destroy(cast(wl_proxy*) g_compositor);
    wl_proxy_destroy(cast(wl_proxy*) g_registry);
    wl_display_disconnect(g_display);
    printf("ok: %d frames, %d configures, closes_seen=%d vetoes_left=%d\n",
        g_frames, g_configures, g_closesSeen, g_vetoesLeft);
    return 0;
}
