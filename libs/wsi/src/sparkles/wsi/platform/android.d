/**
The native Android backend: the activity's window and lifecycle, and the
clipboard, over the NDK native activity, with no raylib or `native_app_glue`.

$(B Two threads.) The activity's callbacks arrive on the Java main thread. They
do the minimum the platform requires synchronously, record a value in a
mutex-guarded channel, and wake the WSI thread through Event Horizon's waker.
The WSI thread runs the application and the loop, turns those values into
`WindowEvent`s, and never runs application code inside a callback.

$(B The window.) An activity has one window, so `createWindow` names it rather
than creating one. Its `ANativeWindow` comes and goes with the activity: while
none exists the window's physical size is zero, which suspends presentation
(`SurfaceMetrics.suspended`). When the surface is destroyed, the callback waits
until the application has drained the event that reported it, so a renderer
learns of the loss before the surface disappears.

$(B The clipboard.) Android has no NDK clipboard, so it goes through
`ClipboardManager` over JNI (`sparkles.android.clipboard`). A paste streams
from the Java string in bounded slices. An offer is built whole on the Java
side, because a streamed offer needs a Java `ContentProvider`, and Binder
bounds one clip to about 1 MB. Android sends no change notification to an app
without Java code, so offers are announced when the window gains focus.

$(B Entry.) An application mixes in $(LREF AndroidWsiMain) and names
`sparkles_wsi_onCreate` as the activity's `android.app.func_name`.

See `docs/specs/window-system-integration/PLAN.md`, milestone MA.
*/
module sparkles.wsi.platform.android;

version (Android):

import core.lifetime : move;
import core.sys.posix.pthread;
import core.time : Duration, MonoTime, msecs;

import sparkles.android.activity : ANativeActivity, nativeActivity;
import sparkles.android.clipboard : ClipDescription, ClipText, closeClipText,
    describePrimaryClip, openPrimaryClipText, readClipText, setPrimaryClipTyped;
import sparkles.android.main_thread : wireMainThread;
import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.pool.pool : Pool, PoolError;
import sparkles.base.text.utf16 : utf16ToUtf8, utf8ToUtf16;
import sparkles.event_horizon.backend.concept : Waker;
import sparkles.event_horizon.errors : IoErrorStage, IoResult, OpKind, ioErr,
    ioOk;
import sparkles.event_horizon.loop : DefaultLoop, RunStatus;
import sparkles.wsi.clipboard;
import sparkles.wsi.events;
import sparkles.wsi.handles;
import sparkles.wsi.history : PointerSample;
import sparkles.wsi.loop : EventQueue;
import sparkles.wsi.types;

// ── the NDK surface this backend touches ────────────────────────────────────

private extern (C) nothrow @nogc
{
    void ANativeWindow_acquire(void* window);
    void ANativeWindow_release(void* window);
    int ANativeWindow_getWidth(void* window);
    int ANativeWindow_getHeight(void* window);
    void ANativeActivity_finish(void* activity);
    void* AConfiguration_new();
    void AConfiguration_delete(void* config);
    void AConfiguration_fromAssetManager(void* config, void* assets);
    int AConfiguration_getDensity(const(void)* config);
    int rt_init();
    int __android_log_write(int priority, const(char)* tag, const(char)* text);
}

/// `<android/native_activity.h>`'s callback table, in declaration order.
private struct ANativeActivityCallbacks
{
    extern (C) nothrow:
    void function(void*) onStart, onResume;
    void* function(void*, size_t*) onSaveInstanceState;
    void function(void*) onPause, onStop, onDestroy;
    void function(void*, int) onWindowFocusChanged;
    void function(void*, void*) onNativeWindowCreated, onNativeWindowResized,
        onNativeWindowRedrawNeeded, onNativeWindowDestroyed;
    void function(void*, void*) onInputQueueCreated, onInputQueueDestroyed;
    void function(void*, const(void)*) onContentRectChanged;
    void function(void*) onConfigurationChanged, onLowMemory;
}

// ── the channel from the Java main thread ───────────────────────────────────

/// What an activity callback hands the WSI thread.
private enum NoteKind : ubyte
{
    surfaceCreated,
    surfaceResized,
    surfaceRedraw,
    surfaceDestroyed,
    focusGained,
    focusLost,
    resumed,
    paused,
    destroyed,
}

