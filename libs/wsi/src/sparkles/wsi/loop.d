/**
Deterministic WSI recording core.

The native backends use the same generation, ordering, bounded-queue, and
non-reentrant-drain rules. This implementation gives those rules executable
tests before a display server is involved; it intentionally exposes no native
handle.
*/
module sparkles.wsi.loop;

import core.time : MonoTime;
import std.math : isFinite;
import sparkles.base.pool.pool : Pool, PoolError;
import sparkles.base.pool.text_pool : TextPool;
static import sparkles.base.pool.text_pool;

import sparkles.wsi.clipboard;
import sparkles.wsi.events;
import sparkles.wsi.handles;
import sparkles.wsi.history;
import sparkles.wsi.types;

@safe:

/**
A backend's bounded event queue (`ED1`), with its text beside it (`ED8`).

Events are plain values; the text they carry lives in a `TextPool` the queue
owns and is named in the payload by a `TextId`. Text is readable through
`withText` while the drain that delivers its event runs, and is released when
that event's sink call returns.

Pointer motion merges in place into the same window and pointer's queued
motion (`ED2`), and every native sample is kept beside the queue in a
history ring (`ED3`), see $(LREF pushMotion).

Params:
    Capacity = event slots
    TextBytes = the text arena shared by every queued event's text
    HistoryDepth = samples kept per (window, pointer)
    HistoryKeys = (window, pointer) pairs with a history ring at once
*/
struct EventQueue(size_t Capacity, size_t TextBytes = maxEventText + 1,
    size_t HistoryDepth = 64, size_t HistoryKeys = 4)
