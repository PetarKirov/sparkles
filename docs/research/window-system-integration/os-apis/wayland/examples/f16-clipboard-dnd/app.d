// F16 clipboard + DnD demo — wl_data_device_manager on top of the xdg-shell
// scaffold (../scaffold/app.d; findings: ../../f16-clipboard-dnd.md).
//
// ONE client, TWO toplevels (A = wsi-f16-a, the source; B = wsi-f16-b, the
// drop target) — clipboard and drag-and-drop are the SAME machinery
// (wl_data_source / wl_data_offer over pipe fds), exercised end to end:
//
//   stale probe   at startup, before ANY input event exists, a wl_data_source
//                 is offered and wl_data_device.set_selection(serial=0) is
//                 attempted — the Wayland divergence under test: the clipboard
//                 cannot be claimed without a recent input serial. ./run.sh
//                 then proves with `wl-paste` (a real second client) that no
//                 selection was installed.
//   copy          an injected right-click on A yields a REAL serial; a new
//                 source offering text/plain;charset=utf-8 + text/plain
//                 (payload é漢🎈) is installed; `wl-paste -l` / `wl-paste`
//                 read it back (the demo serves wl_data_source.send by
//                 writing the fd) — then `wl-copy` takes the selection over
//                 and the demo logs wl_data_source.cancelled (ownership loss).
//   paste         when a wtype-plugged keyboard gives the client keyboard
//                 focus, wl_data_device.data_offer + selection deliver
//                 wl-copy's offer; the demo logs the offered MIME types and
//                 receives the bytes through its own pipe.
//   dnd           an injected left-press on A starts
//                 wl_data_device.start_drag (actions copy|move) WHILE the
//                 button is held; the injector sweeps the pointer into B and
//                 releases. Both sides of the negotiation are one process,
//                 so the full sequence is in one log: enter(A)/motion/leave,
//                 enter(B), offer accept + set_actions(preferred=move),
//                 source_actions/action, drop, receive-pipe transfer,
//                 finish, dnd_drop_performed, dnd_finished.
//
// Headless-safe: no compositor → SKIP, exit 0; a seat-less compositor
// (headless weston) logs the registry probe and exits 0.
module app;

import c; // ImportC: wayland-client + xdg-shell glue + pipe/poll
import instrument;
import core.stdc.stdio : printf;
import core.stdc.stdlib : atoi, getenv;
import core.stdc.string : strcmp, strlen, strncpy;

enum int winWidth = 640;
enum int winHeight = 480;
enum uint BTN_LEFT = 0x110, BTN_RIGHT = 0x111;

__gshared immutable char* mimeUtf8 = "text/plain;charset=utf-8";
__gshared immutable char* mimePlain = "text/plain";
__gshared immutable char* clipPayload = "é漢🎈"; // 9 UTF-8 bytes
__gshared immutable char* dndPayload = "dnd-payload-é漢🎈";

// -------------------------------------------------------------------- state

struct Buffer
{
    wl_buffer* handle;
    uint* pixels;
    size_t byteSize;
    int width, height;
    bool busy;
}

struct Surf
{
    wl_surface* surface;
    xdg_surface* xdgSurface;
    xdg_toplevel* toplevel;
    Buffer[2] buffers;
    int width = winWidth, height = winHeight;
    int pendingW, pendingH;
    bool configured;
}

/// One in-flight wl_data_offer.receive transfer (read end of the pipe).
struct Pipe
{
    int fd = -1;
    wl_data_offer* offer;
    char[4096] buf;
    size_t len;
}

/// MIME types announced by a wl_data_offer before its enter/selection event.
struct OfferInfo
{
    wl_data_offer* offer;
    char[64][8] mimes; // up to 8 MIME strings of 63 chars
    int mimeCount;
    uint sourceActions;
}

enum size_t IDX_A = 0, IDX_B = 1;
__gshared immutable(char*)[2] g_surfNames = ["A", "B"];

