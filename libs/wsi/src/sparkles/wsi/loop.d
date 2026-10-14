/**
Deterministic WSI recording core.

The native backends use the same generation, ordering, bounded-queue, and
non-reentrant-drain rules. This implementation gives those rules executable
tests before a display server is involved; it intentionally exposes no native
handle.
*/
module sparkles.wsi.loop;

import std.math : isFinite;
import sparkles.base.pool.pool : Pool, PoolError;
import sparkles.base.pool.text_pool : TextPool;
static import sparkles.base.pool.text_pool;

import sparkles.wsi.events;
import sparkles.wsi.handles;
import sparkles.wsi.types;

@safe:

/**
A backend's bounded event queue (`ED1`), with its text beside it (`ED8`).

Events are plain values; the text they carry lives in a `TextPool` the queue
owns and is named in the payload by a `TextId`. Text is readable through
`withText` while the drain that delivers its event runs, and is released when
that event's sink call returns.

Params:
    Capacity = event slots
    TextBytes = the text arena shared by every queued event's text
*/
struct EventQueue(size_t Capacity, size_t TextBytes = maxEventText + 1)
if (Capacity > 0 && TextBytes > 0)
{
    private WindowEvent[Capacity] events_;
    private size_t head_;
    private size_t count_;
    private bool draining_;
    private uint dropped_;
    private ulong droppedSequence_;
    // One text slot more than there are event slots: a drain pops an event
    // before its sink runs, so the event in flight still holds its text while
    // the sink enqueues a full queue's worth.
    private TextPool!(EventTextTag, Capacity + 1, TextBytes,
        TextBytes < maxEventText ? TextBytes : maxEventText) texts_;

    bool full() const pure nothrow @nogc => count_ == Capacity;
    bool empty() const pure nothrow @nogc => count_ == 0;
    size_t length() const pure nothrow @nogc => count_;

    /// Events dropped since the last drain; the next drain reports and
    /// clears it.
    uint dropped() const pure nothrow @nogc => dropped_;

    /// Whether arrivals are refused until the next drain reports the loss.
    bool admissionClosed() const pure nothrow @nogc => full || dropped_ != 0;

    /**
    `ED5`: a full queue drops the arriving event and counts it rather than
    failing. A consumer that stops draining must not be able to fail a
    dispatch, and through it the loop. The loss is reported by the next
    drain and is visible in the delivered sequence numbers as a gap.

    From the first drop until that report, every arrival is dropped, even one
    that would fit: an event refused for want of text space (`pushText`) can
    leave a slot free, and admitting a later event into it would queue a
    sequence above a dropped one, which no position of the notice could then
    order (`ED6`).
    */
    WsiResult!void push(WindowEvent event) pure nothrow @nogc
    {
        if (admissionClosed)
        {
            drop(event.sequence);
            return wsiOk();
        }

        events_[(head_ + count_) % Capacity] = event;
        ++count_;
        return wsiOk();
    }

    /**
    Stores `text` in the queue's text pool and pushes the event that
    `make(id, kept)` builds around it: `id` names the stored text and `kept`
    is how many of its bytes were kept, so a payload with offsets into the
    text can clamp them (`CompositionEvent.clampTo`). Empty text takes no
    pool slot and is named by `TextId.init`.

    When the queue refuses arrivals, or the pool cannot hold the text, the
    event is dropped and counted (`ED5`, `ED8`); text is truncated only at
    `maxEventText`, never for want of space.
    */
    WsiResult!void pushText(Make)(ulong sequence, WindowId window,
        scope const(char)[] text, scope Make make)
    {
        if (admissionClosed)
        {
            drop(sequence);
            return wsiOk();
        }

        TextId id;
        size_t kept;
        if (text.length != 0)
        {
            auto interned = texts_.intern(text);
            if (interned.hasError)
            {
                drop(sequence);
                return wsiOk();
            }
            id = interned.value;
            kept = texts_.lengthOf(id).value;
        }
        return push(WindowEvent(sequence, window, WindowEventPayload(make(id, kept))));
    }

    /**
    Push, coalescing over $(LREF supersedes): scans the queue's trailing
    run of superseded-kind events and, when one of this event's kind and
    window is found there, replaces that event's payload where it sits —
    so bounded capacity survives native event floods whose intermediate
    observations no consumer needs (a resize drag interleaves metrics and
    expose events, hundreds per dispatch). The scan stops at the first
    event that must keep its place. A merged event keeps its sequence, so
    drained sequences stay strictly increasing, the sequence names when
    the merged run began, and the payload names its newest observation.
    */
    WsiResult!void pushCoalesced(WindowEvent event) pure nothrow @nogc
    {
        size_t scanned;
        while (scanned < count_)
        {
            ref candidate =
                events_[(head_ + count_ - 1 - scanned) % Capacity];
            if (supersedes(candidate, event))
            {
                // `ED2`: merge in place. The queued event keeps its
                // sequence and its position, so only the observation it
                // carries is replaced. That consumes no slot, costs no
                // compaction, and keeps every queued sequence below any
                // dropped one, which is what lets `ED5`'s notice go last
                // and still increase.
                const keptSequence = candidate.sequence;
                candidate = event;
                candidate.sequence = keptSequence;
                return wsiOk();
            }
            // Only events that themselves could coalesce with something may
            // be scanned past; anything else anchors the queue's order.
            if (!coalescible(candidate) || candidate.window != event.window)
                break;
            ++scanned;
        }
        return push(event);
    }

    /**
    Drain the events present at entry. Events appended by the sink are deferred
    to the next drain, and a recursive drain is rejected.

    The text pool is held borrowed for the whole drain, so the slice a sink
    reads through `withText` stays put even if the sink causes more text to be
    queued. Each event's text is released once its sink call returns, also
    when the sink throws.
    */
    WsiResult!size_t drain(Sink)(scope Sink sink)
    {
        if (draining_)
            return wsiErr!size_t(wsiError(WsiErrorKind.reentrant,
                WsiOperation.dispatch, diagnostic: "recursive WSI event drain"));

        draining_ = true;
        scope (exit) draining_ = false;
        auto borrowed = texts_.borrow();

        size_t available = count_;
        foreach (_; 0 .. available)
        {
            auto event = events_[head_];
            events_[head_] = WindowEvent.init;
            head_ = (head_ + 1) % Capacity;
            --count_;
            scope (exit)
                releaseText(event);
            sink(event);
        }
        if (dropped_ != 0)
        {
            // `ED5`: report the loss last. Every dropped event's sequence
            // is above everything queued when it was dropped, and a merge
            // never introduces a higher one, so last is the only position
            // that keeps `ED6`'s strictly increasing order.
            auto notice = WindowEvent(droppedSequence_, WindowId.init,
                WindowEventPayload(EventsDroppedEvent(dropped_)));
            dropped_ = 0;
            droppedSequence_ = 0;
            ++available;
            sink(notice);
        }
        return wsiOk(available);
    }

    /**
    Calls `fn(text, truncated)` — or `fn(text)` — with the text `id` names
    (`ED8`). Valid while the drain that delivered the event runs; afterwards
    the id is stale and this returns `WsiErrorKind.staleId`. `TextId.init`
    names the empty text.
    */
    WsiResult!void withText(Fn)(in TextId id, scope Fn fn)
    {
        if (id == TextId.init)
        {
            static if (__traits(compiles, fn("", false)))
                fn("", false);
            else
                fn("");
            return wsiOk();
        }
        if (texts_.withText(id, fn).hasError)
            return wsiErr!void(wsiError(WsiErrorKind.staleId,
                WsiOperation.command,
                diagnostic: "event text is read during the drain that delivers it"));
        return wsiOk();
    }

    /**
    Copies `event`'s text into `pool`, which the caller owns, and returns the
    same event naming the copy — for an event kept past its drain callback,
    recorded, replayed or handed to another thread (`ED8`). An event with no
    text is returned unchanged.
    */
    WsiResult!WindowEvent retain(Pool)(WindowEvent event, ref Pool pool)
    if (is(Pool.Id == TextId))
    {
        const id = textOf(event);
        if (id == TextId.init)
            return wsiOk(event);
        auto copied = sparkles.base.pool.text_pool.retain(texts_, id, pool);
        if (copied.hasError)
            return wsiErr!WindowEvent(wsiError(
                copied.error == PoolError.full
                    ? WsiErrorKind.capacity : WsiErrorKind.staleId,
                WsiOperation.command,
                diagnostic: copied.error == PoolError.full
                    ? "the destination text pool is full"
                    : "event text is retained during the drain that delivers it"));
        setTextOf(event, copied.value);
        return wsiOk(event);
    }

    private void drop(ulong sequence) pure nothrow @nogc
    {
        if (dropped_ != uint.max)
            ++dropped_;
        if (sequence > droppedSequence_)
            droppedSequence_ = sequence;
    }

    private void releaseText(in WindowEvent event) pure nothrow @nogc
    {
        const id = textOf(event);
        if (id != TextId.init)
            texts_.release(id);
    }
}

