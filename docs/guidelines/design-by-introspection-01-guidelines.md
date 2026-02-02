# Design by Introspection (DbI) — Standard for D

## 1. Purpose and Scope

### 1.1 Quick Mental Model

DbI components are **shells with hooks**. The shell handles boilerplate (operators, type integration, composition). The hook customizes behavior through **optional** intercept points discovered via `static if` at compile time.

Less capable hooks → reduced features, not errors. Each `static if` doubles the design space covered by a single codebase.

### 1.2 When to Use DbI

**Use when:**

- The domain has high vocabulary — many independent, orthogonal capabilities that combine in numerous ways
- Building generic algorithms (ranges, iterators, adapters)
- Building wrappers with pluggable semantics (checked arithmetic, error-handling, allocators)
- Supporting ecosystem interop (conversion hooks like `asSlice`, `asRange`, `toX`)
- You find yourself naming every combination of features or adding capability requires updating an interface hierarchy

Good fits: allocators, numeric wrappers, error handling strategies, container/range abstractions, serialization, middleware/hook systems.

**Do NOT use when:**

- The domain has a small, stable vocabulary with 2-3 variations (a simple `enum` flag or sum type is clearer)
- The domain truly needs a fixed, strict interface (e.g., security-critical authentication APIs)
- You need runtime substitution and dynamic loading (use interfaces/classes)
- You cannot specify stable semantics for "missing capability"
- The "optional" primitives would change semantics in surprising ways

---

## 2. Normative Language

The keywords are interpreted as strict requirements (RFC 2119 style):

- **MUST / MUST NOT** — absolute requirement or prohibition
- **SHOULD / SHOULD NOT** — recommended, but exceptions may exist with justification
- **MAY** — truly optional

---

## 3. Definitions

- **Required primitive:** A member/function/property a type MUST implement to participate.
- **Optional primitive / hook:** A member/function/property a type MAY implement to enable extra behaviors (performance, safety, semantics).
- **Capability trait:** A template/enum that detects if a primitive exists with the right signature/semantics.
- **Fallback path:** Correct baseline behavior requiring only required primitives.
- **Fast path:** Specialized behavior enabled by optional primitives.
- **Hook / policy:** A customization type that optionally provides named members that alter behavior.
- **Precedence order:** The documented rule that determines which hook/primitive wins when multiple options could apply.

---

## 4. Core Rules

### 4.1 Required Primitives

- Components **MUST** define a minimal required set.
- Required primitives **MUST** remain stable across minor versions.
- Required primitives **MUST** be semantically clear, hard to regret, and cheap to implement.
- Adding a new required primitive **MUST** be treated as a breaking change.

### 4.2 Optional Primitives

- Optional primitives **MUST** be truly optional: absence **MUST NOT** break correctness.
- Optional primitives **MUST** be discoverable by introspection (traits / `__traits(compiles, ...)`).
- Optional primitives **SHOULD** be orthogonal (avoid overlapping ambiguously unless precedence is defined).
- Adding a new optional primitive **SHOULD** be non-breaking.
- Each optional primitive **MUST** document: capability name, detection rule, and behavioral impact.

### 4.3 Introspection and Capability Detection

- Capability detection **MUST** be centralized into named traits/templates.
- Code **MUST NOT** scatter ad-hoc `__traits(compiles, ...)` checks throughout business logic.
- Detection traits **MUST** check the exact expression you intend to call, not just `hasMember`.
- Detection results **MUST** be cached in `enum` values to avoid repeated instantiation. Note that defining the result as `enum bool` inside a template (as shown below) accomplishes this automatically — the `enum` is computed once per unique instantiation and reused thereafter.

**Naming convention:**

- `hasX!T` — member existence / valid call
- `supportsX!T` — higher-level semantic capability
- `canX!(T, Args...)` — when args affect the check

**Template pattern:**

```d
enum bool hasPutMany(R, E) = __traits(compiles, {
    R r = R.init;
    E[] xs;
    r.putMany(xs);  // exact intended expression
});
```

### 4.4 Elastic Composition

- When composing components (wrappers, allocators, adapters), the composite **MUST** expose capabilities that reflect its parts.
- Composites **MUST NOT** claim capabilities their parts don't support.
- Composites **MUST NOT** silently drop capabilities that are available.
- Composition order effects **MUST** be documented and tested.

**Self-introspection pattern:**

```d
// Composite queries its own conditionally-defined members
static if (hasMember!(typeof(this), "deallocate"))
    deallocate(b);
```

---

## 5. Shell and Hook Design

### 5.1 Shell Responsibilities

The shell (wrapper type) **MUST** handle:

