/**
Deterministic WSI recording core.

The native backends use the same generation, ordering, bounded-queue, and
non-reentrant-drain rules. This implementation gives those rules executable
tests before a display server is involved; it intentionally exposes no native
handle.
*/
module sparkles.wsi.loop;

import std.math : isFinite;

import sparkles.wsi.events;
import sparkles.wsi.handles;
import sparkles.wsi.types;

@safe:

struct EventQueue(size_t Capacity)
if (Capacity > 0)
{
    private WindowEvent[Capacity] events_;
    private size_t head_;
    private size_t count_;
    private bool draining_;

    bool full() const pure nothrow @nogc => count_ == Capacity;
    bool empty() const pure nothrow @nogc => count_ == 0;
    size_t length() const pure nothrow @nogc => count_;

    WsiResult!void push(WindowEvent event) pure nothrow @nogc
    {
        if (full)
            return wsiErr!void(wsiError(WsiErrorKind.capacity,
                WsiOperation.dispatch, diagnostic: "WSI event queue is full"));

        assignEvent(events_[(head_ + count_) % Capacity], event);
        ++count_;
        return wsiOk();
    }

    /**
    Drain the events present at entry. Events appended by the sink are deferred
    to the next drain, and a recursive drain is rejected.
    */
    WsiResult!size_t drain(Sink)(scope Sink sink)
    {
        if (draining_)
            return wsiErr!size_t(wsiError(WsiErrorKind.reentrant,
                WsiOperation.dispatch, diagnostic: "recursive WSI event drain"));

        draining_ = true;
        scope (exit) draining_ = false;

        size_t available = count_;
        foreach (_; 0 .. available)
        {
            auto event = events_[head_];
            clearEvent(events_[head_]);
            head_ = (head_ + 1) % Capacity;
            --count_;
            sink(event);
        }
        return wsiOk(available);
    }
}

/// Headless implementation used for lifecycle and host tests.
struct RecordingWsi(size_t MaxWindows = 8, size_t MaxEvents = 64)
if (MaxWindows > 0 && MaxEvents > 0)
{
    private struct Slot
    {
        uint generation;
        bool live;
        SurfaceMetrics metrics;
    }

    private Slot[MaxWindows] windows_;
    private EventQueue!MaxEvents events_;
    private ulong nextSequence_ = 1;
    private bool closed_;

    WsiResult!WindowId createWindow(in WindowConfig config)
    {
        if (closed_)
            return failure!WindowId(WsiErrorKind.closed,
                WsiOperation.createWindow, "WSI is closed");
        if (!isFinite(config.logicalSize.width)
            || !isFinite(config.logicalSize.height)
            || config.logicalSize.width < 0 || config.logicalSize.height < 0
            || config.logicalSize.width > uint.max
            || config.logicalSize.height > uint.max)
            return failure!WindowId(WsiErrorKind.invalidArgument,
                WsiOperation.createWindow, "invalid logical window size");
        if (events_.full)
            return failure!WindowId(WsiErrorKind.capacity,
                WsiOperation.createWindow, "WSI event queue is full");

        foreach (i, ref slot; windows_)
        {
            if (slot.live)
                continue;

            ++slot.generation;
            if (slot.generation == 0)
                ++slot.generation;
            slot.live = true;
            slot.metrics = SurfaceMetrics(
                config.logicalSize,
                PhysicalSize(cast(uint) config.logicalSize.width,
                    cast(uint) config.logicalSize.height),
                ScaleFactor(1));

            auto id = WindowId(cast(uint) i + 1, slot.generation);
            auto queued = emit(id, ReadyEvent(slot.metrics));
            assert(!queued.hasError, "capacity was checked before allocation");
            return wsiOk(id);
        }

        return failure!WindowId(WsiErrorKind.capacity,
            WsiOperation.createWindow, "WSI window capacity reached");
    }

    WsiResult!void requestClose(WindowId id)
        => checkedEmit(id, CloseRequestedEvent());

    WsiResult!void setMetrics(WindowId id, SurfaceMetrics metrics)
    {
        auto slot = checkedSlot(id);
        if (slot.hasError)
            return wsiErr!void(slot.error);
        if (!metrics.scale.valid)
            return failure!void(WsiErrorKind.invalidArgument,
                WsiOperation.command, "scale factor must be positive");

        auto queued = emit(id, SurfaceMetricsChangedEvent(metrics));
        if (queued.hasError)
            return queued;
        windows_[slot.value].metrics = metrics;
        return wsiOk();
    }

    WsiResult!void destroyWindow(WindowId id)
    {
        auto slot = checkedSlot(id);
        if (slot.hasError)
            return wsiErr!void(slot.error);
        if (events_.full)
            return failure!void(WsiErrorKind.capacity, WsiOperation.close,
                "WSI event queue is full");

        windows_[slot.value].live = false;
        return emit(id, DestroyedEvent());
    }

    WsiResult!NativeHandles nativeHandles(WindowId id)
    {
        auto slot = checkedSlot(id);
        if (slot.hasError)
            return wsiErr!NativeHandles(slot.error);
        return failure!NativeHandles(WsiErrorKind.unsupported,
            WsiOperation.queryHandle,
            "recording windows have no native handle");
    }

    bool isLive(WindowId id) pure nothrow @nogc
    {
        if (!id.valid || id.slot > MaxWindows)
            return false;
        const slot = windows_[id.slot - 1];
        return slot.live && slot.generation == id.generation;
    }

    size_t pendingEvents() const pure nothrow @nogc => events_.length;

    WsiResult!size_t drain(Sink)(scope Sink sink) => events_.drain(sink);

    void close() pure nothrow @nogc
    {
        closed_ = true;
        foreach (ref slot; windows_)
            slot.live = false;
    }

    private WsiResult!size_t checkedSlot(WindowId id) pure nothrow @nogc
    {
        if (!id.valid || id.slot > MaxWindows)
            return failure!size_t(WsiErrorKind.staleId,
                WsiOperation.command, "invalid WSI window id");

        size_t index = cast(size_t) id.slot - 1;
        const slot = windows_[index];
        if (!slot.live || slot.generation != id.generation)
            return failure!size_t(WsiErrorKind.staleId,
                WsiOperation.command, "stale WSI window id");
        return wsiOk(index);
    }

    private WsiResult!void checkedEmit(Payload)(WindowId id, Payload payload)
    {
        auto slot = checkedSlot(id);
        if (slot.hasError)
            return wsiErr!void(slot.error);
        return emit(id, payload);
    }

    private WsiResult!void emit(Payload)(WindowId id, Payload payload)
    {
        auto result = events_.push(WindowEvent(nextSequence_, id,
            WindowEventPayload(payload)));
        if (!result.hasError)
            ++nextSequence_;
        return result;
    }

    private WsiResult!T failure(T)(WsiErrorKind kind, WsiOperation operation,
        scope const(char)[] diagnostic) pure nothrow @nogc
        => wsiErr!T(wsiError(kind, operation, diagnostic: diagnostic));
}