__gshared
{
    wl_display* g_display;
    wl_registry* g_registry;
    wl_compositor* g_compositor;
    wl_shm* g_shm;
    xdg_wm_base* g_wmBase;
    wl_seat* g_seat;
    wl_pointer* g_pointer;
    wl_keyboard* g_keyboard;
    wl_data_device_manager* g_ddm;
    uint g_ddmVersion;
    wl_data_device* g_dataDevice;
    wl_data_source* g_selSource; // currently installed selection source
    wl_data_source* g_staleSource; // the serial=0 probe source
    wl_data_source* g_dragSource;
    wl_data_offer* g_dndOffer; // current drag offer (target side)
    OfferInfo[4] g_offers;

    Surf[2] g_surfs;
    int g_focusIdx = -1;
    double g_ptrX, g_ptrY;
    uint g_dndEnterSerial;
    int g_dndMotions;
    Pipe[2] g_pipes; // [0] selection paste, [1] dnd drop — independent
    bool g_running = true, g_autoExit, g_staleProbeSent;
    bool g_dndFinished;
    long g_runUsCap = 2_500_000;
    long g_firstPaintUs = -1, g_exitAtUs = -1;
    int g_frames;
}

// ---------------------------------------------------------- offer registry

OfferInfo* offerInfo(wl_data_offer* o) nothrow @nogc
{
    foreach (ref oi; g_offers)
        if (oi.offer is o)
            return &oi;
    return null;
}

OfferInfo* offerInfoNew(wl_data_offer* o) nothrow @nogc
{
    foreach (ref oi; g_offers)
        if (oi.offer is null)
        {
            oi.offer = o;
            oi.mimeCount = 0;
            oi.sourceActions = 0;
            return &oi;
        }
    g_offers[0].offer = o; // recycle the oldest slot
    g_offers[0].mimeCount = 0;
    g_offers[0].sourceActions = 0;
    return &g_offers[0];
}

void offerInfoDrop(wl_data_offer* o) nothrow @nogc
{
    foreach (ref oi; g_offers)
        if (oi.offer is o)
            oi.offer = null;
}

void logOfferMimes(const(char)* kind, OfferInfo* oi) nothrow @nogc
{
    instrEvent(kind, "mime_count=%d", oi !is null ? oi.mimeCount : -1);
    if (oi !is null)
        foreach (i; 0 .. oi.mimeCount)
            instrEvent("offer_mime", "i=%d mime=%s", i, oi.mimes[i].ptr);
}

bool offerHas(OfferInfo* oi, const(char)* mime) nothrow @nogc
{
    if (oi is null)
        return false;
    foreach (i; 0 .. oi.mimeCount)
        if (strcmp(oi.mimes[i].ptr, mime) == 0)
            return true;
    return false;
}

// ------------------------------------------------------------ data source

extern (C) void onSourceTarget(void* data, wl_data_source* s, const(char)* mime) nothrow @nogc
{
    // DnD only: the target's current accept state (null = would reject).
    instrEvent("source_target", "mime=%s", mime !is null ? mime : "(null)");
}

extern (C) void onSourceSend(void* data, wl_data_source* s, const(char)* mime, int fd) nothrow @nogc
{
    const(char)* payload = s is g_dragSource ? dndPayload : clipPayload;
    immutable len = strlen(payload);
    immutable written = write(fd, payload, len);
    close(fd);
    instrEvent("clip_send", "source=%s fmt=%s bytes=%lld",
        s is g_dragSource ? "dnd".ptr : "selection".ptr, mime, cast(long) written);
}

extern (C) void onSourceCancelled(void* data, wl_data_source* s) nothrow @nogc
{
    // Selection: ownership loss (another client set the selection).
    // DnD: the drag was rejected/ended without a successful drop.
    instrEvent("ownership_lost", "source=%s",
        s is g_dragSource ? "dnd".ptr : (s is g_staleSource ? "stale".ptr : "selection".ptr));
    if (s is g_selSource)
        g_selSource = null;
    else if (s is g_staleSource)
        g_staleSource = null;
    else if (s is g_dragSource)
        g_dragSource = null;
    wsi_data_source_destroy(s);
}

extern (C) void onSourceDndDropPerformed(void* data, wl_data_source* s) nothrow @nogc
{
    instrEvent("source_dnd_drop_performed");
}

