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
learns of the loss before the surface disappears. Its scale and safe insets
come from the framework over JNI (`sparkles.android.window_metrics`), reread
when the configuration, the content rect, the surface or focus changes.

$(B Input.) The activity's `AInputQueue` is attached to the main thread's
looper, and each event is translated there into plain records: a key with its
scan code, a motion event as one record per pointer and per historical sample.
The WSI thread turns them into key, text, touch, pointer and scroll events,
with the platform's event times, and puts a batched event's history in the
queue's sample ring (`ED3`). Pointer input is routed by the surface's bounds,
so the window receives none until a frame was presented on it. The soft
keyboard edits a hidden field (`sparkles.android.ime`) that is polled while
$(LREF AndroidWsi.setTextInput) is on.

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
import core.atomic : atomicStore, cas;
import core.stdc.config : c_long;
import core.time : Duration, MonoTime, msecs, nsecs, seconds;
import std.math : lround;

import sparkles.android.activity : ANativeActivity, nativeActivity, noteActivityResumed,
    refreshConfiguration;
import sparkles.android.clipboard : ClipDescription, ClipText, closeClipText,
    describePrimaryClip, openPrimaryClipText, readClipText, setPrimaryClipTyped;
import sparkles.android.ime : installImeField, pollImeField, showImeKeyboard;
import jni_c : JNIEnv;
import sparkles.android.main_thread : postToMainThread, wireMainThread;
import sparkles.android.window_metrics : displayDensity, layOutEdgeToEdge,
    windowInsets;
import sparkles.android.text_input : imeBackspace, imeEnter, keyCharacter,
    onTyped, popTypedChar;
import sparkles.base.buffer : UniqueBuffer;
import sparkles.input.pointer : PointerShape;
import sparkles.base.pool.pool : Pool, PoolError;
import sparkles.base.sync.condition : Condition;
import sparkles.base.sync.mutex : Mutex;
import sparkles.base.text.utf16 : utf16ToUtf8, utf32ToUtf8, utf8ToUtf16;
import sparkles.event_horizon.backend.concept : Waker;
import sparkles.event_horizon.errors : IoErrorStage, IoResult, OpKind, ioErr,
    ioOk;
import sparkles.event_horizon.loop : DefaultLoop, RunStatus;
import sparkles.input.events : KeyAction, Mods, PointerButton;
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

    void* ALooper_forThread();
    void AInputQueue_attachLooper(void* queue, void* looper, int ident,
        ALooperCallback callback, void* data);
    void AInputQueue_detachLooper(void* queue);
    int AInputQueue_getEvent(void* queue, void** event);
    int AInputQueue_preDispatchEvent(void* queue, void* event);
    void AInputQueue_finishEvent(void* queue, void* event, int handled);

    int AInputEvent_getType(const(void)* event);
    int AInputEvent_getDeviceId(const(void)* event);
    int AInputEvent_getSource(const(void)* event);
    int AKeyEvent_getAction(const(void)* event);
    int AKeyEvent_getKeyCode(const(void)* event);
    int AKeyEvent_getScanCode(const(void)* event);
    int AKeyEvent_getMetaState(const(void)* event);
    int AKeyEvent_getRepeatCount(const(void)* event);
    long AKeyEvent_getEventTime(const(void)* event);
    int AMotionEvent_getAction(const(void)* event);
    int AMotionEvent_getMetaState(const(void)* event);
    int AMotionEvent_getButtonState(const(void)* event);
    long AMotionEvent_getEventTime(const(void)* event);
    size_t AMotionEvent_getPointerCount(const(void)* event);
    int AMotionEvent_getPointerId(const(void)* event, size_t index);
    int AMotionEvent_getToolType(const(void)* event, size_t index);
    float AMotionEvent_getX(const(void)* event, size_t index);
    float AMotionEvent_getY(const(void)* event, size_t index);
    float AMotionEvent_getPressure(const(void)* event, size_t index);
    float AMotionEvent_getTouchMajor(const(void)* event, size_t index);
    float AMotionEvent_getTouchMinor(const(void)* event, size_t index);
    float AMotionEvent_getAxisValue(const(void)* event, int axis, size_t index);
    size_t AMotionEvent_getHistorySize(const(void)* event);
    long AMotionEvent_getHistoricalEventTime(const(void)* event, size_t history);
    float AMotionEvent_getHistoricalX(const(void)* event, size_t index, size_t history);
    float AMotionEvent_getHistoricalY(const(void)* event, size_t index, size_t history);
    float AMotionEvent_getHistoricalPressure(const(void)* event, size_t index,
        size_t history);
    float AMotionEvent_getHistoricalAxisValue(const(void)* event, int axis,
        size_t index, size_t history);
}

private alias ALooperCallback = extern (C) int function(int fd, int events,
    void* data) nothrow;

// API 33; absent below it, where a press's button comes from the button state.
pragma(LDC_extern_weak)
private extern (C) int AMotionEvent_getActionButton(const(void)* event) nothrow @nogc;

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
    contentRect,   /// the area system bars and the soft keyboard leave
    configuration, /// density, orientation or another setting changed
    activityStarted, /// a new activity of this process took over the window
    lowMemory,     /// the system is short of memory
    frame,         /// a display frame began (`AChoreographer`)
}

private struct Note
{
    NoteKind kind;
    void* surface;
    int[4] rect; /// `contentRect`: left, top, right, bottom in window pixels
    long frameNanos; /// `frame`: the frame's start, `CLOCK_MONOTONIC`
    /// `surfaceDestroyed`: the WSI thread releases the surface's reference,
    /// not the callback (a finished activity's surface, lost after another
    /// activity started).
    bool wsiReleases;
}

/**
Shared between the Java main thread and the WSI thread; every field is read and
written under `lock`. The callbacks run on a thread druntime does not know, so
they touch only `__gshared` state and C calls.
*/
private struct Channel
{
    Mutex lock;
    Condition released;
    Note[32] notes;
    size_t head, count;
    void* activity; /// the activity whose callbacks are current
    Waker waker;
    bool hasWaker;
    bool releasePending; /// a destroyed surface waits for the WSI thread

