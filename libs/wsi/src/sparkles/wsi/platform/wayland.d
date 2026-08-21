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

import sparkles.base.text.utf8 : validateUtf8;
import sparkles.input.events : KeyAction, Mods;
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

    private extern (C) static void onRegistryGlobalRemove(void*,
        wl_registry*, uint) nothrow @nogc
    {
    }

    private extern (C) static void onSeatCapabilities(void* data,
        wl_seat* seat, uint capabilities) nothrow @nogc
    {
        enum keyboardCapability = 2;
        auto owner = cast(WaylandWsi*) data;
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
        const metrics = SurfaceMetrics(LogicalSize(width, height),
            PhysicalSize(width, height), ScaleFactor(1));
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