- Operator overloads
- `@property` / `ref` / `scope` / `nothrow` forwarding where appropriate
- Value storage and conversions
- Invariants independent of policy

### 5.2 Hook Responsibilities

The hook (policy) **MUST** handle:

- Optional intercepts
- Reporting / logging / throwing / aborting
- Alternate semantics (explicitly named)

Hook members **MUST** be optional. Absence **MUST** produce default behavior.

### 5.3 Stateless vs Stateful Hooks

- If hook has no state, the wrapper **SHOULD** avoid storing it:

```d
static if (stateSize!Hook > 0)
    Hook hook;
else
    alias hook = Hook;
```

- If hook has state, wrapper **MUST** store it and document: initialization rules, copy/move semantics, thread-safety expectations.

### 5.4 Precedence Order

If multiple hook mechanisms can apply, use this order:

1. **Full override** hook (e.g., `hookOpUnary`, `hookOpBinary`) — takes complete control
2. **Event hooks** (e.g., `onOverflow`, `onError`, `onAccess`) — observe/handle at critical point
3. **Fallback/default behavior**

A single hook **MUST** provide at most one override for a given hook primitive. If a shell accepts multiple hooks, the shell **MUST** define how they are composed and their relative precedence.

This precedence **MUST** be documented and tested. Changing precedence is a breaking change.

**Dispatch pattern:**

```d
static if (hasOverrideOp!Hook)
{
    return hook.overrideOp(args);   // override wins
}
else static if (hasOnEvent!Hook)
{
    hook.onEvent(args);             // event next
    return fallback(args);          // then fallback
}
else
{
    return fallback(args);
}
```

### 5.5 Attribute Propagation

DbI shells often need to conditionally propagate function attributes (`@safe`, `nothrow`, `@nogc`, `pure`) based on hook capabilities. The shell **SHOULD** infer attributes from the hook's members where possible, using `@safe`, `nothrow`, etc. inference or explicit attribute forwarding.

**Pattern:**

```d
struct Wrapper(T, Hook)
{
    // Attributes inferred from hook.onEvent and fallbackOp
    auto doOp(Args...)(Args args)
    {
        static if (hasOnEvent!Hook)
            hook.onEvent(args);
        return fallbackOp(args);
    }
}
```

When attribute inference is insufficient, use explicit conditional attributes:

```d
auto doOp(Args...)(Args args) @safe if (isSafe!(Hook.onEvent))
```

---

## 6. Fallbacks and Fast Paths

### 6.1 Baseline Correctness

- Every DbI component **MUST** implement a baseline correct fallback requiring only required primitives.
- The fallback path **MUST** define semantics ("reference behavior").
- The fallback **MUST** be the semantic reference implementation.

### 6.2 Fast Path Equivalence

- Fast paths **MUST** be behaviorally equivalent to fallback (or document and justify exceptions).
- Fast paths **SHOULD** be "obviously better" (fewer allocations, lower complexity).
- If a fast path risks semantic drift, it **MUST** be opted into explicitly via a clearly named hook.
- Types **MUST NOT** implement an optional primitive that only works sometimes — either it works or omit it.

**Example pattern:**

```d
void putAll(R, E)(ref R r, E[] xs)
{
    static if (hasBulkPut!(R, E))
    {
        r.putMany(xs);              // O(1) fast path
    }
    else
    {
        foreach (x; xs) r.put(x);   // O(n) fallback
    }
}
```

---

## 7. `static if` Hygiene

### 7.1 Branch Documentation

- Each `static if` fork **MUST** correspond to a documented behavior mode.
- Each fork **MUST** have test coverage for both branches.
- Forks **SHOULD** be ordered from most specific to least specific.
- Forks **MUST NOT** silently change user-visible semantics unless the hook name communicates that semantic shift.

### 7.2 Avoiding Deep Nesting

- Keep branches short and self-contained.
- Factor complex multi-feature interactions into separate methods rather than nesting.

**Do:**

```d
static if (hasMember!(Hook, "onOverflow"))
{
    if (wouldOverflow) payload = hook.onOverflow(payload);
    else ++payload;
}
else
{
    ++payload;
}
```

**Don't:**

```d
static if (X) {
    static if (Y) {
        static if (Z) { /* 8 paths, hard to verify */ }
    }
}
```

### 7.3 The `void` Hook Test

`Widget!(T, void)` **SHOULD** compile and behave as the baseline with no hook involvement. Use this as a smoke test that the shell stands alone.

---

## 8. Diagnostics

### 8.1 Fail Early with Clear Messages

- Public templates/functions **MUST** use constraints to fail early and clearly.
- If no fallback exists, code **MUST** `static assert` with a targeted message that:
  - Names the missing capability
  - Shows the required expression form

