// F13 — CSD & decoration modes (see ../../f13-decorations.md and
// ../../../features/f13-decorations.md). One binary, three behaviours:
//
//   Mode A (default)      bind zxdg_decoration_manager_v1 when offered, request
//                         server-side, log the compositor's configure mode=…
//                         answer, honor runtime mode switches (the auto storm
//                         flips set_mode(client_side) → unset_mode mid-run).
//   Mode B (CSD)          WSI_FORCE_CSD=1, or whenever SSD is denied or the
//                         protocol is absent (the source= is logged): draw a
//                         minimal title bar (solid rect + block-glyph title +
//                         close box) and a fake-shadow margin ring whose outer
//                         band is 8 resize zones. Pointer-down on the bar →
//                         xdg_toplevel.move(seat, serial); on a band zone →
//                         xdg_toplevel.resize(seat, serial, edge); on the close
//                         box → client shutdown. xdg_surface.set_window_geometry
//                         excludes the margin; every commit logs buffer size vs
//                         geometry so the contract is visible in the trace.
//   WSI_NO_GEOMETRY=1     keep the margin but never call set_window_geometry —
//                         the auto storm's set_maximized then commits a buffer
//                         larger than the configured size, and the compositor's
//                         reaction (weston: fatal invalid_surface_state) is the
//                         "what breaks without it" deliverable.
//
// The libdecor comparison variant lives in ./libdecor-variant/. Headless-safe:
// no compositor → SKIP, exit 0; no seat (headless weston) → the pointer paths
// are unarmed and only the negotiation + geometry story runs.
module app;

import c; // ImportC: wayland-client + xdg-shell + xdg-decoration glue (wsi_*)
import instrument;
import core.stdc.stdio : printf;
import core.stdc.stdlib : getenv, atoi;
import core.stdc.string : strcmp;

// ----------------------------------------------------------------- tunables

enum int defaultWidth = 640; // window *geometry* size (content + title bar)
enum int defaultHeight = 480;
enum int margin = 12; // fake-shadow ring around the geometry (CSD only)
enum int bandExtra = 4; // resize band reaches this far inside the geometry
enum int titleH = 28; // title-bar height, inside the geometry
enum int maximizeAtFrame = 30, unmaximizeAtFrame = 55;
enum int csdModeAtFrame = 80, unsetModeAtFrame = 105; // decoration mode storm
enum uint BTN_LEFT = 0x110;

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
    wl_seat* g_seat;
    wl_pointer* g_pointer;
    xdg_wm_base* g_wmBase;
    wl_surface* g_surface;
    xdg_surface* g_xdgSurface;
    xdg_toplevel* g_toplevel;
    zxdg_decoration_manager_v1* g_decoMgr;
    zxdg_toplevel_decoration_v1* g_deco;
    wl_callback* g_frameCb;
    Buffer[2] g_buffers;

    int g_geoW = defaultWidth, g_geoH = defaultHeight; // acked geometry size
    int g_pendingWidth, g_pendingHeight;
    bool g_maximized, g_fullscreen, g_activated;
    uint g_decoMode; // 0 = no answer yet / protocol absent
    bool g_forceCsd, g_noGeometry, g_noStorm;
    bool g_configured, g_running = true, g_autoExit;
    long g_runUsCap = 2_500_000;
    int g_frames, g_commits;
    int g_lastLoggedBw, g_lastLoggedBh; // commit-log dedup
    int g_ptrX, g_ptrY; // surface-local pointer position
    int g_zone = -99; // last logged csd_hit zone
}

// ------------------------------------------------------------ CSD geometry

bool csdActive() nothrow @nogc
{
    return g_forceCsd || g_decoMode != ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE;
}

/// Fake-shadow margin currently in effect. Real CSD drops its shadow when
/// maximized/fullscreen (the geometry must exactly match the configured size
/// anyway); the WSI_NO_GEOMETRY probe keeps it to arm the violation.
int marginNow() nothrow @nogc
{
    if (!csdActive())
        return 0;
    if (g_noGeometry)
        return margin;
    return (g_maximized || g_fullscreen) ? 0 : margin;
}

bool titleBarNow() nothrow @nogc
{
    return csdActive() && !g_fullscreen;
}