// `SumType.opAssign` is conservatively `@system` under DIP1000. Every WSI
// alternative owns only value storage (no borrowed slices), so copying it into
// the fixed queue cannot escape a reference. Keep that trust in one place.
private void assignEvent(ref WindowEvent destination, ref WindowEvent source)
    @trusted pure nothrow @nogc
{
    destination = source;
}

private void clearEvent(ref WindowEvent destination)
    @trusted pure nothrow @nogc
{
    destination = WindowEvent.init;
}

@("wsi.loop.lifecycleIsOrderedAndGenerationSafe")
unittest
{
    RecordingWsi!(1, 8) wsi;
    auto config = WindowConfig();
    config.logicalSize = LogicalSize(320, 200);
    const first = wsi.createWindow(config).value;
    assert(wsi.isLive(first));
    assert(!wsi.requestClose(first).hasError);
    assert(!wsi.destroyWindow(first).hasError);
    assert(!wsi.isLive(first));

    WindowEvent[3] seen;
    size_t count;
    assert(wsi.drain((WindowEvent e) {
        assignEvent(seen[count++], e);
    }).value == 3);
    assert(seen[0].sequence == 1 && seen[1].sequence == 2
        && seen[2].sequence == 3);
    assert(seen[0].payload.match!((in ReadyEvent event) => true, _ => false));
    assert(seen[1].payload.match!(
        (in CloseRequestedEvent event) => true, _ => false));
    assert(seen[2].payload.match!(
        (in DestroyedEvent event) => true, _ => false));

    const second = wsi.createWindow(config).value;
    assert(second.slot == first.slot && second.generation != first.generation);
    assert(wsi.requestClose(first).error.kind == WsiErrorKind.staleId);
}

@("wsi.loop.eventsAppendedDuringDrainAreDeferred")
unittest
{
    RecordingWsi!(1, 8) wsi;
    const id = wsi.createWindow(WindowConfig()).value;
    size_t firstPass;
    auto drained = wsi.drain((WindowEvent event) {
        ++firstPass;
        assert(!wsi.requestClose(id).hasError);
    });
    assert(drained.value == 1 && firstPass == 1);
    assert(wsi.pendingEvents == 1);
    assert(wsi.drain((WindowEvent event) {}).value == 1);
}

@("wsi.loop.recordingHandleFailureIsTyped")
unittest
{
    RecordingWsi!() wsi;
    const id = wsi.createWindow(WindowConfig()).value;
    const handles = wsi.nativeHandles(id);
    assert(handles.hasError);
    assert(handles.error.kind == WsiErrorKind.unsupported);
    assert(handles.error.operation == WsiOperation.queryHandle);
}
