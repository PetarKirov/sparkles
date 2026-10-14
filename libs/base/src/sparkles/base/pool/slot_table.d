/**
The identity layer of a pool: generations, live bits and the free list.

A `SlotTable` issues and retires `Handle`s and holds nothing else, so it fits
both a pool whose records live beside it (`sparkles.base.pool.pool`) and a
table whose records live somewhere it does not own.

Storage is fixed and inline. The all-zero state is a valid empty table: a slot
that has never been issued has generation 0, and slots are issued from a
high-water mark before (`fifo`) or after (`lifo`) the freed ones, so no
constructor has to seed a free list.

See `docs/specs/base/pool.md` §3 (`POOL1`–`POOL7`).
*/
module sparkles.base.pool.slot_table;

public import sparkles.base.pool.handle : Handle, PoolError, PoolResult,
    Reuse, Wrap, isHandle, poolErr, poolOk;

/**
A fixed-capacity table of generational slots.

Params:
    H = the handle type issued, some `Handle!Tag`
    capacity = the number of slots
    reuse = which freed slot is issued next (`POOL6`)
    wrap = what a slot whose generation reaches `generationLimit` becomes
        (`POOL5`)
    generationLimit = the largest generation a slot may reach. `uint.max`
        unless the generation must fit fewer bits — a handle packed into a
        `user_data` word, or a test that needs to reach the limit quickly.
*/
struct SlotTable(H, size_t capacity, Reuse reuse = Reuse.lifo,
    Wrap wrap = Wrap.retire, uint generationLimit = uint.max)