private struct Note
{
    NoteKind kind;
    void* surface;
}

/**
Shared between the Java main thread and the WSI thread; every field is read and
written under `lock`. The callbacks run on a thread druntime does not know, so
they touch only `__gshared` state and C calls.
*/
private struct Channel
{
    pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    // Initialised by `startActivity`: druntime's Bionic bindings have no
    // `PTHREAD_COND_INITIALIZER`.
    pthread_cond_t released;
    Note[32] notes;
    size_t head, count;
    Waker waker;
    bool hasWaker;
    bool releasePending; /// a destroyed surface waits for the WSI thread
}

private __gshared Channel channel;

private void post(NoteKind kind, void* surface = null) nothrow @nogc
{
    pthread_mutex_lock(&channel.lock);
    if (channel.count < channel.notes.length)
    {
        channel.notes[(channel.head + channel.count) % channel.notes.length] =
            Note(kind, surface);
        ++channel.count;
    }
    const wake = channel.hasWaker;
    auto waker = channel.waker;
    pthread_mutex_unlock(&channel.lock);
    if (wake)
        waker.wake();
}

extern (C) private nothrow
{
    void onSurfaceCreated(void*, void* surface)
    {
        ANativeWindow_acquire(surface);
        post(NoteKind.surfaceCreated, surface);
    }

    void onSurfaceResized(void*, void* surface)
    {
        post(NoteKind.surfaceResized, surface);
    }

    void onSurfaceRedraw(void*, void* surface)
    {
        post(NoteKind.surfaceRedraw, surface);
    }

    // The platform destroys the surface as soon as this returns, so it waits
    // until the WSI thread has reported the loss and the application has
    // drained that report. The wait is bounded: an application that stops
    // draining must not hang the activity.
    void onSurfaceDestroyed(void*, void* surface)
    {
        import core.sys.posix.time : clock_gettime, CLOCK_REALTIME, timespec;

        pthread_mutex_lock(&channel.lock);
        channel.releasePending = true;
        pthread_mutex_unlock(&channel.lock);
        post(NoteKind.surfaceDestroyed, surface);

        timespec until;
        clock_gettime(CLOCK_REALTIME, &until);
        until.tv_sec += 2;
        pthread_mutex_lock(&channel.lock);
        while (channel.releasePending)
            if (pthread_cond_timedwait(&channel.released, &channel.lock, &until) != 0)
                break;
        channel.releasePending = false;
        pthread_mutex_unlock(&channel.lock);
        ANativeWindow_release(surface);
    }

    void onFocusChanged(void*, int focused)
    {
        post(focused ? NoteKind.focusGained : NoteKind.focusLost);
    }

    void onResumed(void*) { post(NoteKind.resumed); }
    void onPaused(void*) { post(NoteKind.paused); }
    void onDestroyed(void*) { post(NoteKind.destroyed); }
}

/**
Starts an activity whose window this backend owns: records the activity for
`sparkles:android`, starts druntime, installs the callbacks, and runs
`appMain` on a thread of its own. Called from the entry
$(LREF AndroidWsiMain) defines.
*/
void startActivity(void* activity, void function() nothrow appMain) nothrow
{
    import core.thread : Thread;

    wireMainThread(activity);
    rt_init();
    pthread_cond_init(&channel.released, null);
    auto callbacks = *cast(ANativeActivityCallbacks**) activity;
    callbacks.onNativeWindowCreated = &onSurfaceCreated;
    callbacks.onNativeWindowResized = &onSurfaceResized;
    callbacks.onNativeWindowRedrawNeeded = &onSurfaceRedraw;
    callbacks.onNativeWindowDestroyed = &onSurfaceDestroyed;
    callbacks.onWindowFocusChanged = &onFocusChanged;
    callbacks.onResume = &onResumed;
    callbacks.onPause = &onPaused;
    callbacks.onDestroy = &onDestroyed;
    try
        (new Thread(appMain)).start();
    catch (Exception)
        __android_log_write(6, "sparkles-wsi", "cannot start the application thread");
}