// Zone codes: 1..10 = xdg_toplevel resize_edge enum, 100 = title bar,
// 101 = close box, 0 = content.
int zoneAt(int x, int y, int bw, int bh) nothrow @nogc
{
    immutable m = marginNow();
    if (m > 0)
    {
        immutable band = m + bandExtra;
        uint e = 0;
        if (y < band)
            e |= XDG_TOPLEVEL_RESIZE_EDGE_TOP;
        else if (y >= bh - band)
            e |= XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM;
        if (x < band)
            e |= XDG_TOPLEVEL_RESIZE_EDGE_LEFT;
        else if (x >= bw - band)
            e |= XDG_TOPLEVEL_RESIZE_EDGE_RIGHT;
        if (e != 0)
            return cast(int) e;
    }
    if (titleBarNow() && y >= m && y < m + titleH && x >= m && x < bw - m)
        return x >= bw - m - titleH ? 101 : 100;
    return 0;
}

const(char)* zoneName(int z) nothrow @nogc
{
    switch (z)
    {
    case 100: return "title";
    case 101: return "close";
    case XDG_TOPLEVEL_RESIZE_EDGE_TOP: return "top";
    case XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM: return "bottom";
    case XDG_TOPLEVEL_RESIZE_EDGE_LEFT: return "left";
    case XDG_TOPLEVEL_RESIZE_EDGE_RIGHT: return "right";
    case XDG_TOPLEVEL_RESIZE_EDGE_TOP_LEFT: return "top_left";
    case XDG_TOPLEVEL_RESIZE_EDGE_TOP_RIGHT: return "top_right";
    case XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM_LEFT: return "bottom_left";
    case XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM_RIGHT: return "bottom_right";
    default: return "content";
    }
}

// ----------------------------------------------------------------- painting

// 3×5 block glyphs for the title "WSI-F13 CSD"; each row is 3 bits, msb left.
struct Glyph
{
    char c;
    ubyte[5] rows;
}

__gshared immutable Glyph[10] g_font = [
    {'W', [0b101, 0b101, 0b101, 0b111, 0b101]},
    {'S', [0b111, 0b100, 0b111, 0b001, 0b111]},
    {'I', [0b111, 0b010, 0b010, 0b010, 0b111]},
    {'-', [0b000, 0b000, 0b111, 0b000, 0b000]},
    {'F', [0b111, 0b100, 0b110, 0b100, 0b100]},
    {'1', [0b010, 0b110, 0b010, 0b010, 0b111]},
    {'3', [0b111, 0b001, 0b011, 0b001, 0b111]},
    {'C', [0b111, 0b100, 0b100, 0b100, 0b111]},
    {'D', [0b110, 0b101, 0b101, 0b101, 0b110]},
    {' ', [0b000, 0b000, 0b000, 0b000, 0b000]},
];

void fillRect(ref Buffer b, int x0, int y0, int w, int h, uint argb) nothrow @nogc
{
    foreach (y; y0 .. y0 + h)
    {
        if (y < 0 || y >= b.height)
            continue;
        uint* row = b.pixels + cast(size_t) y * b.width;
        foreach (x; x0 .. x0 + w)
            if (x >= 0 && x < b.width)
                row[x] = argb;
    }
}

void drawTitle(ref Buffer b, int x, int y) nothrow @nogc
{
    enum scale = 3;
    static immutable string text = "WSI-F13 CSD";
    foreach (ch; text)
    {
        foreach (ref g; g_font)
            if (g.c == ch)
            {
                foreach (ry; 0 .. 5)
                    foreach (rx; 0 .. 3)
                        if (g.rows[ry] & (0b100 >> rx))
                            fillRect(b, x + rx * scale, y + ry * scale, scale, scale, 0xffe5_e9f0);
                break;
            }
        x += 4 * scale;
    }
}

