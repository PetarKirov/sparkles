/**
 * A @nogc container with Small Buffer Optimization (SBO).
 *
 * Provides an append-only buffer that stores small amounts of data inline
 * (avoiding heap allocation) and automatically switches to heap storage
 * when capacity is exceeded.
 *
 * Primary use case: appending elements in a temporary scope where GC
 * allocation is not desired.
 */
module sparkles.base.buffer;

import std.algorithm.comparison : max;
import std.array : overlap;
import std.range.primitives : ElementType, hasLength, hasSlicing, isInputRange;
import std.experimental.allocator : makeArray, expandArray, dispose;
import std.traits : hasIndirections;
import std.experimental.allocator.building_blocks.affix_allocator : AffixAllocator;

import sparkles.test_runner.attributes : betterC;

version (unittest) import std.range : iota;

/// Whether `elements` aliases `region` — the guard the append paths use before
/// an inline->heap transition can invalidate the source.
///
/// `std.array.overlap` *orders* two pointers, which CTFE rejects outright when
/// they come from unrelated blocks ("the ordering of pointers to unrelated
/// memory blocks is indeterminate"). That would make every compile-time append
/// a compile error, so at CTFE this compares element *identity* instead: a
/// source that aliases a buffer is a slice of that buffer's own storage, hence
/// its first element is one of `region`'s. Runtime keeps `overlap`'s O(1) test.
///
/// Attributes infer: the address-of/identity work is `@safe`, and `overlap`
/// carries its own.
private bool aliasesRegion(T)(in T[] elements, in T[] region)
{
    if (elements.length == 0 || region.length == 0)
        return false;
    if (__ctfe)
    {
        foreach (i; 0 .. region.length)
            if (&region[i] is &elements[0])
                return true;
        return false;
    }
    return elements.overlap(region).length != 0;
}

// Heap blocks carry a `ControlBlock` refcount prefix ahead of the element data.
// These live at module scope (rather than nested in the struct) so that the
// copy-on-write and `unique` instantiations of `Buffer` share one
// allocator type — that is what lets `toShared` transfer a heap block from a
// `unique` buffer to a copy-on-write one without reallocating.
/*
druntime's collector-root entry points, redeclared `pure`.

`core.memory.GC.addRange`/`removeRange` are `nothrow @nogc` but not `pure`, and
`Buffer`'s methods are — a display list built in `pure` code still has to
root its block. This is druntime's own `pureMalloc` device: declare the C symbol
with the attributes the caller needs, because registering a root changes only
whether the collector may reclaim memory, which no pure computation observes.

$(B Declared, not cast.) Casting a function pointer to `pure` and calling it for
its side effect alone is not equivalent: a strongly-pure call returning `void`
has, by definition, no observable effect, and the compiler is free to delete it.
dmd does exactly that — with the cast in place, the roots were never registered
and the tests below collected their payloads out from under the buffer, while
ldc kept the calls and passed. An `extern (C)` declaration is emitted as a call.

`ti` is passed as `null`: the range holds `b.length` elements and a single
element's `TypeInfo` would describe only the first, so conservative scanning of
the whole block is the honest request.
*/
extern (C) private pure nothrow @nogc @system
{
    pragma(mangle, "gc_addRange") void pureGcAddRange(const void* p, size_t sz, const TypeInfo ti);
    pragma(mangle, "gc_removeRange") void pureGcRemoveRange(const void* p);
}

private struct ControlBlock { size_t refCount; }

/*
`Mallocator`, restated over druntime's `pureMalloc` family.

Phobos' own `Mallocator` is shaped exactly like this, and using it directly is
what kept this module out of `-betterC` builds: its `instance`, `allocate`,
`reallocate` and `deallocate` are ordinary (non-template) members, so they are
emitted once into `libphobos2` and a druntime-free link has nothing to resolve
them against. Everything else this module borrows from
`std.experimental.allocator` — `AffixAllocator`, `makeArray`, `expandArray`,
`dispose` — is a template, and templates are instantiated into the caller's
object file, so they link fine. Swapping the one leaf that isn't buys the whole
container a `-betterC` build without changing a line of its allocation,
initialization or destruction semantics.

`core.memory`'s `pureMalloc`/`pureRealloc`/`pureFree` are `extern (C)`
forwarders to libc, present with or without druntime, and already the repo's
sanctioned manual-allocation primitives.
*/
private struct PureMallocator
{
    import std.experimental.allocator.common : platformAlignment;

    enum uint alignment = platformAlignment;

    @trusted @nogc nothrow pure
    void[] allocate(size_t bytes) shared const
    {
        import core.memory : pureMalloc;

        if (!bytes)
            return null;
        auto p = pureMalloc(bytes);
        return p ? p[0 .. bytes] : null;
    }

    @system @nogc nothrow pure
    bool reallocate(ref void[] b, size_t bytes) shared const
    {
        import core.memory : pureFree, pureRealloc;

        if (!bytes)
        {
            pureFree(b.ptr);
            b = null;
            return true;
        }
        auto p = pureRealloc(b.ptr, bytes);
        if (p is null)
            return false;
        b = p[0 .. bytes];
        return true;
    }

    @system @nogc nothrow pure
    bool deallocate(void[] b) shared const
    {
        import core.memory : pureFree;

        pureFree(b.ptr);
        return true;
    }

    static shared PureMallocator instance;
}

private alias BlockAllocator = AffixAllocator!(PureMallocator, ControlBlock);

/*
Copies `src` onto `dst`, which must be the same length, without druntime.

D's own `dst[] = src[]` lowers to a call to druntime's `_d_array_slice_copy`,
which a `-betterC` link has nothing to resolve — one such copy anywhere in the
buffer costs the whole container its druntime-free build, and it has one on
every copy, growth and storage-transition path. `memmove` comes from libc and
links either way.

`memmove` rather than `memcpy`: every caller here copies between provably
disjoint ranges (the append paths check with `aliasesRegion` first, and the
storage transitions stage through a separate buffer), but the overlapping case
is a silent corruption rather than a loud failure, and the ranges are short
enough that the difference does not show up.

Only plain-old-data takes that path. An element type with a postblit, a copy
constructor or a destructor keeps per-element assignment, so those run exactly
as they did when the compiler emitted the copy.
*/
private void copyElements(Dst, Src)(scope Dst[] dst, scope Src[] src)
if (is(typeof(dst[0] = src[0])) && Dst.sizeof == Src.sizeof)
in (dst.length == src.length, "copyElements: length mismatch")
{
    // Deduced separately rather than as one `T`: the copy constructor is
    // `inout`, so both sides arrive as `inout(T)[]` and neither matches a
    // `const(T)[]` parameter.
    static if (__traits(isPOD, Dst))
    {
        if (__ctfe)
        {
            foreach (i; 0 .. src.length)
                dst[i] = src[i];
        }
        else if (src.length)
        {
            (() @trusted {
                import core.stdc.string : memmove;

                memmove(cast(void*) dst.ptr, cast(const void*) src.ptr,
                    src.length * Dst.sizeof);
            })();
        }
    }
    else
    {
        foreach (i; 0 .. src.length)
            dst[i] = src[i];
    }
}

// Round a required element count up to the next power of two (saturating: a
// count whose doubling would overflow is left as-is). Shared by every growth
// site so the capacity policy stays in one place.
private size_t roundedCapacity(size_t needed) @safe pure nothrow @nogc
{
    import std.math.algebraic : truncPow2;

    size_t capacity = needed;
    if (capacity > 0)
    {
        const t = truncPow2(capacity);
        if (t != capacity)
        {
            const rounded = t << 1;
            if (rounded != 0)
                capacity = rounded;
        }
    }
    return capacity;
}

/**
What storage a buffer may use, and whether it may be copied.

The bits are capabilities, so the combination $(I is) the policy: `inline` alone
never allocates, `heap` alone carries no inline array, and both together is the
small-buffer optimization. $(LREF Storage.none) is the empty set — the neutral
default for an alias's `extra` parameter — but a buffer with neither storage bit
has nowhere to put anything and fails $(LREF Buffer)'s constraint.
*/
enum Storage : ubyte
{
    none   = 0,      /// the empty set — not a valid policy on its own
    inline = 1 << 0, /// may hold elements in the inline `T[N]`
    heap   = 1 << 1, /// may allocate
    unique = 1 << 2, /// move-only: copying is disabled, so the grow path is refcount-free
}

/**
 * A `@nogc` container whose storage policy is a template parameter.
 *
 * `storage` is a set of $(LREF Storage) capability bits, and the combination is
 * the policy: `inline` alone never allocates, `heap` alone carries no inline
 * array, both together is the small-buffer optimization, and `unique` on top of
 * either disables copying. Prefer the aliases — $(LREF InlineBuffer),
 * $(LREF UniqueBuffer), $(LREF SharedBuffer), $(LREF HeapBuffer) — and spell the
 * bits out only for a combination none of them names.
 *
 * $(B Which one?) $(LREF UniqueBuffer) is the default: a buffer with a single
 * owner should not pay for a reference count. Reach for $(LREF SharedBuffer)
 * when the buffer is genuinely copied — naming it is a claim that something
 * copies it.
 *
 * With `Storage.heap`, elements are stored inline up to `N` elements, then
 * automatically allocated on the heap (via
 * `AffixAllocator!(Mallocator, ControlBlock)`, which keeps the reference count
 * in an allocation prefix; the element capacity is the heap slice length) when
 * capacity is exceeded. Heap blocks are managed with the
 * `std.experimental.allocator` `makeArray`/`expandArray`/`dispose` helpers.
 *
 * Without `Storage.unique` the buffer is copyable. Copying an inline buffer
 * duplicates its elements (independent copies). Copying a heap buffer shares the
 * allocation and bumps a reference count; the shared block is cloned
 * copy-on-write the first time a mutable copy is written. This suits the common
 * pattern of one producer building a buffer mutably, then handing out many
 * `const` reader copies — read via `const` (e.g. through `borrow`) never clones.
 * Mutating accessors on a shared mutable copy clone first, so a mutable
 * slice/reference taken from a shared buffer and held across a later mutation
 * may be invalidated (the usual copy-on-write caveat) — read through `const` to
 * share without that risk.
 *
 * With `Storage.unique`, copy construction and assignment are `@disable`d, so
 * the buffer is a sole owner by construction. Mutation then never reads or bumps
 * a reference count — the append/grow hot path skips the uniqueness check
 * entirely. Hand a finished one to the shareable copy-on-write world with
 * $(LREF Buffer.toShared), which consumes it and returns the corresponding
 * copy-on-write instantiation (heap storage transfers without a reallocation).
 *
 * Any policy carrying `Storage.heap` is an output range. `Storage.inline` alone
 * is deliberately not one — `put` promises to accept what it is given, and a
 * buffer that cannot grow cannot promise that — so write into it with
 * $(LREF Buffer.tryWrite), which reports overflow instead.
 *
 * Note: with both storage bits, location is tied to length (data is inline
 * whenever `length <= N`), so `reserve` pre-grows only once on the heap,
 * and `clear`/`popBack` that drop the length back to `<= N` revert
 * to inline storage. A policy with `Storage.heap` alone has nothing to revert
 * to, so it keeps its block across every shrink — `popBack`, `length`, `clear` —
 * and releases it only in the destructor (or transfers it via `toShared`):
 * `reserve` once, then reuse.
 *
 * Params:
 *   T = Element type
 *   N = Number of elements stored inline, and `0` exactly when `storage` omits
 *       `Storage.inline`. The default fills the slice-sized union exactly
 *       (`max(1, (T[]).sizeof / T.sizeof)`), so the struct stays three words
 *       (`3 * size_t.sizeof`) regardless of `T` — e.g. 16 for `char`, 4 for
 *       `int`, 2 for `long`.
 *   storage = The $(LREF Storage) capability bits that make up the policy. Must
 *       include at least one of `Storage.inline` / `Storage.heap`: a buffer with
 *       neither has nowhere to put anything.
 */
struct Buffer(T, size_t N = max(size_t(1), (T[]).sizeof / T.sizeof),
    Storage storage = cast(Storage)(Storage.inline | Storage.heap))
