// F07 IME / text input demo — an editable line with a visible caret, driven by
// zwp_text_input_v3 (text-input-unstable-v3) on top of the xdg-shell scaffold
// (../scaffold/app.d; findings: ../../scaffold.md, ../../f07-text-input.md).
//
// What it implements, per the protocol XML (text-input-unstable-v3.xml):
//
//   - bind zwp_text_input_manager_v3, get_text_input for the seat;
//   - on zwp_text_input_v3.enter: enable + set_surrounding_text +
//     set_content_type + set_cursor_rectangle(caret cells) + commit;
//   - the v3 double-buffered event state: preedit_string / commit_string /
//     delete_surrounding_text only latch *pending* state, which is applied
//     atomically on done(serial) in the exact order the XML mandates
//     (1. drop old preedit, 2. delete surrounding, 3. insert commit string,
//     4. recalculate surrounding, 5-6. install new preedit + caret);
//   - the serial discipline: the client counts its own commit requests; a
//     done.serial equal to that count permits new state requests, a stale
//     serial means "apply the edits, but do not touch protocol state yet".
//
// The line is rendered with block glyphs (no font lib): each committed UTF-8
// byte is a colored cell (color = hash of the byte), the pre-edit is rendered
// inline at the caret as cells over a bright underline band, and the caret is
// a white bar. The *real* strings are logged (`text committed="…" preedit="…"`).
// wl_keyboard events are logged in full (keycode, xkb keysym, UTF-8) so the
// findings doc can answer which key events still arrive while an IME composes.
// Plain typing also works without an IME: xkbcommon translates the key, the
// demo edits locally and resends state with change_cause=other.
//
// Headless-safe: no compositor → SKIP, exit 0; no zwp_text_input_manager_v3 or
// no wl_seat → the absence is logged as the finding and the run still exits 0.
module app;

import c; // ImportC: wayland-client + xdg-shell + text-input-v3 glue + xkbcommon
import instrument;
import core.stdc.stdio : printf, snprintf;
import core.stdc.stdlib : getenv;
import core.stdc.string : memcpy, memmove, strcmp, strlen;

// ----------------------------------------------------------------- tunables

enum int defaultWidth = 640;
enum int defaultHeight = 220;
enum int autoExitFrames = 150; // ≈ 2.5 s at 60 Hz
enum long autoExitUsCap = 3_000_000;
enum int textCap = 240; // committed-line byte budget (protocol max is 4000)

// Block-glyph layout (surface-local px — the units set_cursor_rectangle takes).
enum int cellX0 = 16, cellY0 = 96, cellW = 12, cellH = 48, underlineH = 6;

// Keysyms used for local editing (values from xkbcommon-keysyms.h).
enum uint keyBackSpace = 0xff08, keyEscape = 0xff1b, keyLeft = 0xff51, keyRight = 0xff53;

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
    wl_keyboard* g_keyboard;
    xdg_wm_base* g_wmBase;
    wl_surface* g_surface;
    xdg_surface* g_xdgSurface;
    xdg_toplevel* g_toplevel;
    wl_callback* g_frameCb;
    zwp_text_input_manager_v3* g_tiManager;
    zwp_text_input_v3* g_ti;

    xkb_context* g_xkbCtx;
    xkb_keymap* g_xkbKeymap;
    xkb_state* g_xkbState;

    Buffer[2] g_buffers;
    int g_width = defaultWidth, g_height = defaultHeight;
    int g_pendingWidth, g_pendingHeight;
    bool g_configured, g_running = true, g_autoExit;
    int g_frames, g_commits;

    // --- the editable line -------------------------------------------------
    char[textCap + 1] g_text = '\0'; // committed text, NUL-terminated
    int g_textLen;
    int g_cursor; // byte index into g_text
    char[textCap + 1] g_preedit = '\0'; // current (applied) pre-edit
    int g_preeditLen;
    int g_preeditCb, g_preeditCe; // caret begin/end inside the pre-edit, bytes

    // --- zwp_text_input_v3 client state ------------------------------------
    bool g_tiFocused; // between enter and leave
    uint g_tiCommits; // number of commit requests sent == expected done serial
    // pending (double-buffered) event state, applied on done():
    char[textCap + 1] g_pendPreedit = '\0';
    int g_pendPreeditLen, g_pendPreeditCb, g_pendPreeditCe;
    char[textCap + 1] g_pendCommit = '\0';
    int g_pendCommitLen;
    uint g_pendDelBefore, g_pendDelAfter;
}

