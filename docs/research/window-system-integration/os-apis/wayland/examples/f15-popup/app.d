// F15 popup demo — xdg_popup + xdg_positioner + xdg_popup.grab on top of the
// xdg-shell scaffold (../scaffold/app.d; findings: ../../f15-popup.md).
//
// Four choreographed scenarios, selected by WSI_SCENARIO (input injected by
// ./run.sh through this binary's own `inject` mode — one zwlr_virtual_pointer
// device held across a WHOLE scenario, see ./inject.d):
//
//   menu     right-click opens a 3-item context menu: xdg_positioner with a
//            1x1 anchor rect at the click, gravity bottom_right,
//            constraint_adjustment slide|flip, then xdg_popup.grab with the
//            press serial. Hover highlight from wl_pointer.motion; a
//            reposition probe (xdg_popup v3 reposition/repositioned) fires
//            350 ms after the popup maps; clicking item 2 ("submenu >")
//            opens a NESTED popup parented on the first (the protocol
//            requires the chain) with its own grab; a click OUTSIDE the
//            window then dismisses — the compositor decides, the client only
//            receives xdg_popup.popup_done (topmost first: measured).
//   edge     same right-click menu, but the window sits at the output's
//            bottom-right corner so the requested placement is constrained —
//            the xdg_popup.configure x/y is the COMPOSITOR's solution
//            (slide? flip?); dismissal is Esc, delivered on the grab's
//            wl_keyboard (wtype plugs a virtual keyboard in; libxkbcommon
//            decodes its generated keymap).
//   stale    xdg_popup.grab with serial=1 when NO input event ever happened —
//            what does the compositor do with an invalid grab serial?
//            (protocol error? immediate popup_done? silent grant?) Measured.
//   noinput  headless-weston baseline (no seat → no serial → no grab):
//            plain popup + nested popup + reposition, logging the
//            positioner-solved placements only.
//
// Headless-safe: no compositor → SKIP, exit 0.
module app;

import c; // ImportC: wayland-client + xdg-shell glue + xkbcommon + poll
import instrument;
import core.stdc.stdio : printf;
import core.stdc.stdlib : atoi, getenv;
import core.stdc.string : strcmp;

enum int mainWidth = 640;
enum int mainHeight = 480;
enum uint BTN_LEFT = 0x110, BTN_RIGHT = 0x111;

// Menu geometry (also hardcoded in ./inject.d and ./run.sh — keep in sync).
enum int p1W = 160, p1H = 96; // popup1: 3 items
enum int p2W = 140, p2H = 64; // popup2 (submenu): 2 items
enum int itemX = 4, itemW = 152, itemY0 = 6, itemStep = 28, itemH = 26;

enum Scenario
{
    noinput,
    menu,
    edge,
    stale,
}

__gshared immutable(char*)[4] g_scenarioNames = ["noinput", "menu", "edge", "stale"];

// -------------------------------------------------------------------- state

struct Buffer
{
    wl_buffer* handle;
    uint* pixels;
    size_t byteSize;
    int width, height;
    bool busy;
}

/// One wl_surface with either the toplevel or a popup role.
struct Surf
{
    wl_surface* surface;
    xdg_surface* xdgSurface;
    xdg_toplevel* toplevel;
    xdg_popup* popup;
    Buffer[2] buffers;
    int width, height;
    int items; // popup menu item count (0 for the toplevel)
    int hoverItem = -1;
    bool configured;
}

enum size_t IDX_MAIN = 0, IDX_POPUP1 = 1, IDX_POPUP2 = 2;
__gshared immutable(char*)[3] g_surfNames = ["main", "popup1", "popup2"];

