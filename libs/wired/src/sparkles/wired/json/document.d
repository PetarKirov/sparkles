/**
The arena JSON document model (`docs/specs/wired/SPEC.md` §11.2).

A parsed document is one contiguous arena of 16-byte $(LREF JsonCell)s
plus one string pool holding every string unescaped and NUL-terminated.
$(LREF JsonDocument) owns both blocks; $(LREF JsonValue) is a copyable
8-byte borrowed view whose lifetime `dip1000` ties to the document.

Layout invariants (established by the reader, relied on by the views):

$(LIST
    * A container's children are stored contiguously after it; the next
        sibling of any value is `cell + extent(cell)` where a scalar's
        extent is 1 and a container stores its extent in the payload.
    * An object's children alternate key cell / value cell; keys are
        string cells.
    * String payloads point into the document's pool, are NUL-terminated,
        and carry their length in the cell tag.
)

Memory management follows the composable-allocators guideline
(`docs/guidelines/allocators/index.md` §4): the document is generic over
its allocator — monostate allocators (the `Mallocator` default) occupy
zero bytes via the `stateSize` idiom, stateful ones are stored. Over the
default `Mallocator` every operation here is `@safe pure nothrow @nogc`.
*/
module sparkles.wired.json.document;

import std.experimental.allocator.common : stateSize;
import std.experimental.allocator.mallocator : Mallocator;

/// The dynamic type of a JSON value in a parsed document.
enum JsonKind : ubyte
{
    none, /// default-constructed / invalid view
    null_, /// JSON `null`
    bool_, /// `true` / `false`
    integer, /// integer-shaped number that fits `long`
    uinteger, /// integer-shaped number that fits only `ulong`
    floating, /// number with fraction/exponent (or saturated overflow)
    string_, /// string (unescaped, NUL-terminated in the pool)
    rawNumber, /// verbatim number token (`JsonReadOptions.rawNumbers`)
    array, /// JSON array
    object, /// JSON object
}

/**
One 16-byte arena cell: a tag (kind in the low 8 bits, size — string
byte length or container member count — in the high 56) and an 8-byte
payload.
*/
package struct JsonCell
{
    ulong tag;
    /// The 8-byte payload, kind-dependent: i64/u64/f64 scalar bits, a
    /// pool pointer (strings), or the container extent. Stored as plain
    /// bits — a union with a pointer member would make every access
    /// `@system`; instead the few pointer reinterpretations live in
    /// small `@trusted` kernels.
    ulong bits;

    this(JsonKind kind, ulong size = 0) @safe pure nothrow @nogc
    {
        tag = kind | (size << 8);
    }

    JsonKind kind() const @safe pure nothrow @nogc
        => cast(JsonKind)(tag & 0xFF);

    /// String byte length or container member count.
    ulong size() const @safe pure nothrow @nogc
        => tag >> 8;

    /// Cells to the next sibling, this cell included.
    size_t extent() const @safe pure nothrow @nogc
    {
        const k = kind;
        return k == JsonKind.array || k == JsonKind.object
            ? cast(size_t) bits : 1;
    }

    /// The pool bytes of a string/rawNumber cell.
    const(char)[] text() const @trusted pure nothrow @nogc
    in (kind == JsonKind.string_ || kind == JsonKind.rawNumber)
        => (cast(immutable(char)*) bits)[0 .. size];
}

static assert(JsonCell.sizeof == 16);

/**
An owning, non-copyable, movable parsed JSON document (SPEC §11.2).

`Allocator` supplies both blocks (cell arena + string pool). The
document stores block slices (client-tracked sizes — the untyped `void[]`
protocol) and frees them in the destructor when the allocator supports
`deallocate`; under an arena parent (e.g. `Region`) the individual frees
may no-op and the region reclaims wholesale.
*/
struct JsonDocument(Allocator = Mallocator)
{
    static if (stateSize!Allocator)
        package Allocator alloc;
    else
        package alias alloc = Allocator.instance;