extern (C) void onSourceDndFinished(void* data, wl_data_source* s) nothrow @nogc
{
    instrEvent("source_dnd_finished", "note=target-done-source-may-delete-on-move");
    if (s is g_dragSource)
        g_dragSource = null;
    wsi_data_source_destroy(s);
    g_dndFinished = true;
    g_exitAtUs = instrNowUs() + 1_000_000; // wind down shortly after
}

extern (C) void onSourceAction(void* data, wl_data_source* s, uint action) nothrow @nogc
{
    instrEvent("source_action", "dnd_action=%u", action);
}

__gshared wl_data_source_listener g_sourceListener = {
    &onSourceTarget, &onSourceSend, &onSourceCancelled,
    &onSourceDndDropPerformed, &onSourceDndFinished, &onSourceAction
};

wl_data_source* makeTextSource(bool forDnd) nothrow @nogc
{
    wl_data_source* s = wsi_ddm_create_data_source(g_ddm);
    wsi_data_source_add_listener(s, &g_sourceListener, null);
    wsi_data_source_offer(s, mimeUtf8);
    wsi_data_source_offer(s, mimePlain);
    if (forDnd && g_ddmVersion >= 3)
        wsi_data_source_set_actions(s,
            WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY | WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE);
    instrEvent("clip_offer", "kind=%s formats=[%s,%s]%s",
        forDnd ? "dnd".ptr : "selection".ptr, mimeUtf8, mimePlain,
        forDnd ? " actions=copy|move".ptr : "".ptr);
    return s;
}

// ------------------------------------------------------------- data offer

extern (C) void onOfferOffer(void* data, wl_data_offer* o, const(char)* mime) nothrow @nogc
{
    OfferInfo* oi = offerInfo(o);
    if (oi !is null && oi.mimeCount < oi.mimes.length)
    {
        strncpy(oi.mimes[oi.mimeCount].ptr, mime, 63);
        oi.mimes[oi.mimeCount][63] = '\0';
        oi.mimeCount++;
    }
}

extern (C) void onOfferSourceActions(void* data, wl_data_offer* o, uint actions) nothrow @nogc
{
    OfferInfo* oi = offerInfo(o);
    if (oi !is null)
        oi.sourceActions = actions;
    instrEvent("offer_source_actions", "actions=%u", actions);
}

extern (C) void onOfferAction(void* data, wl_data_offer* o, uint action) nothrow @nogc
{
    // The compositor's pick from source-actions ∩ target-actions (and the
    // target's preference) — who chose copy vs move, answered here.
    instrEvent("offer_action", "dnd_action=%u note=compositor-resolved", action);
}

__gshared wl_data_offer_listener g_offerListener = {
    &onOfferOffer, &onOfferSourceActions, &onOfferAction
};

/// Begin an fd transfer from `o` (slot 0 = selection paste, slot 1 = dnd
/// post-drop read); the pipe's read end joins the poll loop and is drained
/// to EOF there. The two slots are independent — a selection offer
/// re-delivered right after a drop must not clobber the dnd transfer.
void receiveFrom(wl_data_offer* o, bool isDnd) nothrow @nogc
{
    Pipe* p = &g_pipes[isDnd ? 1 : 0];
    if (p.fd >= 0)
    {
        close(p.fd);
        p.fd = -1;
    }
    int[2] fds;
    if (wsi_pipe2_cloexec(fds.ptr) != 0)
        return;
    wsi_data_offer_receive(o, mimeUtf8, fds[1]);
    close(fds[1]);
    wl_display_flush(g_display);
    p.fd = fds[0];
    p.offer = o;
    p.len = 0;
    instrEvent("clip_request", "kind=%s fmt=%s", isDnd ? "dnd".ptr : "selection".ptr, mimeUtf8);
}

void drainPipe(bool isDnd) nothrow @nogc
{
    Pipe* p = &g_pipes[isDnd ? 1 : 0];
    immutable n = read(p.fd, p.buf.ptr + p.len, p.buf.length - 1 - p.len);
    if (n > 0)
    {
        p.len += n;
        return;
    }
    close(p.fd);
    p.fd = -1;
    p.buf[p.len] = '\0';
    instrEvent(isDnd ? "dnd_drop_data" : "paste_data",
        "bytes=%lld text=%s", cast(long) p.len, p.buf.ptr);
    if (isDnd && p.offer !is null)
    {
        if (g_ddmVersion >= 3)
            wsi_data_offer_finish(p.offer); // "the drag-and-drop operation ended successfully"
        instrEvent("dnd_finish_sent");
        wsi_data_offer_destroy(p.offer);
        offerInfoDrop(p.offer);
        if (g_dndOffer is p.offer)
            g_dndOffer = null;
    }
    p.offer = null;
}