if (Capacity > 0 && TextBytes > 0)
{
    // Where a (window, pointer)'s merge partner sits while it is queued.
    private static struct MotionSlot
    {
        WindowId window;
        PointerId pointer;
        bool relative;
        ulong sequence;
        size_t slot;
    }

    // A window whose motion policy differs from the default (`ED9`).
    private static struct MotionPolicy
    {
        WindowId window;
        bool coalesce = true;
        bool sumRelative = true;
    }

    private WindowEvent[Capacity] events_;
    private MotionSlot[2 * HistoryKeys] motion_;
    private MotionPolicy[4] policies_;
    private SampleHistory!(HistoryDepth, HistoryKeys) history_;
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

        endMotionRun(event);
        events_[(head_ + count_) % Capacity] = event;
        ++count_;
        return wsiOk();
    }

    /**
    Pushes pointer motion, merging it in place (`ED2`), and records its
    native `samples` in the history ring of its window and pointer (`ED3`).

    `event` is a `moved` `PointerEvent`, a `RelativePointerEvent` or a
    `moved` `TouchEvent`; its `samples` count is set to `samples.length`,
    and with none given the event itself is the one sample recorded. While
    the same window and pointer's motion of the same kind is still queued,
    and no press, release, enter or leave of that pointer came after it,
    the queued event takes this one's position, modifiers, pressure and
    timestamp, adds its relative delta and sample count, and keeps its
    sequence and place. Touch never merges (`ED4`); its samples are only
    recorded. A window's merging and relative summing are switched off by
    $(LREF setMotionPolicy).
    */
    WsiResult!void pushMotion(WindowEvent event,
        scope const(PointerSample)[] samples...) pure nothrow @nogc
    {
        PointerId pointer;
        bool relative, touch;
        const motion = event.payload.match!(
            (in PointerEvent e) { pointer = e.pointer; return e.phase == PointerPhase.moved; },
            (in RelativePointerEvent e) { pointer = e.pointer; relative = true; return true; },
            (in TouchEvent e) { pointer = e.contact; touch = true; return e.phase == TouchPhase.moved; },
            _ => false);
        assert(motion, "pushMotion takes pointer motion");

        const count = samples.length == 0 ? 1 : cast(uint) samples.length;
        event.payload.match!(
            (ref PointerEvent e) { e.samples = count; },
            (ref RelativePointerEvent e) { e.samples = count; },
            (ref TouchEvent e) { e.samples = count; },
            (ref _) {});
        foreach (ref sample; samples)
            history_.record(event.window, pointer, sample);
        if (samples.length == 0)
            history_.record(event.window, pointer, sampleOf(event));

        if (dropped_ != 0)
        {
            drop(event.sequence);
            return wsiOk();
        }
        const policy = policyOf(event.window);
        const merges = !touch && policy.coalesce
            && (!relative || policy.sumRelative);
        if (merges)
            if (auto queued = queuedMotion(event.window, pointer, relative))
            {
                merge(*queued, event);
                return wsiOk();
            }
        if (full)
        {
            drop(event.sequence);
            return wsiOk();
        }
        const slot = (head_ + count_) % Capacity;
        events_[slot] = event;
        ++count_;
        if (merges)
            noteMotion(event.window, pointer, relative, event.sequence, slot);
        return wsiOk();
    }

    /**
    Sets `window`'s motion policy (`ED9`): whether its pointer motion merges
    at all, and whether relative motion merges by summing. Both default to
    on. At most four windows may differ from the default; a fifth fails with
    `capacity`.
    */
    WsiResult!void setMotionPolicy(WindowId window, bool coalesce,
        bool sumRelative) pure nothrow @nogc
    {
        foreach (ref p; policies_)
            if (p.window == window)
            {
                p.coalesce = coalesce;
                p.sumRelative = sumRelative;
                if (coalesce && sumRelative)
                    p = MotionPolicy.init;
                return wsiOk();
            }
        if (coalesce && sumRelative)
            return wsiOk();
        foreach (ref p; policies_)
            if (p.window == WindowId.init)
            {
                p = MotionPolicy(window, coalesce, sumRelative);
                return wsiOk();
            }
        return wsiErr!void(wsiError(WsiErrorKind.capacity, WsiOperation.command,
            diagnostic: "at most four windows may change their motion policy"));
    }

    /**
    Copies the newest samples of `window`'s `pointer` into `into`, in arrival
    order, and returns how many (`ED3`). A merged event's own samples are its
    newest `samples`.
    */
    size_t copySamples(WindowId window, PointerId pointer,
        scope PointerSample[] into) const pure nothrow @nogc
        => history_.copy(window, pointer, into);

    /// Forgets `window`'s history and motion policy, as when it is destroyed.
    void forgetWindow(WindowId window) pure nothrow @nogc
    {
        history_.forget(window);
        foreach (ref p; policies_)
            if (p.window == window)
                p = MotionPolicy.init;
        foreach (ref m; motion_)
            if (m.window == window)
                m = MotionSlot.init;
    }

    /**
    Stores `text` in the queue's text pool and pushes the event that
    `make(id, kept)` builds around it: `id` names the stored text and `kept`
    is how many of its bytes were kept, so a payload with offsets into the
    text can clamp them (`CompositionEvent.clampTo`). Empty text takes no
    pool slot and is named by `TextId.init`. `timestamp` stamps the event
    (`ED7`).

    When the queue refuses arrivals, or the pool cannot hold the text, the
    event is dropped and counted (`ED5`, `ED8`); text is truncated only at
    `maxEventText`, never for want of space.
    */
    WsiResult!void pushText(Make)(ulong sequence, WindowId window,
        scope const(char)[] text, scope Make make,
        MonoTime timestamp = MonoTime.init)
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
        return push(WindowEvent(sequence, window, WindowEventPayload(make(id, kept)),
            timestamp));
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
    Pointer motion goes to $(LREF pushMotion), with no samples beyond the
    event itself.
    */
    WsiResult!void pushCoalesced(WindowEvent event) pure nothrow @nogc
    {
        // Pointer motion has its own merge, with history (`ED2`, `ED3`).
        if (isMotion(event))
            return pushMotion(event);
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

    // A press, release, enter or leave of a pointer anchors its motion: what
    // was queued before it must stay before it (`ED2`).
    private void endMotionRun(in WindowEvent event) pure nothrow @nogc
    {
        PointerId pointer;
        const anchors = event.payload.match!(
            (in PointerEvent e) { pointer = e.pointer; return e.phase != PointerPhase.moved; },
            _ => false);
        if (!anchors)
            return;
        foreach (ref m; motion_)
            if (m.window == event.window && m.pointer == pointer)
                m = MotionSlot.init;
    }

    // The one sample a motion event names when its backend passed none.
    private static PointerSample sampleOf(in WindowEvent event) pure nothrow @nogc
    {
        PointerSample sample;
        sample.timestamp = event.timestamp;
        event.payload.match!(
            (in PointerEvent e) {
                sample.position = e.logicalPosition;
                sample.pressure = e.pressure;
            },
            (in RelativePointerEvent e) { sample.dx = e.dx; sample.dy = e.dy; },
            (in TouchEvent e) {
                sample.position = e.logicalPosition;
                sample.pressure = e.pressure;
            },
            (_) {});
        return sample;
    }

    private MotionPolicy policyOf(WindowId window) const pure nothrow @nogc
    {
        foreach (p; policies_)
            if (p.window == window)
                return p;
        return MotionPolicy.init;
    }

    // The queued motion a new sample of (window, pointer) merges into, if
    // it is still queued: drained or overwritten slots fail the sequence
    // check, since sequences only increase.
    private WindowEvent* queuedMotion(WindowId window, PointerId pointer,
        bool relative) pure nothrow @nogc return
    {
        foreach (ref m; motion_)
        {
            if (m.sequence == 0 || m.window != window || m.pointer != pointer
                || m.relative != relative)
                continue;
            const offset = (m.slot + Capacity - head_) % Capacity;
            if (offset < count_ && events_[m.slot].sequence == m.sequence)
                return &events_[m.slot];
            m = MotionSlot.init;
            return null;
        }
        return null;
    }

    private void noteMotion(WindowId window, PointerId pointer, bool relative,
        ulong sequence, size_t slot) pure nothrow @nogc
    {
        size_t free = motion_.length;
        foreach (i, ref m; motion_)
        {
            if (m.window == window && m.pointer == pointer
                && m.relative == relative)
            {
                free = i;
                break;
            }
            const offset = (m.slot + Capacity - head_) % Capacity;
            const stale = m.sequence == 0 || offset >= count_
                || events_[m.slot].sequence != m.sequence;
            if (stale && free == motion_.length)
                free = i;
        }
        // Every entry live and for other pointers: this one simply does not
        // merge until one frees up.
        if (free != motion_.length)
            motion_[free] = MotionSlot(window, pointer, relative, sequence, slot);
    }

    private static void merge(ref WindowEvent queued, in WindowEvent next)
        pure nothrow @nogc
    {
        const keptSequence = queued.sequence;
        uint before;
        double dx = 0, dy = 0;
        queued.payload.match!(
            (in PointerEvent e) { before = e.samples; },
            (in RelativePointerEvent e) { before = e.samples; dx = e.dx; dy = e.dy; },
            (_) {});
        queued = next;
        queued.sequence = keptSequence;
        queued.payload.match!(
            (ref PointerEvent e) { e.samples += before; },
            (ref RelativePointerEvent e) { e.samples += before; e.dx += dx; e.dy += dy; },
            (ref _) {});
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

version (unittest)
{
    import sparkles.input.events : PointerButton;

    private enum testWindow = WindowId(0, 1);
    private enum testPointer = PointerId(0, 1);

    private WindowEvent moved(ulong sequence, double x, PointerId pointer = testPointer)
        @safe pure nothrow @nogc
    {
        PointerEvent e;
        e.pointer = pointer;
        e.phase = PointerPhase.moved;
        e.logicalPosition = LogicalPosition(x, 0);
        return WindowEvent(sequence, testWindow, WindowEventPayload(e));
    }

    private WindowEvent pressed(ulong sequence) @safe pure nothrow @nogc
    {
        PointerEvent e;
        e.pointer = testPointer;
        e.phase = PointerPhase.pressed;
        e.button = PointerButton.left;
        return WindowEvent(sequence, testWindow, WindowEventPayload(e));
    }

    private PointerSample at(double x) @safe pure nothrow @nogc
        => PointerSample(position: LogicalPosition(x, 0));

    // Each drained event's (sequence, x, samples), motion or not.
    private struct Drained
    {
        ulong[8] sequence;
        double[8] x;
        uint[8] samples;
        size_t count;

        void opCall(WindowEvent event) @safe pure nothrow @nogc
        {
            sequence[count] = event.sequence;
            event.payload.match!(
                (in PointerEvent e) { x[count] = e.logicalPosition.x; samples[count] = e.samples; },
                (in RelativePointerEvent e) { x[count] = e.dx; samples[count] = e.samples; },
                (in TouchEvent e) { x[count] = e.logicalPosition.x; samples[count] = e.samples; },
                (_) {});
            ++count;
        }
    }
}

@("wsi.loop.motionMergesInPlaceAndKeepsEverySample")
@safe pure nothrow @nogc
unittest
{
    // `ED2`: a run of motion is one queued event with the newest position,
    // its first sequence and the run's sample count; `ED3`: every sample is
    // in the ring, in arrival order.
    EventQueue!8 queue;
    assert(!queue.pushMotion(moved(1, 10), at(10)).hasError);
    assert(!queue.pushMotion(moved(2, 20), at(15), at(20)).hasError);
    assert(!queue.pushMotion(moved(3, 30), at(30)).hasError);
    assert(queue.length == 1);

    Drained drained;
    assert(!queue.drain(&drained.opCall).hasError);
    assert(drained.count == 1 && drained.sequence[0] == 1);
    assert(drained.x[0] == 30 && drained.samples[0] == 4);

    PointerSample[8] samples;
    assert(queue.copySamples(testWindow, testPointer, samples[]) == 4);
    assert(samples[0].position.x == 10 && samples[3].position.x == 30);
}

@("wsi.loop.aPressAnchorsMotionAndADrainEndsTheRun")
@safe pure nothrow @nogc
unittest
{
    import sparkles.input.events : PointerButton;

    // The last position before a press is delivered before it; motion after
    // the press starts a new run, and so does motion after a drain.
    EventQueue!8 queue;
    assert(!queue.pushMotion(moved(1, 10)).hasError);
    assert(!queue.push(pressed(2)).hasError);
    assert(!queue.pushMotion(moved(3, 20)).hasError);
    assert(!queue.pushMotion(moved(4, 30)).hasError);

    Drained drained;
    assert(!queue.drain(&drained.opCall).hasError);
    assert(drained.count == 3);
    assert(drained.sequence[0] == 1 && drained.x[0] == 10);
    assert(drained.sequence[1] == 2);
    assert(drained.sequence[2] == 3 && drained.x[2] == 30 && drained.samples[2] == 2);

    assert(!queue.pushMotion(moved(5, 40)).hasError);
    Drained after;
    assert(!queue.drain(&after.opCall).hasError);
    assert(after.count == 1 && after.sequence[0] == 5 && after.samples[0] == 1,
        "a drained event is never merged into");
}

@("wsi.loop.aMotionFloodNeverOverflowsTheQueue")
@safe pure nothrow @nogc
unittest
{
    import sparkles.input.events : PointerButton;

    // A flood of one pointer's motion, longer than the queue, interleaved
    // with another pointer's: both merge, nothing drops, and order holds.
    EventQueue!4 queue;
    const other = PointerId(1, 1);
    foreach (i; 0 .. 1000)
    {
        assert(!queue.pushMotion(moved(2 * i + 1, i)).hasError);
        assert(!queue.pushMotion(moved(2 * i + 2, -i, other)).hasError);
    }
    assert(queue.length == 2 && queue.dropped == 0);

    Drained drained;
    assert(!queue.drain(&drained.opCall).hasError);
    assert(drained.count == 2 && drained.sequence[0] < drained.sequence[1]);
    assert(drained.x[0] == 999 && drained.samples[0] == 1000);
    assert(drained.x[1] == -999 && drained.samples[1] == 1000);
    PointerSample[100] kept;
    assert(queue.copySamples(testWindow, testPointer, kept[]) == 64,
        "the ring holds its depth");
}

@("wsi.loop.relativeMotionSumsAndTouchNeverMerges")
@safe pure nothrow @nogc
unittest
{
    EventQueue!8 queue;
    const relative = (ulong sequence, double dx) @safe pure nothrow @nogc
        => WindowEvent(sequence, testWindow, WindowEventPayload(
            RelativePointerEvent(testPointer, dx, 0, true)));
    assert(!queue.pushMotion(relative(1, 1.5)).hasError);
    assert(!queue.pushMotion(relative(2, 2.5)).hasError);

    TouchEvent touch;
    touch.contact = PointerId(5, 1);
    touch.phase = TouchPhase.moved;
    assert(!queue.pushMotion(WindowEvent(3, testWindow, WindowEventPayload(touch)),
        at(1), at(2), at(3)).hasError);
    assert(!queue.pushMotion(WindowEvent(4, testWindow, WindowEventPayload(touch)),
        at(4)).hasError);

    Drained drained;
    assert(!queue.drain(&drained.opCall).hasError);
    assert(drained.count == 3);
    assert(drained.x[0] == 4 && drained.samples[0] == 2, "relative deltas sum");
    assert(drained.samples[1] == 3 && drained.samples[2] == 1, "touch stays apart");
    PointerSample[8] kept;
    assert(queue.copySamples(testWindow, PointerId(5, 1), kept[]) == 4);
}

@("wsi.loop.coalescedPushesRouteMotionToItsOwnMerge")
@safe pure nothrow @nogc
unittest
{
    // Every backend queues through `pushCoalesced`, so this is where native
    // motion starts merging with history.
    EventQueue!8 queue;
    assert(!queue.pushCoalesced(moved(1, 10)).hasError);
    assert(!queue.pushCoalesced(moved(2, 20)).hasError);
    assert(queue.length == 1);
    PointerSample[4] samples;
    assert(queue.copySamples(testWindow, testPointer, samples[]) == 2);
    assert(samples[0].position.x == 10 && samples[1].position.x == 20);
}

@("wsi.loop.aWindowCanTurnMergingOff")
@safe pure nothrow @nogc
unittest
{
    import sparkles.input.events : PointerButton;

    // `ED9`: a drawing view keeps every event, history or not.
    EventQueue!8 queue;
    assert(!queue.setMotionPolicy(testWindow, false, true).hasError);
    assert(!queue.pushMotion(moved(1, 10)).hasError);
    assert(!queue.pushMotion(moved(2, 20)).hasError);
    assert(queue.length == 2);
    assert(!queue.setMotionPolicy(testWindow, true, true).hasError);
    assert(!queue.pushMotion(moved(3, 30)).hasError);
    assert(!queue.pushMotion(moved(4, 40)).hasError);
    assert(queue.length == 3);
}

@("wsi.loop.motionAfterADropIsDroppedToo")
@safe pure nothrow @nogc
unittest
{
    import sparkles.input.events : PointerButton;

    // `ED5`'s latch covers merges: once an event was dropped, merging a newer
    // position into an older queued event would reorder it past the loss.
    EventQueue!2 queue;
    assert(!queue.pushMotion(moved(1, 10)).hasError);
    assert(!queue.push(pressed(2)).hasError);
    assert(!queue.push(pressed(3)).hasError);
    assert(queue.dropped == 1);
    assert(!queue.pushMotion(moved(4, 20)).hasError);
    assert(queue.dropped == 2);
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

@("wsi.loop.aReplacedSurfaceIsReportedLostBeforeItsSuccessor")
@safe pure nothrow @nogc
unittest
{
    import std.sumtype : match;

    // `ED4`: a surface shown, lost, and replaced by one of the same size
    // before the drain drains as the loss and then the new surface. Merging
    // the replacement into either earlier observation would hide the loss.
    EventQueue!8 queue;
    const window = WindowId(1, 1);
    static WindowEvent metrics(ulong sequence, WindowId window, uint side)
        @safe pure nothrow @nogc
        => WindowEvent(sequence, window, WindowEventPayload(SurfaceMetricsChangedEvent(
            SurfaceMetrics(LogicalSize(side, side), PhysicalSize(side, side),
                ScaleFactor(1)))));
    assert(!queue.pushCoalesced(metrics(1, window, 100)).hasError);
    assert(!queue.pushCoalesced(metrics(2, window, 0)).hasError);
    assert(!queue.pushCoalesced(metrics(3, window, 100)).hasError);

    bool[4] suspended;
    size_t n;
    assert(!queue.drain((WindowEvent event) @safe pure nothrow @nogc {
        event.payload.match!(
            (in SurfaceMetricsChangedEvent e) { suspended[n++] = e.metrics.suspended; },
            (_) {});
    }).hasError);
    assert(n == 2, "the loss superseded the first observation, nothing else merged");
    assert(suspended[0] && !suspended[1]);
}

@("wsi.loop.overflowIsCountedAndReportedRatherThanFatal")
@safe pure nothrow @nogc
unittest
{
    import sparkles.input.events : PointerButton;

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
    import sparkles.input.events : PointerButton;

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
    import sparkles.input.events : PointerButton;

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
    import sparkles.input.events : PointerButton;

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
    import sparkles.input.events : PointerButton;

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
    private ClipboardState!() clipboard_;
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
        events_.forgetWindow(id);
        return emit(id, DestroyedEvent());
    }

    /// Recording has no display connection.
    WsiResult!DisplayHandle displayHandle()
        => failure!DisplayHandle(WsiErrorKind.unsupported, WsiOperation.queryHandle,
            "recording has no display connection");

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

    /**
    Queues pointer input for `id`, as a native backend would: motion through
    `pushMotion` (`ED2`, `ED3`), with one history sample per position in
    `samples` (the event's own position when empty); anything else in order.
    */
    WsiResult!void injectPointer(WindowId id, PointerEvent event,
        scope const(PointerSample)[] samples...)
    {
        auto slot = checkedSlot(id);
        if (slot.hasError)
            return wsiErr!void(slot.error);
        auto queued = WindowEvent(nextSequence_, id, WindowEventPayload(event));
        WsiResult!void result;
        if (event.phase != PointerPhase.moved)
            result = events_.push(queued);
        else
            result = events_.pushMotion(queued, samples);
        if (!result.hasError)
            ++nextSequence_;
        return result;
    }

    /// Sets `id`'s motion policy (`ED9`); see `EventQueue.setMotionPolicy`.
    WsiResult!void setMotionPolicy(WindowId id, bool coalesce, bool sumRelative)
    {
        auto slot = checkedSlot(id);
        if (slot.hasError)
            return wsiErr!void(slot.error);
        return events_.setMotionPolicy(id, coalesce, sumRelative);
    }

    /// The newest samples of `id`'s `pointer`, in arrival order (`ED3`).
    size_t copySamples(WindowId id, PointerId pointer, scope PointerSample[] into)
        const pure nothrow @nogc
        => events_.copySamples(id, pointer, into);


    /**
    Offers `mimeTypes` from `window` on the clipboard; requests pull the bytes
    from `provider`, which must outlive the offer (`DT3`). An offer this
    application made before is withdrawn.
    */
    WsiResult!OfferId offerClipboard(P)(WindowId window,
        scope const(char[])[] mimeTypes, ref P provider)
    if (isDataProvider!P)
    {
        auto slot = checkedSlot(window);
        if (slot.hasError)
            return wsiErr!OfferId(slot.error);
        auto added = clipboard_.add(window, mimeTypes, true);
        if (added.hasError)
            return added;
        clipboard_.offers[added.value].provider =
            (() @trusted => ProviderRef.to(provider))();
        publish(added.value);
        return added;
    }

    /// ditto, for a small whole value: WSI keeps one copy until the offer ends.
    WsiResult!OfferId offerClipboard(WindowId window, scope const(char)[] mimeType,
        scope const(ubyte)[] value)
    {
        auto slot = checkedSlot(window);
        if (slot.hasError)
            return wsiErr!OfferId(slot.error);
        auto added = clipboard_.add(window, mimeType, true);
        if (added.hasError)
            return added;
        auto record = &clipboard_.offers[added.value];
        record.value.bytes ~= value;
        record.hasValue = true;
        publish(added.value);
        return added;
    }

    /// Ends an offer this application made, reporting `withdrawn` (`DT1`).
    WsiResult!void withdrawClipboard(OfferId offer)
    {
        auto record = clipboard_.offers.get(offer);
        if (record is null || !record.own)
            return failure!void(WsiErrorKind.staleId, WsiOperation.command,
                "no live offer of this application's");
        announce(offer, DataOfferAction.withdrawn);
        clipboard_.drop(offer);
        return wsiOk();
    }

    /**
    Starts streaming `offer`'s `mimeType` content into `sink`, which must
    outlive its `finish` call (`DT2`).
    */
    WsiResult!TransferId receive(S)(OfferId offer, scope const(char)[] mimeType,
        ref S sink)
    if (isDataSink!S)
        => clipboard_.begin(offer, mimeType, (() @trusted => SinkRef.to(sink))());

    /// Ends a transfer with `cancelled`; its sink then hears nothing more.
    WsiResult!void cancelTransfer(TransferId transfer)
        => clipboard_.cancel(transfer);

    /**
    The recording backend's transfer dispatch: moves one chunk of at most
    `chunkBytes` for every live transfer, ending each whose provider is
    exhausted. Returns whether any transfer is still live.
    */
    bool pumpTransfers(size_t chunkBytes = 64 * 1024)
    in (chunkBytes > 0)
    {
        import sparkles.base.buffer : UniqueBuffer;

        UniqueBuffer!(ubyte, 1) buffer;
        buffer.length = chunkBytes;
        foreach (h; clipboard_.transfers.byLive)
        {
            ref transfer = clipboard_.transfers[h];
            auto offer = clipboard_.offers.get(transfer.offer);
            if (offer is null)
            {
                clipboard_.end(h, TransferStatus.failed);
                continue;
            }
            const n = offer.fill(transfer.mime[], transfer.offset, buffer[]);
            if (n == 0)
            {
                clipboard_.end(h, TransferStatus.completed);
                continue;
            }
            transfer.offset += n;
            transfer.sink.chunk(h, buffer[][0 .. n]);
        }
        return clipboard_.transfers.liveCount != 0;
    }

    /**
    Stands in for another application copying: its offer replaces the
    clipboard, withdrawing this application's. `provider` serves its bytes.
    */
    WsiResult!OfferId simulateForeignOffer(P)(scope const(char[])[] mimeTypes,
        ref P provider)
    if (isDataProvider!P)
    {
        auto added = clipboard_.add(WindowId.init, mimeTypes, false);
        if (added.hasError)
            return added;
        clipboard_.offers[added.value].provider =
            (() @trusted => ProviderRef.to(provider))();
        publish(added.value);
        return added;
    }

    // Makes `offer` the clipboard's, withdrawing the offer it replaces when
    // that one was this application's, and announces one event per type.
    private void publish(OfferId offer)
    {
        const previous = clipboard_.current;
        if (auto old = clipboard_.offers.get(previous))
        {
            if (old.own)
                announce(previous, DataOfferAction.withdrawn);
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
    import sparkles.input.events : PointerButton;

    RecordingWsi!() wsi;
    const id = wsi.createWindow(WindowConfig()).value;
    const handles = wsi.nativeHandles(id);
    assert(handles.hasError);
    assert(handles.error.kind == WsiErrorKind.unsupported);
    assert(handles.error.operation == WsiOperation.queryHandle);
}

version (unittest)
{
    import sparkles.input.events : PointerButton;

    /// Serves `size` bytes of a position-derived pattern, so a receiver can
    /// verify every byte without the provider keeping a copy.
    private struct PatternProvider
    {
        ulong size;

        static ubyte at(ulong offset) @safe pure nothrow @nogc
            => cast(ubyte)(offset * 31 + (offset >> 8));

        size_t fill(scope const(char)[], ulong offset, scope ubyte[] buffer)
            @safe pure nothrow @nogc
        {
            if (offset >= size)
                return 0;
            const n = size - offset < buffer.length
                ? cast(size_t)(size - offset) : buffer.length;
            foreach (i; 0 .. n)
                buffer[i] = at(offset + i);
            return n;
        }
    }

    /// Checks each byte against the pattern as it arrives; keeps nothing.
    private struct PatternSink
    {
        ulong received;
        size_t chunks;
        size_t largestChunk;
        bool mismatch;
        uint finishes;
        TransferStatus status;

        void chunk(TransferId, scope const(ubyte)[] bytes) @safe pure nothrow @nogc
        {
            foreach (i, b; bytes)
                mismatch |= b != PatternProvider.at(received + i);
            received += bytes.length;
            ++chunks;
            if (bytes.length > largestChunk)
                largestChunk = bytes.length;
        }

        void finish(TransferId, TransferStatus how) @safe pure nothrow @nogc
        {
            ++finishes;
            status = how;
        }
    }

    private WindowId openRecordingWindow(R)(ref R wsi)
    {
        WindowConfig config;
        config.logicalSize = LogicalSize(10, 10);
        return wsi.createWindow(config).value;
    }
}

@("wsi.loop.clipboardRoundTripsInChunks")
@safe unittest
{
    RecordingWsi!(1, 16) wsi;
    const window = openRecordingWindow(wsi);
    auto provider = PatternProvider(300_000);
    const(char)[][2] types = ["text/plain;charset=utf-8", "application/x-test"];
    const offer = wsi.offerClipboard(window, types[], provider).value;

    // `DT1`: one `offered` event per type, naming the offer and no content.
    size_t announced;
    assert(!wsi.drain((WindowEvent event) {
        event.payload.match!(
            (in DataOfferEvent e) {
                assert(e.offer == offer && e.action == DataOfferAction.offered);
                assert(!wsi.withText(e.mimeType, (scope const(char)[] mime) {
                    assert(mime == types[announced]);
                }).hasError);
                ++announced;
            },
            (_) {});
    }).hasError);
    assert(announced == 2);

    // `DT2`/`DT4`: the content streams in bounded chunks and ends once.
    PatternSink sink;
    assert(wsi.receive(offer, "application/x-test", sink).hasValue);
    while (wsi.pumpTransfers(64 * 1024)) {}
    assert(sink.received == 300_000 && !sink.mismatch);
    assert(sink.chunks == 5 && sink.largestChunk == 64 * 1024);
    assert(sink.finishes == 1 && sink.status == TransferStatus.completed);

    // A type the offer does not name is refused.
    PatternSink other;
    assert(wsi.receive(offer, "image/png", other).error.kind
        == WsiErrorKind.invalidArgument);
}

@("wsi.loop.aReplacedOfferIsWithdrawnAndStale")
@safe unittest
{
    RecordingWsi!(1, 16) wsi;
    const window = openRecordingWindow(wsi);
    auto ours = PatternProvider(10);
    const(char)[][1] text = ["text/plain"];
    const mine = wsi.offerClipboard(window, text[], ours).value;

    // A transfer in flight when the offer ends fails: its provider need not
    // outlive the offer (`DT3`).
    PatternSink reading;
    assert(wsi.receive(mine, "text/plain", reading).hasValue);

    auto theirs = PatternProvider(5);
    const foreign = wsi.simulateForeignOffer(text[], theirs).value;
    assert(reading.finishes == 1 && reading.status == TransferStatus.failed);

    bool withdrawn;
    bool offered;
    assert(!wsi.drain((WindowEvent event) {
        event.payload.match!(
            (in DataOfferEvent e) {
                withdrawn |= e.offer == mine && e.action == DataOfferAction.withdrawn;
                offered |= e.offer == foreign && e.action == DataOfferAction.offered;
            },
            (_) {});
    }).hasError);
    assert(withdrawn && offered);

    PatternSink late;
    assert(wsi.receive(mine, "text/plain", late).error.kind == WsiErrorKind.staleId);
    assert(wsi.withdrawClipboard(mine).error.kind == WsiErrorKind.staleId);
    assert(late.finishes == 0);

    // The foreign offer is readable like any other.
    PatternSink paste;
    assert(wsi.receive(foreign, "text/plain", paste).hasValue);
    while (wsi.pumpTransfers()) {}
    assert(paste.received == 5 && paste.status == TransferStatus.completed);
}

@("wsi.loop.cancelEndsATransferOnce")
@safe unittest
{
    RecordingWsi!(1, 16) wsi;
    const window = openRecordingWindow(wsi);
    auto provider = PatternProvider(1000);
    const(char)[][1] text = ["text/plain"];
    const offer = wsi.offerClipboard(window, text[], provider).value;

    PatternSink sink;
    const transfer = wsi.receive(offer, "text/plain", sink).value;
    wsi.pumpTransfers(100);
    assert(!wsi.cancelTransfer(transfer).hasError);
    assert(sink.finishes == 1 && sink.status == TransferStatus.cancelled);
    const before = sink.received;
    wsi.pumpTransfers(100);
    assert(sink.received == before && sink.finishes == 1);
    assert(wsi.cancelTransfer(transfer).error.kind == WsiErrorKind.staleId);
}

@("wsi.loop.aWholeValueOfferKeepsOneCopy")
@safe unittest
{
    RecordingWsi!(1, 16) wsi;
    const window = openRecordingWindow(wsi);
    ubyte[5] value = cast(ubyte[5]) "hello";
    const offer = wsi.offerClipboard(window, "text/plain", value[]).value;
    value[] = 0; // the offer holds its own copy

    static struct Collect
    {
        ubyte[16] bytes;
        size_t length;
        bool done;

        void chunk(TransferId, scope const(ubyte)[] b) @safe pure nothrow @nogc
        {
            bytes[length .. length + b.length] = b[];
            length += b.length;
        }

        void finish(TransferId, TransferStatus status) @safe pure nothrow @nogc
        {
            done = status == TransferStatus.completed;
        }
    }

    Collect collect;
    assert(wsi.receive(offer, "text/plain", collect).hasValue);
    while (wsi.pumpTransfers(2)) {}
    assert(collect.done && collect.bytes[0 .. collect.length] == "hello");
}