@("wsi.loop.aMergedEventKeepsItsSequenceAndTakesTheNewestObservation")
@safe pure nothrow @nogc
unittest
{
    import std.sumtype : match;

    // `ED2`: merging replaces the observation in place. The sequence names
    // when the run began, so drained order is unaffected by how long a flood
    // ran; the payload names its newest state.
    EventQueue!8 queue;
    const window = WindowId(1, 1);
    static SurfaceMetrics metricsWide(uint width) @safe pure nothrow @nogc
        => SurfaceMetrics(LogicalSize(width, 100), PhysicalSize(width, 100),
            ScaleFactor(1));

    assert(!queue.pushCoalesced(WindowEvent(1, window,
        WindowEventPayload(SurfaceMetricsChangedEvent(metricsWide(100)))))
        .hasError);
    assert(!queue.pushCoalesced(WindowEvent(2, window,
        WindowEventPayload(SurfaceMetricsChangedEvent(metricsWide(200)))))
        .hasError);
    assert(queue.length == 1, "the second observation took the first's slot");

    ulong sequence;
    double width = 0;
    assert(!queue.drain((WindowEvent event) @safe pure nothrow @nogc {
        sequence = event.sequence;
        event.payload.match!(
            (in SurfaceMetricsChangedEvent value) {
                width = value.metrics.logicalSize.width;
            },
            (_) {});
    }).hasError);
    assert(sequence == 1);
    assert(width == 200);
}