if (storage & (Storage.inline | Storage.heap))
{
pure nothrow @nogc:

    /// May elements live in the inline `T[N]`?
    private enum bool hasInline = (storage & Storage.inline) != 0;
    /// May this buffer allocate?
    private enum bool hasHeap = (storage & Storage.heap) != 0;
    /// Is copying disabled?
    private enum bool unique = (storage & Storage.unique) != 0;

    /**
    How many elements fit without allocating — `N`, named.

    A compile-time constant, unlike $(LREF Buffer.capacity), so it can size a
    static array that has to hold this buffer's contents. That is the one place
    the number would otherwise be repeated as a literal and drift.
    */
    enum size_t inlineCapacity = N;

    static if (hasInline)
        static assert(N > 0, "N must be greater than 0 for a policy with Storage.inline");
    else
        static assert(N == 0,
            "N is the inline capacity; a policy without Storage.inline must pass 0");

    // The copy-on-write instantiation this `unique` buffer promotes to (and,
    // symmetrically, the type `toShared` returns). Same field layout — only the
    // ownership discipline differs — so a heap block moves across for free.
    static if (unique)
        private alias Shared = Buffer!(T, N, cast(Storage)(storage & ~Storage.unique));

    private
    {
        // Discriminant: `_length <= N` <=> data lives inline. With only one
        // residency that reduces to a constant, and the dead field is absent
        // rather than merely unused.
        size_t _length = 0;

        // `_inline` is deliberately NOT `= void`. For a `T` holding references
        // the untouched slots would be garbage pointers, which the conservative
        // scan of a stack- or GC-resident buffer would follow.
        static if (hasHeap)
            union
            {
                // `T[N]` is `T[0]` for a heap-only policy — zero bytes, so the
                // struct still costs one slice — which keeps `_length > N` a
                // correct discriminant and every growth path unchanged.
                T[N] _inline;                     // live iff !onHeap
                T[] _block;                       // capacity slots (ControlBlock prefix precedes them)
            }
        else
            // No union, so a slice of `_inline` is provably a reference to the
            // frame — which is what lets `-dip1000` reject escaping one.
            T[N] _inline;

        alias Allocator = BlockAllocator;

        static if (hasHeap)
            // The shared control block (logically-mutable metadata; valid iff onHeap).
            ref ControlBlock ctrl() const @system
                => Allocator.instance.prefix(cast(ubyte[]) _block);
    }

    @property const
    {
    @safe:
        /// Returns the number of elements in the buffer.
        size_t length() => _length;

        /// Supports `$` operator in slices.
        alias opDollar = length;

        /// Returns true if the buffer contains no elements.
        bool empty() => _length == 0;

        /// Returns true if the buffer is using heap-allocated storage.
        static if (hasHeap && !hasInline)
            // `_length > N` is `_length > 0` here, which cannot express a block
            // reserved before anything was written. The block itself is the
            // discriminant instead. `@trusted` to read the overlapped field:
            // `T[0]` occupies no bytes, so nothing else can be live in it.
            bool onHeap() @trusted => _block !is null;
        else
            bool onHeap() => hasHeap && _length > N;

    @trusted:
        /// Returns the total capacity of the buffer.
        static if (hasHeap)
            size_t capacity() => onHeap ? _block.length : N;
        else
            size_t capacity() => N;   // `N` is the whole of it

        static if (!unique && hasHeap)
            /// Test-facing: shared reference count (0 while inline).
            private size_t refCount() =>
                onHeap ? ctrl().refCount : 0;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // copy / assign / destroy
    // ─────────────────────────────────────────────────────────────────────────

    static if (unique)
    {
        // `unique` buffers are move-only: a sole owner cannot be copied, only
        // moved (or promoted with `toShared`). Disabling the copy constructors
        // and copy-assignment is what makes the append/grow path refcount-free.
        @disable this(ref inout Buffer);
        @disable this(ref const Buffer);
        @disable ref Buffer opAssign(ref const Buffer);
    }
    else
    {
        /**
         * Copy constructor (copy-on-write). An inline buffer copies its elements,
         * yielding an independent buffer. A heap buffer instead shares storage and
         * bumps the reference count; the shared block is cloned only when a mutable
         * copy is first written (see `ensureUniqueStorage`). Reaching a copy through
         * `const` (e.g. via `borrow`) is therefore a zero-clone read-only handle.
         */
        this(ref scope inout Buffer rhs) inout scope @trusted
        {
            this._length = rhs._length;
            // `inout` is assignable only inside an `inout` function, and
            // `copyElements` is not one — so the qualifier is cast off for the
            // copy. Sound here for the same reason the `const` overload below
            // casts: this object is under construction and nothing else can
            // observe its storage yet.
            static if (hasHeap)
            {
                if (rhs.onHeap)
                {
                    this._block = rhs._block;
                    ++this.ctrl().refCount;
                    return;
                }
            }
            copyElements(cast(T[]) this._inline[0 .. rhs._length],
                cast(const(T)[]) rhs._inline[0 .. rhs._length]);
        }

        /// Build a mutable working copy from a `const` (e.g. borrowed) buffer.
        this(ref scope const Buffer rhs) scope @trusted
        {
            _length = rhs._length;
            static if (hasHeap)
            {
                if (rhs.onHeap)
                {
                    _block = cast(T[]) rhs._block;
                    ++ctrl().refCount;
                    return;
                }
            }
            copyElements(_inline[0 .. rhs._length], rhs._inline[0 .. rhs._length]);
        }

        /// Copy assignment: release current storage, then share/copy from `rhs`.
        /// Accepts a `const` (e.g. borrowed) source — a heap source is shared (refcount
        /// bumped), an inline source is copied — mirroring the copy constructors.
        ref Buffer opAssign(ref scope const Buffer rhs) return scope @trusted
        {
            if (&this is &rhs)
                return this;

            static if (hasHeap)
            {
                if (rhs.onHeap)
                    ++rhs.ctrl().refCount; // acquire rhs before releasing self

                releaseStorage();
                _length = rhs._length;

                if (rhs.onHeap)
                {
                    _block = cast(T[]) rhs._block;
                    return this;
                }
            }
            else
                _length = rhs._length;

            copyElements(_inline[0 .. rhs._length], rhs._inline[0 .. rhs._length]);
            return this;
        }
    }

    /// Move assignment from an rvalue: release current storage, then steal
    /// `rhs`'s storage (no refcount change — ownership transfers). `rhs` is
    /// neutralized so its destructor frees nothing.
    ref Buffer opAssign(scope Buffer rhs) return scope @trusted
    {
        static if (hasHeap)
        {
            releaseStorage();
            _length = rhs._length;
            if (rhs.onHeap)
            {
                _block = rhs._block;
                // Both discriminants: a policy with inline storage derives
                // `onHeap` from the length, a heap-only one from the block.
                // Zeroing only the length left the latter's destructor freeing
                // the block this buffer had just taken.
                rhs._block = null;
                rhs._length = 0;
                return this;
            }
        }
        else
            _length = rhs._length;

        copyElements(_inline[0 .. rhs._length], rhs._inline[0 .. rhs._length]);
        rhs._length = 0;
        return this;
    }

    static if (hasHeap)
        /// Destructor: drop this owner's reference; dispose heap memory at zero.
        // `releaseStorage` directly, not `clear`: for a heap-only policy `clear`
        // deliberately keeps the block, and this is the one place it must go.
        ~this() @safe { releaseStorage(); }

    // ─────────────────────────────────────────────────────────────────────────
    // element access — const path shares; mutable path clones if shared
    //
    // The mutable `opSlice`/`opIndex`/`front`/`back` overloads call
    // `ensureUniqueStorage()`, so on a shared (heap, refcount > 1) buffer they trigger a
    // copy-on-write clone *even when you only read* the returned reference —
    // overload resolution cannot tell read from write. To share a heap buffer
    // without cloning, read through `const`/`borrow` (which select the const
    // overloads).
    // ─────────────────────────────────────────────────────────────────────────

    // Current element slice; element constness follows `this`. `return scope`: the
    // slice may alias `this` (inline storage), so `this` can't escape and the
    // result's lifetime is bounded by the buffer.
    private inout(T)[] view() inout return scope @trusted
    {
        static if (hasHeap)
            return onHeap ? _block[0 .. _length] : _inline[0 .. _length];
        else
            return _inline[0 .. _length];
    }

    // The element accessors below all return storage that may alias `this` (the
    // inline small-buffer or the shared heap block), so each is `return scope` —
    // the result is lifetime-bounded by the buffer, which lets `-dip1000` prove a
    // container that holds a `Buffer` and exposes `return scope` views over it
    // (e.g. `sparkles.tui.cell.Grid`) doesn't leak the storage. See the
    // `Buffer.unique.returnScopeContainer` regression test.
    @safe
    {
        /// Returns a read-only slice of all elements (shares storage).
        const(T)[] opSlice() const return scope => view();

        /// Returns a mutable slice of all elements (clones if shared).
        T[] opSlice() return scope
        {
            static if (hasHeap)
                ensureUniqueStorage();   // no shared block to clone otherwise
            return view();
        }

        /// Returns a read-only sub-slice from `start` to `end`.
        const(T)[] opSlice(size_t start, size_t end) const return scope
        in (start <= end, "Invalid slice bounds: start > end")
        in (end <= _length, "Slice end out of bounds")
            => this[][start .. end];

        /// Returns a mutable sub-slice from `start` to `end` (clones if shared).
        T[] opSlice(size_t start, size_t end) return scope
        in (start <= end, "Invalid slice bounds: start > end")
        in (end <= _length, "Slice end out of bounds")
            => this[][start .. end];

        /// Returns a read-only reference to the element at the given index.
        ref const(T) opIndex(size_t index) const return scope
        in (index < _length, "Index out of bounds") => this[][index];

        /// Returns a mutable reference to the element at the given index.
        ref T opIndex(size_t index) return scope
        in (index < _length, "Index out of bounds") => this[][index];

        /// Returns a read-only reference to the first element.
        ref const(T) front() const return scope => this[0];

        /// Returns a mutable reference to the first element.
        ref T front() return scope => this[0];

        /// Returns a read-only reference to the last element.
        ref const(T) back() const return scope => this[$ - 1];

        /// Returns a mutable reference to the last element.
        ref T back() return scope => this[$ - 1];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // mutation
    // ─────────────────────────────────────────────────────────────────────────

    /// Output range interface: appends a single element.
    // A buffer that may not allocate is deliberately NOT an output range:
    // `put` promises to accept what it is given, and a fixed capacity cannot.
    // Write into one with `tryWrite`, which reports overflow instead.
    static if (hasHeap)
    {
        void put(T element) scope @safe
        {
            putOne(element);
        }

        /*
        The append proper.

        The parameter above is `in` — and so `scope` under `-preview=in` — only for
        an element type that carries no references. Where `T` does carry them,
        `scope` would be a promise the buffer cannot keep: it stores the element,
        which outlives the call, so a scope reference handed in would be escaping.
        Such a caller must own what it hands over, which is what taking `T` by value
        says.
        */
        private void putOne(T element) scope @safe
        {
            // Fast path: while the buffer is inline (`length <= N`) it is always
            // uniquely owned — copy-on-write applies only to shared heap blocks — so
            // append straight into the inline slots and skip `ensureUniqueStorage`
            // (and its refcount work) entirely. This is the hot path for output-range
            // builders that never spill to the heap.
            const l = _length;
            if (l < N)
            {
                (() @trusted { _inline[l] = element; })();
                _length = l + 1;
                return;
            }
            T tmp = element;
            T[] tail = ensureUniqueStorage(extraLen: 1);
            tail[0] = tmp;
            ++_length;
        }

        /// Output range interface: appends elements from a slice.
        void put(in T[] elements) scope @trusted
        {
            const n = elements.length;
            if (n == 0)
                return;

            const oldLen = _length;
            const newLen = oldLen + n;

            static if (unique)
            {
                // Sole owner: no refcount to consult and no shared block to clone.
                const hasRoom = onHeap ? newLen <= _block.length : newLen <= N;
                if (hasRoom)
                {
                    // Existing storage already has the slots. Any source that
                    // aliases us lives in `[0 .. oldLen]`, disjoint from the
                    // `[oldLen .. newLen]` destination, so a plain copy is safe.
                    _length = newLen;
                    copyElements(this.view()[oldLen .. newLen], elements[]);
                    return;
                }

                // Growth needed: `ensureUniqueStorage` performs the inline->heap
                // transition or the in-place realloc, preserving `[0 .. oldLen]`. If
                // the source aliases that region it is preserved (and possibly
                // relocated) too, so we recover it from the grown block by its
                // offset rather than reading the now-stale `elements`.
                auto v = this.view();
                const overlaps = elements.aliasesRegion(v);
                const aliasStart = overlaps ? cast(size_t)(elements.ptr - v.ptr) : 0;

                T[] tail = ensureUniqueStorage(extraLen: n);
                copyElements(tail, overlaps ? _block[aliasStart .. aliasStart + n] : elements[]);
                _length = newLen;
                return;
            }
            else
            {
                // If the source aliases inline storage, preserve it before the union is
                // overwritten by the inline->heap transition.
                const overlapsInline = () @trusted {
                    return !onHeap && elements.aliasesRegion(_inline[0 .. oldLen]);
                }();

                // Fast path: the result stays inline (always uniquely owned) and the
                // source doesn't alias our live inline data — one bulk copy, no
                // `ensureUniqueStorage`/refcount work.
                if (newLen <= N && !overlapsInline)
                {
                    copyElements(_inline[oldLen .. newLen], elements[]);
                    _length = newLen;
                    return;
                }

                if (newLen > N && overlapsInline)
                {
                    static if (hasIndirections!T)
                        T[N] tmp;
                    else
                        T[N] tmp = void;
                    copyElements(tmp[0 .. elements.length], elements[]);
                    T[] tail = ensureUniqueStorage(extraLen: elements.length);
                    copyElements(tail, tmp[0 .. elements.length]);
                    _length = newLen;
                    return;
                }

                // If a unique heap block must grow while the source aliases it, keep the
                // old block alive until after the tail copy. `ensureUniqueStorage` then
                // takes the shared-clone path instead of reallocating underneath us.
                T[] retainedBlock;
                if (oldLen > N && newLen > _block.length
                    && ctrl().refCount == 1
                    && elements.aliasesRegion(cast(const(T)[]) _block))
                {
                    retainedBlock = _block;
                    ++ctrl().refCount;
                }

                T[] tail = ensureUniqueStorage(extraLen: elements.length);
                copyElements(tail, elements[]);
                _length = newLen;

                if (retainedBlock !is null)
                {
                    if (--Allocator.instance.prefix(retainedBlock).refCount == 0)
                    {
                        removeBlockRange(retainedBlock.ptr);
                        dispose(Allocator.instance, retainedBlock);
                    }
                }
            }
        }

        /// Appends a single element using `~=` operator.
        void opOpAssign(string op : "~")(T element) scope @safe
        {
            put(element);
        }

        /// Appends elements from a slice using `~=` operator.
        void opOpAssign(string op : "~")(in T[] elements) scope @safe
        {
            put(elements);
        }

        /// Output range interface: appends every element of an input range whose
        /// elements are convertible to `T` (a `T[]` uses the bulk slice overload).
        /// Specializes on range capability: a contiguous (sliceable-to-`T[]`) range
        /// becomes one bulk copy, a known-length range pre-sizes to a single
        /// allocation, and any other input range falls back to amortized appends.
        void put(R)(R elements)
        if (isInputRange!R && is(ElementType!R : T) && !is(immutable R == immutable(T)[]))
        {
            static if (hasSlicing!R && is(typeof(elements[]) : const(T)[]))
                put(elements[]);
            else static if (hasLength!R)
            {
                const n = elements.length;
                if (n == 0)
                    return;
                const oldLen = _length;
                const newLen = oldLen + n;

                // `!onHeap`, not `oldLen <= N`: the two agree wherever there is
                // inline storage, but for a heap-only policy the length test
                // reads "empty", which is also what a freshly reserved buffer
                // looks like — and this path allocates a new block without
                // releasing the one already held.
                if (!onHeap && newLen > N)
                {
                    // inline -> heap transition: to prevent range elements that alias
                    // our inline storage from reading corrupted data, we must allocate
                    // the new block, fill it with the inline elements and range elements,
                    // and only then overwrite the union by assigning _block.
                    T[] nb = allocateBlock(roundedCapacity(newLen));
                    copyElements(nb[0 .. oldLen], _inline[0 .. oldLen]);
                    size_t i = oldLen;
                    foreach (e; elements)
                        nb[i++] = e;

                    () @trusted {
                        _block = nb;
                        _length = newLen;
                    }();
                }
                else
                {
                    T[] tail = ensureUniqueStorage(extraLen: n);
                    size_t i;
                    foreach (e; elements)
                        tail[i++] = e;
                    _length = newLen;
                }
            }
            else
                foreach (e; elements)
                    put(e);
        }

        /// Appends every element of an input range using the `~=` operator.
        void opOpAssign(string op : "~", R)(R elements)
        if (isInputRange!R && is(ElementType!R : T) && !is(immutable R == immutable(T)[]))
        {
            put(elements);
        }

        /**
         * Sets the element count. Growing appends `T.init`-filled elements (one
         * storage growth); shrinking drops elements from the back, reverting to
         * inline storage when the new length fits (the `popBack` invariant).
         */
        @property void length(size_t newLength) @trusted
        {
            if (newLength == _length)
                return;
            if (newLength > _length)
            {
                T[] tail = ensureUniqueStorage(extraLen: newLength - _length);
                tail[] = T.init;
                _length = newLength;
                return;
            }
            static if (hasInline)
            {
                if (_length > N && newLength <= N)
                {
                    // Crossing heap -> inline: copy survivors out first to keep the
                    // invariant `length <= N  <=>  inline`.
                    T[] b = _block;
                    T[N] tmp = void;
                    copyElements(tmp[0 .. newLength], b[0 .. newLength]);
                    releaseStorage();
                    copyElements(_inline[0 .. newLength], tmp[0 .. newLength]);
                    _length = newLength;
                    return;
                }
            }
            // A heap-only policy has nothing to revert to: the block stays.
            _length = newLength;
        }

        /// Removes the last element.
        void popBack() @trusted
        in (_length > 0, "Cannot pop from empty buffer")
        {
            static if (hasInline)
            {
                if (_length == N + 1)
                {
                    // Crossing N+1 -> N: data must move back inline to keep the
                    // invariant `length <= N  <=>  inline`. Copy survivors out first.
                    T[] b = _block;
                    T[N] tmp = void;
                    copyElements(tmp[], b[0 .. N]);
                    releaseStorage();
                    copyElements(_inline[0 .. N], tmp[]);
                    _length = N;
                    return;
                }
            }
            // A heap-only policy has nothing to revert to: the block stays.
            --_length;
        }

        /// Removes all elements. With inline storage this releases the heap
        /// block and reverts to inline; a heap-only policy keeps its block
        /// (there is nothing to revert to), so `reserve` once and `clear`
        /// between uses is allocation-free. The destructor releases it.
        void clear() scope @safe
        {
            static if (hasInline)
                releaseStorage();
            _length = 0;
        }

    }

    static if (!hasHeap)
    {
        /**
         * Appends whatever `fn` writes, or nothing at all.
         *
         * The transactional counterpart to the free $(LREF tryWrite): the sink
         * writes into the slots $(I past) `length`, and `length` advances only
         * when everything fit. A buffer's value is `[0 .. length]`, so a write
         * that did not fit leaves the buffer exactly as it was. Returns `false`
         * in that case.
         *
         * This is the only way to write into a policy without `Storage.heap`,
         * which has no `put` because it cannot honour one.
         *
         * Two overloads, as for the free function: this one fixes the
         * delegate's attributes so a capturing callback stays `@nogc`; the
         * deduced one below accepts a callback that is not `@safe` and infers
         * its own safety from it. (`pure nothrow @nogc` are the buffer's own
         * attributes, so a callback must still be all three.)
         */
        bool tryWrite(scope void delegate(scope ref BoundedSink!T)
            @safe pure nothrow @nogc fn) @safe
        {
            auto written = _inline[_length .. N].tryWrite(fn);
            if (written is null)
                return false;
            _length += written.length;
            return true;
        }

        /// ditto
        bool tryWrite(Dg)(scope Dg fn)
        if (!is(Dg : void delegate(scope ref BoundedSink!T) @safe pure nothrow @nogc))
        {
            auto written = _inline[_length .. N].tryWrite(fn);
            if (written is null)
                return false;
            _length += written.length;
            return true;
        }

        /**
         * Replaces the value, or keeps the old one.
         *
         * Returns `false` when `source` does not fit, leaving this buffer
         * untouched — the whole-value counterpart to
         * $(LREF Buffer.tryWrite)'s transactional append. A caller that would
         * rather truncate should slice `source` itself; refusing is the
         * default because a fixed buffer usually holds something whose meaning
         * a silent truncation would change (a UTF-8 sequence, a path).
         */
        bool assign(scope const(T)[] source) scope @safe
        {
            if (source.length > N)
                return false;

            copyElements(_inline[0 .. source.length], source);
            _length = source.length;
            return true;
        }

        /**
         * Removes all elements.
         *
         * There is no storage to release — `N` is the whole capacity — so this
         * is the length reset alone. It is what makes a fixed buffer
         * rewritable: `clear` then $(LREF Buffer.tryWrite) builds a new value
         * in pieces, where $(LREF Buffer.assign) takes one already assembled.
         */
        void clear() scope @safe
        {
            _length = 0;
        }
    }

    /**
     * Content equality: the elements, not the storage.
     *
     * Compares `this[]` against `rhs[]`, so a buffer holding its elements
     * inline equals one holding the same elements on the heap, and capacity
     * beyond `length` — which may be uninitialised — never participates.
     */
    bool opEquals(size_t OtherN, Storage OtherStorage)(
        auto ref const Buffer!(T, OtherN, OtherStorage) rhs) const @safe
        => this[] == rhs[];

    /// ditto
    bool opEquals(scope const(T)[] rhs) const @safe => this[] == rhs;

    /**
     * Ensures the buffer has at least `newCapacity` slots.
     *
     * With inline storage, location is tied to length — data is inline whenever
     * `length <= N` — so `reserve` can only pre-grow a buffer that is
     * $(I already) on the heap; on an inline (including empty) buffer it is a
     * no-op, and the next inline→heap transition allocates from scratch.
     *
     * For a heap-only policy this is how the buffer is sized before use: there
     * is no `N` to raise, and the block persists across `popBack`, `length` and
     * `clear` until the destructor, so one `reserve` serves every reuse.
     *
     * Without `Storage.heap` there is nowhere to grow to, and this is a no-op.
     */
    void reserve(size_t newCapacity) @safe
    {
        static if (!hasHeap)
            return; // nowhere to grow to; `N` is the whole capacity
        else
        {
            if (newCapacity <= capacity)
                return; // already large enough — don't clone a shared block needlessly
            // Deliberately reached while still inline: a `HeapBuffer` has no `N`
            // to raise, so this is the only way to size one before use.
            ensureUniqueStorage(minCapacity: newCapacity);
        }
    }

    static if (!unique)
    {
        /**
         * Returns a `const`, storage-sharing handle to this buffer — the
         * producer-builds-then-many-readers handoff. Reading through the result (or
         * its copies) never clones, since nothing can mutate through `const`.
         *
         * Like Rust's `Borrow`, this is the read side of the copy-on-write type — but
         * unlike a Rust borrow it is an $(I owner): it bumps the reference count and
         * keeps the heap block alive independently of the source (closer to
         * `Rc::clone` than a lifetime-bound `&`). `const x = buf;` is equivalent;
         * `borrow` simply names the handoff and works in expression position.
         *
         * See_Also: $(LREF Buffer.toOwned) for the inverse (an independent,
         * uniquely-owned mutable copy).
         */
        const(Buffer) borrow() const @safe => this;

        /**
         * Returns an independent, uniquely-owned mutable copy, eagerly detached from
         * any shared block (Rust's `ToOwned`/`Cow::into_owned`). The result shares
         * with no one — its reference count is 1 — so later mutations never pay a
         * copy-on-write clone, and it is unaffected by writes to the source.
         *
         * Plain copy construction (`auto b = a;`) is the lazy counterpart: it shares
         * a heap block and clones only on the first write. `toOwned` forces that
         * clone up front.
         */
        Buffer toOwned() const @safe
        {
            Buffer copy = this; // shares (heap) or copies (inline)
            static if (hasHeap)
                copy.ensureUniqueStorage(); // force a private block if shared
            return copy;
        }
    }
    else
    {
        /**
         * Consumes this `unique` buffer and returns an equivalent copy-on-write
         * `SharedBuffer!(T, N)` that can be shared/borrowed. This is the bridge from
         * the refcount-free build phase to the many-readers handoff: build mutably
         * under `unique` (no per-append uniqueness checks), then `toShared` once and
         * hand out `const` copies.
         *
         * The heap block transfers directly — no reallocation and no element copy —
         * because both instantiations share the same affix layout; an inline buffer
         * copies its (small) inline elements. Afterwards this buffer is left empty
         * (it no longer owns the storage).
         *
         * See_Also: $(LREF Buffer.toOwned) / $(LREF Buffer.borrow) on the
         * returned copy-on-write buffer.
         */
        Shared toShared() @trusted
        {
            Shared result;
            result._length = _length;
            static if (hasHeap)
            {
                if (onHeap)
                {
                    result._block = _block; // transfer ownership (refCount already 1)
                    _block = null; // relinquish: our destructor must not free the block
                    _length = 0;
                    return result;
                }
            }
            // Inline elements are copied; there is no block to hand over.
            copyElements(result._inline[0 .. _length], _inline[0 .. _length]);
            _length = 0;
            return result;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // private helpers
    // ─────────────────────────────────────────────────────────────────────────

    static if (hasHeap)
    {
    // Allocate a heap block for `blockCapacity` elements (refCount 1).
    private static T[] allocateBlock(size_t blockCapacity) @trusted
    {
        T[] b = makeArray!T(Allocator.instance, blockCapacity);
        assert(b !is null, "Buffer: allocation failed");
        Allocator.instance.prefix(b).refCount = 1;
        addBlockRange(b);
        return b;
    }

        // Grow the heap block to `capacity` slots, keeping the GC root in step.
        //
        // `expandArray` falls through to `reallocate` here (the affix allocator over
        // `Mallocator` has no `expand`), so the block may MOVE — and its length
        // changes even when it does not.
        //
        // For a `T` with indirections that is not acceptable: `realloc` moves the
        // elements into memory the collector does not scan and frees the old block
        // before the new one could be registered, and any thread's allocation can
        // turn that window into a collection — the strings a buffer holds vanish
        // under it. So that case allocates (and registers) the new block first,
        // copies, and only then drops the old root and frees the old block. A
        // pointer-free `T` has no root to keep and reallocates in place.
        private void reallocateBlock(size_t capacity) scope @safe
        {
            static if (hasIndirections!T)
            {
                T[] nb = allocateBlock(capacity);
                () @trusted {
                    copyElements(nb[0 .. _length], _block[0 .. _length]);
                    removeBlockRange(_block.ptr);
                    dispose(Allocator.instance, _block);
                    _block = nb;
                }();
            }
            else
            {
                const ok = (() @trusted =>
                    Allocator.instance.expandArray(
                        _block, capacity - _block.length
                    )
                )();
                if (!ok)
                    assert(false, "Buffer: reallocation failed");
            }
        }

        /*
        Register a heap block as a GC root, for a `T` that carries references.

        The block comes from `Mallocator`, which the collector does not scan. An
        element holding the $(I only) reference to GC memory would therefore let
        that memory be collected while the buffer still points at it — so without
        this, `SharedBuffer!(T, N)` is simply unsafe for any `T` with indirections,
        which is why `DrawOp` streams have had to use a GC array.

        `GC.addRange`/`removeRange` are `nothrow @nogc` but not `pure`, and this
        struct's methods are. Casting the purity in is sound for the same reason
        druntime does it for `pureMalloc`: registering a root changes only whether
        the collector may reclaim memory, which no pure computation can observe.

        Registration is per $(I block), not per owner: a shared block is registered
        once by whoever allocated it and unregistered once by whoever disposes it,
        so reference counting needs no help here. A block moved between owners
        (`toShared`) keeps its registration, since the address does not change.
        */
        private static void addBlockRange(scope T[] b) @trusted
        {
            static if (hasIndirections!T)
                if (b.length)
                    pureGcAddRange(b.ptr, b.length * T.sizeof, null);
        }

        /// ditto
        private static void removeBlockRange(const(void)* p) @trusted
        {
            static if (hasIndirections!T)
                if (p !is null)
                    pureGcRemoveRange(p);
        }

        // Ensure this buffer has unique mutable storage with room for `extraLen`
        // additional elements (and at least `minCapacity` total slots). `_length`
        // is deliberately unchanged; callers fill the returned tail and then commit.
        // `return`: the returned tail may alias `this` (the inline small-buffer), so
        // the mutable `opSlice`/`opIndex` that call it stay valid on a `scope this`
        // (e.g. a container exposing `return scope` views — see the regression test).
        private T[] ensureUniqueStorage(size_t extraLen = 0, size_t minCapacity = 0) return scope @safe
        {
            const oldLen = _length;
            const newLen = oldLen + extraLen;

            static if (hasInline)
            {
                if (newLen <= N)
                    return (() @trusted => _inline[oldLen .. newLen])();
            }
            else
            {
                // `N` is 0, so the test above would swallow every call — and a
                // policy with no inline storage has nothing to fit into. With a
                // block already held, fall through even for a zero-length
                // request: a shared block still has to be cloned (`toOwned`).
                if (newLen == 0 && minCapacity == 0 && !onHeap)
                    return null;
            }

            const needed = max(newLen, minCapacity);
            const capacity = roundedCapacity(needed);

            static if (unique)
            {
                // Sole owner by construction — no reference count to read, never a
                // clone.
                if (!onHeap)
                {
                    // inline -> heap: allocate a fresh block and move the inline
                    // elements into it before the union is repurposed as `_block`.
                    T[] nb = allocateBlock(capacity);
                    () @trusted {
                        copyElements(nb[0 .. oldLen], _inline[0 .. oldLen]);
                        _block = nb;
                    }();
                    return nb[oldLen .. newLen];
                }
                // Already on the heap: grow in place when too small.
                if (needed > this.capacity)
                {
                    reallocateBlock(capacity);
                }
                return (() @trusted => _block[oldLen .. newLen])();
            }
            else
            {
                const rc = this.refCount;
                if (rc == 1)
                {
                    if (needed > this.capacity)
                    {
                        reallocateBlock(capacity);
                    }
                    return (() @trusted => _block[oldLen .. newLen])();
                }

                T[] oldBlock = this.view;
                T[] newBlock = allocateBlock(max(this.capacity, capacity));
                copyElements(newBlock[0 .. oldLen], oldBlock[]);
                () @trusted {
                    if (rc > 1) --ctrl().refCount;
                    _block = newBlock;
                }();
                return newBlock[oldLen .. newLen];
            }
        }

        // Drop this owner's heap reference. If refCount hits 0, destroy and free the
        // block. Nulls `_block` so no dangling/aliased pointer survives in the union
        // (callers reset `_length` and/or reassign `_block` afterwards).
        private void releaseStorage() @trusted
        {
            if (!onHeap)
                return;
            static if (unique)
            {
                removeBlockRange(_block.ptr); // before the memory goes back
                dispose(Allocator.instance, _block); // sole owner: free outright
            }
            else if (--ctrl().refCount == 0)
            {
                removeBlockRange(_block.ptr);
                dispose(Allocator.instance, _block);
            }
            _block = null;
        }
    }
}

///
// ─────────────────────────────────────────────────────────────────────────────
// Reference-bearing elements
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    // An element type with an indirection — the case the buffer could not hold
    // safely before: the heap block is not GC-scanned, and the inline slots were
    // `void`-initialized.
    private struct Payload
    {
        string text;
        int tag;
    }
}

@("Buffer.indirections.inlineSlotsAreInitialized")
@safe pure nothrow @nogc
unittest
{
    // Untouched inline slots must read as `T.init`, not as whatever the stack
    // held. A garbage `string` here is a pointer the conservative collector
    // would follow.
    Buffer!(Payload, 4) buf;
    buf ~= Payload("one", 1);
    assert(buf.length == 1);
    assert(buf[0] == Payload("one", 1));

    // Growing into a slot that was never written yields an initialized element.
    buf.length = 3;
    assert(buf[1] == Payload.init && buf[2] == Payload.init);
}

@("Buffer.indirections.stillNogc")
@safe pure nothrow @nogc
unittest
{
    // Rooting the block must not cost the buffer its attributes: `GC.addRange`
    // is `nothrow @nogc`, and the purity cast is what keeps this instantiation
    // usable from `pure` code at all.
    Buffer!(Payload, 2) buf;
    foreach (i; 0 .. 16)
        buf ~= Payload("x", i);
    assert(buf.onHeap && buf.length == 16);
    assert(buf[15].tag == 15);
}

@("Buffer.indirections.heapElementsSurviveCollection")
@system
unittest
{
    import core.memory : GC;
    import std.conv : text;

    enum count = 64;

    Buffer!(Payload, 2) buf;
    foreach (i; 0 .. count)
        buf ~= Payload(text("payload-", i), i); // freshly GC-allocated each time
    assert(buf.onHeap, "the test is about the heap block, not the inline slots");

    // The buffer now holds the only references to those strings. Without the
    // block registered as a root the collector cannot see them, and the memory
    // is free to be handed out again.
    GC.collect();

    // Churn the heap so anything actually reclaimed is overwritten rather than
    // merely dangling — a dangling pointer to intact memory would still compare
    // equal and let the bug pass unnoticed.
    string[] churn;
    foreach (i; 0 .. 4096)
        churn ~= text("churn-", i);
    assert(churn.length == 4096);

    foreach (i; 0 .. count)
    {
        assert(buf[i].tag == i);
        assert(buf[i].text == text("payload-", i),
            "element text was collected or overwritten");
    }
}

@("Buffer.indirections.survivesCopyOnWriteAndTransfer")
@system
unittest
{
    import core.memory : GC;
    import std.conv : text;

    Buffer!(Payload, 2) a;
    foreach (i; 0 .. 32)
        a ~= Payload(text("a-", i), i);

    // A copy shares the block; writing through it clones, and the clone is a
    // separate allocation that needs its own root.
    auto b = a;
    b ~= Payload(text("b-", 0), 99);
    assert(a.length == 32 && b.length == 33);

    // A `unique` buffer's block transfers to the shared world without
    // reallocating, so its registration must travel with it — registered once
    // by the allocation, dropped once by whoever disposes it.
    UniqueBuffer!(Payload, 2) u;
    foreach (i; 0 .. 32)
        u ~= Payload(text("u-", i), i);
    auto shared_ = u.toShared();

    GC.collect();

    foreach (i; 0 .. 32)
    {
        assert(a[i].text == text("a-", i));
        assert(b[i].text == text("a-", i));
        assert(shared_[i].text == text("u-", i));
    }
    assert(b[32].text == "b-0");
}

@("Buffer.indirections.pointerFreeLayoutUnchanged")
@safe pure nothrow @nogc
unittest
{
    // The cost is paid only where it buys something: an element type without
    // indirections keeps the `void`-initialized inline storage and the
    // three-word layout the default `N` is chosen for.
    static assert(!hasIndirections!char && !hasIndirections!int);
    static assert(Buffer!char.sizeof == 3 * size_t.sizeof);
    static assert(Buffer!int.sizeof == 3 * size_t.sizeof);
    static assert(Buffer!long.sizeof == 3 * size_t.sizeof);

    Buffer!(char, 16) buf;
    buf ~= "unchanged";
    assert(buf[] == "unchanged");
}

@("Buffer.tour")
@safe pure nothrow @nogc
unittest
{
    // A `Buffer` starts empty and inline — no heap allocation yet.
    Buffer!(int, 4) buf;
    assert(buf.empty && !buf.onHeap && buf.capacity == 4);

    // Append single elements or slices; it is also an output range (`put`).
    buf ~= 1;
    buf ~= [2, 3];
    buf.put(4);
    assert(buf[] == [1, 2, 3, 4] && !buf.onHeap);

    // Overflowing the inline capacity transparently moves to the heap.
    buf ~= 5;
    assert(buf.onHeap && buf.capacity >= 5);

    // Index, sub-slice, front/back, and `$`.
    assert(buf[0] == 1 && buf[$ - 1] == 5);
    assert(buf[1 .. 3] == [2, 3]);
    assert(buf.front == 1 && buf.back == 5);

    // popBack/clear shrink it; dropping back to <= N reverts to inline storage.
    buf.popBack();
    assert(buf[] == [1, 2, 3, 4] && !buf.onHeap);
    buf.clear();
    assert(buf.empty);

    // ── Copy-on-write ────────────────────────────────────────────────────────
    Buffer!(int, 2) a;
    a ~= iota(5);            // [0, 1, 2, 3, 4], now on the heap
    assert(a.refCount == 1);         // sole owner

    // `borrow()` hands out a const, storage-sharing reader: no element copy,
    // just a bumped reference count. Reading through `const` never clones.
    const reader = a.borrow;
    assert(a.refCount == 2);         // `a` and `reader` share one block
    assert(reader[] == [0, 1, 2, 3, 4] && a.refCount == 2);

    // A *mutable* copy shares too — the clone is deferred to the first write.
    auto b = a;
    assert(a.refCount == 3);         // a, reader, b
    b ~= 5;                          // copy-on-write: b detaches here
    assert(b[] == [0, 1, 2, 3, 4, 5]);          // b is independent
    assert(reader[] == [0, 1, 2, 3, 4]);        // original intact (const read)
    assert(a.refCount == 2);         // a and reader still share it

    // Nuance: the *mutable* accessors clone even when you only read — overload
    // resolution cannot tell a read from a write. A mutable read of the shared
    // `a` detaches it from `reader`; reach through `const`/`borrow` to avoid it.
    auto s = a[];                    // mutable opSlice → clones, just from a read
    assert(s == [0, 1, 2, 3, 4] && a.refCount == 1);   // `a` now owns its block

    // `toOwned()` eagerly detaches: an independent, uniquely-owned copy sharing
    // with nobody, so its later writes never pay a copy-on-write clone.
    auto owned = reader.toOwned();
    assert(owned.refCount == 1);     // detached up front
    owned ~= 9;                      // already unique → no clone
    assert(owned[] == [0, 1, 2, 3, 4, 9]);
    assert(reader[] == [0, 1, 2, 3, 4]);        // reader untouched
}

/**
Checks an output-range `toString` implementation against expected text.

This helper is intended for unit tests of types that expose
`void toString(Writer)(ref Writer w)`. It renders into a $(LREF Buffer)
so passing tests can run without GC allocation.

Params:
    value    = Value whose `toString` overload is tested.
    expected = Expected rendered text.
    file     = Source file for assertion reporting.
    line     = Source line for assertion reporting.

Throws: `AssertError` if the rendered text does not match `expected`.
*/
void checkToString(T, size_t outputBufferSize = 1024, size_t errorBufferSize = 1024)(
    auto ref T value,
    const(char)[] expected,
    string file = __FILE__,
    size_t line = __LINE__,
)
{
    Buffer!(char, outputBufferSize) buf;
    value.toString(buf);
    assertRendered!errorBufferSize("toString mismatch", buf[], expected, file, line);
}

/// Like $(LREF checkToString), but for a free writer expression rather than
/// a `toString` method. `render` is a callable taking
/// `ref Buffer!(char, outputBufferSize)`; its output is compared to
/// `expected` with the same recycled-`AssertError` diff on mismatch (so the
/// caller stays `@safe pure nothrow @nogc`):
/// ---
/// checkWriter!((ref b) => writeIntegerPadded(b, 7, 3))("007");
/// ---
void checkWriter(alias render, size_t outputBufferSize = 1024,
    size_t errorBufferSize = 1024)(
    const(char)[] expected,
    string file = __FILE__,
    size_t line = __LINE__,
)
{
    Buffer!(char, outputBufferSize) buf;
    render(buf);
    assertRendered!errorBufferSize("rendered output mismatch", buf[], expected, file, line);
}

/**
Compares rendered bytes against expected text and fails with a readable diff.

The comparison helper behind $(LREF checkToString) and $(LREF checkWriter), and
usable directly whenever a test already has the rendered bytes in hand — a
grid painted into a cell buffer, a frame captured from a recording backend —
and only wants the diff-on-mismatch reporting:
---
assertRendered("frame mismatch", frame.text, expectedFrame);
---
Rendering into a $(LREF Buffer) is what keeps a passing test
`@safe pure nothrow @nogc`; the failure path allocates nothing either, so the
attribute set survives into the assertion.

$(B Failure mode follows the build.) With exceptions available this throws a
recycled `AssertError` carrying the diff, attributed to `file`/`line`. Under
`-betterC` (`version (D_Exceptions)` is off) `throw` is illegal, so the same
message goes through `assert(false, …)` — which the test runner compiles with
`-checkaction=C`, so it reaches C's `assert` and aborts. C's `assert` prints
its own call site rather than `file`/`line`, so those are folded into the
message text instead.

Params:
    errorBufferSize = Inline capacity, in `char`s, of the diff buffer. A
        message longer than this spills to the heap rather than truncating.
    header   = Short label for what mismatched, e.g. `"toString mismatch"`.
    actual   = The rendered bytes.
    expected = The bytes `actual` should equal.
    file     = Source file for assertion reporting.
    line     = Source line for assertion reporting.

Throws: `AssertError` if `actual` differs from `expected`. Under `-betterC`,
        aborts through C's `assert` instead.

See_Also: $(LREF checkToString), $(LREF checkWriter)
*/
void assertRendered(size_t errorBufferSize = 1024)(
    const(char)[] header,
    const(char)[] actual,
    const(char)[] expected,
    string file = __FILE__,
    size_t line = __LINE__,
)
{
    if (actual == expected)
        return;

    Buffer!(char, errorBufferSize) errBuf;

    version (D_Exceptions) {}
    else
    {
        // C's `assert` reports the `assert(false, …)` site — this module —
        // rather than the caller, so carry the caller's location in the text.
        import sparkles.base.text.writers : writeInteger;

        errBuf.put(file);
        errBuf.put(':');
        writeInteger(errBuf, line);
        errBuf.put(": ");
    }

    errBuf.put(header);
    errBuf.put(":\nExpected:\n");
    errBuf.put(expected);
    errBuf.put("\nActual:\n");
    errBuf.put(actual);

    version (D_Exceptions)
    {
        import core.exception : AssertError;
        import sparkles.base.lifetime : recycledErrorInstance;

        // @trusted only here: recycledErrorInstance is @system (it parks the
        // Error object in a static buffer).
        () @trusted {
            throw recycledErrorInstance!AssertError(errBuf[], file, line);
        }();
    }
    else
    {
        // C's `assert` takes a `const char*`, so the message must carry its own
        // terminator — a bare slice leaves the C library reading whatever
        // follows the buffer into its diagnostic.
        errBuf.put('\0');
        assert(false, errBuf[]);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit Tests
// ─────────────────────────────────────────────────────────────────────────────

@("Buffer.basic.creation")
@safe pure nothrow @nogc
unittest
{
    // By default, N fills the slice-sized union exactly, so the struct stays
    // three words wide for any T (16 chars / 4 ints / 2 longs inline).
    {
        static assert(Buffer!char.sizeof == 3 * size_t.sizeof);
        static assert(Buffer!int.sizeof == 3 * size_t.sizeof);
        static assert(Buffer!long.sizeof == 3 * size_t.sizeof);
        Buffer!int buf;
        assert(buf.length == 0);
        assert(buf.empty);
        assert(buf.capacity == (ubyte[]).sizeof / int.sizeof); // 4 on x86_64
        assert(!buf.onHeap);
    }

    {
        Buffer!(int, 4) buf;
        assert(buf.length == 0);
        assert(buf.empty);
        assert(buf.capacity == 4);
        assert(!buf.onHeap);
    }
}

@("checkToString.outputRangeToString")
@safe pure nothrow @nogc
unittest
{
    struct Example
    {
        int value;

        void toString(Writer)(ref Writer w) const
        {
            w.put("Example(");
            if (value == 42)
                w.put("42");
            else
                w.put("?");
            w.put(")");
        }
    }

    checkToString(Example(42), "Example(42)");
}

@("checkToString.mismatchMessage")
@system
unittest
{
    import core.exception : AssertError;
    import std.exception : assertThrown, collectException;

    struct Example
    {
        void toString(Writer)(ref Writer w) const
        {
            w.put("actual");
        }
    }

    assertThrown!AssertError(checkToString(Example(), "expected"));

    auto error = collectException!AssertError(
        checkToString(Example(), "expected")
    );
    assert(error !is null);
    assert(error.msg == "toString mismatch:\nExpected:\nexpected\nActual:\nactual");
}

@("checkWriter.rendersLambda")
@safe pure nothrow @nogc
unittest
{
    checkWriter!((ref b) => b.put("hi"))("hi");
}

@("assertRendered.matchingBytesPass")
@safe pure nothrow @nogc
unittest
{
    // The direct entry point, for a test that already holds rendered bytes.
    assertRendered("frame mismatch", "abc", "abc");
}

@("assertRendered.mismatchMessage")
@system
unittest
{
    import core.exception : AssertError;
    import std.exception : collectException;

    auto error = collectException!AssertError(
        assertRendered("frame mismatch", "actual", "expected")
    );
    assert(error !is null);
    assert(error.msg == "frame mismatch:\nExpected:\nexpected\nActual:\nactual");
}

@("buffer.helpers.betterC")
@betterC
@safe pure nothrow @nogc
unittest
{
    // The helpers must survive a druntime-free build: `assertRendered`'s
    // failure path is a `throw` where exceptions exist and a C `assert`
    // where they don't, and this test is what keeps the second arm compiling.
    struct Example
    {
        void toString(Writer)(ref Writer w) const
        {
            w.put("Example(ok)");
        }
    }

    checkToString(Example(), "Example(ok)");
    checkWriter!((ref b) => b.put("hi"))("hi");
    assertRendered("frame mismatch", "abc", "abc");
}

@("Buffer.betterC")
@betterC
@safe pure nothrow @nogc
unittest
{
    // The container itself, across the inline -> heap transition, without
    // druntime: the heap block comes from `Mallocator`, not the GC.
    Buffer!(char, 8) buf;
    buf ~= "hello";
    buf ~= ' ';
    buf ~= "world";
    assert(buf.onHeap && buf[] == "hello world");

    buf.clear();
    assert(buf.empty && !buf.onHeap);
}

@("Buffer.put.append")
@safe pure nothrow @nogc
unittest
{
    Buffer!(int, 4) buf;

    // Single element put
    buf.put(42);
    assert(buf.length == 1);
    assert(buf[0] == 42);
    assert(!buf.onHeap);

    // Multiple element put
    buf.put([1, 2]);
    assert(buf.length == 3);
    assert(buf[] == [42, 1, 2]);
    assert(!buf.onHeap);

    // Append operator
    buf ~= 100;
    assert(buf.length == 4);
    assert(buf.capacity == 4);
    assert(buf[] == [42, 1, 2, 100]);
    assert(!buf.onHeap);

    // This will trigger heap allocation
    buf ~= 200;
    assert(buf.length == 5);
    assert(buf[] == [42, 1, 2, 100, 200]);
    assert(buf.onHeap);

    buf ~= [300, 400];
    assert(buf.length == 7);
    assert(buf[] == [42, 1, 2, 100, 200, 300, 400]);
    assert(buf.onHeap);
}

@("Buffer.indexingAndSlicing")
@safe pure nothrow @nogc
unittest
{
    Buffer!(int, 4) buf;

    // Empty slicing
    assert(buf[].length == 0);
    assert(buf[0 .. 0].length == 0);

    buf ~= [1, 2, 3, 4];

    // Full & partial slices
    assert(buf[] == [1, 2, 3, 4]);
    assert(buf[1 .. 3] == [2, 3]);
    assert(buf[0 .. $] == [1, 2, 3, 4]);
    assert(buf[$ - 2 .. $] == [3, 4]);

    // Index access & Dollar
    assert(buf[0] == 1);
    assert(buf[1] == 2);
    assert(buf[2] == 3);
    assert(buf[$ - 1] == 4);
    assert(buf.opDollar() == 4);

    // Modify through index
    buf[1] = 20;
    assert(buf[1] == 20);

    // Modify through slice
    buf[][2] = 30;
    assert(buf[2] == 30);
    assert(buf[] == [1, 20, 30, 4]);

    // Const access
    void checkConst(ref const Buffer!(int, 4) cbuf)
    {
        assert(cbuf[0] == 1);
        assert(cbuf.length == 4);
        assert(cbuf[] == [1, 20, 30, 4]);
    }
    checkConst(buf);
}

@("Buffer.clear")
@safe pure nothrow @nogc
unittest
{
    Buffer!(int, 4) buf;

    // Clear inline
    buf ~= [1, 2];
    assert(buf.length == 2);
    buf.clear();
    assert(buf.length == 0);
    assert(buf.empty);
    assert(!buf.onHeap);
    assert(buf.capacity == 4);

    // Reuse after clear inline
    buf ~= [10, 20];
    assert(buf.length == 2);
    assert(buf[] == [10, 20]);

    // Transition to heap
    buf ~= [30, 40, 50];
    assert(buf.onHeap);

    // Clear reverts to inline (invariant check)
    buf.clear();
    assert(buf.length == 0);
    assert(buf.empty);
    assert(!buf.onHeap);

    // Reuse after clear heap
    buf ~= 7;
    assert(buf[] == [7]);
    assert(!buf.onHeap);
}

@("Buffer.clear.noDanglingReuse")
@safe pure nothrow @nogc
unittest
{
    // After clearing a heap buffer, `_block` must not survive as a dangling
    // pointer: re-growing back onto the heap must allocate cleanly.
    Buffer!(int, 2) buf;
    buf ~= iota(6);          // heap
    assert(buf.onHeap);

    buf.clear();
    assert(buf.length == 0 && !buf.onHeap);

    buf ~= iota(10, 16);             // re-grow onto a fresh heap block
    assert(buf.onHeap);
    assert(buf[] == [10, 11, 12, 13, 14, 15]);
}

@("Buffer.length.setter")
@safe pure nothrow @nogc
unittest
{
    // Grow-with-default, inline and across the inline -> heap boundary.
    Buffer!(int, 4) buf;
    buf ~= 7;
    buf.length = 3;
    assert(buf.length == 3);
    assert(!buf.onHeap);
    assert(buf[0] == 7 && buf[1] == 0 && buf[2] == 0);

    buf.length = 6; // crosses onto the heap
    assert(buf.length == 6);
    assert(buf.onHeap);
    assert(buf[0] == 7 && buf[5] == 0);

    // Shrink on the heap, then across heap -> inline (content preserved).
    buf[1] = 42;
    buf.length = 5;
    assert(buf.onHeap && buf.length == 5);
    buf.length = 2;
    assert(!buf.onHeap);
    assert(buf.length == 2);
    assert(buf[0] == 7 && buf[1] == 42);

    // No-op and shrink-to-empty.
    buf.length = 2;
    assert(buf.length == 2);
    buf.length = 0;
    assert(buf.empty);
}

@("Buffer.reserve")
@safe pure nothrow @nogc
unittest
{
    // Reserve is a no-op when inline (storage location tied to length)
    {
        Buffer!(int, 4) buf;
        buf.reserve(100);
        assert(buf.capacity == 4);
        assert(!buf.onHeap);
        assert(buf.length == 0);
    }
    {
        Buffer!(int, 8) buf;
        buf.reserve(4); // Less than N
        assert(buf.capacity == 8);
        assert(!buf.onHeap);
    }
    {
        Buffer!(int, 4) buf;
        buf ~= [1, 2];
        buf.reserve(8);
        assert(!buf.onHeap);
        assert(buf.capacity == 4);
        assert(buf[] == [1, 2]);
    }

    // Reserve grows when already on heap
    {
        Buffer!(int, 4) buf;
        buf ~= iota(5);          // heap
        assert(buf.onHeap);
        buf.reserve(100);
        assert(buf.capacity >= 100);
        assert(buf.length == 5);
        assert(buf[] == [0, 1, 2, 3, 4]);
    }
}

@("Buffer.frontBack")
@safe pure nothrow @nogc
unittest
{
    Buffer!(int, 4) buf;
    buf ~= 1;
    buf ~= 2;
    buf ~= 3;
    assert(buf.front == 1);
    assert(buf.back == 3);
}

@("Buffer.popBack")
@safe pure nothrow @nogc
unittest
{
    Buffer!(int, 4) buf;
    buf ~= [1, 2, 3];

    // Single popBack
    buf.popBack();
    assert(buf.length == 2);
    assert(buf.back == 2);

    // Multiple popBack
    buf.popBack();
    assert(buf.length == 1);
    assert(buf[0] == 1);

    // Revert to inline from heap
    buf.clear();
    buf ~= iota(5); // length 5 > 4 -> heap
    assert(buf.onHeap);

    buf.popBack(); // 5 -> 4: must revert to inline
    assert(!buf.onHeap);
    assert(buf.length == 4);
    assert(buf[] == [0, 1, 2, 3]);
}

@("Buffer.withStructType")
@safe pure nothrow @nogc
unittest
{
    struct Point { int x, y; }
    Buffer!(Point, 2) buf;
    buf ~= Point(1, 2);
    buf ~= Point(3, 4);
    assert(buf[0].x == 1);
    assert(buf[1].y == 4);
}

@("Buffer.exactCapacityBoundary")
@safe pure nothrow @nogc
unittest
{
    Buffer!(int, 4) buf;
    // Fill exactly to capacity
    buf ~= 1;
    buf ~= 2;
    buf ~= 3;
    buf ~= 4;
    assert(buf.length == 4);
    assert(!buf.onHeap);

    // One more triggers growth
    buf ~= 5;
    assert(buf.length == 5);
    assert(buf.onHeap);
    assert(buf.capacity >= 8); // Doubled
}



@("Buffer.outputRangeCompatibility")
unittest
{
    import std.range : isOutputRange;
    static assert(isOutputRange!(Buffer!(int, 4), int));
    static assert(isOutputRange!(Buffer!(char, 16), char));
}



@("Buffer.largeGrowth")
@safe pure nothrow @nogc
unittest
{
    Buffer!(int, 2) buf;
    // Add many elements to trigger multiple reallocations
    buf ~= iota(100);

    assert(buf.length == 100);
    foreach (i; 0 .. 100)
        assert(buf[i] == i);
}

@("Buffer.putSlice")
@safe pure nothrow @nogc
unittest
{
    Buffer!(int, 8) buf;
    int[4] arr = [1, 2, 3, 4];
    buf.put(arr[]);
    assert(buf.length == 4);
    assert(buf[] == arr[]);
}

@("Buffer.appendSlice")
@safe pure nothrow @nogc
unittest
{
    Buffer!(int, 8) buf;
    buf ~= 0;
    int[3] arr = [1, 2, 3];
    buf ~= arr[];
    assert(buf.length == 4);
    assert(buf[] == [0, 1, 2, 3]);
}

@("Buffer.appendInputRange")
@safe pure nothrow @nogc
unittest
{
    import std.algorithm.iteration : filter, map;

    // Any input range of convertible elements appends, via `put` or `~=`.
    Buffer!(int, 2) buf;
    buf.put(iota(3));                 // [0, 1, 2], spills to heap
    buf ~= iota(3, 6);               // [0, 1, 2, 3, 4, 5]
    assert(buf[] == [0, 1, 2, 3, 4, 5]);

    // Lazy pipelines work too — no intermediate allocation.
    Buffer!(int, 8) evens;
    evens ~= iota(10).filter!(x => x % 2 == 0);
    assert(evens[] == [0, 2, 4, 6, 8]);

    // Element type need only be convertible to T.
    Buffer!(long, 2) longs;
    longs ~= iota(4).map!(x => cast(long) x);
    assert(longs[] == [0L, 1, 2, 3]);
}

@("Buffer.appendInputRange.specialization")
@safe pure nothrow @nogc
unittest
{
    // hasLength path: a large known-length range goes inline -> heap in a single
    // fill (no per-element reallocation).
    Buffer!(int, 4) big;
    big ~= iota(50);
    assert(big.length == 50);
    foreach (i; 0 .. 50)
        assert(big[i] == i);

    // Contiguous path: a range that is hasSlicing and slices to a T[] is bulk
    // copied through the slice put overload rather than appended element by element.
    static struct Contig
    {
        int[] d;
        @property bool empty() const => d.length == 0;
        @property int front() const => d[0];
        void popFront() { d = d[1 .. $]; }
        Contig save() => Contig(d);          // forward range (hasSlicing needs this)
        @property size_t length() const => d.length;
        alias opDollar = length;
        const(int)[] opSlice() const => d;                  // r[] → bulk-copy slice
        Contig opSlice(size_t a, size_t b) => Contig(d[a .. b]); // r[a..b] → subrange
    }
    static assert(hasSlicing!Contig && is(typeof(Contig.init[]) : const(int)[]));

    Buffer!(int, 2) c;
    int[4] backing = [7, 8, 9, 10];
    c ~= Contig(backing[]);
    assert(c[] == [7, 8, 9, 10]);
}



@("Buffer.charBuffer")
@safe pure nothrow @nogc
unittest
{
    Buffer!(char, 8) buf;
    buf ~= 'H';
    buf ~= 'i';
    assert(buf[] == "Hi");

    buf.put("!!");
    assert(buf[] == "Hi!!");
}

@("Buffer.emptyPutSlice")
@safe pure nothrow @nogc
unittest
{
    Buffer!(int, 4) buf;
    buf ~= 1;
    int[] empty;
    buf.put(empty);
    assert(buf.length == 1);
    assert(buf[0] == 1);
}

/// Appending is usable at compile time: the alias guard the append paths run
/// before an inline->heap transition must not reach for `std.array.overlap`,
/// whose pointer *ordering* CTFE rejects outright (see `aliasesRegion`). This
/// pins the inline case — a CTFE `enum` forces evaluation through the
/// interpreter, so a regression is a compile error, not a failed assert.
@("Buffer.ctfeAppend")
@safe pure nothrow @nogc
unittest
{
    static char[8] render()
    {
        char[8] out_ = 0;
        Buffer!(char, 16) buf;
        buf ~= "ab";
        buf.put("cd");
        out_[0 .. buf.length] = buf[];
        return out_;
    }

    enum ctfe = render();          // evaluated by the CTFE interpreter
    assert(ctfe[0 .. 4] == "abcd");
    assert(ctfe == render());      // and the runtime path agrees
}

@("Buffer.capacity.powerOfTwoGrowth")
@safe pure nothrow @nogc
unittest
{
    Buffer!(int, 2) buf;
    buf ~= [0, 1];
    assert(buf.capacity == 2);

    buf ~= 2;
    assert(buf.onHeap && buf.capacity == 4);

    buf ~= 3;
    assert(buf.capacity == 4);

    buf ~= 4;
    assert(buf.capacity == 8);

    Buffer!(int, 2) bulk;
    bulk ~= iota(9);
    assert(bulk.capacity == 16);
}

@("Buffer.selfAppend.inlineToHeap")
@safe pure nothrow @nogc
unittest
{
    Buffer!(int, 4) buf;
    buf ~= [0, 1, 2];

    buf ~= buf[];
    assert(buf.onHeap);
    assert(buf[] == [0, 1, 2, 0, 1, 2]);
}

@("Buffer.selfAppend.heapGrow")
@safe pure nothrow @nogc
unittest
{
    // Appending a buffer's own slice to itself must survive the reallocation
    // that the append triggers (the source aliases the block being grown).
    Buffer!(int, 2) buf;
    buf ~= iota(5);          // heap: [0, 1, 2, 3, 4]
    assert(buf.onHeap);

    buf ~= buf[];                    // self-append across a realloc-grow
    assert(buf.length == 10);
    assert(buf[] == [0, 1, 2, 3, 4, 0, 1, 2, 3, 4]);
}









// ─────────────────────────────────────────────────────────────────────────────
// Copy-on-write
// ─────────────────────────────────────────────────────────────────────────────

@("Buffer.cow.inlineCopyIndependent")
@safe pure nothrow @nogc
unittest
{
    Buffer!(int, 4) a;
    a ~= 1;
    a ~= 2;
    auto b = a;                  // inline copy: independent
    assert(b[] == [1, 2]);
    a[0] = 99;                   // mutate original
    assert(b[0] == 1);           // copy unchanged
    assert(!a.onHeap && !b.onHeap);
}

@("Buffer.cow.heapShareThenClone")
@safe pure nothrow @nogc
unittest
{
    Buffer!(int, 2) a;
    a ~= iota(5);        // heap: [0, 1, 2, 3, 4]
    assert(a.onHeap);

    auto b = a;                  // share the heap block
    assert(a.refCount == 2 && b.refCount == 2);

    b ~= 5;                      // mutate b -> copy-on-write clone
    assert(a.refCount == 1 && b.refCount == 1);
    assert(a[] == [0, 1, 2, 3, 4]);          // original intact
    assert(b[] == [0, 1, 2, 3, 4, 5]);
}

@("Buffer.cow.constReadersShare")
@safe pure nothrow @nogc
unittest
{
    Buffer!(int, 2) a;
    a ~= iota(5);        // heap
    const ro = a.borrow();       // const read-only handle, shares storage
    const r2 = ro;               // another reader, shares too
    assert(a.refCount == 3);
    assert(ro[] == [0, 1, 2, 3, 4]);
    assert(r2[] == [0, 1, 2, 3, 4]);

    a ~= 99;                     // producer mutates -> CoW
    assert(ro[] == [0, 1, 2, 3, 4]);         // borrowed readers keep old value
    assert(a[] == [0, 1, 2, 3, 4, 99]);
    assert(ro.refCount == 2);
}

@("Buffer.cow.copyAssignment")
@safe pure nothrow @nogc
unittest
{
    Buffer!(int, 2) a, b;
    a ~= iota(5);        // heap
    b ~= 100;                    // b inline

    b = a;                       // copy-assign: b releases its own, shares a's
    assert(a.refCount == 2);
    assert((cast(const) b)[] == [0, 1, 2, 3, 4]);   // const read: no clone

    b ~= 5;                      // CoW
    assert(a.refCount == 1);
    assert(a[] == [0, 1, 2, 3, 4]);
    assert(b[] == [0, 1, 2, 3, 4, 5]);
}

@("Buffer.cow.constOpAssign")
@safe pure nothrow @nogc
unittest
{
    Buffer!(int, 2) a;
    a ~= iota(5);        // heap

    // Assigning a const/borrowed source must compile and share storage.
    const borrowed = a.borrow();
    Buffer!(int, 2) work;
    work ~= 100;                 // work inline, owns nothing on the heap
    work = borrowed;               // const copy-assign: shares a's block
    assert(a.refCount == 3);     // a, borrowed, work all share
    assert((cast(const) work)[] == [0, 1, 2, 3, 4]);   // const read: no clone

    work ~= 5;                   // CoW: clone away from the shared block
    assert(a.refCount == 2);     // a, borrowed still share
    assert(a[] == [0, 1, 2, 3, 4]);
    assert(work[] == [0, 1, 2, 3, 4, 5]);

    // Rvalue/move assignment must also compile.
    Buffer!(int, 2) mv;
    mv = makeHeapBuffer();
    assert(mv[] == [0, 1, 2, 3, 4]);
}

// Helper: returns a heap Buffer by value (rvalue source for opAssign).
version (unittest)
private Buffer!(int, 2) makeHeapBuffer() @safe pure nothrow @nogc
{
    Buffer!(int, 2) r;
    r ~= iota(5);
    return r;
}

@("Buffer.cow.refCountLifetime")
@safe pure nothrow @nogc
unittest
{
    Buffer!(int, 2) a;
    a ~= iota(5);
    assert(a.refCount == 1);
    {
        auto b = a;
        assert(a.refCount == 2);
        {
            auto c = a;
            assert(a.refCount == 3);
        }                        // c released
        assert(a.refCount == 2);
    }                            // b released
    assert(a.refCount == 1);
    assert(a[] == [0, 1, 2, 3, 4]);          // survivor intact
}

@("Buffer.cow.constToMutableWorkingCopy")
@safe pure nothrow @nogc
unittest
{
    Buffer!(int, 2) a;
    a ~= iota(5);
    const borrowed = a.borrow();
    Buffer!(int, 2) work = borrowed;      // const -> mutable copy ctor
    assert((cast(const) work)[] == [0, 1, 2, 3, 4]);

    work ~= 7;                   // CoW; borrowed untouched
    assert(borrowed[] == [0, 1, 2, 3, 4]);
    assert(work[] == [0, 1, 2, 3, 4, 7]);
}

@("Buffer.cow.toOwned")
@safe pure nothrow @nogc
unittest
{
    Buffer!(int, 2) a;
    a ~= iota(5);            // heap
    const reader = a.borrow();       // a + reader share, refCount 2

    // toOwned detaches an independent copy without disturbing the source.
    auto owned = a.toOwned();
    assert(owned.refCount == 1);     // uniquely owns its block
    assert(a.refCount == 2);         // a and reader still share, untouched
    assert(owned[] == [0, 1, 2, 3, 4]);

    owned ~= 9;                      // already unique → no CoW clone
    assert(owned[] == [0, 1, 2, 3, 4, 9]);
    assert(reader[] == [0, 1, 2, 3, 4]);   // source unaffected

    // An inline buffer is already independent; toOwned just copies it.
    Buffer!(int, 4) sm;
    sm ~= [1, 2];
    auto c = sm.toOwned();
    assert(!c.onHeap && c[] == [1, 2]);
}

@("Buffer.cow.sharedGrowAppend")
@safe pure nothrow @nogc
unittest
{
    // Growing a *shared* buffer folds the CoW clone and the grow into one
    // allocation; the shared original must stay intact and detach cleanly.

    // Single-element put on a shared, full heap buffer.
    Buffer!(int, 2) a;
    a ~= [0, 1, 2, 3];               // heap, capacity 4 (full)
    const reader = a.borrow;         // share, refCount 2
    assert(a.refCount == 2 && a.capacity == 4);

    a ~= 4;                          // shared + full → clone straight into grown block
    assert(reader[] == [0, 1, 2, 3]);            // original block intact
    assert(a[] == [0, 1, 2, 3, 4]);
    assert(a.refCount == 1 && reader.refCount == 1);
    assert(a.capacity >= 5);

    // Slice put on a shared, growing heap buffer.
    Buffer!(int, 2) b;
    b ~= [0, 1, 2, 3];               // heap
    const rb = b.borrow;
    assert(b.refCount == 2);
    b ~= [10, 11, 12];               // shared + grow
    assert(rb[] == [0, 1, 2, 3]);                // original intact
    assert(b[] == [0, 1, 2, 3, 10, 11, 12]);
    assert(b.refCount == 1);
}

@("Buffer.selfAppend.sharedAlias")
@safe pure nothrow @nogc
unittest
{
    // Self-append through a const (shared) slice: the source aliases the old
    // block, which the clone keeps alive (via the borrow) while copying.
    Buffer!(int, 2) a;
    a ~= [0, 1, 2, 3];               // heap
    const reader = a.borrow;         // share, refCount 2
    a ~= a.borrow[];                 // xs aliases the shared block
    assert(reader[] == [0, 1, 2, 3]);            // original intact
    assert(a[] == [0, 1, 2, 3, 0, 1, 2, 3]);
}

@("Buffer.reserve.sharedGrowsOnce")
@safe pure nothrow @nogc
unittest
{
    Buffer!(int, 2) a;
    a ~= [0, 1, 2, 3, 4];            // heap
    const reader = a.borrow;         // share
    assert(a.refCount == 2);

    a.reserve(100);                  // shared + grow → one allocation
    assert(a.refCount == 1 && reader.refCount == 1);
    assert(a.capacity >= 100);
    assert(a[] == [0, 1, 2, 3, 4]);
    assert(reader[] == [0, 1, 2, 3, 4]);         // sharer keeps the old block
}

@("Buffer.reserve.sharedDetachPreservesCapacity")
@safe pure nothrow @nogc
unittest
{
    Buffer!(int, 2) a;
    a ~= [0, 1, 2, 3, 4];
    a.reserve(100);
    const reservedCapacity = a.capacity;

    auto b = a;
    b[0] = 99;                         // detach without growing

    assert(a.capacity == reservedCapacity);
    assert(b.capacity == reservedCapacity);
    assert(a[0] == 0);
    assert(b[0] == 99);
}

@("Buffer.cow.attributesPreserved")
@safe pure nothrow @nogc
unittest
{
    // The whole copy/borrow/clone cycle must hold @safe pure nothrow @nogc.
    Buffer!(char, 4) a;
    a ~= "hello world";          // heap
    auto b = a;                  // share
    const ro = a.borrow();       // borrow
    b ~= '!';                    // CoW clone
    assert((cast(const) a)[] == "hello world");
    assert(ro[] == "hello world");
    assert(b[] == "hello world!");
}

@("Buffer.selfAppend.singleAliasTransition")
@safe pure nothrow @nogc
unittest
{
    struct LargePoint { long x, y, z, w; }
    Buffer!(LargePoint, 2) buf;
    buf ~= LargePoint(1, 2, 3, 4);
    buf ~= LargePoint(5, 6, 7, 8);

    // This should append buf[0] to buf, triggering inline->heap transition
    // while checking that the element passed by ref is not corrupted.
    buf ~= buf[0];
    assert(buf.onHeap);
    assert(buf.length == 3);
    assert(buf[0] == LargePoint(1, 2, 3, 4));
    assert(buf[1] == LargePoint(5, 6, 7, 8));
    assert(buf[2] == LargePoint(1, 2, 3, 4));
}

@("Buffer.selfAppend.rangeAliasTransition")
@safe pure nothrow @nogc
unittest
{
    import std.algorithm : map;
    Buffer!(int, 4) buf;
    buf ~= [1, 2, 3];

    // Trigger inline->heap transition with map range aliasing buf
    buf ~= buf[].map!(x => x * 2);
    assert(buf.onHeap);
    assert(buf.length == 6);
    assert(buf[] == [1, 2, 3, 2, 4, 6]);
}

// ─────────────────────────────────────────────────────────────────────────────
// Unique (copy-on-write opted out)
// ─────────────────────────────────────────────────────────────────────────────

///
@("Buffer.unique.tour")
@safe pure nothrow @nogc
unittest
{
    // A `unique` buffer behaves like the default one for building — append
    // inline, spill to the heap, index/slice — but carries no copy-on-write
    // machinery, so appends never consult a reference count.
    UniqueBuffer!(int, 4) buf;
    buf ~= [1, 2, 3];
    buf.put(4);
    assert(buf[] == [1, 2, 3, 4] && !buf.onHeap);

    buf ~= 5;                            // spill to the heap
    assert(buf.onHeap && buf[] == [1, 2, 3, 4, 5]);
    assert(buf[0] == 1 && buf[$ - 1] == 5 && buf[1 .. 3] == [2, 3]);

    // It is move-only: there is no sharing, so it cannot be copied — only moved
    // or promoted. `toShared` consumes it and hands back an ordinary
    // copy-on-write `Buffer!(int, 4)` that borrows/shares as usual.
    auto sh = buf.toShared();
    assert(buf.length == 0);             // consumed
    assert(sh[] == [1, 2, 3, 4, 5] && sh.refCount == 1);

    const reader = sh.borrow;            // now shareable
    assert(sh.refCount == 2 && reader[] == [1, 2, 3, 4, 5]);
}

@("Buffer.unique.moveOnly")
@safe pure nothrow @nogc
unittest
{
    // Copy construction and copy-assignment are disabled; the type is move-only.
    static assert(!__traits(isCopyable, UniqueBuffer!(int, 4)));
    static assert( __traits(isCopyable, Buffer!(int, 4)));       // default: copyable

    static assert(!__traits(compiles, (UniqueBuffer!(int, 4) a) { auto b = a; }));
    static assert(!__traits(compiles, (UniqueBuffer!(int, 4) a,
        UniqueBuffer!(int, 4) b) { b = a; }));

    // Still an output range, and moving works.
    import std.range : isOutputRange;
    static assert(isOutputRange!(UniqueBuffer!(int, 4), int));

    import std.algorithm.mutation : move;
    UniqueBuffer!(int, 2) a;
    a ~= iota(5);                        // heap
    UniqueBuffer!(int, 2) b;
    b = move(a);                         // move-assignment steals the block
    assert(b[] == [0, 1, 2, 3, 4] && a.length == 0);
}

@("Buffer.unique.heapGrowth")
@safe pure nothrow @nogc
unittest
{
    UniqueBuffer!(int, 2) buf;
    buf ~= iota(100);                    // many reallocations, all in place
    assert(buf.length == 100);
    foreach (i; 0 .. 100)
        assert(buf[i] == i);

    // popBack across the heap->inline boundary and clear both work.
    buf.clear();
    assert(buf.empty && !buf.onHeap);
    buf ~= iota(3);                      // heap: [0, 1, 2]
    buf.popBack();                       // 3 -> 2: revert to inline
    assert(!buf.onHeap && buf[] == [0, 1]);
}

@("Buffer.unique.selfAppend.inlineToHeap")
@safe pure nothrow @nogc
unittest
{
    // Self-append that crosses inline->heap: the source aliases inline storage,
    // which must be read into the new block before the union is overwritten.
    UniqueBuffer!(int, 4) buf;
    buf ~= [0, 1, 2];
    buf ~= buf[];
    assert(buf.onHeap && buf[] == [0, 1, 2, 0, 1, 2]);
}

@("Buffer.unique.selfAppend.heapGrow")
@safe pure nothrow @nogc
unittest
{
    // Self-append that forces a heap grow: the source aliases the block being
    // grown, so the unique path allocate-copy-frees rather than reallocating
    // underneath the source.
    UniqueBuffer!(int, 2) buf;
    buf ~= iota(5);                      // heap: [0, 1, 2, 3, 4], capacity 8
    buf ~= buf[];                        // 5 + 5 = 10 > capacity → grow
    assert(buf.length == 10);
    assert(buf[] == [0, 1, 2, 3, 4, 0, 1, 2, 3, 4]);
}

@("Buffer.unique.toShared.inline")
@safe pure nothrow @nogc
unittest
{
    UniqueBuffer!(int, 4) u;
    u ~= [1, 2];
    auto sh = u.toShared();
    assert(u.length == 0 && !u.onHeap); // consumed, left empty
    assert(!sh.onHeap && sh[] == [1, 2]);

    // The result is a fully-featured copy-on-write buffer.
    auto copy = sh;                      // inline copy: independent
    copy[0] = 99;
    assert(sh[0] == 1 && copy[0] == 99);
}

@("Buffer.unique.toShared.heapTransfersBlock")
@safe pure nothrow @nogc
unittest
{
    UniqueBuffer!(int, 2) u;
    u ~= iota(5);                        // heap
    const cap = u.capacity;

    auto sh = u.toShared();              // block transfers, no realloc
    assert(u.length == 0);
    assert(sh.onHeap && sh[] == [0, 1, 2, 3, 4]);
    assert(sh.capacity == cap);          // same block
    assert(sh.refCount == 1);            // sole owner

    // Copy-on-write is live on the promoted buffer.
    const reader = sh.borrow;
    assert(sh.refCount == 2);
    auto w = sh;                         // share
    w ~= 5;                              // CoW clone
    assert(reader[] == [0, 1, 2, 3, 4]); // original intact
    assert(w[] == [0, 1, 2, 3, 4, 5]);
}

@("Buffer.unique.returnScopeContainer")
@safe pure nothrow @nogc
unittest
{
    // A container that owns a `unique` Buffer and exposes `return scope` views
    // into it — the `sparkles.tui.cell.Grid` pattern. Under `-dip1000` the accessor
    // body indexes/slices a `scope this._buf`, which only type-checks because the
    // buffer's element accessors (and the `ensureUniqueStorage` the mutable path
    // calls) are `return`-qualified. Dropping that `return` regresses right here:
    // "scope variable `this._buf` calling non-scope member function ...".
    static struct Holder
    {
        private UniqueBuffer!(int, 2) _buf;
        void push(int v) @safe => _buf.put(v);
        ref int opIndex(size_t i) return scope @safe => _buf[i];
        ref const(int) opIndex(size_t i) const return scope @safe => _buf[i];
        int[] all() return scope @safe => _buf[];
        const(int)[] all() const return scope @safe => _buf[];
        static int firstOf(ref const Holder h) @safe => h[0]; // exercises the const path
    }

    Holder h;
    h.push(10);
    h.push(20);
    h.push(30); // N == 2 → now on the heap
    assert(h[0] == 10 && h[2] == 30);
    h[1] = 99; // mutable ref write through the `return scope` accessor
    assert(h[1] == 99 && Holder.firstOf(h) == 10);

    int sum;
    foreach (v; h.all) // mutable `return scope` slice
        sum += v;
    assert(sum == 10 + 99 + 30);
}

@("Buffer.noIndirections.putAndAppendByValue")
@safe pure nothrow @nogc
unittest
{
    // Struct with no indirections (POD / value payload)
    static struct Point
    {
        int x;
        int y;
        long tag;
    }
    static assert(!hasIndirections!Point);

    // Test unique buffer (unique = true)
    {
        UniqueBuffer!(Point, 2) buf;
        buf.put(Point(1, 2, 100));
        buf ~= Point(3, 4, 200);
        // Inline capacity reached (N == 2)
        assert(!buf.onHeap && buf.length == 2);
        assert(buf[0] == Point(1, 2, 100));
        assert(buf[1] == Point(3, 4, 200));

        // Spill to heap
        buf ~= Point(5, 6, 300);
        buf.put(Point(7, 8, 400));
        assert(buf.onHeap && buf.length == 4);
        assert(buf[2] == Point(5, 6, 300));
        assert(buf[3] == Point(7, 8, 400));

        // Slice append
        const Point[2] more = [Point(9, 10, 500), Point(11, 12, 600)];
        buf ~= more[];
        assert(buf.length == 6);
        assert(buf[4] == Point(9, 10, 500));
        assert(buf[5] == Point(11, 12, 600));
    }

    // Test shared buffer (unique = false, CoW)
    {
        SharedBuffer!(Point, 2) buf;
        buf.put(Point(10, 20, 1000));
        buf ~= Point(30, 40, 2000);
        buf ~= Point(50, 60, 3000); // heap spill
        assert(buf.onHeap && buf.length == 3);

        auto copy = buf;
        assert(buf.refCount == 2);
        copy ~= Point(70, 80, 4000); // CoW clone
        assert(buf.length == 3);
        assert(copy.length == 4);
        assert(copy[3] == Point(70, 80, 4000));
    }
}

@("Buffer.sumTypePayload.putAndAppend")
@safe pure nothrow @nogc
unittest
{
    import std.sumtype : SumType, match;

    alias Val = SumType!(int, double, bool, typeof(null));
    static struct PayloadA { int x; Val val; }
    static struct PayloadB { long id; }
    alias NodePayload = SumType!(PayloadA, PayloadB);

    static struct ComplexNode
    {
        int kind;
        NodePayload payload;
        long span;

        this(P)(int k, P p, long s) @trusted pure nothrow @nogc
        {
            kind = k;
            span = s;
            payload = p;
        }
    }
    static assert(!hasIndirections!ComplexNode);

    // Test unique buffer with complex nested SumType
    UniqueBuffer!(ComplexNode, 2) buf;
    buf.put(ComplexNode(1, PayloadA(10, Val(null)), 100));
    buf ~= ComplexNode(2, PayloadB(200), 300);
    assert(!buf.onHeap && buf.length == 2);

    // Spill to heap
    buf ~= ComplexNode(3, PayloadA(30, Val(3.14)), 400);
    assert(buf.onHeap && buf.length == 3);

    const isNullVal = buf[0].payload.match!(
        (in PayloadA a) => a.val.match!(
            (in typeof(null)) => true,
            _ => false
        ),
        (in PayloadB) => false
    );
    assert(isNullVal);
}


// ─────────────────────────────────────────────────────────────────────────────
// The four named policies.
// ─────────────────────────────────────────────────────────────────────────────

/**
A buffer that never allocates: the elements live in the inline `T[N]` and
nowhere else.

The policy with a guarantee no other has. Because there is no union, a slice of
the storage is provably a reference to the enclosing frame, so `-dip1000`
rejects returning one from a `@safe` function — the property `CString` is built
on. It also has no destructor, so it is plain data: copyable, comparable, and
usable as a field in an aggregate that must stay POD.

It is deliberately $(B not) an output range: `put` promises to accept what it is
given, and this cannot. Write into it with $(LREF tryWrite).

Pass `Storage.unique` as `extra` for the move-only form, which is what prevents
an accidental copy of a large one.
*/
template InlineBuffer(T, size_t N, Storage extra = Storage.none)
if (!(extra & ~Storage.unique)) // `extra` is the ownership axis only
{
    alias InlineBuffer = Buffer!(T, N, cast(Storage)(Storage.inline | extra));
}

/**
A buffer with no inline array: the elements always live on the heap.

For a sequence whose typical size makes an inline array dead weight — the struct
costs one slice regardless of how much it holds. Size it up front with `reserve`;
there is no `N` to raise.
*/
template HeapBuffer(T, Storage extra = Storage.none)
if (!(extra & ~Storage.unique)) // `extra` is the ownership axis only
{
    alias HeapBuffer = Buffer!(T, 0, cast(Storage)(Storage.heap | extra));
}

/**
Small-buffer optimization with shared heap storage: inline while the elements
fit, heap when they do not, and a copy is a second handle on the same block.

$(B The storage is shared; the value is not.) A write through one copy clones
the block first, so it is invisible to the others — copies behave as independent
values. This is unlike `shared_ptr`, where a mutation propagates to every holder.
*/
alias SharedBuffer(T, size_t N = max(size_t(1), (T[]).sizeof / T.sizeof)) =
    Buffer!(T, N, cast(Storage)(Storage.inline | Storage.heap));

/**
Small-buffer optimization with a sole owner: inline while the elements fit, heap
when they do not, and copying is disabled.

Disabling copies is what removes the reference count from the grow path — there
is no second owner to consult. Hand a finished one to the shared world with
`toShared`, which consumes it and transfers any heap block without reallocating.
*/
alias UniqueBuffer(T, size_t N = max(size_t(1), (T[]).sizeof / T.sizeof)) =
    Buffer!(T, N, cast(Storage)(Storage.inline | Storage.heap | Storage.unique));

// ─────────────────────────────────────────────────────────────────────────────
// Bounded writing.
// ─────────────────────────────────────────────────────────────────────────────

/**
A bounded output range over storage someone else owns.

Handed out by $(LREF tryWrite) and valid only inside it, so a partially written
destination is never observable: either the whole write fits, or nothing is
kept. Overflow is recorded rather than thrown, which is what lets the entire
`sparkles.base.text.writers` family compose inside one attempt.
*/
struct BoundedSink(T)
{
    private T[] _dest;
    private size_t _length;
    private bool _overflowed;

    /// Appends one element, or records overflow if there is no room.
    void put(T element) @safe pure nothrow @nogc
    {
        if (_length >= _dest.length)
        {
            _overflowed = true;
            return;
        }
        _dest[_length++] = element;
    }

    /// ditto
    void put(scope const(T)[] elements) @safe pure nothrow @nogc
    {
        // One bounds check and one bulk copy; nothing is written unless the
        // whole slice fits, so overflow never leaves a partial tail behind.
        const end = _length + elements.length;
        if (end > _dest.length)
        {
            _overflowed = true;
            return;
        }
        copyElements(_dest[_length .. end], elements);
        _length = end;
    }
}

/**
Runs `fn` against a bounded output range over `dest`, returning what it wrote.

---
if (auto path = scratch[].tryWrite((scope ref BoundedSink!char w) {
        w.put("/proc/"); w.writeValue(pid); w.put("/status");
    }))
    return openAt(path.ptr);
return err(ENAMETOOLONG);
---

$(B On overflow the result is `null`) and the bytes in `dest` are unspecified:
the sink writes straight into it, so a partial write is visible there. `dest` is
scratch, and `null` is the only signal to read. `Buffer.tryWrite` is the
transactional form — it restores `length`, and a buffer's value is
`[0 .. length]`, so a failed write leaves the buffer's value untouched.

$(B `null` is not the empty slice.) A successful write of nothing returns
`dest[0 .. 0]`, whose pointer is `dest.ptr`; only overflow returns `null`. Test
with `is null`, never with `.length == 0`.

$(B Lifetime.) `dest` is `return`, so the result is tied to the destination and
`-dip1000` rejects returning it from a function whose buffer is a local.

Works on anything that yields a slice — a static array, an $(LREF InlineBuffer),
a region of a larger buffer — because `dest` is that slice.
*/
T[] tryWrite(T)(return T[] dest,
    scope void delegate(scope ref BoundedSink!T) @safe pure nothrow @nogc fn)
    @safe pure nothrow @nogc
{
    scope sink = BoundedSink!T(dest);
    fn(sink);
    return sink._overflowed ? null : dest[0 .. sink._length];
}

/**
As above, for a callback that is not `@safe pure nothrow @nogc`.

The stricter overload exists because fixing the delegate's attributes is what
keeps a $(I capturing) callback `@nogc`; deducing the type instead accepts any
callback but allocates a closure. Having both means neither property is lost.
*/
T[] tryWrite(T, Dg)(return T[] dest, scope Dg fn)
if (!is(Dg : void delegate(scope ref BoundedSink!T) @safe pure nothrow @nogc))
{
    scope sink = BoundedSink!T(dest);
    fn(sink);
    return sink._overflowed ? null : dest[0 .. sink._length];
}

///
@("buffer.tryWrite.writesOrReportsWithoutTrace")
@safe pure nothrow @nogc
unittest
{
    char[16] room;
    auto got = room[].tryWrite((scope ref BoundedSink!char w) => w.put("/proc/1"));
    assert(got == "/proc/1");

    // Overflow reports `null`. The raw form writes straight into `dest`, so
    // what is left there is unspecified — `null` is the only signal.
    char[4] tight;
    auto over = tight[].tryWrite((scope ref BoundedSink!char w) => w.put("/proc/1"));
    assert(over is null);
}

@("buffer.tryWrite.emptyWriteIsNotOverflow")
@safe pure nothrow @nogc
unittest
{
    // The distinction every caller has to get right: `null` means it did not
    // fit; a zero-length slice means there was nothing to write.
    char[4] dest;
    auto none = dest[].tryWrite((scope ref BoundedSink!char w) {});
    assert(none !is null);
    assert(none.length == 0);
}

@("buffer.tryWrite.keepsNogcThroughACapturingCallback")
@safe pure nothrow @nogc
unittest
{
    // The reason the strict overload fixes the delegate's attributes rather
    // than deducing them.
    const pid = 7;
    char[8] dest;
    auto got = dest[].tryWrite((scope ref BoundedSink!char w) {
        w.put("cpu");
        w.put(cast(char)('0' + pid));
    });
    assert(got == "cpu7");
}

@("buffer.tryWrite.resultCannotOutliveTheDestination")
unittest
{
    // `return` on `dest` is what makes this checkable.
    static assert(!__traits(compiles, {
        char[] leak() @safe pure nothrow @nogc
        {
            char[8] local;
            return local[].tryWrite((scope ref BoundedSink!char w) => w.put("x"));
        }
    }), "dip1000 should reject escaping the written slice");
}

@("buffer.Storage.inlineOnlyIsNotAnOutputRange")
unittest
{
    import std.range.primitives : isOutputRange;

    // WRT1: a buffer that may not allocate cannot honour `put`'s contract.
    static assert(!isOutputRange!(InlineBuffer!(char, 8), char));
    static assert(!__traits(compiles, { InlineBuffer!(char, 8) b; b ~= 'x'; }));

    // Every policy that may grow keeps both.
    static assert(isOutputRange!(SharedBuffer!(char, 8), char));
    static assert(isOutputRange!(UniqueBuffer!(char, 8), char));
    static assert(isOutputRange!(HeapBuffer!char, char));
}

@("buffer.Storage.inlineOnlyRejectsEscapes")
unittest
{
    // BUF6: no union, so the elements are provably a reference to the frame.
    static assert(!__traits(compiles, {
        const(char)[] leak() @safe { InlineBuffer!(char, 8) b; return b[]; }
    }), "dip1000 should reject escaping an inline buffer's elements");

    // The forms that may allocate reach their bytes through a pointer and
    // cannot offer this.
    static assert(__traits(compiles, {
        const(char)[] fine() @safe { SharedBuffer!(char, 8) b; return b[]; }
    }));
}

@("buffer.Storage.rejectsPoliciesWithNowhereToPut")
unittest
{
    // BUF2/BUF3: no storage bit, and a non-zero `N` without inline storage.
    static assert(!__traits(compiles, Buffer!(char, 8, Storage.unique)));
    static assert(!__traits(compiles, Buffer!(char, 8, Storage.heap)));
    static assert(__traits(compiles, Buffer!(char, 0, Storage.heap)));
}

@("buffer.inlineCapacity.isAvailableAtCompileTime")
@safe pure nothrow @nogc
unittest
{
    // The point of the constant: sizing something else from it. `capacity()` is
    // a runtime accessor and cannot appear here.
    InlineBuffer!(char, 96) label;
    char[typeof(label).inlineCapacity + 1] terminated;
    assert(terminated.length == 97);

    static assert(HeapBuffer!int.inlineCapacity == 0);
    static assert(UniqueBuffer!(int, 4).inlineCapacity == 4);
}

@("buffer.inline.assignReplacesWholeValue")
@safe pure nothrow @nogc
unittest
{
    InlineBuffer!(char, 8) b;
    assert(b.assign("wayland"));
    assert(b[] == "wayland");

    // Refused, and the old value survives — which is exactly what separates
    // `assign` from `clear` followed by a write.
    assert(!b.assign("too-long!"));
    assert(b[] == "wayland");

    assert(b.assign(""));
    assert(b.length == 0);
}

@("buffer.inline.clearResetsLength")
@safe pure nothrow @nogc
unittest
{
    // An inline-only buffer has no storage to release, so `clear` is the
    // length reset alone — and `clear` + `tryWrite` is how a fixed buffer
    // replaces its value.
    InlineBuffer!(char, 8) b;
    assert(b.tryWrite((scope ref BoundedSink!char w) { w.put("first"); }));
    b.clear();
    assert(b.length == 0);
    assert(b[] == "");
    assert(b.tryWrite((scope ref BoundedSink!char w) { w.put("second"); }));
    assert(b[] == "second");

    // The replacement is transactional: one that cannot fit leaves the buffer
    // empty rather than half-written.
    b.clear();
    assert(!b.tryWrite((scope ref BoundedSink!char w) { w.put("far too long"); }));
    assert(b[] == "");
}

@("buffer.opEquals.comparesContentsNotStorage")
@safe pure nothrow @nogc
unittest
{
    // BUF10: capacity beyond `length` never participates, so policies with
    // different residency compare equal when they hold the same elements.
    SharedBuffer!(char, 4) small;
    small ~= "abcdefgh";        // grown to the heap
    assert(small.onHeap);

    SharedBuffer!(char, 64) big;
    big ~= "abcdefgh";          // still inline
    assert(!big.onHeap);

    assert(small == big);
    assert(small == "abcdefgh");
}

@("buffer.HeapBuffer.reserveSizesItBeforeUse")
@safe pure nothrow @nogc
unittest
{
    // BUF11: a heap-only buffer has no `N` to raise, so `reserve` is the only
    // way to size it up front.
    HeapBuffer!int b;
    b.reserve(64);
    assert(b.capacity >= 64);
    assert(b.length == 0);

    foreach (i; 0 .. 64)
        b ~= i;
    assert(b.length == 64);
    assert(b[][63] == 63);
}

// ─────────────────────────────────────────────────────────────────────────────
// Heap-only and inline-unique: the two policies with no small-buffer union.
// ─────────────────────────────────────────────────────────────────────────────

@("buffer.HeapBuffer.moveAssignTransfersBlock")
@safe pure nothrow @nogc
unittest
{
    // `onHeap` is the block for a heap-only policy, so the moved-from rvalue
    // must be stripped of it — zeroing its length alone left its destructor
    // freeing the block the assignee had just taken.
    static HeapBuffer!int make() @safe pure nothrow @nogc
    {
        HeapBuffer!int r;
        r ~= [1, 2, 3];
        return r;
    }

    HeapBuffer!int a;
    a = make();
    assert(a.onHeap && a.refCount == 1);

    // A fresh same-sized allocation must not land on `a`'s block.
    HeapBuffer!int other;
    other ~= [7, 7, 7];
    assert(a[] == [1, 2, 3]);
    assert((() @trusted => a._block.ptr !is other._block.ptr)());

    import std.algorithm.mutation : move;
    HeapBuffer!(int, Storage.unique) u;
    u ~= iota(5);
    HeapBuffer!(int, Storage.unique) v;
    v = move(u);
    assert(u.length == 0 && !u.onHeap);
    HeapBuffer!(int, Storage.unique) w;
    w ~= iota(5);
    assert(v[] == [0, 1, 2, 3, 4]);
    assert((() @trusted => v._block.ptr !is w._block.ptr)());
}

@("buffer.HeapBuffer.copyOnWrite")
@safe pure nothrow @nogc
unittest
{
    HeapBuffer!int a;
    a ~= [1, 2, 3];
    auto b = a;                          // shares the block
    assert(a.refCount == 2 && b.refCount == 2);

    b ~= 4;                              // clones
    assert(a.refCount == 1 && b.refCount == 1);
    assert(a[] == [1, 2, 3] && b[] == [1, 2, 3, 4]);

    const reader = a.borrow;
    assert(a.refCount == 2 && reader[] == [1, 2, 3]);
}

@("buffer.HeapBuffer.putRangeReusesReservedBlock")
@safe pure nothrow @nogc
unittest
{
    // The known-length range path used to take the inline->heap transition on
    // "empty", allocating a second block over the reserved one.
    HeapBuffer!int b;
    b.reserve(64);
    const p = (() @trusted => b._block.ptr)();
    b ~= iota(5);
    assert(b.capacity >= 64);
    assert((() @trusted => b._block.ptr is p)());
    assert(b[] == [0, 1, 2, 3, 4]);
}

@("buffer.HeapBuffer.shrinkKeepsBlock")
@safe pure nothrow @nogc
unittest
{
    // A heap-only policy has nothing to revert to, so every shrink keeps the
    // block: one `reserve` serves a buffer that is drained and refilled.
    HeapBuffer!int b;
    b.reserve(64);
    const cap = b.capacity;
    const p = (() @trusted => b._block.ptr)();

    b ~= 1;
    b.popBack();
    assert(b.empty && b.onHeap && b.capacity == cap);

    b ~= [1, 2, 3];
    b.length = 0;
    assert(b.empty && b.onHeap && b.capacity == cap);

    b ~= [1, 2, 3];
    b.clear();
    assert(b.empty && b.onHeap && b.capacity == cap);

    foreach (i; 0 .. 64)
        b ~= i;
    assert(b.capacity == cap);
    assert((() @trusted => b._block.ptr is p)());
}

@("buffer.HeapBuffer.toOwnedDetachesWhenEmpty")
@safe pure nothrow @nogc
unittest
{
    HeapBuffer!int a;
    a.reserve(8);
    auto b = a;
    assert(a.refCount == 2);

    auto owned = b.toOwned();
    assert(owned.refCount == 1);
    assert(a.refCount == 2);
    assert(owned.capacity == a.capacity);
}

@("buffer.HeapBuffer.uniqueToShared")
@safe pure nothrow @nogc
unittest
{
    HeapBuffer!(int, Storage.unique) u;
    u ~= iota(5);
    const cap = u.capacity;

    auto sh = u.toShared();
    static assert(is(typeof(sh) == HeapBuffer!int));
    assert(u.length == 0 && !u.onHeap);
    assert(sh.onHeap && sh.capacity == cap && sh.refCount == 1);
    assert(sh[] == [0, 1, 2, 3, 4]);
}

@("buffer.inline.uniqueIsMoveOnlyAndPromotes")
@safe pure nothrow @nogc
unittest
{
    // BUF7 for `inline | unique`: the policy instantiates, cannot be copied,
    // and promotes to the copyable inline policy by copying its elements.
    alias U = InlineBuffer!(char, 8, Storage.unique);
    static assert(!__traits(isCopyable, U));
    static assert(__traits(isCopyable, InlineBuffer!(char, 8)));

    U u;
    assert(u.tryWrite((scope ref BoundedSink!char w) { w.put("abc"); }));
    assert(u[] == "abc");

    auto sh = u.toShared();
    static assert(is(typeof(sh) == InlineBuffer!(char, 8)));
    assert(u.length == 0);
    assert(sh[] == "abc");
    auto copy = sh;
    assert(copy[] == "abc");
}

@("buffer.inline.tryWriteAcceptsSystemCallback")
@system pure nothrow @nogc
unittest
{
    // WRT6 on the member: a callback that is not `@safe` takes the deduced
    // overload. (`pure nothrow @nogc` are the buffer's own attributes and
    // still apply — the struct is declared under them.)
    int seen;
    InlineBuffer!(char, 8) b;
    assert(b.tryWrite((scope ref BoundedSink!char w) @system {
        seen = 1;
        w.put("sys");
    }));
    assert(b[] == "sys" && seen == 1);
}

@("buffer.inline.tryWriteOverflowKeepsExistingValue")
@safe pure nothrow @nogc
unittest
{
    InlineBuffer!(char, 8) b;
    assert(b.tryWrite((scope ref BoundedSink!char w) { w.put("abc"); }));

    // Six more do not fit after three; the value must be exactly what it was.
    assert(!b.tryWrite((scope ref BoundedSink!char w) { w.put("defghi"); }));
    assert(b[] == "abc");

    // Five do.
    assert(b.tryWrite((scope ref BoundedSink!char w) { w.put("defgh"); }));
    assert(b[] == "abcdefgh");

    // Full: an empty write still succeeds, one element does not.
    assert(b.tryWrite((scope ref BoundedSink!char w) {}));
    assert(!b.tryWrite((scope ref BoundedSink!char w) { w.put('x'); }));
    assert(b[] == "abcdefgh");
}

@("buffer.aliases.rejectStorageBitsInExtra")
unittest
{
    // `extra` is the ownership axis; a residency bit there would silently
    // turn one alias into another policy.
    static assert(!__traits(compiles, InlineBuffer!(char, 8, Storage.heap)));
    static assert(!__traits(compiles, HeapBuffer!(char, Storage.inline)));
    static assert(__traits(compiles, InlineBuffer!(char, 8, Storage.unique)));
    static assert(__traits(compiles, HeapBuffer!(char, Storage.unique)));
}

// A buffer held by a struct whose methods take `this` as `scope` — a lexer
// storing its error, say — must be writable there: every mutator declares
// `this` as `scope`, so the enclosing method's `@safe` inference does not
// hinge on the order in which the compiler analyzed the buffer's members.
@("Buffer.scope.writableThroughScopeThis")
@safe pure nothrow @nogc
unittest
{
    static struct Holder
    {
        SharedBuffer!(char, 8) note;
        UniqueBuffer!(int, 4) ints;
        InlineBuffer!(char, 8) fixed;

        void fill() scope @safe
        {
            note ~= "abc";
            note ~= 'd';
            note.clear();
            note ~= "xy";
            SharedBuffer!(char, 8) other;
            other ~= "z";
            note = other;
            ints.put(1);
            ints ~= 2;
            fixed.assign("ok");
            fixed.clear();
        }

        // A copy taken from a `scope` buffer: the copy constructors declare
        // their source `scope`, since a shared block is refcounted rather
        // than borrowed, so the copy is not tied to the source's lifetime.
        SharedBuffer!(char, 8) copyOfNote() scope @safe => note;
        SharedBuffer!(char, 8) assignedNote() scope @safe
        {
            SharedBuffer!(char, 8) copy;
            copy = note;
            return copy;
        }
    }

    Holder h;
    h.fill();
    assert(h.note[] == "z");
    assert(h.copyOfNote()[] == "z");
    assert(h.assignedNote()[] == "z");
    static immutable int[2] want = [1, 2];
    assert(h.ints[] == want[]);
    assert(h.fixed.length == 0);
}
