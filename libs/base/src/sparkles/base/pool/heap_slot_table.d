/**
A slot table whose columns live on the heap and grow.

`HeapSlotTable` issues and retires `Handle`s exactly as `SlotTable` does, for
a consumer that cannot bound its number of identities in advance — the node
handles of an open SDL document, say. It holds no records; a record store
beside it, indexed by slot, grows with it.

See `docs/specs/base/pool.md` §3.1 (`POOL19`–`POOL21`).
*/
module sparkles.base.pool.heap_slot_table;

import sparkles.base.buffer : HeapBuffer;

public import sparkles.base.pool.handle : Handle, PoolError, PoolResult,
    Reuse, Wrap, isHandle, poolErr, poolOk;

/**
A growable table of generational slots.

The parameters mean what they mean for `SlotTable`, except that there is no
fixed capacity: `insert` grows the table when no slot is free (`POOL19`),
and growth keeps every handle and the reuse order (`POOL20`, `POOL21`). An
empty table owns no memory. The table cannot be copied.
*/
struct HeapSlotTable(H, Reuse reuse = Reuse.lifo, Wrap wrap = Wrap.retire,
    uint generationLimit = uint.max)
if (isHandle!H && generationLimit > 0)
{
    private static struct Slot
    {
        uint generation; // 0 = never issued
        bool live;
    }

    private HeapBuffer!Slot slots_; // length = the allocated capacity
    private HeapBuffer!uint freed_; // a stack (lifo) or a queue from freedHead_ (fifo)
    private size_t freedHead_;      // fifo only
    private uint highWater_;        // slots [0, highWater_) were issued once
    private uint liveCount_;
    private uint retired_;

    @disable this(this);

    /// The number of allocated slots, including retired ones.
    size_t slotCapacity() const @safe pure nothrow @nogc => slots_.length;

    /// The number of live handles.
    size_t liveCount() const @safe pure nothrow @nogc => liveCount_;

    /// The number of allocated slots that can still hold a live handle.
    size_t usableCapacity() const @safe pure nothrow @nogc
        => slots_.length - retired_;

    /// Ensures at least `count` slots are allocated, so that many inserts
    /// need no growth (`POOL19`).
    void reserve(size_t count) @safe pure nothrow @nogc
    {
        if (count > uint.max - 1)
            count = uint.max - 1;
        if (count > slots_.length)
            grow(count);
    }

    /**
    Issues a handle to a free slot, growing the table when none is free;
    `PoolError.full` only once the index space is exhausted.
    */
    PoolResult!H insert() @safe pure nothrow @nogc
    {
        uint index;
        if (reuse == Reuse.fifo && highWater_ < slots_.length)
            index = highWater_++;
        else if (freedCount != 0)
            index = popFreed();
        else
        {
            if (highWater_ == slots_.length)
            {
                if (slots_.length >= uint.max - 1)
                    return poolErr!H(PoolError.full);
                grow(slots_.length < 8 ? 8 : slots_.length * 2);
            }
            index = highWater_++;
        }

        auto slot = &slots_[index];
        if (slot.generation == 0)
            slot.generation = 1;
        slot.live = true;
        ++liveCount_;
        return poolOk(H(index, slot.generation));
    }

    /// The slot index `h` names, if it is live; `invalid`, then `stale`
    /// (`POOL4`).
    PoolResult!uint resolve(in H h) const @safe pure nothrow @nogc
    {
        if (!h.valid || h.index >= slots_.length)
            return poolErr!uint(PoolError.invalid);
        if (!slots_[h.index].live || slots_[h.index].generation != h.generation)
            return poolErr!uint(PoolError.stale);
        uint index = h.index;
        return poolOk(index);
    }

    /// Whether `h` names a live occupant.
    bool isLive(in H h) const @safe pure nothrow @nogc
        => h.valid && h.index < slots_.length && slots_[h.index].live
            && slots_[h.index].generation == h.generation;

    /// Whether slot `index` is live.
    bool liveAt(size_t index) const @safe pure nothrow @nogc
        => index < slots_.length && slots_[index].live;

    /// The handle for live slot `index`.
    H handleAt(size_t index) const @safe pure nothrow @nogc
    in (liveAt(index), "handleAt: slot is not live")
        => H(cast(uint) index, slots_[index].generation);

    /// Removes the occupant `h` names and returns its slot index; every
    /// handle to it is stale from here on (`POOL3`, `POOL5`).
    PoolResult!uint remove(in H h) @safe pure nothrow @nogc
    {
        auto found = resolve(h);
        if (found.hasError)
            return found;

        uint index = found.value;
        auto slot = &slots_[index];
        slot.live = false;
        --liveCount_;

        if (slot.generation >= generationLimit)
        {
            static if (wrap == Wrap.retire)
            {
                ++retired_;
                return poolOk(index);
            }
            else
                slot.generation = 1;
        }
        else
            ++slot.generation;

        freed_ ~= index;
        return poolOk(index);
    }

    /// Removes every occupant, as if each were removed in index order.
    void clear() @safe pure nothrow @nogc
    {
        foreach (uint i; 0 .. highWater_)
            if (slots_[i].live)
                remove(H(i, slots_[i].generation));
    }

    /// The live handles, in index order. Removing the current element while
    /// iterating is allowed; inserting is not.
    auto byLive() const @safe pure nothrow @nogc return
    {
        static struct Live
        {
            private const(HeapSlotTable)* table;
            private uint next;

            bool empty() const => next >= table.highWater_;
            H front() const => H(next, table.slots_[next].generation);
            void popFront()
            {
                ++next;
                skip();
            }

            private void skip()
            {
                while (next < table.highWater_ && !table.slots_[next].live)
                    ++next;
            }
        }

        auto range = Live(&this, 0);
        range.skip();
        return range;
    }

    private size_t freedCount() const @safe pure nothrow @nogc
        => freed_.length - freedHead_;

    private uint popFreed() @safe pure nothrow @nogc
    {
        static if (reuse == Reuse.lifo)
        {
            const index = freed_[$ - 1];
            freed_.popBack();
            return index;
        }
        else
        {
            const index = freed_[freedHead_++];
            if (freedHead_ == freed_.length)
            {
                freed_.clear(releaseStorage: false);
                freedHead_ = 0;
            }
            else if (freedHead_ >= 32 && freedHead_ * 2 >= freed_.length)
            {
                // Compact the queue so its storage stays bounded by the
                // number of freed slots.
                const live = freed_.length - freedHead_;
                foreach (i; 0 .. live)
                    freed_[i] = freed_[freedHead_ + i];
                freed_.length = live;
                freedHead_ = 0;
            }
            return index;
        }
    }

    private void grow(size_t count) @safe pure nothrow @nogc
    {
        if (count > uint.max - 1)
            count = uint.max - 1;
        // New slots are `Slot.init`: never issued, generation 0.
        slots_.length = count;
    }
}

