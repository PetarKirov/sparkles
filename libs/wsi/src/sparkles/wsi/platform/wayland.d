/**
Native Wayland lifecycle integrated through Event Horizon's foreign-fd path.

The adapter owns one `wl_display`, never calls a blocking Wayland dispatch
function, acknowledges each `xdg_surface.configure` inside its listener, and
observes the mandatory `prepare_read`/`read_events|cancel_read` pairing.  The
renderer receives the `wl_surface` only after the initial configure.
*/
module sparkles.wsi.platform.wayland;

version (linux):

import core.stdc.errno : EAGAIN, errno;
import core.stdc.string : strcmp;
import core.sys.posix.pthread : pthread_equal, pthread_self, pthread_t;
import core.sys.posix.sys.mman : MAP_FAILED, MAP_PRIVATE, PROT_READ, mmap,
    munmap;
import core.sys.posix.unistd : posixClose = close;
import core.time : Duration;
import std.math : isFinite;
import std.traits : Parameters;

import sparkles.base.text.utf8 : validateUtf8;
import sparkles.input.events : KeyAction, Mods, PointerButton;
import sparkles.input.pointer : PointerShape;
import sparkles.event_horizon.errors : IoErrorStage, IoResult, OpKind,
    ioErr, ioOk;
import sparkles.event_horizon.loop : DefaultLoop, RunStatus;
import sparkles.event_horizon.op : Completion, OpHandle, OpPollAdd, PollEvents;
import sparkles.wsi.events;
import sparkles.wsi.handles;
import sparkles.wsi.loop : EventQueue;
import sparkles.wsi.types;

import wayland_native;

/*
The listener tables are immutable data, but ImportC drops the C `const`
qualifier from `*_add_listener` parameters. The protocol never writes
through a listener table, so handing out a mutable view is sound.
*/
private T* listenerPtr(T)(ref immutable T listener) @system pure nothrow @nogc
    => cast(T*) &listener;

/** One UI-thread Wayland connection and its bounded native event queue. */
struct WaylandWsi
{
    enum maxWindows = 16;
    enum maxEvents = 128;

    @disable this(this);

    private struct Slot
    {
        WaylandWsi* owner;
        wl_surface* surface;
        xdg_surface* xdgSurface;
        xdg_toplevel* toplevel;
        wl_callback* frameCallback;
        uint generation;
        bool live;
        bool ready;
        int pendingWidth;
        int pendingHeight;
        LogicalSize requestedSize;
        SurfaceMetrics metrics;
        ubyte enteredOutputs;
        int scale = 1;
        PointerShape cursorShape = PointerShape.default_;
        bool cursorVisible = true;
    }

    private wl_display* display_;
    private wl_registry* registry_;
    private wl_compositor* compositor_;
    private xdg_wm_base* wmBase_;
    private wl_seat* seat_;
    private uint seatVersion_;
    private wl_keyboard* keyboard_;
    private xkb_context* xkbContext_;
    private xkb_keymap* xkbKeymap_;
    private xkb_state* xkbState_;
    private struct Output
    {
        uint registryName;
        wl_output* output;
        int scale = 1;
        int pendingScale = 1;
    }

    private Output[8] outputs_;
    private wl_pointer* pointer_;
    private wp_cursor_shape_manager_v1* cursorShapeManager_;
    private wp_cursor_shape_device_v1* cursorShapeDevice_;
    private uint pointerEnterSerial_;
    private const(wl_surface)* pointerFocus_;
    private LogicalPosition pointerPosition_;
    private double pendingScrollDx_ = 0;
    private double pendingScrollDy_ = 0;
    private int pendingDiscreteX_;
    private int pendingDiscreteY_;
    private ScrollSource pendingScrollSource_ = ScrollSource.unknown;
    private bool pendingScroll_;
    private const(wl_surface)* keyboardFocus_;
    private Mods keyboardMods_;
    private int keyRepeatRate_;
    private int keyRepeatDelayMs_;
    private wl_callback* bootstrapSync_;
    private pthread_t ownerThread_;
    private Slot[maxWindows] windows_;
    private EventQueue!maxEvents events_;
    private ulong nextSequence_ = 1;
    private ulong nextFrameToken_ = 1;
    private bool bootstrapComplete_;
    private bool open_;
    private bool closed_;
    private bool hasStickyError_;
    private WsiError stickyError_;

    private DefaultLoop* loop_;
    private OpHandle pollHandle_;
    private bool pollArmed_;
    private bool pollCompleted_;
    private bool preparedRead_;
    private bool nativeIoBorrowed_;
    private bool detaching_;
    private int pollResult_;

    /**
    Opens the compositor connection and attaches it without a round trip.

    Registry enumeration is completed asynchronously through `loop`; callers
    drive `runIntegratedOnce` until `bootstrapComplete` before creating a
    window. Event Horizon performs the first and every subsequent wait.
    */
    static WsiResult!void open(out WaylandWsi wsi, ref DefaultLoop loop)
    {
        wsi.display_ = wl_display_connect(null);
        if (wsi.display_ is null)
            return waylandFailure!void(WsiOperation.open, errno,
                "wl_display_connect failed", WsiErrorKind.unavailable);

        wsi.ownerThread_ = pthread_self();
        wsi.open_ = true;
        wsi.loop_ = &loop;
        wsi.registry_ = wl_display_get_registry(wsi.display_);
        if (wsi.registry_ is null
            || wl_registry_add_listener(wsi.registry_,
                listenerPtr(registryListener), &wsi) != 0)
        {
            wsi.closeConnectionOnly();
            return waylandFailure!void(WsiOperation.open, 0,
                "failed to install Wayland registry listener");
        }
        wsi.bootstrapSync_ = wl_display_sync(wsi.display_);
        if (wsi.bootstrapSync_ is null
            || wl_callback_add_listener(wsi.bootstrapSync_,
                listenerPtr(bootstrapListener), &wsi) != 0)
        {
            wsi.closeConnectionOnly();
            return waylandFailure!void(WsiOperation.open, 0,
                "failed to arm asynchronous registry sync");
        }

        auto armed = wsi.prepareAndArm();
        if (armed.hasError)
        {
            wsi.closeConnectionOnly();
            return armed;
        }
        return wsiOk();
    }

    bool bootstrapComplete() const pure nothrow @nogc
        => bootstrapComplete_;

    bool canCreateWindows() const pure nothrow @nogc
        => bootstrapComplete_ && compositor_ !is null && wmBase_ !is null
            && !hasStickyError_;

