/**
A fixed-capacity pool of records addressed by generational handles.

`Pool` is a `SlotTable` with one `Record` per slot, stored inline as an array
of structs. A record's address never changes while it is live (`POOL8`), so it
can be handed to C as callback data; a handle can be reserved before its
record is built (`POOL9`), because building one may call back; and removing a
record destroys it there and then (`POOL10`).

See `docs/specs/base/pool.md` §4.
*/
module sparkles.base.pool.pool;

import core.lifetime : move;

public import sparkles.base.pool.slot_table;

/**
A fixed-capacity pool of `Record`s, one per live handle.

The pool may not be copied: a copy would duplicate every live identity and
leave the addresses handed out pointing at the original. It may still be
moved before any record address has been registered with C code.
*/
struct Pool(H, Record, size_t capacity, Reuse reuse = Reuse.lifo,
    Wrap wrap = Wrap.retire, uint generationLimit = uint.max)
if (isHandle!H)
{
    private SlotTable!(H, capacity, reuse, wrap, generationLimit) table_;
    private Record[capacity] records_;

    @disable this(this);

    /// The number of slots, including retired ones.
    enum size_t slotCapacity = capacity;

    size_t liveCount() const => table_.liveCount;           /// See `SlotTable`.
    size_t usableCapacity() const => table_.usableCapacity; /// ditto
    bool full() const => table_.full;                       /// ditto
    bool isLive(in H h) const => table_.isLive(h);           /// ditto
    PoolResult!uint resolve(in H h) const => table_.resolve(h); /// ditto
    H handleAt(size_t index) const => table_.handleAt(index);   /// ditto
    bool liveAt(size_t index) const => table_.liveAt(index);     /// ditto

    /// The live handles, in index order. See `SlotTable.byLive`.
    auto byLive() const return => table_.byLive;

    /**
    Issues a handle whose record is `Record.init`, for a caller that must know
    the identity before the record can be built. Finish with `commit`, or undo
    with `cancel`.
    */
    PoolResult!H reserve() => table_.insert();

    /// Moves `record` into the slot `h` names, destroying what was there.
    PoolResult!H commit(in H h, Record record)
    {
        auto slot = table_.resolve(h);
        if (slot.hasError)
            return poolErr!H(slot.error);
        move(record, records_[slot.value]);
        H issued = h;
        return poolOk(issued);
    }

    /// Undoes a `reserve` (or removes a committed record): see `remove`.
    PoolResult!H cancel(in H h) => remove(h);

    /// Issues a handle and moves `record` into its slot.
    PoolResult!H insert(Record record)
    {
        auto h = table_.insert();
        if (h.hasError)
            return h;
        move(record, records_[h.value.index]);
        return h;
    }

    /**
    Removes the record `h` names, running its destructor now and leaving
    `Record.init` in the slot. Returns the removed handle.
    */
    PoolResult!H remove(in H h)
    {
        auto slot = table_.remove(h);
        if (slot.hasError)
            return poolErr!H(slot.error);
        destroy(records_[slot.value]);
        H removed = h;
        return poolOk(removed);
    }

    /// Removes every record, in index order.
    void clear()
    {
        foreach (h; table_.byLive)
            remove(h);
    }

    /**
    The record `h` names, or `null` if `h` is not live. The pointer is scoped
    to the pool (`POOL11`): it may be used while the record is live and may
    not outlive the pool.
    */
    inout(Record)* get(in H h) inout return
    {
        auto slot = table_.resolve(h);
        return slot.hasError ? null : &records_[slot.value];
    }

    /// The record a known-live `h` names.
    ref inout(Record) opIndex(in H h) inout return
    in (table_.isLive(h), "Pool[h]: the handle is not live")
        => records_[h.index];

    /**
    The record in slot `index`, live or not. For a caller that found the slot
    by scanning (`byLive`, or a search over native objects); the record of a
    free slot is `Record.init`.
    */
    ref inout(Record) at(size_t index) inout return
    in (index < capacity, "Pool.at: index out of range")
        => records_[index];

    /**
    The slot index of a record this pool owns, or `size_t.max` for any other
    address. For C callbacks, which hand back the record pointer they were
    registered with (POOL8).
    */
    size_t indexOf(scope const(Record)* record) const @safe pure nothrow @nogc
    {
        if (record is null || record < &records_[0] || record > &records_[$ - 1])
            return size_t.max;
        return (() @trusted => cast(size_t)(record - &records_[0]))();
    }

    /// Calls `fn(record)` if `h` is live; otherwise returns why not.
    PoolResult!H withRecord(Fn)(in H h, scope Fn fn)
    {
        auto slot = table_.resolve(h);
        if (slot.hasError)
            return poolErr!H(slot.error);
        fn(records_[slot.value]);
        H visited = h;
        return poolOk(visited);
    }
}

