/**
Native Wayland lifecycle integrated through Event Horizon's foreign-fd path.

The adapter owns one `wl_display`, never calls a blocking Wayland dispatch
function, acknowledges each `xdg_surface.configure` inside its listener, and
observes the mandatory `prepare_read`/`read_events|cancel_read` pairing.  The
renderer receives the `wl_surface` only after the initial configure.

The clipboard is the seat's `wl_data_device` selection. Its bytes move through
pipes that Event Horizon polls, one chunk per readiness, and listeners only
record what the compositor said: dispatch acts on it, so no sink is called
from inside libwayland.
*/
module sparkles.wsi.platform.wayland;

version (linux):

import core.atomic : atomicOp;
import core.stdc.errno : EAGAIN, EINTR, EPIPE, errno;
import core.sys.linux.unistd : pipe2;
import core.sys.posix.fcntl : F_GETFL, F_SETFL, O_CLOEXEC, O_NONBLOCK, fcntl;
import core.stdc.string : strcmp, strlen;
import core.sys.posix.pthread : pthread_equal, pthread_self, pthread_t;
import core.sys.posix.sys.mman : MAP_FAILED, MAP_PRIVATE, PROT_READ, mmap,
    munmap;
import core.sys.posix.unistd : getpid, posixClose = close, read, write;
import core.sys.linux.time : CLOCK_BOOTTIME, CLOCK_MONOTONIC_RAW;
import core.sys.posix.time : CLOCK_MONOTONIC, clock_gettime, timespec;
import core.time : Duration, MonoTime, msecs, nsecs, seconds, usecs;
import std.math : isFinite;
import std.traits : Parameters;

import sparkles.base.buffer : InlineBuffer, UniqueBuffer;
import sparkles.base.text.utf8 : validateUtf8;
import sparkles.base.pool.pool : Pool, PoolError;
import sparkles.base.text.cstring : hasInteriorNul, toTempStringz;
import sparkles.input.events : KeyAction, Mods, PointerButton;
import sparkles.input.pointer : PointerShape;
import sparkles.event_horizon.errors : IoErrorStage, IoResult, OpKind,
    ioErr, ioOk;