__gshared
{
    wl_display* g_display;
    wl_registry* g_registry;
    wl_compositor* g_compositor;
    wl_shm* g_shm;
    xdg_wm_base* g_wmBase;
    uint g_wmBaseVersion;
    wl_seat* g_seat;
    wl_pointer* g_pointer;
    wl_keyboard* g_keyboard;
    wl_callback* g_frameCb;
    xkb_context* g_xkbCtx;
    xkb_keymap* g_xkbKeymap;
    xkb_state* g_xkbState;

    Surf[3] g_surfs;
    Scenario g_scenario = Scenario.noinput;
    int g_focusIdx = -1; // pointer-focused surf index, -1 = none of ours
    double g_ptrX, g_ptrY; // surface-local, on g_focusIdx
    int g_pendingW, g_pendingH; // toplevel configure
    bool g_running = true, g_autoExit;
    long g_runUsCap = 2_500_000;
    long g_firstPaintUs = -1; // epoch for the noinput/stale step machine
    long g_repositionAtUs = -1; // menu/edge: scheduled after popup1 maps
    bool g_repositionSent, g_grabUsed;
    int g_step; // noinput/stale step machine
    int g_doneEvents; // popup_done counter (dismissal ORDER evidence)
    int g_frames;
    bool g_staleConfigured, g_staleDone;
}

// ------------------------------------------------------------------ popups

/// Create popup `idx` with the given positioner recipe, optionally grabbing
/// with `grabSerial` (>= 0). The initial commit carries no buffer (the
/// configure/ack contract applies to popups exactly as to toplevels).
void openPopup(size_t idx, size_t parentIdx, int ax, int ay, int aw, int ah,
    uint anchor, uint gravity, uint adjustment, int w, int h, long grabSerial,
    const(char)* note) nothrow @nogc
{
    Surf* s = &g_surfs[idx];
    s.width = w;
    s.height = h;
    s.items = idx == IDX_POPUP2 ? 2 : 3;
    s.hoverItem = -1;
    s.configured = false;
    xdg_positioner* pos = wsi_wm_base_create_positioner(g_wmBase);
    wsi_positioner_set_size(pos, w, h);
    wsi_positioner_set_anchor_rect(pos, ax, ay, aw, ah);
    wsi_positioner_set_anchor(pos, anchor);
    wsi_positioner_set_gravity(pos, gravity);
    wsi_positioner_set_constraint_adjustment(pos, adjustment);
    if (g_wmBaseVersion >= 3)
        wsi_positioner_set_reactive(pos); // auto-reposition on env change (v3)
    s.surface = wsi_compositor_create_surface(g_compositor);
    s.xdgSurface = wsi_wm_base_get_xdg_surface(g_wmBase, s.surface);
    wsi_xdg_surface_add_listener(s.xdgSurface, &g_xdgSurfaceListener, cast(void*) idx);
    s.popup = wsi_xdg_surface_get_popup(s.xdgSurface, g_surfs[parentIdx].xdgSurface, pos);
    wsi_popup_add_listener(s.popup, &g_popupListener, cast(void*) idx);
    wsi_positioner_destroy(pos);
    instrEvent("popup_open",
        "idx=%s parent=%s anchor_rect=%d,%d %dx%d anchor=%u gravity=%u adjustment=%u size=%dx%d note=%s",
        g_surfNames[idx], g_surfNames[parentIdx], ax, ay, aw, ah,
        anchor, gravity, adjustment, w, h, note);
    if (grabSerial >= 0)
    {
        wsi_popup_grab(s.popup, g_seat, cast(uint) grabSerial);
        g_grabUsed = true;
        instrEvent("grab", "idx=%s serial=%lld state=requested", g_surfNames[idx], grabSerial);
    }
    wsi_surface_commit(s.surface); // mandatory no-buffer first commit
}

/// Client-side dismissal (item click / Esc): topmost first, per the chain
/// rule ("they must be destroyed in the reverse order they were created in").
void dismissPopups(const(char)* cause) nothrow @nogc
{
    foreach_reverse (idx; IDX_POPUP1 .. g_surfs.length)
        if (g_surfs[idx].popup !is null)
        {
            instrEvent("popup_dismiss", "idx=%s cause=%s", g_surfNames[idx], cause);
            destroyPopup(idx);
        }
}

void destroyPopup(size_t idx) nothrow @nogc
{
    Surf* s = &g_surfs[idx];
    if (s.popup is null)
        return;
    wsi_popup_destroy(s.popup);
    wsi_xdg_surface_destroy(s.xdgSurface);
    wsi_surface_destroy(s.surface);
    foreach (ref b; s.buffers)
        if (b.handle !is null)
        {
            wsi_buffer_destroy(b.handle);
            munmap(b.pixels, b.byteSize);
            b = Buffer.init;
        }
    s.popup = null;
    s.xdgSurface = null;
    s.surface = null;
    if (g_focusIdx == cast(int) idx)
        g_focusIdx = -1;
}