@("wsi.loop.overflowIsCountedAndReportedRatherThanFatal")
@safe pure nothrow @nogc
unittest
{
    import std.sumtype : match;

    // `ED5`: a consumer that stops draining must not be able to fail a
    // dispatch, and through it the loop. Keyboard events never merge, so this
    // flood can only overflow.
    EventQueue!4 queue;
    const window = WindowId(1, 1);
    ulong sequence = 1;
    foreach (_; 0 .. 10)
        assert(!queue.push(WindowEvent(sequence++, window,
            WindowEventPayload(KeyboardEvent()))).hasError,
            "overflow is not a failure");
    assert(queue.dropped == 6);

    ulong last;
    size_t delivered;
    uint reported;
    ulong noticeSequence;
    auto result = queue.drain((WindowEvent event) @safe pure nothrow @nogc {
        assert(event.sequence > last, "drained order stays increasing");
        last = event.sequence;
        ++delivered;
        event.payload.match!(
            (in EventsDroppedEvent value) {
                reported = value.count;
                noticeSequence = event.sequence;
            },
            (_) {});
    });
    // Four survivors plus the notice, which arrives last carrying the
    // sequence of the last event lost, so the gap names what went missing.
    assert(!result.hasError && result.value == 5 && delivered == 5);
    assert(reported == 6 && noticeSequence == 10);
    assert(queue.dropped == 0, "the loss is reported once");
}

@("wsi.loop.aTextPoolMissClosesAdmissionUntilTheNotice")
@safe pure nothrow @nogc
unittest
{
    import std.sumtype : match;

    // `ED5` with `ED8`: an event refused for want of text space leaves its
    // slot free. Admitting the next arrival into it would queue sequence 3
    // above dropped sequence 2, and no position of the notice could then
    // keep the drained order increasing.
    EventQueue!(4, 8) queue;
    const window = WindowId(0, 1);
    static TextCommittedEvent committed(TextId text, size_t)
        => TextCommittedEvent(text);

    assert(!queue.pushText(1, window, "12345678", &committed).hasError);
    assert(!queue.pushText(2, window, "x", &committed).hasError);
    assert(queue.dropped == 1 && queue.length == 1, "no text space for 2");
    assert(!queue.push(WindowEvent(3, window,
        WindowEventPayload(KeyboardEvent()))).hasError);
    assert(queue.dropped == 2 && queue.length == 1, "3 is refused too");

    ulong last;
    ulong[2] seen;
    size_t n;
    uint reported;
    assert(!queue.drain((WindowEvent event) @safe pure nothrow @nogc {
        assert(event.sequence > last, "drained order stays increasing");
        last = event.sequence;
        seen[n++] = event.sequence;
        event.payload.match!(
            (in EventsDroppedEvent e) { reported = e.count; },
            (_) {});
    }).hasError);
    assert(seen == [1, 3] && reported == 2);

    // The notice reopened admission.
    assert(!queue.pushText(4, window, "y", &committed).hasError);
    assert(queue.length == 1 && queue.dropped == 0);
}

