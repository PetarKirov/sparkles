/**
Native X11/XCB lifecycle integrated as an Event Horizon foreign fd.

XCB owns no blocking loop: its connection descriptor is armed with
`OpPollAdd`, completions only mark readiness, and `runIntegratedOnce` drains
native values before re-arming the same Event Horizon loop. XIM/keymap work is
a later input slice and cannot introduce another display connection or wait.

The clipboard is the `CLIPBOARD` selection, owned by a hidden `InputOnly`
helper window that is also the requestor of every conversion; transfers past
one 64 KiB property go `INCR`, and XFixes reports another client taking the
selection.
*/
module sparkles.wsi.platform.x11;

version (linux):

import core.stdc.stdlib : free;
import core.stdc.string : strlen;
import core.sys.posix.pthread : pthread_equal, pthread_self, pthread_t;
import core.time : Duration, MonoTime;

import sparkles.base.pool.pool : Pool, PoolError;
import sparkles.base.text.utf8 : validateUtf8;
import sparkles.event_horizon.errors : IoErrorStage, IoResult, OpKind,
    ioErr, ioOk;
import sparkles.event_horizon.loop : DefaultLoop, RunStatus;
import sparkles.event_horizon.op : Completion, OpHandle, OpPollAdd, PollEvents;
import sparkles.input.events : KeyAction, Mods, PointerButton;
import sparkles.input.pointer : PointerShape;
import sparkles.base.buffer : UniqueBuffer;
import sparkles.wsi.clipboard;
import sparkles.wsi.events;
import sparkles.wsi.handles;
import sparkles.wsi.history : PointerSample;
import sparkles.wsi.loop : EventQueue;
import sparkles.wsi.types;

import xcb_native;

/** One UI-thread XCB connection and its bounded native event queue. */
struct X11Wsi
{
    enum maxWindows = 16;
    enum maxEvents = 128;

    @disable this(this);

    private struct Slot
    {
        uint window;
        bool ready;
        SurfaceMetrics metrics;
        uint cursor;
        ushort xic;
        bool xicReady;
        PointerCaptureMode captureMode;
        bool relativePointer;
    }

    private struct Bootstrap
    {
        int screenIndex;
        int fd = -1;
        uint root;
        uint rootVisual;
        uint blackPixel;
        uint wmProtocols;
        uint wmDeleteWindow;
    }

    private xcb_connection_t* connection_;
    private Bootstrap bootstrap_;
    private uint cursorFont_;
    private xkb_context* xkbContext_;
    private xkb_keymap* xkbKeymap_;
    private xkb_state* xkbState_;
    private pthread_t ownerThread_;
    private Pool!(WindowId, Slot, maxWindows) windows_;
    private EventQueue!maxEvents events_;
    private ulong nextSequence_ = 1;
    private bool open_;
    private bool closed_;
    private bool hasStickyError_;
    private WsiError stickyError_;

    private DefaultLoop* loop_;
    private OpHandle pollHandle_;
    private bool pollArmed_;
    private bool pollCompleted_;
    private int pollResult_;
    private bool detaching_;
    private ulong[4] pressedKeys_;
    private xcb_xim_t* xim_;
    private bool ximConnected_;
    private WindowId pendingIc_; // the window whose input context is in flight
    private ubyte xiOpcode_;
    private bool xiRawSelected_;
    // Per XInput device id: 0 unknown, 1 relative x/y axes, 2 anything
    // else. Reset whenever the device hierarchy or a device's classes
    // change, so a reused id cannot inherit a stale answer.
    private ubyte[256] rawDeviceKind_;

    /** Connects to the process' selected X display on the calling UI thread. */
    static WsiResult!void open(out X11Wsi wsi)
    {
        int screenIndex;
        auto connection = xcb_connect(null, &screenIndex);
        const connectError = connection is null
            ? -1 : xcb_connection_has_error(connection);
        if (connectError != 0)
        {
            if (connection !is null)
                xcb_disconnect(connection);
            return x11Failure!void(WsiOperation.open, connectError,
                "xcb_connect failed", WsiErrorKind.unavailable);
        }

        auto screens = xcb_setup_roots_iterator(xcb_get_setup(connection));
        foreach (_; 0 .. screenIndex)
        {
            if (screens.rem == 0)
                break;
            xcb_screen_next(&screens);
        }
        if (screens.rem == 0)
        {
            xcb_disconnect(connection);
            return x11Failure!void(WsiOperation.open, 0,
                "selected X screen does not exist");
        }

        wsi.bootstrap_ = Bootstrap(
            screenIndex: screenIndex,
            fd: xcb_get_file_descriptor(connection),
            root: screens.data.root,
            rootVisual: screens.data.root_visual,
            blackPixel: screens.data.black_pixel,
            wmProtocols: internAtom(connection, "WM_PROTOCOLS"),
            wmDeleteWindow: internAtom(connection, "WM_DELETE_WINDOW"));
        if (wsi.bootstrap_.fd < 0 || wsi.bootstrap_.wmProtocols == 0
            || wsi.bootstrap_.wmDeleteWindow == 0)
        {
            xcb_disconnect(connection);
            return x11Failure!void(WsiOperation.open, 0,
                "XCB bootstrap lacks a descriptor or the WM atoms");
        }
        wsi.connection_ = connection;
        // Best effort: without XKB the server keeps synthesizing a release
        // before each repeated press, and held keys read as typing.
        enableDetectableAutorepeat(connection);
        wsi.openKeymap();
        wsi.openXInput();
        wsi.openClipboard();
        wsi.ownerThread_ = pthread_self();
        wsi.open_ = true;
        return wsiOk();
    }

    /*
    Best-effort xkbcommon-x11 layout behind logical keys: a server without
    the extension leaves logical identity unknown while physical identity
    keeps flowing. Keymap-change events are a later slice.
    */
    private void openKeymap()
    {
        if (xkb_x11_setup_xkb_extension(connection_,
                XKB_X11_MIN_MAJOR_XKB_VERSION, XKB_X11_MIN_MINOR_XKB_VERSION,
                XKB_X11_SETUP_XKB_EXTENSION_NO_FLAGS,
                null, null, null, null) == 0)
            return;
        const device = xkb_x11_get_core_keyboard_device_id(connection_);
        if (device < 0)
            return;
        xkbContext_ = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
        if (xkbContext_ is null)
            return;
        xkbKeymap_ = xkb_x11_keymap_new_from_device(xkbContext_, connection_,
            device, XKB_KEYMAP_COMPILE_NO_FLAGS);
        if (xkbKeymap_ !is null)
            xkbState_ = xkb_x11_state_new_from_device(xkbKeymap_,
                connection_, device);
    }

    /// Unshifted base-level identity under the current layout; X keycodes
    /// are already xkb keycodes.
    private LogicalKey logicalForKey(uint keycode, uint coreState)
        nothrow @nogc
    {
        if (xkbKeymap_ is null || xkbState_ is null)
            return LogicalKey.init;
        // The core state mask shares xkb's real-modifier positions and
        // carries the group in bits 13–14.
        xkb_state_update_mask(xkbState_, coreState & 0xFF, 0, 0, 0, 0,
            (coreState >> 13) & 3);
        const layout = xkb_state_key_get_layout(xkbState_, keycode);
        const(uint)* keysyms;
        const count = xkb_keymap_key_get_syms_by_level(xkbKeymap_, keycode,
            layout, 0, &keysyms);
        if (count < 1)
            return LogicalKey.init;
        return logicalFromKeysym(keysyms[0],
            xkb_keysym_to_utf32(keysyms[0]));
    }

    private static uint internAtom(xcb_connection_t* connection,
        scope const(char)[] name)
    {
        auto reply = xcb_intern_atom_reply(connection,
            xcb_intern_atom(connection, 0, cast(ushort) name.length, name.ptr),
            null);
        if (reply is null)
            return 0;
        const atom = reply.atom;
        free(reply);
        return atom;
    }

    /*
    Without detectable auto-repeat the server synthesizes a release before
    every repeated press, so a held key is indistinguishable from typing.
    With the per-client flag a repeat is a second press with no release in
    between, which becomes KeyAction.repeat. Best-effort: a server without
    XKB simply keeps the synthesized releases.
    */
    private static void enableDetectableAutorepeat(
        xcb_connection_t* connection)
    {
        auto use = xcb_xkb_use_extension_reply(connection,
            xcb_xkb_use_extension(connection, XCB_XKB_MAJOR_VERSION,
                XCB_XKB_MINOR_VERSION), null);
        if (use is null)
            return;
        const supported = use.supported != 0;
        free(use);
        if (!supported)
            return;
        auto flags = xcb_xkb_per_client_flags_reply(connection,
            xcb_xkb_per_client_flags(connection, XCB_XKB_ID_USE_CORE_KBD,
                XCB_XKB_PER_CLIENT_FLAG_DETECTABLE_AUTO_REPEAT,
                XCB_XKB_PER_CLIENT_FLAG_DETECTABLE_AUTO_REPEAT, 0, 0, 0),
            null);
        if (flags !is null)
            free(flags);
    }