/// Paint the whole buffer: margin ring (fake shadow), title bar + glyphs +
/// close box, content gradient — or just the gradient when SSD is active.
void paint(ref Buffer b) nothrow @nogc
{
    immutable m = marginNow();
    immutable tb = titleBarNow() ? titleH : 0;
    if (m > 0) // semi-transparent "shadow" — ARGB8888 has real alpha
        fillRect(b, 0, 0, b.width, b.height, 0x4010_1010);
    if (tb > 0)
    {
        fillRect(b, m, m, b.width - 2 * m, tb, 0xff2e_3440);
        drawTitle(b, m + 10, m + 6);
        // close box: rightmost titleH×titleH square of the bar, with an X
        immutable cx = b.width - m - titleH;
        fillRect(b, cx, m, titleH, titleH, 0xff8b_2e2e);
        foreach (i; 6 .. titleH - 6)
        {
            fillRect(b, cx + i, m + i, 2, 2, 0xffff_ffff);
            fillRect(b, cx + titleH - i - 2, m + i, 2, 2, 0xffff_ffff);
        }
    }
    // content gradient (scaffold pattern), below the title bar
    immutable x0 = m, y0 = m + tb, cw = b.width - 2 * m, chh = b.height - 2 * m - tb;
    foreach (y; 0 .. chh)
    {
        uint* row = b.pixels + cast(size_t)(y0 + y) * b.width + x0;
        immutable uint g = cast(uint)(y * 255 / (chh > 1 ? chh - 1 : 1)) << 8;
        foreach (x; 0 .. cw)
            row[x] = 0xff00_0000 | (cast(uint)(x * 255 / (cw > 1 ? cw - 1 : 1)) << 16) | g;
    }
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
    immutable fd = memfd_create("wsi-f13", MFD_CLOEXEC);
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

/// Paint + commit. Buffer = geometry + 2×margin; set_window_geometry tells the
/// compositor which part of it is "the window" — unless WSI_NO_GEOMETRY=1.
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
    immutable m = marginNow();
    immutable bw = g_geoW + 2 * m, bh = g_geoH + 2 * m;
    if (!ensureBuffer(*buf, bw, bh))
    {
        g_running = false;
        return;
    }
    paint(*buf);
    if (csdActive() && !g_noGeometry)
        wsi_xdg_surface_set_window_geometry(g_xdgSurface, m, m, g_geoW, g_geoH);
    if (bw != g_lastLoggedBw || bh != g_lastLoggedBh)
    {
        instrEvent("commit", "buffer=%dx%d geometry=%dx%d@%d,%d geometry_set=%d csd=%d",
            bw, bh, g_geoW, g_geoH, m, m,
            (csdActive() && !g_noGeometry) ? 1 : 0, csdActive() ? 1 : 0);
        g_lastLoggedBw = bw;
        g_lastLoggedBh = bh;
    }
    wsi_surface_attach(g_surface, buf.handle, 0, 0);
    wsi_surface_damage_buffer(g_surface, 0, 0, bw, bh);
    if (g_frameCb is null)
    {
        g_frameCb = wsi_surface_frame(g_surface);
        wsi_callback_add_listener(g_frameCb, &g_frameListener, null);
    }
    wsi_surface_commit(g_surface);
    buf.busy = true;
    g_commits++;
    if (g_commits == 1)
        instrEvent("first_commit", "buffer=%dx%d", bw, bh);
}

// ---------------------------------------------------------------- listeners

extern (C) void onGlobal(void* data, wl_registry* reg, uint name,
    const(char)* iface, uint ver) nothrow @nogc
{
    static uint capped(uint a, uint w) nothrow @nogc
    {
        return a < w ? a : w;
    }

    if (strcmp(iface, wl_compositor_interface.name) == 0)
        g_compositor = cast(wl_compositor*) wsi_registry_bind(reg, name,
            &wl_compositor_interface, capped(ver, 4));
    else if (strcmp(iface, wl_shm_interface.name) == 0)
        g_shm = cast(wl_shm*) wsi_registry_bind(reg, name, &wl_shm_interface, 1);
    else if (strcmp(iface, xdg_wm_base_interface.name) == 0)
        g_wmBase = cast(xdg_wm_base*) wsi_registry_bind(reg, name, &xdg_wm_base_interface, 1);
    else if (strcmp(iface, wl_seat_interface.name) == 0 && g_seat is null)
    {
        g_seat = cast(wl_seat*) wsi_registry_bind(reg, name, &wl_seat_interface, capped(ver, 5));
        wsi_seat_add_listener(g_seat, &g_seatListener, null);
    }
    else if (strcmp(iface, zxdg_decoration_manager_v1_interface.name) == 0)
        g_decoMgr = cast(zxdg_decoration_manager_v1*) wsi_registry_bind(reg, name,
            &zxdg_decoration_manager_v1_interface, 1);
    else
        return;
    instrEvent("step", "name=wl_registry_bind iface=%s version=%u", iface, ver);
}