/**
Defines the activity's entry point, `sparkles_wsi_onCreate`, which the manifest
names as `android.app.func_name`. `appMain` runs on its own thread: it opens
an $(LREF AndroidWsi), creates its window, and drives the loop, as a desktop
`main` would.
*/
mixin template AndroidWsiMain(alias appMain)
{
    export extern (C) void sparkles_wsi_onCreate(void* activity, void*, size_t) nothrow
    {
        static void run() nothrow
        {
            try
                appMain();
            catch (Throwable t)
            {
                import sparkles.wsi.platform.android : logFailure;

                logFailure(t.msg);
            }
        }

        import sparkles.wsi.platform.android : startActivity;

        startActivity(activity, &run);
    }
}

/// Writes `message` to logcat at error priority, under the tag `sparkles-wsi`.
void logFailure(scope const(char)[] message) @trusted nothrow
{
    import std.string : toStringz;

    try
        __android_log_write(6, "sparkles-wsi", message.toStringz);
    catch (Exception)
        __android_log_write(6, "sparkles-wsi", "failure");
}

// ── the backend ─────────────────────────────────────────────────────────────

/**
One Android WSI owner, on the application's thread. It has one window, the
activity's, and is address-pinned once attached, as every backend is.
*/
struct AndroidWsi
{
    enum maxWindows = 1;
    enum maxEvents = 128;

    /// Largest UTF-16 slice one paste step reads: 16 Ki units, at most
    /// 48 KiB of UTF-8, the chunk bound a sink sees (`DT4`).
    enum size_t pasteSliceUnits = 16 * 1024;

    @disable this(this);

    private struct Slot
    {
        bool ready;
        SurfaceMetrics metrics;
    }

    private Pool!(WindowId, Slot, maxWindows) windows_;
    private EventQueue!maxEvents events_;
    private ulong nextSequence_ = 1;
    private DefaultLoop* loop_;
    private bool open_;
    private bool closed_;
    private pthread_t owner_;
    private void* activity_;
    private void* surface_;   // the `ANativeWindow` the WSI thread knows of
    private bool releaseOwed_; // a destroyed surface waits for the next drain
    private ScaleFactor scale_ = ScaleFactor(1);

    private ClipboardState!() clipboard_;
    private long seenClipStamp_; // the last clip described
    private long ownClipStamp_;  // the clip this application set
    private ClipText[8] reading_; // per transfer slot: the text being pasted
    private size_t[8] readUnits_; // UTF-16 units already delivered

    /**
    Opens the backend on the calling thread, which becomes its owner. Fails
    with `unavailable` when no activity was recorded: the process was not
    started through $(LREF AndroidWsiMain).
    */
    static WsiResult!void open(out AndroidWsi wsi)
    {
        auto activity = nativeActivity();
        if (activity is null)
            return androidFailure!void(WsiOperation.open,
                "no activity: start the app through AndroidWsiMain",
                WsiErrorKind.unavailable);
        wsi.activity_ = cast(void*) activity;
        wsi.owner_ = pthread_self();
        wsi.scale_ = densityScale(activity);
        wsi.open_ = true;
        return wsiOk();
    }

    /// Joins Event Horizon: callbacks then wake the loop's single wait.
    WsiResult!void attach(ref DefaultLoop loop)
    {
        auto owner = requireOwner!void(WsiOperation.attach);
        if (owner.hasError)
            return owner;
        auto waker = loop.waker();
        if (waker.hasError)
            return androidFailure!void(WsiOperation.attach,
                "Event Horizon has no waker");
        pthread_mutex_lock(&channel.lock);
        channel.waker = waker.value;
        channel.hasWaker = true;
        pthread_mutex_unlock(&channel.lock);
        loop_ = &loop;
        return wsiOk();
    }

    /**
    One integrated step: applies what the activity reported, moves one slice
    of every paste, then waits in Event Horizon for at most `timeout`.
    */
    IoResult!RunStatus runIntegratedOnce(ref DefaultLoop loop,
        Duration timeout = Duration.max)
    {
        if (loop_ is null)
        {
            auto attached = attach(loop);
            if (attached.hasError)
                return ioErr!RunStatus(0, OpKind.nop, IoErrorStage.submit,
                    "failed to attach the Android activity channel");
        }
        else if (loop_ !is &loop)
            return ioErr!RunStatus(0, OpKind.nop, IoErrorStage.submit,
                "Android WSI used with a different Event Horizon loop");

        bool work = serviceNotes();
        work |= pumpTransfers();
        if (work)
            return ioOk(RunStatus.dispatched);
        auto result = loop.runOnce(timeout);
        if (result.hasError)
            return result;
        work = serviceNotes();
        work |= pumpTransfers();
        return work && result.value != RunStatus.stopped
            ? ioOk(RunStatus.dispatched) : result;
    }