// ----------------------------------------------------------- text utilities

int clampInt(int v, int lo, int hi) nothrow @nogc
{
    return v < lo ? lo : (v > hi ? hi : v);
}

/// Copy a NUL-terminated C string into a bounded buffer, returning the length.
int copyStr(const(char)* src, ref char[textCap + 1] dst) nothrow @nogc
{
    int n = src is null ? 0 : cast(int) strlen(src);
    if (n > textCap)
        n = textCap;
    if (n > 0)
        memcpy(dst.ptr, src, n);
    dst[n] = '\0';
    return n;
}

void insertAtCursor(const(char)* s, int n) nothrow @nogc
{
    if (n <= 0 || g_textLen + n > textCap)
        return;
    memmove(g_text.ptr + g_cursor + n, g_text.ptr + g_cursor, g_textLen - g_cursor);
    memcpy(g_text.ptr + g_cursor, s, n);
    g_textLen += n;
    g_cursor += n;
    g_text[g_textLen] = '\0';
}

void deleteRange(int begin, int end) nothrow @nogc // [begin, end) in bytes
{
    begin = clampInt(begin, 0, g_textLen);
    end = clampInt(end, begin, g_textLen);
    memmove(g_text.ptr + begin, g_text.ptr + end, g_textLen - end);
    g_textLen -= end - begin;
    g_cursor = g_cursor >= end ? g_cursor - (end - begin) : clampInt(g_cursor, 0, begin);
    g_text[g_textLen] = '\0';
}

/// Step one UTF-8 code point left/right from `idx` (indices never split a
/// code point — the same invariant text-input-v3 demands of its byte offsets).
int cpPrev(int idx) nothrow @nogc
{
    do
        --idx;
    while (idx > 0 && (g_text[idx] & 0xc0) == 0x80);
    return idx < 0 ? 0 : idx;
}

int cpNext(int idx) nothrow @nogc
{
    do
        ++idx;
    while (idx < g_textLen && (g_text[idx] & 0xc0) == 0x80);
    return idx > g_textLen ? g_textLen : idx;
}

void logText() nothrow @nogc
{
    instrEvent("text", "committed=\"%s\" cursor=%d preedit=\"%s\" preedit_cursor=%d..%d",
        g_text.ptr, g_cursor, g_preedit.ptr, g_preeditCb, g_preeditCe);
}

// --------------------------------------------- caret rect + protocol commits

/// Caret rectangle in surface-local coordinates: the cell the caret occupies,
/// accounting for the pre-edit caret offset (cursor_begin) when composing.
void caretRect(out int x, out int y, out int w, out int h) nothrow @nogc
{
    immutable col = g_cursor + (g_preeditLen > 0 ? clampInt(g_preeditCb, 0, g_preeditLen) : 0);
    x = cellX0 + col * cellW;
    y = cellY0;
    w = cellW;
    h = cellH;
}