extern (C) void onGlobalRemove(void* data, wl_registry* reg, uint name) nothrow @nogc
{
}

extern (C) void onWmBasePing(void* data, xdg_wm_base* b, uint serial) nothrow @nogc
{
    wsi_wm_base_pong(b, serial);
}

/// zxdg_toplevel_decoration_v1.configure: the compositor's decoration answer.
/// "The specified mode must be obeyed by the client."
extern (C) void onDecorationConfigure(void* data, zxdg_toplevel_decoration_v1* d,
    uint mode) nothrow @nogc
{
    immutable prev = g_decoMode;
    g_decoMode = mode;
    instrEvent("decoration", "mode=%s source=protocol raw=%u",
        mode == ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE ? "ssd".ptr : "csd".ptr, mode);
    if (g_configured && prev != mode)
        render(); // honor the runtime switch: redraw with/without the frame
}

extern (C) void onToplevelConfigure(void* data, xdg_toplevel* t, int w, int h,
    wl_array* states) nothrow @nogc
{
    g_pendingWidth = w;
    g_pendingHeight = h;
    g_maximized = g_fullscreen = g_activated = false;
    const start = cast(const(uint)*) states.data;
    foreach (i; 0 .. states.size / uint.sizeof)
    {
        if (start[i] == XDG_TOPLEVEL_STATE_MAXIMIZED)
            g_maximized = true;
        if (start[i] == XDG_TOPLEVEL_STATE_FULLSCREEN)
            g_fullscreen = true;
        if (start[i] == XDG_TOPLEVEL_STATE_ACTIVATED)
            g_activated = true;
    }
    instrEvent("xdg_toplevel_configure", "size=%dx%d maximized=%d fullscreen=%d activated=%d",
        w, h, g_maximized ? 1 : 0, g_fullscreen ? 1 : 0, g_activated ? 1 : 0);
}

extern (C) void onXdgSurfaceConfigure(void* data, xdg_surface* s, uint serial) nothrow @nogc
{
    // The configured size is the *window geometry* size — the buffer adds the
    // margin back on top of it (the heart of the set_window_geometry contract).
    immutable w = g_pendingWidth > 0 ? g_pendingWidth : defaultWidth;
    immutable h = g_pendingHeight > 0 ? g_pendingHeight : defaultHeight;
    instrEvent("configure", "serial=%u size=%dx%d", serial, w, h);
    wsi_xdg_surface_ack_configure(s, serial);
    immutable resized = w != g_geoW || h != g_geoH;
    g_geoW = w;
    g_geoH = h;
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
    if (g_autoExit)
    {
        if (!g_noStorm)
        {
            if (g_frames == maximizeAtFrame)
            {
                instrEvent("state_request", "kind=set_maximized");
                wsi_toplevel_set_maximized(g_toplevel);
            }
            else if (g_frames == unmaximizeAtFrame)
            {
                instrEvent("state_request", "kind=unset_maximized");
                wsi_toplevel_unset_maximized(g_toplevel);
            }
            else if (g_frames == csdModeAtFrame && g_deco !is null)
            {
                instrEvent("decoration_request", "mode=client_side");
                wsi_decoration_set_mode(g_deco, ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE);
            }
            else if (g_frames == unsetModeAtFrame && g_deco !is null)
            {
                instrEvent("decoration_request", "mode=unset");
                wsi_decoration_unset_mode(g_deco);
            }
        }
        if (instrNowUs() > g_runUsCap) // time-based: sway runs need the injection window
        {
            g_running = false;
            return;
        }
    }
    render();
}

// ------------------------------------------------------- pointer (CSD input)

extern (C) void onPointerEnter(void* data, wl_pointer* p, uint serial,
    wl_surface* surf, int sx, int sy) nothrow @nogc
{
    g_ptrX = sx / 256;
    g_ptrY = sy / 256;
    instrEvent("pointer_enter", "serial=%u pos=%d,%d", serial, g_ptrX, g_ptrY);
}

extern (C) void onPointerLeave(void* data, wl_pointer* p, uint serial, wl_surface* surf) nothrow @nogc
{
    g_zone = -99;
}

