/**
Sole-ownership heap values: $(LREF Unique) and $(LREF makeUnique).

A `Unique!(T, Allocator)` owns one heap-allocated `T` — a struct, a scalar, or
a class instance: it allocates and constructs through the allocator, hands out
borrowed access, and destroys plus deallocates exactly once, at scope exit.
Copying is `@disable`d, so the type $(I is) the ownership proof — there is no
second owner to free the block, and no `dispose` call for a caller to forget
on an early return.

Two properties make it usable where `new` is not:

$(UL
    $(LI $(B off the collected heap.) The default allocator is `Mallocator`,
    so a multi-megabyte value costs no GC block and triggers no collection —
    which matters on threads with small stacks, and in code under an
    allocation budget.)
    $(LI $(B still scanned, when it must be.) A value that holds pointers or
    slices into GC memory keeps them alive: the block is registered as a
    collector root range for as long as this owner holds it, and — because
    the block is initialized and registered $(I before) the constructor runs —
    references the constructor itself stores are covered too.)
)

$(B What this type does not do.) It gives ownership, not borrow-checking.
`get`, `*`, and `ptr` are marked `return scope`, but `dip1000` only enforces
that against a `scope` owner, so `@safe` code can still take a reference and
outlive it. Treat borrowed references the way you would treat those from any
container: do not store them past the owner's lifetime.

For a growable sequence use `sparkles.base.smallbuffer.SmallBuffer` (its
`unique` mode is the move-only, sole-owner variant of the same idea); `Unique`
is for a single value whose address must be stable.

See_Also:
    $(LINK2 https://dlang.org/phobos/std_experimental_allocator.html, `std.experimental.allocator`),
    the repository's $(I Composable Memory Allocators) guideline.
*/
module sparkles.base.unique;

import std.experimental.allocator.gc_allocator : GCAllocator;
import std.experimental.allocator.mallocator : Mallocator;
import std.traits : classInstanceAlignment, hasElaborateDestructor,
    hasIndirections;

///
@safe unittest
{
    struct Node
    {
        int value;
        string label; // a GC reference — the block is rooted for it
    }

    auto node = makeUnique!Node(42, "answer");
    assert(!node.empty);
    assert(node.get.value == 42); // borrowed access
    assert((*node).label == "answer");

    auto moved = node.move(); // ownership transfers; the source empties
    assert(node.empty);
    assert(moved.get.value == 42);
} // `moved` destroys and frees the value here

/**
Whether an allocator's blocks are already scanned by the collector.

`GCAllocator` is recognized directly; any other allocator can opt in by
declaring `enum bool collectorScanned = true;` — a wrapper around the
collector's own allocator is the case that needs it, since it cannot be
recognized by type.

Params:
    Allocator = the allocator type to probe

Returns: `true` when blocks from `Allocator` are collector-managed, so
    $(LREF Unique) must not register a root range over them.
*/
template isCollectorScanned(Allocator)
{
    // Not one `||` expression: `&&` short-circuits at evaluation, but both
    // operands are still analysed, so naming `Allocator.collectorScanned`
    // would be an error for every allocator that does not declare it.
    static if (is(Allocator == GCAllocator))
        enum bool isCollectorScanned = true;
    else static if (__traits(hasMember, Allocator, "collectorScanned"))
        enum bool isCollectorScanned = Allocator.collectorScanned;
    else
        enum bool isCollectorScanned = false;
}

/**
Whether $(LREF Unique) registers its block with the collector by default.

`true` when `T` can hold references (`hasIndirections`, which is always the
case for a class instance) and the allocator is not itself collector-scanned.
Registering a root over collector-managed memory is redundant book-keeping,
and makes it ambiguous who owns the un-registration.

The trait sees types, not intent: a `T` that stores a GC pointer as a
`size_t` is not detected. Pass $(LREF Unique)'s `rootInCollector` argument (or
$(LREF makeUnique)'s) explicitly for those.

Params:
    T = the owned value's type
    Allocator = the allocator type the block comes from

Returns: the default for `Unique`'s and `makeUnique`'s `rootInCollector`.
*/
enum bool needsCollectorRoot(T, Allocator) =
    hasIndirections!T && !isCollectorScanned!Allocator;

