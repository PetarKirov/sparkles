/**
Variable-length text behind generational ids.

`TextPool` generalises `DqlEngine.intern` (`sparkles.dql.engine`): text is
appended to one inline byte arena and addressed by a `TextSpan`. The
difference is that callers never hold the span. They hold an id — a `Handle`
into a pool of spans — so the arena can reset when it empties and compact
when it fragments without invalidating anything a caller kept.

The price is that text is read only inside a borrow (`withText`). While any
borrow is open the pool does not move bytes, so the slice a callback receives
stays valid for exactly as long as the callback runs.

See `docs/specs/base/pool.md` §5 (`POOL12`–`POOL18`).
*/
module sparkles.base.pool.text_pool;

import sparkles.base.text.span : TextSpan;

public import sparkles.base.pool.pool;

/**
A fixed-capacity store of up to `slots` texts sharing `bytes` bytes.

Params:
    Tag = distinguishes this pool's ids (`Handle!Tag`) from other handles
    slots = the most texts live at once
    bytes = the arena's size, shared by all live texts
    maxText = the most bytes one text keeps; longer input is cut at a UTF-8
        boundary and flagged (`POOL12`). Arena pressure never truncates
        (`POOL13`).
    reuse = which freed id slot is issued next
*/
struct TextPool(Tag, size_t slots, size_t bytes, size_t maxText = bytes,
    Reuse reuse = Reuse.lifo)