@("wsi.loop.textIsReadableDuringItsDrainAndStaleAfter")
@safe unittest
{
    RecordingWsi!(1, 8) wsi;
    WindowConfig config;
    config.logicalSize = LogicalSize(10, 10);
    const id = wsi.createWindow(config).value;
    assert(!wsi.commitText(id, "héllo").hasError);
    assert(!wsi.commitText(id, "").hasError);

    TextId kept;
    bool read;
    size_t empties;
    assert(!wsi.drain((WindowEvent event) {
        event.payload.match!(
            (in TextCommittedEvent e) {
                if (e.text == TextId.init)
                {
                    // Empty text takes no slot and reads as "".
                    assert(!wsi.withText(e.text, (scope const(char)[] text) {
                        assert(text.length == 0);
                    }).hasError);
                    ++empties;
                    return;
                }
                kept = e.text;
                assert(!wsi.withText(e.text,
                    (scope const(char)[] text, bool truncated) {
                        read = text == "héllo" && !truncated;
                    }).hasError);
            },
            (_) {});
    }).hasError);
    assert(read && empties == 1);

    // `ED8`: the drain is over, so the id is stale.
    const late = wsi.withText(kept, (scope const(char)[]) {
        assert(false, "a stale id must not be read");
    });
    assert(late.hasError && late.error.kind == WsiErrorKind.staleId);
}

@("wsi.loop.retainCopiesTextPastTheDrain")
@safe unittest
{
    RecordingWsi!(1, 8) wsi;
    WindowConfig config;
    config.logicalSize = LogicalSize(10, 10);
    const id = wsi.createWindow(config).value;
    assert(!wsi.commitText(id, "kept").hasError);

    TextPool!(EventTextTag, 4, 64) log;
    WindowEvent recorded;
    assert(!wsi.drain((WindowEvent event) {
        if (textOf(event) != TextId.init)
            recorded = wsi.retain(event, log).value;
    }).hasError);

    // The recorded event names the copy, readable through the consumer's pool.
    bool same;
    assert(log.withText(textOf(recorded), (scope const(char)[] text) {
        same = text == "kept";
    }).hasValue);
    assert(same && recorded.window == id);
}

@("wsi.loop.theEventInFlightKeepsItsTextWhileTheSinkEnqueues")
@safe nothrow
unittest
{
    // `ED8`: drain pops an event before its sink runs, so the queue holds one
    // text slot more than it has event slots. A sink refilling the queue
    // must not find the text pool full.
    EventQueue!2 queue;
    const window = WindowId(0, 1);
    static TextCommittedEvent committed(TextId text, size_t)
        => TextCommittedEvent(text);
    ulong sequence = 1;
    assert(!queue.pushText(sequence++, window, "a", &committed).hasError);
    assert(!queue.pushText(sequence++, window, "b", &committed).hasError);

    bool refilled;
    assert(!queue.drain((WindowEvent event) {
        if (!refilled)
        {
            refilled = true;
            assert(!queue.pushText(sequence++, window, "c", &committed).hasError);
        }
    }).hasError);
    assert(queue.dropped == 0 && queue.length == 1);
}

@("wsi.loop.aThrowingSinkStillReleasesItsText")
@safe unittest
{
    EventQueue!2 queue;
    const window = WindowId(0, 1);
    static TextCommittedEvent committed(TextId text, size_t)
        => TextCommittedEvent(text);
    assert(!queue.pushText(1, window, "boom", &committed).hasError);

    try
        queue.drain((WindowEvent event) { throw new Exception("sink failed"); });
    catch (Exception)
    {
    }
    assert(queue.texts_.liveCount == 0 && !queue.texts_.borrowed);
    assert(!queue.drain((WindowEvent event) {}).hasError, "draining_ was reset");
}