/**
A sole owner of one heap-allocated `T`.

Construct with $(LREF makeUnique); the destructor destroys and frees the
value. Copying is `@disable`d — transfer ownership with $(LREF Unique.move)
(or `core.lifetime.move`), which is what lets the type guarantee that exactly
one owner ever frees the block.

`T` may be a struct, a scalar, a static array, or a $(B class). For a class
the owner holds the reference itself and the block is the class instance, so
`Unique!C` is a class instance that lives outside the collected heap while
still being scanned; `get` yields the reference rather than a `ref`.

$(B Attributes infer) on everything that touches `T` or the allocator, so an
owner is exactly as `pure`/`nothrow`/`@nogc`/`@safe` as they are:
`Unique!(Point, Mallocator)` works from `@safe pure nothrow @nogc` code, while
a `T` whose destructor allocates simply propagates that. The accessors that
only read the handle are annotated directly — those attributes are intrinsic.

$(B Equality is identity.) `==` compares handles, as the compiler-generated
comparison of the single field: two owners of equal values are $(I not) equal;
only an owner compared with itself is.

$(B Lifetime caveats), none of them specific to this type but all worth
stating: a `static`/`__gshared` owner never runs its destructor (D does not
destruct globals), an owner inside an associative array is not destroyed when
the array is collected, and `Unique[]` cannot be appended to (array append
needs a copy). `const`/`immutable` owners destruct correctly; `shared` ones
are not supported.

Params:
    T = the owned value's type. Interfaces are excluded — there is nothing to
        construct, and the interface pointer is not the allocation's address.
    Allocator = a stateless allocator (one exposing `instance`), used for both
        the allocation and the matching deallocation. When `T.alignof` exceeds
        the allocator's `alignment`, the allocator must also offer
        `alignedAllocate`.
    rootInCollector = whether to register the block as a collector root range
        while it is owned. Defaults to $(LREF needsCollectorRoot).
*/
struct Unique(T, Allocator = Mallocator,
    bool rootInCollector = needsCollectorRoot!(T, Allocator))
