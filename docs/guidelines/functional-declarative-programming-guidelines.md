# D Developer Guidelines: Functional & Declarative Programming

## Philosophy

D's greatest strength as a systems programming language is that it lets you write code that reads like a high-level declarative specification while compiling down to efficient machine code. Unlike most systems languages that force you into imperative, mutation-heavy patterns, D's design — ranges, templates, UFCS, compile-time evaluation, and purity — encourages a style where you _describe what you want_, not how to compute it step by step.

This document codifies that style into actionable guidelines. The overarching principle is: **separate the what from the how**. Separate algorithms from data structures. Separate transformation logic from iteration mechanics. Separate policy from mechanism. The result is code that is easier to reason about, easier to compose, easier to test, and — thanks to D's zero-cost abstractions — just as fast as hand-written imperative code.

---

## Relationship to Other Guidelines

- **[Code Style](code-style.md)** — Formatting, naming, and syntax conventions used in all examples in this document
- **[Design by Introspection](design-by-introspection-01-guidelines.md)** — Detailed patterns for capability detection (capability traits), optional primitives, and concepts. Section 6 of this document provides a functional programming perspective on these patterns; refer to the DbI guidelines for comprehensive coverage.

---

## 1. Prefer Declarative Pipelines Over Imperative Loops

### The Problem with Imperative Loops

Imperative loops mix together iteration, filtering, transformation, and accumulation into a single block of mutable state. This makes them hard to read, hard to compose, and hard to parallelize.

```d
// ❌ Imperative — intent is buried in mechanics
int[] results;
for (int i = 0; i < data.length; i++)
{
    if (data[i] > threshold)
    {
        results ~= data[i] * 2;
    }
}
```

### Declarative Alternative

```d
// ✅ Declarative — reads like a specification
auto results = data
    .filter!(x => x > threshold)
    .map!(x => x * 2);
```

The declarative version separates concerns: `filter` handles selection, `map` handles transformation. Each step is independently testable and reusable. The pipeline is lazy — no intermediate arrays are allocated.

### Guidelines

- **Use `std.algorithm` and `std.range` as your primary toolkit.** Functions like `map`, `filter`, `reduce`, `fold`, `zip`, `chain`, `chunks`, `enumerate`, `take`, `drop`, `until`, `retro`, `stride`, and `joiner` cover the vast majority of iteration patterns.
- **Express intent through named operations**, not control flow. If you're writing a `for` loop, ask whether the same thing can be expressed as a pipeline of standard operations.
- **Reserve imperative loops for genuinely stateful algorithms** where the loop body has complex, interdependent side effects that don't decompose into standard operations — for example, certain graph traversals or in-place partitioning schemes.

---

## 2. Embrace Lazy Evaluation and Streaming

### Why Laziness Matters

D ranges are lazy by default. When you write `data.filter!(x => x > 0).map!(x => x * 2)`, no work happens until someone consumes the result. This has profound implications for performance and composability.

- **No intermediate allocations.** A pipeline of five operations over a million-element array doesn't create five million-element temporary arrays. It processes each element through the entire pipeline before moving to the next.
- **Works with infinite sequences.** You can define `iota(1, int.max)` or `generate!(() => uniform(0, 100))` and combine them with `take`, `until`, or `find` to consume only what you need.
- **Enables streaming.** File I/O, network data, and generator functions can all present themselves as ranges and participate in the same pipelines as in-memory arrays.

### Practical Examples

```d
import std.algorithm.iteration : map, filter;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.range : chunks, recurrence, take;
import std.string : splitter, strip;

// Parse a space-separated string of ints lazily
auto ints = "1 3 2".splitter().map!(to!int);

// Pairwise sums without materializing intermediate state
auto pairSums = [1, 2, 3, 4].chunks(2).map!(chunk => chunk.sum);

// First 10 Fibonacci numbers as a lazy range
auto fibs = recurrence!((s, n) => s[n-1] + s[n-2])(1, 1).take(10);

// Read lines from stdin, process only those matching a pattern
auto matching = stdin.byLineCopy
    .filter!(line => line.canFind("ERROR"))
    .map!(line => line.strip);
```

### Guidelines