extern (C) void onPointerMotion(void* data, wl_pointer* p, uint time, int sx, int sy) nothrow @nogc
{
    g_ptrX = sx / 256;
    g_ptrY = sy / 256;
    immutable m = marginNow();
    immutable z = zoneAt(g_ptrX, g_ptrY, g_geoW + 2 * m, g_geoH + 2 * m);
    if (z != g_zone)
    {
        g_zone = z;
        instrEvent("csd_hit", "zone=%s pos=%d,%d", zoneName(z), g_ptrX, g_ptrY);
    }
}

extern (C) void onPointerButton(void* data, wl_pointer* p, uint serial, uint time,
    uint button, uint state) nothrow @nogc
{
    instrEvent("pointer_button", "serial=%u button=0x%x state=%u", serial, button, state);
    if (button != BTN_LEFT || state != WL_POINTER_BUTTON_STATE_PRESSED || !csdActive())
        return;
    immutable m = marginNow();
    immutable z = zoneAt(g_ptrX, g_ptrY, g_geoW + 2 * m, g_geoH + 2 * m);
    if (z == 100)
    {
        instrEvent("move_start", "serial=%u", serial);
        wsi_toplevel_move(g_toplevel, g_seat, serial);
    }
    else if (z >= 1 && z <= 10)
    {
        instrEvent("resize_start", "edge=%u name=%s serial=%u", cast(uint) z, zoneName(z), serial);
        wsi_toplevel_resize(g_toplevel, g_seat, serial, cast(uint) z);
    }
    else if (z == 101)
    {
        // The close box sends *nothing* on the wire — CSD close is a pure
        // client-side decision (F14 owns the vetoable-close choreography).
        instrEvent("csd_close", "note=client shutdown, no protocol request");
        g_running = false;
    }
}

extern (C) void onPointerAxis(void* data, wl_pointer* p, uint t, uint a, int v) nothrow @nogc
{
}

extern (C) void onPointerFrame(void* data, wl_pointer* p) nothrow @nogc
{
}

extern (C) void onPointerAxisSource(void* data, wl_pointer* p, uint s) nothrow @nogc
{
}

extern (C) void onPointerAxisStop(void* data, wl_pointer* p, uint t, uint a) nothrow @nogc
{
}

extern (C) void onPointerAxisDiscrete(void* data, wl_pointer* p, uint a, int d) nothrow @nogc
{
}

extern (C) void onPointerAxisValue120(void* data, wl_pointer* p, uint a, int v) nothrow @nogc
{
}

extern (C) void onPointerAxisRelDir(void* data, wl_pointer* p, uint a, uint dir) nothrow @nogc
{
}

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
        wsi_pointer_destroy(g_pointer); // capability flap (wlrctl unplug)
        g_pointer = null;
    }
}

extern (C) void onSeatName(void* data, wl_seat* s, const(char)* name) nothrow @nogc
{
}

__gshared wl_registry_listener g_registryListener = {&onGlobal, &onGlobalRemove};
__gshared xdg_wm_base_listener g_wmBaseListener = {&onWmBasePing};
__gshared wl_seat_listener g_seatListener = {&onSeatCapabilities, &onSeatName};
__gshared xdg_surface_listener g_xdgSurfaceListener = {&onXdgSurfaceConfigure};
__gshared xdg_toplevel_listener g_toplevelListener = {
    &onToplevelConfigure, &onToplevelClose,
    &onToplevelConfigureBounds, &onToplevelWmCapabilities
};
__gshared zxdg_toplevel_decoration_v1_listener g_decoListener = {&onDecorationConfigure};
__gshared wl_buffer_listener g_bufferListener = {&onBufferRelease};
__gshared wl_callback_listener g_frameListener = {&onFrameDone};
__gshared wl_pointer_listener g_pointerListener = {
    &onPointerEnter, &onPointerLeave, &onPointerMotion, &onPointerButton,
    &onPointerAxis, &onPointerFrame, &onPointerAxisSource, &onPointerAxisStop,
    &onPointerAxisDiscrete, &onPointerAxisValue120, &onPointerAxisRelDir
};

// ----------------------------------------------------------------- teardown

