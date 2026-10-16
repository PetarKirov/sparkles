/**
Pointer and touch samples kept beside the event queue (`ED3`).

A merged motion event stands for many native samples (`ED2`); a platform that
batches touch delivers one event per frame for many. The samples themselves
live here, one ring per (window, pointer), so a drawing consumer can read
every position while the queue holds one event. History is advisory: a full
ring drops its oldest sample, and a ring for a pointer not seen recently is
reused for a new one.
*/
module sparkles.wsi.history;

import core.time : MonoTime;

import sparkles.wsi.types;

@safe:

/// One native pointer or touch sample.
struct PointerSample
{
    /// The platform's time for the sample, in the loop's monotonic clock
    /// (`ED7`).
    MonoTime timestamp;
    LogicalPosition position;
    /// Relative motion this sample carried; zero for absolute-only devices.
    double dx = 0;
    double dy = 0;
    /// Normalized to 0–1 where the device reports it; NaN where it does not.
    float pressure = float.nan;
    /// Stylus tilt in degrees from the surface normal, along x and y; NaN
    /// where the device reports none.
    float tiltX = float.nan;
    float tiltY = float.nan;
}

/**
Fixed-capacity rings of samples keyed by (window, pointer).

Params:
    Depth = samples kept per (window, pointer)
    Keys = (window, pointer) pairs kept at once; the least recently
        recorded pair's ring is reused when a new pair arrives
*/
struct SampleHistory(size_t Depth, size_t Keys)
if (Depth > 0 && Keys > 0)
{
    private static struct Ring
    {
        WindowId window;
        PointerId pointer;
        ulong lastUse;
        size_t head;
        size_t count;
        ulong dropped;
        PointerSample[Depth] samples;
    }

    private Ring[Keys] rings_;
    private ulong clock_;

    /// Appends `sample` to the ring of (`window`, `pointer`), dropping its
    /// oldest sample when the ring is full.
    void record(WindowId window, PointerId pointer, in PointerSample sample)
        pure nothrow @nogc
    {
        ref ring = ringFor(window, pointer);
        ring.lastUse = ++clock_;
        if (ring.count == Depth)
        {
            ring.head = (ring.head + 1) % Depth;
            --ring.count;
            ++ring.dropped;
        }
        ring.samples[(ring.head + ring.count) % Depth] = sample;
        ++ring.count;
    }

    /// Samples held for (`window`, `pointer`).
    size_t length(WindowId window, PointerId pointer) const pure nothrow @nogc
    {
        if (const ring = find(window, pointer))
            return ring.count;
        return 0;
    }

    /// Samples the ring of (`window`, `pointer`) dropped because it was full.
    ulong dropped(WindowId window, PointerId pointer) const pure nothrow @nogc
    {
        if (const ring = find(window, pointer))
            return ring.dropped;
        return 0;
    }

    /**
    Copies the newest `into.length` samples of (`window`, `pointer`), or all
    it holds if fewer, into `into` in arrival order, and returns how many.
    A merged event's samples are the newest `event.samples` of its pair.
    */
    size_t copy(WindowId window, PointerId pointer, scope PointerSample[] into)
        const pure nothrow @nogc
    {
        const ring = find(window, pointer);
        if (ring is null)
            return 0;
        const n = into.length < ring.count ? into.length : ring.count;
        const first = ring.head + ring.count - n;
        foreach (i; 0 .. n)
            into[i] = ring.samples[(first + i) % Depth];
        return n;
    }

    /// Forgets every ring of `window`, as when it is destroyed.
    void forget(WindowId window) pure nothrow @nogc
    {
        foreach (ref ring; rings_)
            if (ring.window == window)
                ring = Ring.init;
    }

    private const(Ring)* find(WindowId window, PointerId pointer)
        const pure nothrow @nogc return
    {
        foreach (ref ring; rings_)
            if (ring.lastUse != 0 && ring.window == window
                && ring.pointer == pointer)
                return &ring;
        return null;
    }

    private ref Ring ringFor(WindowId window, PointerId pointer)
        pure nothrow @nogc return
    {
        size_t oldest;
        foreach (i, ref ring; rings_)
        {
            if (ring.lastUse != 0 && ring.window == window
                && ring.pointer == pointer)
                return ring;
            if (ring.lastUse < rings_[oldest].lastUse)
                oldest = i;
        }
        rings_[oldest].head = 0;
        rings_[oldest].count = 0;
        rings_[oldest].dropped = 0;
        rings_[oldest].window = window;
        rings_[oldest].pointer = pointer;
        return rings_[oldest];
    }
}

@("wsi.history.aFullRingDropsItsOldestSample")
@safe pure nothrow @nogc
unittest
{
    SampleHistory!(4, 2) history;
    const window = WindowId(0, 1);
    const pointer = PointerId(0, 1);
    foreach (i; 0 .. 6)
        history.record(window, pointer,
            PointerSample(position: LogicalPosition(i, 0)));
    assert(history.length(window, pointer) == 4);
    assert(history.dropped(window, pointer) == 2);

    PointerSample[8] samples;
    assert(history.copy(window, pointer, samples[]) == 4);
    foreach (i; 0 .. 4)
        assert(samples[i].position.x == i + 2, "arrival order, oldest dropped");
    assert(history.copy(window, pointer, samples[0 .. 2]) == 2);
    assert(samples[0].position.x == 4 && samples[1].position.x == 5,
        "a short copy takes the newest samples");
}

@("wsi.history.aNewPointerReusesTheLeastRecentRing")
@safe pure nothrow @nogc
unittest
{
    SampleHistory!(4, 2) history;
    const window = WindowId(0, 1);
    history.record(window, PointerId(1, 1), PointerSample.init);
    history.record(window, PointerId(2, 1), PointerSample.init);
    history.record(window, PointerId(1, 1), PointerSample.init);
    history.record(window, PointerId(3, 1), PointerSample.init);
    assert(history.length(window, PointerId(1, 1)) == 2, "recently used: kept");
    assert(history.length(window, PointerId(2, 1)) == 0, "least recent: reused");
    assert(history.length(window, PointerId(3, 1)) == 1);

    history.forget(window);
    assert(history.length(window, PointerId(1, 1)) == 0);
}