version (unittest)
{
    private struct TestTag {}
    private alias TestHandle = Handle!TestTag;

    /// Destructions of a `Counted` that was ever given a value. Thread-local,
    /// so the tests that read it are not `pure`.
    private int drops;

    /// Counts its own destruction; the `.init` value is free to destroy.
    private struct Counted
    {
        int value;

        ~this() @safe nothrow @nogc
        {
            if (value != 0)
                ++drops;
        }
    }
}

@("pool.pool.insertGetRemove")
@safe pure nothrow @nogc
unittest
{
    static struct Point { int x, y; }

    Pool!(TestHandle, Point, 4) pool;
    const a = pool.insert(Point(1, 2)).value;
    const b = pool.insert(Point(3, 4)).value;
    assert(pool.liveCount == 2);
    assert(pool[a] == Point(1, 2));
    assert(pool.get(b).y == 4);

    pool[a].x = 10;
    assert(pool.get(a).x == 10);

    assert(pool.remove(a).value == a);
    assert(pool.get(a) is null);
    assert(pool.remove(a).error == PoolError.stale);
    assert(pool.at(a.index) == Point.init);
    assert(!pool.isLive(a) && pool.isLive(b));
}

@("pool.pool.recordsNeverMove")
@safe pure nothrow @nogc
unittest
{
    static struct Point { int x, y; }

    Pool!(TestHandle, Point, 4) pool;
    const a = pool.insert(Point(1, 1)).value;
    const pa = pool.get(a);

    foreach (i; 0 .. 3)
    {
        const other = pool.insert(Point(i, i)).value;
        pool.remove(other);
    }
    assert(pool.get(a) is pa);
    assert(*pa == Point(1, 1));
    assert(pool.indexOf(pa) == a.index);
    Point elsewhere;
    assert(pool.indexOf(&elsewhere) == size_t.max);
    assert(pool.indexOf(null) == size_t.max);
}

@("pool.pool.reserveCommitCancel")
@safe nothrow @nogc
unittest
{
    drops = 0;
    Pool!(TestHandle, Counted, 2) pool;

    // The identity exists before the record is built.
    const h = pool.reserve().value;
    assert(pool.isLive(h) && *pool.get(h) == Counted.init);

    // A synchronous callback during construction can find it.
    assert(pool.get(h) !is null);
    assert(pool.commit(h, Counted(42)).value == h);
    assert(pool[h].value == 42 && drops == 0);

    // A second commit destroys the record it overwrites.
    assert(pool.commit(h, Counted(43)).hasValue);
    assert(drops == 1 && pool[h].value == 43);

    // Cancelling a reservation that failed later.
    const failed = pool.reserve().value;
    assert(pool.cancel(failed).hasValue);
    assert(!pool.isLive(failed) && drops == 1);
    assert(pool.commit(failed, Counted(1)).error == PoolError.stale);
    // The rejected record was moved in and dropped by the call, once.
    assert(drops == 2);
}

@("pool.pool.removalDestroysExactlyOnce")
@safe nothrow @nogc
unittest
{
    drops = 0;
    {
        Pool!(TestHandle, Counted, 4) pool;
        const a = pool.insert(Counted(1)).value;
        const b = pool.insert(Counted(2)).value;
        assert(drops == 0);

        pool.remove(a);
        assert(drops == 1);
        pool.remove(a); // stale: nothing destroyed
        assert(drops == 1);

        pool.clear();
        assert(drops == 2 && pool.liveCount == 0 && !pool.isLive(b));
    }
    // The pool's own destruction runs only `.init` destructors.
    assert(drops == 2);
}

@("pool.pool.moveOnlyRecords")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.buffer : UniqueBuffer;

    static struct Named
    {
        UniqueBuffer!(char, 4) name;
    }

    Pool!(TestHandle, Named, 2) pool;
    Named n;
    n.name ~= "longer than four";
    const h = pool.insert(move(n)).value;
    assert(pool[h].name[] == "longer than four");
    assert(n.name.length == 0);

    pool.remove(h);
    assert(pool.at(h.index).name.length == 0);
    static assert(!__traits(compiles, { auto copy = pool; }));
}

@("pool.pool.withRecordAndEscape")
@safe pure nothrow @nogc
unittest
{
    static struct Point { int x, y; }

    Pool!(TestHandle, Point, 2) pool;
    const h = pool.insert(Point(1, 2)).value;

    int seen;
    assert(pool.withRecord(h, (ref Point p) { seen = p.x + p.y; }).hasValue);
    assert(seen == 3);
    pool.remove(h);
    assert(pool.withRecord(h, (ref Point p) { seen = 0; }).error
        == PoolError.stale);
    assert(seen == 3);

    // A record pointer cannot outlive a pool on the stack; a value read
    // through it can.
    static assert(!__traits(compiles, () @safe {
        Pool!(TestHandle, Point, 2) local;
        return local.get(local.insert(Point.init).value);
    }));
    static assert(__traits(compiles, () @safe {
        Pool!(TestHandle, Point, 2) local;
        return local.get(local.insert(Point.init).value).x;
    }));
}