- **Defer materialization.** Don't call `.array` until you actually need a concrete array (e.g., for random access, passing to C code, or storing long-term). Let pipelines stay lazy as long as possible.
- **Use `std.range.generate` and `recurrence`** for sequences defined by a formula rather than stored data.
- **Compose range adaptors freely.** Because each adaptor returns a new range, you can build complex transformations from simple pieces: `data.enumerate.filter!(t => t.index % 2 == 0).map!(t => t.value)`.
- **Understand range categories.** Know the difference between `InputRange`, `ForwardRange`, `BidirectionalRange`, and `RandomAccessRange`. Choose the weakest category your algorithm needs — this maximizes the set of data sources it works with.

---

## 3. Separate Algorithms from Data Structures

### The N×M Problem

If you have N algorithms and M data structures, writing each algorithm specifically for each data structure requires N×M implementations. Ranges solve this by providing a common abstraction layer: algorithms operate on ranges, and data structures expose themselves as ranges.

### How Ranges Decouple Algorithms from Data

D's range concept defines a _capability trait_ — a template that detects whether a type supports certain operations, verified at compile time. Following the [concepts](https://github.com/atilaneves/concepts) library pattern, capability traits are best defined using a check function that exercises the exact expressions you intend to call:

```d
/// Check function that exercises the InputRange required primitives.
/// Using a check function (rather than a single-expression enum) provides
/// better error messages on constraint failure — the compiler shows which
/// specific operation failed.
void checkInputRange(R)(inout int = 0)
{
    R r = R.init;     // can define a range object
    if (r.empty) {}   // can test for empty
    r.popFront;       // can invoke popFront()
    auto h = r.front; // can get the front of the range
}

/// Capability trait: true if R satisfies the InputRange concept
enum isInputRange(R) = is(typeof(checkInputRange!R));
```

Any type satisfying this concept — arrays, linked lists, file streams, procedurally generated sequences — can be passed to any algorithm that accepts an `InputRange`. The algorithm doesn't know or care how the data is stored; it only knows how to access elements sequentially.

```d
import std.range.primitives : ElementType;
import std.algorithm.searching : find;

// This function works with ANY InputRange of comparable elements
auto findFirst(R)(R range, ElementType!R needle)
if (isInputRange!R)
    => range.find(needle);

// Works with arrays
[3, 1, 4, 1, 5].findFirst(4);

// Works with lazy ranges
iota(1, 1000).filter!(x => x % 7 == 0).findFirst(49);

// Works with file I/O
File("data.txt").byLine.findFirst("target");
```

### Guidelines

- **Write algorithms as templates constrained by range categories**, not concrete types. Use `if (isInputRange!R)`, `if (isRandomAccessRange!R)`, etc.
- **Expose your data structures as ranges.** Implement `empty`, `front`, `popFront()` (and `save` for `ForwardRange`, `back`/`popBack()` for `BidirectionalRange`, `opIndex` for `RandomAccessRange`).
- **Favor the weakest range category that suffices.** An algorithm that only needs sequential access should accept `InputRange`, not `RandomAccessRange`. This maximizes reuse.
- **Use `std.range.interfaces` sparingly.** The `InputRange!E` interface provides type-erased runtime polymorphism for ranges. Prefer templates for performance; use the interface only when you need to store heterogeneous ranges in a container or cross ABI boundaries.

---

## 4. Use UFCS to Build Fluent, Composable APIs

### What UFCS Enables

Uniform Function Call Syntax allows `fun(a, b)` to be written as `a.fun(b)`. This transforms free functions into what looks like method calls, enabling fluent chaining:

```d
import std.algorithm.iteration : filter, map;
import std.algorithm.sorting : sort;
import std.stdio : writeln;

// Without UFCS — deeply nested, reads inside-out
writeln(sort(filter!(x => x > 0)(map!(x => x * 2)(data))));

// With UFCS — linear, reads left-to-right
data.map!(x => x * 2)
    .filter!(x => x > 0)
    .sort
    .writeln;
```

### UFCS as a Design Tool

UFCS means you don't need to put every operation into a class or struct. You can define free functions that operate on any type and call them with method syntax. This is central to D's philosophy of separating algorithms from data:

```d
// Free function operating on any view type (from CyberShadow's image library).
auto crop(V)(in V src, int x0, int y0, int x1, int y1)
if (isView!V)
{
    /* ... */
}

// Used with UFCS — reads like a method chain
auto result = image
    .crop(10, 10, 90, 90)
    .vflip()
    .nearestNeighbor(200, 200);
```

### Guidelines