import sparkles.event_horizon.loop : DefaultLoop, RunStatus;
import sparkles.event_horizon.op : Completion, OpHandle, OpPollAdd, PollEvents;
import sparkles.wsi.clipboard;
import sparkles.wsi.events;
import sparkles.wsi.handles;
import sparkles.wsi.history : PointerSample;
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
    /// The most presentation feedback requests in flight at once: a few
    /// frames' worth for every window.
    enum maxPresentationFeedbacks = 32;

    @disable this(this);

    private struct Slot
    {
        WaylandWsi* owner;
        wl_surface* surface;
        xdg_surface* xdgSurface;
        xdg_toplevel* toplevel;
        wl_callback* frameCallback;
        bool ready;
        int pendingWidth;
        int pendingHeight;
        LogicalSize requestedSize;
        SurfaceMetrics metrics;
        ubyte enteredOutputs;
        int scale = 1;
        PointerShape cursorShape = PointerShape.default_;
        bool cursorVisible = true;
        zwp_confined_pointer_v1* confined;
        bool relative;
        /// The server-side decoration request, when one was made (`F13`).
        zxdg_toplevel_decoration_v1* decoration;
        /// The frame as configured so far, and as last reported: a
        /// configure sequence fills `pendingState`; `xdg_surface.configure`
        /// applies it, reporting a change.
        WindowState pendingState;
        WindowState state;
        bool stateReported;
        /// `DecorationPreference.none`: a client-side frame is not drawn.
        bool noFrame;
        /// What a client frame draws outside the window (`F13`), and the
        /// window's own size, which the surface exceeds by the margin.
        FrameExtents extents;
        LogicalSize windowSize;
        /// Geometry and regions were set from extents, and are reset to the
        /// protocol's defaults when the extents are taken back.
        bool placed;
        /// The crop of the buffers committed, and the viewport that makes it;
        /// empty for none (`setBufferCrop`).
        wp_viewport* viewport;
        PhysicalSize crop;
        int cropScale;
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

    private struct PendingFeedback
    {
        WaylandWsi* owner;
        PresentationFeedback* proxy;
        WindowId window;
        ulong tag;
    }
    private wl_pointer* pointer_;
    private wp_cursor_shape_manager_v1* cursorShapeManager_;
    private wp_viewporter* viewporter_;
    /// `wp_presentation` and its clock (`PRF13`): `clock_id`'s value, or
    /// `uint.max` until the compositor sends it.
    private wp_presentation* presentation_;
    private uint presentationClock_ = uint.max;
    /// The feedback requests in flight, each answered once by a
    /// `PresentedEvent`; a listener's data is its entry, so they never move.
    private PendingFeedback[maxPresentationFeedbacks] feedbacks_;
    private zxdg_decoration_manager_v1* decorationManager_;
    /// `WsiConfig.app`'s id: every toplevel's `app_id`.
    private InlineBuffer!(char, 128) appId_;
    private wp_cursor_shape_device_v1* cursorShapeDevice_;
    private uint pointerEnterSerial_;
    private uint pointerButtonSerial_;
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
    private zwp_text_input_manager_v3* textInputManager_;
    private zwp_pointer_constraints_v1* pointerConstraints_;
    private zwp_relative_pointer_manager_v1* relativePointerManager_;
    private zwp_relative_pointer_v1* relativePointer_;
    private zwp_text_input_v3* textInput_;
    private const(wl_surface)* textInputFocus_;
    private PendingTextInput pendingText_;
    private bool compositionActive_;
    private int keyRepeatRate_;
    private int keyRepeatDelayMs_;
    private OpHandle repeatTimer_;
    private bool repeatInFlight_;
    private bool repeatFirstFire_;
    private uint repeatKey_ = noRepeatKey;
    private wl_callback* bootstrapSync_;
    private pthread_t ownerThread_;
    private Pool!(WindowId, Slot, maxWindows) windows_;
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
    static WsiResult!void open(out WaylandWsi wsi, ref DefaultLoop loop,
        in WsiConfig config = WsiConfig.init)
    {
        if (auto fault = config.app.fault)
            return waylandFailure!void(WsiOperation.open, 0, fault,
                WsiErrorKind.invalidArgument);
        cast(void) wsi.appId_.assign(config.app.idOrDefault);
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
        if (auto fault = config.fault)
            return waylandFailure!WindowId(WsiOperation.createWindow, 0,
                fault, WsiErrorKind.invalidArgument);
        if (!config.visible || config.parent.valid || config.transparent
            || config.state == WindowStartupState.minimized)
            return waylandFailure!WindowId(WsiOperation.createWindow, 0,
                "requested Wayland startup configuration is not implemented",
                WsiErrorKind.unsupported);

        if (windows_.full)
            return waylandFailure!WindowId(WsiOperation.createWindow, 0,
                "Wayland window capacity reached", WsiErrorKind.capacity);

        auto paused = pausePoll();
        if (paused.hasError)
            return wsiErr!WindowId(paused.error);

        // The id exists before the object tree: its listeners may fire
        // during construction, and they find their window by this record.
        auto reserved = windows_.reserve();
        assert(reserved.hasValue, "capacity was checked before the pause");
        WindowId id = reserved.value;
        ref slot = windows_[id];
        slot.owner = &this;
        slot.ready = false;
        slot.requestedSize = config.logicalSize;
        slot.windowSize = config.logicalSize;
        slot.extents = config.frameExtents;
        // Each step returns the moment it fails, so no later call runs against
        // a null object. They share one cleanup rather than each repeating
        // `destroyNative` and the re-arm: `destroyNative` frees exactly what
        // was built, so a partial tree is as safe to hand it as a whole one.
        bool buildObjectTree()
        {
            slot.surface = wl_compositor_create_surface(compositor_);
            if (slot.surface is null)
                return false;
            if (wl_surface_add_listener(slot.surface,
                    listenerPtr(surfaceListener), &slot) != 0)
                return false;
            slot.xdgSurface = xdg_wm_base_get_xdg_surface(
                wmBase_, slot.surface);
            if (slot.xdgSurface is null)
                return false;
            slot.toplevel = xdg_surface_get_toplevel(slot.xdgSurface);
            if (slot.toplevel is null)
                return false;
            if (xdg_surface_add_listener(slot.xdgSurface,
                    listenerPtr(xdgSurfaceListener), &slot) != 0
                || xdg_toplevel_add_listener(slot.toplevel,
                    listenerPtr(toplevelListener), &slot) != 0)
                return false;
            return requestDecorations(slot, config.decorations);
        }

        if (!buildObjectTree())
        {
            destroyNative(slot);
            windows_.cancel(id);
            // Re-arm on the failure path; its own error must not shadow the
            // construction failure being reported, so it goes to the sticky
            // slot instead.
            auto rearmed = prepareAndArm();
            if (rearmed.hasError)
                remember(rearmed.error);
            return waylandFailure!WindowId(WsiOperation.createWindow, 0,
                "failed to construct Wayland toplevel object tree");
        }

        // Terminated at the seam rather than in a fixed array sized one byte
        // past whatever `WindowConfig.title` happens to hold today.
        xdg_toplevel_set_title(slot.toplevel,
            config.title[].toTempStringz.ptr);
        xdg_toplevel_set_app_id(slot.toplevel, appId_[].toTempStringz.ptr);
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
            windows_.cancel(id);
            return wsiErr!WindowId(rearmed.error);
        }
        return wsiOk(id);
    }

    /*
    Compositor-driven interactive move/resize, the first sliver of F13's
    window controls: GNOME draws no server-side decorations, so without a
    client affordance calling these a toplevel cannot be moved or resized
    at all there. Both must answer a pointer press — the compositor
    validates the serial — so the affordance is "start on button down".
    */

    /// Hands the current pointer drag to the compositor as a window move.
    WsiResult!void startInteractiveMove(WindowId id)
    {
        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        if (seat_ is null || pointerButtonSerial_ == 0)
            return waylandFailure!void(WsiOperation.command, 0,
                "interactive move needs a recent pointer press",
                WsiErrorKind.invalidArgument);
        auto paused = pausePoll();
        if (paused.hasError)
            return paused;
        xdg_toplevel_move(windows_.at(checked.value).toplevel, seat_,
            pointerButtonSerial_);
        return prepareAndArm();
    }

    /// ditto, as a resize from the given edge or corner.
    WsiResult!void startInteractiveResize(WindowId id, ResizeEdge edge)
    {
        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        if (seat_ is null || pointerButtonSerial_ == 0)
            return waylandFailure!void(WsiOperation.command, 0,
                "interactive resize needs a recent pointer press",
                WsiErrorKind.invalidArgument);
        if (edge == ResizeEdge.none)
            return waylandFailure!void(WsiOperation.command, 0,
                "interactive resize needs an edge",
                WsiErrorKind.invalidArgument);
        auto paused = pausePoll();
        if (paused.hasError)
            return paused;
        xdg_toplevel_resize(windows_.at(checked.value).toplevel, seat_,
            pointerButtonSerial_, edge);
        return prepareAndArm();
    }

    WsiResult!void setMaximized(WindowId id, bool maximized)
    {
        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        auto paused = pausePoll();
        if (paused.hasError)
            return paused;
        ref slot = windows_.at(checked.value);
        if (maximized)
            xdg_toplevel_set_maximized(slot.toplevel);
        else
            xdg_toplevel_unset_maximized(slot.toplevel);
        return prepareAndArm();
    }

    /// Retitles the window (`F13`): what the window list, the dock and a
    /// server-drawn title bar show. A client-drawn bar reads its own copy.
    WsiResult!void setTitle(WindowId id, in char[] title)
    {
        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        if (validateUtf8(title).hasError || hasInteriorNul(title))
            return waylandFailure!void(WsiOperation.command, 0,
                "a window title is NUL-free UTF-8", WsiErrorKind.invalidArgument);
        auto paused = pausePoll();
        if (paused.hasError)
            return paused;
        xdg_toplevel_set_title(windows_.at(checked.value).toplevel,
            title.toTempStringz.ptr);
        return prepareAndArm();
    }

    /**
    The smallest size, in logical units, the user may resize the window to
    (`F14`); a zero dimension lifts that bound. A client-drawn frame sets it
    so the window cannot shrink past its own title bar. It applies with the
    window's next commit.
    */
    WsiResult!void setMinimumSize(WindowId id, LogicalSize size)
    {
        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        if (!size.width.isFinite || !size.height.isFinite || size.width < 0 || size.height < 0
            || size.width > int.max || size.height > int.max)
            return waylandFailure!void(WsiOperation.command, 0,
                "a minimum size is finite and not negative", WsiErrorKind.invalidArgument);
        auto paused = pausePoll();
        if (paused.hasError)
            return paused;
        xdg_toplevel_set_min_size(windows_.at(checked.value).toplevel,
            cast(int) size.width, cast(int) size.height);
        return prepareAndArm();
    }

    /// Asks the window manager to minimize the window (`F14`). It may
    /// refuse; nothing reports whether it did.
    WsiResult!void setMinimized(WindowId id)
    {
        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        auto paused = pausePoll();
        if (paused.hasError)
            return paused;
        xdg_toplevel_set_minimized(windows_.at(checked.value).toplevel);
        return prepareAndArm();
    }

    /**
    Opens the window manager's own window menu at `at`, in logical units from
    the window's top-left (`F13`): what a client-drawn title bar shows on a
    secondary click. Like a move, it must answer a pointer press.
    */
    WsiResult!void showWindowMenu(WindowId id, LogicalPosition at)
    {
        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        if (seat_ is null || pointerButtonSerial_ == 0)
            return waylandFailure!void(WsiOperation.command, 0,
                "the window menu needs a recent pointer press",
                WsiErrorKind.invalidArgument);
        auto paused = pausePoll();
        if (paused.hasError)
            return paused;
        xdg_toplevel_show_window_menu(windows_.at(checked.value).toplevel, seat_,
            pointerButtonSerial_, cast(int) at.x, cast(int) at.y);
        return prepareAndArm();
    }

    /*
    The frame request (`F13`), made before the first commit as the protocol
    requires, and told to the compositor whichever way it goes: one that
    decorates unless asked otherwise must hear `client` (and `none`, which
    the protocol spells as client-side) as well as `server`. Without the
    decoration manager — GNOME has none — the frame is the client's; with
    it, the decoration's configure answers, inside the configure sequence it
    applies to.
    */
    private bool requestDecorations(ref Slot slot, DecorationPreference preference)
    {
        const drawsNone = preference == DecorationPreference.none;
        slot.noFrame = drawsNone;
        slot.pendingState.decorations = drawsNone ? DecorationMode.none : DecorationMode.client;
        if (decorationManager_ is null)
            return true;
        slot.decoration = zxdg_decoration_manager_v1_get_toplevel_decoration(
            decorationManager_, slot.toplevel);
        if (slot.decoration is null
            || zxdg_toplevel_decoration_v1_add_listener(slot.decoration,
                listenerPtr(decorationListener), &slot) != 0)
            return false;
        const serverSide = preference == DecorationPreference.automatic
            || preference == DecorationPreference.server;
        zxdg_toplevel_decoration_v1_set_mode(slot.decoration, serverSide
            ? ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE
            : ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE);
        return true;
    }

    WsiResult!void destroyWindow(WindowId id)
    {
        auto checked = checkedSlot(id, WsiOperation.close);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        auto paused = pausePoll();
        if (paused.hasError)
            return paused;
        destroyNative(windows_.at(checked.value));
        windows_.remove(id);
        events_.forgetWindow(id);
        const hadSticky = hasStickyError_;
        // Every feedback request is answered: the window's are discarded
        // with it, their objects freed with its surface.
        foreach (ref feedback; feedbacks_)
            if (feedback.proxy !is null && feedback.window == id)
            {
                wp_presentation_feedback_destroy(feedback.proxy);
                emit(id, PresentedEvent(tag: feedback.tag, discarded: true));
                feedback = PendingFeedback.init;
            }
        emit(id, DestroyedEvent());
        auto rearmed = prepareAndArm();
        if (!hadSticky && hasStickyError_)
            return wsiErr!void(stickyError_);
        return rearmed;
    }

    /// The connection's display handle, without a window: what a
    /// process-scoped renderer (a Vulkan instance and device) is chosen
    /// from before any window has a surface (§10.1).
    WsiResult!DisplayHandle displayHandle()
    {
        auto owner = requireOwner!DisplayHandle(WsiOperation.queryHandle);
        if (owner.hasError)
            return owner;
        return wsiOk(DisplayHandle(WaylandDisplayHandle(display_)));
    }

    WsiResult!NativeHandles nativeHandles(WindowId id)
    {
        auto checked = checkedSlot(id, WsiOperation.queryHandle);
        if (checked.hasError)
            return wsiErr!NativeHandles(checked.error);
        ref slot = windows_.at(checked.value);
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
        nativeWork |= serviceClipboard();
        if (nativeWork)
            return ioOk(RunStatus.dispatched);

        auto result = loop.runOnce(timeout);
        if (result.hasError)
            return result;
        if (!servicePoll(nativeWork))
            return ioErr!RunStatus(cast(int) stickyError_.nativeCode,
                OpKind.pollAdd, IoErrorStage.completion,
                "Wayland dispatch/re-arm failed");
        nativeWork |= serviceClipboard();
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
        // The repeat timer's completion borrows this struct; reap it before
        // the loop reference goes away, like the display poll below.
        repeatKey_ = noRepeatKey;
        if (repeatInFlight_)
        {
            auto reaped = loop_.cancelAndWait(repeatTimer_);
            repeatInFlight_ = false;
            if (reaped.hasError)
                return waylandFailure!void(WsiOperation.attach,
                    reaped.error.code,
                    "failed to cancel and reap the key-repeat timer");
        }
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
        // The clipboard's pipes are polled by the loop; close them while
        // it is still attached.
        closeClipboard();
        auto detached = detach();
        if (detached.hasError)
            remember(detached.error);
        foreach (h; windows_.byLive)
            destroyNative(windows_[h]);
        windows_.clear();
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
                    cancelled.error.code,
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
                submitted.error.code,
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
        if (selectionSync_ !is null)
        {
            wl_callback_destroy(selectionSync_);
            selectionSync_ = null;
        }
        releasePointer();
        if (textInput_ !is null)
        {
            zwp_text_input_v3_destroy(textInput_);
            textInput_ = null;
            textInputFocus_ = null;
        }
        if (textInputManager_ !is null)
        {
            zwp_text_input_manager_v3_destroy(textInputManager_);
            textInputManager_ = null;
        }
        if (pointerConstraints_ !is null)
        {
            zwp_pointer_constraints_v1_destroy(pointerConstraints_);
            pointerConstraints_ = null;
        }
        if (relativePointerManager_ !is null)
        {
            zwp_relative_pointer_manager_v1_destroy(relativePointerManager_);
            relativePointerManager_ = null;
        }
        if (cursorShapeManager_ !is null)
        {
            wp_cursor_shape_manager_v1_destroy(cursorShapeManager_);
            cursorShapeManager_ = null;
        }
        if (decorationManager_ !is null)
        {
            zxdg_decoration_manager_v1_destroy(decorationManager_);
            decorationManager_ = null;
        }
        if (viewporter_ !is null)
        {
            wp_viewporter_destroy(viewporter_);
            viewporter_ = null;
        }
        foreach (ref feedback; feedbacks_)
            if (feedback.proxy !is null)
            {
                wp_presentation_feedback_destroy(feedback.proxy);
                feedback = PendingFeedback.init;
            }
        if (presentation_ !is null)
        {
            wp_presentation_destroy(presentation_);
            presentation_ = null;
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
        if (slot.confined !is null)
            zwp_confined_pointer_v1_destroy(slot.confined);
        if (slot.frameCallback !is null)
            wl_callback_destroy(slot.frameCallback);
        // Before its toplevel: a decoration outliving it is a protocol error.
        if (slot.decoration !is null)
            zxdg_toplevel_decoration_v1_destroy(slot.decoration);
        // Before its surface, as every surface extension.
        if (slot.viewport !is null)
            wp_viewport_destroy(slot.viewport);
        if (slot.toplevel !is null)
            xdg_toplevel_destroy(slot.toplevel);
        if (slot.xdgSurface !is null)
            xdg_surface_destroy(slot.xdgSurface);
        if (slot.surface !is null)
            wl_surface_destroy(slot.surface);
        slot = Slot.init;
    }

    private WsiResult!size_t checkedSlot(WindowId id,
        WsiOperation operation)
    {
        auto owner = requireOwner!size_t(operation);
        if (owner.hasError)
            return owner;
        auto index = windows_.resolve(id);
        if (index.hasError)
            return waylandFailure!size_t(operation, 0,
                index.error == PoolError.invalid
                    ? "invalid Wayland window id" : "stale Wayland window id",
                WsiErrorKind.staleId);
        size_t slot = index.value;
        return wsiOk(slot);
    }

    private WindowId idAt(size_t index) const pure nothrow @nogc
        => windows_.handleAt(index);

    private size_t indexOfSlot(const Slot* slot) const pure nothrow @nogc
    {
        foreach (i; 0 .. windows_.slotCapacity)
            if (&windows_.at(i) is slot)
                return i;
        return size_t.max;
    }

    private size_t indexOfSurface(const wl_surface* surface)
        const pure nothrow @nogc
    {
        if (surface is null)
            return size_t.max;
        foreach (h; windows_.byLive)
            if (windows_[h].surface is surface)
                return h.index;
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
        scope Make make) nothrow @nogc
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

    /// Largest piece one pipe read or write moves: also the bound on the
    /// chunks a sink sees (`DT4`).
    enum size_t clipChunkBytes = 64 * 1024;

    /// Whether the compositor offers a data device: without one the
    /// clipboard commands fail with `unsupported`.
    bool clipboardAvailable() const @safe pure nothrow @nogc => dataDevice_ !is null;

    /**
    Offers `mimeTypes` as the selection through a `wl_data_source`; each
    client's request pulls the bytes from `provider` into that client's pipe,
    one chunk at a time as it drains (`DT3`, `DT4`). The provider must
    outlive the offer. Setting the selection needs a recent input serial, so
    a window of this application must have had keyboard or pointer input.
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
        return setSelection(added.value);
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
        return setSelection(added.value);
    }

    /// Ends an offer this application made: clears the selection and
    /// reports `withdrawn` (`DT1`).
    WsiResult!void withdrawClipboard(OfferId offer)
    {
        auto record = clipboard_.offers.get(offer);
        if (record is null || !record.own)
            return waylandFailure!void(WsiOperation.command, 0,
                "no live offer of this application's", WsiErrorKind.staleId);
        if (offer == clipboard_.current && dataDevice_ !is null)
        {
            wl_data_device_set_selection(dataDevice_, null, inputSerial_);
            flushRequests();
        }
        announce(offer, DataOfferAction.withdrawn);
        dropOffer(offer);
        return wsiOk();
    }

    /**
    Starts reading `offer`'s `mimeType` into `sink` (`DT2`): the compositor
    is asked to have the offer's source write into a pipe, which Event
    Horizon reports readable. Only the current selection is readable.
    */
    WsiResult!TransferId receive(S)(OfferId offer, scope const(char)[] mimeType,
        ref S sink)
    if (isDataSink!S)
    {
        const own = offer == sourceOffer_;
        if (offer != clipboard_.current || !clipboard_.offers.isLive(offer)
            || (!own && selectionOffer_ is null))
            return waylandFailure!TransferId(WsiOperation.command, 0,
                "the offer has ended", WsiErrorKind.staleId);
        auto begun = clipboard_.begin(offer, mimeType,
            (() @trusted => SinkRef.to(sink))());
        if (begun.hasError)
            return begun;
        ref pipe = readers_[begun.value.index];
        pipe = Pipe(&this, -1, begun.value);
        // An own offer is read through the compositor too, once it has
        // returned the source as the selection (`serviceClipboard`).
        if (own && !selectionIsOwn_)
            pipe.waiting = true;
        else
            startRead(pipe);
        return begun;
    }

    // Asks the selection's source to write the transfer's type into a pipe.
    private void startRead(ref Pipe pipe)
    {
        pipe.waiting = false;
        auto transfer = clipboard_.transfers.get(pipe.transfer);
        int[2] fds;
        if (transfer is null || selectionOffer_ is null
            || pipe2(fds, O_CLOEXEC | O_NONBLOCK) != 0)
        {
            clipboard_.end(pipe.transfer, TransferStatus.failed);
            return;
        }
        char[maxMimeType + 1] mime = 0;
        mime[0 .. transfer.mime.length] = transfer.mime[];
        wl_data_offer_receive(selectionOffer_, mime.ptr, fds[1]);
        flushRequests();
        posixClose(fds[1]);
        pipe.fd = fds[0];
        armPipe(pipe, PollEvents.readable);
    }

    /// Ends a transfer with `cancelled`; its sink then hears nothing more and
    /// its pipe is closed.
    WsiResult!void cancelTransfer(TransferId transfer)
    {
        if (clipboard_.transfers.isLive(transfer))
        {
            readers_[transfer.index].waiting = false;
            closePipe(readers_[transfer.index]);
        }
        return clipboard_.cancel(transfer);
    }

    // One pipe a transfer moves through, either way: a reader of an offer, or
    // a writer serving a requester. Address-stable inside the backend, so the
    // Event Horizon completion can name it.
    private struct Pipe
    {
        WaylandWsi* owner;
        int fd = -1;
        TransferId transfer; // a reader's transfer
        OfferId offer;       // a writer's offer
        ubyte type;          // a writer's MIME type, by index
        ulong offset;        // bytes a writer pulled from the provider
        size_t pending;      // bytes of `chunk` not yet written
        size_t written;
        OpHandle handle;
        bool armed;
        bool ready;
        int result;
        bool fresh;          // a writer waiting for its first arming
        bool waiting;        // a reader of an own offer, before its selection
        UniqueBuffer!(ubyte, 1) chunk;
    }

    private enum textMime = "text/plain;charset=utf-8";

    private ClipboardState!() clipboard_;
    private wl_data_device_manager* dataManager_;
    private wl_data_device* dataDevice_;
    private wl_data_source* source_;        // the own offer's, while it is the selection
    private OfferId sourceOffer_;
    private wl_data_offer* pendingOffer_;   // introduced, not yet the selection
    private PendingOffer pending_;
    private wl_data_offer* selectionOffer_; // the selection's, own or foreign
    private uint inputSerial_;              // the latest keyboard or button serial
    // What listeners saw, for `serviceClipboard` to act on from dispatch:
    // listeners run inside libwayland's dispatch, where no sink may be
    // called (`DT2`).
    private bool selectionChanged_;
    private InlineBuffer!(char, maxMimeType)[maxOfferTypes] selectionTypes_;
    private ubyte selectionTypeCount_;
    private OfferId cancelledOffer_;
    private bool selectionIsOwn_; // the compositor returned the own source
    // Every own source offers a marker type of its own, never shown to the
    // application (`ownMarker`): the selection is this application's current
    // source only when it carries the current marker. A compositor hands
    // back other selections while a source is held — another client's, or
    // its own copy of an earlier one (Weston's clipboard).
    private uint instance_;           // this connection's number in the process, from 1
    private uint sourceNumber_;       // the current own source's marker number
    private bool selectionOwn_;       // the selection carries the current marker
    private bool selectionStale_;     // ... an earlier own source's marker
    // A round trip after each `set_selection`: a compositor that does not
    // take the selection says nothing (Weston, for a serial no newer than
    // the selection's), so its end is when to conclude it did not.
    private wl_callback* selectionSync_;
    private bool selectionSettled_;
    private Pipe[8] readers_;
    private Pipe[4] writers_;

    // What an introduced offer has said so far: its application types (at
    // most `maxOfferTypes`) and which marker, if any, it carried. A marker
    // is judged before the type cap and never counts toward it: an own
    // offer carries its marker after the application's types, so a full
    // offer's marker arrives when the cap is already reached — and it is
    // the marker that says the offer is this application's own.
    private struct PendingOffer
    {
        InlineBuffer!(char, maxMimeType)[maxOfferTypes] types;
        ubyte count;
        bool own;   // carries the current source's marker
        bool stale; // carries an earlier own source's marker

        void reset() nothrow @nogc
        {
            count = 0;
            own = stale = false;
        }

        // One `wl_data_offer.offer` type, against the current own source
        // (`instance`, `number`).
        void noteType(scope const(char)[] spelled, uint instance, uint number)
            nothrow @nogc
        {
            // A source marker is never an application's type: it says
            // whose the offer is.
            if (spelled.length > markerStem.length
                && spelled[0 .. markerStem.length] == markerStem)
            {
                char[64] current;
                const mine = ownMarker(current, instance, number);
                if (spelled == mine)
                    own = true;
                else
                {
                    // This connection's stem (`…-<pid>.<instance>-`): an
                    // earlier source of its own, not another connection's
                    // in the process.
                    size_t stem = mine.length;
                    while (stem > 0 && mine[stem - 1] != '-')
                        --stem;
                    stale = spelled.length > stem && spelled[0 .. stem] == mine[0 .. stem];
                }
                return;
            }
            if (count == maxOfferTypes)
                return;
            // Text under its X names (Xwayland, older toolkits) is the one
            // MIME type; anything else that is not a MIME type is skipped.
            const mime = spelled == "UTF8_STRING" ? textMime : spelled;
            if (mime.length == 0 || mime.length > maxMimeType || !isMimeType(mime))
                return;
            foreach (ref t; types[0 .. count])
                if (t[] == mime)
                    return;
            const assigned = types[count].assign(mime);
            assert(assigned, "the length was checked");
            ++count;
        }
    }

    private void ensureDataDevice() nothrow @nogc
    {
        if (dataDevice_ !is null || dataManager_ is null || seat_ is null)
            return;
        dataDevice_ = wl_data_device_manager_get_data_device(dataManager_, seat_);
        if (dataDevice_ !is null
            && wl_data_device_add_listener(dataDevice_,
                listenerPtr(dataDeviceListener), &this) != 0)
            remember(wsiError(WsiErrorKind.nativeFailure, WsiOperation.open,
                BackendKind.wayland, 0, "failed to install wl_data_device listener"));
    }

    private WsiResult!OfferId setSelection(OfferId offer)
    {
        if (dataDevice_ is null)
        {
            clipboard_.drop(offer);
            return waylandFailure!OfferId(WsiOperation.command, 0,
                "the compositor offers no wl_data_device_manager",
                WsiErrorKind.unsupported);
        }
        auto source = wl_data_device_manager_create_data_source(dataManager_);
        if (source is null || wl_data_source_add_listener(source,
                listenerPtr(dataSourceListener), &this) != 0)
        {
            clipboard_.drop(offer);
            return waylandFailure!OfferId(WsiOperation.command, 0,
                "creating a wl_data_source failed");
        }
        auto record = clipboard_.offers.get(offer);
        foreach (ref t; record.types[0 .. record.typeCount])
        {
            char[maxMimeType + 1] mime = 0;
            mime[0 .. t.length] = t[];
            wl_data_source_offer(source, mime.ptr);
        }
        // This source's marker, after the application's types.
        if (instance_ == 0)
            instance_ = atomicOp!"+="(nextInstance, 1);
        ++sourceNumber_;
        char[64] marker;
        cast(void) ownMarker(marker, instance_, sourceNumber_);
        wl_data_source_offer(source, marker.ptr);
        // The previous own source is replaced: the compositor cancels it, and
        // `publish` withdraws its offer now.
        releaseSource();
        source_ = source;
        sourceOffer_ = offer;
        selectionIsOwn_ = false;
        wl_data_device_set_selection(dataDevice_, source, inputSerial_);
        armSelectionSync();
        flushRequests();
        publish(offer);
        return wsiOk(offer);
    }

    // What begins every own source's marker type, before
    // `<pid>.<instance>-<number>`: unique to a connection, as two can share a
    // process (the clipboard lane's second client does).
    private enum markerStem = "application/x-sparkles-wsi-own-";

    // The marker type of connection `instance`'s own source `number`, in `buf`
    // with a NUL after it; the slice leaves the NUL out.
    private static const(char)[] ownMarker(return ref char[64] buf, uint instance, uint number)
        nothrow @nogc
    {
        size_t n;
        void decimal(ulong v)
        {
            char[20] digits;
            size_t k;
            do
            {
                digits[k++] = cast(char)('0' + v % 10);
                v /= 10;
            }
            while (v);
            while (k)
                buf[n++] = digits[--k];
        }

        buf[0 .. markerStem.length] = markerStem;
        n = markerStem.length;
        decimal(getpid());
        buf[n++] = '.';
        decimal(instance);
        buf[n++] = '-';
        decimal(number);
        buf[n] = 0;
        return buf[0 .. n];
    }

    private void armSelectionSync() nothrow @nogc
    {
        if (display_ is null)
            return;
        if (selectionSync_ !is null)
            wl_callback_destroy(selectionSync_);
        selectionSync_ = wl_display_sync(display_);
        if (selectionSync_ !is null && wl_callback_add_listener(selectionSync_,
                listenerPtr(selectionSyncListener), &this) != 0)
        {
            wl_callback_destroy(selectionSync_);
            selectionSync_ = null;
        }
    }

    private extern (C) static void onSelectionSync(void* data, wl_callback* callback, uint)
        nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        wl_callback_destroy(callback);
        owner.selectionSync_ = null;
        owner.selectionSettled_ = true;
    }

    // This application's offer is not the selection: it ends (`DT1`), its
    // readers failing, and its source with it.
    private void withdrawOwnOffer()
    {
        const offer = sourceOffer_;
        if (clipboard_.offers.isLive(offer))
        {
            announce(offer, DataOfferAction.withdrawn);
            dropOffer(offer);
        }
        else
            releaseSource();
        selectionIsOwn_ = false;
    }

    private void releaseSource() nothrow @nogc
    {
        if (source_ is null)
            return;
        wl_data_source_destroy(source_);
        source_ = null;
        sourceOffer_ = OfferId.init;
    }

    private void flushRequests() nothrow @nogc
    {
        if (display_ !is null)
            wl_display_flush(display_);
    }

    private void armPipe(ref Pipe pipe, PollEvents interest) nothrow
    {
        if (pipe.armed || pipe.fd < 0 || loop_ is null)
            return;
        auto submitted = loop_.submit(OpPollAdd(pipe.fd, interest, false),
            &onPipeReady, &pipe);
        if (submitted.hasError)
        {
            pipe.ready = true;
            pipe.result = -1;
            return;
        }
        pipe.handle = submitted.value;
        pipe.armed = true;
    }

    private static void onPipeReady(void* context, ref Completion completion)
        nothrow @nogc
    {
        auto pipe = cast(Pipe*) context;
        pipe.armed = false;
        pipe.ready = true;
        pipe.result = completion.res;
    }

    private void closePipe(ref Pipe pipe) nothrow
    {
        if (pipe.armed && loop_ !is null)
        {
            const reaped = loop_.cancelAndWait(pipe.handle);
            pipe.armed = false;
            if (reaped.hasError)
                remember(wsiError(WsiErrorKind.nativeFailure, WsiOperation.command,
                    BackendKind.wayland, reaped.error.code,
                    "failed to cancel a clipboard pipe's poll"));
        }
        if (pipe.fd >= 0)
            posixClose(pipe.fd);
        pipe.fd = -1;
        pipe.ready = false;
        pipe.pending = 0;
        pipe.written = 0;
    }

    // Acts on what the listeners recorded, then moves the bytes of every pipe
    // Event Horizon reported ready, from the backend's own dispatch (`DT2`);
    // whether any of it happened.
    private bool serviceClipboard()
    {
        bool work;
        if (cancelledOffer_ != OfferId.init)
        {
            // Another client took the selection: this application's offer
            // ends (`DT1`).
            const offer = cancelledOffer_;
            cancelledOffer_ = OfferId.init;
            work = true;
            if (clipboard_.offers.isLive(offer))
            {
                announce(offer, DataOfferAction.withdrawn);
                dropOffer(offer);
            }
        }
        if (selectionChanged_)
        {
            selectionChanged_ = false;
            work = true;
            // An earlier own source's selection, overtaken by a later
            // `set_selection` whose own report follows: nothing to act on.
            if (!selectionStale_)
            {
                selectionIsOwn_ = source_ !is null && selectionOwn_;
                // Another client's selection, or the compositor's copy of an
                // earlier one, while a source is held: this application's
                // offer is not the selection.
                if (source_ !is null && !selectionOwn_ && selectionOffer_ !is null)
                    withdrawOwnOffer();
                noticeSelection();
                if (selectionIsOwn_)
                    foreach (ref pipe; readers_)
                        if (pipe.waiting)
                            startRead(pipe);
            }
        }
        if (selectionSettled_)
        {
            selectionSettled_ = false;
            work = true;
            // The round trip after `set_selection` ended with no report of
            // this source as the selection. With keyboard focus — the client
            // a compositor reports selections to — it did not take it, and
            // the offer ends rather than leaving its readers waiting.
            if (source_ !is null && !selectionIsOwn_ && keyboardFocus_ !is null)
                withdrawOwnOffer();
        }
        foreach (ref pipe; writers_)
            if (pipe.fresh)
            {
                pipe.fresh = false;
                work = true;
                armPipe(pipe, PollEvents.writable);
            }
        foreach (ref pipe; readers_)
        {
            if (!pipe.ready)
                continue;
            pipe.ready = false;
            work = true;
            readPipe(pipe);
        }
        foreach (ref pipe; writers_)
        {
            if (!pipe.ready)
                continue;
            pipe.ready = false;
            work = true;
            writePipe(pipe);
        }
        return work;
    }

    private void readPipe(ref Pipe pipe)
    {
        const transfer = pipe.transfer;
        ubyte[clipChunkBytes] chunk = void;
        const n = read(pipe.fd, chunk.ptr, chunk.length);
        if (n > 0)
        {
            if (auto record = clipboard_.transfers.get(transfer))
                record.sink.chunk(transfer, chunk[0 .. n]);
            armPipe(pipe, PollEvents.readable);
            return;
        }
        if (n < 0 && (errno == EAGAIN || errno == EINTR))
        {
            armPipe(pipe, PollEvents.readable);
            return;
        }
        closePipe(pipe);
        clipboard_.end(transfer, n == 0 ? TransferStatus.completed : TransferStatus.failed);
    }

    // One chunk from the provider at a time; a requester that stops reading
    // holds at most that chunk here (`DT4`).
    private void writePipe(ref Pipe pipe)
    {
        auto record = clipboard_.offers.get(pipe.offer);
        if (record is null || pipe.result < 0)
        {
            closePipe(pipe);
            return;
        }
        if (pipe.pending == pipe.written)
        {
            pipe.chunk.length = clipChunkBytes;
            pipe.pending = record.fill(record.types[pipe.type][], pipe.offset,
                pipe.chunk[]);
            pipe.offset += pipe.pending;
            pipe.written = 0;
            if (pipe.pending == 0)
            {
                // The provider's end: closing the pipe is the end of data.
                closePipe(pipe);
                return;
            }
        }
        const n = writeWithoutSigpipe(pipe.fd, pipe.chunk[].ptr + pipe.written,
            pipe.pending - pipe.written);
        if (n < 0 && errno != EAGAIN && errno != EINTR)
        {
            closePipe(pipe); // the requester went away (EPIPE)
            return;
        }
        if (n > 0)
            pipe.written += n;
        armPipe(pipe, PollEvents.writable);
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

    // Ends an offer: its readers fail and close, and so do the writers
    // serving it.
    private void dropOffer(OfferId offer)
    {
        foreach (h; clipboard_.transfers.byLive)
            if (clipboard_.transfers[h].offer == offer)
                closePipe(readers_[h.index]);
        foreach (ref pipe; writers_)
            if (pipe.offer == offer && pipe.fd >= 0)
                closePipe(pipe);
        if (offer == sourceOffer_)
            releaseSource();
        clipboard_.drop(offer);
    }

    private WindowId firstWindow()
    {
        foreach (h; windows_.byLive)
            return h;
        return WindowId.init;
    }

    private void closeClipboard() nothrow
    {
        foreach (ref pipe; readers_)
            closePipe(pipe);
        foreach (ref pipe; writers_)
            closePipe(pipe);
        foreach (h; clipboard_.transfers.byLive)
            clipboard_.end(h, TransferStatus.failed);
        releaseSource();
        if (pendingOffer_ !is null)
            wl_data_offer_destroy(pendingOffer_);
        if (selectionOffer_ !is null && selectionOffer_ !is pendingOffer_)
            wl_data_offer_destroy(selectionOffer_);
        pendingOffer_ = selectionOffer_ = null;
        if (dataDevice_ !is null)
        {
            wl_data_device_release(dataDevice_);
            dataDevice_ = null;
        }
        if (dataManager_ !is null)
        {
            wl_data_device_manager_destroy(dataManager_);
            dataManager_ = null;
        }
    }

    // ── data-device listeners ───────────────────────────────────────────────

    private extern (C) static void onDataOffer(void* data, wl_data_device*,
        wl_data_offer* offer) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        if (owner.pendingOffer_ !is null && owner.pendingOffer_ !is owner.selectionOffer_)
            wl_data_offer_destroy(owner.pendingOffer_);
        owner.pendingOffer_ = offer;
        owner.pending_.reset();
        wl_data_offer_add_listener(offer, listenerPtr(dataOfferListener), owner);
    }

    private extern (C) static void onOfferType(void* data, wl_data_offer* offer,
        const(char)* type) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        if (offer !is owner.pendingOffer_)
            return;
        owner.pending_.noteType(type[0 .. strlen(type)], owner.instance_,
            owner.sourceNumber_);
    }

    private extern (C) static void onSelection(void* data, wl_data_device*,
        wl_data_offer* offer) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        if (owner.selectionOffer_ !is null && owner.selectionOffer_ !is offer)
            wl_data_offer_destroy(owner.selectionOffer_);
        owner.selectionOffer_ = offer;
        owner.selectionTypeCount_ = 0;
        const introduced = offer !is null && offer is owner.pendingOffer_;
        owner.selectionOwn_ = introduced && owner.pending_.own;
        owner.selectionStale_ = introduced && owner.pending_.stale;
        if (introduced)
        {
            owner.selectionTypes_ = owner.pending_.types;
            owner.selectionTypeCount_ = owner.pending_.count;
            owner.pendingOffer_ = null;
        }
        owner.selectionChanged_ = true;
    }

    // A new selection: this application's own source coming back, which
    // needs nothing, or another client's, which replaces whatever was.
    private void noticeSelection()
    {
        if (source_ !is null)
            return;
        if (auto record = clipboard_.offers.get(clipboard_.current))
        {
            if (record.own)
                announce(clipboard_.current, DataOfferAction.withdrawn);
            dropOffer(clipboard_.current);
        }
        if (selectionOffer_ is null || selectionTypeCount_ == 0)
            return;
        const(char)[][maxOfferTypes] types;
        foreach (i; 0 .. selectionTypeCount_)
            types[i] = selectionTypes_[i][];
        auto added = clipboard_.add(firstWindow(), types[0 .. selectionTypeCount_],
            false);
        if (!added.hasError)
            publish(added.value);
    }

    private extern (C) static void onSourceSend(void* data, wl_data_source* source,
        const(char)* type, int fd) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        auto record = owner.clipboard_.offers.get(owner.sourceOffer_);
        const spelled = type[0 .. strlen(type)];
        ubyte index = ubyte.max;
        if (source is owner.source_ && record !is null)
            foreach (i, ref t; record.types[0 .. record.typeCount])
                if (t[] == spelled)
                    index = cast(ubyte) i;
        Pipe* free;
        foreach (ref pipe; owner.writers_)
            if (pipe.fd < 0)
            {
                free = &pipe;
                break;
            }
        if (index == ubyte.max || free is null)
        {
            posixClose(fd); // an unknown type, or every writer busy: no data
            return;
        }
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
        free.owner = owner;
        free.fd = fd;
        free.offer = owner.sourceOffer_;
        free.type = index;
        free.offset = 0;
        free.pending = free.written = 0;
        free.result = 0;
        // Armed and written from dispatch (`serviceClipboard`).
        free.fresh = true;
    }

    private extern (C) static void onSourceCancelled(void* data,
        wl_data_source* source) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        if (source !is owner.source_)
        {
            wl_data_source_destroy(source);
            return;
        }
        owner.cancelledOffer_ = owner.sourceOffer_;
        owner.releaseSource();
    }

    private static bool isMimeType(scope const(char)[] name) @safe pure nothrow @nogc
    {
        foreach (c; name)
            if (c == '/')
                return true;
        return false;
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
            // v2 reports tiled edges, v5 the window manager's capabilities,
            // v6 suspension; every listener handles all of v6's events.
            const version_ = advertisedVersion < 6 ? advertisedVersion : 6;
            owner.wmBase_ = cast(xdg_wm_base*) wl_registry_bind(
                registry, name, &xdg_wm_base_interface, version_);
            if (owner.wmBase_ !is null
                && xdg_wm_base_add_listener(owner.wmBase_,
                    listenerPtr(wmBaseListener), owner) != 0)
                owner.remember(wsiError(WsiErrorKind.nativeFailure,
                    WsiOperation.open, BackendKind.wayland, 0,
                    "failed to install xdg_wm_base listener"));
        }
        else if (strcmp(interfaceName,
            zxdg_decoration_manager_v1_interface.name) == 0
            && owner.decorationManager_ is null)
        {
            owner.decorationManager_ = cast(zxdg_decoration_manager_v1*)
                wl_registry_bind(registry, name,
                    &zxdg_decoration_manager_v1_interface, 1);
        }
        else if (strcmp(interfaceName, wp_viewporter_interface.name) == 0
            && owner.viewporter_ is null)
        {
            owner.viewporter_ = cast(wp_viewporter*) wl_registry_bind(registry,
                name, &wp_viewporter_interface, 1);
        }
        else if (strcmp(interfaceName, wp_presentation_interface.name) == 0
            && owner.presentation_ is null)
        {
            // v2 only lets a variable-rate output report a refresh; the
            // events are v1's.
            const version_ = advertisedVersion < 2 ? advertisedVersion : 2;
            owner.presentation_ = cast(wp_presentation*) wl_registry_bind(
                registry, name, &wp_presentation_interface, version_);
            if (owner.presentation_ !is null
                && wp_presentation_add_listener(owner.presentation_,
                    listenerPtr(presentationListener), owner) != 0)
                owner.remember(wsiError(WsiErrorKind.nativeFailure,
                    WsiOperation.open, BackendKind.wayland, 0,
                    "failed to install wp_presentation listener"));
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
            owner.ensureTextInput();
            owner.ensureDataDevice();
        }
        else if (strcmp(interfaceName, wl_data_device_manager_interface.name) == 0
            && owner.dataManager_ is null)
        {
            const version_ = advertisedVersion < 3 ? advertisedVersion : 3;
            owner.dataManager_ = cast(wl_data_device_manager*) wl_registry_bind(
                registry, name, &wl_data_device_manager_interface, version_);
            owner.ensureDataDevice();
        }
        else if (strcmp(interfaceName,
            zwp_text_input_manager_v3_interface.name) == 0
            && owner.textInputManager_ is null)
        {
            owner.textInputManager_ = cast(zwp_text_input_manager_v3*)
                wl_registry_bind(registry, name,
                    &zwp_text_input_manager_v3_interface, 1);
            owner.ensureTextInput();
        }
        else if (strcmp(interfaceName,
            zwp_pointer_constraints_v1_interface.name) == 0
            && owner.pointerConstraints_ is null)
        {
            owner.pointerConstraints_ = cast(zwp_pointer_constraints_v1*)
                wl_registry_bind(registry, name,
                    &zwp_pointer_constraints_v1_interface, 1);
        }
        else if (strcmp(interfaceName,
            zwp_relative_pointer_manager_v1_interface.name) == 0
            && owner.relativePointerManager_ is null)
        {
            owner.relativePointerManager_ =
                cast(zwp_relative_pointer_manager_v1*)
                wl_registry_bind(registry, name,
                    &zwp_relative_pointer_manager_v1_interface, 1);
        }
    }

    /// The manager and the seat arrive in either registry order; the
    /// per-seat text-input object exists once both are bound.
    private void ensureTextInput() nothrow @nogc
    {
        if (textInput_ !is null || textInputManager_ is null
            || seat_ is null)
            return;
        textInput_ = zwp_text_input_manager_v3_get_text_input(
            textInputManager_, seat_);
        if (textInput_ !is null
            && zwp_text_input_v3_add_listener(textInput_,
                listenerPtr(textInputListener), &this) != 0)
            remember(wsiError(WsiErrorKind.nativeFailure,
                WsiOperation.dispatch, BackendKind.wayland, 0,
                "failed to install zwp_text_input_v3 listener"));
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
            foreach (h; owner.windows_.byLive)
            {
                ref window = owner.windows_[h];
                if ((window.enteredOutputs & (1 << i)) != 0)
                {
                    window.enteredOutputs &= ~cast(ubyte)(1 << i);
                    owner.refreshWindowScale(h.index);
                }
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
                    foreach (h; owner.windows_.byLive)
                        if ((owner.windows_[h].enteredOutputs & (1 << i)) != 0)
                            owner.refreshWindowScale(h.index);
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
                OutputId(cast(uint) i, 1), entered));
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
        ref slot = windows_.at(windowIndex);
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
        const metrics = metricsFor(slot, slot.windowSize, slot.state);
        if (slot.ready && metrics != slot.metrics)
            emit(idAt(windowIndex), SurfaceMetricsChangedEvent(metrics));
        slot.metrics = metrics;
    }

    /// The surface's metrics for a window of `window` logical units in
    /// `state`: the surface is the window and the frame's margin round it.
    private static SurfaceMetrics metricsFor(ref const Slot slot, LogicalSize window,
        in WindowState state) nothrow @nogc
    {
        const m = slot.extents.marginIn(state);
        const logical = LogicalSize(window.width + 2 * m, window.height + 2 * m);
        auto metrics = SurfaceMetrics(logical,
            PhysicalSize(cast(int)(logical.width * slot.scale),
                cast(int)(logical.height * slot.scale)),
            ScaleFactor(slot.scale));
        const pm = m * slot.scale;
        metrics.frameMargin = PhysicalInsets(pm, pm, pm, pm);
        return metrics;
    }

    /*
    The window inside its surface, as the compositor is to place and stack it
    (`F13`): its geometry, the input region (the window and its outer resize
    border; a press on the shadow beyond goes through) and the opaque region
    (the window less its rounded corners). Double-buffered, so they apply
    with the next buffer — the one at the size they were set for. A window
    that asked for no extents keeps the protocol's defaults.
    */
    private void placeWindow(ref Slot slot, in WindowState state) nothrow @nogc
    {
        if (slot.xdgSurface is null || slot.surface is null)
            return;
        const w = cast(int) slot.windowSize.width, h = cast(int) slot.windowSize.height;
        if (slot.extents == FrameExtents.init)
        {
            // Taken back: the whole surface is the window again, and takes
            // input everywhere, as before any were set.
            if (slot.placed && w > 0 && h > 0)
            {
                xdg_surface_set_window_geometry(slot.xdgSurface, 0, 0, w, h);
                wl_surface_set_input_region(slot.surface, null);
                wl_surface_set_opaque_region(slot.surface, null);
            }
            slot.placed = false;
            return;
        }
        const m = cast(int) slot.extents.marginIn(state);
        if (w <= 0 || h <= 0)
            return;
        slot.placed = true;
        xdg_surface_set_window_geometry(slot.xdgSurface, m, m, w, h);
        if (auto input = wl_compositor_create_region(compositor_))
        {
            const r = cast(int) slot.extents.resizeIn(state);
            wl_region_add(input, m - r, m - r, w + 2 * r, h + 2 * r);
            wl_surface_set_input_region(slot.surface, input);
            wl_region_destroy(input);
        }
        if (auto opaque = wl_compositor_create_region(compositor_))
        {
            const r = cast(int) slot.extents.radiusIn(state);
            if (2 * r < w && 2 * r < h)
            {
                wl_region_add(opaque, m, m + r, w, h - 2 * r);
                if (r > 0)
                    wl_region_add(opaque, m + r, m, w - 2 * r, h);
            }
            wl_surface_set_opaque_region(slot.surface, opaque);
            wl_region_destroy(opaque);
        }
    }

    /**
    What a client-drawn frame draws outside the window from now on (`F13`):
    the surface grows by the margin while the frame is the client's and the
    window is not maximized or fullscreen, and the metrics that follow say
    so. It applies with the window's next buffer.
    */
    WsiResult!void setFrameExtents(WindowId id, FrameExtents extents)
    {
        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        if (const fault = extents.fault)
            return waylandFailure!void(WsiOperation.command, 0, fault,
                WsiErrorKind.invalidArgument);
        auto paused = pausePoll();
        if (paused.hasError)
            return paused;
        const index = checked.value;
        ref slot = windows_.at(index);
        slot.extents = extents;
        placeWindow(slot, slot.state);
        const metrics = metricsFor(slot, slot.windowSize, slot.state);
        if (slot.ready && metrics != slot.metrics)
            emit(idAt(index), SurfaceMetricsChangedEvent(metrics));
        slot.metrics = metrics;
        return prepareAndArm();
    }

    /// Whether $(LREF setBufferCrop) can crop: the compositor has
    /// `wp_viewporter`.
    bool canCropBuffers() const @safe pure nothrow @nogc => viewporter_ !is null;

    /**
    Show only the top-left `shown` pixels of the buffers the window commits
    from now on, at the window's size; an empty size shows whole buffers
    again. A renderer that keeps a swapchain larger than the window through
    an interactive resize spares a new swapchain per step, and Mesa's round
    trip to the compositor with it. Applies with the next commit, as every
    surface state; a compositor without `wp_viewporter` reports
    `unsupported`, and buffers must then match the window.
    */
    WsiResult!void setBufferCrop(WindowId id, PhysicalSize shown)
    {
        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        ref slot = windows_.at(checked.value);
        const scale = slot.scale > 0 ? slot.scale : 1;
        const whole = shown.width == 0 || shown.height == 0;
        // Whole buffers are what a surface without a viewport shows: asking
        // for them costs nothing, viewporter or not.
        if (whole && slot.viewport is null)
            return wsiOk();
        if (whole ? slot.crop == PhysicalSize.init
            : shown == slot.crop && scale == slot.cropScale)
            return wsiOk();
        if (viewporter_ is null)
            return waylandFailure!void(WsiOperation.command, 0,
                "the compositor has no wp_viewporter", WsiErrorKind.unsupported);
        if (shown.width % scale || shown.height % scale)
            return waylandFailure!void(WsiOperation.command, 0,
                "a crop must be whole surface units", WsiErrorKind.invalidArgument);
        auto paused = pausePoll();
        if (paused.hasError)
            return paused;
        if (slot.viewport is null)
            slot.viewport = wp_viewporter_get_viewport(viewporter_, slot.surface);
        if (slot.viewport is null)
            return waylandFailure!void(WsiOperation.command, 0,
                "wp_viewporter.get_viewport failed");
        if (!whole)
        {
            const w = cast(int)(shown.width / scale), h = cast(int)(shown.height / scale);
            // Surface-local units, after the buffer scale: whole ones.
            wp_viewport_set_source(slot.viewport, 0, 0, w << 8, h << 8);
            wp_viewport_set_destination(slot.viewport, w, h);
        }
        else
        {
            wp_viewport_set_source(slot.viewport, -256, -256, -256, -256);
            wp_viewport_set_destination(slot.viewport, -1, -1);
        }
        slot.crop = whole ? PhysicalSize.init : shown;
        slot.cropScale = scale;
        return prepareAndArm();
    }

    // ── presentation feedback (`PRF13`) ─────────────────────────────────────

    /// Whether $(LREF requestPresentationFeedback) can answer: the
    /// compositor has `wp_presentation`.
    bool canReportPresentation() const @safe pure nothrow @nogc
        => presentation_ !is null;

    /**
    The compositor's presentation clock, a POSIX `clockid_t`, once it has
    said (it does as the global is bound, so by `bootstrapComplete`); `-1`
    before, and without `wp_presentation`. `CLOCK_MONOTONIC` (1) is
    `MonoTime`'s own; `CLOCK_MONOTONIC_RAW` (4, headless Weston's) and
    `CLOCK_BOOTTIME` (7) are converted to it; under any other a
    `PresentedEvent` has no `shown` time.
    */
    int presentationClock() const @safe pure nothrow @nogc
        => presentationClock_ == uint.max ? -1 : cast(int) presentationClock_;

    /**
    Asks when the surface's next commit reaches the display: a
    `PresentedEvent` carrying `tag` answers, once, with the time it was
    shown, the refresh interval and how (`zeroCopy`, `vsync`), or that it
    was discarded. The commit is whichever comes next on the window's
    surface — Vulkan's `vkQueuePresentKHR` makes it for a swapchain — so
    request it before the present, inside the native-I/O borrow if one is
    held. A compositor without `wp_presentation` reports `unsupported`;
    `maxPresentationFeedbacks` requests in flight report `capacity`.
    */
    WsiResult!void requestPresentationFeedback(WindowId id, ulong tag)
    {
        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        ref slot = windows_.at(checked.value);
        if (presentation_ is null)
            return waylandFailure!void(WsiOperation.command, 0,
                "the compositor has no wp_presentation", WsiErrorKind.unsupported);
        if (slot.surface is null)
            return waylandFailure!void(WsiOperation.command, 0,
                "the window has no wl_surface", WsiErrorKind.unavailable);
        size_t free = size_t.max;
        foreach (i, ref feedback; feedbacks_)
            if (feedback.proxy is null)
            {
                free = i;
                break;
            }
        if (free == size_t.max)
            return waylandFailure!void(WsiOperation.command, 0,
                "too many presentation feedback requests in flight",
                WsiErrorKind.capacity);
        auto paused = pausePoll();
        if (paused.hasError)
            return paused;
        ref entry = feedbacks_[free];
        entry.proxy = wp_presentation_feedback(presentation_, slot.surface);
        if (entry.proxy is null
            || wp_presentation_feedback_add_listener(entry.proxy,
                listenerPtr(presentationFeedbackListener), &entry) != 0)
        {
            if (entry.proxy !is null)
                wp_presentation_feedback_destroy(entry.proxy);
            entry = PendingFeedback.init;
            cast(void) prepareAndArm();
            return waylandFailure!void(WsiOperation.command, 0,
                "wp_presentation.feedback failed");
        }
        entry.owner = &this;
        entry.window = id;
        entry.tag = tag;
        return prepareAndArm();
    }

    private extern (C) static void onPresentationClock(void* data,
        wp_presentation*, uint clock) nothrow @nogc
    {
        (cast(WaylandWsi*) data).presentationClock_ = clock;
    }

    private extern (C) static void onFeedbackSyncOutput(void*,
        PresentationFeedback*, wl_output*) nothrow @nogc
    {
    }

    private extern (C) static void onFeedbackPresented(void* data,
        PresentationFeedback* proxy, uint secondsHigh, uint secondsLow,
        uint nanoseconds, uint refresh, uint sequenceHigh, uint sequenceLow,
        uint flags) nothrow @nogc
    {
        auto entry = cast(PendingFeedback*) data;
        PresentedEvent event = {
            tag: entry.tag,
            shown: shownOnMonoTime(entry.owner.presentationClock_,
                clockTime(secondsHigh, secondsLow, nanoseconds)),
            refreshNanoseconds: refresh,
            outputSequence: (ulong(sequenceHigh) << 32) | sequenceLow,
            flags: cast(PresentationFlags)(flags & 0xF),
        };
        answerFeedback(entry, proxy, event);
    }

    private extern (C) static void onFeedbackDiscarded(void* data,
        PresentationFeedback* proxy) nothrow @nogc
    {
        auto entry = cast(PendingFeedback*) data;
        answerFeedback(entry, proxy, PresentedEvent(tag: entry.tag, discarded: true));
    }

    // Both answers are the object's destructor events: it is freed here.
    private static void answerFeedback(PendingFeedback* entry,
        PresentationFeedback* proxy, in PresentedEvent event) nothrow @nogc
    {
        auto owner = entry.owner;
        const window = entry.window;
        wp_presentation_feedback_destroy(proxy);
        *entry = PendingFeedback.init;
        if (owner !is null && !owner.windows_.resolve(window).hasError)
            owner.emit(window, event);
    }

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
            owner.cancelRepeat();
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
        ref slot = windows_.at(checked.value);
        slot.cursorShape = shape;
        auto paused = pausePoll();
        if (paused.hasError)
            return paused;
        applyCursor(slot);
        return prepareAndArm();
    }

    /*
    F10 on Wayland: the compositor owns every grab, so explicit `capture`
    is honestly `unsupported`; `confine` is `pointer-constraints-v1`'s
    `confine_pointer` over the whole surface with a persistent lifetime
    (the compositor activates it while the pointer is over the surface and
    re-activates it after focus returns), and raw relative motion is
    `relative-pointer-v1`'s per-seat object, whose unaccelerated deltas go
    to the focused window that asked for them. Both die with the surface
    and with the seat's pointer.
    */

    /// Confines the pointer to the window's surface, or releases it;
    /// `capture` reports typed `unsupported`.
    WsiResult!void setPointerCapture(WindowId id, PointerCaptureMode mode)
    {
        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        ref slot = windows_.at(checked.value);
        if (mode == PointerCaptureMode.capture)
            return waylandFailure!void(WsiOperation.command, 0,
                "Wayland has no explicit pointer capture: the compositor owns grabs",
                WsiErrorKind.unsupported);
        if (mode == PointerCaptureMode.confine)
        {
            if (pointerConstraints_ is null)
                return waylandFailure!void(WsiOperation.command, 0,
                    "compositor lacks zwp_pointer_constraints_v1",
                    WsiErrorKind.unsupported);
            if (pointer_ is null)
                return waylandFailure!void(WsiOperation.command, 0,
                    "the seat has no pointer to confine",
                    WsiErrorKind.unavailable);
            if (slot.confined !is null)
                return wsiOk();
        }
        else if (slot.confined is null)
            return wsiOk();
        auto paused = pausePoll();
        if (paused.hasError)
            return paused;
        if (mode == PointerCaptureMode.confine)
        {
            slot.confined = zwp_pointer_constraints_v1_confine_pointer(
                pointerConstraints_, slot.surface, pointer_, null,
                ZWP_POINTER_CONSTRAINTS_V1_LIFETIME_PERSISTENT);
            if (slot.confined is null)
                remember(wsiError(WsiErrorKind.nativeFailure,
                    WsiOperation.command, BackendKind.wayland, 0,
                    "zwp_pointer_constraints_v1.confine_pointer failed"));
        }
        else
        {
            zwp_confined_pointer_v1_destroy(slot.confined);
            slot.confined = null;
        }
        auto rearmed = prepareAndArm();
        if (hasStickyError_)
            return wsiErr!void(stickyError_);
        return rearmed;
    }

    /// Routes the seat's unaccelerated motion to this window while it has
    /// pointer focus.
    WsiResult!void setRelativePointer(WindowId id, bool enabled)
    {
        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        if (relativePointerManager_ is null)
            return waylandFailure!void(WsiOperation.command, 0,
                "compositor lacks zwp_relative_pointer_manager_v1",
                WsiErrorKind.unsupported);
        if (enabled && pointer_ is null)
            return waylandFailure!void(WsiOperation.command, 0,
                "the seat has no pointer", WsiErrorKind.unavailable);
        windows_.at(checked.value).relative = enabled;
        bool anyRelative;
        foreach (h; windows_.byLive)
            anyRelative |= windows_[h].relative;
        if (anyRelative == (relativePointer_ !is null))
            return wsiOk();
        auto paused = pausePoll();
        if (paused.hasError)
            return paused;
        if (anyRelative)
        {
            relativePointer_ =
                zwp_relative_pointer_manager_v1_get_relative_pointer(
                    relativePointerManager_, pointer_);
            if (relativePointer_ is null
                || zwp_relative_pointer_v1_add_listener(relativePointer_,
                    listenerPtr(relativePointerListener), &this) != 0)
                remember(wsiError(WsiErrorKind.nativeFailure,
                    WsiOperation.command, BackendKind.wayland, 0,
                    "failed to create the relative pointer"));
        }
        else
        {
            zwp_relative_pointer_v1_destroy(relativePointer_);
            relativePointer_ = null;
        }
        auto rearmed = prepareAndArm();
        if (hasStickyError_)
            return wsiErr!void(stickyError_);
        return rearmed;
    }

    private extern (C) static void onRelativeMotion(void* data,
        zwp_relative_pointer_v1*, uint, uint, wl_fixed_t, wl_fixed_t,
        wl_fixed_t dxUnaccel, wl_fixed_t dyUnaccel) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        const index = owner.indexOfSurface(owner.pointerFocus_);
        if (index == size_t.max || !owner.windows_.at(index).relative)
            return;
        owner.emit(owner.idAt(index), RelativePointerEvent(seatPointer,
            wl_fixed_to_double(dxUnaccel), wl_fixed_to_double(dyUnaccel),
            true));
    }

    /// Visibility uses the core null-surface cursor, so it works with or
    /// without the shape protocol.
    WsiResult!void setCursorVisible(WindowId id, bool visible)
    {
        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        ref slot = windows_.at(checked.value);
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
            case PointerShape.nwseResize:
                return WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NWSE_RESIZE;
            case PointerShape.neswResize:
                return WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NESW_RESIZE;
        }
    }

    private void releasePointer() nothrow @nogc
    {
        if (pointer_ is null)
            return;
        // Constraints and the relative pointer name this wl_pointer.
        if (relativePointer_ !is null)
        {
            zwp_relative_pointer_v1_destroy(relativePointer_);
            relativePointer_ = null;
        }
        foreach (h; windows_.byLive)
            if (windows_[h].confined !is null)
            {
                zwp_confined_pointer_v1_destroy(windows_[h].confined);
                windows_[h].confined = null;
            }
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
    private enum seatPointer = PointerId(0, 1);

    /// A surface-local logical position in the buffer's pixels at its
    /// integer `scale`: floored, so a grab's position left of the surface
    /// stays left of it.
    private static PhysicalPosition physicalAt(LogicalPosition p, int scale) @safe pure nothrow @nogc
    {
        import std.math : floor;

        return PhysicalPosition(cast(int) floor(p.x * scale), cast(int) floor(p.y * scale));
    }

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
        event.physicalPosition = physicalAt(pointerPosition_, windows_.at(index).scale);
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
            owner.applyCursor(owner.windows_.at(index));
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
        uint serial, uint, uint button, uint state) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        if (state != 0)
        {
            owner.pointerButtonSerial_ = serial;
            owner.inputSerial_ = serial;
        }
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
            scroll.physicalPosition = physicalAt(owner.pointerPosition_,
                owner.windows_.at(index).scale);
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

    /// Queues the text evdev `key` types under the current modifiers and
    /// layout. A key an input method consumes never reaches `wl_keyboard`,
    /// so every key seen here is one nothing else typed.
    private void emitTypedText(WindowId id, uint key) nothrow @nogc
    {
        if (xkbState_ is null)
            return;
        char[64] utf8 = void;
        const n = xkb_state_key_get_utf8(xkbState_, key + 8, utf8.ptr, utf8.length);
        if (n <= 0 || n >= utf8.length)
            return;
        if (const text = xkbTypedText(utf8[0 .. n]))
            emitText(id, text, (TextId committed, size_t kept) => TextCommittedEvent(committed));
    }

    private extern (C) static void onKeyboardEnter(void* data,
        wl_keyboard*, uint serial, wl_surface* surface, wl_array*) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        owner.inputSerial_ = serial;
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
        {
            owner.keyboardFocus_ = null;
            owner.cancelRepeat();
        }
        const index = owner.indexOfSurface(surface);
        if (index != size_t.max)
            owner.emit(owner.idAt(index), FocusChangedEvent(false));
    }

    private extern (C) static void onKeyboardKey(void* data, wl_keyboard*,
        uint serial, uint, uint key, uint state) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        owner.inputSerial_ = serial;
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
        if (state != 0)
        {
            owner.emitTypedText(owner.idAt(index), key);
            // Wayland never repeats on the wire (wl_keyboard.key is one
            // press); the client synthesizes repeats for the most recently
            // pressed repeating key, per the compositor's repeat_info.
            if (owner.shouldRepeatKey(key))
                owner.scheduleRepeat(key, first: true);
        }
        else if (key == owner.repeatKey_)
            owner.cancelRepeat();
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

    private enum uint noRepeatKey = uint.max;

    private bool shouldRepeatKey(uint key) nothrow @nogc
        => repeatsEnabled(keyRepeatRate_, keyRepeatDelayMs_)
            && xkbKeymap_ !is null
            && xkb_keymap_key_repeats(xkbKeymap_, key + 8) != 0;

    /*
    Repeat synthesis keeps at most one timer op in flight. Retargeting (a
    new repeating press) or stopping (release/leave) cancels the in-flight
    op; its terminal completion either re-arms for the new schedule or goes
    quiet, so a stale completion can never masquerade as a live timer and
    teardown has exactly one op to reap.
    */

    private void scheduleRepeat(uint key, bool first) nothrow @nogc
    {
        repeatKey_ = key;
        repeatFirstFire_ = first;
        if (repeatInFlight_)
        {
            if (loop_ !is null)
                loop_.cancel(repeatTimer_);
            return;
        }
        armRepeatOp();
    }

    private void cancelRepeat() nothrow @nogc
    {
        repeatKey_ = noRepeatKey;
        if (repeatInFlight_ && loop_ !is null)
            loop_.cancel(repeatTimer_);
    }

    private void armRepeatOp() nothrow @nogc
    {
        if (loop_ is null || detaching_ || repeatKey_ == noRepeatKey)
            return;
        const rel = repeatFirstFire_
            ? msecs(keyRepeatDelayMs_) : repeatInterval(keyRepeatRate_);
        auto armed = loop_.submitAfter(rel, &onRepeatTimer, &this);
        if (armed.hasError)
        {
            // Repeat is an enhancement: degrade to no synthesis rather
            // than poisoning the connection with a sticky error.
            repeatKey_ = noRepeatKey;
            return;
        }
        repeatTimer_ = armed.value;
        repeatInFlight_ = true;
    }

    private static void onRepeatTimer(void* ctx, ref Completion done)
        nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) ctx;
        owner.repeatInFlight_ = false;
        if (owner.repeatKey_ == noRepeatKey)
            return; // released or left while the op was in flight
        if (done.res != 0)
        {
            owner.armRepeatOp(); // retargeted: arm the new schedule
            return;
        }
        owner.fireRepeat();
    }

    private void fireRepeat() nothrow @nogc
    {
        const index = indexOfSurface(keyboardFocus_);
        if (index == size_t.max)
        {
            repeatKey_ = noRepeatKey;
            return;
        }
        KeyboardEvent event;
        event.physical = PhysicalKey(repeatKey_, 0);
        event.logical = logicalForKey(repeatKey_);
        event.location = evdevKeyLocation(repeatKey_);
        event.action = KeyAction.repeat;
        event.modifiers = keyboardMods_;
        emit(idAt(index), event);
        emitTypedText(idAt(index), repeatKey_);
        repeatFirstFire_ = false;
        armRepeatOp();
    }

    /*
    text-input-v3 is double-buffered: preedit/commit/delete events stash
    pending state and `done` applies one atomic batch (fields not sent in a
    cycle reset to empty). This window layer plays the always-enabled role
    IMM32 already plays on Win32 — enable on the compositor's enter, disable
    on leave — until an explicit per-window text-input opt-in API exists.
    */

    private extern (C) static void onTextInputEnter(void* data,
        zwp_text_input_v3* textInput, wl_surface* surface) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        owner.textInputFocus_ = surface;
        zwp_text_input_v3_enable(textInput);
        zwp_text_input_v3_commit(textInput);
    }

    private extern (C) static void onTextInputLeave(void* data,
        zwp_text_input_v3* textInput, wl_surface* surface) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        zwp_text_input_v3_disable(textInput);
        zwp_text_input_v3_commit(textInput);
        if (owner.compositionActive_)
        {
            const index = owner.indexOfSurface(surface);
            if (index != size_t.max)
                owner.emit(owner.idAt(index), CompositionEvent());
            owner.compositionActive_ = false;
        }
        if (owner.textInputFocus_ is surface)
            owner.textInputFocus_ = null;
        owner.pendingText_.reset();
    }

    private extern (C) static void onTextInputPreedit(void* data,
        zwp_text_input_v3*, const(char)* text, int cursorBegin,
        int cursorEnd) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        stage(owner.pendingText_.preedit, text);
        owner.pendingText_.cursorBegin = cursorBegin;
        owner.pendingText_.cursorEnd = cursorEnd;
    }

    private extern (C) static void onTextInputCommit(void* data,
        zwp_text_input_v3*, const(char)* text) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        stage(owner.pendingText_.commit, text);
    }

    private extern (C) static void onTextInputDelete(void* data,
        zwp_text_input_v3*, uint beforeLength, uint afterLength)
        nothrow @nogc
    {
        // Surrounding-text deletion needs a vocabulary event of its own;
        // stash it so the batch shape is complete when that lands.
        auto owner = cast(WaylandWsi*) data;
        owner.pendingText_.deleteBefore = beforeLength;
        owner.pendingText_.deleteAfter = afterLength;
    }

    private extern (C) static void onTextInputDone(void* data,
        zwp_text_input_v3*, uint) nothrow @nogc
    {
        auto owner = cast(WaylandWsi*) data;
        const batch = textInputBatch(owner.pendingText_,
            owner.compositionActive_);
        owner.compositionActive_ = batch.compositionActiveAfter;
        scope (exit)
            owner.pendingText_.reset();
        const index = owner.indexOfSurface(owner.textInputFocus_);
        if (index == size_t.max)
            return;
        const id = owner.idAt(index);
        if (batch.emitCommit)
            owner.emitText(id, owner.pendingText_.commit[],
                (TextId text, size_t kept) => TextCommittedEvent(text));
        if (batch.emitComposition)
            owner.emitText(id, owner.pendingText_.preedit[],
                (TextId text, size_t kept) {
                    CompositionEvent event = batch.composition;
                    event.preedit = text;
                    event.clampTo(kept);
                    return event;
                });
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
        // A floating window's size is the one a configure that leaves the
        // size to the client (0 × 0) keeps: Weston's at the end of a resize,
        // which went back to the size the window opened at, and any
        // compositor's on restoring a maximized window.
        if (!slot.pendingState.edgesHeld)
            slot.requestedSize = LogicalSize(width, height);
        // The configure sizes the window; the surface is it and the margin
        // the new state keeps.
        slot.windowSize = LogicalSize(width, height);
        owner.placeWindow(*slot, slot.pendingState);
        const metrics = metricsFor(*slot, slot.windowSize, slot.pendingState);
        const index = owner.indexOfSlot(slot);
        if (index == size_t.max)
            return;
        const id = owner.idAt(index);

        // The frame first: an application insetting its content for its own
        // title bar lays out against the metrics that follow.
        if (!slot.stateReported || slot.pendingState != slot.state)
        {
            slot.state = slot.pendingState;
            slot.stateReported = true;
            owner.emit(id, WindowStateChangedEvent(slot.state));
        }

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
        xdg_toplevel*, int width, int height, wl_array* states) nothrow @nogc
    {
        auto slot = cast(Slot*) data;
        slot.pendingWidth = width;
        slot.pendingHeight = height;
        slot.pendingState.flags = toplevelFlags(arrayWords(states));
    }

    private extern (C) static void onDecorationConfigure(void* data,
        zxdg_toplevel_decoration_v1*, uint mode) nothrow @nogc
    {
        auto slot = cast(Slot*) data;
        // A window that draws no frame and is left one to draw draws none;
        // one the compositor decorates anyway is decorated.
        slot.pendingState.decorations =
            mode == ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE ? DecorationMode.server
                : slot.noFrame ? DecorationMode.none : DecorationMode.client;
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

    private extern (C) static void onToplevelConfigureBounds(void* data,
        xdg_toplevel*, int width, int height) nothrow @nogc
    {
        auto slot = cast(Slot*) data;
        static ushort side(int v) => cast(ushort)(v <= 0 ? 0 : v > ushort.max ? ushort.max : v);
        slot.pendingState.boundsWidth = side(width);
        slot.pendingState.boundsHeight = side(height);
    }

    private extern (C) static void onToplevelWmCapabilities(void* data,
        xdg_toplevel*, wl_array* capabilities) nothrow @nogc
    {
        auto slot = cast(Slot*) data;
        slot.pendingState.capabilities = windowCapabilities(arrayWords(capabilities));
    }

    private extern (C) static void onFrameDone(void* data,
        wl_callback* callback, uint) nothrow @nogc
    {
        auto slot = cast(Slot*) data;
        auto owner = slot.owner;
        wl_callback_destroy(callback);
        slot.frameCallback = null;
        const index = owner.indexOfSlot(slot);
        if (index == size_t.max || !owner.windows_.liveAt(index))
            return;
        owner.emit(owner.idAt(index), FrameReadyEvent(
            owner.nextFrameToken_++, 0));
        owner.armFrameCallback(*slot);
    }

    private void armFrameCallback(ref Slot slot) nothrow @nogc
    {
        if (slot.surface is null || slot.frameCallback !is null)
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
private immutable zxdg_toplevel_decoration_v1_listener decorationListener = {
    &WaylandWsi.onDecorationConfigure
};
private immutable wp_presentation_listener presentationListener = {
    &WaylandWsi.onPresentationClock
};
private immutable wp_presentation_feedback_listener presentationFeedbackListener = {
    &WaylandWsi.onFeedbackSyncOutput, &WaylandWsi.onFeedbackPresented,
    &WaylandWsi.onFeedbackDiscarded
};
private immutable wl_callback_listener frameListener = {
    &WaylandWsi.onFrameDone
};
private immutable wl_callback_listener selectionSyncListener = {
    &WaylandWsi.onSelectionSync
};

// The last connection number given out in this process (`WaylandWsi.instance_`).
private shared uint nextInstance;
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
private immutable zwp_relative_pointer_v1_listener relativePointerListener = {
    &WaylandWsi.onRelativeMotion
};
private immutable zwp_text_input_v3_listener textInputListener = {
    &WaylandWsi.onTextInputEnter, &WaylandWsi.onTextInputLeave,
    &WaylandWsi.onTextInputPreedit, &WaylandWsi.onTextInputCommit,
    &WaylandWsi.onTextInputDelete, &WaylandWsi.onTextInputDone
};
private immutable wl_keyboard_listener keyboardListener = {
    &WaylandWsi.onKeyboardKeymap, &WaylandWsi.onKeyboardEnter,
    &WaylandWsi.onKeyboardLeave, &WaylandWsi.onKeyboardKey,
    &WaylandWsi.onKeyboardModifiers, &WaylandWsi.onKeyboardRepeatInfo
};

/**
One text-input-v3 batch, stashed between events and applied on `done`. The
texts are owned copies: the compositor's strings are borrowed only for the
event that carries them, and `done` arrives later.
*/
struct PendingTextInput
{
    UniqueBuffer!(char, 512) preedit;
    UniqueBuffer!(char, 256) commit;
    int cursorBegin = -1;
    int cursorEnd = -1;
    uint deleteBefore;
    uint deleteAfter;

    /// Back to the empty batch, keeping any storage already grown.
    void reset() @safe pure nothrow @nogc
    {
        preedit.clear(releaseStorage: false);
        commit.clear(releaseStorage: false);
        cursorBegin = cursorEnd = -1;
        deleteBefore = deleteAfter = 0;
    }
}

/**
Copies a compositor string into `staged`, keeping one byte more than
`maxEventText`: enough for the queue to see the text was longer, cut it at a
code-point boundary and flag it (`ED8`), without staging an unbounded string.
*/
private void stage(Staged)(ref Staged staged,
    const(char)* text) nothrow @nogc
{
    staged.clear(releaseStorage: false);
    if (text is null)
        return;
    const span = text.spanFromZ;
    staged ~= span[0 .. span.length <= maxEventText ? span.length : maxEventText + 1];
}

/// Borrow a NUL-terminated C string as a span (never null).
private const(char)[] spanFromZ(const(char)* text) @system nothrow @nogc
    => text[0 .. strlen(text)];

/**
Maps one applied pre-edit batch to the shared composition vocabulary:
`cursor_begin`/`cursor_end` are byte offsets into the pre-edit (`-1` hides
the cursor — mapped to the end, where new text lands), an ordered non-empty
range is the selection, and the whole pre-edit carries the conventional
underline segment (text-input-v3 has no per-segment attributes).

The text itself is not in the result: the queue stores it and names it in
`preedit` (`ED8`), clamping these offsets to what it kept.
*/
CompositionEvent compositionFromPreedit(scope const(char)[] preedit,
    int cursorBegin, int cursorEnd) @safe pure nothrow @nogc
{
    CompositionEvent event;
    const int length = cast(int)(preedit.length < maxEventText
        ? preedit.length : maxEventText);
    const begin = cursorBegin >= 0
        ? (cursorBegin < length ? cursorBegin : length) : length;
    event.cursor = cast(ushort) begin;
    if (cursorBegin >= 0 && cursorEnd > cursorBegin && cursorBegin < length)
    {
        const end = cursorEnd < length ? cursorEnd : length;
        event.selectionStart = cast(ushort) cursorBegin;
        event.selectionLength = cast(ushort) (end - cursorBegin);
    }
    if (length != 0)
    {
        event.segments[0] = CompositionSegment(0,
            cast(ushort) length, CompositionSegmentStyle.underline);
        event.segmentCount = 1;
    }
    return event;
}

/// What one applied `done` batch emits, in protocol order. The texts stay in
/// the pending batch until they are queued.
struct TextInputBatch
{
    bool emitCommit;
    bool emitComposition;
    CompositionEvent composition;
    bool compositionActiveAfter;
}

/**
Applies text-input-v3's `done` semantics to one pending batch: the commit
string is inserted before the new pre-edit replaces the old one, fields
not sent in the cycle are empty, and an empty pre-edit ends an active
composition with exactly one empty `CompositionEvent` — never a stream of
them while no composition is active.
*/
TextInputBatch textInputBatch(in PendingTextInput pending,
    bool compositionActive) @safe pure nothrow @nogc
{
    TextInputBatch batch;
    batch.emitCommit = pending.commit.length != 0;
    if (pending.preedit.length != 0)
    {
        batch.emitComposition = true;
        batch.composition = compositionFromPreedit(pending.preedit[],
            pending.cursorBegin, pending.cursorEnd);
        batch.compositionActiveAfter = true;
    }
    else if (compositionActive)
        batch.emitComposition = true;
    return batch;
}

@("wsi.wayland.textInputBatch.commitThenPreeditAndSingleEnd")
@safe pure nothrow @nogc
unittest
{
    // Mid-composition batch: pre-edit only.
    PendingTextInput typing;
    typing.preedit ~= "に";
    typing.cursorBegin = 3;
    typing.cursorEnd = 3;
    const mid = textInputBatch(typing, false);
    assert(!mid.emitCommit && mid.emitComposition);
    assert(mid.compositionActiveAfter);

    // Conversion accepted: commit lands and the composition ends in the
    // same batch — the empty composition event tells the window so.
    PendingTextInput accepted;
    accepted.commit ~= "日本";
    const done = textInputBatch(accepted, true);
    assert(done.emitCommit);
    assert(done.emitComposition && done.composition.segmentCount == 0);
    assert(!done.compositionActiveAfter);

    // A done with nothing pending and no active composition is silent.
    const idle = textInputBatch(PendingTextInput(), false);
    assert(!idle.emitCommit && !idle.emitComposition);

    accepted.reset();
    assert(accepted.commit.length == 0 && accepted.cursorBegin == -1);
}

@("wsi.wayland.compositionFromPreedit.cursorSelectionAndUnderline")
@safe pure nothrow @nogc
unittest
{
    // A visible cursor between the bytes of a multi-byte pre-edit.
    const plain = compositionFromPreedit("にほん", 3, 3);
    assert(plain.cursor == 3 && plain.selectionLength == 0);
    assert(plain.segmentCount == 1);
    assert(plain.segments[0] == CompositionSegment(0, 9,
        CompositionSegmentStyle.underline));

    // An ordered cursor range is the selection; out-of-range ends clamp.
    const selected = compositionFromPreedit("abcd", 1, 99);
    assert(selected.selectionStart == 1 && selected.selectionLength == 3);

    // A hidden cursor (-1) lands at the end, where new text is inserted.
    const hidden = compositionFromPreedit("ab", -1, -1);
    assert(hidden.cursor == 2 && hidden.selectionLength == 0);

    // An empty pre-edit is the composition-ended shape: no segments.
    const ended = compositionFromPreedit("", 0, 0);
    assert(ended.segmentCount == 0);
}

/**
Whether `wl_keyboard.repeat_info` enables client-side repeat: `rate` is
repeats per second and zero disables repeat entirely; a negative delay is
not a schedule.
*/
bool repeatsEnabled(int rate, int delayMs) @safe pure nothrow @nogc
    => rate > 0 && delayMs >= 0;

/// The steady interval between synthesized repeats; never rounds to zero.
Duration repeatInterval(int rate) @safe pure nothrow @nogc
in (rate > 0)
    => msecs(1000 / rate > 0 ? 1000 / rate : 1);

@("wsi.wayland.repeatSchedule.repeatInfoGatesAndNeverZero")
@safe pure nothrow @nogc
unittest
{
    // Weston's defaults: 40 repeats/s after 400 ms.
    assert(repeatsEnabled(40, 400));
    assert(repeatInterval(40) == msecs(25));
    // rate 0 is the protocol's "repeat disabled"; negative delay is bogus.
    assert(!repeatsEnabled(0, 400));
    assert(!repeatsEnabled(-1, 400));
    assert(!repeatsEnabled(40, -1));
    // An immediate-delay schedule is legal, and a >1000/s rate still ticks.
    assert(repeatsEnabled(40, 0));
    assert(repeatInterval(2000) == msecs(1));
}

@("wsi.wayland.pendingOffer.markerJudgedBeforeTheTypeCap")
@system unittest
{
    alias PendingOffer = WaylandWsi.PendingOffer;
    enum mimes = [
        "text/plain", "text/html", "image/png", "image/jpeg",
        "application/json", "text/csv", "application/pdf", "audio/wav",
    ];
    static assert(mimes.length == maxOfferTypes);
    static const(char)[] markerOf(ref char[64] buf, uint instance, uint number)
        => WaylandWsi.ownMarker(buf, instance, number);

    // A full own offer: eight application types, the marker last (as
    // `setSelection` offers it). The marker still owns the offer.
    PendingOffer p;
    foreach (m; mimes)
        p.noteType(m, 1, 2);
    assert(p.count == maxOfferTypes && !p.own);
    char[64] buf;
    p.noteType(markerOf(buf, 1, 2), 1, 2);
    assert(p.own && !p.stale, "the marker after the cap still classifies");
    assert(p.count == maxOfferTypes, "and never counted toward it");
    p.noteType("video/mp4", 1, 2);
    assert(p.count == maxOfferTypes, "a ninth type is dropped");

    // The marker first does not spend a type slot either.
    p.reset();
    p.noteType(markerOf(buf, 1, 2), 1, 2);
    foreach (m; mimes)
        p.noteType(m, 1, 2);
    assert(p.own && p.count == maxOfferTypes);

    // An earlier source of this connection is stale; another connection's
    // marker in the same process is neither own nor stale.
    p.reset();
    p.noteType(markerOf(buf, 1, 1), 1, 2);
    assert(!p.own && p.stale);
    p.reset();
    p.noteType(markerOf(buf, 2, 2), 1, 2);
    assert(!p.own && !p.stale);

    // Normalization and dedup ride along: the X name is the one MIME type,
    // a repeat and a non-MIME name take no slot.
    p.reset();
    p.noteType("UTF8_STRING", 1, 2);
    p.noteType("text/plain;charset=utf-8", 1, 2);
    p.noteType("STRING", 1, 2);
    assert(p.count == 1 && p.types[0][] == "text/plain;charset=utf-8");
}

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

private wl_region* wl_compositor_create_region()(wl_compositor* self)
    => cast(wl_region*) wl_proxy_marshal_flags(cast(wl_proxy*) self,
        WL_COMPOSITOR_CREATE_REGION, &wl_region_interface,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, cast(void*) null);

private void wl_region_add()(wl_region* self, int x, int y, int width, int height)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, WL_REGION_ADD, null,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, x, y, width, height);
}