void teardown() nothrow @nogc
{
    foreach (ref b; g_buffers)
        if (b.handle !is null)
        {
            wsi_buffer_destroy(b.handle);
            munmap(b.pixels, b.byteSize);
        }
    if (g_frameCb !is null)
        wsi_callback_destroy(g_frameCb);
    if (g_deco !is null) // spec: "must be destroyed before its xdg_toplevel"
        wsi_decoration_destroy(g_deco);
    if (g_pointer !is null)
        wsi_pointer_destroy(g_pointer);
    if (g_toplevel !is null)
        wsi_toplevel_destroy(g_toplevel);
    if (g_xdgSurface !is null)
        wsi_xdg_surface_destroy(g_xdgSurface);
    if (g_surface !is null)
        wsi_surface_destroy(g_surface);
    if (g_decoMgr !is null)
        wsi_decoration_manager_destroy(g_decoMgr);
    if (g_wmBase !is null)
        wsi_wm_base_destroy(g_wmBase);
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

int main(string[] args)
{
    if (args.length >= 2 && args[1] == "inject")
    {
        import inject : injectMain;
        import std.conv : to;

        return injectMain(args.length > 2 ? args[2].to!int : 500,
            args.length > 3 ? args[3].to!int : 400);
    }
    instrInit("f13-deco");
    bool env(const(char)* n)
    {
        const v = getenv(n);
        return v !is null && *v == '1';
    }

    g_autoExit = env("WSI_AUTO_EXIT");
    g_forceCsd = env("WSI_FORCE_CSD");
    g_noGeometry = env("WSI_NO_GEOMETRY");
    g_noStorm = env("WSI_NO_STORM");
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
    if (g_compositor is null || g_shm is null || g_wmBase is null)
    {
        printf("SKIP: compositor lacks a required global\n");
        teardown();
        return 0;
    }
    wsi_wm_base_add_listener(g_wmBase, &g_wmBaseListener, null);

    g_surface = wsi_compositor_create_surface(g_compositor);
    g_xdgSurface = wsi_wm_base_get_xdg_surface(g_wmBase, g_surface);
    wsi_xdg_surface_add_listener(g_xdgSurface, &g_xdgSurfaceListener, null);
    g_toplevel = wsi_xdg_surface_get_toplevel(g_xdgSurface);
    wsi_toplevel_add_listener(g_toplevel, &g_toplevelListener, null);
    wsi_toplevel_set_title(g_toplevel, "wsi-f13-decorations");
    const appId = getenv("WSI_APP_ID");
    wsi_toplevel_set_app_id(g_toplevel, appId !is null ? appId : "wsi-f13-decorations");

    // Decoration negotiation MUST precede any buffer attach ("creating an
    // xdg_toplevel_decoration from an xdg_toplevel which has a buffer attached
    // or committed is a client error").
    if (g_decoMgr !is null)
    {
        g_deco = wsi_decoration_manager_get_toplevel_decoration(g_decoMgr, g_toplevel);
        wsi_decoration_add_listener(g_deco, &g_decoListener, null);
        immutable want = g_forceCsd
            ? ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE
            : ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE;
        wsi_decoration_set_mode(g_deco, want);
        instrEvent("decoration_request", "mode=%s",
            want == ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE
                ? "server_side".ptr : "client_side".ptr);
    }
    else
        instrEvent("decoration", "mode=csd source=absent"); // no global at all
    instrWindowCreated();

    wsi_surface_commit(g_surface); // mandatory no-buffer commit
    while (g_running && wl_display_dispatch(g_display) != -1)
    {
        if (g_autoExit && instrNowUs() > g_runUsCap + 2_000_000)
            g_running = false;
    }

    // Error path: a fatal protocol error (the WSI_NO_GEOMETRY probe earns one)
    // kills the connection; recover the (interface, code, id) triple.
    immutable err = wl_display_get_error(g_display);
    if (err != 0)
    {
        wl_interface* iface;
        uint id;
        immutable code = wl_display_get_protocol_error(g_display, &iface, &id);
        instrEvent("protocol_error", "errno=%d interface=%s code=%u object_id=%u",
            err, iface !is null ? iface.name : "none".ptr, code, id);
        printf("outcome: protocol error — interface=%s code=%u (connection killed)\n",
            iface !is null ? iface.name : "none".ptr, code);
        teardown();
        return 0; // the probe *expects* this; the evidence is the log
    }
    teardown();
    printf("ok: %d frames, %d commits, final mode=%s geometry=%dx%d\n",
        g_frames, g_commits, csdActive() ? "csd".ptr : "ssd".ptr, g_geoW, g_geoH);
    return 0;
}
