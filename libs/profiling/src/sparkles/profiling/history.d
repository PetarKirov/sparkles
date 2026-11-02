/**
The last `N` frames, in a ring of fixed capacity (`PRF3`): adding one
overwrites the oldest and allocates nothing.
*/
module sparkles.profiling.history;

import core.time : Duration;

import sparkles.profiling.frame : FrameRecord;

/// ditto
struct FrameHistory(size_t N)
if (N > 0)
{
    private FrameRecord[N] ring;
    private ulong seen_;

@safe pure nothrow @nogc:

    /// Keeps `r`, dropping the oldest when full.
    void add(in FrameRecord r)
    {
        ring[cast(size_t)(seen_ % N)] = r;
        ++seen_;
    }

    /// How many records it ever saw.
    ulong seen() const => seen_;

    /// How many it holds.
    size_t length() const => seen_ < N ? cast(size_t) seen_ : N;

    /// Whether it holds none.
    bool empty() const => seen_ == 0;

    /// The `i`th record held, oldest first.
    ref const(FrameRecord) opIndex(size_t i) const return
    in (i < length)
        => ring[cast(size_t)((seen_ - length + i) % N)];

    /// The newest record.
    ref const(FrameRecord) last() const return
    in (!empty)
        => this[length - 1];

    /**
    The record numbered `number`, if it is still held: device times arrive
    frames after their frame (`PRF10`), and are written into its record.
    Assumes records are added in number order, one each.
    */
    FrameRecord* find(ulong number) return
    {
        if (empty || number > last.number || last.number - number >= length)
            return null;
        auto r = &ring[cast(size_t)((seen_ - 1 - (last.number - number)) % N)];
        return r.number == number ? r : null;
    }

    /**
    Records that frame `number` reached the display at `shown` (from the
    run's origin), when it is still held: a presentation time arrives frames
    after its record was added (`PRF13`). Returns the record, or null when
    the frame has left the history or was never in it.
    */
    const(FrameRecord)* markShown(ulong number, Duration shown) return
    {
        if (empty || number > ring[cast(size_t)((seen_ - 1) % N)].number)
            return null;
        // Newest first: the frame shown is a recent one.
        foreach_reverse (i; 0 .. length)
        {
            auto r = &ring[cast(size_t)((seen_ - length + i) % N)];
            if (r.number == number)
            {
                // A frame is shown once: a second answer for it is ignored.
                if (r.shownKnown)
                    return null;
                r.shown = shown;
                r.shownKnown = true;
                return r;
            }
            if (r.number < number)
                break;
        }
        return null;
    }

    /// The records held, oldest first.
    auto opSlice() const return
    {
        static struct Range
        {
            const(FrameHistory)* history;
            size_t front_, back_;

            bool empty() const => front_ >= back_;
            ref const(FrameRecord) front() const => (*history)[front_];
            void popFront() { ++front_; }
            size_t length() const => back_ - front_;
        }

        return Range(&this, 0, length);
    }
}

///
@("profiling.history.keepsTheNewest")
@safe pure nothrow @nogc unittest
{
    import core.time : Duration, msecs;

    FrameHistory!4 h;
    assert(h.empty && h.length == 0);
    foreach (n; 0 .. 6)
    {
        FrameRecord r;
        r.number = n;
        h.add(r);
    }
    assert(h.seen == 6 && h.length == 4);
    assert(h[0].number == 2 && h.last.number == 5);
    ulong expected = 2;
    foreach (ref r; h[])
        assert(r.number == expected++);
    assert(expected == 6);
    assert(h.find(5).number == 5 && h.find(2).number == 2);
    assert(h.find(1) is null && h.find(6) is null, "dropped, and not yet seen");
    h.find(3).gpu = Duration.zero + 1.msecs;
    assert(h[1].gpu == 1.msecs);
}

@("profiling.history.marksAFrameShownLate")
@safe pure nothrow @nogc unittest
{
    import core.time : msecs;

    FrameHistory!4 h;
    assert(h.markShown(0, 1.msecs) is null);
    foreach (n; 0 .. 6)
    {
        FrameRecord r;
        r.number = n * 2; // frames not presented leave gaps
        r.start = (n * 10).msecs;
        h.add(r);
    }
    const shown = h.markShown(8, 55.msecs);
    Duration latency;
    assert(shown !is null && shown.latency(latency) && latency == 15.msecs);
    assert(h[2].shownKnown && !h[3].shownKnown);
    assert(h.markShown(2, 1.msecs) is null, "the frame has left the history");
    assert(h.markShown(7, 1.msecs) is null && h.markShown(12, 1.msecs) is null);
    assert(h.markShown(8, 60.msecs) is null && h[2].shown == 55.msecs, "shown once");
}