/// The right-click menu (popup1). Anchor: 1x1 rect at the click position,
/// anchor point its bottom-right corner, gravity bottom_right ("down-right
/// of the cursor"), constraint_adjustment slide|flip on both axes.
void openMenu(int clickX, int clickY, long serial) nothrow @nogc
{
    enum uint adj = XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_X
        | XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_Y
        | XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_X
        | XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_Y;
    openPopup(IDX_POPUP1, IDX_MAIN, clickX, clickY, 1, 1,
        XDG_POSITIONER_ANCHOR_BOTTOM_RIGHT, XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT,
        adj, p1W, p1H, serial, "context-menu");
}

/// The submenu (popup2), parented on POPUP1 — the chain the protocol
/// requires for a second grabbing popup. Anchored to item 2's rect, opening
/// to the right; flip_x so a constrained edge would mirror it to the left.
void openSubmenu(long serial) nothrow @nogc
{
    enum uint adj = XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_X
        | XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_Y;
    openPopup(IDX_POPUP2, IDX_POPUP1, itemX, itemY0 + 2 * itemStep, itemW, itemH,
        XDG_POSITIONER_ANCHOR_TOP_RIGHT, XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT,
        adj, p2W, p2H, serial, "submenu");
}

extern (C) void onPopupConfigure(void* data, xdg_popup* p, int x, int y, int w, int h) nothrow @nogc
{
    immutable idx = cast(size_t) data;
    // x/y are "relative to the upper left corner of the window geometry of
    // the parent surface" — this is the compositor's placement DECISION,
    // not an echo of the request.
    instrEvent("popup_placed", "idx=%s x=%d y=%d size=%dx%d",
        g_surfNames[idx], x, y, w, h);
    if (w > 0 && h > 0)
    {
        g_surfs[idx].width = w;
        g_surfs[idx].height = h;
    }
    if (idx == IDX_POPUP1 && g_scenario == Scenario.stale)
        g_staleConfigured = true;
    // Schedule the explicit-reposition probe once the menu has mapped.
    if (idx == IDX_POPUP1 && !g_repositionSent && g_repositionAtUs < 0
        && g_scenario != Scenario.edge && g_wmBaseVersion >= 3)
        g_repositionAtUs = instrNowUs() + 350_000;
}

extern (C) void onPopupDone(void* data, xdg_popup* p) nothrow @nogc
{
    immutable idx = cast(size_t) data;
    g_doneEvents++;
    // The compositor dismissed us; the client merely cleans up. The ORDER of
    // these events across the chain is the topmost-first evidence.
    instrEvent("popup_dismiss", "idx=%s cause=popup_done order=%d",
        g_surfNames[idx], g_doneEvents);
    if (idx == IDX_POPUP1 && g_scenario == Scenario.stale)
        g_staleDone = true;
    destroyPopup(idx);
}

extern (C) void onPopupRepositioned(void* data, xdg_popup* p, uint token) nothrow @nogc
{
    instrEvent("repositioned", "idx=%s token=%u", g_surfNames[cast(size_t) data], token);
}

__gshared xdg_popup_listener g_popupListener = {
    &onPopupConfigure, &onPopupDone, &onPopupRepositioned
};

/// The v3 explicit-reposition probe: a fresh positioner (same recipe,
/// +24/+16 offset), xdg_popup.reposition(token=7) → expect repositioned(7)
/// followed by a new popup configure.
void sendReposition() nothrow @nogc
{
    Surf* s = &g_surfs[IDX_POPUP1];
    if (s.popup is null)
        return;
    xdg_positioner* pos = wsi_wm_base_create_positioner(g_wmBase);
    wsi_positioner_set_size(pos, p1W, p1H);
    wsi_positioner_set_anchor_rect(pos, 180, 180, 1, 1);
    wsi_positioner_set_anchor(pos, XDG_POSITIONER_ANCHOR_BOTTOM_RIGHT);
    wsi_positioner_set_gravity(pos, XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT);
    wsi_positioner_set_constraint_adjustment(pos,
        XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_X
        | XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_Y);
    wsi_positioner_set_offset(pos, 24, 16);
    wsi_positioner_set_reactive(pos);
    wsi_popup_reposition(s.popup, pos, 7);
    wsi_positioner_destroy(pos);
    g_repositionSent = true;
    instrEvent("reposition_request", "idx=popup1 token=7 offset=24,16");
}

