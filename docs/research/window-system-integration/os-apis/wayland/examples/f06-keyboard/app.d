// F06 keyboard & keymap on Wayland (../../f06-keyboard.md): scancode → keysym
// → text are three different questions, and Wayland answers NONE of them in
// the protocol — wl_keyboard.key carries a bare evdev scancode, and everything
// above it is the client's job, via libxkbcommon:
//
//   1. wl_keyboard.keymap hands the client an fd + size; the client mmaps it
//      (MAP_PRIVATE, per the protocol) and compiles it with
//      xkb_keymap_new_from_string. The compositor can re-send it at ANY time
//      (layout switch, a new input device with a different map) — the demo
//      logs every `keymap_event` and rebuilds xkb_keymap/xkb_state each time.
//   2. wl_keyboard.modifiers carries raw mask+group; xkb_state_update_mask
//      applies it. Sym and UTF-8 for a key are then
//      xkb_state_key_get_one_sym / xkb_state_key_get_utf8 at keycode
//      (= evdev code + 8, the historical X11 offset xkbcommon keeps).
//   3. KEY REPEAT IS CLIENT-SIDE: wl_keyboard.repeat_info (v4+) only states
//      rate/delay; no repeated key events ever arrive. The demo implements
//      repeat with a timerfd (the F05 external-fd pattern) and proves both
//      mandatory cancellations: on wl_keyboard.key release and on
//      wl_keyboard.leave (focus loss).
//   4. Dead-key compose is ALSO client-side: pressed syms feed an
//      xkb_compose_state (table from the locale); `compose state=…`
//      transitions and the composed text are logged.
//
// Every press/release logs `key code=<evdev+8> sym=<name> text=<utf8>
// state=down|up repeat=0|1`. Headless weston advertises NO wl_seat, so the
// Tier-A run uses a wlroots headless compositor (sway) + wtype's
// zwp_virtual_keyboard_v1 injection — see ../../f06-keyboard.md for the
// choreography. No compositor → SKIP; no seat → SKIP (exit 0 both ways).
//
// Based on the scaffold (../scaffold/app.d, findings ../../scaffold.md);
// instrumentation contract: ./instrument.d.
module app;

import c; // ImportC: wayland + xdg-shell + xkbcommon + timerfd/poll + wsi_*
import instrument;
import core.stdc.stdio : printf;
import core.stdc.stdlib : atoll, getenv;
import core.stdc.string : strcmp;

// ----------------------------------------------------------------- tunables

enum int defaultWidth = 640;
enum int defaultHeight = 480;
enum int pollTimeoutMs = 250;
enum long defaultCapUs = 30_000_000; // WSI_AUTO_EXIT=1 run length (override: WSI_F06_CAP_US)

// -------------------------------------------------------------------- state

/// One wl_shm-backed ARGB8888 buffer (scaffold pattern).
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
    wl_keyboard* g_keyboard;
    xdg_wm_base* g_wmBase;
    wl_surface* g_surface;
    xdg_surface* g_xdgSurface;
    xdg_toplevel* g_toplevel;
    wl_callback* g_frameCb;

    Buffer[2] g_buffers;
    int g_width = defaultWidth;
    int g_height = defaultHeight;
    int g_pendingWidth, g_pendingHeight;
    bool g_configured, g_presented;
    bool g_running = true;
    bool g_autoExit;
    int g_frames, g_commits;

    // xkbcommon: the client-owned keyboard state machine.
    xkb_context* g_xkbCtx;
    xkb_keymap* g_xkbKeymap;
    xkb_state* g_xkbState;
    xkb_compose_table* g_composeTable;
    xkb_compose_state* g_composeState;

    // Client-side repeat (the F05 timerfd pattern).
    int g_repeatTimerfd = -1;
    int g_repeatRate; // characters/second, 0 = disabled (repeat_info)
    int g_repeatDelayMs;
    uint g_repeatKeycode; // 0 = no repeat armed

    // Findings counters.
    int g_keymapCount, g_keyEvents, g_repeatSynth;
    int g_cancelRelease, g_cancelFocus;
}