if (isUniqueTarget!(T, Allocator))
{
    private Handle!T handle;

    // ─────────────────────────────────────────────────────────────────────
    // ownership: move-only, by disabled copy construction (not a postblit)
    // ─────────────────────────────────────────────────────────────────────

    /**
    Sole ownership: there is no copy, only a transfer.

    Disabling the copy $(I constructor) — rather than a postblit — is what
    also disables copy-assignment (which needs to copy-construct its source)
    while leaving move-assignment from an rvalue working, so
    `owner = makeUnique!T(…)` still replaces the owned value.
    */
    @disable this(ref inout typeof(this));

    /// Destroys and frees the owned value, if any.
    ~this()
    {
        reset();
    }

    // ─────────────────────────────────────────────────────────────────────
    // observation and borrowing — handle reads only, so the attributes here
    // are intrinsic rather than inferred
    // ─────────────────────────────────────────────────────────────────────

    @safe pure nothrow @nogc
    {
        /// Returns: whether this owner holds nothing — after `move`,
        /// `release`, or `reset`, and when `makeUnique` could not allocate.
        bool empty() const => handle is null;

        /// Returns: whether this owner holds a value (`empty`'s negation, for
        /// `if (owner)`).
        bool opCast(B : bool)() const => handle !is null;

        /**
        The owned value, borrowed: a `ref` to it, or — for a class — the
        reference itself.

        `*owner` is the same accessor. Both borrow: the result stays valid
        only while this owner holds the value (see the module's note on what
        `return scope` does and does not enforce here).

        Returns: the owned value.
        */
        static if (is(T == class))
            inout(T) get() inout return scope
            in (handle !is null, "borrowing from an empty Unique")
                => handle;
        else
            ref inout(T) get() inout return scope
            in (handle !is null, "borrowing from an empty Unique")
                => *handle;

        /// ditto
        auto ref inout(T) opUnary(string op : "*")() inout return scope
            => get();

        /**
        The handle without the non-empty precondition: the address of the
        owned value, or the class reference — `null` when empty.

        Returns: a borrowed handle; use $(LREF Unique.release) to transfer.
        */
        inout(Handle!T) ptr() inout return scope => handle;
    }

    // ─────────────────────────────────────────────────────────────────────
    // transfer and teardown
    // ─────────────────────────────────────────────────────────────────────

    /**
    Transfers ownership to the returned owner and empties this one.

    The moved-from owner is left `empty`, so its destructor is a no-op — the
    destroy-reset contract every move in D owes its source.

    Returns: the new sole owner of the value.
    */
    typeof(this) move()
    {
        typeof(this) result;
        result.handle = handle;
        handle = null;
        return result;
    }

    /**
    Relinquishes ownership without destroying: returns the handle and empties
    this owner.

    `@system`, and unavoidably so: the caller inherits both obligations this
    type was keeping — freeing the block through the same allocator, and, when
    `rootInCollector` is `true`, keeping the references inside it reachable.
    The root range is dropped here, and re-registering it (`GC.addRange`) is
    itself `@system`, so `@safe` code could not discharge what this hands it.

    Returns: the handle, now unowned and unrooted.
    */
    Handle!T release() @system
    {
        auto released = handle;
        handle = null;
        static if (rootInCollector)
            if (released !is null)
                pureGcRemoveRange(cast(const void*) released);
        return released;
    }

    /**
    Destroys and frees the owned value now, leaving this owner empty.

    Idempotent, and safe to call from the owned value's own reach: the handle
    is cleared before the value's destructor runs, so an owner observed during
    destruction looks empty rather than half-destroyed.

    The three steps are ordered deliberately. `T`'s destructor runs $(I while)
    the block is still a collector root, since it may read the references it
    owns; the root is dropped next; the memory is released last. Dropping the
    root earlier would let a collection during the destructor reclaim what it
    is still reading, and dropping it after the free would leave the collector
    scanning memory the allocator has taken back.
    */
    void reset()
    {
        if (handle is null)
            return;
        auto owned = handle;
        handle = null;
        auto address = () @trusted { return cast(void*) owned; }();
        static if (is(T == class))
        {
            debug
            {
                const dynamicSize = (() @trusted
                    => typeid(cast(Object) owned).initializer.length)();
                assert(dynamicSize == blockSize!T,
                    "a Unique block holds an instance of a different class");
            }
            // Finalizing a class instance goes through druntime's `rt_finalize`
            // hook, which is `@system` for every class. Sole ownership is what
            // makes it trustworthy here — the instance is fully constructed,
            // this is the only handle to it, and it is about to be freed — so
            // the only unsafety left to launder would be the class's own
            // destructor, and a `@system` one keeps its attribute.
            static if (hasSafeFinalizer!T)
                () @trusted { destroy!false(owned); }();
            else
                destroy!false(owned);
        }
        else static if (hasElaborateDestructor!T)
            destroy!false(*owned);
        () @trusted {
            releaseBlock!(T, Allocator, rootInCollector)(
                address[0 .. blockSize!T]);
        }();
    }
}

/**
Allocates a `T` from `Allocator` and returns its sole owner.

`args` are forwarded to `T`'s constructor; with no argument the value is
`T.init` — which requires `T` to be default-constructible, so a `T` with
`@disable this()` must be given constructor arguments.

$(B Allocation failure is a value, not a throw.) An allocator that cannot
satisfy the request yields an `empty` owner — the shape `@nogc` callers can
handle. (`GCAllocator` is the exception: it throws `OutOfMemoryError` before
this function sees a null block.) A constructor that throws frees the block
and lets the exception out.

$(B On `@safe`.) The allocation and the emplacement are the unsafe steps, and
they are vouched for here only when `new T(args)` would itself have compiled
in `@safe` code — the language's own verdict on building this value from
these arguments. A `T` whose construction is `@system` keeps that attribute,
and its caller must be `@system` too.

$(B The gap this cannot close.) `new Borrower(&local)` is rejected in `@safe`
code — `dip1000` sees a stack address stored into a heap value — but
`makeUnique!Borrower(&local)` is $(I not): the check is a caller-side
consequence of how the callee's parameters are inferred, and the inference
does not reach through a variadic `auto ref` template parameter list (LDC
1.41 / frontend 2.111; three different formulations of the store were tried).
Passing an argument that a heap value must not outlive is therefore the
caller's judgement here, exactly as it is for any container that stores what
it is handed.

Params:
    T = the value type to allocate
    Allocator = a stateless allocator (one exposing `instance`)
    rootInCollector = whether to register the block as a collector root range
        (defaults to $(LREF needsCollectorRoot))
    args = constructor arguments for `T`

Returns: an owner of the new value, or an `empty` owner if allocation failed.
*/
auto makeUnique(T, Allocator = Mallocator,
    bool rootInCollector = needsCollectorRoot!(T, Allocator), Args...)(
    auto ref Args args)
