/**
Native X11/XCB lifecycle integrated as an Event Horizon foreign fd.

XCB owns no blocking loop: its connection descriptor is armed with
`OpPollAdd`, completions only mark readiness, and `runIntegratedOnce` drains
native values before re-arming the same Event Horizon loop. XIM/keymap work is
a later input slice and cannot introduce another display connection or wait.
*/
module sparkles.wsi.platform.x11;

version (linux):

import core.stdc.stdlib : free;
import core.stdc.string : strlen;
import core.sys.posix.pthread : pthread_equal, pthread_self, pthread_t;
import core.time : Duration;

import sparkles.base.text.utf8 : validateUtf8;
import sparkles.event_horizon.errors : IoErrorStage, IoResult, OpKind,
    ioErr, ioOk;
import sparkles.event_horizon.loop : DefaultLoop, RunStatus;
import sparkles.event_horizon.op : Completion, OpHandle, OpPollAdd, PollEvents;
import sparkles.input.events : KeyAction, Mods, PointerButton;
import sparkles.input.pointer : PointerShape;
import sparkles.wsi.events;
import sparkles.wsi.handles;
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
        uint generation;
        bool live;
        bool ready;
        SurfaceMetrics metrics;
        uint cursor;
        ushort xic;
        bool xicReady;
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
    private Slot[maxWindows] windows_;
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
    private size_t pendingIcSlot_ = size_t.max;

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
        const(char)* name)
    {
        auto reply = xcb_intern_atom_reply(connection,
            xcb_intern_atom(connection, 0,
                cast(ushort) strlen(name), name), null);
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

        size_t index = size_t.max;
        foreach (i, ref slot; windows_)
            if (!slot.live && slot.window == 0)
            {
                index = i;
                break;
            }
        if (index == size_t.max)
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

        ref slot = windows_[index];
        ++slot.generation;
        if (slot.generation == 0)
            ++slot.generation;
        slot.xic = 0;
        slot.xicReady = false;
        slot.window = window;
        slot.live = true;
        slot.ready = true;
        slot.metrics = SurfaceMetrics(
            LogicalSize(width, height), PhysicalSize(width, height),
            ScaleFactor(1));
        auto id = idAt(index);
        requestNextIc();
        const hadSticky = hasStickyError_;
        emit(id, ReadyEvent(slot.metrics));
        if (!hadSticky && hasStickyError_)
        {
            destroyNative(window);
            slot.live = false;
            slot.ready = false;
            slot.window = 0;
            return wsiErr!WindowId(stickyError_);
        }
        return wsiOk(id);
    }

    WsiResult!void destroyWindow(WindowId id)
    {
        auto checked = checkedSlot(id, WsiOperation.close);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        ref slot = windows_[checked.value];
        if (slot.xicReady && xim_ !is null)
            xcb_xim_destroy_ic(xim_, slot.xic, null, null);
        slot.xic = 0;
        slot.xicReady = false;
        const error = destroyNative(slot.window);
        if (error != 0)
            return x11Failure!void(WsiOperation.close, error,
                "xcb_destroy_window failed");
        slot.live = false;
        slot.ready = false;
        slot.window = 0;
        emit(id, DestroyedEvent());
        return hasStickyError_ ? wsiErr!void(stickyError_) : wsiOk();
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
        ref slot = windows_[checked.value];
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
        ref slot = windows_[checked.value];
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

    WsiResult!NativeHandles nativeHandles(WindowId id)
    {
        auto checked = checkedSlot(id, WsiOperation.queryHandle);
        if (checked.hasError)
            return wsiErr!NativeHandles(checked.error);
        ref slot = windows_[checked.value];

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
        return ximConnected_ && windows_[checked.value].xicReady;
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
        owner.pendingIcSlot_ = size_t.max;
        foreach (ref slot; owner.windows_)
        {
            slot.xic = 0;
            slot.xicReady = false;
        }
    }

    /*
    Input contexts are created one at a time: the create-ic reply carries no
    window, so a single in-flight request keeps the reply attributable.
    */
    private void requestNextIc() nothrow @nogc
    {
        if (!ximConnected_ || pendingIcSlot_ != size_t.max)
            return;
        foreach (i, ref slot; windows_)
        {
            if (!slot.live || slot.xicReady || slot.xic != 0)
                continue;
            pendingIcSlot_ = i;
            uint style = XCB_IM_PreeditNothing | XCB_IM_StatusNothing;
            uint window = slot.window;
            // Attribute names are XCB_XIM_XNInputStyle etc.; spelled out
            // because ImportC exposes only integer macros.
            if (!xcb_xim_create_ic(xim_, &onIcCreated, &this,
                "inputStyle".ptr, &style,
                "clientWindow".ptr, &window,
                "focusWindow".ptr, &window,
                cast(void*) null))
                pendingIcSlot_ = size_t.max;
            return;
        }
    }

    private extern (C) static void onIcCreated(xcb_xim_t*, ushort ic,
        void* data) nothrow @nogc
    {
        auto owner = cast(X11Wsi*) data;
        const index = owner.pendingIcSlot_;
        owner.pendingIcSlot_ = size_t.max;
        if (index < owner.windows_.length && owner.windows_[index].live)
        {
            owner.windows_[index].xic = ic;
            owner.windows_[index].xicReady = true;
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
        TextCommittedEvent committed;
        if (committed.text.assign(bytes))
            owner.emit(owner.idAt(index), committed);
    }

    private size_t indexOfIc(ushort ic) const nothrow @nogc
    {
        if (ic == 0)
            return size_t.max;
        foreach (i, ref slot; windows_)
            if (slot.live && slot.xicReady && slot.xic == ic)
                return i;
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
                    cancelled.error.errnoValue,
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
        foreach (i; 0 .. windows_.length)
            if (windows_[i].live)
            {
                if (windows_[i].cursor != 0)
                {
                    xcb_free_cursor(connection_, windows_[i].cursor);
                    windows_[i].cursor = 0;
                }
                destroyNative(windows_[i].window);
                windows_[i].live = false;
                windows_[i].ready = false;
                windows_[i].window = 0;
            }
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
                submitted.error.errnoValue, "OpPollAdd(XCB fd) failed");
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
    private enum corePointer = PointerId(1, 1);

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
                ref slot = windows_[index];
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
                if (ximConnected_ && windows_[index].xicReady)
                {
                    xcb_xim_forward_event(xim_, windows_[index].xic,
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
                    ref slot = windows_[index];
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
            case XCB_DESTROY_NOTIFY:
                auto event = cast(const xcb_destroy_notify_event_t*) generic;
                const index = indexOfWindow(event.window);
                if (index == size_t.max)
                    return;
                ref slot = windows_[index];
                auto id = idAt(index);
                slot.live = false;
                slot.ready = false;
                slot.window = 0;
                emit(id, DestroyedEvent());
                break;
            default:
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
        foreach (i, const ref slot; windows_)
            if (slot.live && slot.window == window)
                return i;
        return size_t.max;
    }

    private WindowId idAt(size_t index) const pure nothrow @nogc
        => WindowId(cast(uint) index + 1, windows_[index].generation);

    private WsiResult!size_t checkedSlot(WindowId id,
        WsiOperation operation)
    {
        auto owner = requireOwner!size_t(operation);
        if (owner.hasError)
            return owner;
        if (!id.valid || id.slot > maxWindows)
            return x11Failure!size_t(operation, 0,
                "invalid X11 window id", WsiErrorKind.staleId);
        size_t index = cast(size_t) id.slot - 1;
        const slot = windows_[index];
        if (!slot.live || slot.generation != id.generation)
            return x11Failure!size_t(operation, 0,
                "stale X11 window id", WsiErrorKind.staleId);
        return wsiOk(index);
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
            WindowEventPayload(payload)));
        if (result.hasError)
        {
            remember(result.error);
            return;
        }
        ++nextSequence_;
    }

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
