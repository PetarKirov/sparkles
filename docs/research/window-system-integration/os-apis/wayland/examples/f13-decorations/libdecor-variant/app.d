// F13 libdecor comparison variant (see ../app.d for the hand-rolled CSD this
// is measured against, and ../../../f13-decorations.md for the LOC ledger).
// The sanctioned helper-library exception: libdecor_new + libdecor_decorate
// replace the *entire* shell layer — xdg_surface/xdg_toplevel creation, the
// configure/ack dance, xdg-decoration negotiation, set_window_geometry, title
// bar drawing, move/resize hit zones, themes, shadows, double-click-to-
// maximize all live inside libdecor and its cairo/gtk plugin. The app keeps
// only: connect, bind wl_compositor+wl_shm, paint content, commit, dispatch.
// A maximize/unmaximize storm exercises libdecor's geometry handling.
// Headless-safe: no compositor → SKIP, exit 0.
module app;

import c; // ImportC: wayland-client + libdecor.h + wsi_* core helpers
import instrument;
import core.stdc.stdio : printf;
import core.stdc.stdlib : getenv, atoi;
import core.stdc.string : strcmp;

enum int defaultWidth = 640, defaultHeight = 480;

__gshared
{
    wl_display* g_display;
    wl_registry* g_registry;
    wl_compositor* g_compositor;
    wl_shm* g_shm;
    wl_surface* g_surface;
    libdecor* g_ctx;
    libdecor_frame* g_frame;
    wl_buffer* g_buffer; // single-buffered: weston/sway release shm fast
    uint* g_pixels;
    size_t g_byteSize;
    int g_width = defaultWidth, g_height = defaultHeight;
    int g_configures;
    bool g_running = true;
    long g_runUsCap = 2_500_000;
    bool g_maximizedSent, g_unmaximizedSent;
}

extern (C) void onGlobal(void* data, wl_registry* reg, uint name,
    const(char)* iface, uint ver) nothrow @nogc
{
    if (strcmp(iface, wl_compositor_interface.name) == 0)
        g_compositor = cast(wl_compositor*) wsi_registry_bind(reg, name,
            &wl_compositor_interface, ver < 4 ? ver : 4);
    else if (strcmp(iface, wl_shm_interface.name) == 0)
        g_shm = cast(wl_shm*) wsi_registry_bind(reg, name, &wl_shm_interface, 1);
}

extern (C) void onGlobalRemove(void* data, wl_registry* reg, uint name) nothrow @nogc
{
}

__gshared wl_registry_listener g_registryListener = {&onGlobal, &onGlobalRemove};

void paintAndCommit() nothrow @nogc
{
    immutable stride = g_width * 4;
    immutable size = cast(size_t) stride * g_height;
    if (g_buffer !is null)
    {
        wsi_buffer_destroy(g_buffer);
        munmap(g_pixels, g_byteSize);
        g_buffer = null;
    }
    immutable fd = memfd_create("wsi-f13-libdecor", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, cast(long) size) != 0)
        return;
    g_pixels = cast(uint*) mmap(null, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    g_byteSize = size;
    wl_shm_pool* pool = wsi_shm_create_pool(g_shm, fd, cast(int) size);
    g_buffer = wsi_shm_pool_create_buffer(pool, 0, g_width, g_height, stride,
        WL_SHM_FORMAT_ARGB8888);
    wsi_shm_pool_destroy(pool);
    close(fd);
    foreach (y; 0 .. g_height) // content gradient only — NO frame drawing here
    {
        uint* row = g_pixels + cast(size_t) y * g_width;
        immutable uint g = cast(uint)(y * 255 / (g_height - 1)) << 8;
        foreach (x; 0 .. g_width)
            row[x] = 0xff00_0000 | (cast(uint)(x * 255 / (g_width - 1)) << 16) | g;
    }
    wsi_surface_attach(g_surface, g_buffer, 0, 0);
    wsi_surface_damage_buffer(g_surface, 0, 0, g_width, g_height);
    wsi_surface_commit(g_surface);
}

// ---------------------------------------------------- libdecor callbacks

extern (C) void onError(libdecor* ctx, libdecor_error error, const(char)* message) nothrow @nogc
{
    instrEvent("libdecor_error", "error=%d message=%s", error, message);
    g_running = false;
}