if (isUniqueTarget!(T, Allocator))
{
    import core.lifetime : forward;

    Unique!(T, Allocator, rootInCollector) result;

    auto storage = () @trusted { return allocateBlock!(T, Allocator)(); }();
    if (storage is null)
        return result;

    // Initialize and root the block *before* constructing into it. A
    // constructor that allocates can trigger a collection, and one that
    // stores a reference into the value publishes it mid-construction; with
    // the range registered afterwards, both are invisible to the collector
    // for exactly as long as the constructor runs.
    () @trusted {
        auto bytes = cast(ubyte[]) storage;
        // `initSymbol` reports an all-zero initializer as a *null* pointer
        // with the type's length — the pointer, not the length, is what says
        // whether there are bytes to copy.
        const initializer = cast(const(ubyte)[]) __traits(initSymbol, T);
        if (initializer.ptr !is null)
            bytes[] = initializer[];
        else
            bytes[] = 0;
        static if (rootInCollector)
            pureGcAddRange(storage.ptr, storage.length, typeid(T));
    }();
    scope (failure)
        () @trusted {
            releaseBlock!(T, Allocator, rootInCollector)(storage);
        }();

    // Emplacement, not assignment: assigning over the initialized block would
    // run `T`'s destructor on a value no constructor ever built.
    //
    // `new T(args)` is the compile-time stand-in for "may `@safe` code build
    // this value from these arguments?" — the language's own verdict, asked
    // with `__traits(compiles)` and never called. It gates the `@trusted`
    // wrapper: a `T` that cannot be constructed safely keeps its attribute
    // and forces its caller to be `@system`.
    static if (__traits(compiles, () @safe { auto probe = new T(forward!args); }))
        result.handle = () @trusted {
            return constructBlock!T(storage, forward!args);
        }();
    else
        result.handle = constructBlock!T(storage, forward!args);
    return result;
}

/**
Whether `T` can be owned by a $(LREF Unique) drawing from `Allocator`.

Params:
    T = the candidate value type
    Allocator = the candidate allocator type

Returns: `true` when `T` is not an interface and `Allocator` is stateless.
*/
enum bool isUniqueTarget(T, Allocator) =
    !is(T == interface) && is(typeof(Allocator.instance));

/// The owner's stored handle: a class reference, or a pointer to the value.
private template Handle(T)
{
    static if (is(T == class))
        alias Handle = T;
    else
        alias Handle = T*;
}

// The block a `T` needs. For a class this is the instance size, and it is
// exact rather than merely sufficient: `makeUnique!T` constructs a `T` and
// there is no upcast that could leave a `Unique!Base` holding a `Derived`,
// so the static size always matches the dynamic one (`reset` asserts it in
// a `debug` build).
// Whether finalizing a `T` instance would have been `@safe` if druntime's
// hook were not `@system`: a class with no destructor anywhere in its
// hierarchy has no `__xdtor`, and one that has it is asked directly.
private enum bool hasSafeFinalizer(T) =
    !__traits(hasMember, T, "__xdtor")
    || __traits(compiles, () @safe { T instance; instance.__xdtor(); });

private template blockSize(T)
{
    static if (is(T == class))
        enum size_t blockSize = __traits(classInstanceSize, T);
    else
        enum size_t blockSize = T.sizeof;
}