if (isHandle!H && capacity > 0 && capacity < uint.max && generationLimit > 0)
{
    private uint[capacity] generation_; // 0 = never issued
    private bool[capacity] live_;
    private uint[capacity] freed_;      // a stack (lifo) or a ring (fifo)
    private uint freedHead_;            // fifo only: the ring's oldest entry
    private uint freedCount_;
    private uint highWater_;            // slots [0, highWater_) were issued once
    private uint liveCount_;
    private uint retired_;

    /// The number of slots, including retired ones.
    enum size_t slotCapacity = capacity;

    /// The number of live handles.
    size_t liveCount() const @safe pure nothrow @nogc => liveCount_;

    /// The number of slots that can still hold a live handle: capacity less
    /// the retired slots.
    size_t usableCapacity() const @safe pure nothrow @nogc
        => capacity - retired_;

    /// Whether `insert` would fail with `full`.
    bool full() const @safe pure nothrow @nogc
        => freedCount_ == 0 && highWater_ == capacity;

    /**
    Issues a handle to a free slot, or `PoolError.full` with the table
    unchanged.
    */
    PoolResult!H insert() @safe pure nothrow @nogc
    {
        uint index;
        if (reuse == Reuse.fifo && highWater_ < capacity)
            index = highWater_++;
        else if (freedCount_ != 0)
            index = popFreed();
        else if (highWater_ < capacity)
            index = highWater_++;
        else
            return poolErr!H(PoolError.full);

        if (generation_[index] == 0)
            generation_[index] = 1;
        live_[index] = true;
        ++liveCount_;
        return poolOk(H(index, generation_[index]));
    }

    /**
    The slot index `h` names, if it is live. Precedence (`POOL4`): `invalid`
    for generation 0 or an out-of-range index, then `stale`.
    */
    PoolResult!uint resolve(in H h) const @safe pure nothrow @nogc
    {
        if (!h.valid || h.index >= capacity)
            return poolErr!uint(PoolError.invalid);
        if (!live_[h.index] || generation_[h.index] != h.generation)
            return poolErr!uint(PoolError.stale);
        uint index = h.index;
        return poolOk(index);
    }

    /// Whether `h` names a live occupant.
    bool isLive(in H h) const @safe pure nothrow @nogc
        => h.valid && h.index < capacity && live_[h.index]
            && generation_[h.index] == h.generation;

    /// Whether slot `index` is live, for a caller that found the slot by
    /// position (an address handed to C) rather than by handle.
    bool liveAt(size_t index) const @safe pure nothrow @nogc
        => index < capacity && live_[index];

    /**
    The handle for live slot `index`. Lets a caller that found a slot some
    other way (a scan over native objects) recover its identity.
    */
    H handleAt(size_t index) const @safe pure nothrow @nogc
    in (index < capacity && live_[index], "handleAt: slot is not live")
        => H(cast(uint) index, generation_[index]);

    /**
    Removes the occupant `h` names and returns its slot index. Every handle to
    it is stale from here on (`POOL3`); the slot is freed or, if its
    generation is exhausted under `Wrap.retire`, retired (`POOL5`).
    */
    PoolResult!uint remove(in H h) @safe pure nothrow @nogc
    {
        auto slot = resolve(h);
        if (slot.hasError)
            return slot;

        uint index = slot.value;
        live_[index] = false;
        --liveCount_;

        if (generation_[index] >= generationLimit)
        {
            static if (wrap == Wrap.retire)
            {
                ++retired_;
                return poolOk(index);
            }
            else
                generation_[index] = 1;
        }
        else
            ++generation_[index];

        pushFreed(index);
        return poolOk(index);
    }

    /// Removes every occupant, as if each were removed in index order.
    void clear() @safe pure nothrow @nogc
    {
        foreach (i; 0 .. highWater_)
            if (live_[i])
                remove(H(i, generation_[i]));
    }

    /// The live handles, in index order. Removing the current element while
    /// iterating is allowed; inserting is not.
    auto byLive() const @safe pure nothrow @nogc return
    {
        static struct Live
        {
            private const(SlotTable)* table;
            private uint next;

            bool empty() const => next >= table.highWater_;
            H front() const => H(next, table.generation_[next]);
            void popFront()
            {
                ++next;
                skip();
            }

            private void skip()
            {
                while (next < table.highWater_ && !table.live_[next])
                    ++next;
            }
        }

        auto range = Live(&this, 0);
        range.skip();
        return range;
    }

    private uint popFreed() @safe pure nothrow @nogc
    {
        --freedCount_;
        static if (reuse == Reuse.lifo)
            return freed_[freedCount_];
        else
        {
            const index = freed_[freedHead_];
            freedHead_ = cast(uint)((freedHead_ + 1) % capacity);
            return index;
        }
    }

    private void pushFreed(uint index) @safe pure nothrow @nogc
    {
        static if (reuse == Reuse.lifo)
            freed_[freedCount_] = index;
        else
            freed_[(freedHead_ + freedCount_) % capacity] = index;
        ++freedCount_;
    }
}

version (unittest)
{
    private struct TestTag {}
    private alias TestHandle = Handle!TestTag;
}

@("pool.slot_table.issuesFromIndexZero")
@safe pure nothrow @nogc
unittest
{
    static foreach (reuse; [Reuse.lifo, Reuse.fifo])
    {{
        SlotTable!(TestHandle, 4, reuse) table;
        assert(table.liveCount == 0 && !table.full);
        foreach (uint i; 0 .. 4)
            assert(table.insert().value == TestHandle(i, 1));
        assert(table.full);
        assert(table.insert().error == PoolError.full);
        assert(table.liveCount == 4);
    }}
}

@("pool.slot_table.removedHandlesAreStale")
@safe pure nothrow @nogc
unittest
{
    SlotTable!(TestHandle, 2) table;
    const a = table.insert().value;
    assert(table.isLive(a));
    assert(table.remove(a).value == 0);

    assert(!table.isLive(a));
    assert(table.resolve(a).error == PoolError.stale);
    assert(table.remove(a).error == PoolError.stale);

    // The slot is reused under a new generation; the old handle stays stale.
    const b = table.insert().value;
    assert(b.index == a.index && b.generation == 2);
    assert(table.resolve(a).error == PoolError.stale);
    assert(table.resolve(b).value == 0);
}