private void wl_region_destroy()(wl_region* self)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, WL_REGION_DESTROY, null,
        wl_proxy_get_version(cast(wl_proxy*) self), WL_MARSHAL_FLAG_DESTROY);
}

private void wl_surface_set_input_region()(wl_surface* self, wl_region* region)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, WL_SURFACE_SET_INPUT_REGION, null,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, region);
}

private void wl_surface_set_opaque_region()(wl_surface* self, wl_region* region)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, WL_SURFACE_SET_OPAQUE_REGION, null,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, region);
}

private void xdg_surface_set_window_geometry()(xdg_surface* self, int x, int y, int width,
    int height)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, XDG_SURFACE_SET_WINDOW_GEOMETRY, null,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, x, y, width, height);
}

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

private void xdg_toplevel_move()(xdg_toplevel* self, wl_seat* seat,
        uint serial)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, XDG_TOPLEVEL_MOVE, null,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, seat, serial);
}

private void xdg_toplevel_resize()(xdg_toplevel* self, wl_seat* seat,
        uint serial, uint edges)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, XDG_TOPLEVEL_RESIZE, null,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, seat, serial, edges);
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

private void xdg_toplevel_set_minimized()(xdg_toplevel* self)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, XDG_TOPLEVEL_SET_MINIMIZED, null,
        wl_proxy_get_version(cast(wl_proxy*) self), 0);
}