private template blockAlignment(T)
{
    static if (is(T == class))
        enum size_t blockAlignment = classInstanceAlignment!T;
    else
        enum size_t blockAlignment = T.alignof;
}

private void[] allocateBlock(T, Allocator)() @system
{
    static if (blockAlignment!T > Allocator.alignment)
    {
        static assert(__traits(hasMember, Allocator, "alignedAllocate"),
            "`" ~ T.stringof ~ "` needs " ~ blockAlignment!T.stringof
            ~ "-byte alignment, which `" ~ Allocator.stringof
            ~ "` cannot provide: it has no `alignedAllocate`.");
        return Allocator.instance.alignedAllocate(blockSize!T,
            blockAlignment!T);
    }
    else
        return Allocator.instance.allocate(blockSize!T);
}

private auto constructBlock(T, Args...)(void[] storage, auto ref Args args)
    @system
{
    import core.lifetime : emplace, forward;

    static if (is(T == class))
        return emplace!T(storage, forward!args);
    else
        return emplace(cast(T*) storage.ptr, forward!args);
}

// Drops the root range, then returns the exact block that was allocated —
// the same slice, so an allocator that validates the size back stays happy.
private void releaseBlock(T, Allocator, bool rootInCollector)(void[] storage)
    @system
{
    static if (rootInCollector)
        pureGcRemoveRange(storage.ptr);
    Allocator.instance.deallocate(storage);
}

/*
druntime's collector-root entry points, redeclared `pure`.

`core.memory.GC.addRange`/`removeRange` are `nothrow @nogc` but not `pure`,
while `Unique`'s operations infer `pure` for a `pure` `T` — the same problem
`sparkles.base.smallbuffer` solves the same way, and for the same reason:
registering a root changes only whether the collector may reclaim memory,
which no pure computation observes.

$(B Declared, not cast.) A function pointer cast to `pure` and called for its
side effect alone may be deleted outright — a strongly-pure `void` call has no
observable effect by definition, and dmd does elide it. An `extern (C)`
declaration is emitted as a call.

Unlike smallbuffer's array blocks, a `Unique` block holds exactly one value,
so its `TypeInfo` describes the whole range: `typeid(T)` is passed rather than
`null`, which a precise collector can use.
*/
extern (C) private pure nothrow @nogc @system
{
    pragma(mangle, "gc_addRange") void pureGcAddRange(const void* p, size_t sz,
        const TypeInfo ti);
    pragma(mangle, "gc_removeRange") void pureGcRemoveRange(const void* p);
}

@("unique.reset.ownsAndFreesExactlyOnce")
@safe unittest
{
    static int liveCount;
    static struct Counted
    {
        int value;
        this(int value) @safe nothrow @nogc
        {
            this.value = value;
            ++liveCount;
        }
        ~this() @safe nothrow @nogc { --liveCount; }
    }

    {
        auto owner = makeUnique!Counted(7);
        assert(liveCount == 1);
        assert(owner.get.value == 7);
        assert((*owner).value == 7);
        assert(owner.ptr.value == 7);
    }
    assert(liveCount == 0, "the destructor freed the value exactly once");

    // `reset` is the same teardown, on demand and idempotent.
    auto owner = makeUnique!Counted(1);
    owner.reset();
    assert(liveCount == 0 && owner.empty);
    owner.reset();
    assert(liveCount == 0);
}

@("unique.makeUnique.isAllocationFreeAndAttributeClean")
@safe pure nothrow @nogc unittest
{
    static struct Point { int x, y; }

    auto point = makeUnique!Point(3, 4);
    assert(!point.empty && point.get.x == 3 && point.get.y == 4);
    assert(cast(bool) point);

    // Big values are the point of the type: this one touches neither the
    // caller's stack nor the collected heap.
    static struct Slab { ubyte[512 * 1_024] bytes; }

    auto slab = makeUnique!Slab();
    assert(!slab.empty);
    slab.get.bytes[0] = 9;
    assert(slab.get.bytes[0] == 9);
}