if (slots > 0 && bytes > 0 && bytes < uint.max && maxText > 0
    && maxText <= bytes)
{
    /// This pool's id type.
    alias Id = Handle!Tag;

    private static struct Entry
    {
        TextSpan span;
        bool truncated;
    }

    private Pool!(Id, Entry, slots, reuse) entries_;
    private char[bytes] arena_;
    private uint used_; // bytes [0, used_) have been appended
    private uint dead_; // bytes of [0, used_) that belong to released texts
    private uint borrows_;

    @disable this(this);

    /// The number of live texts.
    size_t liveCount() const @safe pure nothrow @nogc => entries_.liveCount;

    /// Bytes appended since the last reset or compaction, live or dead.
    size_t usedBytes() const @safe pure nothrow @nogc => used_;

    /// Bytes owned by released texts, reclaimable by compaction.
    size_t deadBytes() const @safe pure nothrow @nogc => dead_;

    /// Whether a borrow is open, so bytes may not move.
    bool borrowed() const @safe pure nothrow @nogc => borrows_ != 0;

    /// Whether `id` names a live text.
    bool isLive(in Id id) const @safe pure nothrow @nogc => entries_.isLive(id);

    /**
    Stores `text` and returns its id (`POOL12`, `POOL13`, `POOL16`).

    At most `maxText` bytes are kept, cut so the kept prefix never ends inside
    a multi-byte sequence, and the id records that it was truncated. When the
    arena cannot hold the text, the pool compacts if that frees enough room
    and nothing is borrowed; otherwise it returns `PoolError.full` and changes
    nothing. `text` may alias the arena itself (re-interning a borrowed
    slice): the pool then does not compact during this call.
    */
    PoolResult!Id intern(scope const(char)[] text) @safe pure nothrow @nogc
        => store(text, false);

    /**
    Calls `fn(text, truncated)` — or `fn(text)` — with the text `id` names,
    or returns why it cannot (`POOL14`). The slice is valid until `fn`
    returns and may not escape it: no byte moves while it runs, even if `fn`
    interns or releases other texts.
    */
    PoolResult!Id withText(Fn)(in Id id, scope Fn fn)
    {
        auto entry = entries_.get(id);
        if (entry is null)
            return poolErr!Id(stale(id));

        const span = entry.span;
        const truncated = entry.truncated;
        ++borrows_;
        scope (exit)
            endBorrow();

        scope const(char)[] text = arena_[span.startOffset .. span.endOffset];
        static if (__traits(compiles, fn(text, truncated)))
            fn(text, truncated);
        else
            fn(text);

        Id visited = id;
        return poolOk(visited);
    }

    /// The length in bytes of the text `id` names.
    PoolResult!size_t lengthOf(in Id id) const @safe pure nothrow @nogc
    {
        auto entry = entries_.get(id);
        if (entry is null)
            return poolErr!size_t(stale(id));
        size_t length = entry.span.length;
        return poolOk(length);
    }

    /**
    Releases the text `id` names (`POOL17`). Its bytes become dead; once no
    text is live and nothing is borrowed, the arena resets to empty.
    */
    PoolResult!Id release(in Id id) @safe pure nothrow @nogc
    {
        auto entry = entries_.get(id);
        if (entry is null)
            return poolErr!Id(stale(id));
        dead_ += entry.span.length;
        auto removed = entries_.remove(id);
        resetIfEmpty();
        return removed;
    }

    /**
    Holds the pool borrowed until the returned guard is destroyed: while any
    borrow is open, no byte moves and the arena does not reset. A queue holds
    one across a drain so every callback's `withText` slice stays put even if
    the callback interns more text.
    */
    auto borrow() @safe pure nothrow @nogc return
    {
        static struct Borrow
        {
            private TextPool* pool;

            @disable this(this);

            ~this() @safe pure nothrow @nogc
            {
                if (pool !is null)
                    pool.endBorrow();
            }
        }

        ++borrows_;
        return Borrow(&this);
    }

    // Shared by `intern` and `retain`: `carried` is the source's own
    // truncation flag, so a copy of a truncated text stays flagged.
    private PoolResult!Id store(scope const(char)[] text, bool carried)
        @safe pure nothrow @nogc
    {
        size_t length = text.length;
        bool truncated = carried;
        if (length > maxText)
        {
            length = utf8Floor(text, maxText);
            truncated = true;
        }

        if (entries_.full)
            return poolErr!Id(PoolError.full);

        if (used_ + length > bytes)
        {
            const live = used_ - dead_;
            if (borrows_ != 0 || aliasesArena(text) || live + length > bytes)
                return poolErr!Id(PoolError.full);
            compact();
        }

        const start = used_;
        const end = cast(uint)(start + length);
        copyInto(arena_[start .. end], text[0 .. length]);
        used_ = end;

        auto id = entries_.insert(Entry(TextSpan.of(start, end), truncated));
        assert(id.hasValue, "TextPool: a slot was checked free above");
        return id;
    }

    // Moves every live text to the front of the arena, in increasing offset
    // order so no move overwrites a text not yet moved (`POOL15`). Slot order
    // is not offset order once slots have been reused.
    private void compact() @safe pure nothrow @nogc
    in (borrows_ == 0, "TextPool: compacting under a borrow")
    {
        uint[slots] order;
        size_t count;
        foreach (id; entries_.byLive)
        {
            // Insertion sort by start offset: `slots` is a small constant.
            size_t at = count++;
            const start = entries_[id].span.startOffset;
            while (at > 0
                && entries_.at(order[at - 1]).span.startOffset > start)
            {
                order[at] = order[at - 1];
                --at;
            }
            order[at] = id.index;
        }

        uint cursor = 0;
        foreach (index; order[0 .. count])
        {
            auto entry = &entries_.at(index);
            const span = entry.span;
            const length = cast(uint) span.length;
            copyInto(arena_[cursor .. cursor + length],
                arena_[span.startOffset .. span.endOffset]);
            entry.span = TextSpan.of(cursor, cursor + length);
            cursor += length;
        }
        used_ = cursor;
        dead_ = 0;
    }

    private void endBorrow() @safe pure nothrow @nogc
    {
        --borrows_;
        resetIfEmpty();
    }

    private void resetIfEmpty() @safe pure nothrow @nogc
    {
        if (borrows_ == 0 && entries_.liveCount == 0)
            used_ = dead_ = 0;
    }

    private bool aliasesArena(scope const(char)[] text) const
        @safe pure nothrow @nogc
        => text.length != 0 && text.ptr >= &arena_[0] && text.ptr <= &arena_[$ - 1];

    private PoolError stale(in Id id) const @safe pure nothrow @nogc
        => entries_.resolve(id).error;
}

/**
Copies the text `id` names in `src` into `dst` and returns the new id
(`POOL18`). The copy keeps the truncation flag, and is truncated (and flagged)
again if `dst`'s per-text bound is smaller.

`src` is another pool, or any store that lends its texts the same way: a
`withText(id, fn(text, truncated))` whose result reports `hasError`, such as
a window system's event queue. An error of the source's own kind means its
text is gone, and is reported as `PoolError.stale`.
*/
PoolResult!(Dst.Id) retain(Src, Id, Dst)(ref Src src, Id id, ref Dst dst)
if (is(typeof(src.withText(id, (scope const(char)[] text, bool truncated) {}).hasError)))
{
    auto copied = poolErr!(Dst.Id)(PoolError.stale);
    auto read = src.withText(id, (scope const(char)[] text, bool truncated) {
        copied = dst.store(text, truncated);
    });
    if (read.hasError)
    {
        static if (is(typeof(read.error) : PoolError))
            return poolErr!(Dst.Id)(read.error);
        else
            return poolErr!(Dst.Id)(PoolError.stale);
    }
    return copied;
}