    WsiResult!WindowId createWindow(in WindowConfig config)
    {
        auto owner = requireOwner!WindowId(WsiOperation.createWindow);
        if (owner.hasError)
            return owner;
        if (closed_)
            return waylandFailure!WindowId(WsiOperation.createWindow, 0,
                "WSI is closed", WsiErrorKind.closed);
        if (!bootstrapComplete_)
            return waylandFailure!WindowId(WsiOperation.createWindow, 0,
                "Wayland registry bootstrap is still in flight",
                WsiErrorKind.unavailable);
        if (compositor_ is null || wmBase_ is null)
            return waylandFailure!WindowId(WsiOperation.createWindow, 0,
                "compositor lacks wl_compositor or xdg_wm_base",
                WsiErrorKind.unavailable);
        if (config.logicalSize.width <= 0 || config.logicalSize.height <= 0
            || !config.logicalSize.width.isFinite
            || !config.logicalSize.height.isFinite
            || config.logicalSize.width > int.max
            || config.logicalSize.height > int.max)
            return waylandFailure!WindowId(WsiOperation.createWindow, 0,
                "invalid Wayland logical window size",
                WsiErrorKind.invalidArgument);
        if (!config.visible || config.parent.valid || config.transparent
            || config.state == WindowStartupState.minimized
            || config.decorations == DecorationPreference.server)
            return waylandFailure!WindowId(WsiOperation.createWindow, 0,
                "requested Wayland startup configuration is not implemented",
                WsiErrorKind.unsupported);
        if (validateUtf8(config.title.value).hasError)
            return waylandFailure!WindowId(WsiOperation.createWindow, 0,
                "window title is not valid UTF-8",
                WsiErrorKind.invalidArgument);

        size_t index = size_t.max;
        foreach (i, ref slot; windows_)
            if (!slot.live && slot.surface is null)
            {
                index = i;
                break;
            }
        if (index == size_t.max)
            return waylandFailure!WindowId(WsiOperation.createWindow, 0,
                "Wayland window capacity reached", WsiErrorKind.capacity);

        auto paused = pausePoll();
        if (paused.hasError)
            return wsiErr!WindowId(paused.error);

        ref slot = windows_[index];
        ++slot.generation;
        if (slot.generation == 0)
            ++slot.generation;
        slot.owner = &this;
        slot.live = true;
        slot.ready = false;
        slot.requestedSize = config.logicalSize;
        slot.surface = wl_compositor_create_surface(compositor_);
        if (slot.surface !is null
            && wl_surface_add_listener(slot.surface,
                listenerPtr(surfaceListener), &slot) != 0)
        {
            wl_surface_destroy(slot.surface);
            slot.surface = null;
        }
        if (slot.surface !is null)
            slot.xdgSurface = xdg_wm_base_get_xdg_surface(
                wmBase_, slot.surface);
        if (slot.xdgSurface !is null)
            slot.toplevel = xdg_surface_get_toplevel(
                slot.xdgSurface);
        if (slot.surface is null || slot.xdgSurface is null
            || slot.toplevel is null
            || xdg_surface_add_listener(slot.xdgSurface,
                listenerPtr(xdgSurfaceListener), &slot) != 0
            || xdg_toplevel_add_listener(slot.toplevel,
                listenerPtr(toplevelListener), &slot) != 0)
        {
            destroyNative(slot);
            // Re-arm on the failure path; its own error must not shadow the
            // construction failure being reported, so it goes to the sticky
            // slot instead.
            auto rearmed = prepareAndArm();
            if (rearmed.hasError)
                remember(rearmed.error);
            return waylandFailure!WindowId(WsiOperation.createWindow, 0,
                "failed to construct Wayland toplevel object tree");
        }

        char[257] title;
        title[0 .. config.title.length] = config.title.value;
        title[config.title.length] = '\0';
        xdg_toplevel_set_title(slot.toplevel, title.ptr);
        xdg_toplevel_set_app_id(slot.toplevel, "sparkles-wsi");
        if (!config.resizable)
        {
            const width = cast(int) config.logicalSize.width;
            const height = cast(int) config.logicalSize.height;
            xdg_toplevel_set_min_size(slot.toplevel, width, height);
            xdg_toplevel_set_max_size(slot.toplevel, width, height);
        }
        if (config.state == WindowStartupState.maximized)
            xdg_toplevel_set_maximized(slot.toplevel);
        else if (config.state == WindowStartupState.fullscreen)
            xdg_toplevel_set_fullscreen(slot.toplevel, null);

        // Mandatory no-buffer initial commit. The configure listener acks
        // immediately; only then does the renderer receive the wl_surface.
        wl_surface_commit(slot.surface);
        auto rearmed = prepareAndArm();
        if (rearmed.hasError)
        {
            destroyNative(slot);
            return wsiErr!WindowId(rearmed.error);
        }
        return wsiOk(idAt(index));
    }

    WsiResult!void setMaximized(WindowId id, bool maximized)
    {
        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        auto paused = pausePoll();
        if (paused.hasError)
            return paused;
        ref slot = windows_[checked.value];
        if (maximized)
            xdg_toplevel_set_maximized(slot.toplevel);
        else
            xdg_toplevel_unset_maximized(slot.toplevel);
        return prepareAndArm();
    }

    WsiResult!void destroyWindow(WindowId id)
    {
        auto checked = checkedSlot(id, WsiOperation.close);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        auto paused = pausePoll();
        if (paused.hasError)
            return paused;
        ref slot = windows_[checked.value];
        destroyNative(slot);
        const hadSticky = hasStickyError_;
        emit(id, DestroyedEvent());
        auto rearmed = prepareAndArm();
        if (!hadSticky && hasStickyError_)
            return wsiErr!void(stickyError_);
        return rearmed;
    }

    WsiResult!NativeHandles nativeHandles(WindowId id)
    {
        auto checked = checkedSlot(id, WsiOperation.queryHandle);
        if (checked.hasError)
            return wsiErr!NativeHandles(checked.error);
        ref slot = windows_[checked.value];
        if (!slot.ready)
            return waylandFailure!NativeHandles(WsiOperation.queryHandle, 0,
                "wl_surface is not configured yet",
                WsiErrorKind.unavailable);
        NativeHandles handles;
        handles.display = DisplayHandle(WaylandDisplayHandle(display_));
        handles.window = WindowHandle(WaylandWindowHandle(slot.surface));
        return wsiOk(handles);
    }

    /**
    Suspend Event Horizon's prepared read while a native-handle consumer calls
    an API that may itself read the shared `wl_display`.

    Vulkan surface capability and swapchain calls are the motivating consumer:
    Mesa may perform a private Wayland round trip. Leaving WSI's
    `wl_display_prepare_read` outstanding would make that round trip wait on a
    read the scheduler cannot complete until the call returns. Calls must be
    paired with $(LREF endNativeIo) on this owner thread.
    */
    WsiResult!void beginNativeIo()
    {
        auto owner = requireOwner!void(WsiOperation.queryHandle);
        if (owner.hasError)
            return owner;
        if (nativeIoBorrowed_)
            return waylandFailure!void(WsiOperation.queryHandle, 0,
                "Wayland native I/O is already borrowed",
                WsiErrorKind.reentrant);
        auto paused = pausePoll();
        if (paused.hasError)
            return paused;
        nativeIoBorrowed_ = true;
        return wsiOk();
    }

    /// Re-arm Event Horizon after $(LREF beginNativeIo).
    WsiResult!void endNativeIo()
    {
        auto owner = requireOwner!void(WsiOperation.queryHandle);
        if (owner.hasError)
            return owner;
        if (!nativeIoBorrowed_)
            return waylandFailure!void(WsiOperation.queryHandle, 0,
                "Wayland native I/O is not borrowed",
                WsiErrorKind.invalidArgument);
        nativeIoBorrowed_ = false;
        return prepareAndArm();
    }

    /** Drives the sole Event Horizon wait and services completed Wayland I/O. */
    IoResult!RunStatus runIntegratedOnce(ref DefaultLoop loop,
        Duration timeout = Duration.max)
    {
        if (loop_ !is &loop)
            return ioErr!RunStatus(0, OpKind.pollAdd, IoErrorStage.submit,
                "Wayland WSI used with a different Event Horizon loop");

        bool nativeWork;
        if (!servicePoll(nativeWork))
            return ioErr!RunStatus(cast(int) stickyError_.nativeCode,
                OpKind.pollAdd, IoErrorStage.completion,
                "Wayland dispatch/re-arm failed");
        if (nativeWork)
            return ioOk(RunStatus.dispatched);

        auto result = loop.runOnce(timeout);
        if (result.hasError)
            return result;
        if (!servicePoll(nativeWork))
            return ioErr!RunStatus(cast(int) stickyError_.nativeCode,
                OpKind.pollAdd, IoErrorStage.completion,
                "Wayland dispatch/re-arm failed");
        return nativeWork && result.value != RunStatus.stopped
            ? ioOk(RunStatus.dispatched) : result;
    }

    WsiResult!size_t drain(Sink)(scope Sink sink) => events_.drain(sink);

    size_t pendingEvents() const pure nothrow @nogc => events_.length;