@("wsi.loop.eventQueueSurvivesAResizeFloodByCoalescing")
@safe pure nothrow @nogc
unittest
{
    // The shape a resize drag produces: alternating metrics and expose
    // events, far more than the queue holds. Coalescing keeps the newest
    // of each kind instead of failing on capacity.
    EventQueue!8 queue;
    const window = WindowId(1, 1);
    ulong sequence = 1;
    foreach (i; 0 .. 100)
    {
        const metrics = SurfaceMetrics(LogicalSize(100 + i, 100),
            PhysicalSize(100 + i, 100), ScaleFactor(1));
        assert(!queue.pushCoalesced(WindowEvent(sequence++, window,
            WindowEventPayload(SurfaceMetricsChangedEvent(metrics))))
            .hasError);
        assert(!queue.pushCoalesced(WindowEvent(sequence++, window,
            WindowEventPayload(ExposedEvent()))).hasError);
    }
    assert(queue.length == 2);

    // Keyboard events anchor the order: nothing coalesces across them,
    // and drained sequences stay strictly increasing.
    assert(!queue.pushCoalesced(WindowEvent(sequence++, window,
        WindowEventPayload(KeyboardEvent()))).hasError);
    const metrics = SurfaceMetrics(LogicalSize(1, 2), PhysicalSize(1, 2),
        ScaleFactor(1));
    assert(!queue.pushCoalesced(WindowEvent(sequence++, window,
        WindowEventPayload(SurfaceMetricsChangedEvent(metrics))))
        .hasError);
    assert(queue.length == 4);
    ulong last;
    size_t drained;
    auto result = queue.drain((WindowEvent event) @safe pure nothrow @nogc {
        assert(event.sequence > last);
        last = event.sequence;
        ++drained;
    });
    assert(!result.hasError && drained == 4);
}

/// Headless implementation used for lifecycle and host tests.
struct RecordingWsi(size_t MaxWindows = 8, size_t MaxEvents = 64)
if (MaxWindows > 0 && MaxEvents > 0)
{
    private struct Window
    {
        SurfaceMetrics metrics;
    }

    private Pool!(WindowId, Window, MaxWindows) windows_;
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

        const metrics = SurfaceMetrics(
            config.logicalSize,
            PhysicalSize(cast(uint) config.logicalSize.width,
                cast(uint) config.logicalSize.height),
            ScaleFactor(1));
        auto inserted = windows_.insert(Window(metrics));
        if (inserted.hasError)
            return failure!WindowId(WsiErrorKind.capacity,
                WsiOperation.createWindow, "WSI window capacity reached");

        WindowId id = inserted.value;
        auto queued = emit(id, ReadyEvent(metrics));
        assert(!queued.hasError, "capacity was checked before allocation");
        return wsiOk(id);
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
        windows_.at(slot.value).metrics = metrics;
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

        windows_.remove(id);
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

    bool isLive(WindowId id) const pure nothrow @nogc => windows_.isLive(id);

    size_t pendingEvents() const pure nothrow @nogc => events_.length;

    WsiResult!size_t drain(Sink)(scope Sink sink) => events_.drain(sink);

    /// Calls `fn` with the text a delivered event names, during the drain
    /// that delivers it (`ED8`). See `EventQueue.withText`.
    WsiResult!void withText(Fn)(TextId id, scope Fn fn)
        => events_.withText(id, fn);

    /// Copies an event's text into a `TextPool` the caller owns (`ED8`).
    WsiResult!WindowEvent retain(P)(WindowEvent event, ref P pool)
        => events_.retain(event, pool);

    /**
    Queues a `TextCommittedEvent` for `id`, as a native input method would
    on commit: the recording counterpart of a backend's text path.
    */
    WsiResult!void commitText(WindowId id, scope const(char)[] text)
    {
        auto slot = checkedSlot(id);
        if (slot.hasError)
            return wsiErr!void(slot.error);
        auto result = events_.pushText(nextSequence_, id, text,
            (TextId committed, size_t kept) => TextCommittedEvent(committed));
        if (!result.hasError)
            ++nextSequence_;
        return result;
    }

    void close() pure nothrow @nogc
    {
        closed_ = true;
        windows_.clear();
    }

    private WsiResult!size_t checkedSlot(WindowId id) pure nothrow @nogc
    {
        auto index = windows_.resolve(id);
        if (index.hasError)
            return failure!size_t(WsiErrorKind.staleId, WsiOperation.command,
                index.error == PoolError.invalid
                    ? "invalid WSI window id" : "stale WSI window id");
        size_t slot = index.value;
        return wsiOk(slot);
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
        seen[count++] = e;
    }).value == 3);
    assert(seen[0].sequence == 1 && seen[1].sequence == 2
        && seen[2].sequence == 3);
    assert(seen[0].payload.match!((in ReadyEvent event) => true, _ => false));
    assert(seen[1].payload.match!(
        (in CloseRequestedEvent event) => true, _ => false));
    assert(seen[2].payload.match!(
        (in DestroyedEvent event) => true, _ => false));

    const second = wsi.createWindow(config).value;
    assert(second.index == first.index && second.generation != first.generation);
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