/// Send the full client state and commit it — the only place a
/// zwp_text_input_v3.commit is issued, so g_tiCommits *is* the serial the
/// protocol's done event must echo. cause: 0=input_method, 1=other, -1=omit.
void tiCommitState(bool enable, int cause) nothrow @nogc
{
    if (g_ti is null || (!enable && !g_tiFocused))
        return;
    if (enable)
        wsi_text_input_enable(g_ti);
    wsi_text_input_set_surrounding_text(g_ti, g_text.ptr, g_cursor, g_cursor);
    if (cause >= 0)
        wsi_text_input_set_text_change_cause(g_ti, cast(uint) cause);
    wsi_text_input_set_content_type(g_ti,
        ZWP_TEXT_INPUT_V3_CONTENT_HINT_NONE, ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_NORMAL);
    int x, y, w, h;
    caretRect(x, y, w, h);
    wsi_text_input_set_cursor_rectangle(g_ti, x, y, w, h);
    wsi_text_input_commit(g_ti);
    g_tiCommits++;
    instrEvent("ti_commit_state", "serial=%u enable=%d cause=%d cursor_rect=%d,%d %dx%d",
        g_tiCommits, enable ? 1 : 0, cause, x, y, w, h);
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
    immutable fd = memfd_create("wsi-f07", MFD_CLOEXEC);
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

void fillRect(ref Buffer b, int x, int y, int w, int h, uint argb) nothrow @nogc
{
    immutable x0 = clampInt(x, 0, b.width), x1 = clampInt(x + w, 0, b.width);
    immutable y0 = clampInt(y, 0, b.height), y1 = clampInt(y + h, 0, b.height);
    foreach (yy; y0 .. y1)
    {
        uint* row = b.pixels + cast(size_t) yy * b.width;
        row[x0 .. x1] = argb;
    }
}

/// Block glyph: a byte becomes a solid cell whose color hashes the byte value,
/// so distinct characters are visually distinct without any font machinery.
uint cellColor(ubyte c, bool preedit) nothrow @nogc
{
    immutable uint h = (c * 2654435761u) >> 8;
    immutable uint r = 0x50 + (h & 0x7f), g = 0x50 + ((h >> 7) & 0x7f),
        bch = 0x50 + ((h >> 14) & 0x7f);
    // pre-edit cells are dimmed toward blue so they read as "not committed yet"
    return preedit ? 0xff000000 | (r / 2 << 16) | (g / 2 << 8) | 0xff
        : 0xff000000 | (r << 16) | (g << 8) | bch;
}

void paint(ref Buffer b) nothrow @nogc
{
    fillRect(b, 0, 0, b.width, b.height, 0xff14181c); // background
    // status blocks (the on-screen debug string, block-glyph form): focus,
    // text-input present, pre-edit active, then the done-serial low bits.
    fillRect(b, cellX0, 16, 24, 24, g_tiFocused ? 0xff30c030 : 0xffc03030);
    fillRect(b, cellX0 + 32, 16, 24, 24, g_ti !is null ? 0xff3060e0 : 0xff606060);
    fillRect(b, cellX0 + 64, 16, 24, 24, g_preeditLen > 0 ? 0xffe0c020 : 0xff606060);
    foreach (bit; 0 .. 8)
        fillRect(b, cellX0 + 112 + bit * 16, 16, 12, 24,
            (g_tiCommits >> (7 - bit)) & 1 ? 0xffe0e0e0 : 0xff404040);

    fillRect(b, cellX0 - 4, cellY0 - 4, b.width - 2 * cellX0 + 8, cellH + 8, 0xff20262c); // field
    // committed text before the caret, pre-edit, committed after — inline.
    int col = 0;
    void cells(const(char)* s, int begin, int end, bool pre) nothrow @nogc
    {
        foreach (i; begin .. end)
        {
            fillRect(b, cellX0 + col * cellW + 1, cellY0, cellW - 2, cellH - underlineH - 2,
                cellColor(cast(ubyte) s[i], pre));
            if (pre)
                fillRect(b, cellX0 + col * cellW, cellY0 + cellH - underlineH,
                    cellW, underlineH, 0xffffd040); // the underline band
            col++;
        }
    }

    cells(g_text.ptr, 0, g_cursor, false);
    cells(g_preedit.ptr, 0, g_preeditLen, true);
    cells(g_text.ptr, g_cursor, g_textLen, false);
    int cx, cy, cw, ch;
    caretRect(cx, cy, cw, ch);
    fillRect(b, cx - 1, cy - 4, 3, ch + 8, 0xffffffff); // the caret bar
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
    if (buf is null || !ensureBuffer(*buf, g_width, g_height))
        return;
    paint(*buf);
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

// ----------------------------------------------- zwp_text_input_v3 listeners

extern (C) void onTiEnter(void* data, zwp_text_input_v3* ti, wl_surface* s) nothrow @nogc
{
    g_tiFocused = true;
    instrEvent("ti_enter");
    // Per the XML: "After an enter event or disable request all state
    // information is invalidated and needs to be resent by the client."
    tiCommitState(true, -1);
}

extern (C) void onTiLeave(void* data, zwp_text_input_v3* ti, wl_surface* s) nothrow @nogc
{
    // "The client should reset any preedit string previously set" — the
    // composition simply evaporates; nothing is committed.
    immutable hadPreedit = g_preeditLen;
    g_preeditLen = 0;
    g_preedit[0] = '\0';
    instrEvent("ti_leave", "dropped_preedit_bytes=%d", hadPreedit);
    wsi_text_input_disable(g_ti);
    wsi_text_input_commit(g_ti);
    g_tiCommits++;
    g_tiFocused = false;
    instrEvent("ti_commit_state", "serial=%u enable=0 disable=1", g_tiCommits);
    logText();
}

extern (C) void onTiPreedit(void* data, zwp_text_input_v3* ti,
    const(char)* text, int cursorBegin, int cursorEnd) nothrow @nogc
{
    // Double-buffered: latch only; applied on done().
    g_pendPreeditLen = copyStr(text, g_pendPreedit);
    g_pendPreeditCb = cursorBegin;
    g_pendPreeditCe = cursorEnd;
    instrEvent("ti_preedit_string", "text=\"%s\" cursor_begin=%d cursor_end=%d (pending)",
        g_pendPreedit.ptr, cursorBegin, cursorEnd);
}

extern (C) void onTiCommitString(void* data, zwp_text_input_v3* ti, const(char)* text) nothrow @nogc
{
    g_pendCommitLen = copyStr(text, g_pendCommit);
    instrEvent("ti_commit_string", "text=\"%s\" (pending)", g_pendCommit.ptr);
}

extern (C) void onTiDeleteSurrounding(void* data, zwp_text_input_v3* ti,
    uint beforeLength, uint afterLength) nothrow @nogc
{
    g_pendDelBefore = beforeLength;
    g_pendDelAfter = afterLength;
    instrEvent("ti_delete_surrounding_text", "before=%u after=%u (pending)",
        beforeLength, afterLength);
}

/// done(serial): atomically apply the pending state in the order the protocol
/// XML mandates, then — only if the serial matches our commit count — answer
/// with refreshed surrounding text / cursor rectangle.
extern (C) void onTiDone(void* data, zwp_text_input_v3* ti, uint serial) nothrow @nogc
{
    immutable inSync = serial == g_tiCommits;
    instrEvent("ti_done", "serial=%u client_commits=%u in_sync=%d", serial, g_tiCommits, inSync);

    bool surroundingChanged = false;
    // 1. Replace existing preedit string with the cursor.
    g_preeditLen = 0;
    g_preedit[0] = '\0';
    // 2. Delete requested surrounding text (lengths are bytes around the cursor).
    if (g_pendDelBefore != 0 || g_pendDelAfter != 0)
    {
        deleteRange(g_cursor - cast(int) g_pendDelBefore, g_cursor + cast(int) g_pendDelAfter);
        surroundingChanged = true;
    }
    // 3. Insert commit string with the cursor at its end.
    if (g_pendCommitLen > 0)
    {
        insertAtCursor(g_pendCommit.ptr, g_pendCommitLen);
        surroundingChanged = true;
    }
    // 4. (surrounding text is recalculated when we resend state below)
    // 5./6. Insert new preedit text at the cursor, with the caret inside it.
    g_preeditLen = g_pendPreeditLen;
    memcpy(g_preedit.ptr, g_pendPreedit.ptr, g_pendPreeditLen + 1);
    g_preeditCb = g_pendPreeditCb;
    g_preeditCe = g_pendPreeditCe;
    // Pending state resets to initial after every done (per the XML).
    g_pendPreeditLen = g_pendPreeditCb = g_pendPreeditCe = 0;
    g_pendPreedit[0] = '\0';
    g_pendCommitLen = 0;
    g_pendCommit[0] = '\0';
    g_pendDelBefore = g_pendDelAfter = 0;
    logText();

    // Serial discipline: a stale serial means our state is already newer than
    // what the IM saw — apply the edits but send nothing until it catches up.
    if (inSync && (surroundingChanged || g_preeditLen > 0))
        tiCommitState(false, surroundingChanged ? 0 : -1); // 0 = input_method
}

// ----------------------------------------------------- wl_keyboard listeners
// Logged exhaustively: the F07 finding "which raw key events still arrive
// while the IME composes" falls straight out of this stream.

extern (C) void onKbKeymap(void* data, wl_keyboard* kb, uint format, int fd, uint size) nothrow @nogc
{
    instrEvent("kb_keymap", "format=%u size=%u", format, size);
    if (format == WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1 && g_xkbCtx !is null)
    {
        void* mem = mmap(null, size, PROT_READ, MAP_PRIVATE, fd, 0);
        if (mem !is cast(void*)-1)
        {
            g_xkbKeymap = xkb_keymap_new_from_string(g_xkbCtx, cast(const(char)*) mem,
                XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
            if (g_xkbKeymap !is null)
                g_xkbState = xkb_state_new(g_xkbKeymap);
            munmap(mem, size);
        }
    }
    close(fd);
}

extern (C) void onKbEnter(void* data, wl_keyboard* kb, uint serial, wl_surface* s,
    wl_array* keys) nothrow @nogc
{
    instrEvent("kb_enter", "serial=%u pressed_keys=%zu", serial, keys.size / 4);
}

extern (C) void onKbLeave(void* data, wl_keyboard* kb, uint serial, wl_surface* s) nothrow @nogc
{
    instrEvent("kb_leave", "serial=%u", serial);
}

extern (C) void onKbKey(void* data, wl_keyboard* kb, uint serial, uint time,
    uint key, uint state) nothrow @nogc
{
    char[64] symName = '\0';
    char[8] utf8 = '\0';
    uint sym = 0;
    int utf8Len = 0;
    if (g_xkbState !is null)
    {
        immutable keycode = key + 8; // evdev → XKB keycode offset
        sym = xkb_state_key_get_one_sym(g_xkbState, keycode);
        xkb_keysym_get_name(sym, symName.ptr, symName.length);
        utf8Len = xkb_state_key_get_utf8(g_xkbState, keycode, utf8.ptr, utf8.length);
    }
    instrEvent("key", "serial=%u time=%u keycode=%u state=%s sym=0x%x name=%s utf8=\"%s\"",
        serial, time, key, state == 1 ? "pressed".ptr : "released".ptr,
        sym, symName.ptr, utf8.ptr);
    if (state != 1) // act on presses only
        return;

    // Local (non-IME) editing path: change_cause=other on the resulting state.
    if (sym == keyBackSpace && g_cursor > 0)
        deleteRange(cpPrev(g_cursor), g_cursor);
    else if (sym == keyLeft)
        g_cursor = g_cursor > 0 ? cpPrev(g_cursor) : 0;
    else if (sym == keyRight)
        g_cursor = cpNext(g_cursor);
    else if (sym == keyEscape)
    {
        g_running = false;
        return;
    }
    else if (utf8Len > 0 && cast(ubyte) utf8[0] >= 0x20 && utf8[0] != 0x7f)
        insertAtCursor(utf8.ptr, utf8Len);
    else
        return;
    logText();
    tiCommitState(false, 1); // 1 = change_cause other (keyboard, not the IM)
}

extern (C) void onKbModifiers(void* data, wl_keyboard* kb, uint serial,
    uint depressed, uint latched, uint locked, uint group) nothrow @nogc
{
    if (g_xkbState !is null)
        xkb_state_update_mask(g_xkbState, depressed, latched, locked, 0, 0, group);
    instrEvent("kb_modifiers", "depressed=0x%x latched=0x%x locked=0x%x group=%u",
        depressed, latched, locked, group);
}

extern (C) void onKbRepeatInfo(void* data, wl_keyboard* kb, int rate, int delay) nothrow @nogc
{
    instrEvent("kb_repeat_info", "rate=%d delay=%d", rate, delay);
}

// --------------------------------------------------------- shell + bookkeeping

extern (C) void onGlobal(void* data, wl_registry* reg, uint name,
    const(char)* iface, uint ver) nothrow @nogc
{
    instrEvent("global", "iface=%s version=%u", iface, ver); // the registry dump
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
        g_seat = cast(wl_seat*) wsi_registry_bind(reg, name, &wl_seat_interface, capped(ver, 4));
    else if (strcmp(iface, zwp_text_input_manager_v3_interface.name) == 0)
        g_tiManager = cast(zwp_text_input_manager_v3*) wsi_registry_bind(reg, name,
            &zwp_text_input_manager_v3_interface, 1);
}

extern (C) void onGlobalRemove(void* data, wl_registry* reg, uint name) nothrow @nogc
{
}

extern (C) void onWmBasePing(void* data, xdg_wm_base* b, uint serial) nothrow @nogc
{
    wsi_wm_base_pong(b, serial);
}

extern (C) void onSeatCapabilities(void* data, wl_seat* s, uint caps) nothrow @nogc
{
    instrEvent("seat_capabilities", "caps=0x%x", caps);
    enum uint capKeyboard = 2; // WL_SEAT_CAPABILITY_KEYBOARD
    if ((caps & capKeyboard) && g_keyboard is null)
    {
        g_keyboard = wsi_seat_get_keyboard(s);
        wsi_keyboard_add_listener(g_keyboard, &g_keyboardListener, null);
        instrStep("wl_seat_get_keyboard");
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
    g_width = g_pendingWidth > 0 ? g_pendingWidth : defaultWidth;
    g_height = g_pendingHeight > 0 ? g_pendingHeight : defaultHeight;
    wsi_xdg_surface_ack_configure(s, serial);
    if (!g_configured)
    {
        g_configured = true;
        instrFirstConfigure();
    }
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
    if (g_autoExit && (g_frames >= autoExitFrames || instrNowUs() > autoExitUsCap))
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
__gshared wl_keyboard_listener g_keyboardListener = {
    &onKbKeymap, &onKbEnter, &onKbLeave, &onKbKey, &onKbModifiers, &onKbRepeatInfo
};
__gshared zwp_text_input_v3_listener g_tiListener = {
    &onTiEnter, &onTiLeave, &onTiPreedit, &onTiCommitString,
    &onTiDeleteSurrounding, &onTiDone
};

// --------------------------------------------------------------------- main

int main()
{
    instrInit("f07_wayland");
    const autoEnv = getenv("WSI_AUTO_EXIT");
    g_autoExit = autoEnv !is null && *autoEnv == '1';

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
    // The two F07-specific capability probes — each absence is itself a finding.
    instrEvent("text_input_manager", "present=%d", g_tiManager !is null ? 1 : 0);
    instrEvent("seat", "present=%d", g_seat !is null ? 1 : 0);
    wsi_wm_base_add_listener(g_wmBase, &g_wmBaseListener, null);
    if (g_seat !is null)
        wsi_seat_add_listener(g_seat, &g_seatListener, null);
    if (g_tiManager !is null && g_seat !is null)
    {
        g_ti = wsi_text_input_manager_get_text_input(g_tiManager, g_seat);
        wsi_text_input_add_listener(g_ti, &g_tiListener, null);
        instrStep("zwp_text_input_manager_v3_get_text_input");
    }
    g_xkbCtx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);

    g_surface = wsi_compositor_create_surface(g_compositor);
    g_xdgSurface = wsi_wm_base_get_xdg_surface(g_wmBase, g_surface);
    wsi_xdg_surface_add_listener(g_xdgSurface, &g_xdgSurfaceListener, null);
    g_toplevel = wsi_xdg_surface_get_toplevel(g_xdgSurface);
    wsi_toplevel_add_listener(g_toplevel, &g_toplevelListener, null);
    wsi_toplevel_set_title(g_toplevel, "wsi-f07-text-input");
    wsi_toplevel_set_app_id(g_toplevel, "wsi-f07-text-input");
    instrWindowCreated();
    wsi_surface_commit(g_surface); // mandatory no-buffer first commit

    // Poll-based pump (the F04 lesson): a blocking wl_display_dispatch would
    // hang forever if the compositor goes quiet (sway throttles invisible
    // surfaces; an IME run waits on external events), so poll with a timeout
    // keeps the wall-clock auto-exit live during protocol silence.
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
        if (g_autoExit && instrNowUs() > autoExitUsCap)
            g_running = false;
    }

    // Teardown: children before parents.
    if (g_ti !is null)
        wsi_text_input_destroy(g_ti);
    if (g_tiManager !is null)
        wsi_text_input_manager_destroy(g_tiManager);
    if (g_keyboard !is null)
        wsi_keyboard_destroy(g_keyboard);
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
        }
    if (g_frameCb !is null)
        wsi_callback_destroy(g_frameCb);
    wsi_toplevel_destroy(g_toplevel);
    wsi_xdg_surface_destroy(g_xdgSurface);
    wsi_surface_destroy(g_surface);
    wsi_wm_base_destroy(g_wmBase);
    if (g_seat !is null)
        wl_proxy_destroy(cast(wl_proxy*) g_seat);
    wl_proxy_destroy(cast(wl_proxy*) g_shm);
    wl_proxy_destroy(cast(wl_proxy*) g_compositor);
    wl_proxy_destroy(cast(wl_proxy*) g_registry);
    wl_display_disconnect(g_display);

    printf("ok: frames=%d ti_present=%d ti_commits=%u final_text=\"%s\"\n",
        g_frames, g_ti !is null ? 1 : 0, g_tiCommits, g_text.ptr);
    return 0;
}