    WsiResult!void detach()
    {
        auto owner = requireOwner!void(WsiOperation.attach);
        if (owner.hasError)
            return owner;
        if (loop_ is null)
            return wsiOk();
        detaching_ = true;
        auto paused = pausePoll();
        if (paused.hasError)
            return paused;
        loop_ = null;
        return wsiOk();
    }

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
        foreach (ref slot; windows_)
            if (slot.live)
                destroyNative(slot);
        closeConnectionOnly();
        closed_ = true;
        open_ = false;
    }

    ~this()
    {
        closeNow();
    }

    private WsiResult!void pausePoll()
    {
        if (pollArmed_)
        {
            auto cancelled = loop_.cancelAndWait(pollHandle_);
            if (cancelled.hasError)
                return waylandFailure!void(WsiOperation.attach,
                    cancelled.error.errnoValue,
                    "failed to cancel and reap Wayland display poll");
        }
        if (preparedRead_)
        {
            wl_display_cancel_read(display_);
            preparedRead_ = false;
        }
        pollArmed_ = false;
        pollCompleted_ = false;
        return wsiOk();
    }

    private WsiResult!void prepareAndArm()
    {
        if (detaching_ || nativeIoBorrowed_ || loop_ is null)
            return wsiOk();
        if (hasStickyError_)
            return wsiErr!void(stickyError_);
        if (pollArmed_ || preparedRead_)
            return waylandFailure!void(WsiOperation.attach, 0,
                "Wayland read/poll already armed",
                WsiErrorKind.reentrant);

        while (wl_display_prepare_read(display_) != 0)
        {
            if (wl_display_dispatch_pending(display_) < 0)
                return connectionFailure(WsiOperation.dispatch,
                    "wl_display_dispatch_pending failed");
            if (hasStickyError_)
                return wsiErr!void(stickyError_);
        }
        preparedRead_ = true;

        PollEvents interests = PollEvents.readable;
        if (wl_display_flush(display_) < 0)
        {
            if (errno == EAGAIN)
                interests |= PollEvents.writable;
            else
            {
                wl_display_cancel_read(display_);
                preparedRead_ = false;
                return connectionFailure(WsiOperation.dispatch,
                    "wl_display_flush failed");
            }
        }
        auto submitted = loop_.submit(OpPollAdd(wl_display_get_fd(display_),
            interests, false), &onPollReady, &this);
        if (submitted.hasError)
        {
            wl_display_cancel_read(display_);
            preparedRead_ = false;
            return waylandFailure!void(WsiOperation.attach,
                submitted.error.errnoValue,
                "OpPollAdd(Wayland fd) failed");
        }
        pollHandle_ = submitted.value;
        pollArmed_ = true;
        return wsiOk();
    }

    private static void onPollReady(void* context,
        ref Completion completion) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) context;
        owner.pollArmed_ = false;
        owner.pollCompleted_ = true;
        owner.pollResult_ = completion.res;
    }

    private bool servicePoll(out bool nativeWork)
    {
        nativeWork = false;
        if (!pollCompleted_)
            return true;
        pollCompleted_ = false;

        if (pollResult_ < 0)
        {
            if (preparedRead_)
            {
                wl_display_cancel_read(display_);
                preparedRead_ = false;
            }
            if (detaching_)
                return true;
            remember(wsiError(WsiErrorKind.nativeFailure,
                WsiOperation.dispatch, BackendKind.wayland, -pollResult_,
                "Wayland descriptor poll failed"));
            return false;
        }

        const ready = cast(PollEvents) cast(ushort) pollResult_;
        if ((ready & PollEvents.readable) != 0)
        {
            if (wl_display_read_events(display_) < 0)
            {
                preparedRead_ = false;
                rememberConnectionFailure(WsiOperation.dispatch,
                    "wl_display_read_events failed");
                return false;
            }
            preparedRead_ = false;
            const dispatched = wl_display_dispatch_pending(display_);
            if (dispatched < 0)
            {
                rememberConnectionFailure(WsiOperation.dispatch,
                    "wl_display_dispatch_pending failed");
                return false;
            }
            nativeWork = dispatched > 0;
        }
        else
        {
            // A timer/waker cannot complete this poll op; reaching here means
            // writable/error/hangup won, so the prepared read must be paired
            // with cancellation before flushing/re-arming.
            if (preparedRead_)
            {
                wl_display_cancel_read(display_);
                preparedRead_ = false;
            }
        }

        if ((ready & (PollEvents.error | PollEvents.hangup)) != 0)
        {
            rememberConnectionFailure(WsiOperation.dispatch,
                "Wayland connection reported poll error/hangup");
            return false;
        }
        auto armed = prepareAndArm();
        if (armed.hasError)
        {
            remember(armed.error);
            return false;
        }
        return true;
    }

    private void closeConnectionOnly() nothrow @nogc
    {
        if (bootstrapSync_ !is null)
        {
            wl_callback_destroy(bootstrapSync_);
            bootstrapSync_ = null;
        }
        releasePointer();
        if (cursorShapeManager_ !is null)
        {
            wp_cursor_shape_manager_v1_destroy(cursorShapeManager_);
            cursorShapeManager_ = null;
        }
        if (keyboard_ !is null)
        {
            if (seatVersion_ >= WL_KEYBOARD_RELEASE_SINCE_VERSION)
                wl_keyboard_release(keyboard_);
            else
                wl_keyboard_destroy(keyboard_);
            keyboard_ = null;
            keyboardFocus_ = null;
        }
        if (seat_ !is null)
        {
            if (seatVersion_ >= WL_SEAT_RELEASE_SINCE_VERSION)
                wl_seat_release(seat_);
            else
                wl_seat_destroy(seat_);
            seat_ = null;
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
        foreach (ref output; outputs_)
            if (output.output !is null)
            {
                wl_output_destroy(output.output);
                output = Output.init;
            }
        if (wmBase_ !is null)
        {
            xdg_wm_base_destroy(wmBase_);
            wmBase_ = null;
        }
        if (compositor_ !is null)
        {
            wl_proxy_destroy(cast(wl_proxy*) compositor_);
            compositor_ = null;
        }
        if (registry_ !is null)
        {
            wl_proxy_destroy(cast(wl_proxy*) registry_);
            registry_ = null;
        }
        if (display_ !is null)
        {
            wl_display_disconnect(display_);
            display_ = null;
        }
    }

    private static void destroyNative(ref Slot slot) nothrow @nogc
    {
        if (slot.frameCallback !is null)
            wl_callback_destroy(slot.frameCallback);
        if (slot.toplevel !is null)
            xdg_toplevel_destroy(slot.toplevel);
        if (slot.xdgSurface !is null)
            xdg_surface_destroy(slot.xdgSurface);
        if (slot.surface !is null)
            wl_surface_destroy(slot.surface);
        const generation = slot.generation;
        slot = Slot.init;
        slot.generation = generation;
    }

    private WsiResult!size_t checkedSlot(WindowId id,
        WsiOperation operation)
    {
        auto owner = requireOwner!size_t(operation);
        if (owner.hasError)
            return owner;
        if (!id.valid || id.slot > maxWindows)
            return waylandFailure!size_t(operation, 0,
                "invalid Wayland window id", WsiErrorKind.staleId);
        size_t index = cast(size_t) id.slot - 1;
        const slot = windows_[index];
        if (!slot.live || slot.generation != id.generation)
            return waylandFailure!size_t(operation, 0,
                "stale Wayland window id", WsiErrorKind.staleId);
        return wsiOk(index);
    }

    private WindowId idAt(size_t index) const pure nothrow @nogc
        => WindowId(cast(uint) index + 1, windows_[index].generation);

    private size_t indexOfSlot(const Slot* slot) const pure nothrow @nogc
    {
        foreach (i; 0 .. windows_.length)
            if (&windows_[i] is slot)
                return i;
        return size_t.max;
    }

    private size_t indexOfSurface(const wl_surface* surface)
        const pure nothrow @nogc
    {
        if (surface is null)
            return size_t.max;
        foreach (i, const ref slot; windows_)
            if (slot.live && slot.surface is surface)
                return i;
        return size_t.max;
    }

    private WsiResult!T requireOwner(T)(WsiOperation operation)
    {
        if (!open_ && !closed_)
            return waylandFailure!T(operation, 0,
                "Wayland WSI is not open", WsiErrorKind.closed);
        if (pthread_equal(ownerThread_, pthread_self()) == 0)
            return waylandFailure!T(operation, 0,
                "Wayland WSI called from a non-owner thread",
                WsiErrorKind.wrongThread);
        static if (is(T == void))
            return wsiOk();
        else
            return wsiOk(T.init);
    }

    // Fire-and-forget by design: a full queue lands in the sticky error,
    // which the next fallible operation reports.
    private void emit(Payload)(WindowId id, Payload payload) nothrow @nogc
    {
        auto result = events_.push(WindowEvent(nextSequence_, id,
            WindowEventPayload(payload)));
        if (result.hasError)
        {
            remember(result.error);
            return;
        }
        ++nextSequence_;
    }

    private WsiResult!void connectionFailure(WsiOperation operation,
        scope const(char)[] diagnostic) nothrow @nogc
    {
        const displayCode = display_ is null ? 0
            : wl_display_get_error(display_);
        const code = displayCode != 0 ? displayCode : errno;
        return waylandFailure!void(operation, code, diagnostic);
    }

    private void rememberConnectionFailure(WsiOperation operation,
        scope const(char)[] diagnostic) nothrow @nogc
    {
        auto failed = connectionFailure(operation, diagnostic);
        remember(failed.error);
    }

    private void remember(WsiError error) nothrow @nogc
    {
        if (!hasStickyError_)
        {
            error.backend = BackendKind.wayland;
            stickyError_ = error;
            hasStickyError_ = true;
        }
    }

    private extern (C) static void onRegistryGlobal(void* data,
        wl_registry* registry, uint name, const(char)* interfaceName,
        uint advertisedVersion) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        if (strcmp(interfaceName, wl_compositor_interface.name) == 0
            && owner.compositor_ is null)
        {
            const version_ = advertisedVersion < 4 ? advertisedVersion : 4;
            owner.compositor_ = cast(wl_compositor*)
                wl_registry_bind(registry, name,
                    &wl_compositor_interface, version_);
        }
        else if (strcmp(interfaceName, xdg_wm_base_interface.name) == 0
            && owner.wmBase_ is null)
        {
            owner.wmBase_ = cast(xdg_wm_base*) wl_registry_bind(
                registry, name, &xdg_wm_base_interface, 1);
            if (owner.wmBase_ !is null
                && xdg_wm_base_add_listener(owner.wmBase_,
                    listenerPtr(wmBaseListener), owner) != 0)
                owner.remember(wsiError(WsiErrorKind.nativeFailure,
                    WsiOperation.open, BackendKind.wayland, 0,
                    "failed to install xdg_wm_base listener"));
        }
        else if (strcmp(interfaceName,
            wp_cursor_shape_manager_v1_interface.name) == 0
            && owner.cursorShapeManager_ is null)
        {
            owner.cursorShapeManager_ = cast(wp_cursor_shape_manager_v1*)
                wl_registry_bind(registry, name,
                    &wp_cursor_shape_manager_v1_interface, 1);
            if (owner.pointer_ !is null
                && owner.cursorShapeManager_ !is null
                && owner.cursorShapeDevice_ is null)
                owner.cursorShapeDevice_ =
                    wp_cursor_shape_manager_v1_get_pointer(
                        owner.cursorShapeManager_, owner.pointer_);
        }
        else if (strcmp(interfaceName, wl_output_interface.name) == 0)
        {
            foreach (ref slot; owner.outputs_)
            {
                if (slot.output !is null)
                    continue;
                const version_ = advertisedVersion < 2
                    ? advertisedVersion : 2;
                slot.output = cast(wl_output*) wl_registry_bind(registry,
                    name, &wl_output_interface, version_);
                slot.registryName = name;
                slot.scale = 1;
                slot.pendingScale = 1;
                if (slot.output !is null
                    && wl_output_add_listener(slot.output,
                        listenerPtr(outputListener), owner) != 0)
                    owner.remember(wsiError(WsiErrorKind.nativeFailure,
                        WsiOperation.open, BackendKind.wayland, 0,
                        "failed to install wl_output listener"));
                break;
            }
        }
        else if (strcmp(interfaceName, wl_seat_interface.name) == 0
            && owner.seat_ is null)
        {
            const version_ = advertisedVersion < 5 ? advertisedVersion : 5;
            owner.seat_ = cast(wl_seat*) wl_registry_bind(
                registry, name, &wl_seat_interface, version_);
            owner.seatVersion_ = version_;
            if (owner.seat_ !is null
                && wl_seat_add_listener(owner.seat_,
                    listenerPtr(seatListener), owner) != 0)
                owner.remember(wsiError(WsiErrorKind.nativeFailure,
                    WsiOperation.open, BackendKind.wayland, 0,
                    "failed to install wl_seat listener"));
        }
    }

    private extern (C) static void onRegistryGlobalRemove(void* data,
        wl_registry*, uint name) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        foreach (i, ref slot; owner.outputs_)
        {
            if (slot.output is null || slot.registryName != name)
                continue;
            wl_output_destroy(slot.output);
            slot = Output.init;
            foreach (windowIndex, ref window; owner.windows_)
                if (window.live && (window.enteredOutputs & (1 << i)) != 0)
                {
                    window.enteredOutputs &= ~cast(ubyte)(1 << i);
                    owner.refreshWindowScale(windowIndex);
                }
            break;
        }
    }

    private extern (C) static void onOutputGeometry(void*, wl_output*, int,
        int, int, int, int, const(char)*, const(char)*, int) nothrow @nogc
    {
    }

    private extern (C) static void onOutputMode(void*, wl_output*, uint,
        int, int, int) nothrow @nogc
    {
    }

    private extern (C) static void onOutputScale(void* data,
        wl_output* output, int factor) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        foreach (ref slot; owner.outputs_)
            if (slot.output is output)
            {
                slot.pendingScale = factor > 0 ? factor : 1;
                break;
            }
    }

    private extern (C) static void onOutputDone(void* data,
        wl_output* output) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        foreach (i, ref slot; owner.outputs_)
            if (slot.output is output)
            {
                if (slot.scale != slot.pendingScale)
                {
                    slot.scale = slot.pendingScale;
                    foreach (windowIndex, ref window; owner.windows_)
                        if (window.live
                            && (window.enteredOutputs & (1 << i)) != 0)
                            owner.refreshWindowScale(windowIndex);
                }
                break;
            }
    }

    private extern (C) static void onOutputName(void*, wl_output*,
        const(char)*) nothrow @nogc
    {
    }

    private extern (C) static void onOutputDescription(void*, wl_output*,
        const(char)*) nothrow @nogc
    {
    }

    private extern (C) static void onSurfaceEnter(void* data,
        wl_surface*, wl_output* output) nothrow @nogc
    {
        auto slot = cast(Slot*) data;
        slot.owner.trackSurfaceOutput(slot, output, true);
    }

    private extern (C) static void onSurfaceLeave(void* data,
        wl_surface*, wl_output* output) nothrow @nogc
    {
        auto slot = cast(Slot*) data;
        slot.owner.trackSurfaceOutput(slot, output, false);
    }

    private extern (C) static void onSurfacePreferredBufferScale(void*,
        wl_surface*, int) nothrow @nogc
    {
    }

    private extern (C) static void onSurfacePreferredBufferTransform(void*,
        wl_surface*, uint) nothrow @nogc
    {
    }

    private void trackSurfaceOutput(Slot* slot, wl_output* output,
        bool entered) nothrow @nogc
    {
        const windowIndex = indexOfSlot(slot);
        if (windowIndex == size_t.max)
            return;
        foreach (i, ref candidate; outputs_)
        {
            if (candidate.output !is output)
                continue;
            const bit = cast(ubyte)(1 << i);
            if (entered)
                slot.enteredOutputs |= bit;
            else
                slot.enteredOutputs &= ~bit;
            emit(idAt(windowIndex), OutputEnteredEvent(
                OutputId(cast(uint) i + 1, 1), entered));
            refreshWindowScale(windowIndex);
            return;
        }
    }

    /*
    The window's scale is the maximum of its entered outputs (the common
    sharpness-first policy). A change re-derives the physical size from the
    logical one, requests the matching buffer scale, and reports one atomic
    metrics transition.
    */
    private void refreshWindowScale(size_t windowIndex) nothrow @nogc
    {
        ref slot = windows_[windowIndex];
        int scale = 1;
        foreach (i, const ref output; outputs_)
            if ((slot.enteredOutputs & (1 << i)) != 0
                && output.output !is null && output.scale > scale)
                scale = output.scale;
        if (scale == slot.scale)
            return;
        slot.scale = scale;
        if (slot.surface !is null)
            wl_surface_set_buffer_scale(slot.surface, scale);
        const metrics = metricsFor(slot, slot.metrics.logicalSize);
        if (slot.ready && metrics != slot.metrics)
            emit(idAt(windowIndex), SurfaceMetricsChangedEvent(metrics));
        slot.metrics = metrics;
    }

    private static SurfaceMetrics metricsFor(ref const Slot slot,
        LogicalSize logical) nothrow @nogc
        => SurfaceMetrics(logical,
            PhysicalSize(cast(int)(logical.width * slot.scale),
                cast(int)(logical.height * slot.scale)),
            ScaleFactor(slot.scale));

    private extern (C) static void onSeatCapabilities(void* data,
        wl_seat* seat, uint capabilities) nothrow @nogc
    {
        enum pointerCapability = 1;
        enum keyboardCapability = 2;
        auto owner = cast(WaylandWsi*) data;
        const hasPointer = (capabilities & pointerCapability) != 0;
        if (hasPointer && owner.pointer_ is null)
        {
            owner.pointer_ = wl_seat_get_pointer(seat);
            if (owner.pointer_ !is null
                && wl_pointer_add_listener(owner.pointer_,
                    listenerPtr(pointerListener), owner) != 0)
                owner.remember(wsiError(WsiErrorKind.nativeFailure,
                    WsiOperation.dispatch, BackendKind.wayland, 0,
                    "failed to install wl_pointer listener"));
            if (owner.pointer_ !is null
                && owner.cursorShapeManager_ !is null)
                owner.cursorShapeDevice_ =
                    wp_cursor_shape_manager_v1_get_pointer(
                        owner.cursorShapeManager_, owner.pointer_);
        }
        else if (!hasPointer && owner.pointer_ !is null)
        {
            owner.releasePointer();
        }
        const hasKeyboard = (capabilities & keyboardCapability) != 0;
        if (hasKeyboard && owner.keyboard_ is null)
        {
            owner.keyboard_ = wl_seat_get_keyboard(seat);
            if (owner.keyboard_ !is null
                && wl_keyboard_add_listener(owner.keyboard_,
                    listenerPtr(keyboardListener), owner) != 0)
                owner.remember(wsiError(WsiErrorKind.nativeFailure,
                    WsiOperation.dispatch, BackendKind.wayland, 0,
                    "failed to install wl_keyboard listener"));
        }
        else if (!hasKeyboard && owner.keyboard_ !is null)
        {
            if (owner.seatVersion_ >= WL_KEYBOARD_RELEASE_SINCE_VERSION)
                wl_keyboard_release(owner.keyboard_);
            else
                wl_keyboard_destroy(owner.keyboard_);
            owner.keyboard_ = null;
            owner.keyboardFocus_ = null;
            owner.keyboardMods_ = Mods();
        }
    }

    private extern (C) static void onSeatName(void*, wl_seat*,
        const(char)*) nothrow @nogc
    {
    }

    // The keymap fd must be consumed; mapping it through xkbcommon is the
    // logical-key slice, so until then close it immediately.
    /**
    Stores the window's standard cursor shape and applies it while the
    pointer is inside. Server-side shapes come from cursor-shape-v1; a
    compositor without that global reports typed `unsupported`. Custom
    images and cursor themes are a later slice.
    */
    WsiResult!void setCursor(WindowId id, PointerShape shape)
    {
        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        if (cursorShapeManager_ is null)
            return waylandFailure!void(WsiOperation.command, 0,
                "compositor lacks wp_cursor_shape_manager_v1",
                WsiErrorKind.unsupported);
        ref slot = windows_[checked.value];
        slot.cursorShape = shape;
        auto paused = pausePoll();
        if (paused.hasError)
            return paused;
        applyCursor(slot);
        return prepareAndArm();
    }

    /// Visibility uses the core null-surface cursor, so it works with or
    /// without the shape protocol.
    WsiResult!void setCursorVisible(WindowId id, bool visible)
    {
        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        ref slot = windows_[checked.value];
        slot.cursorVisible = visible;
        auto paused = pausePoll();
        if (paused.hasError)
            return paused;
        applyCursor(slot);
        return prepareAndArm();
    }

    private void applyCursor(ref Slot slot) nothrow @nogc
    {
        if (pointer_ is null || pointerEnterSerial_ == 0
            || pointerFocus_ !is slot.surface)
            return;
        if (!slot.cursorVisible)
        {
            wl_pointer_set_cursor(pointer_, pointerEnterSerial_, null, 0, 0);
            return;
        }
        if (cursorShapeDevice_ !is null)
            wp_cursor_shape_device_v1_set_shape(cursorShapeDevice_,
                pointerEnterSerial_, cursorShapeFor(slot.cursorShape));
    }

    /// The shared shape names are CSS cursor names, as is cursor-shape-v1.
    package static uint cursorShapeFor(PointerShape shape)
        @safe pure nothrow @nogc
    {
        final switch (shape)
        {
            case PointerShape.default_:
                return WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT;
            case PointerShape.text:
                return WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_TEXT;
            case PointerShape.pointer:
                return WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_POINTER;
            case PointerShape.ewResize:
                return WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_EW_RESIZE;
            case PointerShape.nsResize:
                return WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NS_RESIZE;
            case PointerShape.grab:
                return WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_GRAB;
            case PointerShape.grabbing:
                return WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_GRABBING;
        }
    }

    private void releasePointer() nothrow @nogc
    {
        if (pointer_ is null)
            return;
        if (cursorShapeDevice_ !is null)
        {
            wp_cursor_shape_device_v1_destroy(cursorShapeDevice_);
            cursorShapeDevice_ = null;
        }
        if (seatVersion_ >= WL_POINTER_RELEASE_SINCE_VERSION)
            wl_pointer_release(pointer_);
        else
            wl_pointer_destroy(pointer_);
        pointer_ = null;
        pointerFocus_ = null;
    }

    /// The seat exposes one pointer.
    private enum seatPointer = PointerId(1, 1);

    private void emitPointer(PointerPhase phase,
        PointerButton button = PointerButton.none) nothrow @nogc
    {
        const index = indexOfSurface(pointerFocus_);
        if (index == size_t.max)
            return;
        PointerEvent event;
        event.pointer = seatPointer;
        event.phase = phase;
        event.button = button;
        event.logicalPosition = pointerPosition_;
        event.physicalPosition = PhysicalPosition(
            cast(int) pointerPosition_.x, cast(int) pointerPosition_.y);
        event.modifiers = keyboardMods_;
        emit(idAt(index), event);
    }

    private extern (C) static void onPointerEnter(void* data,
        wl_pointer*, uint serial, wl_surface* surface, wl_fixed_t sx,
        wl_fixed_t sy) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        owner.pointerEnterSerial_ = serial;
        owner.pointerFocus_ = surface;
        owner.pointerPosition_ =
            LogicalPosition(wl_fixed_to_double(sx), wl_fixed_to_double(sy));
        owner.emitPointer(PointerPhase.entered);
        // The compositor resets the cursor on every enter; re-apply the
        // focused window's stored shape and visibility.
        const index = owner.indexOfSurface(surface);
        if (index != size_t.max)
            owner.applyCursor(owner.windows_[index]);
    }

    private extern (C) static void onPointerLeave(void* data, wl_pointer*,
        uint, wl_surface* surface) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        owner.emitPointer(PointerPhase.left);
        if (owner.pointerFocus_ is surface)
            owner.pointerFocus_ = null;
    }

    private extern (C) static void onPointerMotion(void* data, wl_pointer*,
        uint, wl_fixed_t sx, wl_fixed_t sy) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        owner.pointerPosition_ =
            LogicalPosition(wl_fixed_to_double(sx), wl_fixed_to_double(sy));
        owner.emitPointer(PointerPhase.moved);
    }

    private extern (C) static void onPointerButton(void* data, wl_pointer*,
        uint, uint, uint button, uint state) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        owner.emitPointer(state != 0
            ? PointerPhase.pressed : PointerPhase.released,
            waylandPointerButton(button));
    }

    private extern (C) static void onPointerAxis(void* data, wl_pointer*,
        uint, uint axis, wl_fixed_t value) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        const amount = wl_fixed_to_double(value);
        if (axis == 0)
            owner.pendingScrollDy_ += amount;
        else
            owner.pendingScrollDx_ += amount;
        owner.pendingScroll_ = true;
    }

    private extern (C) static void onPointerAxisSource(void* data,
        wl_pointer*, uint source) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        switch (source)
        {
            case 0: owner.pendingScrollSource_ = ScrollSource.wheel; break;
            case 1: owner.pendingScrollSource_ = ScrollSource.finger; break;
            case 2:
                owner.pendingScrollSource_ = ScrollSource.continuous;
                break;
            default: owner.pendingScrollSource_ = ScrollSource.wheel; break;
        }
    }

    private extern (C) static void onPointerAxisStop(void*, wl_pointer*,
        uint, uint) nothrow @nogc
    {
    }

    private extern (C) static void onPointerAxisDiscrete(void* data,
        wl_pointer*, uint axis, int discrete) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        if (axis == 0)
            owner.pendingDiscreteY_ += discrete;
        else
            owner.pendingDiscreteX_ += discrete;
        owner.pendingScroll_ = true;
    }

    private extern (C) static void onPointerAxisValue120(void*, wl_pointer*,
        uint, int) nothrow @nogc
    {
    }

    private extern (C) static void onPointerAxisRelativeDirection(void*,
        wl_pointer*, uint, uint) nothrow @nogc
    {
    }

    private extern (C) static void onPointerWarp(void*, wl_pointer*,
        wl_fixed_t, wl_fixed_t) nothrow @nogc
    {
    }

    // Axis events accumulate within one frame; the frame boundary flushes a
    // single ScrollEvent so a diagonal two-axis frame stays one gesture.
    private extern (C) static void onPointerFrame(void* data,
        wl_pointer*) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        if (!owner.pendingScroll_)
            return;
        const index = owner.indexOfSurface(owner.pointerFocus_);
        if (index != size_t.max)
        {
            ScrollEvent scroll;
            scroll.logicalPosition = owner.pointerPosition_;
            scroll.physicalPosition = PhysicalPosition(
                cast(int) owner.pointerPosition_.x,
                cast(int) owner.pointerPosition_.y);
            scroll.dx = owner.pendingScrollDx_;
            scroll.dy = owner.pendingScrollDy_;
            scroll.discreteX = owner.pendingDiscreteX_;
            scroll.discreteY = owner.pendingDiscreteY_;
            scroll.source = owner.pendingScrollSource_ == ScrollSource.unknown
                ? ScrollSource.wheel : owner.pendingScrollSource_;
            scroll.unit = ScrollUnit.logical;
            scroll.modifiers = owner.keyboardMods_;
            owner.emit(owner.idAt(index), scroll);
        }
        owner.pendingScrollDx_ = 0;
        owner.pendingScrollDy_ = 0;
        owner.pendingDiscreteX_ = 0;
        owner.pendingDiscreteY_ = 0;
        owner.pendingScrollSource_ = ScrollSource.unknown;
        owner.pendingScroll_ = false;
    }

    /// evdev button codes: BTN_LEFT through BTN_EXTRA.
    package static PointerButton waylandPointerButton(uint button)
        @safe pure nothrow @nogc
    {
        switch (button)
        {
            case 0x110: return PointerButton.left;
            case 0x111: return PointerButton.right;
            case 0x112: return PointerButton.middle;
            case 0x113: return PointerButton.back;
            case 0x114: return PointerButton.forward;
            default: return PointerButton.none;
        }
    }

    // The compositor's keymap becomes the xkbcommon layout behind logical
    // keys. Best-effort: a failed compile leaves logical identity unknown
    // while physical identity keeps flowing. The fd is always consumed.
    private extern (C) static void onKeyboardKeymap(void* data, wl_keyboard*,
        uint format, int fd, uint size) nothrow @nogc
    {
        if (fd < 0)
            return;
        auto owner = cast(WaylandWsi*) data;
        enum xkbV1Format = 1; // WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1
        if (format == xkbV1Format && size > 0)
        {
            auto mapped = mmap(null, size, PROT_READ, MAP_PRIVATE, fd, 0);
            if (mapped !is MAP_FAILED)
            {
                owner.replaceKeymap(cast(const(char)*) mapped);
                munmap(mapped, size);
            }
        }
        posixClose(fd);
    }

    private void replaceKeymap(const(char)* text) nothrow @nogc
    {
        if (xkbContext_ is null)
            xkbContext_ = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
        if (xkbContext_ is null)
            return;
        auto keymap = xkb_keymap_new_from_string(xkbContext_, text,
            XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
        if (keymap is null)
            return;
        auto state = xkb_state_new(keymap);
        if (state is null)
        {
            xkb_keymap_unref(keymap);
            return;
        }
        if (xkbState_ !is null)
            xkb_state_unref(xkbState_);
        if (xkbKeymap_ !is null)
            xkb_keymap_unref(xkbKeymap_);
        xkbKeymap_ = keymap;
        xkbState_ = state;
    }

    /// Unshifted base-level identity under the current layout; Wayland key
    /// codes are evdev, and xkb keycodes are evdev + 8.
    private LogicalKey logicalForKey(uint key) nothrow @nogc
    {
        if (xkbKeymap_ is null || xkbState_ is null)
            return LogicalKey.init;
        const keycode = key + 8;
        const layout = xkb_state_key_get_layout(xkbState_, keycode);
        const(uint)* keysyms;
        const count = xkb_keymap_key_get_syms_by_level(xkbKeymap_, keycode,
            layout, 0, &keysyms);
        if (count < 1)
            return LogicalKey.init;
        return logicalFromKeysym(keysyms[0],
            xkb_keysym_to_utf32(keysyms[0]));
    }

    private extern (C) static void onKeyboardEnter(void* data,
        wl_keyboard*, uint, wl_surface* surface, wl_array*) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        owner.keyboardFocus_ = surface;
        const index = owner.indexOfSurface(surface);
        if (index != size_t.max)
            owner.emit(owner.idAt(index), FocusChangedEvent(true));
    }

    private extern (C) static void onKeyboardLeave(void* data,
        wl_keyboard*, uint, wl_surface* surface) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        if (owner.keyboardFocus_ is surface)
            owner.keyboardFocus_ = null;
        const index = owner.indexOfSurface(surface);
        if (index != size_t.max)
            owner.emit(owner.idAt(index), FocusChangedEvent(false));
    }

    private extern (C) static void onKeyboardKey(void* data, wl_keyboard*,
        uint, uint, uint key, uint state) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        const index = owner.indexOfSurface(owner.keyboardFocus_);
        if (index == size_t.max)
            return;
        KeyboardEvent event;
        event.physical = PhysicalKey(key, 0);
        event.logical = owner.logicalForKey(key);
        event.location = evdevKeyLocation(key);
        event.action = state != 0 ? KeyAction.press : KeyAction.release;
        event.modifiers = owner.keyboardMods_;
        owner.emit(owner.idAt(index), event);
    }

    private extern (C) static void onKeyboardModifiers(void* data,
        wl_keyboard*, uint, uint depressed, uint latched, uint locked,
        uint group) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        owner.keyboardMods_ = xkbRealMods(depressed | latched);
        if (owner.xkbState_ !is null)
            xkb_state_update_mask(owner.xkbState_, depressed, latched,
                locked, 0, 0, group);
    }

    private extern (C) static void onKeyboardRepeatInfo(void* data,
        wl_keyboard*, int rate, int delay) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        owner.keyRepeatRate_ = rate;
        owner.keyRepeatDelayMs_ = delay;
    }

    private extern (C) static void onBootstrapDone(void* data,
        wl_callback* callback, uint) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        wl_callback_destroy(callback);
        owner.bootstrapSync_ = null;
        owner.bootstrapComplete_ = true;
    }

    private extern (C) static void onWmBasePing(void*, xdg_wm_base* base,
        uint serial) nothrow @nogc
    {
        // This synchronous protocol reply is the only work performed inside
        // the native callback; application code remains deferred to drain().
        xdg_wm_base_pong(base, serial);
    }

    private extern (C) static void onXdgSurfaceConfigure(void* data,
        xdg_surface* surface, uint serial) nothrow @nogc
    {
        auto slot = cast(Slot*) data;
        auto owner = slot.owner;

        // The resize handoff's load-bearing rule: acknowledge before event
        // allocation, renderer notification, or any potentially deferred work.
        xdg_surface_ack_configure(surface, serial);

        const width = slot.pendingWidth > 0
            ? cast(uint) slot.pendingWidth
            : cast(uint) slot.requestedSize.width;
        const height = slot.pendingHeight > 0
            ? cast(uint) slot.pendingHeight
            : cast(uint) slot.requestedSize.height;
        const metrics = metricsFor(*slot, LogicalSize(width, height));
        const index = owner.indexOfSlot(slot);
        if (index == size_t.max)
            return;
        const id = owner.idAt(index);

        if (!slot.ready)
        {
            slot.ready = true;
            slot.metrics = metrics;
            owner.emit(id, ReadyEvent(metrics));
            owner.emit(id, ExposedEvent());
            // Initial configure is the renderer's opportunity to make its
            // first buffer commit; later cadence comes from frame callbacks.
            owner.emit(id,
                FrameReadyEvent(owner.nextFrameToken_++, 0));
            owner.armFrameCallback(*slot);
        }
        else
        {
            if (metrics != slot.metrics)
                owner.emit(id,
                    SurfaceMetricsChangedEvent(metrics));
            slot.metrics = metrics;
            owner.emit(id, ExposedEvent());
        }
    }

    private extern (C) static void onToplevelConfigure(void* data,
        xdg_toplevel*, int width, int height, wl_array*) nothrow @nogc
    {
        auto slot = cast(Slot*) data;
        slot.pendingWidth = width;
        slot.pendingHeight = height;
    }

    private extern (C) static void onToplevelClose(void* data,
        xdg_toplevel*) nothrow @nogc
    {
        auto slot = cast(Slot*) data;
        auto owner = slot.owner;
        const index = owner.indexOfSlot(slot);
        if (index != size_t.max)
            owner.emit(owner.idAt(index), CloseRequestedEvent());
    }

    private extern (C) static void onToplevelConfigureBounds(void*,
        xdg_toplevel*, int, int) nothrow @nogc
    {
    }

    private extern (C) static void onToplevelWmCapabilities(void*,
        xdg_toplevel*, wl_array*) nothrow @nogc
    {
    }

    private extern (C) static void onFrameDone(void* data,
        wl_callback* callback, uint) nothrow @nogc
    {
        auto slot = cast(Slot*) data;
        auto owner = slot.owner;
        wl_callback_destroy(callback);
        slot.frameCallback = null;
        const index = owner.indexOfSlot(slot);
        if (index == size_t.max || !slot.live)
            return;
        owner.emit(owner.idAt(index), FrameReadyEvent(
            owner.nextFrameToken_++, 0));
        owner.armFrameCallback(*slot);
    }

    private void armFrameCallback(ref Slot slot) nothrow @nogc
    {
        if (!slot.live || slot.surface is null
            || slot.frameCallback !is null)
            return;
        slot.frameCallback = wl_surface_frame(slot.surface);
        if (slot.frameCallback is null
            || wl_callback_add_listener(slot.frameCallback,
                listenerPtr(frameListener), &slot) != 0)
        {
            if (slot.frameCallback !is null)
                wl_callback_destroy(slot.frameCallback);
            slot.frameCallback = null;
            remember(wsiError(WsiErrorKind.nativeFailure,
                WsiOperation.dispatch, BackendKind.wayland, 0,
                "failed to arm wl_surface.frame callback"));
        }
    }
}