// -------------------------------------------------------- key-event helpers

/// Escape control bytes as \xNN so `text=` stays one parseable log token.
void sanitize(const(char)* src, char* dst, size_t dstLen) nothrow @nogc
{
    static char hexDigit(uint v) nothrow @nogc
    {
        return cast(char)(v < 10 ? '0' + v : 'a' + v - 10);
    }

    size_t j;
    for (size_t i = 0; src[i] != 0 && j + 5 < dstLen; i++)
    {
        immutable ubyte b = src[i];
        if (b >= 0x20 && b != 0x7f)
            dst[j++] = b;
        else
        {
            dst[j++] = '\\';
            dst[j++] = 'x';
            dst[j++] = hexDigit(b >> 4);
            dst[j++] = hexDigit(b & 0xf);
        }
    }
    dst[j] = 0;
}

/// Resolve keycode → (sym name, UTF-8 text) through the current xkb_state.
void resolveKey(uint keycode, ref char[64] symName, ref char[64] text) nothrow @nogc
{
    symName[0] = '?';
    symName[1] = 0;
    text[0] = 0;
    if (g_xkbState is null)
        return;
    immutable sym = xkb_state_key_get_one_sym(g_xkbState, keycode);
    xkb_keysym_get_name(sym, symName.ptr, symName.length);
    xkb_state_key_get_utf8(g_xkbState, keycode, text.ptr, text.length);
}

void logKeyLine(uint keycode, in char[64] symName, const(char)* text, bool down, int repeat) nothrow @nogc
{
    char[128] safe = void;
    sanitize(text, safe.ptr, safe.length);
    instrEvent("key", "code=%u sym=%s text=%s state=%s repeat=%d",
        keycode, symName.ptr, safe.ptr, down ? "down".ptr : "up".ptr, repeat);
}

// --------------------------------------------------- client-side key repeat

/// Arm the repeat timerfd: one-shot delay, then the rate interval — exactly
/// the contract wl_keyboard.repeat_info describes but does not implement.
void armRepeat(uint keycode) nothrow @nogc
{
    if (g_repeatRate <= 0) // rate 0 = "repeat disabled" per the protocol
        return;
    if (g_xkbKeymap is null || !xkb_keymap_key_repeats(g_xkbKeymap, keycode))
        return; // keymap says this key does not repeat (modifiers etc.)
    g_repeatKeycode = keycode;
    immutable long periodNs = 1_000_000_000L / g_repeatRate;
    itimerspec its;
    its.it_value.tv_sec = g_repeatDelayMs / 1000;
    its.it_value.tv_nsec = cast(long)(g_repeatDelayMs % 1000) * 1_000_000;
    its.it_interval.tv_sec = periodNs / 1_000_000_000;
    its.it_interval.tv_nsec = periodNs % 1_000_000_000;
    timerfd_settime(g_repeatTimerfd, 0, &its, null);
    instrEvent("repeat_arm", "code=%u delay_ms=%d rate_hz=%d", keycode,
        g_repeatDelayMs, g_repeatRate);
}

void cancelRepeat(const(char)* reason) nothrow @nogc
{
    if (g_repeatKeycode == 0)
        return;
    itimerspec zero; // all-zero it_value disarms the timer
    timerfd_settime(g_repeatTimerfd, 0, &zero, null);
    instrEvent("repeat_cancel", "reason=%s code=%u", reason, g_repeatKeycode);
    g_repeatKeycode = 0;
}

/// Repeat timer fired: synthesize `repeat=1` key events from the *current*
/// xkb_state (so held-key repeats track live modifier changes).
void drainRepeatTimer() nothrow @nogc
{
    ulong expirations;
    if (read(g_repeatTimerfd, &expirations, expirations.sizeof) != expirations.sizeof)
        return;
    if (g_repeatKeycode == 0)
        return; // raced with a cancel — the read already cleared the fd
    char[64] symName = void, text = void;
    resolveKey(g_repeatKeycode, symName, text);
    foreach (i; 0 .. expirations)
    {
        g_repeatSynth++;
        logKeyLine(g_repeatKeycode, symName, text.ptr, true, 1);
    }
}