private void xdg_toplevel_show_window_menu()(xdg_toplevel* self, wl_seat* seat,
    uint serial, int x, int y)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, XDG_TOPLEVEL_SHOW_WINDOW_MENU, null,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, seat, serial, x, y);
}

private zxdg_toplevel_decoration_v1* zxdg_decoration_manager_v1_get_toplevel_decoration()(
        zxdg_decoration_manager_v1* self, xdg_toplevel* toplevel)
    => cast(zxdg_toplevel_decoration_v1*) wl_proxy_marshal_flags(cast(wl_proxy*) self,
        ZXDG_DECORATION_MANAGER_V1_GET_TOPLEVEL_DECORATION,
        &zxdg_toplevel_decoration_v1_interface,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, cast(void*) null, toplevel);

// `wp_presentation_feedback` names both the C struct and the request that
// makes one; the request's D transcription below shadows the name, so the
// struct is reached through the C request's return type.
private alias PresentationFeedback = typeof(*wayland_native.wp_presentation_feedback(null, null));

private int wp_presentation_add_listener()(wp_presentation* self,
        const(wp_presentation_listener)* listener, void* data)
    => wl_proxy_add_listener(cast(wl_proxy*) self,
        cast(ListenerImpl) listener, data);

private void wp_presentation_destroy()(wp_presentation* self)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, WP_PRESENTATION_DESTROY, null,
        wl_proxy_get_version(cast(wl_proxy*) self), WL_MARSHAL_FLAG_DESTROY);
}