    /**
    Names the activity's window. There is one: a second call fails with
    `capacity`. The window is ready once the activity has a surface.
    */
    WsiResult!WindowId createWindow(in WindowConfig config)
    {
        auto owner = requireOwner!WindowId(WsiOperation.createWindow);
        if (owner.hasError)
            return owner;
        auto reserved = windows_.reserve();
        if (reserved.hasError)
            return androidFailure!WindowId(WsiOperation.createWindow,
                "an Android activity has one window", WsiErrorKind.capacity);
        WindowId id = reserved.value;
        if (surface_ !is null)
        {
            becomeReady(id);
            offerFrame(id);
        }
        return wsiOk(id);
    }

    /**
    Releases this id for the activity's window: it reports `DestroyedEvent`
    and becomes stale, while the activity and its surface stay. A later
    `createWindow` names the window again. $(LREF finishActivity) ends the
    activity itself.
    */
    WsiResult!void destroyWindow(WindowId id)
    {
        auto checked = checkedSlot(id, WsiOperation.close);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        windows_.remove(id);
        events_.forgetWindow(id);
        emit(id, DestroyedEvent());
        return wsiOk();
    }

    /// Ends the activity (`ANativeActivity_finish`): its window then reports
    /// `DestroyedEvent` once the platform destroys it.
    WsiResult!void finishActivity()
    {
        auto owner = requireOwner!void(WsiOperation.close);
        if (owner.hasError)
            return owner;
        ANativeActivity_finish(activity_);
        return wsiOk();
    }

    /// The activity and its current `ANativeWindow`; `unavailable` while the
    /// activity has no surface.
    WsiResult!NativeHandles nativeHandles(WindowId id)
    {
        auto checked = checkedSlot(id, WsiOperation.queryHandle);
        if (checked.hasError)
            return wsiErr!NativeHandles(checked.error);
        if (surface_ is null)
            return androidFailure!NativeHandles(WsiOperation.queryHandle,
                "the activity has no surface now", WsiErrorKind.unavailable);
        NativeHandles handles;
        handles.display = DisplayHandle(AndroidDisplayHandle(activity_));
        handles.window = WindowHandle(AndroidWindowHandle(surface_));
        return wsiOk(handles);
    }

    /**
    Drains the queued events. A surface whose loss this drain reported is
    then released to the platform, so the callback waiting on it returns.
    */
    WsiResult!size_t drain(Sink)(scope Sink sink)
    {
        auto drained = events_.drain(sink);
        if (releaseOwed_)
        {
            releaseOwed_ = false;
            pthread_mutex_lock(&channel.lock);
            channel.releasePending = false;
            pthread_cond_broadcast(&channel.released);
            pthread_mutex_unlock(&channel.lock);
        }
        return drained;
    }

    /// Calls `fn` with the text a delivered event names (`ED8`).
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
        const => events_.copySamples(id, pointer, into);

    /// Copies an event's text into a `TextPool` the caller owns (`ED8`).
    WsiResult!WindowEvent retain(P)(WindowEvent event, ref P pool)
        => events_.retain(event, pool);

    // ── clipboard (`DT1`–`DT5`) ──────────────────────────────────────────────