// ------------------------------------------------------ wl_keyboard events

/// wl_keyboard.keymap: the compositor serializes the WHOLE keymap into an fd.
/// Can arrive again at any time (layout switch / new device) — each arrival
/// replaces the client's xkb_keymap + xkb_state.
extern (C) void onKbKeymap(void* data, wl_keyboard* kb, uint format, int fd,
    uint size) nothrow @nogc
{
    g_keymapCount++;
    instrEvent("keymap_event", "format=%u size=%u n=%d", format, size, g_keymapCount);
    if (format != WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1)
    {
        close(fd);
        return;
    }
    // "From version 7 onwards, the fd must be mapped with MAP_PRIVATE."
    void* mem = mmap(null, size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (mem is cast(void*)-1)
    {
        close(fd);
        return;
    }
    auto keymap = xkb_keymap_new_from_string(g_xkbCtx, cast(const(char)*) mem,
        XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
    munmap(mem, size);
    close(fd);
    if (keymap is null)
    {
        instrEvent("keymap_parse_failed");
        return;
    }
    if (g_xkbState !is null)
        xkb_state_unref(g_xkbState);
    if (g_xkbKeymap !is null)
        xkb_keymap_unref(g_xkbKeymap);
    g_xkbKeymap = keymap;
    g_xkbState = xkb_state_new(keymap);
    const layout0 = xkb_keymap_layout_get_name(keymap, 0);
    instrEvent("keymap_parsed", "layouts=%u layout0=%s",
        xkb_keymap_num_layouts(keymap), layout0 !is null ? layout0 : "(unnamed)".ptr);
    cancelRepeat("keymap_replaced"); // old keycode semantics are gone
}

extern (C) void onKbEnter(void* data, wl_keyboard* kb, uint serial,
    wl_surface* s, wl_array* keys) nothrow @nogc
{
    instrEvent("keyboard_enter", "serial=%u pressed=%zu", serial, keys.size / 4);
}

/// Focus loss kills the repeat timer — the second mandatory cancellation.
extern (C) void onKbLeave(void* data, wl_keyboard* kb, uint serial,
    wl_surface* s) nothrow @nogc
{
    instrEvent("keyboard_leave", "serial=%u", serial);
    if (g_repeatKeycode != 0)
        g_cancelFocus++;
    cancelRepeat("focus_leave");
}

extern (C) void onKbKey(void* data, wl_keyboard* kb, uint serial, uint time,
    uint key, uint state) nothrow @nogc
{
    immutable keycode = key + 8; // evdev → XKB keycode (the historical +8)
    immutable down = state == WL_KEYBOARD_KEY_STATE_PRESSED;
    g_keyEvents++;

    char[64] symName = void, text = void;
    resolveKey(keycode, symName, text);

    // Dead-key compose: pressed syms feed the compose state machine; while
    // composing, the would-be text is withheld; on COMPOSED the machine —
    // not the keymap — provides the final text.
    if (down && g_composeState !is null && g_xkbState !is null)
    {
        immutable sym = xkb_state_key_get_one_sym(g_xkbState, keycode);
        if (xkb_compose_state_feed(g_composeState, sym) == XKB_COMPOSE_FEED_ACCEPTED)
        {
            immutable status = xkb_compose_state_get_status(g_composeState);
            if (status == XKB_COMPOSE_COMPOSING)
            {
                instrEvent("compose", "state=composing");
                text[0] = 0; // a dead key produces no text of its own
            }
            else if (status == XKB_COMPOSE_COMPOSED)
            {
                xkb_compose_state_get_utf8(g_composeState, text.ptr, text.length);
                char[128] safe = void;
                sanitize(text.ptr, safe.ptr, safe.length);
                instrEvent("compose", "state=composed text=%s", safe.ptr);
                xkb_compose_state_reset(g_composeState);
            }
            else if (status == XKB_COMPOSE_CANCELLED)
            {
                instrEvent("compose", "state=cancelled");
                xkb_compose_state_reset(g_composeState);
                text[0] = 0;
            }
        }
    }

    logKeyLine(keycode, symName, text.ptr, down, 0);

    if (down)
        armRepeat(keycode); // a new press re-targets the repeat
    else if (keycode == g_repeatKeycode)
    {
        g_cancelRelease++;
        cancelRepeat("release"); // the first mandatory cancellation
    }
}

/// Raw masks + group from the compositor; xkb_state_update_mask applies them.
/// The client never tracks modifiers itself — pressed keys on *other* clients
/// (grabs, compositor shortcuts) would desync it.
extern (C) void onKbModifiers(void* data, wl_keyboard* kb, uint serial,
    uint depressed, uint latched, uint locked, uint group) nothrow @nogc
{
    if (g_xkbState !is null)
        xkb_state_update_mask(g_xkbState, depressed, latched, locked, 0, 0, group);
    instrEvent("modifiers", "depressed=0x%x latched=0x%x locked=0x%x group=%u",
        depressed, latched, locked, group);
}

/// The whole protocol-side repeat story: two integers, no events.
extern (C) void onKbRepeatInfo(void* data, wl_keyboard* kb, int rate, int delay) nothrow @nogc
{
    g_repeatRate = rate;
    g_repeatDelayMs = delay;
    instrEvent("repeat_info", "rate_hz=%d delay_ms=%d", rate, delay);
}

__gshared wl_keyboard_listener g_keyboardListener = {
    &onKbKeymap, &onKbEnter, &onKbLeave, &onKbKey, &onKbModifiers, &onKbRepeatInfo
};

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
    immutable size = cast(size_t)(stride) * h;
    immutable fd = memfd_create("wsi-f06", MFD_CLOEXEC);
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
    return true;
}

void paint(ref Buffer b, int frame) nothrow @nogc
{
    immutable uint color = (frame & 1) ? 0xff30_3050 : 0xff50_3030;
    immutable n = cast(size_t) b.width * b.height;
    foreach (i; 0 .. n)
        b.pixels[i] = color;
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
        return; // both busy: the release handler re-renders
    if (!ensureBuffer(*buf, g_width, g_height))
    {
        g_running = false;
        return;
    }
    paint(*buf, g_frames);
    assert(buf.width == g_width && buf.height == g_height,
        "committed buffer size does not match the acked configure size");
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

// ------------------------------------------------------ remaining listeners

extern (C) void onGlobal(void* data, wl_registry* reg, uint name,
    const(char)* iface, uint ver) nothrow @nogc
{
    static uint capped(uint advertised, uint want) nothrow @nogc
    {
        return advertised < want ? advertised : want;
    }

    if (strcmp(iface, wl_compositor_interface.name) == 0)
        g_compositor = cast(wl_compositor*) wsi_registry_bind(reg, name,
            &wl_compositor_interface, capped(ver, 4));
    else if (strcmp(iface, wl_shm_interface.name) == 0)
        g_shm = cast(wl_shm*) wsi_registry_bind(reg, name, &wl_shm_interface, 1);
    else if (strcmp(iface, xdg_wm_base_interface.name) == 0)
        g_wmBase = cast(xdg_wm_base*) wsi_registry_bind(reg, name, &xdg_wm_base_interface, 1);
    else if (strcmp(iface, wl_seat_interface.name) == 0)
        g_seat = cast(wl_seat*) wsi_registry_bind(reg, name, &wl_seat_interface,
            capped(ver, 7)); // v4+: wl_keyboard.repeat_info
}

extern (C) void onGlobalRemove(void* data, wl_registry* reg, uint name) nothrow @nogc
{
}

extern (C) void onWmBasePing(void* data, xdg_wm_base* b, uint serial) nothrow @nogc
{
    wsi_wm_base_pong(b, serial);
}

/// Capabilities are dynamic: the keyboard is acquired when announced and
/// released if it disappears (hotplug semantics, even for virtual devices).
extern (C) void onSeatCapabilities(void* data, wl_seat* s, uint caps) nothrow @nogc
{
    instrEvent("seat_capabilities", "caps=0x%x keyboard=%d", caps,
        (caps & WL_SEAT_CAPABILITY_KEYBOARD) != 0);
    if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && g_keyboard is null)
    {
        g_keyboard = wsi_seat_get_keyboard(s);
        wsi_keyboard_add_listener(g_keyboard, &g_keyboardListener, null);
        instrEvent("keyboard_bound");
    }
    else if (!(caps & WL_SEAT_CAPABILITY_KEYBOARD) && g_keyboard !is null)
    {
        cancelRepeat("capability_lost");
        wsi_keyboard_release(g_keyboard);
        g_keyboard = null;
        instrEvent("keyboard_released");
    }
}

extern (C) void onSeatName(void* data, wl_seat* s, const(char)* name) nothrow @nogc
{
    instrEvent("seat_name", "name=%s", name);
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
    auto buf = cast(Buffer*) data;
    buf.busy = false;
    if (g_running && g_configured && g_frameCb is null)
        render();
}

extern (C) void onFrameDone(void* data, wl_callback* cb, uint timeMs) nothrow @nogc
{
    wsi_callback_destroy(cb);
    g_frameCb = null;
    g_frames++;
    if (!g_presented)
    {
        g_presented = true;
        instrFirstPixelPresented();
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

// ------------------------------------------- the F05 multiplexing loop again

/// wl fd + repeat timerfd in one poll — the same canonical
/// prepare_read/poll/read_events pump F05 documents; the repeat timer is
/// exactly the kind of "external fd" that pattern exists for.
bool pumpOnce(int timeoutMs) nothrow @nogc
{
    while (wl_display_prepare_read(g_display) != 0)
        if (wl_display_dispatch_pending(g_display) < 0)
            return false;
    wl_display_flush(g_display);

    pollfd[2] pfds;
    pfds[0].fd = wl_display_get_fd(g_display);
    pfds[0].events = POLLIN;
    pfds[1].fd = g_repeatTimerfd;
    pfds[1].events = POLLIN;
    immutable r = poll(pfds.ptr, 2, timeoutMs);
    if (r < 0)
    {
        wl_display_cancel_read(g_display);
        return false;
    }
    if (pfds[0].revents & POLLIN)
    {
        if (wl_display_read_events(g_display) < 0)
            return false;
        if (wl_display_dispatch_pending(g_display) < 0)
            return false;
    }
    else
        wl_display_cancel_read(g_display);

    if (pfds[1].revents & POLLIN)
        drainRepeatTimer();
    return true;
}

// ----------------------------------------------------------------- teardown

void teardown() nothrow @nogc
{
    if (g_composeState !is null)
        xkb_compose_state_unref(g_composeState);
    if (g_composeTable !is null)
        xkb_compose_table_unref(g_composeTable);
    if (g_xkbState !is null)
        xkb_state_unref(g_xkbState);
    if (g_xkbKeymap !is null)
        xkb_keymap_unref(g_xkbKeymap);
    if (g_xkbCtx !is null)
        xkb_context_unref(g_xkbCtx);
    foreach (ref b; g_buffers)
        if (b.handle !is null)
        {
            wsi_buffer_destroy(b.handle);
            munmap(b.pixels, b.byteSize);
            b = Buffer.init;
        }
    if (g_frameCb !is null)
        wsi_callback_destroy(g_frameCb);
    if (g_keyboard !is null)
        wsi_keyboard_release(g_keyboard);
    if (g_toplevel !is null)
        wsi_toplevel_destroy(g_toplevel);
    if (g_xdgSurface !is null)
        wsi_xdg_surface_destroy(g_xdgSurface);
    if (g_surface !is null)
        wsi_surface_destroy(g_surface);
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
    if (g_repeatTimerfd >= 0)
        close(g_repeatTimerfd);
}

// --------------------------------------------------------------------- main

int main()
{
    instrInit("f06-wayland");
    const autoEnv = getenv("WSI_AUTO_EXIT");
    g_autoExit = autoEnv !is null && *autoEnv == '1';
    long capUs = defaultCapUs;
    if (const cap = getenv("WSI_F06_CAP_US"))
        if (atoll(cap) > 0)
            capUs = atoll(cap);

    // 1. Connect (SKIP cleanly on hosts without a compositor).
    g_display = wl_display_connect(null);
    if (g_display is null)
    {
        printf("SKIP: no Wayland compositor (wl_display_connect returned null)\n");
        return 0;
    }

    // 2. Registry: bind the window globals + the seat.
    g_registry = wsi_display_get_registry(g_display);
    wsi_registry_add_listener(g_registry, &g_registryListener, null);
    wl_display_roundtrip(g_display);

    if (g_compositor is null || g_shm is null || g_wmBase is null)
    {
        printf("SKIP: compositor lacks a required global (wl_compositor/wl_shm/xdg_wm_base)\n");
        teardown();
        return 0;
    }
    if (g_seat is null)
    {
        // Headless weston's documented shape: no input backend, no seat.
        printf("SKIP: compositor advertises no wl_seat (headless weston?) — keyboard demo needs a seat\n");
        teardown();
        return 0;
    }
    wsi_wm_base_add_listener(g_wmBase, &g_wmBaseListener, null);
    wsi_seat_add_listener(g_seat, &g_seatListener, null);

    // 3. xkbcommon context + locale compose table (client-side dead keys).
    g_xkbCtx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    const(char)* locale = getenv("LC_ALL");
    if (locale is null || *locale == 0)
        locale = getenv("LC_CTYPE");
    if (locale is null || *locale == 0)
        locale = getenv("LANG");
    if (locale is null || *locale == 0)
        locale = "C";
    g_composeTable = xkb_compose_table_new_from_locale(g_xkbCtx, locale,
        XKB_COMPOSE_COMPILE_NO_FLAGS);
    if (g_composeTable !is null)
        g_composeState = xkb_compose_state_new(g_composeTable, XKB_COMPOSE_STATE_NO_FLAGS);
    instrEvent("compose_table", "locale=%s status=%s", locale,
        g_composeTable !is null ? "ok".ptr : "unavailable".ptr);

    // 4. The repeat timerfd (armed/disarmed by key events; see armRepeat).
    g_repeatTimerfd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
    if (g_repeatTimerfd < 0)
    {
        printf("SKIP: timerfd unavailable\n");
        teardown();
        return 0;
    }

    // 5. Window object tree (scaffold handshake) — the demo must be a mapped,
    //    focused toplevel to receive wl_keyboard events at all.
    g_surface = wsi_compositor_create_surface(g_compositor);
    g_xdgSurface = wsi_wm_base_get_xdg_surface(g_wmBase, g_surface);
    wsi_xdg_surface_add_listener(g_xdgSurface, &g_xdgSurfaceListener, null);
    g_toplevel = wsi_xdg_surface_get_toplevel(g_xdgSurface);
    wsi_toplevel_add_listener(g_toplevel, &g_toplevelListener, null);
    wsi_toplevel_set_title(g_toplevel, "wsi-f06-keyboard");
    wsi_toplevel_set_app_id(g_toplevel, "wsi-f06-keyboard");
    instrWindowCreated();
    wsi_surface_commit(g_surface); // mandatory initial no-buffer commit

    // 6. Event loop: wl fd + repeat timerfd in one poll (see pumpOnce).
    while (g_running)
    {
        if (!pumpOnce(pollTimeoutMs))
            break;
        if (g_autoExit && instrNowUs() > capUs)
            g_running = false;
    }

    // 7. Teardown + the numbers.
    teardown();
    printf("ok: keymaps=%d key_events=%d repeats_synthesized=%d "
        ~ "cancel_on_release=%d cancel_on_focus_loss=%d\n",
        g_keymapCount, g_keyEvents, g_repeatSynth, g_cancelRelease, g_cancelFocus);
    return 0;
}