    package JsonCell[] cells; /// allocated arena (capacity)
    package size_t cellCount; /// cells in use, root first
    package char[] pool; /// string pool (padded input copy)

    @disable this(this);
    @disable void opAssign(ref JsonDocument);

    /// Whether the document holds a parsed value.
    bool valid() const @safe pure nothrow @nogc
        => cellCount != 0;

    /// The root value; its lifetime (and that of every view and string
    /// slice reached through it) is bound to this document.
    JsonValue root() const return scope @trusted pure nothrow @nogc
    in (valid, "empty document has no root")
        => JsonValue(&cells[0]);

    ~this()
    {
        static if (__traits(hasMember, Allocator, "deallocate"))
        {
            if (cells.length)
                () @trusted { alloc.deallocate(cast(void[]) cells); }();
            if (pool.length)
                () @trusted { alloc.deallocate(cast(void[]) pool); }();
        }
        cells = null;
        pool = null;
        cellCount = 0;
    }

    // ── package construction interface (used by the reader) ──────────────

    /// Allocates the two blocks; returns false on allocator failure.
    /// `goodAllocSize` slack is claimed for the arena — the reader's
    /// estimate is a lower bound, so free capacity is pure win.
    package bool acquire(size_t cellCapacity, size_t poolBytes)
    {
        import std.experimental.allocator.common : goodAllocSize;

        const cellBytes = goodAllocSize(alloc, cellCapacity * JsonCell.sizeof);
        auto cellBlock = alloc.allocate(cellBytes);
        if (cellBlock is null)
            return false;
        auto poolBlock = alloc.allocate(poolBytes);
        if (poolBlock is null)
        {
            static if (__traits(hasMember, Allocator, "deallocate"))
                () @trusted { alloc.deallocate(cellBlock); }();
            return false;
        }
        cells = () @trusted {
            return (cast(JsonCell*) cellBlock.ptr)[0 .. cellBlock.length / JsonCell.sizeof];
        }();
        pool = () @trusted {
            return (cast(char*) poolBlock.ptr)[0 .. poolBlock.length];
        }();
        return true;
    }

    /// Grows the cell arena ×1.5, preferring in-place `expand`, falling
    /// back to `reallocate` (cell indices — not pointers — thread the
    /// parser state, so a moving reallocation needs no fixups).
    package bool growCells()
    {
        const oldBytes = cells.length * JsonCell.sizeof;
        const newBytes = oldBytes + oldBytes / 2;
        auto block = () @trusted { return cast(void[]) cells; }();

        static if (__traits(hasMember, Allocator, "expand"))
        {
            const expanded = () @trusted {
                return alloc.expand(block, newBytes - oldBytes);
            }();
            if (expanded)
            {
                cells = () @trusted {
                    return (cast(JsonCell*) block.ptr)[0 .. block.length / JsonCell.sizeof];
                }();
                return true;
            }
        }
        static if (__traits(hasMember, Allocator, "reallocate"))
        {
            const reallocated = () @trusted {
                return alloc.reallocate(block, newBytes);
            }();
            if (reallocated)
            {
                cells = () @trusted {
                    return (cast(JsonCell*) block.ptr)[0 .. block.length / JsonCell.sizeof];
                }();
                return true;
            }
            return false;
        }
        else
        {
            // allocate + copy + deallocate
            auto fresh = alloc.allocate(newBytes);
            if (fresh is null)
                return false;
            () @trusted {
                fresh[0 .. oldBytes] = block[];
            }();
            static if (__traits(hasMember, Allocator, "deallocate"))
                () @trusted { alloc.deallocate(block); }();
            cells = () @trusted {
                return (cast(JsonCell*) fresh.ptr)[0 .. fresh.length / JsonCell.sizeof];
            }();
            return true;
        }
    }
}

/**
A borrowed, copyable, 8-byte view of one value in a document
(SPEC §11.2). Copying a view is free; the document must outlive every
view (`dip1000`-enforced from `root()` onward). Accessors carry
`in`-contracts on the dynamic kind; iteration is forward-only through
$(LREF byElement) / $(LREF byKeyValue) — element access is sequential by
design (the layout stores extents, not child pointers).
*/
struct JsonValue
{
    private const(JsonCell)* cell;