    WsiResult!WindowId createWindow(in WindowConfig config)
    {
        auto owner = requireOwner!WindowId(WsiOperation.createWindow);
        if (owner.hasError)
            return owner;
        if (closed_)
            return x11Failure!WindowId(WsiOperation.createWindow, 0,
                "WSI is closed", WsiErrorKind.closed);
        if (auto fault = config.fault)
            return x11Failure!WindowId(WsiOperation.createWindow, 0,
                fault, WsiErrorKind.invalidArgument);
        // Narrower than the shared bound: X11 geometry requests are CARD16.
        if (config.logicalSize.width > ushort.max
            || config.logicalSize.height > ushort.max)
            return x11Failure!WindowId(WsiOperation.createWindow, 0,
                "X11 window size exceeds the protocol's 16-bit geometry",
                WsiErrorKind.invalidArgument);
        if (config.parent.valid || config.transparent || !config.resizable
            || config.decorations == DecorationPreference.none
            || config.state != WindowStartupState.normal)
            return x11Failure!WindowId(WsiOperation.createWindow, 0,
                "requested X11 startup configuration is not implemented",
                WsiErrorKind.unsupported);

        if (windows_.full)
            return x11Failure!WindowId(WsiOperation.createWindow, 0,
                "X11 window capacity reached", WsiErrorKind.capacity);

        const window = xcb_generate_id(connection_);
        if (window == 0)
            return x11Failure!WindowId(WsiOperation.createWindow,
                xcb_connection_has_error(connection_),
                "xcb_generate_id failed");
        const width = cast(ushort) config.logicalSize.width;
        const height = cast(ushort) config.logicalSize.height;
        const uint[2] values = [
            bootstrap_.blackPixel,
            XCB_EVENT_MASK_EXPOSURE | XCB_EVENT_MASK_STRUCTURE_NOTIFY
                | XCB_EVENT_MASK_FOCUS_CHANGE
                | XCB_EVENT_MASK_KEY_PRESS | XCB_EVENT_MASK_KEY_RELEASE
                | XCB_EVENT_MASK_BUTTON_PRESS | XCB_EVENT_MASK_BUTTON_RELEASE
                | XCB_EVENT_MASK_POINTER_MOTION
                | XCB_EVENT_MASK_ENTER_WINDOW | XCB_EVENT_MASK_LEAVE_WINDOW,
        ];
        xcb_create_window(connection_, XCB_COPY_FROM_PARENT, window,
            bootstrap_.root, 0, 0, width, height, 0,
            XCB_WINDOW_CLASS_INPUT_OUTPUT, bootstrap_.rootVisual,
            XCB_CW_BACK_PIXEL | XCB_CW_EVENT_MASK, values.ptr);
        xcb_change_property(connection_, XCB_PROP_MODE_REPLACE, window,
            bootstrap_.wmProtocols, XCB_ATOM_ATOM, 32, 1,
            &bootstrap_.wmDeleteWindow);
        xcb_change_property(connection_, XCB_PROP_MODE_REPLACE, window,
            XCB_ATOM_WM_NAME, XCB_ATOM_STRING, 8,
            cast(uint) config.title.length, config.title[].ptr);
        if (config.visible)
            xcb_map_window(connection_, window);
        const error = xcb_flush(connection_) > 0
            ? 0 : xcb_connection_has_error(connection_);
        if (error != 0)
            return x11Failure!WindowId(WsiOperation.createWindow, error,
                "XCB window request batch failed to flush");

        auto reserved = windows_.reserve();
        assert(reserved.hasValue, "capacity was checked before the request");
        WindowId id = reserved.value;
        ref slot = windows_[id];
        slot.window = window;
        slot.ready = true;
        slot.metrics = SurfaceMetrics(
            LogicalSize(width, height), PhysicalSize(width, height),
            ScaleFactor(1));
        requestNextIc();
        const hadSticky = hasStickyError_;
        emit(id, ReadyEvent(slot.metrics));
        if (!hadSticky && hasStickyError_)
        {
            destroyNative(window);
            windows_.remove(id);
            events_.forgetWindow(id);
            return wsiErr!WindowId(stickyError_);
        }
        return wsiOk(id);
    }

    WsiResult!void destroyWindow(WindowId id)
    {
        auto checked = checkedSlot(id, WsiOperation.close);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        ref slot = windows_.at(checked.value);
        if (slot.captureMode != PointerCaptureMode.none)
        {
            xcb_ungrab_pointer(connection_, XCB_CURRENT_TIME);
            slot.captureMode = PointerCaptureMode.none;
        }
        slot.relativePointer = false;
        if (slot.xicReady && xim_ !is null)
            xcb_xim_destroy_ic(xim_, slot.xic, null, null);
        slot.xic = 0;
        slot.xicReady = false;
        const error = destroyNative(slot.window);
        if (error != 0)
            return x11Failure!void(WsiOperation.close, error,
                "xcb_destroy_window failed");
        if (slot.cursor != 0)
            xcb_free_cursor(connection_, slot.cursor);
        windows_.remove(id);
        events_.forgetWindow(id);
        emit(id, DestroyedEvent());
        return hasStickyError_ ? wsiErr!void(stickyError_) : wsiOk();
    }

    /*
    F10 on X11: explicit capture and confinement are one active pointer grab
    — `owner_events` keeps normal delivery inside the window, `confine_to`
    pins the pointer to it — and raw relative motion is XInput 2's
    `RawMotion` selected on the root window (raw events come from the
    slave device, so the selection names every device). Both unwind on
    destruction; a grab outlives focus changes by design, since it holds
    the pointer.

    One physical motion raises several raw events: one per slave device
    that reported it, and since XI 2.1 a copy under the master's id. Only
    the slave-originated event (`deviceid == sourceid`) from a device whose
    x/y valuators are relative becomes a `RelativePointerEvent`: an
    absolute device (a tablet, a touchscreen, Xwayland's absolute
    `xwayland-pointer` beside its `xwayland-relative-pointer`) carries
    positions in its raw values, not deltas, so it is not differentiated
    into motion. Under Xwayland the grab also reaches less than on a real
    server: the compositor routes no pointer events over non-X surfaces to
    it, and a warp (the confine-time warp inside included) is dropped
    unless the pointer is already over the window.
    */

    /// Grabs (or releases) the pointer for this window; `confine` also
    /// keeps it inside the content area.
    WsiResult!void setPointerCapture(WindowId id, PointerCaptureMode mode)
    {
        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        ref slot = windows_.at(checked.value);
        if (mode == PointerCaptureMode.none)
        {
            if (slot.captureMode != PointerCaptureMode.none)
            {
                xcb_ungrab_pointer(connection_, XCB_CURRENT_TIME);
                flushCommands();
            }
            slot.captureMode = mode;
            return hasStickyError_ ? wsiErr!void(stickyError_) : wsiOk();
        }
        enum ushort grabMask = XCB_EVENT_MASK_BUTTON_PRESS
            | XCB_EVENT_MASK_BUTTON_RELEASE | XCB_EVENT_MASK_POINTER_MOTION
            | XCB_EVENT_MASK_ENTER_WINDOW | XCB_EVENT_MASK_LEAVE_WINDOW;
        auto cookie = xcb_grab_pointer(connection_, 1, slot.window, grabMask,
            XCB_GRAB_MODE_ASYNC, XCB_GRAB_MODE_ASYNC,
            mode == PointerCaptureMode.confine ? slot.window : XCB_NONE,
            XCB_NONE, XCB_CURRENT_TIME);
        auto reply = xcb_grab_pointer_reply(connection_, cookie, null);
        if (reply is null)
            return x11Failure!void(WsiOperation.command,
                xcb_connection_has_error(connection_),
                "xcb_grab_pointer produced no reply");
        scope (exit) free(reply);
        if (reply.status != XCB_GRAB_STATUS_SUCCESS)
            return x11Failure!void(WsiOperation.command, reply.status,
                "the server refused the pointer grab");
        slot.captureMode = mode;
        return wsiOk();
    }

    /// Selects raw relative motion; a server without XInput 2 answers
    /// typed unsupported.
    WsiResult!void setRelativePointer(WindowId id, bool enabled)
    {
        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        if (xiOpcode_ == 0)
            return x11Failure!void(WsiOperation.command, 0,
                "XInput 2 raw motion is not available on this server",
                WsiErrorKind.unsupported);
        windows_.at(checked.value).relativePointer = enabled;
        bool anyRelative;
        foreach (h; windows_.byLive)
            anyRelative |= windows_[h].relativePointer;
        if (anyRelative == xiRawSelected_)
            return wsiOk();
        auto selected = selectRawMotion(anyRelative);
        if (selected.hasError)
            return selected;
        xiRawSelected_ = anyRelative;
        return wsiOk();
    }

    private void openXInput() nothrow @nogc
    {
        auto data = xcb_get_extension_data(connection_, &xcb_input_id);
        if (data is null || data.present == 0)
            return;
        // The server must see a version query before any XI2 request.
        auto cookie = xcb_input_xi_query_version(connection_, 2, 2);
        auto reply = xcb_input_xi_query_version_reply(connection_, cookie,
            null);
        if (reply is null)
            return;
        const supported = reply.major_version >= 2;
        free(reply);
        if (supported)
            xiOpcode_ = data.major_opcode;
    }

    private WsiResult!void selectRawMotion(bool on)
    {
        // xcb_input_event_mask_t is a header followed by mask_len words.
        static struct RawMotionMask
        {
            xcb_input_event_mask_t head;
            uint mask;
        }

        RawMotionMask masks;
        masks.head.deviceid = XCB_INPUT_DEVICE_ALL;
        masks.head.mask_len = 1;
        masks.mask = on
            ? XCB_INPUT_XI_EVENT_MASK_RAW_MOTION
                | XCB_INPUT_XI_EVENT_MASK_HIERARCHY
                | XCB_INPUT_XI_EVENT_MASK_DEVICE_CHANGED
            : 0;
        // ImportC drops the header's `const` on the mask pointer.
        const error = checkedRequest(xcb_input_xi_select_events_checked(
            connection_, bootstrap_.root, 1,
            cast(xcb_input_event_mask_t*) &masks));
        if (error != 0)
            return x11Failure!void(WsiOperation.command, error,
                "xcb_input_xi_select_events failed");
        return wsiOk();
    }