private PresentationFeedback* wp_presentation_feedback()(wp_presentation* self,
        wl_surface* surface)
    => cast(PresentationFeedback*) wl_proxy_marshal_flags(cast(wl_proxy*) self,
        WP_PRESENTATION_FEEDBACK, &wp_presentation_feedback_interface,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, surface, cast(void*) null);

private int wp_presentation_feedback_add_listener()(PresentationFeedback* self,
        const(wp_presentation_feedback_listener)* listener, void* data)
    => wl_proxy_add_listener(cast(wl_proxy*) self,
        cast(ListenerImpl) listener, data);

private void wp_presentation_feedback_destroy()(PresentationFeedback* self)
    => wl_proxy_destroy(cast(wl_proxy*) self);

/// A presentation timestamp, as the protocol splits it, from its clock's zero.
private Duration clockTime(uint secondsHigh, uint secondsLow, uint nanoseconds)
    @safe pure nothrow @nogc
{
    const whole = (ulong(secondsHigh) << 32) | secondsLow;
    return (cast(long) whole).seconds + (cast(long) nanoseconds).nsecs;
}

/*
A presentation time on clock `clock` as a `MonoTime`, or `MonoTime.init`.

`CLOCK_MONOTONIC` is the clock `MonoTime` reads on Linux, so its times convert
exactly (as Android's frame times are converted). `CLOCK_MONOTONIC_RAW` runs
unslewed and `CLOCK_BOOTTIME` also counts suspend, so each differs from it by
an offset that moves only slowly (NTP's slew, at most 500 ppm) or across a
suspend: the offset is sampled as the time arrives, between two `MonoTime`
reads, and a time a frame or two old converts within microseconds. Any other
clock — `CLOCK_REALTIME` steps — is reported unknown.
*/
private MonoTime shownOnMonoTime(uint clock, Duration shown) @safe nothrow @nogc
{
    if (clock == CLOCK_MONOTONIC)
        return MonoTime.zero + shown;
    if (clock != CLOCK_MONOTONIC_RAW && clock != CLOCK_BOOTTIME)
        return MonoTime.init;
    timespec ts;
    const before = MonoTime.currTime;
    if ((() @trusted => clock_gettime(cast(int) clock, &ts))() != 0)
        return MonoTime.init;
    const after = MonoTime.currTime;
    return onMonoTime(shown, ts.tv_sec.seconds + ts.tv_nsec.nsecs,
        before + (after - before) / 2);
}