    InputRecord[1024] inputs;
    size_t inputHead, inputCount;
    uint inputLost; /// records refused because the ring was full
}

/// What kind of input an $(LREF InputRecord) carries.
private enum InputKind : ubyte
{
    key,
    touch,
    mouse,
    stylus,
    scroll,
}

/// The button a press record names when it releases every held button.
private enum ubyte allButtons = 0xFF;

/**
One native input sample, translated on the main thread into plain values.
A motion event becomes one record per pointer and per historical sample;
`last` marks a pointer's newest sample in its event, so the WSI thread knows
where one queued event's samples end.
*/
private struct InputRecord
{
    InputKind kind;
    ubyte phase;  /// `KeyAction`, `PointerPhase` or `TouchPhase`
    ubyte button; /// `PointerButton`, or `allButtons`
    bool last;
    int code;     /// key: the key code; pointer: the platform's pointer id
    int scanCode; /// key: the physical scan code
    int meta;     /// `AMETA_*` state
    int device;
    long time;    /// nanoseconds, `CLOCK_MONOTONIC`
    float x = 0, y = 0;
    float pressure = float.nan;
    float major = 0, minor = 0;
    float tiltX = float.nan, tiltY = float.nan;
}

private __gshared Channel channel;

// A note from an activity other than the current one is dropped: a finished
// activity's last callbacks can arrive after a new activity started in the
// same process, and its `destroyed` must not end the new one's window.
private bool post(void* activity, NoteKind kind, void* surface = null,
    int[4] rect = 0) nothrow @nogc
    => postNote(activity, Note(kind, surface, rect));

// Whether the note was queued: `false` for another activity's, or a full
// channel.
private bool postNote(void* activity, Note note) nothrow @nogc
{
    channel.lock.lock();
    if (activity !is channel.activity)
    {
        channel.lock.unlock();
        return false;
    }
    return enqueueLocked(note);
}

// Queues `note` and wakes the WSI thread; called with `channel.lock` held,
// which it releases.
private bool enqueueLocked(Note note) nothrow @nogc
{
    const queued = channel.count < channel.notes.length;
    if (queued)
    {
        channel.notes[(channel.head + channel.count) % channel.notes.length] =
            note;
        ++channel.count;
    }
    const wake = channel.hasWaker;
    auto waker = channel.waker;
    channel.lock.unlock();
    if (wake)
        waker.wake();
    return queued;
}

// ── frame opportunities, from `AChoreographer` on the main thread ───────────

private extern (C) nothrow @nogc
{
    void* AChoreographer_getInstance();
    void AChoreographer_postFrameCallback(void* choreographer,
        void function(c_long, void*) nothrow @nogc callback, void* data);
}

// API 29; below it the `long`-sized callback is the 32-bit-safe one.
pragma(LDC_extern_weak)
private extern (C) void AChoreographer_postFrameCallback64(void* choreographer,
    void function(long, void*) nothrow @nogc callback, void* data) nothrow @nogc;

private shared bool framePending; // a frame callback is registered

// `requestFrame` asks the main thread, whose looper the choreographer needs,
// to register one callback for the next display frame.
private void frameJob(JNIEnv*, void*) nothrow @nogc
{
    auto choreographer = AChoreographer_getInstance();
    if (choreographer is null)
    {
        atomicStore(framePending, false);
        return;
    }
    if (&AChoreographer_postFrameCallback64 !is null)
        AChoreographer_postFrameCallback64(choreographer, &onFrame64, null);
    else
        AChoreographer_postFrameCallback(choreographer, &onFrame, null);
}

private extern (C) void onFrame64(long frameTimeNanos, void*) nothrow @nogc
{
    atomicStore(framePending, false);
    channel.lock.lock();
    auto activity = channel.activity;
    channel.lock.unlock();
    Note note = Note(NoteKind.frame);
    note.frameNanos = frameTimeNanos;
    postNote(activity, note);
}

private extern (C) void onFrame(c_long frameTimeNanos, void* data) nothrow @nogc
{
    onFrame64(frameTimeNanos, data);
}

// Appends one native event's records at once, so the WSI thread never sees
// half of a motion event's samples, then wakes it.
private void postInputs(scope const(InputRecord)[] records) nothrow @nogc
{
    if (records.length == 0)
        return;
    channel.lock.lock();
    if (channel.inputs.length - channel.inputCount < records.length)
        channel.inputLost += cast(uint) records.length;
    else
        foreach (ref record; records)
        {
            channel.inputs[(channel.inputHead + channel.inputCount)
                % channel.inputs.length] = record;
            ++channel.inputCount;
        }
    const wake = channel.hasWaker;
    auto waker = channel.waker;
    channel.lock.unlock();
    if (wake)
        waker.wake();
}

// ── input, on the main thread ───────────────────────────────────────────────

private enum : int
{
    inputTypeKey = 1,
    inputTypeMotion = 2,
    keyActionDown = 0,
    keyActionUp = 1,
    motionDown = 0,
    motionUp = 1,
    motionMove = 2,
    motionCancel = 3,
    motionPointerDown = 5,
    motionPointerUp = 6,
    motionHoverMove = 7,
    motionScroll = 8,
    motionHoverEnter = 9,
    motionHoverExit = 10,
    motionButtonPress = 11,
    motionButtonRelease = 12,
    toolFinger = 1,
    toolStylus = 2,
    toolMouse = 3,
    toolEraser = 4,
    sourceMouse = 0x2002,
    sourceStylus = 0x4002,
    axisOrientation = 8,
    axisVScroll = 9,
    axisHScroll = 10,
    axisTilt = 25,
}