    /// One XInput 2 RawMotion event: valuators 0 and 1 are the pointer's
    /// x and y; the raw (unaccelerated) values are what relative mode
    /// reports.
    private void handleRawMotion(xcb_input_raw_motion_event_t* event)
        nothrow @nogc
    {
        // The master's XI 2.1 copy of a slave event carries the master's
        // id; the slave's own delivery is the one to keep.
        if (event.deviceid != event.sourceid
            || !hasRelativeAxes(event.sourceid))
            return;
        // The accessors are read-only in C; ImportC loses that `const`.
        const maskLength =
            xcb_input_raw_button_press_valuator_mask_length(event);
        const masks = xcb_input_raw_button_press_valuator_mask(event);
        const rawCount = xcb_input_raw_button_press_axisvalues_raw_length(event);
        const raw = xcb_input_raw_button_press_axisvalues_raw(event);
        if (masks is null || raw is null)
            return;
        double dx = 0;
        double dy = 0;
        size_t next;
        foreach (word; 0 .. maskLength)
            foreach (bit; 0 .. 32)
            {
                if ((masks[word] & (1u << bit)) == 0)
                    continue;
                if (next >= rawCount)
                    return;
                const value = raw[next].integral
                    + raw[next].frac / 4294967296.0;
                ++next;
                const valuator = word * 32 + bit;
                if (valuator == 0)
                    dx = value;
                else if (valuator == 1)
                    dy = value;
            }
        if (dx == 0 && dy == 0)
            return;
        foreach (h; windows_.byLive)
            if (windows_[h].relativePointer)
                emit(h, RelativePointerEvent(corePointer, dx, dy, true));
    }

    /// Whether a device's x and y valuators (0 and 1) are relative axes,
    /// asked of the server once per device id and remembered.
    private bool hasRelativeAxes(ushort deviceId) nothrow @nogc
    {
        if (deviceId >= rawDeviceKind_.length)
            return false;
        if (rawDeviceKind_[deviceId] == 0)
            rawDeviceKind_[deviceId] = queryAxesRelative(deviceId) ? 1 : 2;
        return rawDeviceKind_[deviceId] == 1;
    }

    private bool queryAxesRelative(ushort deviceId) nothrow @nogc
    {
        auto cookie = xcb_input_xi_query_device(connection_, deviceId);
        auto reply = xcb_input_xi_query_device_reply(connection_, cookie,
            null);
        if (reply is null)
            return false;
        scope (exit) free(reply);
        bool sawX;
        bool sawY;
        bool relative = true;
        for (auto infos = xcb_input_xi_query_device_infos_iterator(reply);
            infos.rem != 0; xcb_input_xi_device_info_next(&infos))
        {
            if (infos.data.deviceid != deviceId)
                continue;
            for (auto classes =
                    xcb_input_xi_device_info_classes_iterator(infos.data);
                classes.rem != 0; xcb_input_device_class_next(&classes))
            {
                if (classes.data.type != XCB_INPUT_DEVICE_CLASS_TYPE_VALUATOR)
                    continue;
                auto valuator =
                    cast(const xcb_input_valuator_class_t*) classes.data;
                if (valuator.number > 1)
                    continue;
                (valuator.number == 0 ? sawX : sawY) = true;
                relative &= valuator.mode == XCB_INPUT_VALUATOR_MODE_RELATIVE;
            }
        }
        return sawX && sawY && relative;
    }

    /**
    Applies a standard cursor shape from the core `cursor` font. CSS
    `grab`/`grabbing` have no core glyph and use the `fleur` move cursor as
    the documented nearest shape; custom images are a later slice.
    */
    WsiResult!void setCursor(WindowId id, PointerShape shape)
    {
        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        ref slot = windows_.at(checked.value);
        if (cursorFont_ == 0)
        {
            cursorFont_ = xcb_generate_id(connection_);
            static immutable fontName = "cursor";
            const opened = checkedRequest(xcb_open_font_checked(connection_,
                cursorFont_, fontName.length, fontName.ptr));
            if (opened != 0)
            {
                cursorFont_ = 0;
                return x11Failure!void(WsiOperation.command, opened,
                    "the core cursor font is unavailable",
                    WsiErrorKind.unsupported);
            }
        }
        const glyph = x11CursorGlyph(shape);
        const cursor = xcb_generate_id(connection_);
        const created = checkedRequest(xcb_create_glyph_cursor_checked(
            connection_, cursor, cursorFont_, cursorFont_,
            glyph, cast(ushort)(glyph + 1),
            0, 0, 0, 0xFFFF, 0xFFFF, 0xFFFF));
        if (created != 0)
            return x11Failure!void(WsiOperation.command, created,
                "xcb_create_glyph_cursor failed");
        return installCursor(slot, cursor);
    }

    /// An invisible cursor is a 1x1 empty pixmap cursor; visible restores
    /// the stored shape by simply removing the override.
    WsiResult!void setCursorVisible(WindowId id, bool visible)
    {
        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        ref slot = windows_.at(checked.value);
        if (visible)
        {
            const none = 0u;
            const changed = checkedRequest(
                xcb_change_window_attributes_checked(connection_,
                    slot.window, XCB_CW_CURSOR, &none));
            if (changed != 0)
                return x11Failure!void(WsiOperation.command, changed,
                    "restoring the window cursor failed");
            if (slot.cursor != 0)
                return installCursor(slot, slot.cursor, false);
            return flushCommands();
        }
        const pixmap = xcb_generate_id(connection_);
        const made = checkedRequest(xcb_create_pixmap_checked(connection_, 1,
            pixmap, bootstrap_.root, 1, 1));
        if (made != 0)
            return x11Failure!void(WsiOperation.command, made,
                "creating the blank cursor pixmap failed");
        const cursor = xcb_generate_id(connection_);
        const created = checkedRequest(xcb_create_cursor_checked(connection_,
            cursor, pixmap, pixmap, 0, 0, 0, 0, 0, 0, 0, 0));
        xcb_free_pixmap(connection_, pixmap);
        if (created != 0)
            return x11Failure!void(WsiOperation.command, created,
                "creating the blank cursor failed");
        const changed = checkedRequest(xcb_change_window_attributes_checked(
            connection_, slot.window, XCB_CW_CURSOR, &cursor));
        xcb_free_cursor(connection_, cursor);
        if (changed != 0)
            return x11Failure!void(WsiOperation.command, changed,
                "hiding the window cursor failed");
        return flushCommands();
    }

    private WsiResult!void installCursor(ref Slot slot, uint cursor,
        bool own = true)
    {
        const changed = checkedRequest(xcb_change_window_attributes_checked(
            connection_, slot.window, XCB_CW_CURSOR, &cursor));
        if (changed != 0)
        {
            if (own)
                xcb_free_cursor(connection_, cursor);
            return x11Failure!void(WsiOperation.command, changed,
                "setting the window cursor failed");
        }
        if (own)
        {
            if (slot.cursor != 0 && slot.cursor != cursor)
                xcb_free_cursor(connection_, slot.cursor);
            slot.cursor = cursor;
        }
        return flushCommands();
    }

    private WsiResult!void flushCommands()
    {
        return xcb_flush(connection_) > 0
            ? wsiOk()
            : x11Failure!void(WsiOperation.command,
                xcb_connection_has_error(connection_),
                "XCB flush failed");
    }

    private int checkedRequest(xcb_void_cookie_t cookie)
    {
        auto error = xcb_request_check(connection_, cookie);
        if (error is null)
            return 0;
        const code = error.error_code;
        free(error);
        return code;
    }

    /// Core `cursor` font glyphs (X11/cursorfont.h numbering).
    package static ushort x11CursorGlyph(PointerShape shape)
        @safe pure nothrow @nogc
    {
        final switch (shape)
        {
            case PointerShape.default_: return 68; // XC_left_ptr
            case PointerShape.text: return 152; // XC_xterm
            case PointerShape.pointer: return 60; // XC_hand2
            case PointerShape.ewResize: return 108; // XC_sb_h_double_arrow
            case PointerShape.nsResize: return 116; // XC_sb_v_double_arrow
            case PointerShape.grab: return 52; // XC_fleur (nearest)
            case PointerShape.grabbing: return 52; // XC_fleur (nearest)
        }
    }

    /// The connection's display handle, without a window: what a
    /// process-scoped renderer (a Vulkan instance and device) is chosen
    /// from before any window has a surface (§10.1).
    WsiResult!DisplayHandle displayHandle()
    {
        auto owner = requireOwner!DisplayHandle(WsiOperation.queryHandle);
        if (owner.hasError)
            return owner;
        return wsiOk(DisplayHandle(X11DisplayHandle(connection_, null, bootstrap_.screenIndex)));
    }

    WsiResult!NativeHandles nativeHandles(WindowId id)
    {
        auto checked = checkedSlot(id, WsiOperation.queryHandle);
        if (checked.hasError)
            return wsiErr!NativeHandles(checked.error);
        ref slot = windows_.at(checked.value);

        NativeHandles handles;
        handles.display = DisplayHandle(X11DisplayHandle(connection_, null,
            bootstrap_.screenIndex));
        handles.window = WindowHandle(X11WindowHandle(slot.window,
            bootstrap_.rootVisual));
        return wsiOk(handles);
    }

    /** Drains every XCB event currently buffered; never waits. */
    WsiResult!size_t pumpEvents()
    {
        auto owner = requireOwner!size_t(WsiOperation.dispatch);
        if (owner.hasError)
            return owner;
        size_t count;
        while (true)
        {
            auto generic = xcb_poll_for_event(connection_);
            if (generic is null)
                break;
            ++count;
            if (xim_ is null || !xcb_xim_filter_event(xim_, generic))
                handleNative(generic);
            free(generic);
        }
        const connectionError = xcb_connection_has_error(connection_);
        if (connectionError != 0)
            remember(wsiError(WsiErrorKind.nativeFailure,
                WsiOperation.dispatch, BackendKind.x11, connectionError,
                "XCB connection failed while dispatching"));
        if (hasStickyError_)
            return wsiErr!size_t(stickyError_);
        return wsiOk(count);
    }

    /** Attaches the X connection fd to the supplied Event Horizon loop. */
    WsiResult!void attach(ref DefaultLoop loop)
    {
        auto owner = requireOwner!void(WsiOperation.attach);
        if (owner.hasError)
            return owner;
        if (loop_ !is null)
            return loop_ is &loop ? wsiOk()
                : x11Failure!void(WsiOperation.attach, 0,
                    "X11 WSI is attached to another loop",
                    WsiErrorKind.invalidArgument);
        loop_ = &loop;
        detaching_ = false;
        openXim();
        return armPoll();
    }