    /**
    Offers `mimeTypes` on the clipboard. Android has no request callback, so
    the provider is read in full now, in bounded chunks, and the text is
    handed to Java. It must be UTF-8: a clip without a `ContentProvider`
    carries text.
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
        auto set = setClip(mimeTypes, provider, mimeTypes[0]);
        if (set.hasError)
        {
            clipboard_.drop(added.value);
            return wsiErr!OfferId(set.error);
        }
        publish(added.value);
        return added;
    }

    /// ditto, for a small whole value.
    WsiResult!OfferId offerClipboard(WindowId window, scope const(char)[] mimeType,
        scope const(ubyte)[] value)
    {
        ValueProvider copy;
        copy.bytes ~= value;
        const(char)[][1] types = [mimeType];
        return (() @trusted => offerClipboard(window, types[], copy))();
    }

    /// Ends an offer this application made: clears the clip and reports
    /// `withdrawn` (`DT1`).
    WsiResult!void withdrawClipboard(OfferId offer)
    {
        auto record = clipboard_.offers.get(offer);
        if (record is null || !record.own)
            return androidFailure!void(WsiOperation.command,
                "no live offer of this application's", WsiErrorKind.staleId);
        announce(offer, DataOfferAction.withdrawn);
        endReading(offer);
        clipboard_.drop(offer);
        return wsiOk();
    }

    /**
    Starts streaming `offer`'s text into `sink` (`DT2`). Only the clipboard's
    current offer is readable; a replaced one is stale.
    */
    WsiResult!TransferId receive(S)(OfferId offer, scope const(char)[] mimeType,
        ref S sink)
    if (isDataSink!S)
    {
        if (offer != clipboard_.current)
            return androidFailure!TransferId(WsiOperation.command,
                "the offer has ended", WsiErrorKind.staleId);
        return clipboard_.begin(offer, mimeType,
            (() @trusted => SinkRef.to(sink))());
    }

    /// Ends a transfer with `cancelled`; its sink then hears nothing more.
    WsiResult!void cancelTransfer(TransferId transfer)
    {
        if (clipboard_.transfers.isLive(transfer))
            closeReading(transfer.index);
        return clipboard_.cancel(transfer);
    }

    /// Reads the clipboard's description and announces a changed clip, as a
    /// focus gain does. For an application that needs it sooner.
    void refreshClipboard() => noticeClip(describePrimaryClip());

    void close()
    {
        if (closed_)
            return;
        foreach (h; clipboard_.transfers.byLive)
        {
            closeReading(h.index);
            clipboard_.end(h, TransferStatus.failed);
        }
        pthread_mutex_lock(&channel.lock);
        channel.hasWaker = false;
        channel.releasePending = false;
        pthread_cond_broadcast(&channel.released);
        pthread_mutex_unlock(&channel.lock);
        closed_ = true;
        open_ = false;
    }

    ~this()
    {
        close();
    }

    // ── internals ───────────────────────────────────────────────────────────

    private bool serviceNotes()
    {
        Note[32] taken;
        size_t n;
        pthread_mutex_lock(&channel.lock);
        while (channel.count != 0)
        {
            taken[n++] = channel.notes[channel.head];
            channel.head = (channel.head + 1) % channel.notes.length;
            --channel.count;
        }
        pthread_mutex_unlock(&channel.lock);

        foreach (ref note; taken[0 .. n])
            apply(note);
        return n != 0;
    }

    private void apply(in Note note)
    {
        auto live = windowHandle();
        final switch (note.kind)
        {
            case NoteKind.surfaceCreated:
                surface_ = cast(void*) note.surface;
                if (live.valid)
                {
                    if (!windows_[live].ready)
                        becomeReady(live);
                    else
                        reportMetrics(live);
                    offerFrame(live);
                }
                break;
            case NoteKind.surfaceResized:
                if (live.valid && cast(void*) note.surface is surface_)
                    reportMetrics(live);
                break;
            case NoteKind.surfaceRedraw:
                if (live.valid && cast(void*) note.surface is surface_)
                    offerFrame(live);
                break;
            case NoteKind.surfaceDestroyed:
                if (cast(void*) note.surface !is surface_)
                    break;
                surface_ = null;
                if (live.valid)
                {
                    // A zero pixel extent suspends presentation (`F01`).
                    reportMetrics(live);
                    releaseOwed_ = true;
                }
                else
                    releaseNow();
                break;
            case NoteKind.focusGained:
                if (live.valid)
                    emit(live, FocusChangedEvent(true));
                noticeClip(describePrimaryClip());
                break;
            case NoteKind.focusLost:
                if (live.valid)
                    emit(live, FocusChangedEvent(false));
                break;
            case NoteKind.resumed:
                if (live.valid)
                    emit(live, OccludedEvent(false));
                break;
            case NoteKind.paused:
                if (live.valid)
                    emit(live, OccludedEvent(true));
                break;
            case NoteKind.destroyed:
                if (live.valid)
                {
                    windows_.remove(live);
                    events_.forgetWindow(live);
                    emit(live, DestroyedEvent());
                }
                break;
        }
    }