private immutable wl_registry_listener registryListener = {
    &WaylandWsi.onRegistryGlobal, &WaylandWsi.onRegistryGlobalRemove
};
private immutable wl_callback_listener bootstrapListener = {
    &WaylandWsi.onBootstrapDone
};
private immutable xdg_wm_base_listener wmBaseListener = {
    &WaylandWsi.onWmBasePing
};
private immutable xdg_surface_listener xdgSurfaceListener = {
    &WaylandWsi.onXdgSurfaceConfigure
};
private immutable xdg_toplevel_listener toplevelListener = {
    &WaylandWsi.onToplevelConfigure, &WaylandWsi.onToplevelClose,
    &WaylandWsi.onToplevelConfigureBounds,
    &WaylandWsi.onToplevelWmCapabilities
};
private immutable wl_callback_listener frameListener = {
    &WaylandWsi.onFrameDone
};
private immutable wl_seat_listener seatListener = {
    &WaylandWsi.onSeatCapabilities, &WaylandWsi.onSeatName
};
private immutable wl_output_listener outputListener = {
    &WaylandWsi.onOutputGeometry, &WaylandWsi.onOutputMode,
    &WaylandWsi.onOutputDone, &WaylandWsi.onOutputScale,
    &WaylandWsi.onOutputName, &WaylandWsi.onOutputDescription
};
private immutable wl_surface_listener surfaceListener = {
    &WaylandWsi.onSurfaceEnter, &WaylandWsi.onSurfaceLeave,
    &WaylandWsi.onSurfacePreferredBufferScale,
    &WaylandWsi.onSurfacePreferredBufferTransform
};
private immutable wl_pointer_listener pointerListener = {
    &WaylandWsi.onPointerEnter, &WaylandWsi.onPointerLeave,
    &WaylandWsi.onPointerMotion, &WaylandWsi.onPointerButton,
    &WaylandWsi.onPointerAxis, &WaylandWsi.onPointerFrame,
    &WaylandWsi.onPointerAxisSource, &WaylandWsi.onPointerAxisStop,
    &WaylandWsi.onPointerAxisDiscrete, &WaylandWsi.onPointerAxisValue120,
    &WaylandWsi.onPointerAxisRelativeDirection, &WaylandWsi.onPointerWarp
};
private immutable wl_keyboard_listener keyboardListener = {
    &WaylandWsi.onKeyboardKeymap, &WaylandWsi.onKeyboardEnter,
    &WaylandWsi.onKeyboardLeave, &WaylandWsi.onKeyboardKey,
    &WaylandWsi.onKeyboardModifiers, &WaylandWsi.onKeyboardRepeatInfo
};