@("pool.slot_table.errorPrecedence")
@safe pure nothrow @nogc
unittest
{
    SlotTable!(TestHandle, 2) table;
    assert(table.resolve(TestHandle.init).error == PoolError.invalid);
    assert(table.resolve(TestHandle(2, 1)).error == PoolError.invalid);
    assert(table.resolve(TestHandle(9, 0)).error == PoolError.invalid);
    // In range, valid generation, never issued: stale, not invalid.
    assert(table.resolve(TestHandle(1, 1)).error == PoolError.stale);

    // A failed remove leaves the table unchanged.
    const h = table.insert().value;
    assert(table.remove(TestHandle(h.index, h.generation + 1)).hasError);
    assert(table.isLive(h) && table.liveCount == 1);
}

@("pool.slot_table.retireAtTheGenerationLimit")
@safe pure nothrow @nogc
unittest
{
    SlotTable!(TestHandle, 2, Reuse.lifo, Wrap.retire, 3) table;
    TestHandle h;
    foreach (uint gen; 1 .. 4)
    {
        h = table.insert().value;
        assert(h == TestHandle(0, gen));
        assert(table.remove(h).hasValue);
    }

    // Slot 0 reached generation 3 and retired: never issued again.
    assert(table.usableCapacity == 1);
    assert(table.resolve(h).error == PoolError.stale);
    assert(table.insert().value == TestHandle(1, 1));
    assert(table.full);
    assert(table.insert().error == PoolError.full);
}

@("pool.slot_table.skipZeroWrapsAndReuses")
@safe pure nothrow @nogc
unittest
{
    SlotTable!(TestHandle, 1, Reuse.lifo, Wrap.skipZero, 3) table;
    TestHandle first = table.insert().value;
    table.remove(first);
    table.remove(table.insert().value); // generation 2
    table.remove(table.insert().value); // generation 3, wraps to 1

    // The documented cost: the first handle resolves again (ABA).
    const again = table.insert().value;
    assert(again == first);
    assert(table.usableCapacity == 1);
}

@("pool.slot_table.reuseOrder")
@safe pure nothrow @nogc
unittest
{
    static uint[3] order(Reuse reuse)()
    {
        SlotTable!(TestHandle, 4, reuse) table;
        TestHandle[4] h;
        foreach (i; 0 .. 4)
            h[i] = table.insert().value;
        table.remove(h[2]);
        table.remove(h[0]);
        table.remove(h[3]);
        uint[3] got;
        foreach (i; 0 .. 3)
            got[i] = table.insert().value.index;
        return got;
    }

    assert(order!(Reuse.lifo) == [3, 0, 2]);
    assert(order!(Reuse.fifo) == [2, 0, 3]);
}

@("pool.slot_table.fifoIssuesFreshSlotsFirst")
@safe pure nothrow @nogc
unittest
{
    SlotTable!(TestHandle, 3, Reuse.fifo) table;
    const a = table.insert().value;
    table.remove(a);
    // Fresh slots count as freed at construction, before slot 0's removal.
    assert(table.insert().value.index == 1);
    assert(table.insert().value.index == 2);
    assert(table.insert().value == TestHandle(0, 2));

    SlotTable!(TestHandle, 3, Reuse.lifo) stack;
    stack.remove(stack.insert().value);
    assert(stack.insert().value == TestHandle(0, 2));
}

@("pool.slot_table.byLiveAndClear")
@safe pure nothrow @nogc
unittest
{
    SlotTable!(TestHandle, 4) table;
    TestHandle[4] h;
    foreach (i; 0 .. 4)
        h[i] = table.insert().value;
    table.remove(h[1]);

    uint[4] seen;
    size_t n;
    foreach (live; table.byLive)
        seen[n++] = live.index;
    assert(seen[0 .. n] == [0, 2, 3]);
    assert(table.handleAt(2) == h[2]);
    assert(table.liveAt(2) && !table.liveAt(1) && !table.liveAt(9));

    table.clear();
    assert(table.liveCount == 0);
    assert(table.byLive.empty);
    foreach (old; h)
        assert(!table.isLive(old));
}
