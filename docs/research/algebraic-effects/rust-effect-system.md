# Rust's Implicit Effect System (Rust)

An analysis of how Rust already has an implicit effect system through async, const, unsafe, and other keyword-based effect markers, despite lacking explicit effect handlers.

| Field       | Value                                                         |
| ----------- | ------------------------------------------------------------- |
| Language    | Rust (stable)                                                 |
| Focus       | Analysis of existing language effect markers                  |
| Key Authors | without.boats (blog series), Rust language team               |
| Approach    | Keyword-based effect tracking without general effect handlers |

---

## Overview

### What This Is

Rust does not have user-defined algebraic effect handlers, but it **does** have a form of implicit effect system. The language tracks certain computational capabilities through keywords (`async`, `const`, `unsafe`) that behave similarly to effect annotations in other languages. Understanding these existing mechanisms clarifies both what Rust already achieves and what gaps remain.

### Design Philosophy

Rust prioritizes zero-cost abstractions and explicit control. The language effects that _are_ tracked (async, const, unsafe) are those where the overhead of tracking is minimal and the benefit (memory safety, compile-time evaluation) is substantial. General effect handlers have not been prioritized because:

1. No consensus on the right trade-offs for Rust's constraints (zero-cost, no runtime)
2. Existing patterns (CPS, generics) cover many use cases
3. The complexity budget is spent on ownership/borrowing, which already provides significant capability control

---

## Core Abstractions and Types

### The "Function Coloring" Effect System

without.boats and others have analyzed Rust's keywords as an implicit effect system:

| Keyword  | Effect Meaning              | Propagation                   | Composition                   |
| -------- | --------------------------- | ----------------------------- | ----------------------------- |
| `async`  | May suspend at await points | `async fn` calls `async fn`   | `.await` at call sites        |
| `const`  | Compile-time evaluable      | `const fn` calls `const fn`   | Must be `const` context       |
| `unsafe` | May break memory safety     | `unsafe fn` calls `unsafe fn` | `unsafe` blocks at call sites |
| `?`      | May return early via Err    | `?` in fallible functions     | Return type must match        |

Each of these creates a "color" that functions must match. An `async fn` can only call other `async` functions (or functions that return futures). A `const fn` can only call other `const` functions. This is effect polymorphism through keyword propagation.

### The Function Coloring Problem

The "function coloring" blog post by Robert Nystrom (not Rust-specific) pointed out that async/await creates a split where:

- Red functions (async) can call blue functions (sync) easily
- Blue functions (sync) calling red functions (async) requires ceremony

Rust's `async`/`.await` exhibits this exactly. The general problem is: when an effect is introduced, how do you handle code that doesn't use that effect calling code that does?

Rust's answer varies by effect:

- **async**: Requires `.await` (explicit suspension point)
- **const**: Not callable from non-const contexts without compile-time guarantees
- **unsafe**: Requires `unsafe` block (explicit opt-in to potential UB)
- **?**: Requires compatible return types

---

## How Effects Are Declared

### Keyword-Based Declaration

Effects are declared at the function level through keywords:

```rust
// async effect: may suspend
async fn fetch_data() -> Result<Data, Error> {
    let response = reqwest::get("...").await?;
    response.json().await
}

// const effect: compile-time evaluable
const fn compute_size() -> usize {
    1024 * 64  // can be used in array sizes, const contexts
}

// unsafe effect: memory safety responsibility
unsafe fn transmute_bytes<T>(bytes: [u8; size_of::<T>()]) -> T {
    // Bypasses borrow checker, caller must ensure validity
    std::mem::transmute(bytes)
}

// ? effect: early return via Result
fn fallible_operation() -> Result<(), MyError> {
    let x = another_fallible()?;  // may return early with Err
    Ok(x)
}
```

### Type System Integration

Each effect keyword has corresponding type system support:

- `async fn` returns `impl Future<Output = T>`
- `const fn` can be evaluated at compile time in const contexts
- `unsafe fn` requires `unsafe` block to call
- `?` works via the `Try` trait with associated `Output` type

---

## How Handlers/Interpreters Work

### The Runtime as Handler

Unlike algebraic effect systems where handlers are user-defined, Rust's effects are "handled" by the language runtime or compilation process:

**Async**: The async runtime (Tokio, async-std) handles await points by suspending and resuming tasks.

```rust
// The runtime handles the suspension/resumption
tokio::spawn(async {
    let data = fetch_data().await;  // suspend here, resume when ready
});
```

**Const**: The compiler's const evaluator handles const evaluation.

**Unsafe**: The programmer (via `unsafe` block) takes responsibility -- no runtime check.

**?**: The `Try` trait's `branch` method handles the control flow transformation.

### No User-Defined Handlers

The critical difference from languages like [Koka], [OCaml 5], or Haskell's [eff] is that Rust does **not** allow user-defined handlers for these effects. You cannot:

- Intercept an `await` and provide a different async semantics
- Handle `?` with custom error recovery at the call site
- Redefine what `unsafe` means

The effects are baked into the language and handled by the compiler/runtime.

---

## Composability Model

### Effect Composition Through Generics