private WsiResult!T waylandFailure(T)(WsiOperation operation,
    long nativeCode, scope const(char)[] diagnostic,
    WsiErrorKind kind = WsiErrorKind.nativeFailure) nothrow @nogc
{
    return wsiErr!T(wsiError(kind, operation, BackendKind.wayland,
        nativeCode, diagnostic));
}

/*
ImportC interop: dmd does not emit a C header's `static inline` helpers for
use from another module ("statics defined in one module cannot be referenced
from another"), so every protocol request wrapper this module needs is
transcribed below in D, verbatim from the generating headers, over the
exported `wl_proxy_*` ABI. The request opcodes (`WL_DISPLAY_SYNC`, ...) are
the headers' own macros, which ImportC does export, and module-scope
definitions shadow the imported C declarations, so call sites stay identical
and ldc2 and dmd compile the same code. The C names are kept on purpose;
keep each body a faithful transcription.
*/

private alias ListenerImpl = Parameters!wl_proxy_add_listener[1];

private wl_callback* wl_display_sync()(wl_display* self)
    => cast(wl_callback*) wl_proxy_marshal_flags(cast(wl_proxy*) self,
        WL_DISPLAY_SYNC, &wl_callback_interface,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, cast(void*) null);

private wl_registry* wl_display_get_registry()(wl_display* self)
    => cast(wl_registry*) wl_proxy_marshal_flags(cast(wl_proxy*) self,
        WL_DISPLAY_GET_REGISTRY, &wl_registry_interface,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, cast(void*) null);