    /*
    XIM rides the same XCB connection: xcb-imdkit's client speaks the XIM
    wire protocol through ClientMessage events that `xcb_xim_filter_event`
    consumes inside the ordinary pump, so the hosted single wait stays the
    only wait. Registration happens here, at attach, because the callbacks
    borrow this struct — by attach time it lives at the address the driver
    keeps it at. Everything is best-effort: with no XIM server on
    `$XMODIFIERS`, keys flow exactly as before.
    */
    private void openXim() nothrow
    {
        if (xim_ !is null || connection_ is null)
            return;
        xim_ = xcb_xim_create(connection_, bootstrap_.screenIndex, null);
        if (xim_ is null)
            return;
        xcb_xim_set_use_utf8_string(xim_, true);
        xcb_xim_set_im_callback(xim_, listenerPtr(ximListener), &this);
        if (!xcb_xim_open(xim_, &onXimOpened, true, &this))
        {
            xcb_xim_destroy(xim_);
            xim_ = null;
        }
    }

    /// Whether IME text input is live for this window (an XIM server is
    /// connected and the window's input context exists).
    bool textInputReady(WindowId id)
    {
        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return false;
        return ximConnected_ && windows_.at(checked.value).xicReady;
    }

    private extern (C) static void onXimOpened(xcb_xim_t*, void* data)
        nothrow @nogc
    {
        auto owner = cast(X11Wsi*) data;
        owner.ximConnected_ = true;
        owner.requestNextIc();
    }

    private extern (C) static void onXimDisconnected(xcb_xim_t*, void* data)
        nothrow @nogc
    {
        auto owner = cast(X11Wsi*) data;
        owner.ximConnected_ = false;
        owner.pendingIc_ = WindowId.init;
        foreach (h; owner.windows_.byLive)
        {
            owner.windows_[h].xic = 0;
            owner.windows_[h].xicReady = false;
        }
    }

    /*
    Input contexts are created one at a time: the create-ic reply carries no
    window, so a single in-flight request keeps the reply attributable.
    */
    private void requestNextIc() nothrow @nogc
    {
        if (!ximConnected_ || pendingIc_.valid)
            return;
        foreach (h; windows_.byLive)
        {
            ref slot = windows_[h];
            if (slot.xicReady || slot.xic != 0)
                continue;
            pendingIc_ = h;
            uint style = XCB_IM_PreeditNothing | XCB_IM_StatusNothing;
            uint window = slot.window;
            // Attribute names are XCB_XIM_XNInputStyle etc.; spelled out
            // because ImportC exposes only integer macros.
            if (!xcb_xim_create_ic(xim_, &onIcCreated, &this,
                "inputStyle".ptr, &style,
                "clientWindow".ptr, &window,
                "focusWindow".ptr, &window,
                cast(void*) null))
                pendingIc_ = WindowId.init;
            return;
        }
    }

    private extern (C) static void onIcCreated(xcb_xim_t*, ushort ic,
        void* data) nothrow @nogc
    {
        auto owner = cast(X11Wsi*) data;
        // The reply names no window; the pending id does, and its generation
        // rejects a window destroyed (and its slot reused) while it waited.
        const pending = owner.pendingIc_;
        owner.pendingIc_ = WindowId.init;
        if (auto slot = owner.windows_.get(pending))
        {
            slot.xic = ic;
            slot.xicReady = true;
        }
        owner.requestNextIc();
    }

    private extern (C) static void onXimForwardEvent(xcb_xim_t*, ushort ic,
        xcb_key_press_event_t* event, void* data) nothrow @nogc
    {
        // A key the input method chose not to consume: deliver it exactly
        // as an unfiltered key.
        auto owner = cast(X11Wsi*) data;
        if (event is null)
            return;
        const pressed = (event.response_type & 0x7F) == XCB_KEY_PRESS;
        owner.deliverKey(event, pressed);
    }

    private extern (C) static void onXimCommit(xcb_xim_t*, ushort ic,
        uint flag, char* str, uint length, uint*, size_t, void* data)
        nothrow @nogc
    {
        auto owner = cast(X11Wsi*) data;
        if ((flag & XCB_XIM_LOOKUP_CHARS) == 0 || str is null
            || length == 0)
            return;
        const index = owner.indexOfIc(ic);
        if (index == size_t.max)
            return;
        // xcb_xim_set_use_utf8_string negotiated UTF-8 payloads; reject
        // anything else whole rather than queue invalid bytes.
        const bytes = str[0 .. length];
        if (validateUtf8(bytes).hasError)
            return;
        owner.emitText(owner.idAt(index), bytes,
            (TextId text, size_t kept) => TextCommittedEvent(text));
    }

    private size_t indexOfIc(ushort ic) const nothrow @nogc
    {
        if (ic == 0)
            return size_t.max;
        foreach (h; windows_.byLive)
            if (windows_[h].xicReady && windows_[h].xic == ic)
                return h.index;
        return size_t.max;
    }

    /**
    Runs one Event Horizon iteration and services the XCB readiness edge.

    Timers, channels, subprocesses, the X fd, and the cross-thread waker all
    remain operations of `loop`; this wrapper adds no wait or scheduler.
    */
    IoResult!RunStatus runIntegratedOnce(ref DefaultLoop loop,
        Duration timeout = Duration.max)
    {
        if (loop_ is null)
        {
            auto attached = attach(loop);
            if (attached.hasError)
                return ioErr!RunStatus(cast(int) attached.error.nativeCode,
                    OpKind.pollAdd, IoErrorStage.submit,
                    "failed to attach X11 display fd");
        }
        else if (loop_ !is &loop)
            return ioErr!RunStatus(0, OpKind.pollAdd, IoErrorStage.submit,
                "X11 WSI used with a different Event Horizon loop");

        bool nativeWork;
        if (!servicePoll(nativeWork))
            return ioErr!RunStatus(cast(int) stickyError_.nativeCode,
                OpKind.pollAdd, IoErrorStage.completion,
                "XCB dispatch/re-arm failed");
        // XCB may already have copied events from the socket into its own
        // queue while completing an earlier synchronous reply. In that case
        // the fd is no longer readable, so those values must be observed
        // before entering the only blocking wait.
        if (nativeWork)
            return ioOk(RunStatus.dispatched);
        auto result = loop.runOnce(timeout);
        if (result.hasError)
            return result;
        if (!servicePoll(nativeWork))
            return ioErr!RunStatus(cast(int) stickyError_.nativeCode,
                OpKind.pollAdd, IoErrorStage.completion,
                "XCB dispatch/re-arm failed");
        return nativeWork && result.value != RunStatus.stopped
            ? ioOk(RunStatus.dispatched) : result;
    }

    WsiResult!void detach()
    {
        auto owner = requireOwner!void(WsiOperation.attach);
        if (owner.hasError)
            return owner;
        if (loop_ is null)
            return wsiOk();
        detaching_ = true;
        if (pollArmed_)
        {
            auto cancelled = loop_.cancelAndWait(pollHandle_);
            if (cancelled.hasError)
                return x11Failure!void(WsiOperation.attach,
                    cancelled.error.code,
                    "failed to cancel and reap X11 display poll");
        }
        pollArmed_ = false;
        pollCompleted_ = false;
        loop_ = null;
        return wsiOk();
    }

    WsiResult!size_t drain(Sink)(scope Sink sink) => events_.drain(sink);

    size_t pendingEvents() const pure nothrow @nogc => events_.length;

    WsiResult!void close()
    {
        auto owner = requireOwner!void(WsiOperation.close);
        if (owner.hasError)
            return owner;
        closeNow();
        return hasStickyError_ ? wsiErr!void(stickyError_) : wsiOk();
    }

    /// RAII teardown: idempotent and best-effort; errors join the sticky slot.
    private void closeNow()
    {
        if (closed_ || !open_)
            return;
        auto detached = detach();
        if (detached.hasError)
            remember(detached.error);
        foreach (h; clipboard_.transfers.byLive)
            clipboard_.end(h, TransferStatus.failed);
        if (clip_.helper != 0)
            destroyNative(clip_.helper);
        foreach (h; windows_.byLive)
        {
            if (windows_[h].cursor != 0)
                xcb_free_cursor(connection_, windows_[h].cursor);
            destroyNative(windows_[h].window);
        }
        windows_.clear();
        if (cursorFont_ != 0)
        {
            xcb_close_font(connection_, cursorFont_);
            cursorFont_ = 0;
        }
        if (xkbState_ !is null)
        {
            xkb_state_unref(xkbState_);
            xkbState_ = null;
        }
        if (xkbKeymap_ !is null)
        {
            xkb_keymap_unref(xkbKeymap_);
            xkbKeymap_ = null;
        }
        if (xkbContext_ !is null)
        {
            xkb_context_unref(xkbContext_);
            xkbContext_ = null;
        }
        if (xim_ !is null)
        {
            xcb_xim_close(xim_);
            xcb_xim_destroy(xim_);
            xim_ = null;
            ximConnected_ = false;
        }
        if (connection_ !is null)
        {
            xcb_disconnect(connection_);
            connection_ = null;
        }
        closed_ = true;
        open_ = false;
    }

    ~this()
    {
        closeNow();
    }

    private WsiResult!void armPoll()
    {
        if (detaching_ || pollArmed_)
            return wsiOk();
        auto submitted = loop_.submit(OpPollAdd(bootstrap_.fd,
            PollEvents.readable, false), &onPollReady, &this);
        if (submitted.hasError)
            return x11Failure!void(WsiOperation.attach,
                submitted.error.code, "OpPollAdd(XCB fd) failed");
        pollHandle_ = submitted.value;
        pollArmed_ = true;
        return wsiOk();
    }

    private static void onPollReady(void* context,
        ref Completion completion) nothrow @nogc
    {
        auto owner = cast(X11Wsi*) context;
        owner.pollArmed_ = false;
        owner.pollCompleted_ = true;
        owner.pollResult_ = completion.res;
    }