/// Keys the system acts on (volume, power, media, …): reported, and left
/// unhandled so the system still acts on them.
private bool isSystemKey(int keyCode) @safe pure nothrow @nogc
{
    switch (keyCode)
    {
        case 3: // HOME
        case 24, 25, 164: // VOLUME_UP, VOLUME_DOWN, VOLUME_MUTE
        case 26, 223, 224: // POWER, SLEEP, WAKEUP
        case 27, 80: // CAMERA, FOCUS
        case 79, 85, 86, 87, 88, 89, 90, 91, 126, 127: // HEADSETHOOK, MEDIA_*, MUTE
        case 187, 219, 220, 221: // APP_SWITCH, ASSIST, BRIGHTNESS_DOWN/UP
            return true;
        default:
            return false;
    }
}

private InputKind pointerKind(int toolType, int source) @safe pure nothrow @nogc
{
    switch (toolType)
    {
        case toolFinger: return InputKind.touch;
        case toolStylus, toolEraser: return InputKind.stylus;
        case toolMouse: return InputKind.mouse;
        default:
            if (source == sourceMouse)
                return InputKind.mouse;
            return source == sourceStylus ? InputKind.stylus : InputKind.touch;
    }
}

private PointerButton buttonOf(int bits) @safe pure nothrow @nogc
{
    if (bits & 0x2) return PointerButton.right;  // BUTTON_SECONDARY
    if (bits & 0x4) return PointerButton.middle; // BUTTON_TERTIARY
    if (bits & 0x8) return PointerButton.back;
    if (bits & 0x10) return PointerButton.forward;
    return PointerButton.left;                   // BUTTON_PRIMARY, or none
}

private void stylusTilt(ref InputRecord record, float tilt, float orientation)
    nothrow @nogc
{
    import std.math : atan, cos, sin, tan, PI;

    // Android reports a polar tilt from the normal and the direction it
    // leans; the record carries the two planar angles, in degrees.
    const t = tan(tilt);
    record.tiltX = cast(float)(atan(t * sin(orientation)) * 180 / PI);
    record.tiltY = cast(float)(atan(-t * cos(orientation)) * 180 / PI);
}

// Translates one native event into records; whether it was handled.
private int translateInput(void* event) nothrow @nogc
{
    InputRecord[64] records;
    size_t n;
    const type = AInputEvent_getType(event);
    if (type == inputTypeKey)
    {
        const action = AKeyEvent_getAction(event);
        if (action != keyActionDown && action != keyActionUp)
            return 1; // ACTION_MULTIPLE: its text reaches the IME field
        InputRecord r;
        r.kind = InputKind.key;
        r.code = AKeyEvent_getKeyCode(event);
        r.scanCode = AKeyEvent_getScanCode(event);
        r.meta = AKeyEvent_getMetaState(event);
        r.device = AInputEvent_getDeviceId(event);
        r.time = AKeyEvent_getEventTime(event);
        r.phase = action == keyActionUp ? KeyAction.release
            : AKeyEvent_getRepeatCount(event) > 0 ? KeyAction.repeat
            : KeyAction.press;
        r.last = true;
        postInputs((&r)[0 .. 1]);
        return isSystemKey(r.code) ? 0 : 1;
    }
    if (type != inputTypeMotion)
        return 0;

    const raw = AMotionEvent_getAction(event);
    const action = raw & 0xFF;
    const actionIndex = cast(size_t)((raw & 0xFF00) >> 8);
    const source = AInputEvent_getSource(event);
    const meta = AMotionEvent_getMetaState(event);
    const time = AMotionEvent_getEventTime(event);
    const pointers = AMotionEvent_getPointerCount(event);

    InputRecord sample(size_t i, InputKind kind)
    {
        InputRecord r;
        r.kind = kind;
        r.code = AMotionEvent_getPointerId(event, i);
        r.meta = meta;
        r.time = time;
        r.x = AMotionEvent_getX(event, i);
        r.y = AMotionEvent_getY(event, i);
        r.pressure = AMotionEvent_getPressure(event, i);
        r.major = AMotionEvent_getTouchMajor(event, i);
        r.minor = AMotionEvent_getTouchMinor(event, i);
        if (kind == InputKind.stylus)
            stylusTilt(r, AMotionEvent_getAxisValue(event, axisTilt, i),
                AMotionEvent_getAxisValue(event, axisOrientation, i));
        r.last = true;
        return r;
    }

    void add(InputRecord r)
    {
        if (n < records.length)
            records[n++] = r;
    }

    // Every pointer's samples since the last event, oldest first.
    void moved(ubyte phase)
    {
        const history = AMotionEvent_getHistorySize(event);
        foreach (i; 0 .. pointers)
        {
            const kind = pointerKind(AMotionEvent_getToolType(event, i), source);
            // Keep the newest samples when a pointer's history outruns the
            // record buffer; history is advisory (`ED3`).
            const room = (records.length - n) / (pointers - i);
            const skip = history + 1 > room ? history + 1 - room : 0;
            foreach (h; skip .. history)
            {
                auto r = sample(i, kind);
                r.phase = phase;
                r.last = false;
                r.time = AMotionEvent_getHistoricalEventTime(event, h);
                r.x = AMotionEvent_getHistoricalX(event, i, h);
                r.y = AMotionEvent_getHistoricalY(event, i, h);
                r.pressure = AMotionEvent_getHistoricalPressure(event, i, h);
                if (kind == InputKind.stylus)
                    stylusTilt(r,
                        AMotionEvent_getHistoricalAxisValue(event, axisTilt, i, h),
                        AMotionEvent_getHistoricalAxisValue(event, axisOrientation, i, h));
                add(r);
            }
            auto r = sample(i, kind);
            r.phase = phase;
            add(r);
        }
    }

    const actionKind = pointerKind(AMotionEvent_getToolType(event, actionIndex), source);
    const touch = actionKind == InputKind.touch;
    switch (action)
    {
        case motionDown, motionPointerDown:
            auto r = sample(actionIndex, actionKind);
            r.phase = touch ? cast(ubyte) TouchPhase.began : cast(ubyte) PointerPhase.pressed;
            r.button = buttonOf(AMotionEvent_getButtonState(event));
            add(r);
            break;
        case motionUp, motionPointerUp:
            auto r = sample(actionIndex, actionKind);
            r.phase = touch ? cast(ubyte) TouchPhase.ended : cast(ubyte) PointerPhase.released;
            r.button = allButtons;
            add(r);
            break;
        case motionMove, motionHoverMove:
            moved(touch ? cast(ubyte) TouchPhase.moved : cast(ubyte) PointerPhase.moved);
            break;
        case motionCancel:
            foreach (i; 0 .. pointers)
            {
                const kind = pointerKind(AMotionEvent_getToolType(event, i), source);
                auto r = sample(i, kind);
                r.phase = kind == InputKind.touch ? cast(ubyte) TouchPhase.cancelled
                    : cast(ubyte) PointerPhase.released;
                r.button = allButtons;
                add(r);
            }
            break;
        case motionHoverEnter, motionHoverExit:
            auto r = sample(actionIndex, actionKind);
            r.phase = action == motionHoverEnter ? PointerPhase.entered
                : PointerPhase.left;
            add(r);
            break;
        case motionButtonPress, motionButtonRelease:
            auto r = sample(actionIndex, actionKind);
            r.phase = action == motionButtonPress ? PointerPhase.pressed
                : cast(ubyte) PointerPhase.released;
            const bits = &AMotionEvent_getActionButton !is null
                ? AMotionEvent_getActionButton(event)
                : AMotionEvent_getButtonState(event);
            r.button = buttonOf(bits);
            add(r);
            break;
        case motionScroll:
            auto r = sample(actionIndex, InputKind.scroll);
            r.major = AMotionEvent_getAxisValue(event, axisHScroll, actionIndex);
            r.minor = AMotionEvent_getAxisValue(event, axisVScroll, actionIndex);
            add(r);
            break;
        default:
            return 0;
    }
    postInputs(records[0 .. n]);
    return 1;
}