// ----------------------------------------------------------------- pointer

int surfIndexOf(wl_surface* s) nothrow @nogc
{
    foreach (i, ref sf; g_surfs)
        if (sf.surface is s)
            return cast(int) i;
    return -1;
}

int itemAt(size_t idx, double x, double y) nothrow @nogc
{
    if (x < itemX || x >= itemX + itemW)
        return -1;
    foreach (i; 0 .. g_surfs[idx].items)
    {
        immutable top = itemY0 + i * itemStep;
        if (y >= top && y < top + itemH)
            return i;
    }
    return -1;
}

extern (C) void onPointerEnter(void* data, wl_pointer* p, uint serial,
    wl_surface* surf, int sx, int sy) nothrow @nogc
{
    g_focusIdx = surfIndexOf(surf);
    g_ptrX = sx / 256.0;
    g_ptrY = sy / 256.0;
    instrEvent("pointer_enter", "surface=%s serial=%u pos=%.1f,%.1f",
        g_focusIdx >= 0 ? g_surfNames[g_focusIdx] : "other", serial, g_ptrX, g_ptrY);
    if (g_focusIdx > 0)
    {
        immutable item = itemAt(g_focusIdx, g_ptrX, g_ptrY);
        if (item != g_surfs[g_focusIdx].hoverItem)
        {
            g_surfs[g_focusIdx].hoverItem = item;
            instrEvent("hover", "idx=%s item=%d", g_surfNames[g_focusIdx], item);
            render(g_focusIdx);
        }
    }
}

extern (C) void onPointerLeave(void* data, wl_pointer* p, uint serial, wl_surface* surf) nothrow @nogc
{
    immutable idx = surfIndexOf(surf);
    instrEvent("pointer_leave", "surface=%s serial=%u",
        idx >= 0 ? g_surfNames[idx] : "other", serial);
    if (idx >= 0 && g_surfs[idx].popup !is null && g_surfs[idx].hoverItem != -1)
    {
        g_surfs[idx].hoverItem = -1;
        render(idx);
    }
    g_focusIdx = -1;
}

extern (C) void onPointerMotion(void* data, wl_pointer* p, uint time, int sx, int sy) nothrow @nogc
{
    g_ptrX = sx / 256.0;
    g_ptrY = sy / 256.0;
    if (g_focusIdx <= 0)
        return;
    Surf* s = &g_surfs[g_focusIdx];
    immutable item = itemAt(g_focusIdx, g_ptrX, g_ptrY);
    if (item != s.hoverItem)
    {
        s.hoverItem = item;
        instrEvent("hover", "idx=%s item=%d", g_surfNames[g_focusIdx], item);
        render(g_focusIdx);
    }
}

extern (C) void onPointerButton(void* data, wl_pointer* p, uint serial, uint time,
    uint button, uint state) nothrow @nogc
{
    instrEvent("button", "surface=%s serial=%u button=0x%x state=%u",
        g_focusIdx >= 0 ? g_surfNames[g_focusIdx] : "none", serial, button, state);
    if (state != WL_POINTER_BUTTON_STATE_PRESSED)
        return;
    if (g_focusIdx == IDX_MAIN && button == BTN_RIGHT && g_surfs[IDX_POPUP1].popup is null)
    {
        openMenu(cast(int) g_ptrX, cast(int) g_ptrY, serial);
        return;
    }
    if (g_focusIdx == IDX_POPUP1 && button == BTN_LEFT)
    {
        immutable item = g_surfs[IDX_POPUP1].hoverItem;
        if (item == 2 && g_surfs[IDX_POPUP2].popup is null)
            openSubmenu(serial); // nested grab: parent must be the grabbed popup
        else if (item >= 0)
        {
            instrEvent("item_activated", "idx=popup1 item=%d", item);
            dismissPopups("item-click");
        }
        return;
    }
    if (g_focusIdx == IDX_POPUP2 && button == BTN_LEFT)
    {
        instrEvent("item_activated", "idx=popup2 item=%d", g_surfs[IDX_POPUP2].hoverItem);
        dismissPopups("item-click");
        return;
    }
    // A press on the parent window while a grab is held: does the grab route
    // it here at all, and does the compositor treat "inside the same client
    // but outside the popups" as outside? Logged either way (finding).
    if (g_focusIdx == IDX_MAIN && g_surfs[IDX_POPUP1].popup !is null)
        instrEvent("button_on_parent_during_grab", "serial=%u button=0x%x", serial, button);
}

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