/// `shown`, on a clock that read `clockNow` when `MonoTime` read `now`.
private MonoTime onMonoTime(Duration shown, Duration clockNow, MonoTime now)
    @safe pure nothrow @nogc
    => now - (clockNow - shown);

@("wsi.wayland.presentationTimesAreOnMonoTime")
@safe nothrow @nogc
unittest
{
    import core.sys.posix.time : CLOCK_REALTIME;

    assert(clockTime(0, 12, 345) == 12.seconds + 300.nsecs, "Duration keeps hnsecs");
    assert(clockTime(1, 0, 0) == (1L << 32).seconds);
    // A clock 10 s ahead of `MonoTime`'s: its time 3 ms ago is `now` - 3 ms.
    const now = MonoTime.zero + 100.seconds;
    assert(onMonoTime(110.seconds - 3.msecs, 110.seconds, now) == now - 3.msecs);

    // `CLOCK_MONOTONIC` is `MonoTime`'s; the raw clock converts within a
    // millisecond (here, a reading just taken); `CLOCK_REALTIME` does not.
    const at = MonoTime.currTime;
    assert(shownOnMonoTime(CLOCK_MONOTONIC, at - MonoTime.zero) - at < 1.usecs);
    assert(shownOnMonoTime(CLOCK_REALTIME, 1.seconds) == MonoTime.init);
    timespec raw;
    () @trusted { clock_gettime(CLOCK_MONOTONIC_RAW, &raw); }();
    const converted = shownOnMonoTime(CLOCK_MONOTONIC_RAW,
        raw.tv_sec.seconds + raw.tv_nsec.nsecs);
    const later = MonoTime.currTime;
    assert(converted >= at - 1.msecs && converted <= later + 1.msecs);
}