extern (C) private nothrow
{
    int onInputReady(int, int, void* queue)
    {
        void* event;
        while (AInputQueue_getEvent(queue, &event) >= 0)
        {
            if (AInputQueue_preDispatchEvent(queue, event) != 0)
                continue;
            AInputQueue_finishEvent(queue, event, translateInput(event));
        }
        return 1;
    }

    // Both run on the main thread, whose looper then delivers the queue's
    // events to `onInputReady` there.
    void onInputQueueCreated(void*, void* queue)
    {
        AInputQueue_attachLooper(queue, ALooper_forThread(), 1, &onInputReady, queue);
    }

    void onInputQueueDestroyed(void*, void* queue)
    {
        AInputQueue_detachLooper(queue);
    }

    void onSurfaceCreated(void* activity, void* surface)
    {
        // The WSI thread's reference, released once it reported the loss.
        ANativeWindow_acquire(surface);
        if (!post(activity, NoteKind.surfaceCreated, surface))
            ANativeWindow_release(surface);
    }

    void onSurfaceResized(void* activity, void* surface)
    {
        post(activity, NoteKind.surfaceResized, surface);
    }

    void onSurfaceRedraw(void* activity, void* surface)
    {
        post(activity, NoteKind.surfaceRedraw, surface);
    }

    // The platform destroys the surface as soon as this returns, so it waits
    // until the WSI thread has reported the loss and the application has
    // drained that report. The wait is bounded: an application that stops
    // draining must not hang the activity.
    void onSurfaceDestroyed(void* activity, void* surface)
    {
        channel.lock.lock();
        // A finished activity's surface, lost after another activity of the
        // process started: the application may still present to it, so the
        // WSI thread reports the loss and releases the reference after the
        // drain that reported it. Nothing waits for that here: the new
        // activity's callbacks run on this thread.
        if (activity !is channel.activity)
        {
            auto note = Note(NoteKind.surfaceDestroyed, surface);
            note.wsiReleases = true;
            if (!enqueueLocked(note))
                ANativeWindow_release(surface);
            return;
        }
        channel.releasePending = true;
        channel.lock.unlock();
        post(activity, NoteKind.surfaceDestroyed, surface);

        const until = MonoTime.currTime + 2.seconds;
        {
            auto held = channel.lock.guard();
            while (channel.releasePending)
                if (!channel.released.waitUntil(held, until))
                    break;
            channel.releasePending = false;
        }
        ANativeWindow_release(surface);
    }

    void onFocusChanged(void* activity, int focused)
    {
        post(activity, focused ? NoteKind.focusGained : NoteKind.focusLost);
    }

    // `ARect`: four `int32_t`, left, top, right, bottom.
    void onContentRectChanged(void* activity, const(void)* rect)
    {
        post(activity, NoteKind.contentRect, null, *cast(const(int[4])*) rect);
    }

    void onConfigurationChanged(void* activity) { post(activity, NoteKind.configuration); }
    void onResumed(void* activity) { post(activity, NoteKind.resumed); }
    void onPaused(void* activity) { post(activity, NoteKind.paused); }
    void onDestroyed(void* activity) { post(activity, NoteKind.destroyed); }
    void onLowMemory(void* activity) { post(activity, NoteKind.lowMemory); }
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
    import sparkles.android.ime : forgetImeField;

    wireMainThread(activity);
    if (!runtimeStarted)
    {
        rt_init();
        runtimeStarted = true;
    }
    else
        // The previous activity's soft-keyboard field lived in its views.
        forgetImeField(cast(JNIEnv*) (cast(ANativeActivity*) activity).env);

    // A process can outlive its activity and start another: nothing the
    // previous one queued belongs to this one, and the backend, which
    // outlives both, is told the window is this activity's now.
    // Notes the previous activity queued stay: they are applied in order, and
    // one may carry a surface reference the WSI thread must release. Its later
    // callbacks are dropped (`postNote`), its surface's loss excepted.
    channel.lock.lock();
    channel.activity = activity;
    channel.inputHead = channel.inputCount = 0;
    channel.releasePending = false;
    const startApp = !appRunning;
    appRunning = true;
    enqueueLocked(Note(NoteKind.activityStarted));
    // The window covers the whole panel, cutouts and bars included; what
    // covers it is reported as `safeInsets`. A layout parameter of each
    // activity's window, so set for every one.
    layOutEdgeToEdge();
    auto callbacks = *cast(ANativeActivityCallbacks**) activity;
    callbacks.onNativeWindowCreated = &onSurfaceCreated;
    callbacks.onNativeWindowResized = &onSurfaceResized;
    callbacks.onNativeWindowRedrawNeeded = &onSurfaceRedraw;
    callbacks.onNativeWindowDestroyed = &onSurfaceDestroyed;
    callbacks.onWindowFocusChanged = &onFocusChanged;
    callbacks.onResume = &onResumed;
    callbacks.onPause = &onPaused;
    callbacks.onDestroy = &onDestroyed;
    callbacks.onInputQueueCreated = &onInputQueueCreated;
    callbacks.onContentRectChanged = &onContentRectChanged;
    callbacks.onConfigurationChanged = &onConfigurationChanged;
    callbacks.onInputQueueDestroyed = &onInputQueueDestroyed;
    callbacks.onLowMemory = &onLowMemory;
    if (!startApp)
        return;
    // One application thread for the process (§3): later activities are
    // the same window's, served by the same backend.
    applicationMain = appMain;
    try
        (new Thread(&runApplication)).start();
    catch (Exception)
        __android_log_write(6, "sparkles-wsi", "cannot start the application thread");
}