// ---------------------------------------------------------------- keyboard

extern (C) void onKeymap(void* data, wl_keyboard* kb, uint format, int fd, uint size) nothrow @nogc
{
    instrEvent("keymap", "format=%u size=%u", format, size);
    if (format == WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1)
    {
        void* mem = mmap(null, size, PROT_READ, MAP_PRIVATE, fd, 0);
        if (mem !is cast(void*)-1)
        {
            if (g_xkbKeymap !is null)
                xkb_keymap_unref(g_xkbKeymap);
            if (g_xkbState !is null)
                xkb_state_unref(g_xkbState);
            g_xkbKeymap = xkb_keymap_new_from_string(g_xkbCtx, cast(char*) mem,
                XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
            g_xkbState = g_xkbKeymap !is null ? xkb_state_new(g_xkbKeymap) : null;
            munmap(mem, size);
        }
    }
    close(fd);
}

extern (C) void onKeyboardEnter(void* data, wl_keyboard* kb, uint serial,
    wl_surface* surf, wl_array* keys) nothrow @nogc
{
    // Under an xdg_popup.grab the keyboard focus must land on the POPUP —
    // this line is the proof of where the grab routed it.
    immutable idx = surfIndexOf(surf);
    instrEvent("keyboard_enter", "surface=%s serial=%u",
        idx >= 0 ? g_surfNames[idx] : "other", serial);
}

extern (C) void onKeyboardLeave(void* data, wl_keyboard* kb, uint serial, wl_surface* surf) nothrow @nogc
{
    immutable idx = surfIndexOf(surf);
    instrEvent("keyboard_leave", "surface=%s serial=%u",
        idx >= 0 ? g_surfNames[idx] : "other", serial);
}

extern (C) void onKey(void* data, wl_keyboard* kb, uint serial, uint time,
    uint key, uint state) nothrow @nogc
{
    uint sym = 0;
    if (g_xkbState !is null)
        sym = xkb_state_key_get_one_sym(g_xkbState, key + 8);
    instrEvent("key", "key=%u keysym=0x%x state=%u", key, sym, state);
    if (state == WL_KEYBOARD_KEY_STATE_PRESSED && sym == XKB_KEY_Escape
        && g_surfs[IDX_POPUP1].popup !is null)
        dismissPopups("esc-grab-keyboard");
}

extern (C) void onModifiers(void* data, wl_keyboard* kb, uint serial,
    uint depressed, uint latched, uint locked, uint group) nothrow @nogc
{
    if (g_xkbState !is null)
        xkb_state_update_mask(g_xkbState, depressed, latched, locked, 0, 0, group);
}

extern (C) void onRepeatInfo(void* data, wl_keyboard* kb, int rate, int delay) nothrow @nogc {}

__gshared wl_keyboard_listener g_keyboardListener = {
    &onKeymap, &onKeyboardEnter, &onKeyboardLeave, &onKey, &onModifiers, &onRepeatInfo
};

// ------------------------------------------------------------------- seat

extern (C) void onSeatCapabilities(void* data, wl_seat* s, uint caps) nothrow @nogc
{
    instrEvent("seat_capabilities", "caps=%u", caps);
    immutable hasPointer = (caps & WL_SEAT_CAPABILITY_POINTER) != 0;
    immutable hasKeyboard = (caps & WL_SEAT_CAPABILITY_KEYBOARD) != 0;
    if (hasPointer && g_pointer is null)
    {
        g_pointer = wsi_seat_get_pointer(g_seat);
        wsi_pointer_add_listener(g_pointer, &g_pointerListener, null);
    }
    else if (!hasPointer && g_pointer !is null)
    {
        wsi_pointer_destroy(g_pointer);
        g_pointer = null;
        g_focusIdx = -1;
        // Does the device unplug (capability drop) dismiss an active grab
        // popup? Whatever follows this line in the log is the answer.
        instrEvent("pointer_dropped", "popup1_open=%d popup2_open=%d",
            g_surfs[IDX_POPUP1].popup !is null ? 1 : 0,
            g_surfs[IDX_POPUP2].popup !is null ? 1 : 0);
    }
    if (hasKeyboard && g_keyboard is null)
    {
        g_keyboard = wsi_seat_get_keyboard(g_seat);
        wsi_keyboard_add_listener(g_keyboard, &g_keyboardListener, null);
    }
    else if (!hasKeyboard && g_keyboard !is null)
    {
        wsi_keyboard_destroy(g_keyboard);
        g_keyboard = null;
    }
}

extern (C) void onSeatName(void* data, wl_seat* s, const(char)* name) nothrow @nogc {}

__gshared wl_seat_listener g_seatListener = {&onSeatCapabilities, &onSeatName};

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
    {
        // v3+ unlocks xdg_popup.reposition/repositioned and set_reactive.
        g_wmBaseVersion = capped(ver, 5);
        g_wmBase = cast(xdg_wm_base*) wsi_registry_bind(reg, name,
            &xdg_wm_base_interface, g_wmBaseVersion);
    }
    else if (strcmp(iface, wl_seat_interface.name) == 0 && g_seat is null)
    {
        g_seat = cast(wl_seat*) wsi_registry_bind(reg, name, &wl_seat_interface, capped(ver, 5));
        wsi_seat_add_listener(g_seat, &g_seatListener, null);
    }
}