private void wp_viewporter_destroy()(wp_viewporter* self)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, WP_VIEWPORTER_DESTROY, null,
        wl_proxy_get_version(cast(wl_proxy*) self), WL_MARSHAL_FLAG_DESTROY);
}

private wp_viewport* wp_viewporter_get_viewport()(wp_viewporter* self, wl_surface* surface)
    => cast(wp_viewport*) wl_proxy_marshal_flags(cast(wl_proxy*) self,
        WP_VIEWPORTER_GET_VIEWPORT, &wp_viewport_interface,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, cast(void*) null, surface);

private void wp_viewport_destroy()(wp_viewport* self)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, WP_VIEWPORT_DESTROY, null,
        wl_proxy_get_version(cast(wl_proxy*) self), WL_MARSHAL_FLAG_DESTROY);
}

// `x`, `y`, `width` and `height` are `wl_fixed_t`: 24.8 fixed point.
private void wp_viewport_set_source()(wp_viewport* self, int x, int y, int width, int height)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, WP_VIEWPORT_SET_SOURCE, null,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, x, y, width, height);
}

private void wp_viewport_set_destination()(wp_viewport* self, int width, int height)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, WP_VIEWPORT_SET_DESTINATION, null,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, width, height);
}

private void zxdg_decoration_manager_v1_destroy()(zxdg_decoration_manager_v1* self)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, ZXDG_DECORATION_MANAGER_V1_DESTROY, null,
        wl_proxy_get_version(cast(wl_proxy*) self), WL_MARSHAL_FLAG_DESTROY);
}

private int zxdg_toplevel_decoration_v1_add_listener()(zxdg_toplevel_decoration_v1* self,
        const(zxdg_toplevel_decoration_v1_listener)* listener, void* data)
    => wl_proxy_add_listener(cast(wl_proxy*) self, cast(ListenerImpl) listener, data);

private void zxdg_toplevel_decoration_v1_set_mode()(zxdg_toplevel_decoration_v1* self,
    uint mode)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, ZXDG_TOPLEVEL_DECORATION_V1_SET_MODE, null,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, mode);
}

private void zxdg_toplevel_decoration_v1_destroy()(zxdg_toplevel_decoration_v1* self)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, ZXDG_TOPLEVEL_DECORATION_V1_DESTROY, null,
        wl_proxy_get_version(cast(wl_proxy*) self), WL_MARSHAL_FLAG_DESTROY);
}

/// A `wl_array` of protocol `uint`s as a slice, valid for the event.
private const(uint)[] arrayWords(const(wl_array)* a) @trusted pure nothrow @nogc
    => a is null || a.data is null ? null
        : (cast(const(uint)*) a.data)[0 .. a.size / uint.sizeof];