/// The whole F13 negotiation, reduced to one callback: libdecor hands over the
/// *content* size (frame already subtracted) and takes back a libdecor_state —
/// ack_configure + set_window_geometry happen inside libdecor_frame_commit.
extern (C) void onConfigure(libdecor_frame* frame, libdecor_configuration* conf,
    void* userData) nothrow @nogc
{
    int w, h;
    if (!libdecor_configuration_get_content_size(conf, frame, &w, &h))
    {
        w = defaultWidth;
        h = defaultHeight;
    }
    libdecor_window_state ws;
    if (!libdecor_configuration_get_window_state(conf, &ws))
        ws = LIBDECOR_WINDOW_STATE_NONE;
    g_configures++;
    instrEvent("configure", "content=%dx%d window_state=0x%x", w, h, cast(uint) ws);
    g_width = w;
    g_height = h;
    libdecor_state* state = libdecor_state_new(w, h);
    libdecor_frame_commit(frame, state, conf);
    libdecor_state_free(state);
    paintAndCommit();
    if (g_configures == 1)
        instrFirstPixelPresented(); // first content commit; frame is libdecor's
}

extern (C) void onClose(libdecor_frame* frame, void* userData) nothrow @nogc
{
    instrCloseRequested();
    g_running = false;
}

extern (C) void onCommit(libdecor_frame* frame, void* userData) nothrow @nogc
{
    wsi_surface_commit(g_surface); // sync-subsurface decorations need this
}

extern (C) void onDismissPopup(libdecor_frame* frame, const(char)* seatName, void* userData) nothrow @nogc
{
}

__gshared libdecor_interface g_iface = {&onError};
__gshared libdecor_frame_interface g_frameIface = {
    &onConfigure, &onClose, &onCommit, &onDismissPopup
};

// --------------------------------------------------------------------- main

int main()
{
    instrInit("f13-libdecor");
    const autoEnv = getenv("WSI_AUTO_EXIT");
    immutable autoExit = autoEnv !is null && *autoEnv == '1';
    if (const ms = getenv("WSI_RUN_MS"))
        g_runUsCap = atoi(ms) * 1000L;

    g_display = wl_display_connect(null);
    if (g_display is null)
    {
        printf("SKIP: no Wayland compositor (wl_display_connect returned null)\n");
        return 0;
    }
    g_registry = wsi_display_get_registry(g_display);
    wsi_registry_add_listener(g_registry, &g_registryListener, null);
    wl_display_roundtrip(g_display);
    if (g_compositor is null || g_shm is null)
    {
        printf("SKIP: compositor lacks wl_compositor/wl_shm\n");
        wl_display_disconnect(g_display);
        return 0;
    }
    g_surface = wsi_compositor_create_surface(g_compositor);

    g_ctx = libdecor_new(g_display, &g_iface); // binds xdg-shell + xdg-deco itself
    instrEvent("step", "name=libdecor_new");
    g_frame = libdecor_decorate(g_ctx, g_surface, &g_frameIface, null);
    instrEvent("step", "name=libdecor_decorate");
    libdecor_frame_set_title(g_frame, "wsi-f13-libdecor");
    libdecor_frame_set_app_id(g_frame, "wsi-f13-libdecor");
    libdecor_frame_map(g_frame);
    instrWindowCreated();

    // libdecor owns the event loop entry point: its dispatch wraps the wl
    // socket *and* the plugin's own timers/frame machinery.
    while (g_running && libdecor_dispatch(g_ctx, 100) >= 0)
    {
        immutable now = instrNowUs();
        if (autoExit && !g_maximizedSent && now > g_runUsCap / 3)
        {
            g_maximizedSent = true;
            instrEvent("state_request", "kind=set_maximized");
            libdecor_frame_set_maximized(g_frame);
        }
        else if (autoExit && !g_unmaximizedSent && now > 2 * g_runUsCap / 3)
        {
            g_unmaximizedSent = true;
            instrEvent("state_request", "kind=unset_maximized");
            libdecor_frame_unset_maximized(g_frame);
        }
        if (autoExit && now > g_runUsCap)
            g_running = false;
    }

    libdecor_frame_unref(g_frame);
    libdecor_unref(g_ctx); // tears down its xdg/decoration objects
    if (g_buffer !is null)
    {
        wsi_buffer_destroy(g_buffer);
        munmap(g_pixels, g_byteSize);
    }
    wsi_surface_destroy(g_surface);
    wl_proxy_destroy(cast(wl_proxy*) g_shm);
    wl_proxy_destroy(cast(wl_proxy*) g_compositor);
    wl_proxy_destroy(cast(wl_proxy*) g_registry);
    wl_display_disconnect(g_display);
    printf("ok: %d configures, final content %dx%d\n", g_configures, g_width, g_height);
    return 0;
}
