// F12 cursor demo — both Wayland cursor mechanisms in one binary, runtime-
// selected by the advertised globals, on top of the xdg-shell scaffold
// (../scaffold/app.d; findings: ../../scaffold.md, ../../f12-cursors.md).
//
//   (a) shape path — wp_cursor_shape_device_v1.set_shape (cursor-shape-v1):
//       the compositor owns the pixels; the client sends one enum per change.
//   (b) theme path — classic wl_pointer.set_cursor with a wl_surface the
//       client renders itself from the Xcursor theme via libwayland-cursor
//       (wl_cursor_theme_load at size × buffer-scale, animated frames driven
//       by the frame callback when the theme provides them).
//
// A 3×3 hover-zone grid switches the cursor: the 8 border zones map to the 8
// resize-edge cursors; every (re)entry into the center zone advances a cycle
// default → text → pointer(hand) → bullseye → wait. The bullseye is the
// custom-pixmap requirement: a 24×24 ARGB wl_shm image with hotspot (12,12),
// always set via wl_pointer.set_cursor (cursor-shape-v1 has no custom-image
// request — itself a finding). Every change logs `cursor_set name=… path=…`.
//
// Env knobs: WSI_FORCE_PATH=shape|theme overrides the selection;
// WSI_AUTO_EXIT=1 + WSI_RUN_MS=<ms> bound the run (./run.sh drives the
// pointer over the zones with `swaymsg seat seat0 cursor set`). If no real
// pointer focus arrives by half the run cap, the demo falls back to a blind
// request tour (serial 0) so the WAYLAND_DEBUG trace still carries the
// protocol evidence. Headless-safe: no compositor → SKIP, exit 0; a seat-less
// compositor (headless weston) still yields the registry probe + theme dump.
module app;

import c; // ImportC: wayland-client + wayland-cursor + xdg-shell/cursor-shape glue
import instrument;
import core.stdc.stdio : printf;
import core.stdc.stdlib : atoi, getenv;
import core.stdc.string : strcmp;

enum int defaultWidth = 640;
enum int defaultHeight = 480;
enum int cursorBaseSize = 24; // theme size before HiDPI scaling
enum int bullseyeSize = 24, bullseyeHot = 12;

// ------------------------------------------------------------- cursor table

enum Path
{
    shape, // wp_cursor_shape_device_v1.set_shape
    theme, // wl_pointer.set_cursor + libwayland-cursor
}

/// One logical cursor: the cursor-shape-v1 enum value, the modern (CSS/
/// cursor-spec) theme name and the legacy Xcursor fallback name.
struct CursorDef
{
    const(char)* label;
    uint shape;
    const(char)* name;
    const(char)* legacy;
}

__gshared CursorDef[12] g_defs = [
    {"default", WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT, "default", "left_ptr"},
    {"text", WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_TEXT, "text", "xterm"},
    {"pointer", WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_POINTER, "pointer", "hand1"},
    {"nw-resize", WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NW_RESIZE, "nw-resize", "top_left_corner"},
    {"n-resize", WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_N_RESIZE, "n-resize", "top_side"},
    {"ne-resize", WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NE_RESIZE, "ne-resize", "top_right_corner"},
    {"w-resize", WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_W_RESIZE, "w-resize", "left_side"},
    {"e-resize", WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_E_RESIZE, "e-resize", "right_side"},
    {"sw-resize", WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_SW_RESIZE, "sw-resize", "bottom_left_corner"},
    {"s-resize", WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_S_RESIZE, "s-resize", "bottom_side"},
    {"se-resize", WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_SE_RESIZE, "se-resize", "bottom_right_corner"},
    {"wait", WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_WAIT, "wait", "watch"},
];
enum int idxBullseye = 12; // pseudo-index: the custom pixmap cursor