    private bool servicePoll(out bool nativeWork)
    {
        nativeWork = false;
        const completed = pollCompleted_;
        if (completed)
        {
            pollCompleted_ = false;
            if (pollResult_ < 0)
            {
                if (detaching_)
                    return true;
                remember(wsiError(WsiErrorKind.nativeFailure,
                    WsiOperation.dispatch, BackendKind.x11, -pollResult_,
                    "XCB descriptor poll failed"));
                return false;
            }
        }
        auto pumped = pumpEvents();
        if (pumped.hasError)
            return false;
        nativeWork = pumped.value != 0;
        if (completed && !detaching_)
        {
            auto armed = armPoll();
            if (armed.hasError)
            {
                remember(armed.error);
                return false;
            }
        }
        return true;
    }

    /// The core protocol exposes one pointer per connection.
    private enum corePointer = PointerId(0, 1);

    private void emitPointerAt(size_t index, PointerPhase phase, int x,
        int y, uint state) nothrow
    {
        PointerEvent pointer;
        pointer.pointer = corePointer;
        pointer.phase = phase;
        pointer.logicalPosition = LogicalPosition(x, y);
        pointer.physicalPosition = PhysicalPosition(x, y);
        pointer.modifiers = x11Mods(state);
        emit(idAt(index), pointer);
    }

    /// Core buttons: 1/2/3 are left/middle/right, 8/9 the thumb pair.
    package static PointerButton x11PointerButton(uint detail)
        @safe pure nothrow @nogc
    {
        switch (detail)
        {
            case 1: return PointerButton.left;
            case 2: return PointerButton.middle;
            case 3: return PointerButton.right;
            case 8: return PointerButton.back;
            case 9: return PointerButton.forward;
            default: return PointerButton.none;
        }
    }

    private int destroyNative(uint window)
    {
        xcb_destroy_window(connection_, window);
        return xcb_flush(connection_) > 0
            ? 0 : xcb_connection_has_error(connection_);
    }

    /// One unfiltered key: repeat detection, translation, and the queue.
    private void deliverKey(const xcb_key_press_event_t* event,
        bool pressed) nothrow @nogc
    {
        const index = indexOfWindow(event.event);
        if (index == size_t.max)
            return;
        const keycode = cast(uint) event.detail;
        const repeated = pressed && keyIsDown(keycode);
        setKeyDown(keycode, pressed);
        KeyboardEvent keyboard;
        keyboard.physical = PhysicalKey(keycode, 0);
        keyboard.logical = logicalForKey(keycode, event.state);
        keyboard.location = x11KeyLocation(keycode);
        keyboard.action = pressed
            ? (repeated ? KeyAction.repeat : KeyAction.press)
            : KeyAction.release;
        keyboard.modifiers = x11Mods(event.state);
        emit(idAt(index), keyboard);
    }

    private void handleNative(const xcb_generic_event_t* generic)
    {
        const responseType = generic.response_type & 0x7F;
        if (responseType == 0)
        {
            auto error = cast(const xcb_generic_error_t*) generic;
            remember(wsiError(WsiErrorKind.nativeFailure,
                WsiOperation.dispatch, BackendKind.x11,
                error.error_code, "X11 protocol request failed"));
            return;
        }
        switch (responseType)
        {
            case XCB_EXPOSE:
                auto event = cast(const xcb_expose_event_t*) generic;
                const index = indexOfWindow(event.window);
                if (index == size_t.max)
                    return;
                emit(idAt(index), ExposedEvent());
                emit(idAt(index), FrameReadyEvent());
                break;
            case XCB_CONFIGURE_NOTIFY:
                auto event =
                    cast(const xcb_configure_notify_event_t*) generic;
                const index = indexOfWindow(event.window);
                if (index == size_t.max)
                    return;
                ref slot = windows_.at(index);
                auto metrics = SurfaceMetrics(
                    LogicalSize(event.width, event.height),
                    PhysicalSize(event.width, event.height), ScaleFactor(1));
                if (metrics != slot.metrics)
                    emit(idAt(index), SurfaceMetricsChangedEvent(metrics));
                slot.metrics = metrics;
                emit(idAt(index),
                    MovedEvent(PhysicalPosition(event.x, event.y)));
                break;
            case XCB_CLIENT_MESSAGE:
                auto event = cast(const xcb_client_message_event_t*) generic;
                if (event.type != bootstrap_.wmProtocols
                    || event.data.data32[0] != bootstrap_.wmDeleteWindow)
                    return;
                const index = indexOfWindow(event.window);
                if (index != size_t.max)
                    emit(idAt(index), CloseRequestedEvent());
                break;
            case XCB_KEY_PRESS:
            case XCB_KEY_RELEASE:
                auto event = cast(const xcb_key_press_event_t*) generic;
                const index = indexOfWindow(event.event);
                if (index == size_t.max)
                    return;
                const pressed = responseType == XCB_KEY_PRESS;
                // With a live input context the IM sees every key first:
                // it either commits text or bounces the key back through
                // onXimForwardEvent, which delivers it unchanged.
                if (ximConnected_ && windows_.at(index).xicReady)
                {
                    xcb_xim_forward_event(xim_, windows_.at(index).xic,
                        cast(xcb_key_press_event_t*) event);
                    return;
                }
                deliverKey(event, pressed);
                break;
            case XCB_BUTTON_PRESS:
            case XCB_BUTTON_RELEASE:
                auto event = cast(const xcb_button_press_event_t*) generic;
                const index = indexOfWindow(event.event);
                if (index == size_t.max)
                    return;
                const pressed = responseType == XCB_BUTTON_PRESS;
                // Core buttons 4–7 are the legacy wheel: one discrete step
                // per press (down/up/right/left), nothing on the release.
                if (event.detail >= 4 && event.detail <= 7)
                {
                    if (!pressed)
                        return;
                    ScrollEvent scroll;
                    scroll.logicalPosition =
                        LogicalPosition(event.event_x, event.event_y);
                    scroll.physicalPosition =
                        PhysicalPosition(event.event_x, event.event_y);
                    switch (event.detail)
                    {
                        case 4: scroll.dy = -1; scroll.discreteY = -1; break;
                        case 5: scroll.dy = 1; scroll.discreteY = 1; break;
                        case 6: scroll.dx = -1; scroll.discreteX = -1; break;
                        default: scroll.dx = 1; scroll.discreteX = 1; break;
                    }
                    scroll.source = ScrollSource.wheel;
                    scroll.unit = ScrollUnit.logical;
                    scroll.modifiers = x11Mods(event.state);
                    emit(idAt(index), scroll);
                    return;
                }
                PointerEvent pointer;
                pointer.pointer = corePointer;
                pointer.phase = pressed
                    ? PointerPhase.pressed : PointerPhase.released;
                pointer.button = x11PointerButton(event.detail);
                pointer.logicalPosition =
                    LogicalPosition(event.event_x, event.event_y);
                pointer.physicalPosition =
                    PhysicalPosition(event.event_x, event.event_y);
                pointer.modifiers = x11Mods(event.state);
                emit(idAt(index), pointer);
                break;
            case XCB_MOTION_NOTIFY:
                auto event = cast(const xcb_motion_notify_event_t*) generic;
                const index = indexOfWindow(event.event);
                if (index == size_t.max)
                    return;
                emitPointerAt(index, PointerPhase.moved, event.event_x,
                    event.event_y, event.state);
                break;
            case XCB_ENTER_NOTIFY:
            case XCB_LEAVE_NOTIFY:
                auto event = cast(const xcb_enter_notify_event_t*) generic;
                const index = indexOfWindow(event.event);
                if (index == size_t.max)
                    return;
                emitPointerAt(index,
                    responseType == XCB_ENTER_NOTIFY
                        ? PointerPhase.entered : PointerPhase.left,
                    event.event_x, event.event_y, event.state);
                break;
            case XCB_FOCUS_IN:
            case XCB_FOCUS_OUT:
                auto event = cast(const xcb_focus_in_event_t*) generic;
                const index = indexOfWindow(event.event);
                if (index != size_t.max)
                {
                    const focused = responseType == XCB_FOCUS_IN;
                    ref slot = windows_.at(index);
                    if (ximConnected_ && slot.xicReady)
                    {
                        if (focused)
                            xcb_xim_set_ic_focus(xim_, slot.xic);
                        else
                            xcb_xim_unset_ic_focus(xim_, slot.xic);
                    }
                    emit(idAt(index), FocusChangedEvent(focused));
                }
                break;
            case XCB_GE_GENERIC:
                auto generic2 = cast(const xcb_ge_generic_event_t*) generic;
                if (xiOpcode_ == 0 || generic2.extension != xiOpcode_)
                    break;
                if (generic2.event_type == XCB_INPUT_RAW_MOTION)
                    handleRawMotion(
                        cast(xcb_input_raw_motion_event_t*) generic);
                else if (generic2.event_type == XCB_INPUT_HIERARCHY
                    || generic2.event_type == XCB_INPUT_DEVICE_CHANGED)
                    rawDeviceKind_[] = 0;
                break;
            case XCB_DESTROY_NOTIFY:
                auto event = cast(const xcb_destroy_notify_event_t*) generic;
                const index = indexOfWindow(event.window);
                if (index == size_t.max)
                    return;
                auto id = idAt(index);
                if (windows_[id].cursor != 0)
                    xcb_free_cursor(connection_, windows_[id].cursor);
                windows_.remove(id);
                events_.forgetWindow(id);
                emit(id, DestroyedEvent());
                break;
            default:
                handleClipboard(generic);
                break;
        }
    }

    private bool keyIsDown(uint keycode) const @safe pure nothrow @nogc
        => keyIsDownIn(pressedKeys_, keycode);

    private void setKeyDown(uint keycode, bool down) @safe pure nothrow @nogc
        => setKeyDownIn(pressedKeys_, keycode, down);

    package static bool keyIsDownIn(ref const ulong[4] keys, uint keycode)
        @safe pure nothrow @nogc
        => (keys[(keycode >> 6) & 3] & (1UL << (keycode & 63))) != 0;