- **Design libraries as collections of free functions** that operate on well-defined concepts (like ranges or views). Let UFCS provide the method-call syntax.
- **Prefer free functions over methods** when the operation doesn't need access to private state. Free functions are more composable and can be extended by third parties.
- **Use UFCS chains for data transformation pipelines.** The left-to-right reading order matches the flow of data through the pipeline.
- **Name functions as verbs or transformations** (`filter`, `map`, `crop`, `scale`, `serialize`) to make UFCS chains read naturally.

---

## 5. Leverage Purity and Immutability

### D's Pragmatic Purity

D's `pure` attribute guarantees that a function does not access global mutable state. This is a contract between the function and its caller that enables both human reasoning and compiler optimization.

D's purity is _pragmatic_ rather than dogmatic. A pure function can mutate its arguments — it just can't touch anything else. This means you can write efficient imperative code inside a pure function while still providing referential transparency at the call site:

```d
// "Weakly" pure — mutates its argument, but touches no global state
void drawTriangle(Color[] framebuffer, in Triangle tri) pure
{
    // Imperative pixel-setting code here
}

// "Strongly" pure — immutable/const arguments make it referentially transparent
Color[] renderScene(in Triangle[] triangles, ushort w = 640, ushort h = 480) pure
{
    auto image = new Color[w * h];
    foreach (ref tri; triangles)
        drawTriangle(image, tri);
    return image;
}
```

The key insight: weakly pure functions (which mutate arguments) can be composed into strongly pure functions (which are referentially transparent). This lets you use mutation for performance internally while presenting a functional interface externally.

### Purity and Immutability Work Together

D provides several mechanisms for controlling mutability:

| Mechanism   | Kind                    | Guarantee                                                              |
| ----------- | ----------------------- | ---------------------------------------------------------------------- |
| `pure`      | Function attribute      | No access to global mutable state                                      |
| `in`        | Parameter storage class | Read-only parameter (`const scope`); preferred for function parameters |
| `const`     | Type qualifier          | Transitive read-only view (caller may have mutable access)             |
| `immutable` | Type qualifier          | Data can never change (enables sharing across threads)                 |

### Guidelines

- **Mark functions `pure` whenever possible.** If a function doesn't do I/O and doesn't access module-level or `static` variables, it should be `pure`. This is the single most impactful attribute for code quality.
- **Combine `pure` with `const`/`immutable` parameters** for strong purity guarantees. A `pure` function with only `const` or `immutable` parameters is referentially transparent — the compiler can cache results and reorder calls.
- **Use `in` for read-only parameters** as the default. It implies `const scope` and clearly signals intent. Use `const` when you need to return or store a reference to the data, or when interfacing with APIs that expect `const`.
- **Prefer `immutable` when data truly never changes.** `immutable` provides stronger guarantees for concurrency and optimization.
- **Use weak purity internally, strong purity at API boundaries.** Helper functions can mutate their arguments for efficiency; the public API presents a purely functional interface.

---

## 6. Design by Introspection and Concepts

> **See also:** [Design by Introspection Guidelines](design-by-introspection-01-guidelines.md) for comprehensive coverage of capability traits, optional primitives, fallback paths, and the shell-with-hooks pattern.

### Design by Introspection over OOP Interfaces

D's approach to polymorphism for high-performance code uses _capability traits_ — compile-time checks that detect whether a type supports certain operations. Unlike OOP interfaces, capability traits have zero runtime overhead: no vtable dispatch, no indirection, and full inlining.

Following DbI terminology:

- **Required primitives**: Operations a type MUST implement to participate
- **Optional primitives**: Operations a type MAY implement to enable extra behaviors
- **Capability trait**: A template that detects if a primitive exists with the right signature
- **Fallback path**: Baseline behavior using only required primitives
- **Fast path**: Optimized behavior enabled by optional primitives

### Example: View Capability Traits

The following example from CyberShadow's functional image processing library demonstrates capability traits for 2D views:

```d
/// Check function for the View concept (required primitives)
void checkView(V)(inout int = 0)
{
    V v = V.init;
    size_t w = v.w;      // must have width
    size_t h = v.h;      // must have height
    auto px = v[0, 0];   // must support 2D indexing
}

/// Capability trait: true if V satisfies the View concept
enum isView(V) = is(typeof(checkView!V));

/// Extract the color/pixel type of a view
alias ViewColor(V) = typeof(V.init[0, 0]);

/// Check function for writable views (optional primitive: pixel assignment)
void checkWritableView(V)(inout int = 0)
{
    checkView!V;                          // must be a view
    V v = V.init;
    v[0, 0] = ViewColor!V.init;           // must support pixel assignment
}

/// Capability trait for writable views
enum isWritableView(V) = is(typeof(checkWritableView!V));
```