// ------------------------------------------------------------- data device

extern (C) void onDataOffer(void* data, wl_data_device* d, wl_data_offer* o) nothrow @nogc
{
    // A new offer object: its MIME list arrives as offer events BEFORE the
    // enter/selection event that tells us what it is for.
    offerInfoNew(o);
    wsi_data_offer_add_listener(o, &g_offerListener, null);
    instrEvent("data_offer", "offer=%p", o);
}

extern (C) void onDndEnter(void* data, wl_data_device* d, uint serial,
    wl_surface* surface, int x, int y, wl_data_offer* o) nothrow @nogc
{
    immutable idx = surfIndexOf(surface);
    g_dndEnterSerial = serial;
    g_dndOffer = o;
    OfferInfo* oi = offerInfo(o);
    instrEvent("dnd_enter", "surface=%s serial=%u pos=%.1f,%.1f",
        idx >= 0 ? g_surfNames[idx] : "other", serial, x / 256.0, y / 256.0);
    logOfferMimes("dnd_enter_formats", oi);
    if (o !is null && offerHas(oi, mimeUtf8))
    {
        // Target-side negotiation: accept the mime, then declare our action
        // set + preference (the compositor resolves the final dnd_action).
        wsi_data_offer_accept(o, serial, mimeUtf8);
        if (g_ddmVersion >= 3)
            wsi_data_offer_set_actions(o,
                WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY | WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE,
                WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE);
        instrEvent("dnd_accept", "serial=%u fmt=%s actions=copy|move preferred=move",
            serial, mimeUtf8);
    }
}

extern (C) void onDndLeave(void* data, wl_data_device* d) nothrow @nogc
{
    instrEvent("dnd_leave", "motions_seen=%d", g_dndMotions);
    g_dndOffer = null;
}

extern (C) void onDndMotion(void* data, wl_data_device* d, uint time, int x, int y) nothrow @nogc
{
    g_dndMotions++;
    if (g_dndMotions <= 2 || g_dndMotions % 4 == 0)
        instrEvent("dnd_motion", "n=%d pos=%.1f,%.1f", g_dndMotions, x / 256.0, y / 256.0);
}

extern (C) void onDndDrop(void* data, wl_data_device* d) nothrow @nogc
{
    instrEvent("dnd_drop", "have_offer=%d", g_dndOffer !is null ? 1 : 0);
    if (g_dndOffer !is null)
        receiveFrom(g_dndOffer, true);
}

extern (C) void onSelection(void* data, wl_data_device* d, wl_data_offer* o) nothrow @nogc
{
    if (o is null)
    {
        instrEvent("selection", "offer=null note=selection-cleared");
        return;
    }
    OfferInfo* oi = offerInfo(o);
    instrEvent("selection", "offer=%p own_source=%d", o, g_selSource !is null ? 1 : 0);
    logOfferMimes("selection_formats", oi);
    if (g_selSource is null && offerHas(oi, mimeUtf8))
        receiveFrom(o, false); // paste: another client's clipboard
    else
    {
        wsi_data_offer_destroy(o);
        offerInfoDrop(o);
    }
}

__gshared wl_data_device_listener g_dataDeviceListener = {
    &onDataOffer, &onDndEnter, &onDndLeave, &onDndMotion, &onDndDrop, &onSelection
};

// ----------------------------------------------------------------- pointer

int surfIndexOf(wl_surface* s) nothrow @nogc
{
    foreach (i, ref sf; g_surfs)
        if (sf.surface is s)
            return cast(int) i;
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
}

extern (C) void onPointerLeave(void* data, wl_pointer* p, uint serial, wl_surface* surf) nothrow @nogc
{
    g_focusIdx = -1;
}