    static assert(JsonValue.sizeof == 8);

    /// The dynamic type (`JsonKind.none` for a default view).
    JsonKind kind() const scope @safe pure nothrow @nogc
        => cell is null ? JsonKind.none : (() @trusted => cell.kind)();

    /// `true`/`false` payload.
    bool boolean() const scope @trusted pure nothrow @nogc
    in (kind == JsonKind.bool_)
        => cell.bits != 0;

    /// Integer payload (`JsonKind.integer`).
    long integer() const scope @trusted pure nothrow @nogc
    in (kind == JsonKind.integer)
        => cast(long) cell.bits;

    /// Unsigned payload (`JsonKind.uinteger`: fits `ulong` but not `long`).
    ulong uinteger() const scope @trusted pure nothrow @nogc
    in (kind == JsonKind.uinteger)
        => cell.bits;

    /// Floating payload (`JsonKind.floating`).
    double floating() const scope @trusted pure nothrow @nogc
    in (kind == JsonKind.floating)
    {
        import sparkles.base.text.float_conv : bitsToDouble;

        return bitsToDouble(cell.bits);
    }

    /// Any number kind, converted to `double`.
    double asDouble() const scope @safe pure nothrow @nogc
    in (kind == JsonKind.integer || kind == JsonKind.uinteger
        || kind == JsonKind.floating)
    {
        final switch (kind) with (JsonKind)
        {
        case integer:
            return cast(double) this.integer;
        case uinteger:
            return cast(double) this.uinteger;
        case floating:
            return this.floating;
        case none, null_, bool_, string_, rawNumber, array, object:
            assert(false);
        }
    }

    /// String payload — unescaped; a NUL byte follows the slice in the
    /// document's pool. Borrowed from the document.
    const(char)[] str() const return scope @trusted pure nothrow @nogc
    in (kind == JsonKind.string_)
        => cell.text;

    /// Verbatim number token text (`JsonKind.rawNumber`).
    const(char)[] raw() const return scope @trusted pure nothrow @nogc
    in (kind == JsonKind.rawNumber)
        => cell.text;

    /// Array element count / object member count.
    size_t length() const scope @trusted pure nothrow @nogc
    in (kind == JsonKind.array || kind == JsonKind.object)
        => cast(size_t) cell.size;

    /// Forward range over an array's elements.
    JsonArrayRange byElement() const return scope @trusted pure nothrow @nogc
    in (kind == JsonKind.array)
        => JsonArrayRange(cell + 1, cast(size_t) cell.size);

    /// Forward range over an object's members (`JsonMember`s).
    JsonObjectRange byKeyValue() const return scope @trusted pure nothrow @nogc
    in (kind == JsonKind.object)
        => JsonObjectRange(cell + 1, cast(size_t) cell.size);

    /// The value under `key`, or a `JsonKind.none` view when absent —
    /// a linear scan (O(members)); prefer one `byKeyValue` pass over
    /// repeated lookups.
    JsonValue objectGet(scope const(char)[] key) const return scope @safe pure nothrow @nogc
    in (kind == JsonKind.object)
    {
        foreach (m; byKeyValue)
            if (m.key == key)
                return m.value;
        return JsonValue.init;
    }
}

/// One object member: the (unescaped, borrowed) key and the value view.
struct JsonMember
{
    const(char)[] key;
    JsonValue value;
}

/// Forward range over array elements (extent-hop walk).
struct JsonArrayRange
{
    private const(JsonCell)* cur;
    private size_t remaining;

    bool empty() const scope @safe pure nothrow @nogc => remaining == 0;

    JsonValue front() const return scope @safe pure nothrow @nogc
    in (!empty)
        => JsonValue(cur);

    void popFront() scope @trusted pure nothrow @nogc
    in (!empty)
    {
        cur += cur.extent;
        remaining--;
    }
}

