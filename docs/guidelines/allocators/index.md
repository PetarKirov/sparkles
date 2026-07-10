# Composable Memory Allocators (`std.experimental.allocator`)

Phobos' [`std.experimental.allocator`][alloc-docs] is D's composable,
capability-driven memory-allocation framework — and the canonical large-scale
application of the [Design by Introspection](../design-by-introspection-01-guidelines.md)
style sparkles follows: every allocator advertises its capabilities **by which
methods it defines**, and everything above it detects those capabilities
statically and adapts. This guideline is organized by use case first — pick
your entry point in [§1](#_1-which-api-layer-do-i-need) — followed by a full
technical survey of the package. Every behaviour shown is demonstrated by a
runnable example that CI compiles, runs, and diffs against the printed output.

<details>
<summary><strong>Grounding, versions & stability caveats</strong></summary>

All quotes and claims in this document are cited to the Phobos sources as
`std/experimental/allocator/<file>:<line>`, pinned at phobos commit
`6be6c3809` (July 2026). The runnable snippets are verified by
`ci --verify --files docs/guidelines/allocators/index.md` against the repo
toolchain (LDC 1.41, DMD 2.111 frontend).

The package has lived in `std.experimental` since 2015 (DMD 2.069) and is
Phobos' most battle-tested "experimental" module — but the _experimental_
label is real:

- Parts of the documentation lag the code: the docs still say `theAllocator`
  is an [`IAllocator`][IAllocator]; it is actually an
  [`RCIAllocator`][RCIAllocator].
- The mid-level `typed` module has two latent compile errors
  ([§20](#_20-typedallocator-layer-2)).
- The API may still change before (if ever) leaving `std.experimental`.

The low-level building blocks and the `make`/`dispose` family are the stable,
widely-used core.

</details>

---

## Part I — Guidelines by use case

## 1. Which API layer do I need?

| You are writing …                                                            | Reach for                                                              | Start at                                                                                                                    |
| :--------------------------------------------------------------------------- | :--------------------------------------------------------------------- | :-------------------------------------------------------------------------------------------------------------------------- |
| application code that needs objects and arrays off a chosen allocator        | [`make`][make] / [`dispose`][dispose] / [`theAllocator`][theAllocator] | [§2](#_2-application-authors-make-dispose-and-friends), [§3](#_3-application-authors-theallocator-and-runtime-polymorphism) |
| a library that is allocation-conscious but generic over the allocator        | an `Allocator` template parameter + capability probing                 | [§4](#_4-generic-libraries-accept-any-allocator)                                                                            |
| performance-critical infrastructure — arenas, zero-copy network buffer pools | assembled building blocks                                              | [§5](#_5-high-performance-libraries-arenas-and-buffer-pools), [§18](#_18-case-study-a-jemalloc-style-composite)             |
| a manager for a foreign address space (GPU heaps, registered buffers)        | building blocks as host-side bookkeepers                               | [§6](#_6-showcase-sub-allocating-gpu-device-memory)                                                                         |
| your own allocator                                                           | the two-member static protocol                                         | [§8](#_8-the-static-allocator-protocol), [§21](#_21-writing-your-own-allocator)                                             |

Two doctrines from the package documentation frame everything below. First,
adoption is **opt-in and incremental**: the framework is not wired into `new`
or array literals (`package.d:125-128`), and the default allocator is the GC —
using `make`/`dispose` changes nothing until you deliberately install or pass
a different allocator. Second, the performance rule (`package.d:220-225`):

> "statically-typed assembled allocators are almost always faster than
> allocators that go through `IAllocator`. An important rule of thumb is:
> 'assemble allocator first, adapt to `IAllocator` after'."

---

## 2. Application authors: `make`, `dispose` and friends

These free functions accept _any_ allocator — a static building block, a
monostate `instance`, or an `RCIAllocator` handle — and bridge from untyped
`void[]` to typed objects. For most application code, they plus
[`theAllocator`][theAllocator] ([§3](#_3-application-authors-theallocator-and-runtime-polymorphism))
are the whole API.

### `make` — allocate + construct

`make!T(alloc, args)` (`package.d:1168-1216`) allocates
`max(stateSize!T, 1)` bytes and constructs a `T` in them; classes come back as
references, everything else as `T*`. Documented corner cases worth knowing:

- **Failure is `null`**, not a throw — allocation failure and construction are
  separate concerns.
- **A throwing constructor does not leak**: `scope (failure)` deallocates the
  fresh block before the exception propagates (`package.d:1199-1212`).
- **`make!(T[])` returns a _pointer to an empty array_** (`T[]*`), not an
  array — use `makeArray` for arrays (`package.d:1149-1151`).
- A zero-initialized `T` on an allocator defining the (undocumented, `package`)
  `allocateZeroed` primitive skips construction entirely (`package.d:1171-1177`).

### `dispose` — destroy + deallocate

`dispose(alloc, p)` (`package.d:2412-2460`) destroys and deallocates a pointer,
class/interface reference, or array. The class overload finds the block for the
**dynamic** type via `typeid(obj).initializer.length` (`package.d:2440`) — so
disposing a derived object through a base reference runs the full destructor
chain _and_ frees the correctly-sized block. The example proves both, using a
byte-counting allocator wrapper ([`StatsCollector`][StatsCollector],
[§17](#_17-metadata-and-instrumentation)) as witness:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "allocator_make_dispose"
+/
import std.stdio : writeln;
import std.experimental.allocator : make, dispose;
import std.experimental.allocator.mallocator : Mallocator;
import std.experimental.allocator.building_blocks.stats_collector
    : StatsCollector, Options;

class Base
{
    ~this() { writeln("~Base"); }
}

class Derived : Base
{
    long payload; // makes Derived strictly larger than Base
    ~this() { writeln("~Derived"); }
}

void main()
{
    StatsCollector!(Mallocator, Options.bytesUsed) a;

    Base obj = a.make!Derived;
    writeln("live bytes cover Derived: ",
        a.bytesUsed == __traits(classInstanceSize, Derived));

    a.dispose(obj); // dynamic type: runs ~Derived then ~Base ...
    writeln("all freed: ", a.bytesUsed == 0); // ... and frees Derived's block
}
```

```ansi
live bytes cover Derived: true
~Derived
~Base
all freed: true
```

### Attribute ceiling: how strict can `make`/`dispose` get?

`make`/`dispose` are templates, so — per the
[sparkles safety-attribute rule](../code-style.md) — their attributes are
_inferred_ from whatever allocator they're instantiated with, never forced.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "allocator_make_dispose_attributes"
    dependency "sparkles:base" version="*"
+/
import std.stdio : writeln;
import std.experimental.allocator : make, dispose;
import std.experimental.allocator.mallocator : Mallocator;
import std.experimental.allocator.gc_allocator : GCAllocator;
import sparkles.base.prettyprint : prettyPrint;
import std.traits : hasElaborateDestructor;

struct Point
{
    int x, y;
}

// Mallocator's allocate/deallocate are both @nogc -- only @safe is out of
// reach (deallocate slices a raw pointer, so dispose can't infer @safe).
@safe pure nothrow @nogc
Unique!(Point, Mallocator) makeWithMallocator()
    => Unique!(Point, Mallocator)(1, 2);

// GCAllocator's allocate goes through GC.malloc, which isn't @nogc -- same
// ceiling as Mallocator, minus @nogc.
@safe pure nothrow
Unique!(Point, GCAllocator) makeWithGCAllocator()
    => Unique!(Point, GCAllocator)(3, 4);

@safe
void main()
{
    auto p = makeWithMallocator();
    auto q = makeWithGCAllocator();
    writeln(prettyPrint(*p));
    writeln(prettyPrint(*q));
}

// A small inline Unique(T, Allocator) RAII helper to avoid use-after-free
struct Unique(T, Allocator)
{
    private T* _ptr;

    this(Args...)(auto ref Args args)
    if (__traits(compiles, Allocator.instance.make!T(args)))
    {
        enum bool isConstructionSafe = __traits(compiles, (Args x) @safe => T(x));

        static if (isConstructionSafe)
            () @trusted { _ptr = Allocator.instance.make!T(args); }();
        else
            _ptr = Allocator.instance.make!T(args);
    }

    ~this()
    {
        if (_ptr)
        {
            enum bool isDestructionSafe = !hasElaborateDestructor!T || __traits(compiles, (T x) @safe => destroy(x));

            static if (isDestructionSafe)
                () @trusted { Allocator.instance.dispose(_ptr); }();
            else
                Allocator.instance.dispose(_ptr);
            _ptr = null;
        }
    }

    // Disable copying
    @disable this(this);

    @safe pure nothrow @nogc
    ref inout(T) opUnary(string op : "*")() inout => *_ptr;
}
```

```ansi
[35mPoint[39m([96mx[39m: [34m1[39m, [96my[39m: [34m2[39m)
[35mPoint[39m([96mx[39m: [34m3[39m, [96my[39m: [34m4[39m)
```

> [!WARNING]
> **Neither allocator reaches `@safe` directly.** Both allocators' `deallocate` is
> `@system`, and `dispose` reinterprets the incoming `T*` back to a `void[]`
> via a raw pointer slice (`package.d:2418`) — that slicing is not
> `@safe`-inferrable, regardless of which allocator it's instantiated with.
> To reach `@safe` in the helpers, their system operations are encapsulated
> within the `@trusted` constructor/destructor of the `Unique` RAII wrapper.

### `makeArray` — four overloads, three init strategies

`makeArray!T(alloc, length)` default-initializes; `makeArray!T(alloc, length,
init)` fills; `makeArray(alloc, range)` copies a range (with a
single-allocation fast path for forward ranges, and geometric `reallocate`
growth for input ranges — `package.d:1824-1928`). Plus
`makeMultidimensionalArray` for jagged nested arrays (`package.d:2549-2563`),
and `expandArray` / `shrinkArray` to resize in cooperation with the allocator:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "allocator_make_array"
+/
import std.stdio : writeln;
import std.range : only, iota;
import std.experimental.allocator
    : makeArray, expandArray, shrinkArray, dispose,
      makeMultidimensionalArray, disposeMultidimensionalArray;
import std.experimental.allocator.mallocator : Mallocator;

void main()
{
    alias alloc = Mallocator.instance;

    auto a = alloc.makeArray!int(3);              // default-init
    auto b = alloc.makeArray!int(3, 7);           // fill
    auto c = alloc.makeArray!int(iota(1, 5));     // from a range
    writeln(a, " ", b, " ", c);

    // default init is T.init — for char that is 0xFF, NOT '\0'!
    auto s = alloc.makeArray!char(3);
    writeln("char array bytes: ", cast(ubyte[]) s);

    // grow by 2 zeroes, then by a range, then shrink back
    alloc.expandArray(a, 2);
    alloc.expandArray(a, only(4, 5));
    writeln("expanded: ", a);
    alloc.shrinkArray(a, 4);
    writeln("shrunk:   ", a);

    auto grid = alloc.makeMultidimensionalArray!int(2, 3);
    grid[1][2] = 42;
    writeln("grid: ", grid);

    alloc.disposeMultidimensionalArray(grid);
    foreach (arr; [a, b, c]) alloc.dispose(arr);
    alloc.dispose(s);
}
```

```ansi
[0, 0, 0] [7, 7, 7] [1, 2, 3, 4]
char array bytes: [255, 255, 255]
expanded: [0, 0, 0, 0, 0, 4, 5]
shrunk:   [0, 0, 0]
grid: [[0, 0, 0], [0, 0, 42]]
```

> [!WARNING]
> Three traps in this family:
>
> 1. **`makeArray!char(n)` yields `0xFF` bytes** — default init copies `T.init`
>    and `char.init == 0xFF` (`package.d:1511-1517`). Use the fill overload
>    (`makeArray!char(alloc, n, ' ')`) when you need a blanked buffer.
> 2. **`expandArray` on a `null` array returns `false`** — a null slice cannot
>    be grown (`package.d:2153`); create with `makeArray` first.
> 3. The length-overflow check (`core.checkedint.mulu`) guards only the
>    default-init overload for `T.sizeof > 1` (`package.d:1590-1594`); the fill
>    and range overloads compute `T.sizeof * length` unchecked.

---

## 3. Application authors: `theAllocator` and runtime polymorphism

The dynamic layer erases a static allocator behind the [`IAllocator`][IAllocator]
(or `ISharedAllocator`) interface, managed by the reference-counted handle
structs [`RCIAllocator`][RCIAllocator] / `RCISharedAllocator`:

- [`processAllocator`][processAllocator] (`RCISharedAllocator`) — process-wide;
  lazily initialized to the **GC allocator** (`package.d:1070-1083`).
- [`theAllocator`][theAllocator] (`RCIAllocator`) — thread-local; defaults to a
  proxy that forwards every call to `processAllocator` (`package.d:912-1014`).
  So "default allocations" ultimately hit the GC — the framework is safe to
  adopt incrementally.
- [`allocatorObject(a)`][allocatorObject] wraps any static allocator into an
  `RCIAllocator` by emplacing a `CAllocatorImpl!A` class _inside memory
  allocated from `a` itself_; when the refcount drops to zero the wrapper
  deallocates its own footprint through the wrapped allocator
  (`package.d:3034-3064`).

At this boundary, missing capabilities become _documented fallback values_
instead of missing methods: `alignedAllocate` → `null`, `expand` → `false`
(unless `delta == 0`), `owns`/`empty`/`resolveInternalPointer` →
`Ternary.unknown`, `deallocate` → `false`. "A simple way to check that an
allocator supports deallocation is to call `deallocate(null)`"
(`package.d:371-377`).

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "allocator_the_allocator"
+/
import std.stdio : writeln;
import std.typecons : Ternary;
import std.experimental.allocator
    : allocatorObject, theAllocator, makeArray, dispose;
import std.experimental.allocator.mallocator : Mallocator;
import std.experimental.allocator.building_blocks.stats_collector
    : StatsCollector, Options;

void main()
{
    // Assemble first, adapt after: wrap an instrumented Mallocator. The
    // allocator is *stateful*, so pass it by pointer — allocatorObject moves
    // a by-value argument into the wrapper, leaving your copy in .init state.
    auto counted = StatsCollector!(Mallocator, Options.bytesUsed)();
    auto handle = allocatorObject(&counted);

    // The CAllocatorImpl wrapper class itself was just emplaced into memory
    // drawn from `counted` — the wrapper lives inside the allocator it wraps:
    const wrapperBytes = counted.bytesUsed;
    writeln("wrapper footprint charged to the allocator: ", wrapperBytes > 0);

    auto old = theAllocator;
    theAllocator = handle;
    scope (exit) theAllocator = old;

    auto xs = theAllocator.makeArray!long(10);
    writeln("bytes drawn through theAllocator: ", counted.bytesUsed - wrapperBytes);

    // Capability probing across the runtime boundary:
    writeln("supports deallocate: ", theAllocator.deallocate(null));
    writeln("owns is unsupported: ", theAllocator.owns(xs) == Ternary.unknown);

    theAllocator.dispose(xs);
    writeln("only the wrapper remains: ", counted.bytesUsed == wrapperBytes);
}
```

```ansi
wrapper footprint charged to the allocator: true
bytes drawn through theAllocator: 80
supports deallocate: true
owns is unsupported: true
only the wrapper remains: true
```

> [!IMPORTANT]
> **Set the globals rarely, and early.** Both setters are `@system` for a
> reason: "allocating memory with one allocator and deallocating with another
> causes undefined behavior. Typically, these variables are set during
> application initialization phase and last through the application"
> (`package.d:164-196`). Long-lived containers should _store_ the allocator
> they were built with rather than re-reading `theAllocator`.

> [!WARNING]
> `allocatorObject(a)` (by value) **moves** `a` into the wrapper
> (`package.d:2699-2707`) — your original variable is left in `.init` state.
> Pass a pointer (as above) to retain access, and always pass non-movable
> allocators (e.g. `InSituRegion`) by pointer. `sharedAllocatorObject` on a
> non-copyable stateful allocator is a hard `assert(0, "Not yet implemented")`
> (`package.d:2823`).

---

## 4. Generic libraries: accept any allocator

An allocation-conscious library should not choose an allocator — it should be
_generic_ over one, the way every combinator in the package is. The recipe:

- **Take the allocator as a template parameter** and rely on duck typing —
  anything with `alignment` + `allocate` qualifies, from `Mallocator.instance`
  to a seven-deep composite to an `RCIAllocator` handle chosen at runtime.
- **Embed state with the `stateSize` idiom** (`common.d:34-49`). A monostate
  allocator (`stateSize!A == 0`) is embedded as `alias alloc = A.instance` and
  costs **zero bytes**; a stateful one becomes a member. This is the idiom
  every Phobos building block uses internally:

  ```d
  static if (stateSize!Allocator) Allocator alloc;
  else alias alloc = Allocator.instance;
  ```

- **Probe optional capabilities with `__traits(hasMember, …)`** and adapt —
  use `expand` when the allocator has it, fall back to allocate-copy-deallocate
  when it doesn't. An absent method is _information_, not an error
  ([§8](#_8-the-static-allocator-protocol)).
- **Ask for `goodAllocSize`** before growing: the allocator was going to round
  your request up anyway; claiming the slack turns the next append into a
  no-op ([§10](#_10-heap-sources) shows the GC's step function).
- **Let attributes infer.** Exactly as the
  [sparkles attribute guidelines](../code-style.md) prescribe for templates:
  your type is as `@safe pure nothrow @nogc` as the allocator it is
  instantiated with — forcing attributes would reject legitimate allocators.
- **Store the allocator you were constructed with** and use it for the type's
  whole lifetime — never re-read `theAllocator` mid-life
  ([§3](#_3-application-authors-theallocator-and-runtime-polymorphism)).

All six rules in ~40 lines — a growable byte sink that is state-free over
monostate allocators, and grows _in place_ whenever the allocator can:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "allocator_generic_library"
+/
import std.stdio : writeln;
import std.experimental.allocator : goodAllocSize, stateSize;
import std.experimental.allocator.building_blocks.region : Region;
import std.experimental.allocator.mallocator : Mallocator;

/// A minimal growable byte sink, generic over its allocator — the shape an
/// allocation-conscious library type takes.
struct ByteSink(Allocator)
{
    // The standard state idiom: a stateless allocator costs zero bytes.
    static if (stateSize!Allocator)
        Allocator alloc;
    else
        alias alloc = Allocator.instance;

    private void[] store;
    private size_t used;

    // Attributes are deliberately inferred: the sink is exactly as @safe /
    // nothrow / @nogc as the allocator it is instantiated with.
    void put(scope const(ubyte)[] bytes)
    {
        reserve(used + bytes.length);
        () @trusted { (cast(ubyte[]) store)[used .. used + bytes.length] = bytes[]; }();
        used += bytes.length;
    }

    private void reserve(size_t need)
    {
        if (store.length >= need)
            return;
        // Claim the slack the allocator would round up to anyway ...
        const want = goodAllocSize(alloc,
            need > 2 * store.length ? need : 2 * store.length);
        // ... and grow in place when the allocator is *capable* of it:
        static if (__traits(hasMember, Allocator, "expand"))
            if (store.ptr !is null && alloc.expand(store, want - store.length))
                return;
        auto fresh = alloc.allocate(want);
        if (fresh is null)
            assert(0, "out of memory");
        () @trusted { (cast(ubyte[]) fresh)[0 .. used] = cast(ubyte[]) store[0 .. used]; }();
        static if (__traits(hasMember, Allocator, "deallocate"))
            alloc.deallocate(store);
        store = fresh;
    }
}

void main()
{
    // Monostate allocator: the sink carries no allocator state at all.
    ByteSink!Mallocator m;
    writeln("state-free over a monostate allocator: ",
        ByteSink!Mallocator.sizeof == (void[]).sizeof + size_t.sizeof);

    m.put(cast(const ubyte[]) "Hello, ");
    auto before = m.store.ptr;
    foreach (i; 0 .. 10)
        m.put(cast(const ubyte[]) "allocators! ");
    writeln("Mallocator sink moved while growing:  ", m.store.ptr !is before);
    writeln("content survives the moves: ", cast(const char[]) m.store[0 .. 18]);

    // Stateful allocator: the sink owns a Region member; its store is always
    // the region's most recent allocation, so expand always works in place.
    auto r = ByteSink!(Region!Mallocator)(Region!Mallocator(1024 * 1024));
    r.put(cast(const ubyte[]) "Hello, ");
    before = r.store.ptr;
    foreach (i; 0 .. 10)
        r.put(cast(const ubyte[]) "allocators! ");
    writeln("Region sink grew in place via expand: ", r.store.ptr is before);
}
```

```ansi
state-free over a monostate allocator: true
Mallocator sink moved while growing:  true
content survives the moves: Hello, allocators!
Region sink grew in place via expand: true
```

The same `ByteSink` instantiated over `Mallocator` is `@nogc`-capable and
moves when it grows; over a `Region` it never moves (a region can always
extend its most recent allocation, [§11](#_11-regions-bump-the-pointer-allocation));
over `GCAllocator` it would ride the GC's `expand`. The library wrote none of
that logic — it fell out of capability probing.

---

## 5. High-performance libraries: arenas and buffer pools

When a library owns a hot allocation pattern, it should assemble a specific
allocator for it instead of hitting a general-purpose heap. Two patterns cover
most of the ground: **arenas** (allocate fast, free everything at once) and
**pools** (recycle same-shaped buffers forever).

### Arenas: batch lifetime

For per-request / per-frame / per-parse lifetimes, bump allocation is
unbeatable — one pointer increment per allocation, one reset per batch:

- [`Region!Mallocator(size)`][Region] — one contiguous chunk, freed by its
  destructor; `deallocateAll` resets it for the next batch
  ([§11](#_11-regions-bump-the-pointer-allocation)).
- [`InSituRegion!(size)`][InSituRegion] — the arena _is_ the struct, typically
  on the stack; `StackFront` backs it with the GC for overflow
  ([§16](#_16-combinators-routing-requests)).
- `AllocatorList!(n => Region!Mallocator(max(n, chunk)))` — a **growable**
  arena: exhausting one region lazily spawns the next
  ([§16](#_16-combinators-routing-requests)); `mmapRegionList(bytes)` from
  [`showcase`][showcase] is the preassembled mmap-backed version.
- [`KRRegion`][KRRegion] — when the batch needs _occasional_ frees but you
  still want region speed ([§14](#_14-krregion-the-kernighan-ritchie-heap)).
- [`ScopedAllocator`][ScopedAllocator] — when individual objects need real
  `deallocate` but everything must die with the scope regardless
  ([§17](#_17-metadata-and-instrumentation)).

### Buffer pools: zero-copy networking

Network I/O wants the opposite lifetime shape: fixed-size buffers that
outlive scopes — a buffer handed to the kernel (an `io_uring` submission, a
registered-buffer send) must stay alive until the completion arrives, long
after the code that filled it returned. The building blocks compose into
exactly this:

- [`FreeList!(Parent, 0, bufSize)`][FreeList] makes acquire/release an O(1)
  pointer pop/push — no allocator round-trip per packet
  ([§12](#_12-free-lists)). [`SharedFreeList`][SharedFreeList] is the
  cross-thread variant for when completions land on another thread
  ([§19](#_19-sharing-memory-across-threads)).
- [`AffixAllocator!(…, uint)`][AffixAllocator] puts a **reference count
  inside each buffer's own allocation** — no side table, no GC — so ownership
  can be split between the application and in-flight kernel operations
  ([§17](#_17-metadata-and-instrumentation)).
- For `O_DIRECT` or `io_uring` registered buffers that must be page-aligned,
  draw the pool's backing memory from [`MmapAllocator`][MmapAllocator] or
  [`AscendingPageAllocator`][AscendingPageAllocator]
  ([§15](#_15-ascendingpageallocator-pages-monotonically)).

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "allocator_packet_pool"
+/
import std.stdio : writeln;
import std.experimental.allocator.building_blocks.affix_allocator : AffixAllocator;
import std.experimental.allocator.building_blocks.free_list : FreeList;
import std.experimental.allocator.mallocator : Mallocator;

enum packetSize = 64 * 1024;

/// Fixed-size recycled buffers with an intrusive refcount: the freelist
/// makes acquire/release O(1) pointer pops, the affix puts the refcount
/// *inside* the buffer's own allocation (no side table).
struct PacketPool
{
    alias A = AffixAllocator!(FreeList!(Mallocator, 0, packetSize), uint);
    private A impl;

    void[] acquire()
    {
        auto b = impl.allocate(packetSize);
        impl.prefix(b) = 1;
        return b;
    }

    void retain(void[] b) { ++impl.prefix(b); }

    void release(void[] b)
    {
        if (--impl.prefix(b) == 0)
            impl.deallocate(b); // back onto the freelist, not to malloc
    }

    uint refs(void[] b) => impl.prefix(b);
}

void main()
{
    PacketPool pool;

    auto p = pool.acquire();
    writeln("fresh packet: refs = ", pool.refs(p));

    // Zero-copy send: the kernel (or io_uring completion) holds a reference
    // while the app may already be done with the buffer.
    pool.retain(p);
    writeln("submitted to the kernel: refs = ", pool.refs(p));
    pool.release(p); // app drops its reference
    writeln("app released: refs = ", pool.refs(p));
    auto recycled = p.ptr;
    pool.release(p); // completion arrives -> refcount 0 -> recycled

    auto q = pool.acquire();
    writeln("next acquire reuses the same buffer: ", q.ptr is recycled);
}
```

```ansi
fresh packet: refs = 1
submitted to the kernel: refs = 2
app released: refs = 1
next acquire reuses the same buffer: true
```

For a general-purpose heap built from these same pieces — size-segregated
freelists in the style of jemalloc — see the case study in
[§18](#_18-case-study-a-jemalloc-style-composite).

---

## 6. Showcase: sub-allocating GPU device memory

The untyped protocol has a consequence that is easy to miss: because
allocators traffic in `(pointer, length)` pairs and several building blocks
**never dereference the memory they manage**, they can manage an address
space the host cannot touch at all — GPU device memory being the prime case.

Vulkan makes this necessary: implementations cap the number of live
`VkDeviceMemory` objects (`maxMemoryAllocationCount` is commonly 4096) and
driver allocations are expensive, so real engines allocate a few large heaps
and **sub-allocate**: each buffer or image is bound at an _offset_ into a heap
via `vkBindBufferMemory` / `vkBindImageMemory` (see the
[Vulkan memory-allocation guide][vk-memory]). The allocator's bookkeeping
must therefore live on the host — exactly the [`BitmappedBlock`][BitmappedBlock]
design, whose selling point is that "bookkeeping data [is] separated from the
payload … deallocation does not touch memory around the payload"
(`bitmapped_block.d:1166-1171`, [§13](#_13-bitmappedblock-fixed-blocks-one-bit-each)).

The trick: instantiate a `BitmappedBlock` over [`MmapAllocator`][MmapAllocator]
so its payload range is **plain virtual address space that is never read or
written** — `mmap` commits pages only on first touch, and `allocate` /
`deallocate` / `owns` only ever compute with the payload pointers. The only
host memory actually dirtied is the bitmap. A returned slice then _denotes_ a
device region: its length is the size, and `ptr - base` is the
`VkDeviceMemory` offset:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "allocator_device_pool"
+/
import std.stdio : writefln;
import std.experimental.allocator.building_blocks.bitmapped_block : BitmappedBlock;
import std.experimental.allocator.mmap_allocator : MmapAllocator;

enum blockSize = 64 * 1024;        // sub-allocation granularity we choose
enum heapSize = 32 * 1024 * 1024;  // one VkDeviceMemory allocation

void main()
{
    // Host-side bookkeeping for a 32 MB device heap: 512 blocks tracked by
    // a 64-byte bitmap; the payload range is never-touched virtual memory.
    auto pool = BitmappedBlock!(blockSize, 8, MmapAllocator)(heapSize);

    auto imageA = pool.allocate(1000 * 1024);
    const base = imageA.ptr; // empty pool + first fit -> offset 0
    auto imageB = pool.allocate(130 * 1024);
    auto imageC = pool.allocate(2000 * 1024);

    size_t offsetKB(void[] region) => (region.ptr - base) / 1024;

    // In real code: vkBindImageMemory(device, image, deviceMemory, offset)
    writefln("image A: offset %4d KB, size %4d KB", offsetKB(imageA), imageA.length / 1024);
    writefln("image B: offset %4d KB, size %4d KB", offsetKB(imageB), imageB.length / 1024);
    writefln("image C: offset %4d KB, size %4d KB", offsetKB(imageC), imageC.length / 1024);

    // Free B (say, a destroyed render target); its 3 blocks coalesce back.
    pool.deallocate(imageB);

    // A new 150 KB image is first-fit placed into B's hole.
    auto imageD = pool.allocate(150 * 1024);
    writefln("image D: offset %4d KB, size %4d KB  (reuses B's hole: %s)",
        offsetKB(imageD), imageD.length / 1024, imageD.ptr is imageB.ptr);
}
```

```ansi
image A: offset    0 KB, size 1000 KB
image B: offset 1024 KB, size  130 KB
image C: offset 1216 KB, size 2000 KB
image D: offset 1024 KB, size  150 KB  (reuses B's hole: true)
```

Mapping this onto a real renderer:

- **One pool per `VkDeviceMemory`** (per memory type); wrap the set in an
  [`AllocatorList`][AllocatorList] whose factory calls `vkAllocateMemory` for
  a fresh heap when the existing pools are full
  ([§16](#_16-combinators-routing-requests)) — the same growable-arena shape
  as host-side code.
- **Pick `blockSize` ≥ `bufferImageGranularity`** and the alignment
  requirements from `vkGetImageMemoryRequirements`; block-granular placement
  then satisfies them by construction.
- **Per-frame transient resources** don't need the bitmap at all: a
  `BorrowedRegion` over the same never-touched range gives bump-the-pointer
  offsets and a single `deallocateAll` at frame end
  ([§11](#_11-regions-bump-the-pointer-allocation)).

> [!WARNING]
> Only metadata-level primitives are usable on a foreign address space:
> `allocate`, `deallocate`, `deallocateAll`, `expand`, `owns`,
> `goodAllocSize`. **`reallocate` is off-limits** — on a move it `memcpy`s
> through the payload pointers (`bitmapped_block.d:704-751`), which here would
> dereference device "addresses" the host cannot touch. Likewise, nothing
> above the untyped layer (`make`, `makeArray`) makes sense for memory the
> CPU cannot write.

The same technique manages any foreign or offset-addressed space: sub-ranges
of `io_uring` registered buffers, shared-memory segments, or record offsets
in an append-only file. Prior art for the GPU case is AMD's
[VulkanMemoryAllocator][vma] library — the same host-side-metadata,
block-and-offset design, in ~20k lines of C++.

---

## Part II — Technical survey

The rest of the document is the bottom-up reference behind Part I: the
protocol, each building block with its documented semantics and costs, the
combinators, and the sharp edges — every claim cited to the sources and
demonstrated by a verified example.

## 7. The architecture: four layers, two commitments

The package DDoc lays out a four-layer architecture
(`package.d:73-121`):

1. **High-level, dynamically-typed** — [`theAllocator`][theAllocator] /
   [`processAllocator`][processAllocator] globals, the [`IAllocator`][IAllocator]
   interface, and type-aware helpers [`make`][make], [`makeArray`][makeArray],
   [`dispose`][dispose]. "This layer is all needed for most casual uses."
2. **Mid-level, statically-typed routing** — [`TypedAllocator`][TypedAllocator]
   dispatches by the _type_ being allocated ([§20](#_20-typedallocator-layer-2)).
3. **Low-level building blocks** — "Lego-like pieces that can be used to
   assemble application-specific allocators. The real allocation smarts are
   occurring at this level" (`package.d:102-114`).
4. **Core heap sources** — [`GCAllocator`][GCAllocator],
   [`Mallocator`][Mallocator], [`MmapAllocator`][MmapAllocator]. "Most custom
   allocators would ultimately obtain memory from one of these core allocators."

Two design commitments shape every API in the package
(`building_blocks/package.d:5-32`):

**Untyped `void[]` with client-tracked sizes.** Allocators "deal exclusively in
`void[]` and have no notion of what type the memory allocated would be destined
for". Unlike `malloc`, the _client_ passes the allocated size back on
deallocation — "Storing the size in the allocator has significant negative
performance implications, and is virtually always redundant because client code
needs knowledge of the allocated size in order to avoid buffer overruns." (See
the equivalent C++ [sized-deallocation proposal N3536][n3536].) This is why the
currency is `void[]` — a pointer _and_ a length — "as opposed to `void*`".

**Capability by presence.** Only two members are required of an allocator:
`alignment` and `allocate`. Everything else is optional, and — crucially —

> "Allocators should NOT implement unsupported methods to always fail. For
> example, an allocator that lacks the capability to implement `alignedAllocate`
> should not define it at all (as opposed to defining it to always return `null`
> or throw an exception). The missing implementation statically informs other
> components about the allocator's capabilities and allows them to make design
> decisions accordingly." — `building_blocks/package.d:23-32`

Combinators probe with `__traits(hasMember, Allocator, "expand")` and compose
only what exists. This is precisely the
[optional-primitives pattern](../design-by-introspection-01-guidelines.md) the
DbI guidelines describe — an absent method is _information_, not a defect.

## 8. The static allocator protocol

The full protocol is specified in the DDoc of
[`std.experimental.allocator.building_blocks`][bb-docs]
(`building_blocks/package.d:34-136`). Condensed, with postconditions:

| Primitive                                             | Required | Semantics (postcondition)                                                                                                                    |
| :---------------------------------------------------- | :------- | :------------------------------------------------------------------------------------------------------------------------------------------- |
| `uint alignment`                                      | **yes**  | Minimum alignment of all returned blocks (`> 0`). May be a statically-known `enum`.                                                          |
| `void[] allocate(size_t s)`                           | **yes**  | Returns `s` bytes or `null`. For `s == 0`, "may return any empty slice (including `null`)". (`result is null \|\| result.length == s`)       |
| `size_t goodAllocSize(size_t n)`                      | no       | Actual bytes a request for `n` would consume (internal fragmentation). Default: `n` rounded up to a multiple of `alignment`. (`result >= n`) |
| `void[] alignedAllocate(size_t s, uint a)`            | no       | Like `allocate`, aligned to at least `a` (a power of 2).                                                                                     |
| `void[] allocateAll()`                                | no       | Offers _all_ remaining memory; usually defined by fixed-size allocators; best-effort if memory is already managed.                           |
| `bool expand(ref void[] b, size_t delta)`             | no       | Grow `b` in place. `delta == 0` always succeeds; `expand(null, delta > 0)` is `false`. On failure `b` is unchanged.                          |
| `bool reallocate(ref void[] b, size_t s)`             | no       | Resize, possibly moving. Default free-function implementation composes `expand` + `allocate` + `deallocate`.                                 |
| `bool alignedReallocate(ref void[] b, size_t, uint)`  | no       | `reallocate` preserving an `alignedAllocate` alignment.                                                                                      |
| `Ternary owns(void[] b)`                              | no       | Define **"only if it can decide on ownership precisely and fast"**. `owns(null)` is `Ternary.no`.                                            |
| `Ternary resolveInternalPointer(void* p, ref void[])` | no       | Maps an interior pointer to its enclosing block.                                                                                             |
| `bool deallocate(void[] b)`                           | no       | `deallocate(null)` does nothing and returns `true`. An allocator that cannot deallocate "should not define this primitive at all".           |
| `bool deallocateAll()`                                | no       | Frees everything (postcondition: `empty`). "If an allocator implements this method, it must specify whether its destructor calls it, too."   |
| `Ternary empty()`                                     | no       | `yes` iff no memory is currently allocated.                                                                                                  |
| `static Allocator instance`                           | no       | For _monostate_ allocators (all state global — `malloc`, the GC). "An allocator should not hold state and define `instance` simultaneously." |

Because capability is presence, the capability matrix of a set of allocators is
itself computable with `__traits(hasMember)` — the same probe every combinator
in the package uses internally:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "allocator_capabilities"
+/
import std.stdio : writef, writefln, writeln;
import std.meta : AliasSeq;
import std.experimental.allocator.gc_allocator : GCAllocator;
import std.experimental.allocator.mallocator : Mallocator, AlignedMallocator;
import std.experimental.allocator.mmap_allocator : MmapAllocator;
import std.experimental.allocator.building_blocks.null_allocator : NullAllocator;

alias As = AliasSeq!(GCAllocator, Mallocator, AlignedMallocator, MmapAllocator, NullAllocator);
static immutable names = ["GC", "Malloc", "AlignedM", "Mmap", "Null"];
static immutable prims = [
    "alignedAllocate", "allocateAll", "expand", "reallocate", "alignedReallocate",
    "owns", "resolveInternalPointer", "deallocate", "deallocateAll", "empty",
];

void main()
{
    writef("%-24s", "primitive");
    foreach (n; names)
        writef("%-10s", n);
    writeln;
    static foreach (prim; prims)
    {{
        writef("%-24s", prim);
        static foreach (A; As)
            writef("%-10s", __traits(hasMember, A, prim) ? "yes" : "-");
        writeln;
    }}
}
```

```ansi
primitive               GC        Malloc    AlignedM  Mmap      Null
alignedAllocate         -         -         yes       -         yes
allocateAll             -         -         -         -         yes
expand                  yes       -         -         -         yes
reallocate              yes       yes       yes       -         yes
alignedReallocate       -         -         yes       -         yes
owns                    -         -         -         -         yes
resolveInternalPointer  yes       -         -         -         yes
deallocate              yes       yes       yes       yes       yes
deallocateAll           -         -         -         -         yes
empty                   -         -         -         -         yes
```

The matrix _is_ the documentation: `Mallocator` cannot tell you what it owns
(the C heap keeps no such books — `building_blocks/package.d:100-105`), the GC
can resolve interior pointers (it must, to scan), and
[`NullAllocator`][NullAllocator] implements _everything_ because every operation
is trivially a no-op.

---

## 9. `Ternary`: three-state answers

Queries that an allocator may answer imprecisely return
[`std.typecons.Ternary`][Ternary] — `yes`, `no`, or `unknown` — rather than
`bool`:

- `owns` and `empty` return `yes`/`no` from static allocators that define them.
- At the **runtime interface boundary** ([§3](#_3-application-authors-theallocator-and-runtime-polymorphism)),
  `unknown` gains a second meaning: "the wrapped allocator does not implement
  this primitive at all" (`package.d:309-311`). A static allocator never
  returns `unknown` for `owns`; an [`RCIAllocator`][RCIAllocator] wrapping
  `Mallocator` does.
- Convention: `owns(null)` is `Ternary.no` — "no allocator owns the `null`
  slice" (`building_blocks/package.d:104-105`).

> [!WARNING]
> Don't `writeln` a `Ternary` directly — it prints its internal encoding
> (`Ternary(2)` for `yes`). Compare against `Ternary.yes` / `Ternary.no`
> explicitly, which also reads better.

---

## 10. Heap sources

The four "layer 4" allocators plus the composition terminator:

| Allocator                                | `alignment`                              | Implements (beyond `allocate`)                                                         | Notes                                                                                                                                                                                                                                                |
| :--------------------------------------- | :--------------------------------------- | :------------------------------------------------------------------------------------- | :--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`GCAllocator`][GCAllocator]             | [`platformAlignment`][platformAlignment] | `expand`, `reallocate`, `resolveInternalPointer`, `deallocate`, custom `goodAllocSize` | Default backing of `theAllocator`. "`deallocate` and `reallocate` are `@system` because they may move memory around, leaving dangling pointers" (`gc_allocator.d:25-29`).                                                                            |
| [`Mallocator`][Mallocator]               | `platformAlignment`                      | `reallocate`, `deallocate`                                                             | "Somewhat paradoxically, `malloc` is `@safe` but that's only useful to safe programs that can afford to leak memory" (`mallocator.d:23-28`).                                                                                                         |
| [`AlignedMallocator`][AlignedMallocator] | `platformAlignment` (default)            | `alignedAllocate`, `alignedReallocate`, `reallocate`, `deallocate`                     | `posix_memalign` / `_aligned_malloc`. On Posix `alignedReallocate` is _emulated_ by allocate-copy-free (`mallocator.d:228-234`) — and plain `reallocate` loses a custom alignment (`mallocator.d:217-221`).                                          |
| [`MmapAllocator`][MmapAllocator]         | `4096` (hardcoded)                       | `deallocate`                                                                           | Raw `mmap`/`VirtualAlloc`; "usually intended for allocating large chunks to be managed by fine-granular allocators" (`mmap_allocator.d:11-14`).                                                                                                      |
| [`NullAllocator`][NullAllocator]         | `64 * 1024`                              | _every_ primitive, as a no-op/failure                                                  | The composition terminator. Its huge advertised alignment exists "because `NullAllocator` never actually needs to honor this alignment and because composite allocators using it shouldn't be unnecessarily constrained" (`null_allocator.d:17-23`). |

All five are monostate — `static shared instance` — and their methods are
`shared`, so any thread may use them. `GCAllocator` defines a _custom_
`goodAllocSize` mirroring the GC's real size classes, a step function rather
than mere alignment rounding:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "allocator_heap_sources"
+/
import std.stdio : writefln;
import std.experimental.allocator.gc_allocator : GCAllocator;
import std.experimental.allocator.mallocator : Mallocator;
import std.experimental.allocator : goodAllocSize;

void main()
{
    // GCAllocator: pow2 size classes up to a page, then page multiples
    // (gc_allocator.d:96-112). Mallocator has no member goodAllocSize, so the
    // free-function default kicks in: round up to alignment.
    foreach (n; [size_t(1), 16, 17, 100, 4096, 4097, 16_385])
        writefln("n=%6s  GC->%6s  malloc-default->%6s",
            n, GCAllocator.instance.goodAllocSize(n),
            goodAllocSize(Mallocator.instance, n));
}
```

```ansi
n=     1  GC->    16  malloc-default->    16
n=    16  GC->    16  malloc-default->    16
n=    17  GC->    32  malloc-default->    32
n=   100  GC->   128  malloc-default->   112
n=  4096  GC->  4096  malloc-default->  4096
n=  4097  GC->  8192  malloc-default->  4112
n= 16385  GC-> 20480  malloc-default-> 16400
```

`goodAllocSize` is what lets size-aware containers (like `SmallBuffer`'s
growth policy) claim the slack the allocator would waste anyway.

---

## 11. Regions: bump-the-pointer allocation

[`Region`][Region] "allocates memory straight from one contiguous chunk. There
is no deallocation, and once the region is full, allocation requests return
`null`. Therefore, `Region`s are often used (a) in conjunction with more
sophisticated allocators; or (b) for batch-style very fast allocations that
deallocate everything at once" (`region.d:20-25`). One allocation is an
alignment round-up, a pointer bump, and a bounds check.

The family:

| Type                                         | Storage                                       | Freed by destructor?                             |
| :------------------------------------------- | :-------------------------------------------- | :----------------------------------------------- |
| [`BorrowedRegion`][Region]                   | caller-supplied `ubyte[]`                     | no — "does not own the memory it allocates from" |
| [`Region!Parent`][Region]                    | drawn from a parent allocator                 | yes, iff the parent defines `deallocate`         |
| [`InSituRegion!(size, align)`][InSituRegion] | embedded `ubyte[size]` — typically the stack  | nothing to free                                  |
| [`SbrkRegion`][SbrkRegion]                   | the program break (Posix only, mutex-guarded) | n/a (process-global `instance`)                  |
| `SharedRegion` / `SharedBorrowedRegion`      | as above, lock-free CAS allocate/deallocate   | as `Region`                                      |

Despite "no deallocation" as the model, `Region` _does_ define `deallocate` —
but it only succeeds for the **most recent** allocation (LIFO), and `expand`
only works on the last block:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "allocator_region"
+/
import std.stdio : writeln;
import std.experimental.allocator.building_blocks.region : Region, InSituRegion;
import std.experimental.allocator.mallocator : Mallocator;

void main()
{
    auto r = Region!Mallocator(64 * 1024); // chunk from malloc, freed by dtor

    auto x = r.allocate(100);
    auto y = r.allocate(200);
    writeln("deallocate non-last: ", r.deallocate(x)); // false: LIFO only
    writeln("deallocate last:     ", r.deallocate(y));

    // x is now the last allocation again -> in-place expand succeeds,
    // in alignment-sized steps:
    writeln("expand last by 28: ", r.expand(x, 28), ", new length: ", x.length);

    // A stack region: storage lives inside the struct itself.
    InSituRegion!(4096, 1) stack;
    auto b = stack.allocate(2001);
    writeln("stack-allocated: ", b.length, ", left: ", stack.available);
}
```

```ansi
deallocate non-last: false
deallocate last:     true
expand last by 28: true, new length: 128
stack-allocated: 2001, left: 2095
```

> [!WARNING]
>
> - **Regions must not be copied casually** — a copy duplicates the bump
>   pointer and the two copies then hand out the same memory
>   (`region.d:106-109` advises against naive copying; `InSituRegion` and
>   `KRRegion` disable copying outright).
> - `InSituRegion`'s usable capacity can be less than its `size` parameter:
>   "To make sure that at least `n` bytes are available in the region, use
>   `InSituRegion!(n + a - 1, a)`" (`region.d:681-684`).
> - On systems where the stack grows downward, `InSituRegion` allocates from
>   its end first "such that hot memory is used first" (`region.d:686-689`).

---

## 12. Free lists

[`FreeList!(Parent, min, max)`][FreeList] keeps a singly-linked list of
previously freed blocks: "Allocation requests between `min` and `max` bytes are
rounded up to `max` and served from a singly-linked list of buffers deallocated
in the past. All other allocations are directed to `ParentAllocator`"
(`free_list.d:10-16`). The list node lives _inside_ the freed block, so the
bookkeeping is free.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "allocator_freelist"
+/
import std.stdio : writeln;
import std.experimental.allocator.building_blocks.free_list : FreeList;
import std.experimental.allocator.mallocator : Mallocator;

void main()
{
    FreeList!(Mallocator, 0, 64) fl; // eligible window: sizes 0 .. 64

    // Everything in the window is rounded up to max under the hood ...
    writeln("goodAllocSize(1):   ", fl.goodAllocSize(1));
    writeln("goodAllocSize(100): ", fl.goodAllocSize(100)); // out of window -> parent's

    // ... which is exactly what makes freed blocks reusable for ANY
    // in-window size:
    auto b1 = fl.allocate(48);
    auto p1 = b1.ptr;
    fl.deallocate(b1);
    auto b2 = fl.allocate(32);
    writeln("recycled the freed block: ", b2.ptr is p1);
    writeln("but sliced to the asked size: ", b2.length);
}
```

```ansi
goodAllocSize(1):   64
goodAllocSize(100): 112
recycled the freed block: true
but sliced to the asked size: 32
```

Variants:

- **`FreeList!(Parent, 0, unbounded)`** disables all size checking — every
  deallocation feeds the list, every allocation draws from it. Only correct
  "if an owning allocator above manages sizes", i.e. under a
  [`Segregator`][Segregator] or [`Bucketizer`][Bucketizer]
  (`free_list.d:21-26`) — that is exactly the jemalloc pattern in
  [§18](#_18-case-study-a-jemalloc-style-composite).
- **[`ContiguousFreeList`][ContiguousFreeList]** pre-threads the list through
  _one_ parent block: "better cache locality because items are closer to one
  another … The disadvantages are its pay upfront model … and a hard limit on
  the number of nodes" (`free_list.d:500-516`).
- **[`SharedFreeList`][SharedFreeList]** is the cross-thread variant, with an
  `approxMaxNodes` cap so one thread's deallocation storm can't grow the list
  without bound (`free_list.d:852-988`).
- **`Flag!"adaptive"`** on `FreeList` makes the list shrink itself when the
  hit rate over a 1000-call window is poor (`free_list.d:178-209`).

---

## 13. `BitmappedBlock`: fixed blocks, one bit each

[`BitmappedBlock!(blockSize, alignment, Parent)`][BitmappedBlock] carves one
contiguous chunk into equal blocks and tracks each with a single bit. "The
layout is more compact (overhead is one bit per block), searching for a free
block during allocation enjoys better cache locality, and deallocation does
not touch memory around the payload" (`bitmapped_block.d:1166-1171`). Unlike
`Region` it supports full random `deallocate`, and freeing "implicitly
coalesces free blocks together" — free bits are just free bits
(`bitmapped_block.d:1177-1179`).

Documented cost model (`bitmapped_block.d:1298-1308`): 1 block = find one zero
bit; 2–64 blocks = at most two `ulong` words; more = multiword search.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "allocator_bitmapped_block"
+/
import std.stdio : writeln;
import std.experimental.allocator.building_blocks.bitmapped_block : BitmappedBlock;
import std.experimental.allocator.mallocator : Mallocator;

void main()
{
    // 8 blocks of 64 bytes, memory + bitmap drawn from Mallocator.
    auto bb = BitmappedBlock!(64, 8, Mallocator)(8 * 64);

    void[][] blocks;
    for (;;)
    {
        auto b = bb.allocate(64);
        if (b is null)
            break;
        blocks ~= b;
    }
    writeln("single blocks until exhaustion: ", blocks.length);

    // Free three ADJACENT blocks; their bits form a hole that a multi-block
    // allocation can span — coalescing is implicit.
    foreach (i; 2 .. 5)
        bb.deallocate(blocks[i]);
    auto span = bb.allocate(3 * 64);
    writeln("3-block span in the hole: ", span.length == 192,
        ", exactly where the hole was: ", span.ptr is blocks[2].ptr);
}
```

```ansi
single blocks until exhaustion: 8
3-block span in the hole: true, exactly where the hole was: true
```

Related variants:

- `BitmappedBlock!(…, No.multiblock)` — single-block only, but each operation
  touches exactly one bit; the shared version of this mode is lock-free
  (`bitmapped_block.d:996-1123`). Requests over `blockSize` return `null`.
- [`SharedBitmappedBlock`][SharedBitmappedBlock] — same semantics, spin-locked
  in multiblock mode.
- `BitmappedBlockWithInternalPointers` — adds a second "object start" bitmap
  and with it `resolveInternalPointer` at O(object size)
  (`bitmapped_block.d:2153-2161`) — the building block you need under types
  that keep interior pointers.
- `blockSize` can be `chooseAtRuntime` (`bitmapped_block.d:1242-1250`).

---

## 14. `KRRegion`: the Kernighan-Ritchie heap

[`KRRegion`][KRRegion] is the classic first-fit allocator from K&R's _The C
Programming Language_ §8.7, with a twist: it starts life as a plain region and
only "switches to the free list" the first time the region path fails. "The
recommended use of `KRRegion` is as a region with deallocation. If the
`KRRegion` is dimensioned appropriately, it could often not enter free list
mode during its lifetime. Thus it is as fast as a simple region, whilst
offering deallocation at a small cost" (`kernighan_ritchie.d:34-41`).

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "allocator_krregion"
+/
import std.stdio : writeln;
import std.typecons : Ternary;
import std.experimental.allocator.building_blocks.kernighan_ritchie : KRRegion;

void main()
{
    // NB: the buffer MUST be word-aligned — a bare ubyte[N] stack array is
    // not guaranteed to be, and the constructor asserts on it.
    align(size_t.alignof) ubyte[1024] buf;
    auto kr = KRRegion!()(buf[]);

    writeln("fresh:   empty = ", kr.empty == Ternary.yes);
    auto a = kr.allocate(100);
    auto b = kr.allocate(200);
    writeln("used:    empty = ", kr.empty == Ternary.yes);

    // Arbitrary-order deallocation works (unlike Region):
    writeln("free a (not last): ", kr.deallocate(a));
    writeln("free b:            ", kr.deallocate(b));

    // deallocateAll resets to region mode; the whole buffer is reclaimable.
    kr.deallocateAll;
    auto all = kr.allocateAll;
    writeln("allocateAll after reset: ", all.length, " bytes");
}
```

```ansi
fresh:   empty = true
used:    empty = false
free a (not last): true
free b:            true
allocateAll after reset: 1024 bytes
```

Facts to keep in mind (`kernighan_ritchie.d:43-96`):

- Minimum allocation is **two words** (a free node must hold `next` + `size`),
  so `goodAllocSize(1) == 16` on 64-bit.
- `deallocate` keeps the free list address-sorted with a linear insert, and
  coalesces adjacent free blocks during that walk. Cost is proportional to the
  number of free blocks — cheap for LIFO-ish traffic, linear for adversarial
  patterns.
- If you know traffic is free-list-shaped from the start, call
  `switchToFreeList` right after construction.
- Differences from the real K&R allocator: it never grabs more memory when
  full, and allocated blocks carry no size prefix — D's protocol supplies the
  size at `deallocate` time.

---

## 15. `AscendingPageAllocator`: pages, monotonically

[`AscendingPageAllocator`][AscendingPageAllocator] reserves a large _virtual_
range up front and hands out page-rounded allocations at strictly increasing
addresses; physical memory is committed lazily and `deallocate` decommits
pages without ever reusing their addresses. "Because the allocator does not
reuse memory, any dangling references to deallocated memory will always result
in deterministically crashing the process" (`ascending_page_allocator.d:165-181`,
after the ["Simple, Fast and Safe Manual Memory Management"][kedia-paper]
paper).

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "allocator_page"
+/
import std.stdio : writeln;
import std.experimental.allocator.building_blocks.ascending_page_allocator
    : AscendingPageAllocator;

void main()
{
    auto a = AscendingPageAllocator(1024 * 4096);
    const page = a.goodAllocSize(1); // everything rounds to page multiples
    const total = a.getAvailableSize();

    auto b1 = a.allocate(1);
    writeln("1 byte costs a whole page: ", total - a.getAvailableSize() == page);

    auto b2 = a.allocate(page + 1);
    writeln("page+1 costs two pages:    ", total - a.getAvailableSize() == 3 * page);
    writeln("addresses strictly ascend: ", b2.ptr == b1.ptr + page);

    a.deallocate(b1);
    a.deallocate(b2); // pages decommitted; their addresses are never reissued
}
```

```ansi
1 byte costs a whole page: true
page+1 costs two pages:    true
addresses strictly ascend: true
```

Page granularity makes it wasteful for small objects — its niche is as the
_parent_ of finer-grained blocks (`AlignedBlockList` over it is the canonical
pairing, `aligned_block_list.d:383-395`), or wherever the
crash-on-use-after-free guarantee is worth a page per allocation.

---

## 16. Combinators: routing requests

The compositional heart of the package. Each combinator routes by a different
**discriminator**, and places different demands on its children:

| Combinator                                                | Routes by                                          | Hard requirements on children                                                                     |
| :-------------------------------------------------------- | :------------------------------------------------- | :------------------------------------------------------------------------------------------------ |
| [`FallbackAllocator!(P, F)`][FallbackAllocator]           | `P.owns(b)` at deallocation time                   | "requires that `Primary` defines the `owns` method" (`fallback_allocator.d:16-18`)                |
| [`Segregator!(threshold, S, L)`][Segregator]              | request/block **size** vs a compile-time threshold | none beyond the protocol; variadic form builds a search tree of thresholds                        |
| [`Bucketizer!(A, min, max, step)`][Bucketizer]            | size bucket index                                  | `(max + 1 - min) / step` must divide exactly; sizes outside `[min, max]` are **illegal**          |
| [`AllocatorList!(factory)`][AllocatorList]                | MRU walk + `owns` per node                         | factory is `size_t n => allocator`; capturing lambdas are rejected                                |
| [`Quantizer!(A, roundingFn)`][Quantizer]                  | rounds sizes before delegating                     | `roundingFn` must be `>= n`, monotonic, and deterministic (deallocation re-derives the true size) |
| [`FreeTree!A`][FreeTree]                                  | binary search tree of freed blocks, by size        | parent must be word-aligned; adds `deallocate` to allocators that lack it (e.g. regions)          |
| [`AlignedBlockList!(A, Parent, align)`][AlignedBlockList] | pointer masking — O(1) deallocate                  | parent must implement `alignedAllocate`; serves only sizes ≤ its alignment                        |

`FallbackAllocator` is "the allocator equivalent of an 'or' operator in
algebra … useful for fast, special-purpose allocators backed up by
general-purpose ones" (`fallback_allocator.d:10-22`). The showcase module ships
the most useful preassembly, [`StackFront`][showcase]: an `InSituRegion` (the
stack) falling back to the GC:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "allocator_fallback"
+/
import std.stdio : writeln;
import std.typecons : Ternary;
import std.experimental.allocator.building_blocks.fallback_allocator : FallbackAllocator;
import std.experimental.allocator.building_blocks.region : InSituRegion;
import std.experimental.allocator.gc_allocator : GCAllocator;

// Equivalent to std.experimental.allocator.showcase's StackFront!4096.
alias StackFront = FallbackAllocator!(
    InSituRegion!(4096, GCAllocator.alignment),
    GCAllocator);

void main()
{
    StackFront a;

    auto small = a.allocate(64);         // fits the stack region
    auto big = a.allocate(1024 * 1024);  // spills to the GC

    writeln("small served by the stack: ", a.primary.owns(small) == Ternary.yes);
    writeln("big served by the stack:   ", a.primary.owns(big) == Ternary.yes);
    writeln("both requests satisfied:   ", small.length == 64 && big.length == 1024 * 1024);
}
```

```ansi
small served by the stack: true
big served by the stack:   false
both requests satisfied:   true
```

[`AllocatorList`][AllocatorList] turns a _factory_ into an unbounded supply:
"Given an allocator factory, lazily creates as many allocators as needed to
satisfy allocation requests" (`building_blocks/package.d:276-279`), keeping
them in a most-recently-used list and destroying allocators that empty out.
The factory must be a context-free function (module-level state is fine;
captured locals are rejected by design, `allocator_list.d:606-616`):

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "allocator_allocator_list"
+/
import std.stdio : writeln;
import std.algorithm.comparison : max;
import std.experimental.allocator.building_blocks.allocator_list : AllocatorList;
import std.experimental.allocator.building_blocks.region : Region;
import std.experimental.allocator.mallocator : Mallocator;

int regionsCreated; // module-level: visible to the factory without capture

void main()
{
    // A "growable region": each exhausted region spawns a fresh 16 KB one.
    AllocatorList!((size_t n) {
        ++regionsCreated;
        return Region!Mallocator(max(n, 16 * 1024));
    }) a;

    auto b1 = a.allocate(10 * 1024);
    writeln("regions after 10 KB:  ", regionsCreated);
    auto b2 = a.allocate(10 * 1024); // doesn't fit region 1 -> new region
    writeln("regions after +10 KB: ", regionsCreated);
    writeln("all requests served:  ", b1.length + b2.length == 20 * 1024);
}
```

```ansi
regions after 10 KB:  1
regions after +10 KB: 2
all requests served:  true
```

Bookkeeping for the node list comes from a `BookkeepingAllocator` parameter
(default `GCAllocator`); passing `NullAllocator` selects the self-hosting
"ouroboros" mode where the node array lives in memory drawn from the managed
allocators themselves (`allocator_list.d:81, 325-414`). The showcase module's
`mmapRegionList(bytesPerRegion)` is this pattern over `MmapAllocator`-backed
regions — fast batch allocation with no `deallocate`, everything freed by the
destructor (`showcase.d:53-84`).

---

## 17. Metadata and instrumentation

### `AffixAllocator`: metadata around every block

[`AffixAllocator!(A, Prefix, Suffix)`][AffixAllocator] over-allocates each
block to make room for a `Prefix` before and/or a `Suffix` after it, exposed
via `prefix(b)` / `suffix(b)` accessors returning `ref`. It is "useful for
uses where additional allocation-related information is needed, such as
mutexes, reference counts, or walls for debugging memory corruption errors"
(`affix_allocator.d:9-13`) — and it is the substrate other tools build on:
`ScopedAllocator` keeps its tracking node in the prefix, and `AllocatorList`
instruments each node with a stats prefix.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "allocator_affix"
+/
import std.stdio : writefln, writeln;
import std.experimental.allocator.building_blocks.affix_allocator : AffixAllocator;
import std.experimental.allocator.mallocator : Mallocator;

void main()
{
    // A size_t before and after every allocation — e.g. a refcount + a canary.
    alias A = AffixAllocator!(Mallocator, size_t, size_t);

    auto b = A.instance.allocate(10);
    writeln("client sees exactly its bytes: ", b.length);

    A.instance.prefix(b) = 1;           // refcount
    A.instance.suffix(b) = 0xDEAD_BEEF; // canary
    A.instance.prefix(b) += 1;

    writefln("prefix (refcount): %s", A.instance.prefix(b));
    writefln("suffix (canary):   0x%X", A.instance.suffix(b));

    A.instance.deallocate(b);
}
```

```ansi
client sees exactly its bytes: 10
prefix (refcount): 2
suffix (canary):   0xDEADBEEF
```

Constraints: the parent's alignment must be at least `Prefix.alignof`
(`affix_allocator.d:36-39`); `expand` is only available when there is **no
suffix** (the suffix would have to move); and the affix accessors preserve
qualifiers sensibly — the prefix of an `immutable` block is `ref shared`,
because "although the data is immutable, the allocator knows the underlying
memory is mutable" (`affix_allocator.d:350-379`).

### `StatsCollector`: numbers, not vibes

[`StatsCollector!(A, flags, perCallFlags)`][StatsCollector] wraps any allocator
and counts what flows through, selected at compile time from
`Options`: call counters (`numAllocate`, `numAllocateOK`, `numDeallocate`, …),
byte accounting (`bytesUsed`, `bytesAllocated` cumulative, `bytesSlack`,
`bytesHighTide`, …), and optional per-call-site statistics keyed by
`__FILE__`/`__LINE__`. `Options.bytesUsed` also unlocks an `empty()` query.

### `ScopedAllocator`: automatic cleanup

[`ScopedAllocator!Parent`][ScopedAllocator] "delegates all allocation requests
to `ParentAllocator`. When destroyed, the `ScopedAllocator` object
automatically calls `deallocate` for all memory allocated through its
lifetime" (`scoped_allocator.d:11-15`). Tracking costs a three-word
`AffixAllocator` prefix per block; if you never deallocate mid-scope, the docs
recommend the cheaper `AllocatorList` + `Region` combination instead
(`scoped_allocator.d:16-19`).

The two compose into a self-verifying harness — stats prove the scope leaks
nothing:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "allocator_scoped"
+/
import std.stdio : writeln;
import std.typecons : Ternary;
import std.experimental.allocator.building_blocks.scoped_allocator : ScopedAllocator;
import std.experimental.allocator.building_blocks.stats_collector
    : StatsCollector, Options;
import std.experimental.allocator.mallocator : Mallocator;

alias Counted = StatsCollector!(Mallocator, Options.bytesUsed | Options.numAllocate);

void main()
{
    ScopedAllocator!Counted a;

    cast(void) a.allocate(100);
    cast(void) a.allocate(200);

    // The stats collector sits under an AffixAllocator (the tracking node
    // lives in each block's prefix) — hence parent.parent.
    writeln("allocations: ", a.parent.parent.numAllocate);
    writeln("live bytes cover payload + tracking: ", a.parent.parent.bytesUsed >= 300);

    a.deallocateAll(); // same semantics as the destructor
    writeln("live bytes after cleanup: ", a.parent.parent.bytesUsed);
    writeln("empty: ", a.empty == Ternary.yes);
}
```

```ansi
allocations: 2
live bytes cover payload + tracking: true
live bytes after cleanup: 0
empty: true
```

---

## 18. Case study: a jemalloc-style composite

The package DDoc's flagship example (`building_blocks/package.d:138-176`)
assembles a general-purpose heap "modeled after [jemalloc][jemalloc], which
uses a battery of free-list allocators spaced so as to keep internal
fragmentation to a minimum". Small sizes hit per-band free lists; mid sizes a
growable region list; huge sizes go straight to the GC. Note the
`FreeList!(GCAllocator, 0, unbounded)` — safe _only_ because the `Segregator`
and `Bucketizer` above it guarantee each list sees a single size band:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "allocator_composite"
+/
import std.stdio : writeln;
import std.algorithm.comparison : max;
import std.typecons : Ternary;
import std.experimental.allocator;
import std.experimental.allocator.building_blocks;

alias FList = FreeList!(GCAllocator, 0, unbounded);
alias A = Segregator!(
    8, FreeList!(GCAllocator, 0, 8),
    128, Bucketizer!(FList, 1, 128, 16),
    256, Bucketizer!(FList, 129, 256, 32),
    512, Bucketizer!(FList, 257, 512, 64),
    1024, Bucketizer!(FList, 513, 1024, 128),
    2048, Bucketizer!(FList, 1025, 2048, 256),
    3584, Bucketizer!(FList, 2049, 3584, 512),
    4072 * 1024, AllocatorList!(n => Region!GCAllocator(max(n, 1024 * 4096))),
    GCAllocator
);

void main()
{
    A tuMalloc;

    auto b = tuMalloc.allocate(500);   // Bucketizer band [257, 512], bucket 4
    auto c = tuMalloc.allocate(113);   // Bucketizer band [1, 128], bucket 8
    writeln("mid-size served: ", b.length, " and ", c.length);

    // The 113-byte block lives in a 128-byte bucket -> 15 bytes of headroom
    // make this expansion free and in-place:
    writeln("in-place expand by 14: ", tuMalloc.expand(c, 14),
        ", now ", c.length, " bytes");

    writeln("deallocate mid-size:   ", tuMalloc.deallocate(b));
    writeln("deallocate small:      ", tuMalloc.deallocate(c));

    auto huge = tuMalloc.allocate(5000 * 1024); // over 4072 KB -> GC directly
    writeln("huge served: ", huge.length == 5000 * 1024);
}
```

```ansi
mid-size served: 500 and 113
in-place expand by 14: true, now 127 bytes
deallocate mid-size:   true
deallocate small:      true
huge served: true
```

The routing is all compile-time: `Segregator`'s variadic form builds a binary
search tree over the thresholds (`segregator.d:351-373`), so dispatch costs a
handful of integer comparisons — and deallocation routes by `b.length` through
the same tree, which is why the client-supplies-the-size protocol matters.

---

## 19. Sharing memory across threads

The design doc is explicit about the threading model
(`building_blocks/package.d:178-200`):

- Allocators traffic in `void[]`, never `shared void[]` — "at the time of
  allocation, deallocation, or reallocation, the memory is effectively not
  `shared` (if it were, it would reveal a bug at the application level)".
- Deallocating in a different thread than the allocating one is legal **only
  if both threads use the same `shared` allocator instance** — the allocator
  type must implement `allocate`/`deallocate` as `shared` methods.
- "Conversely, allocating memory with one non-`shared` allocator, passing it
  across threads (by casting the obtained buffer to `shared`), and later
  deallocating it in a different thread … is illegal."

What exists for cross-thread use: the monostate heap sources ([§10](#_10-heap-sources))
are all `shared`; `processAllocator` / `RCISharedAllocator` at the dynamic
layer; and dedicated shared building blocks — [`SharedFreeList`][SharedFreeList],
`SharedRegion` / `SharedBorrowedRegion` (lock-free CAS bump),
[`SharedBitmappedBlock`][SharedBitmappedBlock] (spin-locked; its
single-block mode is lock-free), `SharedAllocatorList`, and
`SharedAscendingPageAllocator`. Combinators are uneven here:
`Segregator` becomes `shared` automatically when both children are stateless
`shared` (`segregator.d:288-304`), while `FallbackAllocator`, `Quantizer`,
`FreeTree`, `Bucketizer` and `ScopedAllocator` have no shared story at all —
compose accordingly.

---

## 20. `TypedAllocator` (layer 2)

[`TypedAllocator!(Primary, Policies...)`][TypedAllocator] routes allocations to
different untyped allocators "depending on the static properties of the types
allocated" (`typed.d:3-8`): a bitmask of `AllocFlag`s is deduced per type —
`fixedSize` for non-arrays, `hasNoIndirections` for pointer-free types (which
a GC need not scan), `immutableShared` / `threadLocal` for sharing — and
matched against the policy list, falling back to the next-most-specific
policy, then the primary. Note that `type2flags` cannot _deduce_
thread-locality (`typed.d:227-240`) — `threadLocal` policies are reachable
only through the explicit `allocatorFor!(uint flags)` form.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "allocator_typed"
+/
import std.stdio : writeln;
import std.experimental.allocator : theAllocator, dispose;
import std.experimental.allocator.typed : TypedAllocator, AllocFlag;
import std.experimental.allocator.gc_allocator : GCAllocator;
import std.experimental.allocator.mallocator : Mallocator;

// Pointer-free fixed-size values -> Mallocator (the GC need not scan them);
// everything else -> the GC.
alias MyAllocator = TypedAllocator!(GCAllocator,
    AllocFlag.fixedSize | AllocFlag.hasNoIndirections,
    Mallocator);

struct PodPoint { int x, y; }        // no indirections -> the Mallocator policy
struct Node { Node* next; int v; }   // has indirections -> falls to the primary

void main()
{
    MyAllocator a;

    // Routing is a pure compile-time function of the type:
    writeln("PodPoint -> Mallocator policy: ",
        is(typeof(a.allocatorFor!PodPoint()) == Mallocator));
    writeln("Node     -> GC primary:        ",
        is(typeof(a.allocatorFor!Node()) == shared(const(GCAllocator))));

    // Allocating through the *primary* works (it aliases the shared
    // GCAllocator.instance) ...
    auto p = a.make!Node();
    writeln("made through the GC primary: ", *p);
    a.dispose(p);

    // ... but `make` through the Mallocator *policy* does not even compile:
    // extra allocators are stored as non-shared members (typed.d:149-150),
    // and every monostate allocator's methods are `shared`.
    static assert(!__traits(compiles, a.make!PodPoint(2, 3)));
}
```

```ansi
PodPoint -> Mallocator policy: true
Node     -> GC primary:        true
made through the GC primary: Node(null, 0)
```

> [!WARNING]
> Treat `TypedAllocator` as illustrative, not production-ready. Two latent
> compile-level bugs — both verified against the phobos checkout _and_ LDC
> 1.41's bundled Phobos — mark its maturity:
>
> 1. The flag-deduction function references a nonexistent enum member,
>    `AllocFlag.forSharing` (`typed.d:233`), so **any** `make`/`makeArray`/
>    `dispose` of a `shared` (non-`immutable`) type **fails to compile**:
>
>    ```d
>    alias TA = TypedAllocator!GCAllocator;
>    static assert(!__traits(compiles, { TA ta; auto p = ta.make!(shared long)(3); }));
>    ```
>
> 2. Extra policy allocators are stored as plain non-`shared` members
>    (`typed.d:149-150`), while every Phobos monostate allocator implements
>    its primitives as `shared` methods — so actually _allocating_ through a
>    `Mallocator`/`MmapAllocator` policy fails to compile too, as the example
>    above static-asserts.
>
> The module's own tests never allocate a `shared` type nor route an
> allocation through an extra policy, so both bugs have sat unnoticed — a
> good measure of this layer's exercise level relative to layers 1, 3, and 4.

---

## 21. Writing your own allocator

The whole protocol contract for a _new_ allocator is two members. Everything
above the protocol — [`make`][make], [`makeArray`][makeArray], the default
[`goodAllocSize`][goodAllocSize] — works with any type that satisfies it, by
duck typing (`package.d:198-225`):

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "allocator_minimal"
+/
import std.stdio : writeln;
import std.experimental.allocator : make, makeArray, platformAlignment;

/// A bump allocator over an embedded buffer.
struct StackArena(size_t capacity)
{
    enum uint alignment = platformAlignment;

    private align(platformAlignment) ubyte[capacity] _store;
    private size_t _used;

    void[] allocate(size_t n) @safe pure nothrow @nogc return scope
    {
        const rounded = roundUp(n);
        if (n == 0 || rounded > capacity - _used)
            return null;
        auto b = _store[_used .. _used + n];
        _used += rounded;
        return b;
    }

    /// LIFO deallocation, Region-style: only the last allocation can be undone.
    bool deallocate(void[] b) @trusted pure nothrow @nogc
    {
        if (b is null)
            return true;
        if (b.ptr + roundUp(b.length) !is _store.ptr + _used)
            return false;
        _used -= roundUp(b.length);
        return true;
    }

    private static size_t roundUp(size_t n) @safe pure nothrow @nogc
        => (n + alignment - 1) & ~(size_t(alignment) - 1);
}

struct Point { int x, y; }

void main()
{
    StackArena!1024 arena;

    auto p = arena.make!Point(3, 4);
    auto xs = arena.makeArray!int(4, 9);
    writeln(*p);
    writeln(xs);

    // Exhaustion: allocate returns null, and make maps that to a null pointer.
    auto q = arena.make!(ubyte[2048]);
    writeln("overcommitted make returns null: ", q is null);
}
```

```ansi
Point(3, 4)
[9, 9, 9, 9]
overcommitted make returns null: true
```

> [!NOTE]
> Why does the example define `deallocate` when the protocol requires only two
> members? Because the _high-level_ API is stricter than the protocol:
> `make`'s constructor-failure cleanup instantiates `alloc.deallocate(m)`
> unconditionally (`package.d:1199-1212`), so an allocator without
> `deallocate` fails to compile under `make` — every allocator that ships with
> Phobos defines it, even `Region` (for which it only undoes the last
> allocation). A truly two-member allocator works with `allocate`, the free
> functions, and manual `emplace`, but not with `make`.

Notes for allocator authors:

- **Reuse the free-function defaults.** The module provides free functions
  [`goodAllocSize`][goodAllocSize], `reallocate` and `alignedReallocate`
  (`common.d:142-457`) implemented in terms of the primitives you do define.
  They deliberately _never_ call a member of the same name, so your own member
  `reallocate` can call the free function as its fallback without recursion
  (`common.d:400-403`).
- **`stateSize` drives composition** (`common.d:34-49`): an empty non-nested
  struct has `stateSize == 0` and is treated as _stateless_; combinators then
  use `A.instance` instead of storing a member. The idiom throughout the
  package is `static if (stateSize!A) A parent; else alias parent = A.instance;`.
- Phobos has an executable conformance spec, `testAllocator`
  (`common.d:537-671`) — it is `package`-visibility so you cannot call it from
  user code, but it is worth reading: it hard-asserts, among much else, that
  `allocate(0) is null` and that `expand(b, 0)` always succeeds.

---

## 22. Attribute reality: `@safe`, `@nogc`, `nothrow`, `pure`

The package follows the same discipline as
[sparkles' attribute guidelines](../code-style.md): concrete non-templated
allocators carry explicit attributes; everything generic lets attributes
_infer_ from the composed parts. What that means in practice:

- **The primitives of the heap sources are honest**: `Mallocator.allocate` is
  `@trusted @nogc nothrow pure`; `GCAllocator.deallocate` and `.reallocate`
  are deliberately `@system` — "they may move memory around, leaving dangling
  pointers" (`gc_allocator.d:25-29`).
- **Building blocks are `@nogc`-clean by construction** (they never touch the
  GC unless their parent is `GCAllocator`), so a `Region!Mallocator`-backed
  pipeline is usable from `@nogc nothrow` code. Attribute inference does the
  bookkeeping — annotate your own concrete wrappers, not the templates.
- **`make` is only as `@safe`/`pure` as `T`'s constructor** (`package.d:
1370-1382`): a `pure` constructor keeps `make` callable from
  `@safe pure nothrow @nogc` code; an impure one poisons it.
- **The dynamic layer is looser than it looks**: `IAllocator.incRef`/`decRef`
  advertise `@safe @nogc pure` but the implementations are `@trusted` with
  raw `memcpy` (`package.d:3034-3064`), and the `processAllocator` getter
  launders `@nogc nothrow` onto `initOnce` via a function-pointer cast
  (`package.d:1076-1082`). Fine to _use_, but don't cite the dynamic layer as
  a `@safe`-by-construction example.
- The `theAllocator`/`processAllocator` **setters are `@system`** on purpose —
  installing an allocator is a global, safety-relevant act
  ([§3](#_3-application-authors-theallocator-and-runtime-polymorphism)).

---

## 23. Pitfalls checklist

- [ ] `Region`/`SbrkRegion` `deallocate` frees **only the last allocation**;
      `expand` works only on the last block ([§11](#_11-regions-bump-the-pointer-allocation)).
- [ ] Never copy a live region/bump allocator — duplicated bookkeeping hands
      out the same memory twice ([§11](#_11-regions-bump-the-pointer-allocation)).
- [ ] `KRRegion` needs a **word-aligned** buffer (assert at construction) and
      has a two-word minimum block ([§14](#_14-krregion-the-kernighan-ritchie-heap)).
- [ ] `makeArray!char(n)` gives `0xFF` bytes (`char.init`), not zeroes
      ([§2](#_2-application-authors-make-dispose-and-friends)).
- [ ] `make!(T[])` returns a pointer to an _empty array_ — use `makeArray`
      ([§2](#_2-application-authors-make-dispose-and-friends)).
- [ ] `expand(null, delta > 0)` and `expandArray` on a null array are `false`
      by specification ([§8](#_8-the-static-allocator-protocol)).
- [ ] Allocating with one allocator and deallocating with another is UB — set
      `theAllocator`/`processAllocator` once, early; containers should store
      their allocator ([§3](#_3-application-authors-theallocator-and-runtime-polymorphism)).
- [ ] `allocatorObject(a)` **moves** `a` in; pass stateful allocators by
      pointer to keep access ([§3](#_3-application-authors-theallocator-and-runtime-polymorphism)).
- [ ] `allocate(0)` returns `null` in every Phobos allocator; don't treat
      `null` from a zero-size request as failure ([§8](#_8-the-static-allocator-protocol)).
- [ ] `deallocate`'s `bool` mostly encodes _capability_, not per-call success —
      probe support with `deallocate(null)` at the dynamic layer
      ([§3](#_3-application-authors-theallocator-and-runtime-polymorphism)).
- [ ] `AlignedMallocator`: plain `reallocate` silently drops a custom
      alignment; Posix `alignedReallocate` is allocate-copy-free
      ([§10](#_10-heap-sources)).
- [ ] `Bucketizer` sizes outside `[min, max]` are illegal — front it with a
      `Segregator` ([§16](#_16-combinators-routing-requests)).
- [ ] `FreeList!(0, unbounded)` skips all size checks — only under a
      size-segregating parent ([§12](#_12-free-lists)).
- [ ] `TypedAllocator` cannot allocate `shared` types (missing
      `AllocFlag.forSharing`) ([§20](#_20-typedallocator-layer-2)).
- [ ] When building blocks manage a _foreign_ address space, `reallocate` and
      anything typed (`make`, `makeArray`) are off-limits — metadata-only
      primitives only ([§6](#_6-showcase-sub-allocating-gpu-device-memory)).
- [ ] Docs lag code in places: `theAllocator` is an `RCIAllocator`, not an
      `IAllocator`; `allocateZeroed` exists but is undocumented and
      `package`-visibility.

---

## 24. Cheat sheet: which building block when

| Need                                                   | Reach for                                                                                      |
| :----------------------------------------------------- | :--------------------------------------------------------------------------------------------- |
| Batch allocations, free everything at once             | [`Region`][Region] / [`InSituRegion`][InSituRegion] (stack), or `mmapRegionList` for unbounded |
| Region speed _plus_ occasional deallocation            | [`KRRegion`][KRRegion]                                                                         |
| Many same-size objects, high alloc/free churn          | [`FreeList`][FreeList] (or [`ContiguousFreeList`][ContiguousFreeList] for locality)            |
| Fixed-size blocks with random dealloc and low overhead | [`BitmappedBlock`][BitmappedBlock] (1 bit/block)                                               |
| Interior-pointer resolution                            | `BitmappedBlockWithInternalPointers`                                                           |
| Deterministic crash on use-after-free                  | [`AscendingPageAllocator`][AscendingPageAllocator]                                             |
| Small-fast allocator with a general-purpose safety net | [`FallbackAllocator`][FallbackAllocator] / `StackFront`                                        |
| Different strategies per size class                    | [`Segregator`][Segregator] (+ [`Bucketizer`][Bucketizer] for fine bands)                       |
| Unbounded capacity from a fixed-size recipe            | [`AllocatorList`][AllocatorList]                                                               |
| Add `deallocate` to an allocator that lacks it         | [`FreeTree`][FreeTree]                                                                         |
| Fewer reallocations for growing buffers                | [`Quantizer`][Quantizer]                                                                       |
| Per-block metadata (refcounts, canaries, sizes)        | [`AffixAllocator`][AffixAllocator]                                                             |
| Leak-checking, sizing, profiling                       | [`StatsCollector`][StatsCollector]                                                             |
| Scope-tied cleanup of many allocations                 | [`ScopedAllocator`][ScopedAllocator]                                                           |
| O(1) deallocation across many sub-allocators           | [`AlignedBlockList`][AlignedBlockList]                                                         |
| Sub-allocating a foreign address space (GPU heaps)     | [`BitmappedBlock`][BitmappedBlock] / `BorrowedRegion` over never-touched virtual memory        |

---

## Sources

- Phobos sources (primary; commit `6be6c3809`):
  `std/experimental/allocator/{package,common,typed,showcase,gc_allocator,mallocator,mmap_allocator}.d`
  and `std/experimental/allocator/building_blocks/*.d`.
- [`std.experimental.allocator` documentation][alloc-docs] and
  [`std.experimental.allocator.building_blocks`][bb-docs] (the protocol
  specification).
- Andrei Alexandrescu, [_std::allocator Is to Allocation what std::vector Is
  to Vexation_][cppcon-talk], CppCon 2015 — the design rationale behind this
  package, presented for C++.
- Lawrence Crowl, [N3536: C++ Sized Deallocation][n3536] — the argument for
  client-tracked sizes.
- [jemalloc][jemalloc] — the model for the size-segregated composite.
- Kedia et al., [_Simple, Fast and Safe Manual Memory Management_][kedia-paper]
  (PLDI 2017) — the design `AscendingPageAllocator` cites.
- The [Vulkan memory-allocation guide][vk-memory] and AMD's
  [VulkanMemoryAllocator][vma] — the device-memory sub-allocation problem and
  its canonical host-side-bookkeeping solution.

<!-- References -->

[alloc-docs]: https://dlang.org/phobos/std_experimental_allocator.html
[bb-docs]: https://dlang.org/phobos/std_experimental_allocator_building_blocks.html
[make]: https://dlang.org/phobos/std_experimental_allocator.html#.make
[makeArray]: https://dlang.org/phobos/std_experimental_allocator.html#.makeArray
[dispose]: https://dlang.org/phobos/std_experimental_allocator.html#.dispose
[theAllocator]: https://dlang.org/phobos/std_experimental_allocator.html#.theAllocator
[processAllocator]: https://dlang.org/phobos/std_experimental_allocator.html#.processAllocator
[allocatorObject]: https://dlang.org/phobos/std_experimental_allocator.html#.allocatorObject
[IAllocator]: https://dlang.org/phobos/std_experimental_allocator.html#.IAllocator
[RCIAllocator]: https://dlang.org/phobos/std_experimental_allocator.html#.RCIAllocator
[goodAllocSize]: https://dlang.org/phobos/std_experimental_allocator_common.html#.goodAllocSize
[platformAlignment]: https://dlang.org/phobos/std_experimental_allocator_common.html#.platformAlignment
[Ternary]: https://dlang.org/phobos/std_typecons.html#Ternary
[GCAllocator]: https://dlang.org/phobos/std_experimental_allocator_gc_allocator.html
[Mallocator]: https://dlang.org/phobos/std_experimental_allocator_mallocator.html#.Mallocator
[AlignedMallocator]: https://dlang.org/phobos/std_experimental_allocator_mallocator.html#.AlignedMallocator
[MmapAllocator]: https://dlang.org/phobos/std_experimental_allocator_mmap_allocator.html
[NullAllocator]: https://dlang.org/phobos/std_experimental_allocator_building_blocks_null_allocator.html
[Region]: https://dlang.org/phobos/std_experimental_allocator_building_blocks_region.html
[InSituRegion]: https://dlang.org/phobos/std_experimental_allocator_building_blocks_region.html#.InSituRegion
[SbrkRegion]: https://dlang.org/phobos/std_experimental_allocator_building_blocks_region.html#.SbrkRegion
[FreeList]: https://dlang.org/phobos/std_experimental_allocator_building_blocks_free_list.html#.FreeList
[ContiguousFreeList]: https://dlang.org/phobos/std_experimental_allocator_building_blocks_free_list.html#.ContiguousFreeList
[SharedFreeList]: https://dlang.org/phobos/std_experimental_allocator_building_blocks_free_list.html#.SharedFreeList
[BitmappedBlock]: https://dlang.org/phobos/std_experimental_allocator_building_blocks_bitmapped_block.html#.BitmappedBlock
[SharedBitmappedBlock]: https://dlang.org/phobos/std_experimental_allocator_building_blocks_bitmapped_block.html#.SharedBitmappedBlock
[KRRegion]: https://dlang.org/phobos/std_experimental_allocator_building_blocks_kernighan_ritchie.html
[AscendingPageAllocator]: https://dlang.org/phobos/std_experimental_allocator_building_blocks_ascending_page_allocator.html
[FallbackAllocator]: https://dlang.org/phobos/std_experimental_allocator_building_blocks_fallback_allocator.html
[Segregator]: https://dlang.org/phobos/std_experimental_allocator_building_blocks_segregator.html
[Bucketizer]: https://dlang.org/phobos/std_experimental_allocator_building_blocks_bucketizer.html
[AllocatorList]: https://dlang.org/phobos/std_experimental_allocator_building_blocks_allocator_list.html
[Quantizer]: https://dlang.org/phobos/std_experimental_allocator_building_blocks_quantizer.html
[FreeTree]: https://dlang.org/phobos/std_experimental_allocator_building_blocks_free_tree.html
[AlignedBlockList]: https://dlang.org/phobos/std_experimental_allocator_building_blocks_aligned_block_list.html
[AffixAllocator]: https://dlang.org/phobos/std_experimental_allocator_building_blocks_affix_allocator.html
[StatsCollector]: https://dlang.org/phobos/std_experimental_allocator_building_blocks_stats_collector.html
[ScopedAllocator]: https://dlang.org/phobos/std_experimental_allocator_building_blocks_scoped_allocator.html
[TypedAllocator]: https://dlang.org/phobos/std_experimental_allocator_typed.html
[showcase]: https://dlang.org/phobos/std_experimental_allocator_showcase.html
[n3536]: https://www.open-std.org/JTC1/SC22/WG21/docs/papers/2013/n3536.html
[cppcon-talk]: https://www.youtube.com/watch?v=LIb3L4vKZ7U
[jemalloc]: https://jemalloc.net/
[kedia-paper]: https://web.archive.org/web/20250815142733/https://www.microsoft.com/en-us/research/wp-content/uploads/2017/03/kedia2017mem.pdf
[vma]: https://github.com/GPUOpen-LibrariesAndSDKs/VulkanMemoryAllocator
[vk-memory]: https://docs.vulkan.org/guide/latest/memory_allocation.html