Functions use template constraints to declare which capability traits they require:

```d
void blitTo(SRC, DST)(in SRC src, ref DST dst)
if (isView!SRC && isWritableView!DST)
{
    assert(src.w == dst.w && src.h == dst.h);
    foreach (y; 0 .. src.h)
        foreach (x; 0 .. src.w)
            dst[x, y] = src[x, y];
}
```

### Fast Path vs Fallback Path

When an optional primitive is available, use it for better performance; otherwise fall back to the baseline implementation:

```d
/// Capability trait for direct scanline access (optional primitive)
enum isDirectView(V) = isView!V && is(typeof(V.init.scanline(0)));

void blitTo(SRC, DST)(in SRC src, ref DST dst)
if (isView!SRC && isWritableView!DST)
{
    foreach (y; 0 .. src.h)
    {
        // Fast path: bulk copy when both support direct scanline access
        static if (isDirectView!SRC && isDirectView!DST)
        {
            dst.scanline(y)[] = src.scanline(y)[];
        }
        // Fallback path: element-by-element copy
        else
        {
            foreach (x; 0 .. src.w)
                dst[x, y] = src[x, y];
        }
    }
}
```

### Mixin Templates for Default Implementations

When a concept has operations that can be derived from a smaller set of primitives, use mixin templates to provide default implementations:

```d
/// Provides opIndex in terms of scanline access
mixin template DirectView()
{
    alias COLOR = typeof(scanline(0)[0]);

    ref COLOR opIndex(int x, int y)
    {
        return scanline(y)[x];
    }

    COLOR opIndexAssign(COLOR value, int x, int y)
    {
        return scanline(y)[x] = value;
    }
}

struct Image(COLOR)
{
    int w, h;
    COLOR[] pixels;

    COLOR[] scanline(int y)
    {
        return pixels[w * y .. w * (y + 1)];
    }

    mixin DirectView;  // Auto-generates opIndex from scanline
}
```

### Guidelines

- **Define capability traits using check functions** that exercise the exact expressions you intend to call. This provides better error messages than single-expression `enum` traits.
- **Name traits consistently**: `isX` for capability detection, `hasX` for member existence.
- **Use template constraints (`if (...)`)** on every templated function to document and enforce requirements.
- **Provide mixin templates for default implementations** derived from required primitives. This reduces boilerplate when implementing the interface.
- **Reserve OOP interfaces and classes for runtime polymorphism** (e.g., heterogeneous collections, plugin systems). For algorithmic code, capability traits give better performance and composability.

---

## 7. Build Composable, Layered Abstractions

### The Composability Principle

Small, focused components that transform input to output are more valuable than large, monolithic ones. In D, composability is achieved through ranges, UFCS, and template generics.

### Procedural/Virtual Views

A powerful pattern from CyberShadow's image processing library: define "views" that compute values on demand rather than storing them. These virtual views compose without allocating memory:

```d
import std.functional : binaryFun;

/// A procedural image — computes pixels on demand from a formula.
/// Returns a Voldemort type: a type defined inside the function with no
/// externally visible name. Users don't need to name it — they just
/// chain operations via UFCS.
template procedural(alias formula)
{
    auto procedural(int w, int h)
    {
        alias fun = binaryFun!(formula, "x", "y");
        alias COLOR = typeof(fun(0, 0));

        struct Procedural
        {
            int w, h;
            COLOR opIndex(int x, int y) => fun(x, y);
        }
        return Procedural(w, h);
    }
}

/// A solid color view — no memory allocation
auto solid(COLOR)(COLOR c, int w, int h)
    => procedural!((x, y) => c)(w, h);

/// Coordinate warp views — composable transformations
alias hflip = warp!(q{w-x-1}, q{y});
alias vflip = warp!(q{x}, q{h-y-1});

// Compose freely:
auto result = image.crop(10, 10, 90, 90).vflip().tile(400, 400);
```

Each transformation is a thin wrapper that delegates to the underlying view. The compiler inlines across all layers, producing code as efficient as a hand-written nested loop.

### Voldemort Types

A **Voldemort type** is a type defined inside a function whose name cannot be spoken outside that function. The type exists and can be used, but only through `auto` type inference:

```d
auto makeCounter(int start)
{
    // This struct is a Voldemort type — no external name
    struct Counter
    {
        int value;
        int next() => value++;
    }
    return Counter(start);
}

auto c = makeCounter(0);  // Works: type inferred as the anonymous Counter
c.next();                 // Works: can call methods
// Counter c2;            // Error: Counter is not accessible here
```