extern (C) void onPointerMotion(void* data, wl_pointer* p, uint time, int sx, int sy) nothrow @nogc
{
    g_ptrX = sx / 256.0;
    g_ptrY = sy / 256.0;
}

extern (C) void onPointerButton(void* data, wl_pointer* p, uint serial, uint time,
    uint button, uint state) nothrow @nogc
{
    instrEvent("button", "surface=%s serial=%u button=0x%x state=%u",
        g_focusIdx >= 0 ? g_surfNames[g_focusIdx] : "none", serial, button, state);
    if (state != WL_POINTER_BUTTON_STATE_PRESSED || g_focusIdx != IDX_A)
        return;
    if (button == BTN_RIGHT)
    {
        // COPY with a REAL input serial — the valid counterpart of the
        // startup stale-serial probe.
        if (g_selSource !is null)
        {
            wsi_data_source_destroy(g_selSource);
            g_selSource = null;
        }
        g_selSource = makeTextSource(false);
        wsi_data_device_set_selection(g_dataDevice, g_selSource, serial);
        instrEvent("set_selection", "serial=%u note=valid-input-serial", serial);
    }
    else if (button == BTN_LEFT && g_dragSource is null)
    {
        // DnD: start_drag must carry the serial of an implicit grab — the
        // injector holds BTN_LEFT down through the whole sweep.
        g_dragSource = makeTextSource(true);
        wsi_data_device_start_drag(g_dataDevice, g_dragSource,
            g_surfs[IDX_A].surface, null, serial);
        instrEvent("dnd_start", "origin=A serial=%u icon=none", serial);
    }
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
    close(fd);
}

extern (C) void onKeyboardEnter(void* data, wl_keyboard* kb, uint serial,
    wl_surface* surf, wl_array* keys) nothrow @nogc
{
    // The selection offer is delivered around THIS moment — "when a client
    // gains keyboard focus" is the delivery contract for selection events.
    immutable idx = surfIndexOf(surf);
    instrEvent("keyboard_enter", "surface=%s serial=%u",
        idx >= 0 ? g_surfNames[idx] : "other", serial);
}

extern (C) void onKeyboardLeave(void* data, wl_keyboard* kb, uint serial, wl_surface* surf) nothrow @nogc {}
extern (C) void onKey(void* data, wl_keyboard* kb, uint serial, uint time, uint key, uint state) nothrow @nogc
{
    instrEvent("key", "key=%u state=%u serial=%u", key, state, serial);
}

extern (C) void onModifiers(void* data, wl_keyboard* kb, uint serial,
    uint depressed, uint latched, uint locked, uint group) nothrow @nogc {}
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
        g_wmBase = cast(xdg_wm_base*) wsi_registry_bind(reg, name, &xdg_wm_base_interface, 1);
    else if (strcmp(iface, wl_seat_interface.name) == 0 && g_seat is null)
    {
        g_seat = cast(wl_seat*) wsi_registry_bind(reg, name, &wl_seat_interface, capped(ver, 5));
        wsi_seat_add_listener(g_seat, &g_seatListener, null);
    }
    else if (strcmp(iface, wl_data_device_manager_interface.name) == 0)
    {
        // v3 = dnd actions (set_actions / action / finish).
        g_ddmVersion = capped(ver, 3);
        g_ddm = cast(wl_data_device_manager*) wsi_registry_bind(reg, name,
            &wl_data_device_manager_interface, g_ddmVersion);
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
    immutable fd = memfd_create("wsi-f16", MFD_CLOEXEC);
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
    immutable uint bg = idx == IDX_A ? 0xff35506a : 0xff6a5035; // A blue, B amber
    foreach (y; 0 .. buf.height)
        foreach (x; 0 .. buf.width)
            buf.pixels[cast(size_t) y * buf.width + x] = bg;
    wsi_surface_attach(s.surface, buf.handle, 0, 0);
    wsi_surface_damage_buffer(s.surface, 0, 0, buf.width, buf.height);
    wsi_surface_commit(s.surface);
    buf.busy = true;
    g_frames++;
}

extern (C) void onWmBasePing(void* data, xdg_wm_base* b, uint serial) nothrow @nogc
{
    wsi_wm_base_pong(b, serial);
}