// zone (row-major 0..8) → def index; center (4) cycles instead.
__gshared immutable int[9] g_zoneDef = [3, 4, 5, 6, -1, 7, 8, 9, 10];
__gshared immutable int[5] g_centerCycle = [0, 1, 2, idxBullseye, 11];

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
    wp_cursor_shape_manager_v1* g_shapeMgr;
    uint g_shapeMgrVersion;
    wp_cursor_shape_device_v1* g_shapeDev;
    wl_surface* g_surface;
    xdg_surface* g_xdgSurface;
    xdg_toplevel* g_toplevel;
    wl_callback* g_frameCb;
    wl_surface* g_cursorSurface; // theme + custom cursors render here
    wl_cursor_theme* g_theme;
    wl_buffer* g_bullseye; // 24×24 ARGB custom cursor
    void* g_bullseyeMem;
    size_t g_bullseyeBytes;

    Buffer[2] g_buffers;
    Path g_path;
    int g_width = defaultWidth, g_height = defaultHeight;
    int g_pendingWidth, g_pendingHeight;
    int g_scale = 1; // wl_surface.preferred_buffer_scale (HiDPI cursor size)
    uint g_enterSerial;
    int g_zone = -1, g_cyclePos = -1, g_currentDef = -1;
    wl_cursor* g_animCursor; // non-null while an animated theme cursor shows
    int g_animFrame;
    long g_animStartUs;
    int g_animLogged;
    bool g_haveEnter, g_seatHasPointer;
    bool g_configured, g_running = true, g_autoExit;
    long g_runUsCap = 2_500_000;
    long g_tourNextUs = -1;
    int g_tourIdx;
    int g_frames, g_commits;
}

const(char)* pathName() nothrow @nogc
{
    return g_path == Path.shape ? "shape".ptr : "theme".ptr;
}

// ------------------------------------------------------- theme + set_cursor

/// (Re)load the Xcursor theme at base size × current buffer scale — the
/// HiDPI size-selection rule the client itself must implement on this path.
void loadTheme() nothrow @nogc
{
    if (g_theme !is null)
        wl_cursor_theme_destroy(g_theme);
    immutable size = cursorBaseSize * g_scale;
    const themeName = getenv("XCURSOR_THEME");
    g_theme = wl_cursor_theme_load(themeName, size, g_shm);
    instrEvent("cursor_theme_load", "requested_size=%d base=%d scale=%d theme=%s loaded=%d",
        size, cursorBaseSize, g_scale,
        themeName !is null ? themeName : "(default)".ptr, g_theme !is null ? 1 : 0);
}

/// Look a cursor up by modern name, then by legacy Xcursor name.
wl_cursor* themeCursor(in CursorDef d, out const(char)* resolved) nothrow @nogc
{
    auto cur = wl_cursor_theme_get_cursor(g_theme, d.name);
    resolved = d.name;
    if (cur is null)
    {
        cur = wl_cursor_theme_get_cursor(g_theme, d.legacy);
        resolved = d.legacy;
    }
    return cur;
}

/// Dump every cursor the demo uses: which name resolved (modern vs legacy
/// Xcursor vocabulary) and the image size the theme picked for our size×scale.
void probeTheme() nothrow @nogc
{
    foreach (ref d; g_defs)
    {
        const(char)* resolved;
        auto cur = themeCursor(d, resolved);
        if (cur is null)
            instrEvent("cursor_probe", "name=%s resolved=MISSING", d.label);
        else
        {
            auto img = cur.images[0];
            instrEvent("cursor_probe", "name=%s resolved=%s image=%ux%u hotspot=%u,%u frames=%u",
                d.label, resolved, img.width, img.height,
                img.hotspot_x, img.hotspot_y, cur.image_count);
        }
    }
}