version (unittest)
{
    private struct HeapTestTag {}
    private alias HeapTestHandle = Handle!HeapTestTag;
}

@("pool.heap_slot_table.emptyOwnsNothingAndGrows")
@safe pure nothrow @nogc
unittest
{
    HeapSlotTable!HeapTestHandle table;
    assert(table.slotCapacity == 0 && table.liveCount == 0);
    assert(table.byLive.empty);
    foreach (uint i; 0 .. 100)
        assert(table.insert().value == HeapTestHandle(i, 1));
    assert(table.liveCount == 100 && table.slotCapacity >= 100);
}

@("pool.heap_slot_table.slotTableContract")
@safe pure nothrow @nogc
unittest
{
    HeapSlotTable!HeapTestHandle table;
    // POOL1 and POOL4: the default handle and out-of-range indexes.
    assert(table.resolve(HeapTestHandle.init).error == PoolError.invalid);
    assert(table.resolve(HeapTestHandle(0, 1)).error == PoolError.invalid);

    // POOL3: removal makes every handle stale, even after reuse.
    const a = table.insert().value;
    assert(table.remove(a).value == 0);
    assert(table.resolve(a).error == PoolError.stale);
    assert(table.remove(a).error == PoolError.stale);
    const b = table.insert().value;
    assert(b == HeapTestHandle(0, 2));
    assert(!table.isLive(a) && table.isLive(b));

    // POOL4: in range and never issued is stale; a failed remove is inert.
    table.reserve(4);
    assert(table.resolve(HeapTestHandle(3, 1)).error == PoolError.stale);
    assert(table.remove(HeapTestHandle(b.index, 9)).hasError);
    assert(table.isLive(b) && table.liveCount == 1);
}