    package static void setKeyDownIn(ref ulong[4] keys, uint keycode,
        bool down) @safe pure nothrow @nogc
    {
        if (down)
            keys[(keycode >> 6) & 3] |= 1UL << (keycode & 63);
        else
            keys[(keycode >> 6) & 3] &= ~(1UL << (keycode & 63));
    }

    /// X keycode = evdev + 8 under the evdev-standard map every current
    /// server exposes through xkeyboard-config.
    package static KeyLocation x11KeyLocation(uint keycode) @safe pure nothrow @nogc
        => keycode >= 8 ? evdevKeyLocation(keycode - 8) : KeyLocation.standard;

    /// Core-protocol state shares the xkb real-modifier bit positions.
    package static Mods x11Mods(uint state) @safe pure nothrow @nogc
        => xkbRealMods(state);

    private size_t indexOfWindow(uint window) const pure nothrow @nogc
    {
        foreach (h; windows_.byLive)
            if (windows_[h].window == window)
                return h.index;
        return size_t.max;
    }

    private WindowId idAt(size_t index) const pure nothrow @nogc
        => windows_.handleAt(index);

    private WsiResult!size_t checkedSlot(WindowId id,
        WsiOperation operation)
    {
        auto owner = requireOwner!size_t(operation);
        if (owner.hasError)
            return owner;
        auto index = windows_.resolve(id);
        if (index.hasError)
            return x11Failure!size_t(operation, 0,
                index.error == PoolError.invalid
                    ? "invalid X11 window id" : "stale X11 window id",
                WsiErrorKind.staleId);
        size_t slot = index.value;
        return wsiOk(slot);
    }

    private WsiResult!T requireOwner(T)(WsiOperation operation)
    {
        if (!open_ && !closed_)
            return x11Failure!T(operation, 0, "X11 WSI is not open",
                WsiErrorKind.closed);
        if (pthread_equal(ownerThread_, pthread_self()) == 0)
            return x11Failure!T(operation, 0,
                "X11 WSI called from a non-owner thread",
                WsiErrorKind.wrongThread);
        static if (is(T == void))
            return wsiOk();
        else
            return wsiOk(T.init);
    }

    // Fire-and-forget by design: a full queue lands in the sticky error,
    // which the next fallible operation reports.
    private void emit(Payload)(WindowId id, Payload payload) nothrow
    {
        auto result = events_.pushCoalesced(WindowEvent(nextSequence_, id,
            WindowEventPayload(payload), MonoTime.currTime));
        if (result.hasError)
        {
            remember(result.error);
            return;
        }
        ++nextSequence_;
    }

    /// Queues an event carrying `text`; see `EventQueue.pushText` (`ED8`).
    private void emitText(Make)(WindowId id, scope const(char)[] text,
        scope Make make) nothrow
    {
        auto result = events_.pushText(nextSequence_, id, text, make,
            MonoTime.currTime);
        if (result.hasError)
        {
            remember(result.error);
            return;
        }
        ++nextSequence_;
    }

    /// Calls `fn` with the text a delivered event names, during the drain
    /// that delivers it (`ED8`). See `EventQueue.withText`.
    // ── clipboard (`DT1`–`DT5`) ──────────────────────────────────────────────

    /// Largest property one step writes or reads: also the bound on the
    /// chunks a sink sees (`DT4`). An own offer larger than this goes `INCR`.
    enum size_t clipChunkBytes = 64 * 1024;