extern (C) void onToplevelConfigure(void* data, xdg_toplevel* t, int w, int h,
    wl_array* states) nothrow @nogc
{
    Surf* s = &g_surfs[cast(size_t) data];
    s.pendingW = w;
    s.pendingH = h;
}

extern (C) void onXdgSurfaceConfigure(void* data, xdg_surface* s, uint serial) nothrow @nogc
{
    immutable idx = cast(size_t) data;
    Surf* sf = &g_surfs[idx];
    sf.width = sf.pendingW > 0 ? sf.pendingW : winWidth;
    sf.height = sf.pendingH > 0 ? sf.pendingH : winHeight;
    wsi_xdg_surface_ack_configure(s, serial);
    sf.configured = true;
    render(idx);
    if (g_firstPaintUs < 0 && g_surfs[IDX_A].configured && g_surfs[IDX_B].configured)
    {
        g_firstPaintUs = instrNowUs();
        instrFirstConfigure();
    }
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

__gshared xdg_wm_base_listener g_wmBaseListener = {&onWmBasePing};
__gshared xdg_surface_listener g_xdgSurfaceListener = {&onXdgSurfaceConfigure};
__gshared xdg_toplevel_listener g_toplevelListener = {
    &onToplevelConfigure, &onToplevelClose,
    &onToplevelConfigureBounds, &onToplevelWmCapabilities
};
__gshared wl_buffer_listener g_bufferListener = {&onBufferRelease};

void makeWindow(size_t idx, const(char)* appId) nothrow @nogc
{
    Surf* s = &g_surfs[idx];
    s.surface = wsi_compositor_create_surface(g_compositor);
    s.xdgSurface = wsi_wm_base_get_xdg_surface(g_wmBase, s.surface);
    wsi_xdg_surface_add_listener(s.xdgSurface, &g_xdgSurfaceListener, cast(void*) idx);
    s.toplevel = wsi_xdg_surface_get_toplevel(s.xdgSurface);
    wsi_toplevel_add_listener(s.toplevel, &g_toplevelListener, cast(void*) idx);
    wsi_toplevel_set_title(s.toplevel, appId);
    wsi_toplevel_set_app_id(s.toplevel, appId);
    wsi_surface_commit(s.surface);
}

// --------------------------------------------------------------------- main

/// The startup probe: set_selection with serial=0 before ANY input event
/// exists anywhere on this connection. THE Wayland clipboard divergence:
/// without a recent input serial there is no clipboard write.
void staleSelectionProbe() nothrow @nogc
{
    g_staleSource = makeTextSource(false);
    wsi_data_device_set_selection(g_dataDevice, g_staleSource, 0);
    wl_display_flush(g_display);
    g_staleProbeSent = true;
    instrEvent("set_selection", "serial=0 note=stale-no-input-event-exists");
}

int main(string[] args)
{
    static int parseInt(in char[] s) nothrow @nogc
    {
        int v;
        foreach (ch; s)
            if (ch >= '0' && ch <= '9')
                v = v * 10 + (ch - '0');
        return v;
    }

    if (args.length >= 2 && args[1].length >= 4 && args[1][0 .. 4] == "inje")
    {
        import inject : injectClick, injectDrag;

        if (args.length == 6 && args[2].length >= 2 && args[2][0 .. 2] == "cl")
            return injectClick(parseInt(args[3]), parseInt(args[4]), parseInt(args[5]));
        if (args.length == 7 && args[2].length >= 2 && args[2][0 .. 2] == "dr")
            return injectDrag(parseInt(args[3]), parseInt(args[4]),
                parseInt(args[5]), parseInt(args[6]));
        printf("usage: inject click <x> <y> <btn> | inject drag <x1> <y1> <x2> <y2>\n");
        return 2;
    }

    instrInit("f16_wayland");
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
    instrEvent("globals", "data_device_manager=%d version=%u seat=%d",
        g_ddm !is null ? 1 : 0, g_ddmVersion, g_seat !is null ? 1 : 0);
    if (g_ddm is null || g_seat is null)
    {
        // headless weston: wl_data_device_manager IS advertised, but with no
        // seat there is no wl_data_device to bind it to — the clipboard is
        // seat-scoped by construction. Registry probe is the Tier-A evidence.
        printf("ok: data_device_manager=%d but seat=%d; clipboard is seat-scoped, nothing to exercise\n",
            g_ddm !is null ? 1 : 0, g_seat !is null ? 1 : 0);
        wl_display_disconnect(g_display);
        return 0;
    }

    g_dataDevice = wsi_ddm_get_data_device(g_ddm, g_seat);
    wsi_data_device_add_listener(g_dataDevice, &g_dataDeviceListener, null);

    wsi_wm_base_add_listener(g_wmBase, &g_wmBaseListener, null);
    makeWindow(IDX_A, "wsi-f16-a");
    makeWindow(IDX_B, "wsi-f16-b");
    instrWindowCreated();

    immutable dispFd = wl_display_get_fd(g_display);
    while (g_running)
    {
        while (wl_display_prepare_read(g_display) != 0)
            wl_display_dispatch_pending(g_display);
        wl_display_flush(g_display);
        pollfd[3] pfds = [
            pollfd(dispFd, POLLIN, 0),
            pollfd(g_pipes[0].fd, POLLIN, 0),
            pollfd(g_pipes[1].fd, POLLIN, 0),
        ];
        if (poll(pfds.ptr, 3, 50) > 0 && (pfds[0].revents & POLLIN))
            wl_display_read_events(g_display);
        else
            wl_display_cancel_read(g_display);
        if (wl_display_dispatch_pending(g_display) == -1)
        {
            instrEvent("display_error", "errno=%d", wl_display_get_error(g_display));
            break;
        }
        foreach (i; 0 .. 2)
            if (g_pipes[i].fd >= 0 && (pfds[i + 1].revents & (POLLIN | POLLHUP)))
                drainPipe(i == 1);
        if (!g_staleProbeSent && g_firstPaintUs >= 0
            && instrNowUs() > g_firstPaintUs + 300_000)
            staleSelectionProbe();
        if (g_exitAtUs >= 0 && instrNowUs() > g_exitAtUs)
            g_running = false;
        if (g_autoExit && instrNowUs() > g_runUsCap)
            g_running = false;
    }

    instrEvent("summary", "dnd_finished=%d dnd_motions=%d sel_source_alive=%d",
        g_dndFinished ? 1 : 0, g_dndMotions, g_selSource !is null ? 1 : 0);

    // Teardown: children before parents.
    foreach (ref p; g_pipes)
        if (p.fd >= 0)
            close(p.fd);
    if (g_dragSource !is null)
        wsi_data_source_destroy(g_dragSource);
    if (g_selSource !is null)
        wsi_data_source_destroy(g_selSource);
    if (g_staleSource !is null)
        wsi_data_source_destroy(g_staleSource);
    if (g_dataDevice !is null)
        wsi_data_device_release(g_dataDevice);
    if (g_ddm !is null)
        wsi_ddm_destroy(g_ddm);
    foreach (idx; 0 .. g_surfs.length)
    {
        Surf* s = &g_surfs[idx];
        foreach (ref b; s.buffers)
            if (b.handle !is null)
            {
                wsi_buffer_destroy(b.handle);
                munmap(b.pixels, b.byteSize);
            }
        wsi_toplevel_destroy(s.toplevel);
        wsi_xdg_surface_destroy(s.xdgSurface);
        wsi_surface_destroy(s.surface);
    }
    if (g_keyboard !is null)
        wsi_keyboard_destroy(g_keyboard);
    if (g_pointer !is null)
        wsi_pointer_destroy(g_pointer);
    if (g_seat !is null)
        wsi_seat_destroy(g_seat);
    wsi_wm_base_destroy(g_wmBase);
    wl_proxy_destroy(cast(wl_proxy*) g_shm);
    wl_proxy_destroy(cast(wl_proxy*) g_compositor);
    wl_proxy_destroy(cast(wl_proxy*) g_registry);
    wl_display_disconnect(g_display);

    printf("ok: dnd_finished=%d dnd_motions=%d\n", g_dndFinished ? 1 : 0, g_dndMotions);
    return 0;
}
