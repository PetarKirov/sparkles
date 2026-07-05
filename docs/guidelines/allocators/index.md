# Composable Memory Allocators (`std.experimental.allocator`)

This is a technical survey of Phobos' [`std.experimental.allocator`][alloc-docs]
— D's composable, capability-driven memory-allocation framework — written as a
guideline for allocation-conscious code in this repository. The package is the
canonical large-scale application of the
[Design by Introspection](../design-by-introspection-01-guidelines.md) style
sparkles follows: every allocator advertises its capabilities **by which methods
it defines**, and combinators detect those capabilities statically and adapt.
Studying it is studying DbI at production scale.

Everything below is grounded in the Phobos sources (cited as
`std/experimental/allocator/<file>:<line>`, pinned at phobos commit `6be6c3809`,
July 2026) and in runnable snippets verified by `ci --verify` against the repo
toolchain (LDC 1.41, DMD 2.111 frontend).

> [!IMPORTANT]
> The package has lived in `std.experimental` since 2015 (DMD 2.069) and is
> Phobos' most battle-tested "experimental" module — but the _experimental_
> label is real: parts of the documentation lag the code (the docs still say
> `theAllocator` is an [`IAllocator`][IAllocator]; it is actually an
> [`RCIAllocator`][RCIAllocator]), the mid-level `typed` module has a latent
> compile error for `shared` types ([§16](#_16-typedallocator-layer-2)), and the
> API may still change. The low-level building blocks and the `make`/`dispose`
> family are the stable, widely-used core.

---

## Background: four layers and two design commitments

The package DDoc lays out a four-layer architecture
(`package.d:73-121`):

1. **High-level, dynamically-typed** — [`theAllocator`][theAllocator] /
   [`processAllocator`][processAllocator] globals, the [`IAllocator`][IAllocator]
   interface, and type-aware helpers [`make`][make], [`makeArray`][makeArray],
   [`dispose`][dispose]. "This layer is all needed for most casual uses."
2. **Mid-level, statically-typed routing** — [`TypedAllocator`][TypedAllocator]
   dispatches by the _type_ being allocated ([§16](#_16-typedallocator-layer-2)).
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

Finally, the package's performance doctrine (`package.d:220-225`):

> "statically-typed assembled allocators are almost always faster than
> allocators that go through `IAllocator`. An important rule of thumb is:
> 'assemble allocator first, adapt to `IAllocator` after'."

---

## 1. The static allocator protocol

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

## 2. `Ternary`: three-state answers

Queries that an allocator may answer imprecisely return
[`std.typecons.Ternary`][Ternary] — `yes`, `no`, or `unknown` — rather than
`bool`:

- `owns` and `empty` return `yes`/`no` from static allocators that define them.
- At the **runtime interface boundary** ([§6](#_6-theallocator-processallocator-runtime-polymorphism)),
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

## 3. A minimal allocator from scratch

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

## 4. Heap sources

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

## 5. The high-level API: `make`, `makeArray`, `dispose` & friends

These free functions accept _any_ allocator — static building block or
`RCIAllocator` — and bridge from untyped `void[]` to typed objects.

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
byte counter as witness:

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

## 6. `theAllocator`, `processAllocator` & runtime polymorphism

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

## 7. Regions: bump-the-pointer allocation

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

## 8. Free lists

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
  [§14](#_14-case-study-a-jemalloc-style-composite).
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

## 9. `BitmappedBlock`: fixed blocks, one bit each

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

## 10. `KRRegion`: the Kernighan-Ritchie heap

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

## 11. `AscendingPageAllocator`: pages, monotonically

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

## 12. Combinators: routing requests

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

## 13. Metadata and instrumentation

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

## 14. Case study: a jemalloc-style composite

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

## 15. Sharing memory across threads

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

What exists for cross-thread use: the monostate heap sources ([§4](#_4-heap-sources))
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

## 16. `TypedAllocator` (layer 2)

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

## 17. Attribute reality: `@safe`, `@nogc`, `nothrow`, `pure`

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
  ([§6](#_6-theallocator-processallocator-runtime-polymorphism)).

---

## 18. Pitfalls checklist

- [ ] `Region`/`SbrkRegion` `deallocate` frees **only the last allocation**;
      `expand` works only on the last block ([§7](#_7-regions-bump-the-pointer-allocation)).
- [ ] Never copy a live region/bump allocator — duplicated bookkeeping hands
      out the same memory twice ([§7](#_7-regions-bump-the-pointer-allocation)).
- [ ] `KRRegion` needs a **word-aligned** buffer (assert at construction) and
      has a two-word minimum block ([§10](#_10-krregion-the-kernighan-ritchie-heap)).
- [ ] `makeArray!char(n)` gives `0xFF` bytes (`char.init`), not zeroes
      ([§5](#_5-the-high-level-api-make-makearray-dispose-friends)).
- [ ] `make!(T[])` returns a pointer to an _empty array_ — use `makeArray`
      ([§5](#_5-the-high-level-api-make-makearray-dispose-friends)).
- [ ] `expand(null, delta > 0)` and `expandArray` on a null array are `false`
      by specification ([§1](#_1-the-static-allocator-protocol)).
- [ ] Allocating with one allocator and deallocating with another is UB — set
      `theAllocator`/`processAllocator` once, early; containers should store
      their allocator ([§6](#_6-theallocator-processallocator-runtime-polymorphism)).
- [ ] `allocatorObject(a)` **moves** `a` in; pass stateful allocators by
      pointer to keep access ([§6](#_6-theallocator-processallocator-runtime-polymorphism)).
- [ ] `allocate(0)` returns `null` in every Phobos allocator; don't treat
      `null` from a zero-size request as failure ([§1](#_1-the-static-allocator-protocol)).
- [ ] `deallocate`'s `bool` mostly encodes _capability_, not per-call success —
      probe support with `deallocate(null)` at the dynamic layer
      ([§6](#_6-theallocator-processallocator-runtime-polymorphism)).
- [ ] `AlignedMallocator`: plain `reallocate` silently drops a custom
      alignment; Posix `alignedReallocate` is allocate-copy-free
      ([§4](#_4-heap-sources)).
- [ ] `Bucketizer` sizes outside `[min, max]` are illegal — front it with a
      `Segregator` ([§12](#_12-combinators-routing-requests)).
- [ ] `FreeList!(0, unbounded)` skips all size checks — only under a
      size-segregating parent ([§8](#_8-free-lists)).
- [ ] `TypedAllocator` cannot allocate `shared` types (missing
      `AllocFlag.forSharing`) ([§16](#_16-typedallocator-layer-2)).
- [ ] Docs lag code in places: `theAllocator` is an `RCIAllocator`, not an
      `IAllocator`; `allocateZeroed` exists but is undocumented and
      `package`-visibility.

---

## 19. Cheat sheet: which building block when

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