/// Attach one theme-cursor frame to the cursor surface (and optionally
/// (re)point the pointer at it). Hotspot is surface-local, i.e. divided by
/// the buffer scale the surface carries.
void attachFrame(wl_cursor* cur, int frame, bool setCursor, uint serial) nothrow @nogc
{
    auto img = cur.images[frame];
    auto buf = wl_cursor_image_get_buffer(img);
    wsi_surface_set_buffer_scale(g_cursorSurface, g_scale);
    wsi_surface_attach(g_cursorSurface, buf, 0, 0);
    wsi_surface_damage_buffer(g_cursorSurface, 0, 0, cast(int) img.width, cast(int) img.height);
    wsi_surface_commit(g_cursorSurface);
    if (setCursor)
        wsi_pointer_set_cursor(g_pointer, serial, g_cursorSurface,
            cast(int) img.hotspot_x / g_scale, cast(int) img.hotspot_y / g_scale);
}

bool ensureBullseye() nothrow @nogc
{
    if (g_bullseye !is null)
        return true;
    enum stride = bullseyeSize * 4;
    enum size = cast(size_t) stride * bullseyeSize;
    immutable fd = memfd_create("wsi-f12-bullseye", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, size) != 0)
        return false;
    uint* px = cast(uint*) mmap(null, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (px is cast(uint*)-1)
    {
        close(fd);
        return false;
    }
    foreach (y; 0 .. bullseyeSize) // concentric red/white rings, transparent corners
        foreach (x; 0 .. bullseyeSize)
        {
            immutable dx = x - bullseyeHot, dy = y - bullseyeHot;
            immutable r2 = dx * dx + dy * dy;
            uint c = 0;
            if (r2 <= 144) // radius 12
                c = ((r2 <= 9) || (r2 > 36 && r2 <= 81)) ? 0xffff2020 : 0xffffffff;
            px[y * bullseyeSize + x] = c;
        }
    wl_shm_pool* pool = wsi_shm_create_pool(g_shm, fd, cast(int) size);
    g_bullseye = wsi_shm_pool_create_buffer(pool, 0, bullseyeSize, bullseyeSize,
        stride, WL_SHM_FORMAT_ARGB8888);
    wsi_shm_pool_destroy(pool);
    close(fd);
    g_bullseyeMem = px;
    g_bullseyeBytes = size;
    return true;
}

/// The single entry point every zone change funnels into.
void applyCursor(int idx, uint serial) nothrow @nogc
{
    if (g_pointer is null)
        return;
    g_currentDef = idx;
    g_animCursor = null;
    if (idx == idxBullseye)
    {
        if (g_pointer is null || !ensureBullseye())
            return;
        // Custom pixmaps have no shape enum: even on the shape path this goes
        // through classic set_cursor. Mixing both on one wl_pointer is legal —
        // the latest request wins.
        wsi_surface_set_buffer_scale(g_cursorSurface, 1);
        wsi_surface_attach(g_cursorSurface, g_bullseye, 0, 0);
        wsi_surface_damage_buffer(g_cursorSurface, 0, 0, bullseyeSize, bullseyeSize);
        wsi_surface_commit(g_cursorSurface);
        wsi_pointer_set_cursor(g_pointer, serial, g_cursorSurface, bullseyeHot, bullseyeHot);
        instrEvent("cursor_set", "name=bullseye path=custom size=%dx%d hotspot=%d,%d serial=%u",
            bullseyeSize, bullseyeSize, bullseyeHot, bullseyeHot, serial);
        return;
    }
    auto d = &g_defs[idx];
    if (g_path == Path.shape)
    {
        if (g_shapeDev is null)
            return; // no pointer yet → no shape device yet
        wsi_cursor_shape_set_shape(g_shapeDev, serial, d.shape);
        instrEvent("cursor_set", "name=%s path=shape shape_enum=%u serial=%u",
            d.label, d.shape, serial);
        return;
    }
    const(char)* resolved;
    auto cur = themeCursor(*d, resolved);
    if (cur is null)
    {
        instrEvent("cursor_set", "name=%s path=theme MISSING", d.label);
        return;
    }
    attachFrame(cur, 0, true, serial);
    auto img = cur.images[0];
    instrEvent("cursor_set", "name=%s path=theme resolved=%s image=%ux%u hotspot=%u,%u frames=%u serial=%u",
        d.label, resolved, img.width, img.height, img.hotspot_x, img.hotspot_y,
        cur.image_count, serial);
    if (cur.image_count > 1) // animated: frames advance on the frame clock
    {
        g_animCursor = cur;
        g_animFrame = 0;
        g_animStartUs = instrNowUs();
        g_animLogged = 0;
    }
}