private int wl_registry_add_listener()(wl_registry* self,
        const(wl_registry_listener)* listener, void* data)
    => wl_proxy_add_listener(cast(wl_proxy*) self,
        cast(ListenerImpl) listener, data);

private void* wl_registry_bind()(wl_registry* self, uint name,
        const(wl_interface)* iface, uint ver)
    // ImportC drops the C signature's `const`, so un-const the borrowed
    // interface table the same way `listenerPtr` does.
    => cast(void*) wl_proxy_marshal_flags(cast(wl_proxy*) self,
        WL_REGISTRY_BIND, cast(wl_interface*) iface, ver, 0, name,
        iface.name, ver, cast(void*) null);

private int wl_callback_add_listener()(wl_callback* self,
        const(wl_callback_listener)* listener, void* data)
    => wl_proxy_add_listener(cast(wl_proxy*) self,
        cast(ListenerImpl) listener, data);

private void wl_callback_destroy()(wl_callback* self)
    => wl_proxy_destroy(cast(wl_proxy*) self);

private wl_surface* wl_compositor_create_surface()(wl_compositor* self)
    => cast(wl_surface*) wl_proxy_marshal_flags(cast(wl_proxy*) self,
        WL_COMPOSITOR_CREATE_SURFACE, &wl_surface_interface,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, cast(void*) null);