/// Forward range over object members (key cell + value extent hops).
struct JsonObjectRange
{
    private const(JsonCell)* cur; // points at a key cell
    private size_t remaining;

    bool empty() const scope @safe pure nothrow @nogc => remaining == 0;

    JsonMember front() const return scope @trusted pure nothrow @nogc
    in (!empty)
    {
        assert(cur.kind == JsonKind.string_, "object key must be a string cell");
        return JsonMember(cur.text, JsonValue(cur + 1));
    }

    void popFront() scope @trusted pure nothrow @nogc
    in (!empty)
    {
        const valueCell = cur + 1;
        cur = valueCell + valueCell.extent;
        remaining--;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests — the reader lands next milestone; these hand-assemble documents.
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    /// Builds `{"a": 1, "b": [true, null, 2.5]}` by hand into `doc`.
    /// Pool: "a\0b\0"; 9 cells.
    private void assembleSample(A)(ref JsonDocument!A doc) @trusted
    {
        assert(doc.acquire(16, 8));
        doc.pool[0 .. 4] = "a\0b\0";
        auto c = doc.cells;

        import sparkles.base.text.float_conv : doubleToBits;

        c[0] = JsonCell(JsonKind.object, 2);
        c[0].bits = 9; // extent
        c[1] = JsonCell(JsonKind.string_, 1); // "a"
        c[1].bits = cast(ulong) doc.pool.ptr;
        c[2] = JsonCell(JsonKind.integer);
        c[2].bits = 1;
        c[3] = JsonCell(JsonKind.string_, 1); // "b"
        c[3].bits = cast(ulong)(doc.pool.ptr + 2);
        c[4] = JsonCell(JsonKind.array, 3);
        c[4].bits = 4; // extent
        c[5] = JsonCell(JsonKind.bool_);
        c[5].bits = 1;
        c[6] = JsonCell(JsonKind.null_);
        c[7] = JsonCell(JsonKind.floating);
        c[7].bits = doubleToBits(2.5);
        c[8] = JsonCell(JsonKind.none);
        doc.cellCount = 9;
    }
}

@("document.JsonCell.layout")
@safe pure nothrow @nogc
unittest
{
    static assert(JsonCell.sizeof == 16);
    static assert(JsonValue.sizeof == 8);

    auto cell = JsonCell(JsonKind.string_, 5);
    assert(cell.kind == JsonKind.string_);
    assert(cell.size == 5);
    assert(cell.extent == 1); // scalar/string extent is implicit

    auto arr = JsonCell(JsonKind.array, 100);
    arr.bits = 42;
    assert(arr.size == 100);
    assert(arr.extent == 42);

    // 56-bit size survives the tag round-trip.
    auto big = JsonCell(JsonKind.string_, (1UL << 56) - 1);
    assert(big.size == (1UL << 56) - 1);
    assert(big.kind == JsonKind.string_);
}

@("document.views.handAssembledWalk")
@safe pure nothrow @nogc
unittest
{
    JsonDocument!Mallocator doc;
    (() @trusted => assembleSample(doc))();
    assert(doc.valid);

    auto root = doc.root;
    assert(root.kind == JsonKind.object);
    assert(root.length == 2);

    size_t seen;
    foreach (m; root.byKeyValue)
    {
        if (seen == 0)
        {
            assert(m.key == "a");
            assert(m.value.kind == JsonKind.integer);
            assert(m.value.integer == 1);
            assert(m.value.asDouble == 1.0);
        }
        else
        {
            assert(m.key == "b");
            assert(m.value.kind == JsonKind.array);
            assert(m.value.length == 3);
        }
        seen++;
    }
    assert(seen == 2);

    auto arr = root.objectGet("b");
    assert(arr.kind == JsonKind.array);
    size_t i;
    foreach (v; arr.byElement)
    {
        final switch (i)
        {
        case 0:
            assert(v.kind == JsonKind.bool_ && v.boolean == true);
            break;
        case 1:
            assert(v.kind == JsonKind.null_);
            break;
        case 2:
            assert(v.kind == JsonKind.floating && v.floating == 2.5);
            break;
        }
        i++;
    }
    assert(i == 3);

    assert(root.objectGet("missing").kind == JsonKind.none);
}

@("document.allocator.exactCountsAndZeroLeaks")
@system unittest
{
    // Stateful allocator with externally observable counters — proves the
    // store-the-allocator path and pins exact allocation behavior.
    static struct CountingMallocator
    {
        size_t* allocs, deallocs;
        size_t* liveBytes;

        enum uint alignment = Mallocator.alignment;

        void[] allocate(size_t n) @trusted nothrow @nogc
        {
            auto b = Mallocator.instance.allocate(n);
            if (b !is null)
            {
                (*allocs)++;
                *liveBytes += b.length;
            }
            return b;
        }

        bool deallocate(void[] b) @trusted nothrow @nogc
        {
            if (b is null)
                return true;
            (*deallocs)++;
            *liveBytes -= b.length;
            return Mallocator.instance.deallocate(b);
        }

        bool reallocate(ref void[] b, size_t s) @trusted nothrow @nogc
        {
            const old = b.length;
            if (!Mallocator.instance.reallocate(b, s))
                return false;
            *liveBytes += b.length - old;
            return true;
        }
    }

    size_t allocs, deallocs, liveBytes;
    {
        auto doc = JsonDocument!CountingMallocator(
            CountingMallocator(&allocs, &deallocs, &liveBytes));
        assert(doc.acquire(8, 64));
        assert(allocs == 2); // one arena + one pool, exactly
        assert(liveBytes >= 8 * JsonCell.sizeof + 64);

        // Grow the arena; the document stays at 2 live blocks.
        const before = doc.cells.length;
        assert(doc.growCells());
        assert(doc.cells.length > before);
    }
    // Destruction frees everything: zero leaked bytes, one deallocate per
    // live block (realloc reuses the arena block).
    assert(liveBytes == 0);
    assert(deallocs == 2);
}

@("document.allocator.regionInstantiation")
@system unittest
{
    import std.experimental.allocator.building_blocks.region : Region;

    // A Region-backed document: allocations come from the arena; the
    // document's individual deallocations no-op (LIFO-only) and the
    // region reclaims wholesale — exactly the documented semantics.
    static struct RegionRef
    {
        Region!Mallocator* impl;

        enum uint alignment = Region!Mallocator.alignment;

        void[] allocate(size_t n) => impl.allocate(n);
        bool deallocate(void[] b) => impl.deallocate(b);
        bool expand(ref void[] b, size_t delta) => impl.expand(b, delta);
    }

    auto region = Region!Mallocator(64 * 1024);
    {
        auto doc = JsonDocument!RegionRef(RegionRef(&region));
        assert(doc.acquire(16, 128));
        (() @trusted => assembleSample2(doc))();
        assert(doc.valid);
        assert(doc.root.kind == JsonKind.array);
        // In-place expand works at the top of the region.
        assert(doc.growCells());
    }
    // Region memory reclaims when `region` goes out of scope.
}

version (unittest)
{
    /// `[false]` — minimal two-cell document for the Region test (the
    /// main sample needs `acquire` to have succeeded with 16 cells).
    private void assembleSample2(A)(ref JsonDocument!A doc) @trusted
    {
        auto c = doc.cells;
        c[0] = JsonCell(JsonKind.array, 1);
        c[0].bits = 2; // extent
        c[1] = JsonCell(JsonKind.bool_);
        c[1].bits = 0;
        doc.cellCount = 2;
    }
}

@("document.move.ownershipTransfers")
@system unittest
{
    import core.lifetime : move;

    JsonDocument!Mallocator a;
    (() @trusted => assembleSample(a))();
    assert(a.valid);

    auto b = move(a);
    assert(b.valid);
    assert(!a.valid); // moved-from: empty, destructor is a no-op
    assert(b.root.kind == JsonKind.object);

    static assert(!__traits(compiles, { auto c = b; })); // non-copyable
}
