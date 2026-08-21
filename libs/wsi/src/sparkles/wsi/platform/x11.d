/**
Native X11/XCB lifecycle integrated as an Event Horizon foreign fd.

XCB owns no blocking loop: its connection descriptor is armed with
`OpPollAdd`, completions only mark readiness, and `runIntegratedOnce` drains
native values before re-arming the same Event Horizon loop. XIM/keymap work is
a later input slice and cannot introduce another display connection or wait.
*/
module sparkles.wsi.platform.x11;

version (linux):

import core.sys.posix.pthread : pthread_equal, pthread_self, pthread_t;
import core.time : Duration;
import std.math : isFinite;

import sparkles.base.text.utf8 : validateUtf8;
import sparkles.event_horizon.errors : IoErrorStage, IoResult, OpKind,
    ioErr, ioOk;
import sparkles.event_horizon.loop : DefaultLoop, RunStatus;
import sparkles.event_horizon.op : Completion, OpHandle, OpPollAdd, PollEvents;
import sparkles.input.events : KeyAction, Mods;
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
    }

    private void* connection_;
    private wsi_xcb_bootstrap bootstrap_;
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

    /** Connects to the process' selected X display on the calling UI thread. */
    static WsiResult!void open(out X11Wsi wsi)
    {
        int nativeError;
        wsi.connection_ = wsi_xcb_connect(&wsi.bootstrap_, &nativeError);
        if (wsi.connection_ is null)
            return x11Failure!void(WsiOperation.open, nativeError,
                "xcb_connect failed", WsiErrorKind.unavailable);
        if (wsi.bootstrap_.fd < 0)
        {
            wsi_xcb_disconnect(wsi.connection_);
            wsi.connection_ = null;
            return x11Failure!void(WsiOperation.open, 0,
                "XCB connection has no pollable descriptor");
        }
        // Best effort: without XKB the server keeps synthesizing a release
        // before each repeated press, and held keys read as typing.
        cast(void) wsi_xcb_enable_detectable_autorepeat(wsi.connection_);
        wsi.ownerThread_ = pthread_self();
        wsi.open_ = true;
        return wsiOk();
    }

    WsiResult!WindowId createWindow(in WindowConfig config)
    {
        auto owner = requireOwner!WindowId(WsiOperation.createWindow);
        if (owner.hasError)
            return owner;
        if (closed_)
            return x11Failure!WindowId(WsiOperation.createWindow, 0,
                "WSI is closed", WsiErrorKind.closed);
        if (config.logicalSize.width < 0 || config.logicalSize.height < 0
            || !config.logicalSize.width.isFinite
            || !config.logicalSize.height.isFinite
            || config.logicalSize.width > ushort.max
            || config.logicalSize.height > ushort.max)
            return x11Failure!WindowId(WsiOperation.createWindow, 0,
                "invalid X11 window size", WsiErrorKind.invalidArgument);
        if (config.parent.valid || config.transparent || !config.resizable
            || config.decorations == DecorationPreference.none
            || config.state != WindowStartupState.normal)
            return x11Failure!WindowId(WsiOperation.createWindow, 0,
                "requested X11 startup configuration is not implemented",
                WsiErrorKind.unsupported);
        if (validateUtf8(config.title.value).hasError)
            return x11Failure!WindowId(WsiOperation.createWindow, 0,
                "window title is not valid UTF-8",
                WsiErrorKind.invalidArgument);

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

        const window = wsi_xcb_generate_id(connection_);
        if (window == 0)
            return x11Failure!WindowId(WsiOperation.createWindow,
                wsi_xcb_connection_error(connection_),
                "xcb_generate_id failed");
        const width = cast(ushort) config.logicalSize.width;
        const height = cast(ushort) config.logicalSize.height;
        const error = wsi_xcb_create_window(connection_, &bootstrap_, window,
            width, height, config.title.value.ptr,
            cast(ushort) config.title.length, config.visible);
        if (error != 0)
            return x11Failure!WindowId(WsiOperation.createWindow, error,
                "XCB window request batch failed to flush");

        ref slot = windows_[index];
        ++slot.generation;
        if (slot.generation == 0)
            ++slot.generation;
        slot.window = window;
        slot.live = true;
        slot.ready = true;
        slot.metrics = SurfaceMetrics(
            LogicalSize(width, height), PhysicalSize(width, height),
            ScaleFactor(1));
        auto id = idAt(index);
        auto queued = emit(id, ReadyEvent(slot.metrics));
        if (queued.hasError)
        {
            cast(void) wsi_xcb_destroy_window(connection_, window);
            slot.live = false;
            slot.ready = false;
            slot.window = 0;
            return wsiErr!WindowId(queued.error);
        }
        return wsiOk(id);
    }

    WsiResult!void destroyWindow(WindowId id)
    {
        auto checked = checkedSlot(id, WsiOperation.close);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        ref slot = windows_[checked.value];
        const error = wsi_xcb_destroy_window(connection_, slot.window);
        if (error != 0)
            return x11Failure!void(WsiOperation.close, error,
                "xcb_destroy_window failed");
        slot.live = false;
        slot.ready = false;
        slot.window = 0;
        return emit(id, DestroyedEvent());
    }

    WsiResult!NativeHandles nativeHandles(WindowId id)
    {
        auto checked = checkedSlot(id, WsiOperation.queryHandle);
        if (checked.hasError)
            return wsiErr!NativeHandles(checked.error);
        ref slot = windows_[checked.value];

        NativeHandles handles;
        handles.display = DisplayHandle(X11DisplayHandle(connection_, null,
            bootstrap_.screen_index));
        handles.window = WindowHandle(X11WindowHandle(slot.window,
            bootstrap_.root_visual));
        return wsiOk(handles);
    }

    /** Drains every XCB event currently buffered; never waits. */
    WsiResult!size_t pumpEvents()
    {
        auto owner = requireOwner!size_t(WsiOperation.dispatch);
        if (owner.hasError)
            return owner;
        size_t count;
        wsi_xcb_event native;
        while (wsi_xcb_poll_event(connection_, &bootstrap_, &native) != 0)
        {
            ++count;
            handleNative(native);
        }
        const connectionError = wsi_xcb_connection_error(connection_);
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
        return armPoll();
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
        if (closed_)
            return wsiOk();

        auto detached = detach();
        if (detached.hasError)
            return detached;
        foreach (i; 0 .. windows_.length)
            if (windows_[i].live)
                cast(void) destroyWindow(idAt(i));
        if (connection_ !is null)
        {
            wsi_xcb_disconnect(connection_);
            connection_ = null;
        }
        closed_ = true;
        open_ = false;
        return hasStickyError_ ? wsiErr!void(stickyError_) : wsiOk();
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

    private void handleNative(in wsi_xcb_event native)
    {
        if (native.kind == WSI_XCB_EVENT_ERROR)
        {
            remember(wsiError(WsiErrorKind.nativeFailure,
                WsiOperation.dispatch, BackendKind.x11,
                native.native_code, "X11 protocol request failed"));
            return;
        }
        const index = indexOfWindow(native.window);
        if (index == size_t.max)
            return;
        ref slot = windows_[index];
        auto id = idAt(index);
        switch (native.kind)
        {
            case WSI_XCB_EVENT_EXPOSE:
                cast(void) emit(id, ExposedEvent());
                cast(void) emit(id, FrameReadyEvent());
                break;
            case WSI_XCB_EVENT_CONFIGURE:
                auto metrics = SurfaceMetrics(
                    LogicalSize(native.width, native.height),
                    PhysicalSize(native.width, native.height), ScaleFactor(1));
                if (metrics != slot.metrics)
                    cast(void) emit(id, SurfaceMetricsChangedEvent(metrics));
                slot.metrics = metrics;
                cast(void) emit(id,
                    MovedEvent(PhysicalPosition(native.x, native.y)));
                break;
            case WSI_XCB_EVENT_CLOSE:
                cast(void) emit(id, CloseRequestedEvent());
                break;
            case WSI_XCB_EVENT_KEY_PRESS:
            case WSI_XCB_EVENT_KEY_RELEASE:
                const pressed = native.kind == WSI_XCB_EVENT_KEY_PRESS;
                const keycode = cast(uint) native.native_code & 0xFF;
                const repeated = pressed && keyIsDown(keycode);
                setKeyDown(keycode, pressed);
                KeyboardEvent event;
                event.physical = PhysicalKey(keycode, 0);
                event.location = x11KeyLocation(keycode);
                event.action = pressed
                    ? (repeated ? KeyAction.repeat : KeyAction.press)
                    : KeyAction.release;
                event.modifiers = x11Mods(native.state);
                cast(void) emit(id, event);
                break;
            case WSI_XCB_EVENT_FOCUS_IN:
                cast(void) emit(id, FocusChangedEvent(true));
                break;
            case WSI_XCB_EVENT_FOCUS_OUT:
                cast(void) emit(id, FocusChangedEvent(false));
                break;
            case WSI_XCB_EVENT_DESTROYED:
                slot.live = false;
                slot.ready = false;
                slot.window = 0;
                cast(void) emit(id, DestroyedEvent());
                break;
            default:
                break;
        }
    }

    private bool keyIsDown(uint keycode) const @safe pure nothrow @nogc
        => (pressedKeys_[(keycode >> 6) & 3] & (1UL << (keycode & 63))) != 0;

    private void setKeyDown(uint keycode, bool down) @safe pure nothrow @nogc
    {
        if (down)
            pressedKeys_[(keycode >> 6) & 3] |= 1UL << (keycode & 63);
        else
            pressedKeys_[(keycode >> 6) & 3] &= ~(1UL << (keycode & 63));
    }

    /*
    Location from the evdev-standard keycode map (X keycode = evdev + 8) that
    every current server exposes through xkeyboard-config. A server with a
    different map degrades to `standard`, never to a wrong modifier pairing,
    because left/right identity also lives in the keycode itself there.
    */
    package static KeyLocation x11KeyLocation(uint keycode) @safe pure nothrow @nogc
    {
        switch (keycode)
        {
            case 50: // KEY_LEFTSHIFT + 8
            case 37: // KEY_LEFTCTRL + 8
            case 64: // KEY_LEFTALT + 8
            case 133: // KEY_LEFTMETA + 8
                return KeyLocation.left;
            case 62: // KEY_RIGHTSHIFT + 8
            case 105: // KEY_RIGHTCTRL + 8
            case 108: // KEY_RIGHTALT + 8
            case 134: // KEY_RIGHTMETA + 8
                return KeyLocation.right;
            case 63: // KEY_KPASTERISK + 8
            case 79: .. case 91: // KEY_KP7 .. KEY_KPDOT + 8
            case 104: // KEY_KPENTER + 8
            case 106: // KEY_KPSLASH + 8
                return KeyLocation.numpad;
            default:
                return KeyLocation.standard;
        }
    }

    /// Core-protocol state mask: Shift, Control, Mod1 (Alt), Mod4 (Super).
    package static Mods x11Mods(uint state) @safe pure nothrow @nogc
        => Mods(
            ctrl: (state & 0x4) != 0,
            alt: (state & 0x8) != 0,
            shift: (state & 0x1) != 0,
            super_: (state & 0x40) != 0);

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

    private WsiResult!void emit(Payload)(WindowId id,
        Payload payload) nothrow
    {
        auto result = events_.push(WindowEvent(nextSequence_, id,
            WindowEventPayload(payload)));
        if (result.hasError)
        {
            remember(result.error);
            return wsiErr!void(stickyError_);
        }
        ++nextSequence_;
        return wsiOk();
    }

    private void remember(WsiError error) nothrow
    {
        if (!hasStickyError_)
        {
            error.backend = BackendKind.x11;
            stickyError_ = error;
            hasStickyError_ = true;
        }
    }
}

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
    X11Wsi wsi;
    assert(!wsi.keyIsDown(38));
    wsi.setKeyDown(38, true);
    assert(wsi.keyIsDown(38));
    wsi.setKeyDown(200, true);
    assert(wsi.keyIsDown(200));
    wsi.setKeyDown(38, false);
    assert(!wsi.keyIsDown(38));
    assert(wsi.keyIsDown(200));
    wsi.setKeyDown(200, false);
    assert(!wsi.keyIsDown(200));
}