/// The longest prefix of `text` of at most `limit` bytes that does not end
/// inside a UTF-8 sequence: the cut never lands before a continuation byte.
private size_t utf8Floor(scope const(char)[] text, size_t limit)
    @safe pure nothrow @nogc
in (limit < text.length)
{
    size_t cut = limit;
    while (cut > 0 && (text[cut] & 0xC0) == 0x80)
        --cut;
    return cut;
}

/// `dst[] = src[]`, correct when the two overlap in either direction.
private void copyInto(scope char[] dst, scope const(char)[] src)
    @safe pure nothrow @nogc
in (dst.length == src.length)
{
    if (dst.length == 0 || dst.ptr is src.ptr)
        return;
    if (src.ptr < dst.ptr)
        foreach_reverse (i, c; src)
            dst[i] = c;
    else
        foreach (i, c; src)
            dst[i] = c;
}

version (unittest)
{
    private struct TestTag {}
    private alias Small = TextPool!(TestTag, 4, 16);

    /// The text `id` names, copied out so a test can compare it.
    private bool holds(P, I)(ref P pool, I id, scope const(char)[] expected,
        bool expectTruncated = false)
    {
        bool same;
        auto read = pool.withText(id, (scope const(char)[] text, bool truncated) {
            same = text == expected && truncated == expectTruncated;
        });
        return read.hasValue && same;
    }
}

@("pool.text_pool.internReadRelease")
@safe pure nothrow @nogc
unittest
{
    Small pool;
    const a = pool.intern("hello").value;
    const b = pool.intern("").value;
    assert(pool.holds(a, "hello") && pool.holds(b, ""));
    assert(pool.lengthOf(a).value == 5);
    assert(pool.usedBytes == 5);

    assert(pool.release(a).hasValue);
    assert(!pool.isLive(a));
    assert(pool.withText(a, (scope const(char)[]) {}).error == PoolError.stale);
    assert(pool.release(a).error == PoolError.stale);
    assert(pool.usedBytes == 5 && pool.deadBytes == 5);

    // The last live text released: the arena resets.
    pool.release(b);
    assert(pool.liveCount == 0 && pool.usedBytes == 0 && pool.deadBytes == 0);
}

@("pool.text_pool.truncatesOnlyAtTheBound")
@safe pure nothrow @nogc
unittest
{
    TextPool!(TestTag, 4, 32, 5) pool;
    assert(pool.holds(pool.intern("hello").value, "hello"));
    assert(pool.holds(pool.intern("hello!").value, "hello", true));

    // "héllo": 'é' is two bytes at [1, 3); a cut at 5 keeps "héll".
    assert(pool.holds(pool.intern("héllo!").value, "héll", true));
    // "aé€": a 5-byte bound lands inside '€' (bytes [3, 6)); keep "aé".
    assert(pool.holds(pool.intern("aé€").value, "aé", true));
}

@("pool.text_pool.pressureFailsNeverTruncates")
@safe pure nothrow @nogc
unittest
{
    Small pool;
    const a = pool.intern("0123456789").value;
    assert(pool.intern("abcdefgh").error == PoolError.full);
    assert(pool.liveCount == 1 && pool.usedBytes == 10);

    // A failed intern on a full id table changes nothing either.
    TextPool!(TestTag, 1, 16) one;
    one.intern("x");
    assert(one.intern("y").error == PoolError.full);
    assert(one.usedBytes == 1);
    assert(pool.holds(a, "0123456789"));
}