extern (C) void onGlobalRemove(void* data, wl_registry* reg, uint name) nothrow @nogc {}

__gshared wl_registry_listener g_registryListener = {&onGlobal, &onGlobalRemove};

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
    immutable fd = memfd_create("wsi-f15", MFD_CLOEXEC);
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

/// Paint surf `idx`: flat background for the main window; solid menu panel
/// with item rows + hover highlight for popups. Event-driven redraw only
/// (no frame-callback loop — popups repaint on hover changes).
void render(size_t idx) nothrow @nogc
{
    Surf* s = &g_surfs[idx];
    if (s.surface is null || !s.configured)
        return;
    Buffer* buf = null;
    foreach (ref b; s.buffers)
        if (!b.busy)
        {
            buf = &b;
            break;
        }
    if (buf is null || !ensureBuffer(*buf, s.width, s.height))
        return;
    immutable uint bg = idx == IDX_MAIN ? 0xff20283c : 0xff3a3a44;
    foreach (y; 0 .. buf.height)
        foreach (x; 0 .. buf.width)
        {
            uint c = bg;
            if (idx != IDX_MAIN)
            {
                if (x == 0 || y == 0 || x == buf.width - 1 || y == buf.height - 1)
                    c = 0xff8888a0; // panel border
                else
                {
                    immutable item = itemAt(idx, x, y);
                    if (item >= 0)
                        c = item == s.hoverItem ? 0xff5a6a92 : 0xff44444e;
                }
            }
            buf.pixels[cast(size_t) y * buf.width + x] = c;
        }
    wsi_surface_attach(s.surface, buf.handle, 0, 0);
    wsi_surface_damage_buffer(s.surface, 0, 0, buf.width, buf.height);
    if (idx == IDX_MAIN && g_frames == 0 && g_frameCb is null)
    {
        g_frameCb = wsi_surface_frame(s.surface);
        wsi_callback_add_listener(g_frameCb, &g_frameListener, null);
    }
    wsi_surface_commit(s.surface);
    buf.busy = true;
}

extern (C) void onWmBasePing(void* data, xdg_wm_base* b, uint serial) nothrow @nogc
{
    wsi_wm_base_pong(b, serial);
}

extern (C) void onToplevelConfigure(void* data, xdg_toplevel* t, int w, int h,
    wl_array* states) nothrow @nogc
{
    g_pendingW = w;
    g_pendingH = h;
}