@("unique.move.transfersSoleOwnership")
@safe unittest
{
    import core.lifetime : move;

    static int liveCount;
    static struct Counted
    {
        int value;
        ~this() @safe nothrow @nogc { if (value) --liveCount; }
    }

    auto first = makeUnique!Counted(5);
    ++liveCount;
    auto second = first.move();
    assert(first.empty, "a moved-from owner destroys nothing");
    assert(second.get.value == 5 && liveCount == 1);

    // `core.lifetime.move` is the same transfer through the druntime API.
    auto third = move(second);
    assert(second.empty && third.get.value == 5 && liveCount == 1);

    // Move-assignment onto a live owner destroys what it replaces.
    third = makeUnique!Counted(6);
    ++liveCount;
    assert(third.get.value == 6 && liveCount == 1);

    // Copying is not merely discouraged, it does not compile — and the type
    // reports as move-only rather than as a postblit type.
    static assert(!__traits(compiles, {
        auto owner = makeUnique!Counted(1);
        auto copy = owner;
    }));
    static assert(!__traits(hasPostblit, Unique!Counted));
    static assert(!__traits(isCopyable, Unique!Counted));
}

@("unique.release.handsOverTheBlockAndItsRoot")
@system unittest
{
    import core.memory : GC;

    // A `T` with indirections, so the rooted path is the one exercised.
    static struct Held { string[] items; }
    static assert(needsCollectorRoot!(Held, Mallocator));

    auto owner = makeUnique!Held();
    owner.get.items = ["a", "b"];
    auto raw = owner.release();
    assert(owner.empty && raw !is null);
    assert(raw.items == ["a", "b"]);

    // `release` dropped the root, so the new owner must re-register it (this
    // is exactly why `release` is `@system`).
    GC.addRange(raw, Held.sizeof);
    GC.collect();
    assert(raw.items == ["a", "b"]);
    GC.removeRange(raw);
    Mallocator.instance.deallocate((cast(void*) raw)[0 .. Held.sizeof]);
}

@("unique.rootInCollector.keepsReferencesAliveAcrossCollections")
@system unittest
{
    import core.memory : GC;
    import std.conv : text;

    // Distinct heap-allocated contents, then real churn: a dangling pointer
    // into intact memory would compare equal and let the bug pass, which is
    // why the payload is rebuilt and compared by content (the shape
    // `SmallBuffer.indirections.heapElementsSurviveCollection` uses).
    static struct Held
    {
        string[] items;
        this(size_t count) @safe
        {
            foreach (i; 0 .. count)
                items ~= text("unique-payload-", i);
            GC.collect(); // mid-construction: the block must already be rooted
            foreach (i; 0 .. count)
                items ~= text("unique-tail-", i);
        }
    }

    auto owner = makeUnique!Held(64);
    GC.collect();
    foreach (i; 0 .. 4096)
    {
        auto churn = text("churn-", i);
        assert(churn.length);
    }

    size_t corrupted;
    foreach (i, item; owner.get.items)
    {
        const expected = i < 64 ? text("unique-payload-", i)
            : text("unique-tail-", i - 64);
        if (item != expected)
            ++corrupted;
    }
    assert(corrupted == 0, "the collector saw every reference the value owns");
}

@("unique.needsCollectorRoot.followsTheAllocatorAndTheType")
@safe unittest
{
    static struct Held { int[] numbers; }
    static struct Plain { int number; }

    static assert(needsCollectorRoot!(Held, Mallocator));
    static assert(!needsCollectorRoot!(Held, GCAllocator),
        "a collector block is scanned already");
    static assert(!needsCollectorRoot!(Plain, Mallocator),
        "no indirections, nothing to keep alive");

    // An allocator can declare itself collector-scanned.
    static struct WrappedGC
    {
        enum bool collectorScanned = true;
        enum uint alignment = GCAllocator.alignment;
        static shared WrappedGC instance;
        void[] allocate(size_t n) shared nothrow
            => GCAllocator.instance.allocate(n);
        bool deallocate(void[] b) shared nothrow
            => GCAllocator.instance.deallocate(b);
    }
    static assert(isCollectorScanned!WrappedGC);
    static assert(!needsCollectorRoot!(Held, WrappedGC));

    // The collector's own allocator still works, unrooted and unrejected.
    auto held = makeUnique!(Held, GCAllocator)();
    held.get.numbers = [4, 5];
    assert(held.get.numbers == [4, 5]);
}