@("pool.text_pool.compactionPreservesTextInOffsetOrder")
@safe pure nothrow @nogc
unittest
{
    Small pool;
    // slot 0 → [0,2), slot 1 → [2,6), slot 2 → [6,8).
    const x = pool.intern("xx").value;
    const b = pool.intern("BBBB").value;
    const y = pool.intern("yy").value;

    // Free slots 2 then 0, so the next intern reuses slot 0 for later bytes:
    // slot 0 → [8,16), slot 1 → [2,6). Slot order is now not offset order,
    // and moving slot 0 first, to [0,8), would overwrite B before it moved.
    pool.release(y);
    pool.release(x);
    const d = pool.intern("DDDDDDDD").value;
    assert(d.index == x.index);

    // 16 used, 4 dead: "EEEE" fits only after compaction.
    const e = pool.intern("EEEE").value;
    assert(pool.holds(b, "BBBB"));
    assert(pool.holds(d, "DDDDDDDD"));
    assert(pool.holds(e, "EEEE"));
    assert(pool.usedBytes == 16 && pool.deadBytes == 0);
}

@("pool.text_pool.noCompactionWhileBorrowed")
@safe pure nothrow @nogc
unittest
{
    Small pool;
    const a = pool.intern("AAAAAAAA").value;
    const b = pool.intern("BBBBBBBB").value;
    pool.release(a);

    {
        auto lock = pool.borrow();
        assert(pool.borrowed);
        // Compaction would make room, but a borrow is open.
        assert(pool.intern("CCCC").error == PoolError.full);
        // Releasing the last text under a borrow does not reset the arena.
        pool.release(b);
        assert(pool.usedBytes == 16);
    }
    assert(!pool.borrowed && pool.usedBytes == 0);
}

@("pool.text_pool.callbackSliceSurvivesInterning")
@safe pure nothrow @nogc
unittest
{
    Small pool;
    const a = pool.intern("AAAAAAAA").value;
    const b = pool.intern("BBBB").value;
    pool.release(a);

    bool ok;
    pool.withText(b, (scope const(char)[] text) {
        // Inside the callback the pool is borrowed: this cannot compact,
        // so `text` still reads "BBBB" afterwards.
        assert(pool.intern("CCCCCCCC").error == PoolError.full);
        ok = text == "BBBB";
    });
    assert(ok);
    // Outside, the same intern compacts and succeeds.
    assert(pool.holds(pool.intern("CCCCCCCC").value, "CCCCCCCC"));
    assert(pool.holds(b, "BBBB"));
}

@("pool.text_pool.aliasedInput")
@safe pure nothrow @nogc
unittest
{
    Small pool;
    const a = pool.intern("ABCDEFGH").value;
    const b = pool.intern("1234").value;

    // Re-interning a borrowed slice of the arena copies it correctly.
    PoolResult!(Small.Id) copy = poolErr!(Small.Id)(PoolError.stale);
    pool.withText(b, (scope const(char)[] text) { copy = pool.intern(text); });
    assert(pool.holds(copy.value, "1234"));

    // Aliased input that would need compaction is refused, not corrupted:
    // 16 bytes used, 8 of them dead.
    pool.release(a);
    PoolResult!(Small.Id) again = poolOk(Small.Id.init);
    pool.withText(b, (scope const(char)[] text) { again = pool.intern(text); });
    assert(again.error == PoolError.full);
    assert(pool.holds(b, "1234") && pool.holds(copy.value, "1234"));
}

@("pool.text_pool.invalidUtf8IsStoredAsGiven")
@safe pure nothrow @nogc
unittest
{
    TextPool!(TestTag, 2, 16, 4) pool;
    immutable char[3] bad = [0xFF, 'a', 0x80];
    assert(pool.holds(pool.intern(bad[]).value, bad[]));
    // A cut never lands before a continuation byte, even in invalid input.
    immutable char[6] tail = ['a', 'b', 'c', 0xE2, 0x82, 0xAC];
    assert(pool.holds(pool.intern(tail[]).value, "abc", true));
}

@("pool.text_pool.retainCopiesBetweenPools")
@safe pure nothrow @nogc
unittest
{
    struct OtherTag {}

    TextPool!(TestTag, 2, 32, 8) src;
    TextPool!(OtherTag, 2, 32, 3) dst;

    const a = src.intern("abcdefghij").value; // kept "abcdefgh", truncated
    const b = src.intern("xy").value;

    const ra = retain(src, a, dst).value;
    assert(dst.holds(ra, "abc", true));
    const rb = retain(src, b, dst).value;
    assert(dst.holds(rb, "xy"));

    // The copies are independent of the source.
    src.release(a);
    assert(dst.holds(ra, "abc", true));
    assert(retain(src, a, dst).error == PoolError.stale);
    // `dst` is full now.
    assert(retain(src, b, dst).error == PoolError.full);
}