extern (C) void onXdgSurfaceConfigure(void* data, xdg_surface* s, uint serial) nothrow @nogc
{
    immutable idx = cast(size_t) data;
    Surf* sf = &g_surfs[idx];
    if (idx == IDX_MAIN)
    {
        sf.width = g_pendingW > 0 ? g_pendingW : mainWidth;
        sf.height = g_pendingH > 0 ? g_pendingH : mainHeight;
    }
    instrEvent("configure", "idx=%s serial=%u size=%dx%d",
        g_surfNames[idx], serial, sf.width, sf.height);
    wsi_xdg_surface_ack_configure(s, serial);
    immutable wasConfigured = sf.configured;
    sf.configured = true;
    if (idx == IDX_MAIN && !wasConfigured)
        instrFirstConfigure();
    render(idx);
    if (idx == IDX_MAIN && g_firstPaintUs < 0)
        g_firstPaintUs = instrNowUs();
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
}

extern (C) void onFrameDone(void* data, wl_callback* cb, uint timeMs) nothrow @nogc
{
    wsi_callback_destroy(cb);
    g_frameCb = null;
    g_frames++;
    if (g_frames == 1)
        instrFirstPixelPresented();
}

__gshared xdg_wm_base_listener g_wmBaseListener = {&onWmBasePing};
__gshared xdg_surface_listener g_xdgSurfaceListener = {&onXdgSurfaceConfigure};
__gshared xdg_toplevel_listener g_toplevelListener = {
    &onToplevelConfigure, &onToplevelClose,
    &onToplevelConfigureBounds, &onToplevelWmCapabilities
};
__gshared wl_buffer_listener g_bufferListener = {&onBufferRelease};
__gshared wl_callback_listener g_frameListener = {&onFrameDone};

// ----------------------------------------------------- scenario step machine

/// Time-driven steps for the input-less scenarios (noinput, stale) and the
/// deferred reposition probe of menu/noinput.
void tick() nothrow @nogc
{
    immutable now = instrNowUs();
    if (g_repositionAtUs >= 0 && now >= g_repositionAtUs && !g_repositionSent)
    {
        g_repositionAtUs = -1;
        sendReposition();
    }
    if (g_firstPaintUs < 0)
        return;
    immutable t = now - g_firstPaintUs;
    final switch (g_scenario)
    {
    case Scenario.menu:
    case Scenario.edge:
        break; // input-driven
    case Scenario.noinput:
        if (g_step == 0 && t > 300_000)
        {
            g_step = 1;
            openMenu(180, 180, -1); // no seat → no serial → no grab
        }
        else if (g_step == 1 && t > 1_300_000 && g_surfs[IDX_POPUP1].popup !is null)
        {
            g_step = 2;
            openSubmenu(-1);
        }
        else if (g_step == 2 && t > 2_000_000)
        {
            g_step = 3;
            dismissPopups("client-teardown");
        }
        break;
    case Scenario.stale:
        if (g_step == 0 && t > 300_000)
        {
            g_step = 1;
            // The probe: a grab serial that never came from any input event.
            openMenu(180, 180, 1);
        }
        else if (g_step == 1 && t > 1_800_000)
        {
            g_step = 2;
            instrEvent("stale_grab_result",
                "configure_received=%d popup_done_received=%d connection_alive=%d",
                g_staleConfigured ? 1 : 0, g_staleDone ? 1 : 0,
                wl_display_get_error(g_display) == 0 ? 1 : 0);
            g_running = false;
        }
        break;
    }
}

// --------------------------------------------------------------------- main

