# Design by Introspection in D: Developer Guidelines

A practical guide to the Design-by-Introspection (DbI) paradigm — what it is, why it matters, and how to apply it effectively in D projects.

---

## What Is Design by Introspection?

Design by Introspection is a programming paradigm first articulated by Andrei Alexandrescu at [DConf 2017](https://www.youtube.com/watch?v=HdzwvY8Mo-w) ([slides](https://dconf.org/2017/talks/alexandrescu.pdf)). It builds on Policy-Based Design (from _Modern C++ Design_) but takes a fundamentally different stance on how components negotiate capabilities.

The paradigm rests on three tenets:

**The Rule of Optionality.** Component primitives are almost entirely opt-in. A component is required to implement only a minimal core — everything else is optional. The component is free to implement any subset of the optional primitives.

**The Rule of Introspection.** A component's consumer uses compile-time introspection to discover which primitives the component actually provides, and adapts its own behavior accordingly.

**The Rule of Elastic Composition.** A component assembled by composing several other components offers capabilities _in proportion to_ the capabilities offered by its parts. Composition neither demands nor discards capabilities needlessly.

The practical consequence: where traditional generic programming requires _all-or-nothing_ conformance to interfaces (you either implement the full concept or you don't), DbI produces components that _gracefully degrade_. Less capable building blocks yield reduced features instead of compilation errors.

### Where DbI Sits Among Paradigms

Consider the progression:

**Design Patterns** — The programmer is the code generator. Patterns are mental templates that humans expand into bespoke code. Maximum plasticity, zero code reuse.

**Policy-Based Design** — The programmer controls a code generator. Templates are assembled from rigid policy components at compile time. Good code reuse, but no adaptability — every policy must implement a fixed interface.

**Design by Introspection** — The programmer molds generators that _communicate with and adapt to one another_. Good plasticity _and_ good code reuse. Components negotiate capabilities at compile time through introspection rather than demanding conformance to rigid contracts.

### Why D Is Uniquely Suited

DbI requires three language capabilities:

1. **Introspection input** — the ability to query types for their members, signatures, and attributes. D provides `__traits`, `.tupleof`, `std.traits`, and `is()` expressions.

2. **Compile-time processing** — the ability to make decisions based on introspection results. D provides `static if`, `static foreach`, and full CTFE (compile-time function evaluation).

3. **Code generation output** — the ability to produce new code based on those decisions. D provides template expansion, `mixin`, and string mixins.

Each `static if` branch doubles the design space covered by a single piece of source code. With _n_ optional primitives, a DbI component compactly represents up to 2^n behavioral variations — written once as linear code.

---

## The Core Pattern: Shell With Hooks

The fundamental DbI architecture is a **shell** that drives **hooks**. The shell handles common concerns (type system integration, operator overloading boilerplate, composition mediation) while hooks customize behavior through optional intercept points.

```d
struct Widget(T, Hook = DefaultHook) {
    private T payload;

    // Stateless hooks consume no space
    static if (stateSize!Hook > 0)
        Hook hook;
    else
        alias hook = Hook;

    void doWork() {
        // Probe for hook capability, adapt accordingly
        static if (hasMember!(Hook, "onBeforeWork"))
            hook.onBeforeWork(payload);

        // ... core logic ...

        static if (hasMember!(Hook, "onAfterWork"))
            hook.onAfterWork(payload);
        else static if (hasMember!(Hook, "onComplete"))
            hook.onComplete();
        // else: no hook — default behavior, no overhead
    }
}
```

Key properties of this pattern:

- **Zero-cost when unused.** If a hook defines no members and carries no state, the shell behaves identically to hand-written code with no hook infrastructure. The compiler eliminates dead `static if` branches entirely.

- **Graceful degradation.** A `Hook = void` or empty hook doesn't cause errors — it simply yields default behavior. This is valuable for dry-run validation, incremental development, and covering a larger design space.

- **Proportional response.** The hook only needs to implement what it cares about. There is no need to stub out unused interface members, implement no-op methods, or inherit from abstract bases.

---

## Real-World DbI: Case Studies

### 1. Ranges in Phobos

D's range abstraction ([`std.range`](https://dlang.org/phobos/std_range.html)) was an early and influential departure from rigid generic programming. The range hierarchy uses introspection rather than nominal subtyping:

```d
// A minimal InputRange — just these two
struct MinimalRange {
    int front() { return current; }
    void popFront() { ... }
    bool empty() { return done; }
}

// A richer range that also offers length and random access
struct RichRange {
    int front() { return data[index]; }
    void popFront() { index++; }
    bool empty() { return index >= data.length; }

    // Optional capabilities — algorithms detect these
    size_t length() { return data.length - index; }
    int opIndex(size_t i) { return data[index + i]; }
    RichRange save() { return this; }
}
```

Algorithms in `std.algorithm` probe for these capabilities:

```d
// From std.algorithm (simplified)
auto find(Range, T)(Range haystack, T needle) {
    // Use length hint if available for better diagnostics/optimization
    static if (hasLength!Range)
        immutable len = haystack.length;

    // Use random access if available for O(1) indexing
    static if (isRandomAccessRange!Range)
        return optimizedFind(haystack, needle);
    else
        return linearFind(haystack, needle);
}
```

The DbI insight Alexandrescu identified in his ["Generic Programming Must Go"](https://www.youtube.com/watch?v=mCrVYYlFTrA) talk ([slides](https://dconf.org/2015/talks/alexandrescu.pdf)) is that D's range system had _already betrayed_ classical generic programming. Instead of naming every combination (`InputRangeWithLength`, `ForwardRangeWithSlicing`, `BidirectionalRangeWithLengthAndSlicing` …), D uses trait predicates like `hasLength`, `isInfinite`, `hasSlicing`, and `hasMobileElements` that can be combined freely. This keeps the concept space compact rather than suffering a combinatorial explosion of named interfaces.

### 2. `std.experimental.allocator` — The Flagship Example

The allocator building blocks ([`std.experimental.allocator.building_blocks`](https://dlang.org/phobos/std_experimental_allocator_building_blocks.html)) are the canonical DbI showcase. Memory allocation is a _high-vocabulary domain_ — alignment, dynamic alignment, quantization, in-place expansion, reallocation, ownership queries, deallocation, statefulness, thread-safety — and the combinatorial explosion of these concerns makes rigid interface hierarchies impractical.

The allocator framework requires only two things:

```d
// Minimal allocator — this is all that's required
struct Region {
    enum uint alignment = 16;

    void[] allocate(size_t n) {
        if (e - p < n) return null;
        auto result = p[0 .. n];
        p += n;
        return result;
    }
}
```

Everything else — `deallocate`, `reallocate`, `expand`, `owns`, `deallocateAll`, `resolveInternalPointer` — is optional. Composite allocators discover what their components offer and propagate capabilities elastically:

```d
struct FallbackAllocator(Primary, Fallback) {
    Primary primary;
    Fallback fallback;

    enum alignment = min(Primary.alignment, Fallback.alignment);

    // Always available — this is the core contract
    void[] allocate(size_t n) {
        auto r = primary.allocate(n);
        return r !is null ? r : fallback.allocate(n);
    }

    // Only available if Primary can determine ownership AND
    // at least one allocator supports deallocation
    static if (hasMember!(Primary, "owns")
            && (hasMember!(Primary, "deallocate")
            || hasMember!(Fallback, "deallocate")))
    void deallocate(void[] b) {
        if (primary.owns(b)) {
            static if (hasMember!(Primary, "deallocate"))
                primary.deallocate(b);
        } else {
            static if (hasMember!(Fallback, "deallocate"))
                fallback.deallocate(b);
        }
    }

    // Only available if both components support ownership queries
    static if (hasMember!(Primary, "owns")
            && hasMember!(Fallback, "owns"))
    bool owns(void[] b) {
        return primary.owns(b) || fallback.owns(b);
    }
}
```

The result: approximately 12 KLOC covers an unbounded space of allocator designs. By comparison, jemalloc implements a _single_ allocator in roughly 45 KLOC. A `Segregator` can split allocations by size class. A `StatsCollector` can wrap any allocator with instrumentation. A `FreeList` can add freelisting to any allocator that supports deallocation. These compose freely, and the composed result faithfully reflects the union of capabilities its parts provide.

### 3. `std.checkedint` — Compact Power

[`std.checkedint`](https://dlang.org/phobos/std_checkedint) demonstrates DbI at a smaller scale. The `Checked` type wraps an integral and delegates overflow/error behavior to a hook:

```d
struct Checked(T, Hook = Abort) if (isIntegral!T) {
    private T payload;

    // Stateless hook optimization
    static if (stateSize!Hook > 0)
        Hook hook;
    else
        alias hook = Hook;

    // Configurable default value
    static if (hasMember!(Hook, "defaultValue"))
        private T payload = Hook.defaultValue!T;

    // Increment with optional hook intercepts
    ref Checked opUnary(string op)() return
    if (op == "++" || op == "--") {
        // Priority 1: full intercept
        static if (hasMember!(Hook, "hookOpUnary"))
            hook.hookOpUnary!op(payload);
        // Priority 2: overflow-specific handler
        else static if (hasMember!(Hook, "onOverflow")) {
            if (payload == max.payload)
                payload = hook.onOverflow!"++"(payload);
            else
                ++payload;
        }
        // Priority 3: no hook — raw operation, no checking
        else
            mixin(op ~ "payload;");

        return this;
    }
}
```

The available hook primitives include `defaultValue`, `min`, `max`, `hookOpCast`, `hookOpEquals`, `hookOpCmp`, `hookOpUnary`, `hookOpBinary`, and `onOverflow`. None are required. A `Checked!(int, void)` behaves identically to a plain `int` — useful for validating that your code works before layering on checks.

The entire implementation (code + tests + documentation) is about 3 KLOC, versus 5-7 KLOC for comparable C++ libraries that use traditional policy-based design and cover fewer configurations.

### 4. Mir's `ndslice`

The [Mir `ndslice`](http://mir-algorithm.libmir.org/mir_ndslice.html) library applies DbI principles to n-dimensional array slicing. Slices are parameterized over their iterator type and dimensionality, and the available operations adapt based on what the underlying iterator supports. A contiguous memory iterator yields different optimizations than a strided or sparse iterator, and the `ndslice` machinery introspects to determine which paths are available.

### 5. `expected` — DbI for Error Handling

The [`expected`](https://github.com/tchaloupka/expected) library ([docs](https://tchaloupka.github.io/expected/expected.html)) applies DbI to the Expected/Result idiom. The `Expected!(T, E, Hook)` type customizes its behavior through a hook that can optionally define:

| Hook Member                 | Effect                                                   |
| --------------------------- | -------------------------------------------------------- |
| `enableDefaultConstructor`  | Allow/disallow default construction                      |
| `enableCopyConstructor`     | When disabled, enables automatic result-checked tracking |
| `enableRefCountedPayload`   | Use refcounted storage for unchecked-result detection    |
| `enableVoidValue`           | Allow `Expected!(void, E)`                               |
| `onAccessEmptyValue`        | Custom behavior when accessing value on an error state   |
| `onAccessEmptyError`        | Custom behavior when accessing error on a value state    |
| `onUnchecked`               | Handler when result is dropped without inspection        |
| `onValueSet` / `onErrorSet` | Intercepts for logging, telemetry, or behavioral change  |

Predefined hooks demonstrate the range: `Abort` (assert on misuse), `Throw` (throw on misuse), `AsException` (throw at construction time — making `Expected` behave like traditional exception handling), and `RCAbort` (refcounted with automatic unchecked-result detection).

A single generic type covers error-handling strategies that would otherwise require separate implementations or complex class hierarchies.

---

## Design Guidelines

### When to Reach for DbI

DbI is most valuable when your domain has **high vocabulary** — many independent, orthogonal capabilities that combine in numerous ways. If you find yourself naming every combination of features, or if adding a new capability requires updating an interface hierarchy, DbI is likely a better fit.

Good candidates include: resource management (allocators, handles, pools), numeric types (checked arithmetic, fixed-point, interval), container abstractions (ranges, iterators, slices), error handling strategies, serialization formats, and middleware/hook systems.

DbI is _less_ suited for domains with small, stable vocabularies where a traditional interface or sum type is clearer. Not every struct with a template parameter needs to be a DbI component.

### Designing the Shell

**Keep the required interface minimal.** The power of DbI comes from optionality. If you demand too much from the hook, you lose the graceful degradation that makes the pattern worthwhile. `std.experimental.allocator` requires only `alignment` and `allocate` — everything else is discovered.

**Document the hook protocol thoroughly.** Since hooks aren't enforced by an `interface` keyword, the documentation _is_ the contract. For each optional primitive, document its signature, when it's called, what the shell does if it's absent, and the interaction with other primitives. The `expected` library's hook table is a good model.

**Layer the fallback chain.** When probing for hook capabilities, establish a clear priority:

```d
// 1. Full override — hook takes complete control
static if (hasMember!(Hook, "hookOperation"))
    hook.hookOperation(args);
// 2. Specific intercept — hook handles the interesting case
else static if (hasMember!(Hook, "onSpecificEvent"))
    // ... shell logic that calls hook at the critical point ...
// 3. Default — no hook involvement
else
    // ... plain behavior, zero overhead ...
```

**The `void` hook test.** If your design works with `Hook = void` (yielding baseline behavior), the shell is well-factored. This is the "dry run" property — it validates that the shell stands on its own and the hook system is purely additive.

### Designing Hooks

**Hooks should be small and focused.** A hook is not a god object. It's a collection of optional intercept points, ideally stateless. When a hook does carry state, the shell should use the `stateSize` pattern to avoid paying for empty state:

```d
static if (stateSize!Hook > 0)
    Hook hook;
else
    alias hook = Hook;
```

**Provide predefined hooks for common cases.** Users shouldn't need to write a hook for the 80% use case. `std.checkedint` provides `Abort`, `Warn`, `ProperCompare`, and `WithNaN`. `expected` provides `Abort`, `Throw`, `AsException`, and `RCAbort`. The defaults should be sensible — `Abort` is a safe starting point.

**Allow composition of hooks when practical.** If hooks are small, users will want to combine them. Consider whether your shell can accept a hook that forwards to multiple sub-hooks.

### Composites and Elastic Propagation

**Propagate capabilities faithfully.** A composite should not claim capabilities its parts don't support, and should not silently discard capabilities that _are_ available. The `FallbackAllocator` example demonstrates this: `deallocate` is only defined when ownership can be determined and at least one component supports deallocation.

**Self-introspect when useful.** A composite can introspect its _own_ conditionally-defined members. From the allocator's `reallocate`:

```d
static if (hasMember!(typeof(this), "deallocate"))
    deallocate(b);
```

This avoids duplicating the conditions that determine whether `deallocate` exists.

**Test the edges.** Compose your building blocks with minimal components (empty hooks, `void` hooks, components offering only the required minimum) to verify graceful degradation. Then compose with fully-capable components to verify that nothing is lost.

---

## Practical Patterns and Idioms

### Trait Predicates Over Named Concepts

Prefer orthogonal Boolean predicates over named concept hierarchies:

```d
// Prefer: orthogonal traits
enum hasLength(R) = is(typeof(R.init.length) : size_t);
enum hasSlicing(R) = is(typeof(R.init[0 .. 1]));
enum isInfinite(R) = is(typeof(R.init.empty) == bool) && !R.init.empty;

// Avoid: combinatorial explosion of named concepts
// InputRangeWithLength, ForwardRangeWithSlicing, ...
```

These compose freely in `static if` conditions and template constraints without naming the power set.

### Compile-Time Interface Documentation

Since DbI interfaces aren't enforced by a language-level `interface`, use an `enum`-based checklist or a template that produces clear error messages:

```d
/// Verifies that A is a valid allocator and provides diagnostics
template isAllocator(A) {
    // Required
    enum hasAlignment = is(typeof(A.alignment) : uint);
    enum hasAllocate = is(typeof(A.init.allocate(size_t.init)) : void[]);

    enum isAllocator = hasAlignment && hasAllocate;
}

// Use in template constraints for clear errors
auto doAllocatorWork(A)(ref A alloc) if (isAllocator!A) {
    ...
}
```

### The Optional-Method Forwarding Pattern

When wrapping a DbI component, forward its optional capabilities:

```d
struct Wrapper(Inner) {
    Inner inner;

    // Always forward the required interface
    void[] allocate(size_t n) { return inner.allocate(n); }
    enum alignment = Inner.alignment;

    // Conditionally forward optional capabilities
    static if (hasMember!(Inner, "deallocate"))
        void deallocate(void[] b) { inner.deallocate(b); }

    static if (hasMember!(Inner, "owns"))
        bool owns(void[] b) { return inner.owns(b); }

    static if (hasMember!(Inner, "expand"))
        bool expand(ref void[] b, size_t delta) {
            return inner.expand(b, delta);
        }
}
```

This ensures wrappers (logging, instrumentation, thread-safety) don't silently drop capabilities.

### `static if` Hygiene

Each `static if` doubles the design space, so keep individual branches small and testable:

```d
// Good: clear, self-contained branches
static if (hasMember!(Hook, "onOverflow")) {
    if (wouldOverflow) payload = hook.onOverflow(payload);
    else ++payload;
} else {
    ++payload;
}

// Avoid: deeply nested static if chains that are hard to reason about
static if (X) {
    static if (Y) {
        static if (Z) {
            // 8 possible paths — hard to verify coverage
        }
    }
}
```

When you have many interacting optional features, factor them into separate methods rather than nesting.

---

## Common Pitfalls

**Over-engineering hooks.** Not every template parameter is a hook point. If the customization has only 2-3 meaningful variations, an `enum`-based flag or a simple `static if` is clearer than full DbI machinery.

**Forgetting the default path.** Every `static if (hasMember!(Hook, ...))` needs an `else` that does something reasonable. If you find that the `else` branch can't do anything useful and must be an error, that primitive might actually be _required_, not optional.

**Opaque error messages.** When a DbI component rejects a type, the user may see deep template instantiation errors. Invest in template constraints with clear diagnostics. Use `pragma(msg)` during development to inspect what the compiler sees.

**Testing only the happy path.** The power of DbI is the combinatorial design space. Test with minimal hooks, maximal hooks, and adversarial combinations. The `Checked!(int, void)` pattern — using a null hook to get baseline behavior — should be a standard test case for any DbI component.

---

## References

- **Design by Introspection** — Andrei Alexandrescu, DConf 2017: [Video](https://www.youtube.com/watch?v=HdzwvY8Mo-w), [Abstract](https://dconf.org/2017/talks/alexandrescu.html), [Slides](https://dconf.org/2017/talks/alexandrescu.pdf)
- **Generic Programming Must Go** — Andrei Alexandrescu, DConf 2015: [Video](https://www.youtube.com/watch?v=mCrVYYlFTrA), [Slides](https://dconf.org/2015/talks/alexandrescu.pdf)
- **`std.range`** — Phobos range primitives: [Documentation](https://dlang.org/phobos/std_range.html)
- **`std.experimental.allocator`** — Allocator building blocks: [Documentation](https://dlang.org/phobos/std_experimental_allocator_building_blocks.html)
- **`std.checkedint`** — Checked integral types: [Documentation](https://dlang.org/phobos/std_checkedint)
- **Mir `ndslice`** — N-dimensional slicing: [Documentation](http://mir-algorithm.libmir.org/mir_ndslice.html)
- **`expected`** — Expected idiom with DbI hooks: [Repository](https://github.com/tchaloupka/expected), [Documentation](https://tchaloupka.github.io/expected/expected.html)