Rust's primary mechanism for effect-like composition is the trait system. Instead of effect rows or handlers, you use bounds:

```rust
// Effect polymorphism via generic bounds
async fn process<T, F>(items: Vec<T>, f: F) -> Vec<Result<T, Error>>
where
    F: AsyncFn(T) -> Result<Processed, Error>,
{
    // Can process items concurrently because f is async
    futures::stream::iter(items)
        .map(|item| f(item))
        .buffer_unordered(10)
        .collect()
        .await
}
```

This achieves some effect polymorphism but without the full handler mechanism.

### Coroutines as a Unifying Mechanism

without.boats has argued that Rust's async functions and generators are both instances of stackless coroutines, and that coroutines and algebraic effect systems are "in some ways isomorphic to one another." The coroutine frame is the universal lowering target: each effect operation becomes a yield point in the state machine, and the handler (executor, for-loop, match) drives the coroutine by resuming it.

This analysis suggests that Rust already has the low-level machinery for a general effect system but lacks the high-level abstraction to unify the per-effect syntax and trait families. See [effing-mad] for a library that builds algebraic effects on Rust's nightly coroutine feature.

---

## Strengths

- **Zero-cost abstractions**: async/await, const evaluation compile to efficient code
- **Explicit is better than implicit**: Effect boundaries are visible at call sites (`.await`, `unsafe` blocks)
- **Compositional through traits**: The effect-like patterns compose through generics and bounds
- **Strong static guarantees**: const and unsafe have clear semantic boundaries
- **Production battle-tested**: The async ecosystem (Tokio, etc.) is mature and widely used

## Weaknesses

- **No user-defined handlers**: Cannot abstract over control flow the way algebraic effects do
- **Function coloring problem**: async/sync split creates library ecosystem friction
- **No effect rows**: Cannot easily express "this function uses effects A and B"
- **Inconsistent effect syntax**: Each effect (async, const, unsafe, ?) has different syntax and rules
- **No resumption control**: Cannot implement backtracking, nondeterminism, or custom control flow

## Key Design Decisions and Trade-offs

| Decision                     | Rationale                                     | Trade-off                                          |
| ---------------------------- | --------------------------------------------- | -------------------------------------------------- |
| Keyword-based effects        | Minimal syntax overhead; clear visual markers | Inconsistent between effects; no general mechanism |
| No user-defined handlers     | Complexity budget; zero-cost constraint       | Cannot abstract over control flow patterns         |
| Runtime/async executor model | Performance; ecosystem flexibility            | Function coloring; library dependencies            |
| Separate unsafe keyword      | Security; explicit opt-in to UB               | Verbose; some safe operations require unsafe       |
| No effect polymorphism       | Type system simplicity                        | Less expressive than full effect systems           |

---

## Comparison with Full Effect Systems

| Feature              | Rust (implicit)                | [Koka]           | [OCaml 5]             | [eff] (Haskell)  |
| -------------------- | ------------------------------ | ---------------- | --------------------- | ---------------- |
| Effect declaration   | Keywords                       | `effect` keyword | `effect` keyword      | GADT data types  |
| Effect composition   | Manual/traits                  | Row polymorphism | Untyped at runtime    | Type-level lists |
| User handlers        | No                             | `handle`         | `match...with effect` | `handle`         |
| Continuation capture | No (stackless coroutines only) | Yes              | Yes (one-shot)        | Yes              |
| Resumption control   | No (runtime managed)           | Yes              | Yes                   | Yes              |

---

## Sources

- [What I want from async in Rust -- without.boats]
- [Async functions in traits are just regular generic functions -- without.boats]
- [Rust async fundamentals]
- [The Rust Programming Language -- Async/Await]
- [Function Coloring is a Myth -- Robert Nystrom]
- [RFC 2394: Async/Await]
- [RFC 2920: Const Generics]
- [Const evaluation -- Rust Reference]
- [Unsafe Rust -- Rust Book]
- [The Try trait -- Rust RFC]

<!-- References -->

[Koka]: koka.md
[OCaml 5]: ocaml-effects.md
[eff]: haskell-eff.md
[effing-mad]: rust-effing-mad.md
[What I want from async in Rust -- without.boats]: https://without.boats/blog/what-i-want-from-async/
[Async functions in traits are just regular generic functions -- without.boats]: https://without.boats/blog/async-generics/
[Rust async fundamentals]: https://rust-lang.github.io/async-book/
[The Rust Programming Language -- Async/Await]: https://doc.rust-lang.org/book/ch17-01-async-await.html
[Function Coloring is a Myth -- Robert Nystrom]: https://journal.stuffwithstuff.com/2015/02/01/what-color-is-your-function/
[RFC 2394: Async/Await]: https://rust-lang.github.io/rfcs/2394-async_await.html
[RFC 2920: Const Generics]: https://rust-lang.github.io/rfcs/2920-const-generics.html
[Const evaluation -- Rust Reference]: https://doc.rust-lang.org/reference/const_eval.html
[Unsafe Rust -- Rust Book]: https://doc.rust-lang.org/book/ch19-01-unsafe-rust.html
[The Try trait -- Rust RFC]: https://rust-lang.github.io/rfcs/3058-try-trait-v2.html