void enterZone(int zone, uint serial) nothrow @nogc
{
    g_zone = zone;
    int idx = g_zoneDef[zone];
    if (idx < 0) // center: advance the cycle on every (re)entry
    {
        g_cyclePos = (g_cyclePos + 1) % cast(int) g_centerCycle.length;
        idx = g_centerCycle[g_cyclePos];
    }
    instrEvent("zone", "zone=%d cursor=%s", zone,
        idx == idxBullseye ? "bullseye".ptr : g_defs[idx].label);
    applyCursor(idx, serial);
}

// ---------------------------------------------------------------- listeners

extern (C) void onPointerEnter(void* data, wl_pointer* p, uint serial,
    wl_surface* surf, int sx, int sy) nothrow @nogc
{
    g_enterSerial = serial;
    g_haveEnter = true;
    immutable x = sx / 256, y = sy / 256;
    instrEvent("pointer_enter", "serial=%u pos=%d,%d", serial, x, y);
    // The contract: the cursor is UNDEFINED on enter; the client must set it
    // now (with this serial) or it keeps whatever the previous client left.
    immutable zone = (y * 3 / (g_height < 1 ? 1 : g_height)) * 3
        + (x * 3 / (g_width < 1 ? 1 : g_width));
    enterZone(zone < 0 ? 0 : (zone > 8 ? 8 : zone), serial);
}

extern (C) void onPointerLeave(void* data, wl_pointer* p, uint serial, wl_surface* surf) nothrow @nogc
{
    instrEvent("pointer_leave", "serial=%u", serial);
    g_zone = -1;
}

extern (C) void onPointerMotion(void* data, wl_pointer* p, uint time, int sx, int sy) nothrow @nogc
{
    immutable x = sx / 256, y = sy / 256;
    immutable zone = (y * 3 / (g_height < 1 ? 1 : g_height)) * 3
        + (x * 3 / (g_width < 1 ? 1 : g_width));
    immutable clamped = zone < 0 ? 0 : (zone > 8 ? 8 : zone);
    if (clamped != g_zone)
        enterZone(clamped, g_enterSerial);
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
    instrEvent("seat_capabilities", "caps=%u pointer=%d keyboard=%d", caps,
        hasPointer ? 1 : 0, (caps & WL_SEAT_CAPABILITY_KEYBOARD) ? 1 : 0);
    if (hasPointer && g_pointer is null)
    {
        g_seatHasPointer = true;
        g_pointer = wsi_seat_get_pointer(g_seat);
        wsi_pointer_add_listener(g_pointer, &g_pointerListener, null);
        if (g_shapeMgr !is null)
            g_shapeDev = wsi_cursor_shape_get_pointer(g_shapeMgr, g_pointer);
    }
    else if (!hasPointer && g_pointer !is null)
    {
        // The capability went away (e.g. the wlrctl virtual pointer was
        // unplugged). The spec: "When the capability is regained, a client
        // should create the new objects" — the old resource stays inert, so
        // destroy it now and re-create on the next capabilities event.
        if (g_shapeDev !is null)
            wsi_cursor_shape_device_destroy(g_shapeDev);
        g_shapeDev = null;
        wsi_pointer_destroy(g_pointer);
        g_pointer = null;
        instrEvent("pointer_dropped", "note=capability removed; proxies destroyed");
    }
}