private int wl_surface_add_listener()(wl_surface* self,
        const(wl_surface_listener)* listener, void* data)
    => wl_proxy_add_listener(cast(wl_proxy*) self,
        cast(ListenerImpl) listener, data);

private void wl_surface_commit()(wl_surface* self)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, WL_SURFACE_COMMIT, null,
        wl_proxy_get_version(cast(wl_proxy*) self), 0);
}

private void wl_surface_destroy()(wl_surface* self)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, WL_SURFACE_DESTROY, null,
        wl_proxy_get_version(cast(wl_proxy*) self), WL_MARSHAL_FLAG_DESTROY);
}

private wl_callback* wl_surface_frame()(wl_surface* self)
    => cast(wl_callback*) wl_proxy_marshal_flags(cast(wl_proxy*) self,
        WL_SURFACE_FRAME, &wl_callback_interface,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, cast(void*) null);

private void wl_surface_set_buffer_scale()(wl_surface* self, int scale)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, WL_SURFACE_SET_BUFFER_SCALE, null,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, scale);
}

private int wl_seat_add_listener()(wl_seat* self,
        const(wl_seat_listener)* listener, void* data)
    => wl_proxy_add_listener(cast(wl_proxy*) self,
        cast(ListenerImpl) listener, data);

private wl_keyboard* wl_seat_get_keyboard()(wl_seat* self)
    => cast(wl_keyboard*) wl_proxy_marshal_flags(cast(wl_proxy*) self,
        WL_SEAT_GET_KEYBOARD, &wl_keyboard_interface,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, cast(void*) null);