Voldemort types are ideal for range adaptors and view wrappers because:

- Users don't need to name intermediate types in a pipeline
- The type is an implementation detail that can change without breaking API
- The compiler can optimize aggressively since the type never escapes

### Guidelines

- **Favor thin wrapper types** that transform access to an underlying resource. These compose with zero overhead when the compiler inlines them.
- **Use Voldemort types** for return values of composable operations. The user doesn't need to name the type — they just chain operations.
- **Make `static if` decisions based on capabilities.** If the underlying type supports direct memory access, provide it; otherwise, fall back to element-by-element access (see Section 6).

---

## 8. Use Mir for Numerical and Multidimensional Work

### When Phobos Ranges Aren't Enough

For numerical computing, image processing, machine learning, and scientific work, the [Mir](http://mir-algorithm.libmir.org/) library extends D's range philosophy to multidimensional data.

### Key Mir Components

- **`mir.ndslice`** — Multidimensional array views (like NumPy's ndarray). Create views over flat memory with arbitrary dimensionality, striding, and slicing. Supports `Slice`, `iota`, `linspace`, and topology transformations.
- **`mir.algorithm.iteration`** — Multidimensional `each`, `reduce`, `fold` that work across all dimensions of an ndslice.
- **`mir.combinatorics`** — Lazy generation of permutations, combinations, and Cartesian products as ranges.
- **`mir-stat`** — Statistical functions (mean, variance, correlation, etc.) that operate on ranges and ndslices.
- **`mir.range`** — Extended range utilities that complement `std.range`.

### Example: Multidimensional Operations

```d
import mir.ndslice : slice, diagonal, transposed, flattened;

// Create a 3×4 matrix, initialize diagonal to 1
auto matrix = slice!double(3, 4);
matrix[] = 0;
matrix.diagonal[] = 1;

// Views are zero-cost — no data copying
auto row = matrix[2];         // View of third row
auto col = matrix[0 .. $, 1]; // View of second column

// Topology transformations compose like 1D ranges
auto transposed = matrix.transposed;
auto flattened = matrix.flattened;
```

### Guidelines

- **Use `mir.ndslice` for any multidimensional data.** Don't flatten 2D/3D data into 1D arrays and manually compute indices. Ndslice handles striding, slicing, and iteration correctly and efficiently.
- **Prefer ndslice topology operations** (transposition, reshaping, striding, windowing) over manual index arithmetic. These are zero-cost views.
- **Combine Mir with Phobos ranges.** Mir slices are compatible with `std.algorithm` — you can `map`, `filter`, and `reduce` over flattened slices.
- **Use `mir-stat` for statistical calculations** rather than rolling your own mean/variance/etc. The implementations handle numerical stability.

---

## 9. Compile-Time Evaluation for Zero-Cost Abstractions

### CTFE as a Design Tool

D's Compile-Time Function Evaluation allows running ordinary D code at compile time. This means you can compute lookup tables, parse configuration formats, validate invariants, and generate code — all before the program starts running.

```d
// Compute a lookup table at compile time
static immutable ubyte[256] popCountTable = ()
{
    ubyte[256] table;
    foreach (i; 0 .. 256)
        table[i] = cast(ubyte) countBitsNaive(i);
    return table;
}();

// String mixins for code generation from compile-time data
enum generateParser = parseGrammar(import("grammar.peg"));
mixin(generateParser);
```

### Interaction with Purity

CTFE requires functions to be evaluable at compile time, which means they must be `pure` (or at least not depend on runtime state). Writing pure functions thus has a double benefit: it enables both compiler optimization _and_ compile-time evaluation.

### Guidelines

- **Write functions to be CTFE-compatible when practical.** This usually means making them `pure` and avoiding inline assembly or `@system` pointer casts.
- **Use `static immutable` for precomputed tables.** They're initialized at compile time and placed in read-only memory.
- **Use `static assert` to validate invariants** at compile time rather than runtime.
- **Combine CTFE with string mixins sparingly.** Powerful but hard to debug — prefer templates and `static if` when they suffice.

---

## 10. Practical Patterns and Recipes

### Pattern: Split-Apply-Combine

```d
import std.algorithm.iteration : group, map;
import std.algorithm.searching : maxElement;
import std.algorithm.sorting : sort;
import std.array : array;
import std.string : toLower;
import std.uni : splitter = byGrapheme;  // or use std.algorithm.splitter

// Most common word in a string
auto mostCommon(string text)
{
    import std.algorithm.iteration : splitter;
    return text
        .toLower
        .splitter(' ')
        .array
        .sort()
        .group
        .maxElement!(g => g[1]);
}
```

### Pattern: Enumerate and Filter by Index

```d
import std.algorithm.iteration : filter, map, sum;
import std.range : enumerate;

// Sum even-indexed elements
auto result = [10, 20, 30, 40, 50]
    .enumerate
    .filter!(t => t.index % 2 == 0)
    .map!(t => t.value)
    .sum;
assert(result == 90);  // 10 + 30 + 50
```

### Pattern: Lazy Recursive Sequences

```d
import std.array : array;
import std.range : recurrence, take;

// Fibonacci sequence as an infinite lazy range
auto fibs = recurrence!((s, n) => s[n-1] + s[n-2])(1, 1);
auto first10 = fibs.take(10).array;
// [1, 1, 2, 3, 5, 8, 13, 21, 34, 55]
```

### Pattern: Chunked/Windowed Processing

```d
import std.algorithm.iteration : map, sum;
import std.range : slide;

// Moving average with a window of 3
auto movingAvg(R)(R data, size_t window)
    => data.slide(window).map!(w => w.sum / cast(double) window);
```

### Pattern: K-mer Enumeration (Bioinformatics)

```d
import std.algorithm.iteration : map;
import std.conv : to;
import std.range : slide;

auto kmers(size_t k)(string seq)
    => seq.slide(k).map!(window => window.to!string);
// "AGCGA".kmers!2 → ["AG", "GC", "CG", "GA"]
```

---

## Summary of Core Principles

1. **Declarative over imperative.** Express _what_ you want, not _how_ to compute it. Use range pipelines as your default idiom.
2. **Lazy over eager.** Don't allocate intermediate results. Let pipelines stream elements through transformations on demand.
3. **Algorithms over data structures.** Write generic functions constrained by range categories. Expose your data types as ranges.
4. **UFCS for composability.** Design libraries as free functions on concepts. UFCS provides fluent chaining for free.
5. **Purity for reasoning.** Mark functions `pure` to guarantee no hidden global state. Combine with `const`/`immutable` for referential transparency.
6. **Design by Introspection over OOP.** Use check functions and template constraints for zero-overhead polymorphism. Reserve classes for runtime dispatch.
7. **Thin composable layers.** Prefer many small wrappers (often Voldemort types) over monolithic components. The compiler inlines across layers for zero-cost abstraction.
8. **Compile time over runtime.** Precompute what you can with CTFE. Validate invariants with `static assert`. Generate specialized code with templates.

---

## References

- [Functional Image Processing in D](https://blog.cy.md/2014/03/21/functional-image-processing-in-d/) — CyberShadow's composable view/image library
- [std.range — Phobos](https://dlang.org/phobos/std_range.html) — D's standard range primitives
- [Component Programming with Ranges](http://wiki.dlang.org/Component_programming_with_ranges) — DWiki article on range-based design
- [Ranges — Programming in D](https://ddili.org/ders/d.en/ranges.html) — Ali Çehreli's comprehensive range tutorial
- [Mir Algorithm](http://mir-algorithm.libmir.org/) — Multidimensional ranges and numerical computing
  - [mir.ndslice](http://mir-algorithm.libmir.org/mir_ndslice.html) — N-dimensional array views
  - [mir.algorithm.iteration](http://mir-algorithm.libmir.org/mir_algorithm_iteration.html) — Multidimensional iteration
  - [mir.combinatorics](http://mir-algorithm.libmir.org/mir_combinatorics.html) — Lazy combinatorial ranges
  - [mir-stat](http://mir-stat.libmir.org/) — Statistical functions for ranges/slices
- [atilaneves/concepts](https://github.com/atilaneves/concepts) — Better template constraint diagnostics
- [D Idioms](https://p0nce.github.io/d-idioms/) — Idiomatic D patterns and best practices
- [Pragmatic D Tutorial: Idiomatic D](https://qznc.github.io/d-tut/idiomatic.html) — Constness, purity, and ranges
- [Rosetta Code: D](https://rosettacode.org/wiki/Category:D) — D solutions to common programming tasks
- [Purity in D](https://klickverbot.at/blog/2012/05/purity-in-d/) — David Nadlinger on D's pragmatic purity design
- [D Functional Garden](https://garden.dlang.io/) — Functional range pipeline examples