    private void releaseNow()
    {
        pthread_mutex_lock(&channel.lock);
        channel.releasePending = false;
        pthread_cond_broadcast(&channel.released);
        pthread_mutex_unlock(&channel.lock);
    }

    private WindowId windowHandle()
    {
        foreach (h; windows_.byLive)
            return h;
        return WindowId.init;
    }

    private SurfaceMetrics currentMetrics()
    {
        const width = surface_ is null ? 0 : ANativeWindow_getWidth(surface_);
        const height = surface_ is null ? 0 : ANativeWindow_getHeight(surface_);
        const physical = PhysicalSize(width < 0 ? 0 : width, height < 0 ? 0 : height);
        return SurfaceMetrics(
            LogicalSize(physical.width / scale_.value, physical.height / scale_.value),
            physical, scale_);
    }

    // The surface needs content: an expose, and a frame opportunity. Frame
    // pacing through `AChoreographer` is a later slice of milestone MA.
    private void offerFrame(WindowId id)
    {
        emit(id, ExposedEvent());
        emit(id, FrameReadyEvent());
    }

    private void becomeReady(WindowId id)
    {
        windows_[id].ready = true;
        windows_[id].metrics = currentMetrics();
        emit(id, ReadyEvent(windows_[id].metrics));
    }

    private void reportMetrics(WindowId id)
    {
        const metrics = currentMetrics();
        if (metrics == windows_[id].metrics)
            return;
        windows_[id].metrics = metrics;
        emit(id, SurfaceMetricsChangedEvent(metrics));
    }

    private static ScaleFactor densityScale(ANativeActivity* activity)
    {
        auto config = AConfiguration_new();
        if (config is null)
            return ScaleFactor(1);
        scope (exit) AConfiguration_delete(config);
        AConfiguration_fromAssetManager(config, activity.assetManager);
        const dpi = AConfiguration_getDensity(config);
        return ScaleFactor(dpi > 0 ? dpi / 160.0 : 1);
    }

    // The clip changed if its timestamp did. Another source replacing this
    // application's clip withdraws its offer (`DT1`); any new clip is
    // announced as a foreign offer.
    private void noticeClip(in ClipDescription description)
    {
        if (!description.present || description.timestamp == seenClipStamp_)
            return;
        seenClipStamp_ = description.timestamp;
        if (description.timestamp == ownClipStamp_)
            return;
        const(char)[][maxOfferTypes] types;
        size_t n;
        foreach (i; 0 .. description.typeCount)
            if (n < types.length && description.type(i).length != 0)
                types[n++] = description.type(i);
        if (n == 0)
            return;
        auto added = clipboard_.add(windowHandle(), types[0 .. n], false);
        if (!added.hasError)
            publish(added.value);
    }