private wl_pointer* wl_seat_get_pointer()(wl_seat* self)
    => cast(wl_pointer*) wl_proxy_marshal_flags(cast(wl_proxy*) self,
        WL_SEAT_GET_POINTER, &wl_pointer_interface,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, cast(void*) null);

private void wl_seat_release()(wl_seat* self)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, WL_SEAT_RELEASE, null,
        wl_proxy_get_version(cast(wl_proxy*) self), WL_MARSHAL_FLAG_DESTROY);
}

private void wl_seat_destroy()(wl_seat* self)
    => wl_proxy_destroy(cast(wl_proxy*) self);

private int wl_keyboard_add_listener()(wl_keyboard* self,
        const(wl_keyboard_listener)* listener, void* data)
    => wl_proxy_add_listener(cast(wl_proxy*) self,
        cast(ListenerImpl) listener, data);

private void wl_keyboard_destroy()(wl_keyboard* self)
    => wl_proxy_destroy(cast(wl_proxy*) self);

private void wl_keyboard_release()(wl_keyboard* self)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, WL_KEYBOARD_RELEASE, null,
        wl_proxy_get_version(cast(wl_proxy*) self), WL_MARSHAL_FLAG_DESTROY);
}

private int wl_pointer_add_listener()(wl_pointer* self,
        const(wl_pointer_listener)* listener, void* data)
    => wl_proxy_add_listener(cast(wl_proxy*) self,
        cast(ListenerImpl) listener, data);

private void wl_pointer_destroy()(wl_pointer* self)
    => wl_proxy_destroy(cast(wl_proxy*) self);

private void wl_pointer_release()(wl_pointer* self)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, WL_POINTER_RELEASE, null,
        wl_proxy_get_version(cast(wl_proxy*) self), WL_MARSHAL_FLAG_DESTROY);
}

private void wl_pointer_set_cursor()(wl_pointer* self, uint serial, wl_surface* surface, int hotspotX, int hotspotY)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, WL_POINTER_SET_CURSOR, null,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, serial, surface, hotspotX, hotspotY);
}

private int wl_output_add_listener()(wl_output* self,
        const(wl_output_listener)* listener, void* data)
    => wl_proxy_add_listener(cast(wl_proxy*) self,
        cast(ListenerImpl) listener, data);

private void wl_output_destroy()(wl_output* self)
    => wl_proxy_destroy(cast(wl_proxy*) self);

private double wl_fixed_to_double()(wl_fixed_t f)
    => f / 256.0;

private int xdg_wm_base_add_listener()(xdg_wm_base* self,
        const(xdg_wm_base_listener)* listener, void* data)
    => wl_proxy_add_listener(cast(wl_proxy*) self,
        cast(ListenerImpl) listener, data);

private void xdg_wm_base_destroy()(xdg_wm_base* self)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, XDG_WM_BASE_DESTROY, null,
        wl_proxy_get_version(cast(wl_proxy*) self), WL_MARSHAL_FLAG_DESTROY);
}

private xdg_surface* xdg_wm_base_get_xdg_surface()(xdg_wm_base* self, wl_surface* surface)
    => cast(xdg_surface*) wl_proxy_marshal_flags(cast(wl_proxy*) self,
        XDG_WM_BASE_GET_XDG_SURFACE, &xdg_surface_interface,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, cast(void*) null,
        surface);

private void xdg_wm_base_pong()(xdg_wm_base* self, uint serial)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, XDG_WM_BASE_PONG, null,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, serial);
}

private int xdg_surface_add_listener()(xdg_surface* self,
        const(xdg_surface_listener)* listener, void* data)
    => wl_proxy_add_listener(cast(wl_proxy*) self,
        cast(ListenerImpl) listener, data);

private void xdg_surface_ack_configure()(xdg_surface* self, uint serial)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, XDG_SURFACE_ACK_CONFIGURE, null,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, serial);
}

private void xdg_surface_destroy()(xdg_surface* self)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, XDG_SURFACE_DESTROY, null,
        wl_proxy_get_version(cast(wl_proxy*) self), WL_MARSHAL_FLAG_DESTROY);
}

private xdg_toplevel* xdg_surface_get_toplevel()(xdg_surface* self)
    => cast(xdg_toplevel*) wl_proxy_marshal_flags(cast(wl_proxy*) self,
        XDG_SURFACE_GET_TOPLEVEL, &xdg_toplevel_interface,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, cast(void*) null);

private int xdg_toplevel_add_listener()(xdg_toplevel* self,
        const(xdg_toplevel_listener)* listener, void* data)
    => wl_proxy_add_listener(cast(wl_proxy*) self,
        cast(ListenerImpl) listener, data);

private void xdg_toplevel_destroy()(xdg_toplevel* self)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, XDG_TOPLEVEL_DESTROY, null,
        wl_proxy_get_version(cast(wl_proxy*) self), WL_MARSHAL_FLAG_DESTROY);
}

private void xdg_toplevel_set_app_id()(xdg_toplevel* self, const(char)* appId)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, XDG_TOPLEVEL_SET_APP_ID, null,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, appId);
}

private void xdg_toplevel_set_title()(xdg_toplevel* self, const(char)* title)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, XDG_TOPLEVEL_SET_TITLE, null,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, title);
}

private void xdg_toplevel_set_fullscreen()(xdg_toplevel* self, wl_output* output)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, XDG_TOPLEVEL_SET_FULLSCREEN, null,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, output);
}

private void xdg_toplevel_set_maximized()(xdg_toplevel* self)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, XDG_TOPLEVEL_SET_MAXIMIZED, null,
        wl_proxy_get_version(cast(wl_proxy*) self), 0);
}

private void xdg_toplevel_unset_maximized()(xdg_toplevel* self)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, XDG_TOPLEVEL_UNSET_MAXIMIZED, null,
        wl_proxy_get_version(cast(wl_proxy*) self), 0);
}

private void xdg_toplevel_set_max_size()(xdg_toplevel* self, int width, int height)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, XDG_TOPLEVEL_SET_MAX_SIZE, null,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, width, height);
}

private void xdg_toplevel_set_min_size()(xdg_toplevel* self, int width, int height)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, XDG_TOPLEVEL_SET_MIN_SIZE, null,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, width, height);
}

private wp_cursor_shape_device_v1* wp_cursor_shape_manager_v1_get_pointer()(wp_cursor_shape_manager_v1* self, wl_pointer* pointer)
    => cast(wp_cursor_shape_device_v1*) wl_proxy_marshal_flags(cast(wl_proxy*) self,
        WP_CURSOR_SHAPE_MANAGER_V1_GET_POINTER, &wp_cursor_shape_device_v1_interface,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, cast(void*) null,
        pointer);

private void wp_cursor_shape_manager_v1_destroy()(wp_cursor_shape_manager_v1* self)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, WP_CURSOR_SHAPE_MANAGER_V1_DESTROY, null,
        wl_proxy_get_version(cast(wl_proxy*) self), WL_MARSHAL_FLAG_DESTROY);
}

private void wp_cursor_shape_device_v1_set_shape()(wp_cursor_shape_device_v1* self, uint serial, uint shape)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, WP_CURSOR_SHAPE_DEVICE_V1_SET_SHAPE, null,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, serial, shape);
}

private void wp_cursor_shape_device_v1_destroy()(wp_cursor_shape_device_v1* self)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, WP_CURSOR_SHAPE_DEVICE_V1_DESTROY, null,
        wl_proxy_get_version(cast(wl_proxy*) self), WL_MARSHAL_FLAG_DESTROY);
}