    /**
    Offers `mimeTypes` on the `CLIPBOARD` selection; requests pull the bytes
    from `provider`, which must outlive the offer (`DT3`). An offer of
    `text/plain;charset=utf-8` also answers `UTF8_STRING`, the target most X
    clients ask for.
    */
    WsiResult!OfferId offerClipboard(P)(WindowId window,
        scope const(char[])[] mimeTypes, ref P provider)
    if (isDataProvider!P)
    {
        auto checked = checkedSlot(window, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!OfferId(checked.error);
        auto added = clipboard_.add(window, mimeTypes, true);
        if (added.hasError)
            return added;
        clipboard_.offers[added.value].provider =
            (() @trusted => ProviderRef.to(provider))();
        return ownSelection(added.value);
    }

    /// ditto, for a small whole value the backend keeps a copy of.
    WsiResult!OfferId offerClipboard(WindowId window, scope const(char)[] mimeType,
        scope const(ubyte)[] value)
    {
        auto checked = checkedSlot(window, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!OfferId(checked.error);
        auto added = clipboard_.add(window, mimeType, true);
        if (added.hasError)
            return added;
        ref record = clipboard_.offers[added.value];
        record.value.bytes ~= value;
        record.hasValue = true;
        return ownSelection(added.value);
    }

    /// Ends an offer this application made: gives up the selection and
    /// reports `withdrawn` (`DT1`).
    WsiResult!void withdrawClipboard(OfferId offer)
    {
        auto record = clipboard_.offers.get(offer);
        if (record is null || !record.own)
            return x11Failure!void(WsiOperation.command, 0,
                "no live offer of this application's", WsiErrorKind.staleId);
        if (clipboard_.current == offer)
        {
            xcb_set_selection_owner(connection_, XCB_NONE, clip_.clipboard,
                XCB_CURRENT_TIME);
            xcb_flush(connection_);
        }
        announce(offer, DataOfferAction.withdrawn);
        dropOffer(offer);
        return wsiOk();
    }

    /**
    Starts reading `offer`'s `mimeType` into `sink` (`DT2`): the selection is
    converted into a property of the helper window and read as it arrives,
    following `INCR`. Only the clipboard's current offer is readable.
    */
    WsiResult!TransferId receive(S)(OfferId offer, scope const(char)[] mimeType,
        ref S sink)
    if (isDataSink!S)
    {
        if (offer != clipboard_.current || !clipboard_.offers.isLive(offer))
            return x11Failure!TransferId(WsiOperation.command, 0,
                "the offer has ended", WsiErrorKind.staleId);
        const target = targetFor(offer, mimeType);
        auto begun = clipboard_.begin(offer, mimeType,
            (() @trusted => SinkRef.to(sink))());
        if (begun.hasError)
            return begun;
        if (target == XCB_NONE)
        {
            clipboard_.end(begun.value, TransferStatus.failed);
            return begun;
        }
        const i = begun.value.index;
        fetches_[i] = Fetch(Fetch.State.requested, begun.value);
        xcb_convert_selection(connection_, clip_.helper, clip_.clipboard,
            target, clip_.transfer[i], XCB_CURRENT_TIME);
        xcb_flush(connection_);
        return begun;
    }

    /// Ends a transfer with `cancelled`; its sink then hears nothing more. An
    /// `INCR` transfer in flight is still read to its end and discarded, so
    /// the sender is not left waiting.
    WsiResult!void cancelTransfer(TransferId transfer)
    {
        if (clipboard_.transfers.isLive(transfer))
        {
            ref fetch = fetches_[transfer.index];
            fetch.state = fetch.state == Fetch.State.incremental
                ? Fetch.State.discarding : Fetch.State.idle;
        }
        return clipboard_.cancel(transfer);
    }

    private struct ClipAtoms
    {
        uint helper;     // the window that owns the selection and receives it
        uint clipboard;
        uint targets;
        uint incr;
        uint utf8;       // UTF8_STRING
        uint targetsProperty;
        uint[8] transfer; // one property per transfer slot
        ubyte xfixesEvent; // XFixes' first event code; 0 without XFixes
    }

    // One incoming transfer, by transfer slot.
    private struct Fetch
    {
        enum State : ubyte { idle, requested, incremental, discarding }
        State state;
        TransferId transfer;
    }

    // One outgoing `INCR` transfer to a requestor.
    private struct Serve
    {
        uint requestor;
        uint property;
        uint target;
        OfferId offer;
        ubyte type;    // the offer's MIME type being sent
        ulong offset;  // bytes already written
        bool live;
    }

    private enum textMime = "text/plain;charset=utf-8";

    private ClipAtoms clip_;
    private ClipboardState!() clipboard_;
    private uint[maxOfferTypes][4] offerTargets_; // per offer slot, per type
    private Fetch[8] fetches_;
    private Serve[4] serves_;
    private bool fetchingTargets_;

    // The helper window and the atoms; XFixes, when present, reports every
    // change of the selection's owner, which is how another client's offer
    // is noticed.
    private void openClipboard()
    {
        clip_.clipboard = internAtom(connection_, "CLIPBOARD");
        clip_.targets = internAtom(connection_, "TARGETS");
        clip_.incr = internAtom(connection_, "INCR");
        clip_.utf8 = internAtom(connection_, "UTF8_STRING");
        clip_.targetsProperty = internAtom(connection_, "SPARKLES_TARGETS");
        foreach (i, ref atom; clip_.transfer)
        {
            char[19] name = "SPARKLES_TRANSFER_0";
            name[18] = cast(char)('0' + i);
            atom = internAtom(connection_, name[]);
        }
        clip_.helper = xcb_generate_id(connection_);
        const uint mask = XCB_EVENT_MASK_PROPERTY_CHANGE;
        xcb_create_window(connection_, 0, clip_.helper, bootstrap_.root,
            -1, -1, 1, 1, 0, XCB_WINDOW_CLASS_INPUT_ONLY, XCB_COPY_FROM_PARENT,
            XCB_CW_EVENT_MASK, &mask);

        auto extension = xcb_get_extension_data(connection_, &xcb_xfixes_id);
        if (extension !is null && extension.present)
        {
            auto version_ = xcb_xfixes_query_version_reply(connection_,
                xcb_xfixes_query_version(connection_, 5, 0), null);
            if (version_ !is null)
            {
                free(version_);
                clip_.xfixesEvent = extension.first_event;
                xcb_xfixes_select_selection_input(connection_, clip_.helper,
                    clip_.clipboard,
                    XCB_XFIXES_SELECTION_EVENT_MASK_SET_SELECTION_OWNER
                        | XCB_XFIXES_SELECTION_EVENT_MASK_SELECTION_WINDOW_DESTROY
                        | XCB_XFIXES_SELECTION_EVENT_MASK_SELECTION_CLIENT_CLOSE);
            }
        }
        xcb_flush(connection_);
    }

    private WsiResult!OfferId ownSelection(OfferId offer)
    {
        auto record = clipboard_.offers.get(offer);
        foreach (i, ref t; record.types[0 .. record.typeCount])
            offerTargets_[offer.index][i] = internAtom(connection_, t[]);
        xcb_set_selection_owner(connection_, clip_.helper, clip_.clipboard,
            XCB_CURRENT_TIME);
        auto owner = xcb_get_selection_owner_reply(connection_,
            xcb_get_selection_owner(connection_, clip_.clipboard), null);
        const owned = owner !is null && owner.owner == clip_.helper;
        free(owner);
        if (!owned)
        {
            dropOffer(offer);
            return x11Failure!OfferId(WsiOperation.command, 0,
                "the X server did not grant the CLIPBOARD selection");
        }
        publish(offer);
        return wsiOk(offer);
    }

    // The X target to convert `offer`'s `mime` to: the atom it was listed
    // as, which for text may be `UTF8_STRING`.
    private uint targetFor(OfferId offer, scope const(char)[] mime)
    {
        auto record = clipboard_.offers.get(offer);
        if (record is null)
            return XCB_NONE;
        foreach (i, ref t; record.types[0 .. record.typeCount])
            if (t[] == mime)
                return offerTargets_[offer.index][i];
        return XCB_NONE;
    }

    // Selection traffic; `true` when the event was the clipboard's.
    private bool handleClipboard(const xcb_generic_event_t* generic)
    {
        const responseType = generic.response_type & 0x7F;
        if (clip_.xfixesEvent != 0
            && responseType == clip_.xfixesEvent + XCB_XFIXES_SELECTION_NOTIFY)
        {
            auto event = cast(const xcb_xfixes_selection_notify_event_t*) generic;
            if (event.selection == clip_.clipboard && event.owner != clip_.helper)
                noticeForeignOwner(event.owner);
            return true;
        }
        switch (responseType)
        {
            case XCB_SELECTION_REQUEST:
                serveRequest(cast(const xcb_selection_request_event_t*) generic);
                return true;
            case XCB_SELECTION_NOTIFY:
                auto event = cast(const xcb_selection_notify_event_t*) generic;
                if (event.requestor == clip_.helper)
                    converted(event);
                return true;
            case XCB_SELECTION_CLEAR:
                auto event = cast(const xcb_selection_clear_event_t*) generic;
                // Another client took the selection: this application's
                // offer has ended (`DT1`).
                if (event.selection == clip_.clipboard)
                    if (auto record = clipboard_.offers.get(clipboard_.current))
                        if (record.own)
                        {
                            announce(clipboard_.current, DataOfferAction.withdrawn);
                            dropOffer(clipboard_.current);
                        }
                return true;
            case XCB_PROPERTY_NOTIFY:
                propertyChanged(cast(const xcb_property_notify_event_t*) generic);
                return true;
            default:
                return false;
        }
    }

    // Another client owns the clipboard now (or no one does): ask it for its
    // targets, which become the foreign offer once they arrive.
    private void noticeForeignOwner(uint owner)
    {
        if (auto record = clipboard_.offers.get(clipboard_.current))
        {
            if (record.own)
                announce(clipboard_.current, DataOfferAction.withdrawn);
            dropOffer(clipboard_.current);
        }
        if (owner == XCB_NONE)
            return;
        fetchingTargets_ = true;
        xcb_convert_selection(connection_, clip_.helper, clip_.clipboard,
            clip_.targets, clip_.targetsProperty, XCB_CURRENT_TIME);
        xcb_flush(connection_);
    }

    private void converted(const xcb_selection_notify_event_t* event)
    {
        if (event.property == clip_.targetsProperty
            || (event.target == clip_.targets && event.property == XCB_NONE
                && fetchingTargets_))
        {
            fetchingTargets_ = false;
            if (event.property != XCB_NONE)
                readForeignTargets();
            return;
        }
        foreach (i, ref fetch; fetches_)
        {
            if (fetch.state != Fetch.State.requested
                || (event.property != clip_.transfer[i]
                    && !(event.property == XCB_NONE
                        && event.target == targetFor(
                            clipboard_.transfers[fetch.transfer].offer,
                            clipboard_.transfers[fetch.transfer].mime[]))))
                continue;
            if (event.property == XCB_NONE)
            {
                fetch.state = Fetch.State.idle;
                clipboard_.end(fetch.transfer, TransferStatus.failed);
                return;
            }
            readTransfer(i, true);
            return;
        }
    }

    // The owner's `TARGETS`, as the MIME types of a foreign offer: every
    // target named like a MIME type, and `UTF8_STRING` as UTF-8 text.
    private void readForeignTargets()
    {
        auto reply = xcb_get_property_reply(connection_,
            xcb_get_property(connection_, 1, clip_.helper, clip_.targetsProperty,
                XCB_ATOM_ATOM, 0, 256), null);
        if (reply is null)
            return;
        scope (exit) free(reply);
        const count = xcb_get_property_value_length(reply) / 4;
        const atoms = (cast(const(uint)*) xcb_get_property_value(reply))[0 .. count];

        char[maxMimeType][maxOfferTypes] names;
        const(char)[][maxOfferTypes] types;
        uint[maxOfferTypes] targets;
        size_t n;
        bool text;
        foreach (atom; atoms)
        {
            if (n == maxOfferTypes)
                break;
            if (atom == clip_.utf8)
            {
                if (!text)
                {
                    text = true;
                    types[n] = textMime;
                    targets[n++] = atom;
                }
                continue;
            }
            auto name = xcb_get_atom_name_reply(connection_,
                xcb_get_atom_name(connection_, atom), null);
            if (name is null)
                continue;
            scope (exit) free(name);
            const length = xcb_get_atom_name_name_length(name);
            const spelled = xcb_get_atom_name_name(name)[0 .. length];
            if (length == 0 || length > maxMimeType || !isMimeType(spelled))
                continue;
            if (spelled == textMime)
            {
                if (text)
                    continue;
                text = true;
            }
            names[n][0 .. length] = spelled[];
            types[n] = names[n][0 .. length];
            targets[n++] = atom;
        }
        if (n == 0)
            return;
        auto added = clipboard_.add(firstWindow(), types[0 .. n], false);
        if (added.hasError)
            return;
        offerTargets_[added.value.index][0 .. n] = targets[0 .. n];
        publish(added.value);
    }

    private static bool isMimeType(scope const(char)[] name) @safe pure nothrow @nogc
    {
        foreach (c; name)
            if (c == '/')
                return true;
        return false;
    }

    // Reads what a conversion left in transfer slot `i`'s property: the whole
    // value, read in bounded pieces, or the start of an `INCR` transfer.
    private void readTransfer(size_t i, bool first)
    {
        ref fetch = fetches_[i];
        ulong offset;
        for (;;)
        {
            auto reply = xcb_get_property_reply(connection_,
                xcb_get_property(connection_, 0, clip_.helper, clip_.transfer[i],
                    XCB_GET_PROPERTY_TYPE_ANY, cast(uint)(offset / 4),
                    cast(uint)(clipChunkBytes / 4)), null);
            if (reply is null)
            {
                fetch.state = Fetch.State.idle;
                clipboard_.end(fetch.transfer, TransferStatus.failed);
                return;
            }
            scope (exit) free(reply);
            if (first && offset == 0 && reply.type == clip_.incr)
            {
                // Deleting the property asks the owner for the first chunk.
                fetch.state = Fetch.State.incremental;
                xcb_delete_property(connection_, clip_.helper, clip_.transfer[i]);
                xcb_flush(connection_);
                return;
            }
            const length = xcb_get_property_value_length(reply);
            const bytes = (cast(const(ubyte)*) xcb_get_property_value(reply))[0 .. length];
            if (length != 0 && fetch.state != Fetch.State.discarding)
                if (auto transfer = clipboard_.transfers.get(fetch.transfer))
                    transfer.sink.chunk(fetch.transfer, bytes);
            offset += length;
            if (reply.bytes_after != 0)
                continue;
            // Deleting the property takes the chunk, which asks an `INCR`
            // sender for the next one.
            xcb_delete_property(connection_, clip_.helper, clip_.transfer[i]);
            xcb_flush(connection_);
            // A whole value ends here; an `INCR` transfer, with an empty chunk.
            const ended = fetch.state == Fetch.State.requested || offset == 0;
            if (ended)
            {
                const discarded = fetch.state == Fetch.State.discarding;
                fetch.state = Fetch.State.idle;
                if (!discarded)
                    clipboard_.end(fetch.transfer, TransferStatus.completed);
            }
            return;
        }
    }

    private void propertyChanged(const xcb_property_notify_event_t* event)
    {
        if (event.state == XCB_PROPERTY_DELETE)
        {
            // A requestor took a chunk of an `INCR` transfer this
            // application serves: write the next one.
            foreach (ref serve; serves_)
                if (serve.live && serve.requestor == event.window
                    && serve.property == event.atom)
                    writeChunk(serve);
            return;
        }
        if (event.window != clip_.helper)
            return;
        foreach (i, ref fetch; fetches_)
            if (event.atom == clip_.transfer[i]
                && (fetch.state == Fetch.State.incremental
                    || fetch.state == Fetch.State.discarding))
                readTransfer(i, false);
    }

    private void serveRequest(const xcb_selection_request_event_t* request)
    {
        xcb_selection_notify_event_t reply;
        reply.response_type = XCB_SELECTION_NOTIFY;
        reply.time = request.time;
        reply.requestor = request.requestor;
        reply.selection = request.selection;
        reply.target = request.target;
        // An obsolete client names no property: the target names it.
        const property = request.property == XCB_NONE ? request.target : request.property;
        reply.property = XCB_NONE;
        scope (exit)
        {
            xcb_send_event(connection_, 0, request.requestor,
                XCB_EVENT_MASK_NO_EVENT, cast(const(char)*) &reply);
            xcb_flush(connection_);
        }

        auto record = clipboard_.offers.get(clipboard_.current);
        if (request.selection != clip_.clipboard || record is null || !record.own)
            return;
        const offer = clipboard_.current;
        if (request.target == clip_.targets)
        {
            uint[maxOfferTypes + 2] atoms;
            size_t n;
            atoms[n++] = clip_.targets;
            foreach (i; 0 .. record.typeCount)
            {
                atoms[n++] = offerTargets_[offer.index][i];
                if (record.types[i][] == textMime)
                    atoms[n++] = clip_.utf8;
            }
            xcb_change_property(connection_, XCB_PROP_MODE_REPLACE,
                request.requestor, property, XCB_ATOM_ATOM, 32, cast(uint) n,
                atoms.ptr);
            reply.property = property;
            return;
        }
        ubyte type = ubyte.max;
        foreach (i; 0 .. record.typeCount)
            if (request.target == offerTargets_[offer.index][i]
                || (request.target == clip_.utf8 && record.types[i][] == textMime))
                type = cast(ubyte) i;
        if (type == ubyte.max)
            return;

        // One chunk fits: send it whole. Otherwise announce `INCR`, and the
        // requestor's deletions pull the rest (`writeChunk`).
        auto chunk = UniqueBuffer!(ubyte, 1)();
        chunk.length = clipChunkBytes;
        const n = fillFully(*record, record.types[type][], 0, chunk[]);
        if (n < clipChunkBytes)
        {
            xcb_change_property(connection_, XCB_PROP_MODE_REPLACE,
                request.requestor, property, request.target, 8, cast(uint) n,
                chunk[].ptr);
            reply.property = property;
            return;
        }
        size_t slot = serves_.length;
        foreach (i, ref serve; serves_)
            if (!serve.live)
            {
                slot = i;
                break;
            }
        if (slot == serves_.length)
            return; // every slot is serving: refuse rather than stall one
        serves_[slot] = Serve(request.requestor, property, request.target,
            offer, type, 0, true);
        const uint mask = XCB_EVENT_MASK_PROPERTY_CHANGE;
        if (request.requestor != clip_.helper)
            xcb_change_window_attributes(connection_, request.requestor,
                XCB_CW_EVENT_MASK, &mask);
        const uint lowerBound = cast(uint) clipChunkBytes;
        xcb_change_property(connection_, XCB_PROP_MODE_REPLACE,
            request.requestor, property, clip_.incr, 32, 1, &lowerBound);
        reply.property = property;
    }

    // The next `INCR` chunk; an empty one ends the transfer.
    private void writeChunk(ref Serve serve)
    {
        auto record = clipboard_.offers.get(serve.offer);
        auto chunk = UniqueBuffer!(ubyte, 1)();
        chunk.length = clipChunkBytes;
        const n = record is null ? 0
            : fillFully(*record, record.types[serve.type][], serve.offset, chunk[]);
        xcb_change_property(connection_, XCB_PROP_MODE_REPLACE, serve.requestor,
            serve.property, serve.target, 8, cast(uint) n, chunk[].ptr);
        xcb_flush(connection_);
        serve.offset += n;
        if (n == 0)
            serve.live = false;
    }

    // Fills `buffer` as far as the provider has bytes: a provider may return
    // short reads before its end.
    private static size_t fillFully(ref OfferRecord record, scope const(char)[] mime,
        ulong offset, scope ubyte[] buffer)
    {
        size_t filled;
        while (filled < buffer.length)
        {
            const n = record.fill(mime, offset + filled, buffer[filled .. $]);
            if (n == 0)
                break;
            filled += n;
        }
        return filled;
    }

    private void publish(OfferId offer)
    {
        const previous = clipboard_.current;
        if (previous != offer)
            if (auto old = clipboard_.offers.get(previous))
            {
                if (old.own)
                    announce(previous, DataOfferAction.withdrawn);
                dropOffer(previous);
            }
        clipboard_.current = offer;
        announce(offer, DataOfferAction.offered);
    }

    private void announce(OfferId offer, DataOfferAction action)
    {
        auto record = clipboard_.offers.get(offer);
        assert(record !is null, "announcing a live offer");
        const window = record.window;
        const count = action == DataOfferAction.offered ? record.typeCount : 1;
        foreach (i; 0 .. count)
            emitText(window, record.types[i][],
                (TextId mime, size_t kept) => DataOfferEvent(offer, action, mime));
    }

    // Ends an offer: its transfers fail, and the `INCR` transfers this
    // application serves from it stop.
    private void dropOffer(OfferId offer)
    {
        foreach (h; clipboard_.transfers.byLive)
            if (clipboard_.transfers[h].offer == offer)
                fetches_[h.index].state = fetches_[h.index].state
                    == Fetch.State.incremental ? Fetch.State.discarding : Fetch.State.idle;
        foreach (ref serve; serves_)
            if (serve.offer == offer)
                serve.live = false;
        clipboard_.drop(offer);
    }

    private WindowId firstWindow()
    {
        foreach (h; windows_.byLive)
            return h;
        return WindowId.init;
    }
    WsiResult!void withText(Fn)(TextId id, scope Fn fn)
        => events_.withText(id, fn);

    /// Sets `id`'s motion policy (`ED9`): whether its pointer motion merges,
    /// and whether relative motion merges by summing.
    WsiResult!void setMotionPolicy(WindowId id, bool coalesce, bool sumRelative)
    {
        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        return events_.setMotionPolicy(id, coalesce, sumRelative);
    }

    /// Copies the newest samples of `id`'s `pointer` into `into`, in
    /// arrival order, and returns how many (`ED3`).
    size_t copySamples(WindowId id, PointerId pointer, scope PointerSample[] into)
        const @safe pure nothrow @nogc => events_.copySamples(id, pointer, into);

    /// Copies an event's text into a `TextPool` the caller owns (`ED8`).
    /// See `EventQueue.retain`.
    WsiResult!WindowEvent retain(P)(WindowEvent event, ref P pool)
        => events_.retain(event, pool);

    private void remember(WsiError error) nothrow @nogc
    {
        if (!hasStickyError_)
        {
            error.backend = BackendKind.x11;
            stickyError_ = error;
            hasStickyError_ = true;
        }
    }
}

/// ImportC drops C `const`, so handing an immutable callback table to the
/// client API needs this documented un-const (same as the Wayland bridge).
private T* listenerPtr(T)(ref immutable T listener) @system pure nothrow @nogc
    => cast(T*) &listener;

private immutable xcb_xim_im_callback ximListener = {
    forward_event: &X11Wsi.onXimForwardEvent,
    commit_string: &X11Wsi.onXimCommit,
    disconnected: &X11Wsi.onXimDisconnected,
};

private WsiResult!T x11Failure(T)(WsiOperation operation, long nativeCode,
    scope const(char)[] diagnostic,
    WsiErrorKind kind = WsiErrorKind.nativeFailure)
{
    return wsiErr!T(wsiError(kind, operation, BackendKind.x11,
        nativeCode, diagnostic));
}

@("wsi.x11.keyLocationFollowsTheEvdevMap")
@safe pure nothrow @nogc
unittest
{
    assert(X11Wsi.x11KeyLocation(50) == KeyLocation.left);
    assert(X11Wsi.x11KeyLocation(62) == KeyLocation.right);
    assert(X11Wsi.x11KeyLocation(37) == KeyLocation.left);
    assert(X11Wsi.x11KeyLocation(105) == KeyLocation.right);
    assert(X11Wsi.x11KeyLocation(64) == KeyLocation.left);
    assert(X11Wsi.x11KeyLocation(108) == KeyLocation.right);
    assert(X11Wsi.x11KeyLocation(79) == KeyLocation.numpad);
    assert(X11Wsi.x11KeyLocation(91) == KeyLocation.numpad);
    assert(X11Wsi.x11KeyLocation(104) == KeyLocation.numpad);
    assert(X11Wsi.x11KeyLocation(106) == KeyLocation.numpad);
    assert(X11Wsi.x11KeyLocation(38) == KeyLocation.standard);
    assert(X11Wsi.x11KeyLocation(9) == KeyLocation.standard);
}

@("wsi.x11.modifiersComeFromTheCoreStateMask")
@safe pure nothrow @nogc
unittest
{
    assert(X11Wsi.x11Mods(0) == Mods());
    assert(X11Wsi.x11Mods(0x1) == Mods(shift: true));
    assert(X11Wsi.x11Mods(0x4) == Mods(ctrl: true));
    assert(X11Wsi.x11Mods(0x8) == Mods(alt: true));
    assert(X11Wsi.x11Mods(0x40) == Mods(super_: true));
    assert(X11Wsi.x11Mods(0x4 | 0x1) == Mods(ctrl: true, shift: true));
    // Lock (caps) and Mod2 (num lock) are latched states, not chord
    // modifiers, and must not leak into Mods.
    assert(X11Wsi.x11Mods(0x2 | 0x10) == Mods());
}

@("wsi.x11.heldKeysRepeatOnlyWithoutAnInterveningRelease")
@safe pure nothrow @nogc
unittest
{
    ulong[4] keys;
    assert(!X11Wsi.keyIsDownIn(keys, 38));
    X11Wsi.setKeyDownIn(keys, 38, true);
    assert(X11Wsi.keyIsDownIn(keys, 38));
    X11Wsi.setKeyDownIn(keys, 200, true);
    assert(X11Wsi.keyIsDownIn(keys, 200));
    X11Wsi.setKeyDownIn(keys, 38, false);
    assert(!X11Wsi.keyIsDownIn(keys, 38));
    assert(X11Wsi.keyIsDownIn(keys, 200));
    X11Wsi.setKeyDownIn(keys, 200, false);
    assert(!X11Wsi.keyIsDownIn(keys, 200));
}