extern (C) void onSeatName(void* data, wl_seat* s, const(char)* name) nothrow @nogc {}

extern (C) void onPreferredBufferScale(void* data, wl_surface* s, int factor) nothrow @nogc
{
    if (factor == g_scale)
        return;
    g_scale = factor;
    instrEvent("preferred_buffer_scale", "factor=%d", factor);
    if (g_path == Path.theme)
    {
        loadTheme(); // HiDPI: reload at base × scale, then re-apply live
        if (g_currentDef >= 0 && g_currentDef != idxBullseye && g_haveEnter)
            applyCursor(g_currentDef, g_enterSerial);
    }
}

extern (C) void onSurfaceEnter(void* data, wl_surface* s, wl_output* o) nothrow @nogc {}

extern (C) void onSurfaceLeave(void* data, wl_surface* s, wl_output* o) nothrow @nogc {}

extern (C) void onPreferredBufferTransform(void* data, wl_surface* s, uint t) nothrow @nogc {}

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
    else if (strcmp(iface, wp_cursor_shape_manager_v1_interface.name) == 0)
    {
        g_shapeMgrVersion = ver;
        g_shapeMgr = cast(wp_cursor_shape_manager_v1*) wsi_registry_bind(reg, name,
            &wp_cursor_shape_manager_v1_interface, capped(ver, 1));
    }
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
    immutable fd = memfd_create("wsi-f12", MFD_CLOEXEC);
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
        return;
    if (!ensureBuffer(*buf, g_width, g_height))
        return;
    foreach (y; 0 .. buf.height) // shade the 3×3 zones so the grid has eyes-appeal
        foreach (x; 0 .. buf.width)
        {
            immutable zone = (y * 3 / buf.height) * 3 + (x * 3 / buf.width);
            immutable g = cast(uint)(0x30 + zone * 0x14);
            buf.pixels[cast(size_t) y * buf.width + x] = 0xff000000 | (g << 16) | (g << 8) | g;
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
    // Animated theme cursor: the client owns the animation timer. We ride the
    // window's frame clock; wl_cursor_frame_and_duration picks the frame.
    if (g_animCursor !is null && g_path == Path.theme)
    {
        uint dur;
        immutable ms = cast(uint)((instrNowUs() - g_animStartUs) / 1000);
        immutable frame = wl_cursor_frame_and_duration(g_animCursor, ms, &dur);
        if (frame != g_animFrame)
        {
            g_animFrame = frame;
            attachFrame(g_animCursor, frame, false, 0);
            if (g_animLogged < 4)
            {
                g_animLogged++;
                instrEvent("cursor_frame", "index=%d duration_ms=%u t_ms=%u", frame, dur, ms);
            }
        }
    }
    render();
}