```d
static assert(hasFront!R, "R must support `.front` (readable).");
static assert(hasPopFront!R, "R must support `.popFront()`.");
```

For richer diagnostics, consider the [`concepts`](https://github.com/atilaneves/concepts) library, which instantiates the checking code on constraint failure to reveal the specific compilation error rather than just reporting a failed constraint.

### 8.2 Constraints Over Deep Instantiation

- "Late failure" inside deeply-nested templates **SHOULD NOT** be the primary diagnostic mechanism.
- Errors **MUST** be phrased in terms of the user's type and required capability, not internal templates.

### 8.3 Optional Debug Tracing

- Components **MAY** provide optional debug tracing for dispatch decisions behind `version = DbIDebug` or a `debug` conditional.
- Such tracing **MUST NOT** change semantics.

---

## 9. Testing Requirements

### 9.1 Capability Matrix

For every DbI component, tests **MUST** cover:

1. **Minimal implementation** — only required primitives
2. Each optional primitive enabled **individually** (where meaningful)
3. Important combinations (2–3-way) that change behavior
4. Order-dependent composition cases (wrapping/policy stacking)

### 9.2 Equivalence Tests

- When there is a fallback + fast path, tests **MUST** assert they produce identical results across representative inputs.

### 9.3 Compile-Time Tests

- Use `static assert` / `__traits(compiles)` in test modules to ensure expected capability detection outcomes.
- Test positive cases, negative cases, and signature mismatch cases (ensures you are not over-accepting).

### 9.4 The `void` Hook Baseline Test

- The `void` hook baseline test is **mandatory** for any new DbI component.

---

## 10. API Evolution

### 10.1 Non-Breaking Changes

The following **SHOULD** be non-breaking when done correctly:

- Adding a new optional primitive (with fallback)
- Adding a new optional hook member (with default behavior unchanged)
- Adding new fast paths guarded by capability checks

Requirements:

- Fallback behavior unchanged
- Precedence unchanged
- Tests added
- Docs updated

### 10.2 Breaking Changes

The following **MUST** be treated as breaking changes:

- Adding a new required primitive
- Changing required primitives
- Changing the semantics of existing primitives
- Changing dispatch precedence
- Removing or renaming recognized hook members without deprecation

### 10.3 Deprecation

- Breaking removals **SHOULD** go through deprecation first, with clear migration guidance.

---

## 11. PR Review Checklist

Reviewers **MUST** confirm:

- [ ] Required primitive set did not grow unintentionally
- [ ] New optional hooks are truly optional (fallback unaffected)
- [ ] Capability checks validate the correct call form (not just `hasMember`)
- [ ] `static if` forks are documented and tested
- [ ] Precedence rules are explicit and preserved
- [ ] Diagnostics are readable at the call site
- [ ] Test matrix covers minimal + key combinations
- [ ] Any semantic changes are clearly named and documented
- [ ] Stateless hooks don't allocate/store state
- [ ] Examples show minimal and enhanced implementations

---

## 12. Do / Don't Summary

| Do                                         | Don't                                           |
| ------------------------------------------ | ----------------------------------------------- |
| Make primitives optional by default        | Require a large interface upfront               |
| Provide `else` for every `static if`       | Leave missing-hook paths as compile errors      |
| Ship predefined hooks for common cases     | Force users to write a hook for basic usage     |
| Document hook protocol as a table          | Rely on code-reading to understand the protocol |
| Use `stateSize` zero-cost optimization     | Waste space on empty hook structs               |
| Test with `void`/minimal hooks             | Only test with fully-capable hooks              |
| Propagate capabilities in composites       | Silently drop optional methods in wrappers      |
| Use orthogonal trait predicates            | Name every combination of capabilities          |
| Keep `static if` branches flat             | Nest 3+ levels of `static if`                   |
| Centralize capability detection in traits  | Scatter `__traits(compiles)` throughout code    |
| Use distinctive hook names (`hookOpUnary`) | Use generic names (`handle`, `process`)         |
| Fail early with constraints                | Let errors surface deep in template internals   |

---

## 13. Reference Implementations

| Library                      | What to Learn                                                                        | Link                                                                             |
| ---------------------------- | ------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------- |
| `std.experimental.allocator` | Flagship DbI: elastic composition, minimal required interface, composite propagation | [docs](https://dlang.org/phobos/std_experimental_allocator_building_blocks.html) |
| `std.range` / Phobos ranges  | Orthogonal trait predicates over named concepts, algorithm adaptation                | [docs](https://dlang.org/phobos/std_range.html)                                  |
| `std.checkedint`             | Shell-with-hooks at small scale, layered fallback chains, `void` hook baseline       | [docs](https://dlang.org/phobos/std_checkedint.html)                             |
| Mir `ndslice`                | DbI for n-dimensional iteration, iterator-capability-driven optimization             | [docs](http://mir-algorithm.libmir.org/mir_ndslice.html)                         |
| `expected`                   | Hook protocol documentation table, predefined hook variants, error handling DbI      | [docs](https://tchaloupka.github.io/expected/expected.html)                      |

---

## Appendix A: Code Templates

### A.1 Capability Detection Trait (Expression-Based)

```d
module mylib.detail.capabilities;

template hasBulkPut(R, E)
{
    enum bool hasBulkPut = __traits(compiles, {
        R r = R.init;
        E[] xs;
        r.putMany(xs);  // exact intended expression
    });
}

template hasOnError(H, Err)
{
    enum bool hasOnError = __traits(compiles, {
        H h = H.init;
        Err e = Err.init;
        h.onError(e);
    });
}
```

### A.2 Ordered Dispatch with Fallback

```d
import mylib.detail.capabilities : hasBulkPut;

void putAll(R, E)(ref R r, E[] xs)
{
    static if (hasBulkPut!(R, E))
    {
        r.putMany(xs);              // fast path
    }
    else
    {
        foreach (x; xs) r.put(x);   // fallback
    }
}
```

### A.3 Optional Hook Member Call

```d
void doThing(Hook, Err)(ref Hook hook, Err err)
{
    static if (hasOnError!(Hook, Err))
        hook.onError(err);
    else
        assert(0, "Unhandled error");  // default policy
}
```

### A.4 Hook Override vs Event Precedence

```d
auto performOp(Hook, Args...)(ref Hook hook, Args args)
{
    // 1. Full override — hook takes complete control
    static if (hasMember!(Hook, "hookOperation"))
    {
        return hook.hookOperation(args);
    }
    // 2. Event hook — observe at critical point
    else static if (hasMember!(Hook, "onOperationEvent"))
    {
        hook.onOperationEvent(args);
        return fallbackOperation(args);
    }
    // 3. Default — no hook, no overhead
    else
    {
        return fallbackOperation(args);
    }
}
```

### A.5 Zero-State Optimization

```d
struct Wrapper(T, Hook = DefaultHook)
{
    T payload;

    // Store hook only if it has state
    static if (stateSize!Hook > 0)
        Hook hook;
    else
        alias hook = Hook;

    // Access hook uniformly
    static if (stateSize!Hook > 0)
        ref inout(Hook) getHook() inout { return hook; }
    else
        static Hook getHook() { return Hook.init; }
}
```

### A.6 Validation Trait for Required Interface

Two styles for the same trait:

```d
// Style 1: Single-expression eponymous enum — compact, but diagnostics
// only report "isAllocator failed" without indicating which check failed.
enum isAllocator(A) =
  is(typeof(A.allocate(size_t.init)) == void[]) &&
  is(typeof(A.alignment) : size_t);

// Style 2: Template with named intermediate checks — more verbose, but
// each sub-check can be inspected individually for better diagnostics.
template isAllocator(A)
{
    enum hasAlignment = is(typeof(A.alignment) : size_t);
    enum hasAllocate = is(typeof(A.init.allocate(size_t.init)) : void[]);
    enum isAllocator = hasAlignment && hasAllocate;
}

// Use in constraints for clear errors at call site
auto doWork(A)(ref A alloc) if (isAllocator!A)
{
    // ...
}
```

---

## Appendix B: References

**Design by Introspection (DConf 2017)**

- Video: <https://www.youtube.com/watch?v=HdzwvY8Mo-w>
- Talk page: <https://dconf.org/2017/talks/alexandrescu.html>
- Slides: <https://dconf.org/2017/talks/alexandrescu.pdf>

**Generic Programming Must Go (DConf 2015)**

- Video: <https://www.youtube.com/watch?v=mCrVYYlFTrA>
- Slides: <https://dconf.org/2015/talks/alexandrescu.pdf>

**Phobos Ranges**

- <https://dlang.org/phobos/std_range.html>
- <https://dlang.org/library/std/range/primitives.html>

**std.experimental.allocator**

- <https://dlang.org/phobos/std_experimental_allocator.html>
- <https://dlang.org/phobos/std_experimental_allocator_building_blocks.html>

**std.checkedint**

- <https://dlang.org/phobos/std_checkedint.html>

**Mir NdSlice**

- <http://mir-algorithm.libmir.org/mir_ndslice.html>

**expected**

- Repository: <https://github.com/tchaloupka/expected>
- Documentation: <https://tchaloupka.github.io/expected/expected.html>