private __gshared bool runtimeStarted;
private __gshared bool appRunning; // under `channel.lock`
private __gshared void function() nothrow applicationMain;

// The application's thread. Should `main` return, the next activity starts
// it again.
private void runApplication() nothrow
{
    applicationMain();
    channel.lock.lock();
    appRunning = false;
    channel.lock.unlock();
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
    private bool activityLive_ = true; // an activity holds the window now
    private ulong nextFrameToken_ = 1;
    private bool releaseOwed_; // a destroyed surface waits for the next drain
    // References the WSI thread owns, released after the next drain.
    private void*[8] releasing_;
    private size_t releasingCount_;
    private ScaleFactor scale_ = ScaleFactor(1);
    private PhysicalInsets insets_; // the last insets read (`refreshMetrics`)
    private MonoTime insetsReadAt_;
    private MonoTime insetsPollUntil_;

    private ClipboardState!() clipboard_;
    private long seenClipStamp_; // the last clip described
    private long ownClipStamp_;  // the clip this application set
    private ClipText[8] reading_; // per transfer slot: the text being pasted
    private size_t[8] readUnits_; // UTF-16 units already delivered

    private bool textInput_;     // the IME field is installed and polled
    private ubyte[2] held_;      // buttons reported pressed: mouse, stylus
    private PointerSample[64] samples_; // one pointer's samples so far
    private size_t sampleCount_;
    private uint lostReported_;  // input records the channel refused

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
        channel.lock.lock();
        channel.waker = waker.value;
        channel.hasWaker = true;
        channel.lock.unlock();
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

        // The soft keyboard edits a field no callback reports, so it is polled
        // while text input is on (`sparkles.android.ime`).
        if (textInput_)
        {
            pollImeField();
            if (timeout > imePollInterval)
                timeout = imePollInterval;
        }
        if (textInput_ || MonoTime.currTime < insetsPollUntil_)
        {
            if (MonoTime.currTime - insetsReadAt_ >= insetsPollInterval)
                refreshMetrics();
            if (timeout > insetsPollInterval)
                timeout = insetsPollInterval;
        }
        bool work = serviceAll();
        if (work)
            return ioOk(RunStatus.dispatched);
        auto result = loop.runOnce(timeout);
        if (result.hasError)
            return result;
        work = serviceAll();
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

    /**
    Asks for one frame opportunity: a `FrameReadyEvent` at the start of the
    next display frame (`AChoreographer`), stamped with its time. A renderer
    that animates asks again after each frame it draws, and one that does not
    simply stops asking, so nothing wakes the loop while nothing changes.
    Requests made before the frame arrives are one request.
    */
    WsiResult!void requestFrame(WindowId id)
    {
        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        if (cas(&framePending, false, true) && !postToMainThread(&frameJob, null))
        {
            atomicStore(framePending, false);
            return androidFailure!void(WsiOperation.command,
                "frame requests need the activity's main thread", WsiErrorKind.unavailable);
        }
        return wsiOk();
    }

    /**
    Shows `shape` for a mouse or stylus over the window: the system pointer
    icon of that kind (`View.setPointerIcon`, Android 7 and later), applied
    on the main thread. A touch has no pointer to shape.
    */
    WsiResult!void setCursor(WindowId id, PointerShape shape)
    {
        import sparkles.android.pointer_icon : PointerIconType, setPointerIcon;

        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        PointerIconType type;
        final switch (shape)
        {
            case PointerShape.default_: type = PointerIconType.arrow; break;
            case PointerShape.text: type = PointerIconType.text; break;
            case PointerShape.pointer: type = PointerIconType.hand; break;
            case PointerShape.ewResize: type = PointerIconType.horizontalDoubleArrow; break;
            case PointerShape.nsResize: type = PointerIconType.verticalDoubleArrow; break;
            case PointerShape.grab: type = PointerIconType.grab; break;
            case PointerShape.grabbing: type = PointerIconType.grabbing; break;
        }
        if (!setPointerIcon(type))
            return androidFailure!void(WsiOperation.command,
                "pointer icons need the activity's main thread", WsiErrorKind.unavailable);
        return wsiOk();
    }

    /// Ends the activity (`ANativeActivity_finish`): its window then reports
    /// `DestroyedEvent` once the platform destroys it.
    WsiResult!void finishActivity()
    {
        auto owner = requireOwner!void(WsiOperation.close);
        if (owner.hasError)
            return owner;
        if (activityLive_)
            ANativeActivity_finish(activity_);
        return wsiOk();
    }

    /// The activity and its current `ANativeWindow`; `unavailable` while the
    /// activity has no surface.
    /// The connection's display handle, without a window: what a
    /// process-scoped renderer (a Vulkan instance and device) is chosen
    /// from before any window has a surface (§10.1).
    WsiResult!DisplayHandle displayHandle()
    {
        auto owner = requireOwner!DisplayHandle(WsiOperation.queryHandle);
        if (owner.hasError)
            return owner;
        return wsiOk(DisplayHandle(AndroidDisplayHandle(activity_)));
    }

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
            releaseNow();
        }
        foreach (s; releasing_[0 .. releasingCount_])
            ANativeWindow_release(s);
        releasingCount_ = 0;
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
        const @safe pure nothrow @nogc => events_.copySamples(id, pointer, into);

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

    // ── text input ──────────────────────────────────────────────────────────

    /// How often the soft keyboard's field is diffed while text input is on.
    enum imePollInterval = 50.msecs;

    /// How often the insets are reread while text input is on: the user can
    /// dismiss the keyboard, and nothing reports it.
    enum insetsPollInterval = 250.msecs;

    /// How long the insets are still reread after text input turns off, while
    /// the keyboard animates out.
    enum keyboardSettle = 1500.msecs;

    /**
    Turns text input on or off for the window: on, the soft keyboard shows
    and edits a hidden field whose changes arrive as `TextCommittedEvent`s
    (`sparkles.android.ime`); its backspace and Enter arrive as key presses
    and releases of `KEYCODE_DEL` and `KEYCODE_ENTER`. A hardware keyboard
    types whether or not this is on. The IME runs without suggestions, so it
    commits at once and no `CompositionEvent` is reported.
    */
    WsiResult!void setTextInput(WindowId id, bool enabled)
    {
        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        if (enabled && !installImeField())
            return androidFailure!void(WsiOperation.command,
                "the soft keyboard's field needs the activity's main thread",
                WsiErrorKind.unavailable);
        onTyped(enabled ? &wakeForTyped : null);
        textInput_ = enabled;
        showImeKeyboard(enabled);
        // The keyboard animates in or out; the poll in `runIntegratedOnce`
        // follows it until it has settled.
        insetsPollUntil_ = MonoTime.currTime + keyboardSettle;
        refreshMetrics();
        return wsiOk();
    }

    /// Reads the clipboard's description and announces a changed clip, as a
    /// focus gain does. For an application that needs it sooner.
    void refreshClipboard() => noticeClip(describePrimaryClip());

    void close()
    {
        if (closed_)
            return;
        if (textInput_)
            onTyped(null);
        foreach (h; clipboard_.transfers.byLive)
        {
            closeReading(h.index);
            clipboard_.end(h, TransferStatus.failed);
        }
        channel.lock.lock();
        channel.hasWaker = false;
        channel.releasePending = false;
        channel.released.notifyAll();
        channel.lock.unlock();
        closed_ = true;
        open_ = false;
    }

    ~this()
    {
        close();
    }

    // ── internals ───────────────────────────────────────────────────────────

    private bool serviceAll()
    {
        bool work = serviceNotes();
        work |= serviceInput();
        work |= drainTyped();
        work |= pumpTransfers();
        return work;
    }

    private bool serviceInput()
    {
        InputRecord[128] taken;
        bool work;
        for (;;)
        {
            size_t n;
            uint lost;
            channel.lock.lock();
            while (channel.inputCount != 0 && n < taken.length)
            {
                taken[n++] = channel.inputs[channel.inputHead];
                channel.inputHead = (channel.inputHead + 1) % channel.inputs.length;
                --channel.inputCount;
            }
            lost = channel.inputLost;
            channel.lock.unlock();
            if (lost != lostReported_)
            {
                lostReported_ = lost;
                logFailure("input arrived faster than the WSI thread took it; some was lost");
            }
            if (n == 0)
                return work;
            work = true;
            foreach (ref record; taken[0 .. n])
                applyInput(record);
        }
    }

    private void applyInput(in InputRecord r)
    {
        const id = windowHandle();
        if (!id.valid)
            return;
        const at = MonoTime.zero + r.time.nsecs;
        const physical = PhysicalPosition(cast(int) r.x, cast(int) r.y);
        const logical = LogicalPosition(r.x / scale_.value, r.y / scale_.value);
        final switch (r.kind)
        {
            case InputKind.key:
                applyKey(id, r, at);
                break;
            case InputKind.touch:
                TouchEvent e;
                e.contact = touchContact(r.code);
                e.phase = cast(TouchPhase) r.phase;
                e.logicalPosition = logical;
                e.physicalPosition = physical;
                e.pressure = r.pressure;
                e.majorRadius = r.major / 2 / scale_.value;
                e.minorRadius = r.minor / 2 / scale_.value;
                if (e.phase == TouchPhase.moved)
                    pushSamples(id, e, r, logical, at);
                else
                    emit(id, e, at);
                break;
            case InputKind.mouse:
            case InputKind.stylus:
                applyPointer(id, r, logical, physical, at);
                break;
            case InputKind.scroll:
                ScrollEvent e;
                e.logicalPosition = logical;
                e.physicalPosition = physical;
                // Android's axes are positive away from the user and to the
                // right; WSI's `dy` is positive scrolling the content down.
                e.dx = r.major;
                e.dy = -r.minor;
                e.discreteX = cast(int) lround(r.major);
                e.discreteY = -cast(int) lround(r.minor);
                e.source = ScrollSource.wheel;
                e.unit = ScrollUnit.logical;
                e.modifiers = modsOf(r.meta);
                emit(id, e, at);
                break;
        }
    }

    private void applyPointer(WindowId id, in InputRecord r,
        LogicalPosition logical, PhysicalPosition physical, MonoTime at)
    {
        const slot = r.kind == InputKind.stylus ? 1 : 0;
        PointerEvent e;
        e.pointer = PointerId(slot, 1);
        e.phase = cast(PointerPhase) r.phase;
        e.logicalPosition = logical;
        e.physicalPosition = physical;
        e.modifiers = modsOf(r.meta);
        e.pressure = r.pressure;
        final switch (e.phase)
        {
            case PointerPhase.moved:
                pushSamples(id, e, r, logical, at);
                return;
            case PointerPhase.entered, PointerPhase.left:
                emit(id, e, at);
                return;
            case PointerPhase.pressed:
                // A mouse reports a press twice, as the contact and as the
                // button; the first one reported wins.
                const bit = cast(ubyte)(1 << r.button);
                if (held_[slot] & bit)
                    return;
                held_[slot] |= bit;
                e.button = cast(PointerButton) r.button;
                emit(id, e, at);
                return;
            case PointerPhase.released:
                foreach (button; 0 .. 8)
                {
                    const bit = cast(ubyte)(1 << button);
                    if (!(held_[slot] & bit)
                        || (r.button != allButtons && r.button != button))
                        continue;
                    held_[slot] &= ~bit;
                    e.button = cast(PointerButton) button;
                    emit(id, e, at);
                }
                return;
        }
    }

    // Collects one pointer's samples until its newest, then queues the
    // motion with all of them (`ED3`).
    private void pushSamples(Payload)(WindowId id, Payload payload,
        in InputRecord r, LogicalPosition logical, MonoTime at)
    {
        if (sampleCount_ == samples_.length)
        {
            samples_[0 .. $ - 1] = samples_[1 .. $];
            --sampleCount_;
        }
        PointerSample sample;
        sample.timestamp = at;
        sample.position = logical;
        sample.pressure = r.pressure;
        sample.tiltX = r.tiltX;
        sample.tiltY = r.tiltY;
        samples_[sampleCount_++] = sample;
        if (!r.last)
            return;
        auto result = events_.pushMotion(WindowEvent(nextSequence_, id,
            WindowEventPayload(payload), at), samples_[0 .. sampleCount_]);
        sampleCount_ = 0;
        if (!result.hasError)
            ++nextSequence_;
    }

    private void applyKey(WindowId id, in InputRecord r, MonoTime at)
    {
        KeyboardEvent e;
        e.physical = PhysicalKey(cast(uint) r.scanCode, 0);
        e.logical = logicalKey(r.device, r.code);
        e.location = keyLocation(r.code);
        e.action = cast(KeyAction) r.phase;
        e.modifiers = modsOf(r.meta);
        emit(id, e, at);

        // Text is separate from the key (§7), and a chord types none.
        if (e.action == KeyAction.release
            || (r.meta & (metaCtrlOn | metaAltOn | metaMetaOn)) != 0)
            return;
        const c = keyCharacter(r.device, r.code, r.meta);
        if (c <= 0 || (c & combiningAccent) != 0)
            return;
        const dchar[1] typed = [cast(dchar) c];
        emitTextOf(typed[], at);
    }

    // The soft keyboard's edits: text, and backspace and Enter as keys.
    private bool drainTyped()
    {
        if (!textInput_)
            return false;
        dchar[256] run;
        size_t n;
        bool work;
        const id = windowHandle();
        for (dchar c = popTypedChar(); c != 0; c = popTypedChar())
        {
            work = true;
            if (c != imeBackspace && c != imeEnter)
            {
                if (n < run.length)
                    run[n++] = c;
                continue;
            }
            if (id.valid)
            {
                emitTextOf(run[0 .. n], MonoTime.currTime);
                n = 0;
                tapKey(id, c == imeBackspace ? keycodeDel : keycodeEnter);
            }
        }
        if (id.valid)
            emitTextOf(run[0 .. n], MonoTime.currTime);
        return work;
    }

    private void tapKey(WindowId id, int keyCode)
    {
        KeyboardEvent e;
        e.logical = LogicalKey(LogicalKeyKind.named, dchar.init, keyCode);
        e.action = KeyAction.press;
        emit(id, e);
        e.action = KeyAction.release;
        emit(id, e);
    }

    private void emitTextOf(scope const(dchar)[] text, MonoTime at)
    {
        const id = windowHandle();
        if (text.length == 0 || !id.valid)
            return;
        char[256 * 4] bytes;
        auto encoded = utf32ToUtf8(text, bytes[]);
        if (encoded.hasError)
            return;
        auto result = events_.pushText(nextSequence_, id, bytes[0 .. encoded.value],
            (TextId committed, size_t kept) => TextCommittedEvent(committed), at);
        if (!result.hasError)
            ++nextSequence_;
    }

    // The key's identity at its unshifted base level (`LogicalKey`).
    private static LogicalKey logicalKey(int device, int keyCode)
    {
        const c = keyCharacter(device, keyCode, 0);
        if (c >= 0x20 && c != 0x7F && (c & combiningAccent) == 0)
            return LogicalKey(LogicalKeyKind.character, cast(dchar) c, keyCode);
        return keyCode != 0
            ? LogicalKey(LogicalKeyKind.named, dchar.init, keyCode)
            : LogicalKey.init;
    }

    private bool serviceNotes()
    {
        Note[32] taken;
        size_t n;
        channel.lock.lock();
        while (channel.count != 0)
        {
            taken[n++] = channel.notes[channel.head];
            channel.head = (channel.head + 1) % channel.notes.length;
            --channel.count;
        }
        channel.lock.unlock();

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
                // The new activity's surface can come before the previous
                // one's loss: report that loss first, so the application lets
                // go of the old surface before it sees the new one.
                if (surface_ !is null && live.valid)
                {
                    surface_ = null;
                    reportMetrics(live);
                }
                surface_ = cast(void*) note.surface;
                if (live.valid)
                {
                    if (!windows_[live].ready)
                        becomeReady(live);
                    else
                        refreshMetrics();
                    offerFrame(live);
                }
                break;
            case NoteKind.surfaceResized:
                if (live.valid && cast(void*) note.surface is surface_)
                    refreshMetrics();
                break;
            case NoteKind.surfaceRedraw:
                if (live.valid && cast(void*) note.surface is surface_)
                    offerFrame(live);
                break;
            case NoteKind.surfaceDestroyed:
                if (note.wsiReleases)
                    releaseAfterDrain(cast(void*) note.surface);
                if (cast(void*) note.surface !is surface_)
                    break;
                surface_ = null;
                if (live.valid)
                    // A zero pixel extent suspends presentation (`F01`).
                    reportMetrics(live);
                if (note.wsiReleases)
                    break;
                if (live.valid)
                    releaseOwed_ = true;
                else
                    releaseNow();
                break;
            case NoteKind.focusGained:
                if (live.valid)
                    emit(live, FocusChangedEvent(true));
                refreshMetrics();
                noticeClip(describePrimaryClip());
                break;
            case NoteKind.focusLost:
                if (live.valid)
                    emit(live, FocusChangedEvent(false));
                break;
            case NoteKind.resumed:
                noteActivityResumed(true);
                if (live.valid)
                    emit(live, OccludedEvent(false));
                break;
            case NoteKind.paused:
                noteActivityResumed(false);
                if (live.valid)
                    emit(live, OccludedEvent(true));
                break;
            case NoteKind.destroyed:
                // The activity ended with no other started: the window stays,
                // without a surface, for the next one (§9.5).
                activityLive_ = false;
                break;
            case NoteKind.activityStarted:
                activity_ = cast(void*) nativeActivity();
                activityLive_ = true;
                refreshConfiguration();
                if (textInput_)
                {
                    installImeField();
                    showImeKeyboard(true);
                }
                break;
            case NoteKind.lowMemory:
                emit(WindowId.init, MemoryPressureEvent(true));
                break;
            case NoteKind.frame:
                if (live.valid && surface_ !is null)
                    emit(live, FrameReadyEvent(nextFrameToken_++, 0),
                        MonoTime.zero + note.frameNanos.nsecs);
                break;
            case NoteKind.contentRect, NoteKind.configuration:
                if (note.kind == NoteKind.configuration)
                    refreshConfiguration();
                // Insets or the density may have changed; the surface's
                // pixels did not.
                refreshMetrics();
                break;
        }
    }

    // A surface reference this thread owns, released once the drain that
    // reports its loss has returned. Should more be owed than one drain
    // releases, the oldest goes now.
    private void releaseAfterDrain(void* surface)
    {
        if (releasingCount_ == releasing_.length)
        {
            ANativeWindow_release(releasing_[0]);
            foreach (i; 1 .. releasing_.length)
                releasing_[i - 1] = releasing_[i];
            --releasingCount_;
        }
        releasing_[releasingCount_++] = surface;
    }

    // The surface-destroyed callback waits on this.
    private void releaseNow()
    {
        channel.lock.lock();
        channel.releasePending = false;
        channel.released.notifyAll();
        channel.lock.unlock();
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
            physical, scale_, physical.width == 0 ? PhysicalInsets.init : insets_);
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
        readMetrics();
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

    // Rereads the density and the insets (`sparkles.android.window_metrics`)
    // and reports the metrics if they changed. Each is a JNI round trip, so
    // this runs when something may have changed, and while text input is on,
    // when the user can dismiss the keyboard unannounced, every
    // `insetsPollInterval`.
    private void refreshMetrics()
    {
        readMetrics();
        const live = windowHandle();
        if (live.valid && windows_[live].ready)
            reportMetrics(live);
    }

    private void readMetrics()
    {
        insetsReadAt_ = MonoTime.currTime;
        const density = displayDensity();
        if (density > 0)
            scale_ = ScaleFactor(density);
        const reading = windowInsets();
        if (reading.known)
        {
            static uint edge(int a, int b) => cast(uint)(a > b ? a : b > 0 ? b : 0);
            insets_ = PhysicalInsets(
                edge(reading.bars[0], reading.keyboard[0]),
                edge(reading.bars[1], reading.keyboard[1]),
                edge(reading.bars[2], reading.keyboard[2]),
                edge(reading.bars[3], reading.keyboard[3]));
        }
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

    private void emit(Payload)(WindowId id, Payload payload,
        MonoTime at = MonoTime.currTime)
    {
        auto result = events_.pushCoalesced(WindowEvent(nextSequence_, id,
            WindowEventPayload(payload), at));
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

// ── input helpers ───────────────────────────────────────────────────────────

private enum : int
{
    metaShiftOn = 0x1,
    metaAltOn = 0x2,
    metaCtrlOn = 0x1000,
    metaMetaOn = 0x10000,
    keycodeEnter = 66,
    keycodeDel = 67,
    /// `KeyCharacterMap.COMBINING_ACCENT`: the result is a dead key's accent.
    combiningAccent = int.min,
}

/// A finger's contact id: past the mouse (0) and the stylus (1).
private PointerId touchContact(int pointerId) @safe pure nothrow @nogc
    => PointerId(16 + pointerId, 1);

private Mods modsOf(int meta) @safe pure nothrow @nogc
    => Mods(
        ctrl: (meta & metaCtrlOn) != 0,
        alt: (meta & metaAltOn) != 0,
        shift: (meta & metaShiftOn) != 0,
        super_: (meta & metaMetaOn) != 0);

private KeyLocation keyLocation(int keyCode) @safe pure nothrow @nogc
{
    switch (keyCode)
    {
        case 57, 59, 113, 117: // ALT_LEFT, SHIFT_LEFT, CTRL_LEFT, META_LEFT
            return KeyLocation.left;
        case 58, 60, 114, 118: // ALT_RIGHT, SHIFT_RIGHT, CTRL_RIGHT, META_RIGHT
            return KeyLocation.right;
        case 144: .. case 163: // NUMPAD_0 .. NUMPAD_RIGHT_PAREN
            return KeyLocation.numpad;
        default:
            return KeyLocation.standard;
    }
}

// The soft keyboard's field typed: wake the WSI thread to drain it.
private void wakeForTyped() nothrow @nogc
{
    channel.lock.lock();
    const wake = channel.hasWaker;
    auto waker = channel.waker;
    channel.lock.unlock();
    if (wake)
        waker.wake();
}

private WsiResult!T androidFailure(T)(WsiOperation operation,
    scope const(char)[] diagnostic, WsiErrorKind kind = WsiErrorKind.nativeFailure)
    => wsiErr!T(wsiError(kind, operation, BackendKind.android,
        diagnostic: diagnostic));