    private void publish(OfferId offer)
    {
        const previous = clipboard_.current;
        if (auto old = clipboard_.offers.get(previous))
        {
            if (old.own)
                announce(previous, DataOfferAction.withdrawn);
            endReading(previous);
            clipboard_.drop(previous);
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
        {
            auto result = events_.pushText(nextSequence_, window,
                record.types[i][],
                (TextId mime, size_t kept) => DataOfferEvent(offer, action, mime));
            if (!result.hasError)
                ++nextSequence_;
        }
    }

    // Reads `provider` in bounded chunks, converts it to UTF-16 as it goes,
    // and sets the clip. The UTF-16 buffer is the only copy, and it lives
    // only until Java has the clip.
    private WsiResult!void setClip(P)(scope const(char[])[] mimeTypes,
        ref P provider, scope const(char)[] firstType)
    {
        UniqueBuffer!(wchar, 1) wide;
        ubyte[4096 + 3] chunk;
        size_t carried;
        ulong offset;
        for (;;)
        {
            const n = provider.fill(firstType, offset, chunk[carried .. 4096 + carried - 3]);
            offset += n;
            const total = carried + n;
            // Convert whole sequences only; carry a split one into the next chunk.
            size_t whole = total;
            if (n != 0)
                whole = completeUtf8Prefix(cast(const(char)[]) chunk[0 .. total]);
            if (whole != 0)
            {
                const start = wide.length;
                wide.length = start + whole; // UTF-16 never needs more units than bytes
                auto converted = utf8ToUtf16(cast(const(char)[]) chunk[0 .. whole],
                    wide[][start .. start + whole]);
                if (converted.hasError)
                    return androidFailure!void(WsiOperation.command,
                        "an Android clip carries UTF-8 text", WsiErrorKind.invalidArgument);
                wide.length = start + converted.value;
            }
            carried = total - whole;
            foreach (i; 0 .. carried)
                chunk[i] = chunk[whole + i];
            if (n == 0)
                break;
        }
        if (carried != 0)
            return androidFailure!void(WsiOperation.command,
                "the offered text ends inside a UTF-8 sequence", WsiErrorKind.invalidArgument);
        const stamp = setPrimaryClipTyped("sparkles", mimeTypes, wide[]);
        if (stamp == 0)
            return androidFailure!void(WsiOperation.command,
                "setPrimaryClip failed; a clip is bounded by one Binder transaction",
                WsiErrorKind.capacity);
        ownClipStamp_ = seenClipStamp_ = stamp;
        return wsiOk();
    }

    // One paste step per transfer: a slice of at most `pasteSliceUnits`
    // UTF-16 units, never ending between a surrogate pair, as UTF-8.
    private bool pumpTransfers()
    {
        bool work;
        foreach (h; clipboard_.transfers.byLive)
        {
            work = true;
            const i = h.index;
            if (reading_[i].global is null)
            {
                reading_[i] = openPrimaryClipText();
                readUnits_[i] = 0;
                if (reading_[i].global is null)
                {
                    clipboard_.end(h, TransferStatus.failed);
                    continue;
                }
            }
            wchar[pasteSliceUnits] units;
            auto n = readClipText(reading_[i], readUnits_[i], units[]);
            if (n == 0)
            {
                closeReading(i);
                clipboard_.end(h, TransferStatus.completed);
                continue;
            }
            if (n > 1 && readUnits_[i] + n < reading_[i].length
                && units[n - 1] >= 0xD800 && units[n - 1] <= 0xDBFF)
                --n;
            char[pasteSliceUnits * 3] bytes;
            auto converted = utf16ToUtf8(units[0 .. n], bytes[]);
            if (converted.hasError)
            {
                closeReading(i);
                clipboard_.end(h, TransferStatus.failed);
                continue;
            }
            readUnits_[i] += n;
            auto record = clipboard_.transfers.get(h);
            record.sink.chunk(h, cast(const(ubyte)[]) bytes[0 .. converted.value]);
        }
        return work;
    }

    private void closeReading(size_t index)
    {
        closeClipText(reading_[index]);
        readUnits_[index] = 0;
    }

    private void endReading(OfferId offer)
    {
        foreach (h; clipboard_.transfers.byLive)
            if (clipboard_.transfers[h].offer == offer)
                closeReading(h.index);
    }

    private void emit(Payload)(WindowId id, Payload payload)
    {
        auto result = events_.pushCoalesced(WindowEvent(nextSequence_, id,
            WindowEventPayload(payload), MonoTime.currTime));
        if (!result.hasError)
            ++nextSequence_;
    }

    private WsiResult!size_t checkedSlot(WindowId id, WsiOperation operation)
    {
        auto owner = requireOwner!size_t(operation);
        if (owner.hasError)
            return owner;
        auto index = windows_.resolve(id);
        if (index.hasError)
            return androidFailure!size_t(operation,
                index.error == PoolError.invalid
                    ? "invalid Android window id" : "stale Android window id",
                WsiErrorKind.staleId);
        size_t slot = index.value;
        return wsiOk(slot);
    }

    private WsiResult!T requireOwner(T)(WsiOperation operation)
    {
        if (!open_)
            return androidFailure!T(operation, "Android WSI is not open",
                WsiErrorKind.closed);
        if (pthread_equal(owner_, pthread_self()) == 0)
            return androidFailure!T(operation,
                "Android WSI calls must come from its owner thread",
                WsiErrorKind.wrongThread);
        static if (is(T == void))
            return wsiOk();
        else
            return wsiOk(T.init);
    }
}

private WsiResult!T androidFailure(T)(WsiOperation operation,
    scope const(char)[] diagnostic, WsiErrorKind kind = WsiErrorKind.nativeFailure)
    => wsiErr!T(wsiError(kind, operation, BackendKind.android,
        diagnostic: diagnostic));