@("unique.class.ownsAnInstanceOffTheCollectedHeap")
@safe unittest
{
    static int liveCount;
    static class Widget
    {
        int size;
        string name;
        this(int size, string name) @safe nothrow @nogc
        {
            this.size = size;
            this.name = name;
            ++liveCount;
        }
        ~this() @safe nothrow @nogc { --liveCount; }
    }

    {
        auto widget = makeUnique!Widget(3, "dial");
        assert(liveCount == 1);
        assert(widget.get.size == 3 && widget.get.name == "dial");
        // For a class the handle *is* the reference.
        static assert(is(typeof(widget.ptr()) == Widget));
        assert(widget.ptr is widget.get);

        auto moved = widget.move();
        assert(widget.empty && moved.get.size == 3);
    }
    assert(liveCount == 0, "the class destructor ran exactly once");

    // An interface has nothing to construct and its pointer is not the
    // allocation's address, so it is rejected outright.
    static assert(!__traits(compiles, Unique!(Widgety, Mallocator)));
}

version (unittest) private interface Widgety { int size(); }

@("unique.makeUnique.refusedAllocationYieldsAnEmptyOwner")
@safe pure nothrow @nogc unittest
{
    import std.experimental.allocator.building_blocks.null_allocator
        : NullAllocator;

    static struct Payload { ubyte[16] bytes; }

    auto owner = makeUnique!(Payload, NullAllocator)();
    assert(owner.empty, "a refused allocation is an empty owner, not a crash");
    assert(!cast(bool) owner);
}

@("unique.makeUnique.throwingConstructorFreesTheBlock")
@safe unittest
{
    static struct Fragile
    {
        this(bool explode) @safe
        {
            if (explode)
                throw new Exception("constructor failed");
        }
    }

    bool caught;
    try
        cast(void) makeUnique!Fragile(true);
    catch (Exception)
        caught = true;
    assert(caught, "the constructor's exception reaches the caller");

    // The happy path still works after the failed one (nothing was leaked
    // into an inconsistent allocator state).
    auto owner = makeUnique!Fragile(false);
    assert(!owner.empty);
}

@("unique.makeUnique.doesNotInheritNewsArgumentEscapeCheck")
@safe unittest
{
    static struct Borrower
    {
        int* pointer;
        this(int* pointer) @safe { this.pointer = pointer; }
    }

    // This test records a known gap rather than a guarantee (see
    // `makeUnique`'s documentation). At function scope `new Borrower(&local)`
    // is rejected — "assigning reference to local variable `local` to
    // non-scope parameter" — while `makeUnique!Borrower(&local)` compiles,
    // because dip1000's caller-side check does not reach through a variadic
    // `auto ref` parameter list. If a future frontend closes that gap this
    // assert flips, and the documentation (and this test) should be updated
    // to promise the check.
    static assert(__traits(compiles, () @safe {
        int local;
        auto escaped = makeUnique!Borrower(&local);
        return escaped;
    }));

    // A heap-allocated argument is fine, and is the intended usage.
    auto pointer = new int(3);
    auto owner = makeUnique!Borrower(pointer);
    assert(*owner.get.pointer == 3);
}

@("unique.allocateBlock.demandsAlignmentTheAllocatorCanProvide")
@safe unittest
{
    import std.experimental.allocator.mallocator : AlignedMallocator;

    align(64) static struct Wide { float[16] values; }
    static assert(Wide.alignof == 64);

    // `Mallocator` guarantees only 16, so the over-aligned type is a compile
    // error there rather than a silently misaligned block.
    static assert(!__traits(compiles, makeUnique!(Wide, Mallocator)()));

    auto wide = makeUnique!(Wide, AlignedMallocator)();
    assert(!wide.empty);
    assert((() @trusted => cast(size_t) wide.ptr % 64)() == 0);
}