@("pool.heap_slot_table.retireAndSkipZero")
@safe pure nothrow @nogc
unittest
{
    HeapSlotTable!(HeapTestHandle, Reuse.lifo, Wrap.retire, 2) retire;
    retire.remove(retire.insert().value);
    const second = retire.insert().value;
    assert(second == HeapTestHandle(0, 2));
    retire.remove(second);
    // Slot 0 retired at the limit; the next insert takes a fresh slot.
    assert(retire.usableCapacity == retire.slotCapacity - 1);
    assert(retire.insert().value.index == 1);

    HeapSlotTable!(HeapTestHandle, Reuse.lifo, Wrap.skipZero, 2) wraps;
    const first = wraps.insert().value;
    wraps.remove(first);
    wraps.remove(wraps.insert().value);
    assert(wraps.insert().value == first); // the documented ABA
}

@("pool.heap_slot_table.growthPreservesHandlesAndOrder")
@safe pure nothrow @nogc
unittest
{
    static foreach (reuse; [Reuse.lifo, Reuse.fifo])
    {{
        HeapSlotTable!(HeapTestHandle, reuse) table;
        HeapTestHandle[8] h;
        foreach (i; 0 .. 8)
            h[i] = table.insert().value;
        table.remove(h[5]);
        table.remove(h[2]);
        const capacity = table.slotCapacity;
        table.reserve(capacity * 4); // POOL20: growth keeps identities
        foreach (i; 0 .. 8)
            assert(table.isLive(h[i]) == (i != 5 && i != 2));
        static if (reuse == Reuse.lifo)
        {
            // POOL21: the most recently freed first, then fresh slots.
            assert(table.insert().value == HeapTestHandle(2, 2));
            assert(table.insert().value == HeapTestHandle(5, 2));
            assert(table.insert().value == HeapTestHandle(8, 1));
        }
        else
        {
            // POOL21: fresh slots while the allocation has them, then the
            // least recently freed.
            foreach (uint i; 8 .. cast(uint) table.slotCapacity)
                assert(table.insert().value == HeapTestHandle(i, 1));
            assert(table.insert().value == HeapTestHandle(5, 2));
            assert(table.insert().value == HeapTestHandle(2, 2));
        }
    }}
}

@("pool.heap_slot_table.fifoQueueCompacts")
@safe pure nothrow @nogc
unittest
{
    HeapSlotTable!(HeapTestHandle, Reuse.fifo) table;
    table.reserve(4);
    HeapTestHandle[4] h;
    foreach (i; 0 .. 4)
        h[i] = table.insert().value;
    // Churn one slot at a time: the queue never holds more than a few.
    foreach (round; 0 .. 1000)
    {
        const slot = round % 4;
        table.remove(h[slot]);
        h[slot] = table.insert().value;
        assert(h[slot].index == slot);
    }
    assert(table.slotCapacity == 4 && table.liveCount == 4);
}

@("pool.heap_slot_table.byLiveAndClear")
@safe pure nothrow @nogc
unittest
{
    HeapSlotTable!HeapTestHandle table;
    HeapTestHandle[4] h;
    foreach (i; 0 .. 4)
        h[i] = table.insert().value;
    table.remove(h[1]);
    uint[4] seen;
    size_t n;
    foreach (live; table.byLive)
        seen[n++] = live.index;
    assert(seen[0 .. n] == [0, 2, 3]);
    assert(table.handleAt(3) == h[3] && !table.liveAt(1));
    table.clear();
    assert(table.liveCount == 0 && table.byLive.empty);
}