/// `xdg_toplevel.configure`'s states as $(LREF ToplevelState) bits; states
/// a newer compositor adds are ignored.
private ushort toplevelFlags(const(uint)[] states) @safe pure nothrow @nogc
{
    ushort flags;
    foreach (st; states)
        switch (st)
        {
            case XDG_TOPLEVEL_STATE_MAXIMIZED: flags |= ToplevelState.maximized; break;
            case XDG_TOPLEVEL_STATE_FULLSCREEN: flags |= ToplevelState.fullscreen; break;
            case XDG_TOPLEVEL_STATE_RESIZING: flags |= ToplevelState.resizing; break;
            case XDG_TOPLEVEL_STATE_ACTIVATED: flags |= ToplevelState.activated; break;
            case XDG_TOPLEVEL_STATE_TILED_LEFT: flags |= ToplevelState.tiledLeft; break;
            case XDG_TOPLEVEL_STATE_TILED_RIGHT: flags |= ToplevelState.tiledRight; break;
            case XDG_TOPLEVEL_STATE_TILED_TOP: flags |= ToplevelState.tiledTop; break;
            case XDG_TOPLEVEL_STATE_TILED_BOTTOM: flags |= ToplevelState.tiledBottom; break;
            case XDG_TOPLEVEL_STATE_SUSPENDED: flags |= ToplevelState.suspended; break;
            default: break;
        }
    return flags;
}

@("wsi.wayland.toplevelFlags.knownStatesOnly")
@safe pure nothrow @nogc
unittest
{
    static immutable uint[] states = [XDG_TOPLEVEL_STATE_ACTIVATED,
        XDG_TOPLEVEL_STATE_TILED_LEFT, 99];
    assert(toplevelFlags(states) == (ToplevelState.activated | ToplevelState.tiledLeft));
    assert(toplevelFlags(null) == 0);
}

/// `xdg_toplevel.wm_capabilities` as $(LREF WindowCapability) bits. An empty
/// list is the protocol's "none offered", not "unknown".
private ubyte windowCapabilities(const(uint)[] caps) @safe pure nothrow @nogc
{
    ubyte bits;
    foreach (c; caps)
        switch (c)
        {
            case XDG_TOPLEVEL_WM_CAPABILITIES_WINDOW_MENU: bits |= WindowCapability.windowMenu; break;
            case XDG_TOPLEVEL_WM_CAPABILITIES_MAXIMIZE: bits |= WindowCapability.maximize; break;
            case XDG_TOPLEVEL_WM_CAPABILITIES_FULLSCREEN: bits |= WindowCapability.fullscreen; break;
            case XDG_TOPLEVEL_WM_CAPABILITIES_MINIMIZE: bits |= WindowCapability.minimize; break;
            default: break;
        }
    return bits;
}

@("wsi.wayland.windowCapabilities.emptyMeansNone")
@safe pure nothrow @nogc
unittest
{
    static immutable uint[] caps = [XDG_TOPLEVEL_WM_CAPABILITIES_MINIMIZE];
    assert(windowCapabilities(caps) == WindowCapability.minimize);
    assert(windowCapabilities(null) == 0);
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

private zwp_text_input_v3* zwp_text_input_manager_v3_get_text_input()(
        zwp_text_input_manager_v3* self, wl_seat* seat)
    => cast(zwp_text_input_v3*) wl_proxy_marshal_flags(
        cast(wl_proxy*) self, ZWP_TEXT_INPUT_MANAGER_V3_GET_TEXT_INPUT,
        &zwp_text_input_v3_interface,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, cast(void*) null,
        seat);

private void zwp_text_input_manager_v3_destroy()(
        zwp_text_input_manager_v3* self)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self,
        ZWP_TEXT_INPUT_MANAGER_V3_DESTROY, null,
        wl_proxy_get_version(cast(wl_proxy*) self), WL_MARSHAL_FLAG_DESTROY);
}

private int zwp_text_input_v3_add_listener()(zwp_text_input_v3* self,
        const(zwp_text_input_v3_listener)* listener, void* data)
    => wl_proxy_add_listener(cast(wl_proxy*) self,
        cast(ListenerImpl) listener, data);

private void zwp_text_input_v3_enable()(zwp_text_input_v3* self)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, ZWP_TEXT_INPUT_V3_ENABLE,
        null, wl_proxy_get_version(cast(wl_proxy*) self), 0);
}

private void zwp_text_input_v3_disable()(zwp_text_input_v3* self)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, ZWP_TEXT_INPUT_V3_DISABLE,
        null, wl_proxy_get_version(cast(wl_proxy*) self), 0);
}

private void zwp_text_input_v3_commit()(zwp_text_input_v3* self)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, ZWP_TEXT_INPUT_V3_COMMIT,
        null, wl_proxy_get_version(cast(wl_proxy*) self), 0);
}

private void zwp_text_input_v3_destroy()(zwp_text_input_v3* self)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, ZWP_TEXT_INPUT_V3_DESTROY,
        null, wl_proxy_get_version(cast(wl_proxy*) self),
        WL_MARSHAL_FLAG_DESTROY);
}

private zwp_confined_pointer_v1* zwp_pointer_constraints_v1_confine_pointer()(
        zwp_pointer_constraints_v1* self, wl_surface* surface,
        wl_pointer* pointer, wl_region* region, uint lifetime)
    => cast(zwp_confined_pointer_v1*) wl_proxy_marshal_flags(
        cast(wl_proxy*) self, ZWP_POINTER_CONSTRAINTS_V1_CONFINE_POINTER,
        &zwp_confined_pointer_v1_interface,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, cast(void*) null,
        surface, pointer, region, lifetime);

private void zwp_pointer_constraints_v1_destroy()(
        zwp_pointer_constraints_v1* self)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self,
        ZWP_POINTER_CONSTRAINTS_V1_DESTROY, null,
        wl_proxy_get_version(cast(wl_proxy*) self), WL_MARSHAL_FLAG_DESTROY);
}

private void zwp_confined_pointer_v1_destroy()(zwp_confined_pointer_v1* self)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self,
        ZWP_CONFINED_POINTER_V1_DESTROY, null,
        wl_proxy_get_version(cast(wl_proxy*) self), WL_MARSHAL_FLAG_DESTROY);
}

private zwp_relative_pointer_v1* zwp_relative_pointer_manager_v1_get_relative_pointer()(
        zwp_relative_pointer_manager_v1* self, wl_pointer* pointer)
    => cast(zwp_relative_pointer_v1*) wl_proxy_marshal_flags(
        cast(wl_proxy*) self,
        ZWP_RELATIVE_POINTER_MANAGER_V1_GET_RELATIVE_POINTER,
        &zwp_relative_pointer_v1_interface,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, cast(void*) null,
        pointer);

private void zwp_relative_pointer_manager_v1_destroy()(
        zwp_relative_pointer_manager_v1* self)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self,
        ZWP_RELATIVE_POINTER_MANAGER_V1_DESTROY, null,
        wl_proxy_get_version(cast(wl_proxy*) self), WL_MARSHAL_FLAG_DESTROY);
}

private int zwp_relative_pointer_v1_add_listener()(
        zwp_relative_pointer_v1* self,
        const(zwp_relative_pointer_v1_listener)* listener, void* data)
    => wl_proxy_add_listener(cast(wl_proxy*) self,
        cast(ListenerImpl) listener, data);

private void zwp_relative_pointer_v1_destroy()(zwp_relative_pointer_v1* self)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self,
        ZWP_RELATIVE_POINTER_V1_DESTROY, null,
        wl_proxy_get_version(cast(wl_proxy*) self), WL_MARSHAL_FLAG_DESTROY);
}

private immutable wl_data_device_listener dataDeviceListener = {
    &WaylandWsi.onDataOffer, &onDataEnter, &onDataLeave, &onDataMotion,
    &onDataDrop, &WaylandWsi.onSelection
};
private immutable wl_data_offer_listener dataOfferListener = {
    &WaylandWsi.onOfferType, &onOfferSourceActions, &onOfferAction
};
private immutable wl_data_source_listener dataSourceListener = {
    &onSourceTarget, &WaylandWsi.onSourceSend, &WaylandWsi.onSourceCancelled,
    &onSourceDropPerformed, &onSourceDndFinished, &onSourceAction
};

// Drag-and-drop events: no drag is accepted yet, so these only keep
// libwayland from calling through a null listener slot.
private extern (C) nothrow @nogc
{
    void onDataEnter(void*, wl_data_device*, uint, wl_surface*, wl_fixed_t,
        wl_fixed_t, wl_data_offer*) {}
    void onDataLeave(void*, wl_data_device*) {}
    void onDataMotion(void*, wl_data_device*, uint, wl_fixed_t, wl_fixed_t) {}
    void onDataDrop(void*, wl_data_device*) {}
    void onOfferSourceActions(void*, wl_data_offer*, uint) {}
    void onOfferAction(void*, wl_data_offer*, uint) {}
    void onSourceTarget(void*, wl_data_source*, const(char)*) {}
    void onSourceDropPerformed(void*, wl_data_source*) {}
    void onSourceDndFinished(void*, wl_data_source*) {}
    void onSourceAction(void*, wl_data_source*, uint) {}
}

private wl_data_device* wl_data_device_manager_get_data_device()(
        wl_data_device_manager* self, wl_seat* seat)
    => cast(wl_data_device*) wl_proxy_marshal_flags(cast(wl_proxy*) self,
        WL_DATA_DEVICE_MANAGER_GET_DATA_DEVICE, &wl_data_device_interface,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, cast(void*) null, seat);

private wl_data_source* wl_data_device_manager_create_data_source()(
        wl_data_device_manager* self)
    => cast(wl_data_source*) wl_proxy_marshal_flags(cast(wl_proxy*) self,
        WL_DATA_DEVICE_MANAGER_CREATE_DATA_SOURCE, &wl_data_source_interface,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, cast(void*) null);

private void wl_data_device_manager_destroy()(wl_data_device_manager* self)
    => wl_proxy_destroy(cast(wl_proxy*) self);

private int wl_data_device_add_listener()(wl_data_device* self,
        const(wl_data_device_listener)* listener, void* data)
    => wl_proxy_add_listener(cast(wl_proxy*) self,
        cast(ListenerImpl) listener, data);

private void wl_data_device_set_selection()(wl_data_device* self,
        wl_data_source* source, uint serial)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, WL_DATA_DEVICE_SET_SELECTION,
        null, wl_proxy_get_version(cast(wl_proxy*) self), 0, source, serial);
}

private void wl_data_device_release()(wl_data_device* self)
{
    if (wl_proxy_get_version(cast(wl_proxy*) self) >= WL_DATA_DEVICE_RELEASE_SINCE_VERSION)
        wl_proxy_marshal_flags(cast(wl_proxy*) self, WL_DATA_DEVICE_RELEASE, null,
            wl_proxy_get_version(cast(wl_proxy*) self), WL_MARSHAL_FLAG_DESTROY);
    else
        wl_proxy_destroy(cast(wl_proxy*) self);
}

private int wl_data_source_add_listener()(wl_data_source* self,
        const(wl_data_source_listener)* listener, void* data)
    => wl_proxy_add_listener(cast(wl_proxy*) self,
        cast(ListenerImpl) listener, data);

private void wl_data_source_offer()(wl_data_source* self, const(char)* mimeType)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, WL_DATA_SOURCE_OFFER, null,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, mimeType);
}

private void wl_data_source_destroy()(wl_data_source* self)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, WL_DATA_SOURCE_DESTROY, null,
        wl_proxy_get_version(cast(wl_proxy*) self), WL_MARSHAL_FLAG_DESTROY);
}

private int wl_data_offer_add_listener()(wl_data_offer* self,
        const(wl_data_offer_listener)* listener, void* data)
    => wl_proxy_add_listener(cast(wl_proxy*) self,
        cast(ListenerImpl) listener, data);

private void wl_data_offer_receive()(wl_data_offer* self, const(char)* mimeType,
        int fd)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, WL_DATA_OFFER_RECEIVE, null,
        wl_proxy_get_version(cast(wl_proxy*) self), 0, mimeType, fd);
}

private void wl_data_offer_destroy()(wl_data_offer* self)
{
    wl_proxy_marshal_flags(cast(wl_proxy*) self, WL_DATA_OFFER_DESTROY, null,
        wl_proxy_get_version(cast(wl_proxy*) self), WL_MARSHAL_FLAG_DESTROY);
}

/**
`write`, with `SIGPIPE` held off: a requester that closed its end makes the
write fail with `EPIPE` instead of killing the process. The signal is blocked
on this thread only for the call, and one it raised is consumed before the
mask is restored, so the process's own disposition is never touched.
*/
private ptrdiff_t writeWithoutSigpipe(int fd, const(void)* bytes, size_t length)
    nothrow @nogc
{
    import core.sys.posix.signal : SIG_BLOCK, SIG_SETMASK, SIGPIPE,
        pthread_sigmask, sigaddset, sigemptyset, sigismember, sigpending,
        sigset_t, sigtimedwait, timespec;

    sigset_t pipeOnly, previous, pending;
    sigemptyset(&pipeOnly);
    sigaddset(&pipeOnly, SIGPIPE);
    pthread_sigmask(SIG_BLOCK, &pipeOnly, &previous);
    // A SIGPIPE already pending belongs to someone else; leave it.
    sigpending(&pending);
    const alreadyPending = sigismember(&pending, SIGPIPE) == 1;
    const n = write(fd, bytes, length);
    const failure = errno;
    if (n < 0 && failure == EPIPE && !alreadyPending)
    {
        timespec now;
        sigtimedwait(&pipeOnly, null, &now);
    }
    pthread_sigmask(SIG_SETMASK, &previous, null);
    errno = failure;
    return n;
}

@("wsi.wayland.pointerPositionsAreInBufferPixels")
@safe pure nothrow @nogc unittest
{
    // At buffer scale 2 a pointer at logical (400.75, 10) is buffer pixel
    // (801, 20): the frame's buttons and the cells are found in buffer
    // pixels. Left of the surface, during a grab, it stays left.
    assert(WaylandWsi.physicalAt(LogicalPosition(400.75, 10), 2) == PhysicalPosition(801, 20));
    assert(WaylandWsi.physicalAt(LogicalPosition(400.75, 10), 1) == PhysicalPosition(400, 10));
    assert(WaylandWsi.physicalAt(LogicalPosition(-0.5, 3), 1) == PhysicalPosition(-1, 3));
}