__gshared wl_registry_listener g_registryListener = {&onGlobal, &onGlobalRemove};
__gshared wl_seat_listener g_seatListener = {&onSeatCapabilities, &onSeatName};
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
    instrInit("f12_wayland");
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
    instrEvent("cursor_shape_v1", "offered=%d version=%u seat=%d pointer=%d",
        g_shapeMgr !is null ? 1 : 0, g_shapeMgrVersion,
        g_seat !is null ? 1 : 0, g_seatHasPointer ? 1 : 0);

    const force = getenv("WSI_FORCE_PATH");
    g_path = g_shapeMgr !is null ? Path.shape : Path.theme;
    if (force !is null && strcmp(force, "theme") == 0)
        g_path = Path.theme;
    if (force !is null && strcmp(force, "shape") == 0 && g_shapeMgr is null)
    {
        printf("SKIP: shape path forced but wp_cursor_shape_manager_v1 missing\n");
        wl_display_disconnect(g_display);
        return 0;
    }
    instrEvent("path_selected", "path=%s", pathName());

    // Theme machinery loads on both paths: the probe is part of the findings,
    // and the bullseye/theme fallback needs the cursor surface anyway.
    loadTheme();
    if (g_theme !is null)
        probeTheme();

    if (g_seat is null)
    {
        // headless weston: no seat at all. The registry probe + theme dump
        // above are still the Tier-A evidence; cursors need a pointer.
        printf("ok: no seat on this compositor; registry+theme probe only\n");
        wl_display_disconnect(g_display);
        return 0;
    }
    // A seat with capabilities=0 (headless sway, no input devices) may gain
    // the pointer capability later — e.g. when `wlrctl` plugs a
    // zwlr_virtual_pointer in (./run.sh does exactly that). get_pointer
    // before the capability exists is a hard wlroots protocol error
    // ("wl_seat.get_pointer called when no pointer capability has existed"),
    // so the demo strictly waits for the capabilities event.

    wsi_wm_base_add_listener(g_wmBase, &g_wmBaseListener, null);
    g_surface = wsi_compositor_create_surface(g_compositor);
    wsi_surface_add_listener(g_surface, &g_surfaceListener, null);
    g_cursorSurface = wsi_compositor_create_surface(g_compositor);
    g_xdgSurface = wsi_wm_base_get_xdg_surface(g_wmBase, g_surface);
    wsi_xdg_surface_add_listener(g_xdgSurface, &g_xdgSurfaceListener, null);
    g_toplevel = wsi_xdg_surface_get_toplevel(g_xdgSurface);
    wsi_toplevel_add_listener(g_toplevel, &g_toplevelListener, null);
    wsi_toplevel_set_title(g_toplevel, "wsi-f12-cursors");
    wsi_toplevel_set_app_id(g_toplevel, "wsi-f12-cursors");
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
        // Blind request tour: if no real pointer focus arrived by half the
        // cap, issue every cursor request anyway (serial 0) so WAYLAND_DEBUG
        // still records the full protocol exchange. Pixels-need-eyes is
        // Tier C either way; this keeps the request side Tier A.
        if (g_autoExit && g_pointer !is null && !g_haveEnter
            && g_tourIdx <= idxBullseye && instrNowUs() > g_runUsCap / 2)
        {
            if (g_tourNextUs < 0)
                instrEvent("tour", "mode=blind serial=0 note=requests-only");
            if (instrNowUs() >= g_tourNextUs)
            {
                applyCursor(g_tourIdx++, 0);
                g_tourNextUs = instrNowUs() + 150_000;
            }
        }
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
    if (g_bullseye !is null)
    {
        wsi_buffer_destroy(g_bullseye);
        munmap(g_bullseyeMem, g_bullseyeBytes);
    }
    if (g_theme !is null)
        wl_cursor_theme_destroy(g_theme);
    if (g_frameCb !is null)
        wsi_callback_destroy(g_frameCb);
    if (g_shapeDev !is null)
        wsi_cursor_shape_device_destroy(g_shapeDev);
    if (g_shapeMgr !is null)
        wsi_cursor_shape_manager_destroy(g_shapeMgr);
    if (g_pointer !is null)
        wsi_pointer_destroy(g_pointer);
    if (g_seat !is null)
        wsi_seat_destroy(g_seat);
    wsi_toplevel_destroy(g_toplevel);
    wsi_xdg_surface_destroy(g_xdgSurface);
    wsi_surface_destroy(g_cursorSurface);
    wsi_surface_destroy(g_surface);
    wsi_wm_base_destroy(g_wmBase);
    wl_proxy_destroy(cast(wl_proxy*) g_shm);
    wl_proxy_destroy(cast(wl_proxy*) g_compositor);
    wl_proxy_destroy(cast(wl_proxy*) g_registry);
    wl_display_disconnect(g_display);

    printf("ok: frames=%d commits=%d path=%s zones_visited_last=%d\n",
        g_frames, g_commits, pathName(), g_zone);
    return 0;
}