int main(string[] args)
{
    if (args.length >= 2 && args[1].length >= 4 && args[1][0 .. 4] == "inje")
    {
        import inject : injectMain;

        return injectMain(args.length >= 3 ? args[2] : "menu");
    }

    instrInit("f15_wayland");
    const scen = getenv("WSI_SCENARIO");
    if (scen !is null)
        foreach (i, n; g_scenarioNames)
            if (strcmp(scen, n) == 0)
                g_scenario = cast(Scenario) i;
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
    g_xkbCtx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
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
    instrEvent("globals", "xdg_wm_base_version=%u seat=%d scenario=%s",
        g_wmBaseVersion, g_seat !is null ? 1 : 0, g_scenarioNames[g_scenario]);
    if (g_seat is null && g_scenario != Scenario.noinput)
    {
        // grab/stale need a wl_seat object; headless weston has none.
        printf("SKIP: scenario %s needs a wl_seat; falling back to noinput\n",
            g_scenarioNames[g_scenario]);
        g_scenario = Scenario.noinput;
    }

    wsi_wm_base_add_listener(g_wmBase, &g_wmBaseListener, null);
    Surf* m = &g_surfs[IDX_MAIN];
    m.width = mainWidth;
    m.height = mainHeight;
    m.surface = wsi_compositor_create_surface(g_compositor);
    m.xdgSurface = wsi_wm_base_get_xdg_surface(g_wmBase, m.surface);
    wsi_xdg_surface_add_listener(m.xdgSurface, &g_xdgSurfaceListener, cast(void*) IDX_MAIN);
    m.toplevel = wsi_xdg_surface_get_toplevel(m.xdgSurface);
    wsi_toplevel_add_listener(m.toplevel, &g_toplevelListener, null);
    const appIdEnv = getenv("WSI_APP_ID");
    const appId = appIdEnv !is null ? appIdEnv : "wsi-f15-popup".ptr;
    wsi_toplevel_set_title(m.toplevel, appId);
    wsi_toplevel_set_app_id(m.toplevel, appId);
    instrWindowCreated();
    wsi_surface_commit(m.surface); // mandatory no-buffer first commit

    immutable dispFd = wl_display_get_fd(g_display);
    bool displayDead = false;
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
        {
            // A protocol error (the stale-grab probe's possible outcome)
            // kills the connection — capture WHICH error before exiting.
            wl_interface* errIface;
            uint errId;
            immutable code = wl_display_get_protocol_error(g_display, &errIface, &errId);
            instrEvent("display_error", "errno=%d protocol_code=%u interface=%s id=%u",
                wl_display_get_error(g_display), code,
                errIface !is null ? errIface.name : "?", errId);
            displayDead = true;
            break;
        }
        tick();
        if (g_autoExit && instrNowUs() > g_runUsCap)
            g_running = false;
    }

    instrEvent("summary",
        "scenario=%s grab_used=%d popup_done_events=%d frames=%d display_dead=%d",
        g_scenarioNames[g_scenario], g_grabUsed ? 1 : 0, g_doneEvents,
        g_frames, displayDead ? 1 : 0);

    if (!displayDead)
    {
        dismissPopups("client-teardown");
        foreach (ref b; g_surfs[IDX_MAIN].buffers)
            if (b.handle !is null)
            {
                wsi_buffer_destroy(b.handle);
                munmap(b.pixels, b.byteSize);
            }
        if (g_frameCb !is null)
            wsi_callback_destroy(g_frameCb);
        if (g_keyboard !is null)
            wsi_keyboard_destroy(g_keyboard);
        if (g_pointer !is null)
            wsi_pointer_destroy(g_pointer);
        if (g_seat !is null)
            wsi_seat_destroy(g_seat);
        wsi_toplevel_destroy(g_surfs[IDX_MAIN].toplevel);
        wsi_xdg_surface_destroy(g_surfs[IDX_MAIN].xdgSurface);
        wsi_surface_destroy(g_surfs[IDX_MAIN].surface);
        wsi_wm_base_destroy(g_wmBase);
        wl_proxy_destroy(cast(wl_proxy*) g_shm);
        wl_proxy_destroy(cast(wl_proxy*) g_compositor);
        wl_proxy_destroy(cast(wl_proxy*) g_registry);
    }
    if (g_xkbState !is null)
        xkb_state_unref(g_xkbState);
    if (g_xkbKeymap !is null)
        xkb_keymap_unref(g_xkbKeymap);
    if (g_xkbCtx !is null)
        xkb_context_unref(g_xkbCtx);
    wl_display_disconnect(g_display);

    printf("ok: scenario=%s popup_done_events=%d display_dead=%d\n",
        g_scenarioNames[g_scenario], g_doneEvents, displayDead ? 1 : 0);
    return 0;
}
