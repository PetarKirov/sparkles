# Rust's Implicit Effect System (Rust)

Rust encodes effects as independent language features -- async, fallibility, iteration, constness, and unsafety -- each with its own keyword and trait mechanism, rather than providing a unified algebraic effect system.

| Field         | Value                                                                                     |
| ------------- | ----------------------------------------------------------------------------------------- |
| Language      | Rust                                                                                      |
| License       | MIT / Apache-2.0 (Rust itself)                                                            |
| Repository    | [github.com/rust-lang/rust](https://github.com/rust-lang/rust)                            |
| Documentation | [doc.rust-lang.org](https://doc.rust-lang.org/)                                           |
| Key Authors   | without.boats (coroutine-effect analysis), Yoshua Wuyts (keyword generics), Niko Matsakis |
| Approach      | Per-effect keywords and traits lowered to coroutine state machines                        |

---

## Overview

### What It Solves

Rust does not have a formal, unified effect system. Instead, it provides a collection of independent language features that each address a specific kind of effectful computation. Each feature has its own syntax, trait, and compilation strategy. The result is a pragmatic but fragmented approach where effects are encoded implicitly through type signatures and keywords rather than declared explicitly through a single effect abstraction.

The five primary effect-like features in Rust are:

| Effect            | Keyword / Syntax   | Trait / Type            | Status (2025)                                   |
| ----------------- | ------------------ | ----------------------- | ----------------------------------------------- |
| Asynchrony        | `async` / `.await` | `Future`                | Stable                                          |
| Fallibility       | `?` operator       | `Result<T, E>`          | Stable                                          |
| Iteration         | `gen` / `yield`    | `Iterator`              | Keyword reserved (2024 edition), blocks nightly |
| Compile-time eval | `const fn`         | (constness constraint)  | Stable, const traits nightly                    |
| Safety boundary   | `unsafe`           | (not a semantic effect) | Stable                                          |

### Design Philosophy

Rust prioritizes zero-cost abstractions and explicit control over runtime behavior. Each effect-like feature is designed to compile down to efficient, predictable machine code -- typically through state machine transformations for `async` and `gen`, monadic chaining via `?` for errors, and compile-time evaluation for `const fn`. This per-effect approach avoids the overhead of a general-purpose effect runtime but creates a "function coloring" problem where each effect introduces a distinct function flavor that does not compose generically with others.

---

## Core Abstractions and Types

### Async / Await (Asynchrony Effect)

Async functions compile to state machines implementing the `Future` trait. Each `.await` point becomes a state transition:

```rust
use std::future::Future;
use std::pin::Pin;
use std::task::{Context, Poll};

// The Future trait -- Rust's encoding of the async effect
trait Future {
    type Output;
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output>;
}

// An async fn is syntactic sugar for a function returning impl Future
async fn fetch_data(url: &str) -> Result<String, Error> {
    let response = client.get(url).await?;  // .await suspends here
    let body = response.text().await?;       // and here
    Ok(body)
}
```

The compiler transforms this into a self-referential state machine. `Pin` is required because the state machine may hold references across yield points, and moving it would invalidate those references.

### Result / ? Operator (Fallibility Effect)

The `?` operator provides early return on error, functioning as a monadic bind:

```rust
// Without ? -- explicit pattern matching
fn read_config(path: &str) -> Result<Config, Error> {
    let contents = match std::fs::read_to_string(path) {
        Ok(s) => s,
        Err(e) => return Err(e.into()),
    };
    let config = match toml::from_str(&contents) {
        Ok(c) => c,
        Err(e) => return Err(e.into()),
    };
    Ok(config)
}

// With ? -- desugared to the same thing
fn read_config(path: &str) -> Result<Config, Error> {
    let contents = std::fs::read_to_string(path)?;
    let config = toml::from_str(&contents)?;
    Ok(config)
}
```

### Gen Blocks (Iteration Effect)

RFC 3513 reserves `gen` in the 2024 edition. Gen blocks produce `Iterator` values via `yield`, mirroring how `async` blocks produce `Future` values:

```rust
// Nightly syntax (gen blocks)
#![feature(gen_blocks)]

fn fibonacci() -> impl Iterator<Item = u64> {
    gen {
        let (mut a, mut b) = (0, 1);
        loop {
            yield a;
            (a, b) = (b, a + b);
        }
    }
}
```

Like async functions, gen blocks compile to state machines. Unlike the full `Coroutine` trait (nightly), gen blocks cannot hold references across yield points in the current design.

### Const Fn (Constness Effect)

`const fn` restricts a function to operations that can be evaluated at compile time:

```rust
const fn factorial(n: u64) -> u64 {
    if n == 0 { 1 } else { n * factorial(n - 1) }
}

// Evaluated at compile time
const FACT_10: u64 = factorial(10);

// Also callable at runtime
let runtime_result = factorial(5);
```

Const functions cannot allocate, access globals, or perform I/O. This is the inverse of most effects: rather than adding a capability, `const` removes capabilities to guarantee compile-time evaluability.

### Unsafe (Safety Boundary)

After discussion with Ralf Jung, the Rust keyword generics initiative concluded that `unsafe` is not semantically an effect. It is a contract mechanism that shifts proof obligations to the caller rather than adding or removing computational capabilities:

```rust
// unsafe fn: caller promises preconditions are met
unsafe fn deref_raw<T>(ptr: *const T) -> &'static T {
    &*ptr
}

// unsafe block: programmer asserts safety invariants hold
let value = unsafe { deref_raw(some_ptr) };
```

---

## How Effects Are Declared

Each effect is declared through distinct syntax. There is no unified effect declaration mechanism:

```rust
// Async effect: declared with `async` keyword
async fn fetch(url: &str) -> String { /* ... */ }

// Fallibility effect: declared via return type
fn parse(input: &str) -> Result<Value, ParseError> { /* ... */ }

// Iteration effect: declared with gen (nightly)
gen fn numbers() -> i32 { yield 1; yield 2; yield 3; }

// Constness: declared with const keyword
const fn square(x: i32) -> i32 { x * x }

// Safety: declared with unsafe keyword
unsafe fn raw_access(ptr: *mut u8) -> u8 { *ptr }
```

The function signature encodes which effects are in play. A function that is both async and fallible must combine the mechanisms:

```rust
// Combining async + fallibility
async fn fetch_and_parse(url: &str) -> Result<Data, Error> {
    let resp = client.get(url).await?;  // both .await and ? in one expression
    Ok(resp.json().await?)
}
```

---

## How Handlers/Interpreters Work

Rust does not have general-purpose effect handlers. Each effect has its own "handling" mechanism:

| Effect      | Handler mechanism                                                      |
| ----------- | ---------------------------------------------------------------------- |
| Async       | Runtime executor (`tokio::runtime`, `async-std`, `smol`) polls futures |
| Fallibility | Caller uses `match`, `?`, `.unwrap()`, or combinators                  |
| Iteration   | `for` loop or iterator combinators (`.map()`, `.filter()`, etc.)       |
| Constness   | Compiler evaluates at compile time in const contexts                   |
| Unsafe      | Programmer provides proof of safety via `unsafe` block                 |

```rust
// "Handling" the async effect: an executor drives the future
#[tokio::main]
async fn main() {
    let data = fetch_data("https://example.com").await;
}

// "Handling" the fallibility effect: match on the result
fn main() {
    match read_config("config.toml") {
        Ok(config) => run(config),
        Err(e) => eprintln!("Error: {e}"),
    }
}

// "Handling" the iteration effect: for loop
fn main() {
    for n in fibonacci().take(10) {
        println!("{n}");
    }
}
```

---

## Performance Approach

Rust compiles each effect to zero-cost abstractions:

- **Async**: State machines with no heap allocation for the frame itself (the caller decides where to store it). No implicit boxing unless using `Box<dyn Future>`.
- **Fallibility**: `Result<T, E>` is a plain enum. The `?` operator compiles to a branch instruction. No exception tables, no stack unwinding.
- **Iteration**: Gen blocks compile to state machines identical to hand-written iterator implementations.
- **Constness**: Evaluated at compile time via CTFE (Compile-Time Function Evaluation). Zero runtime cost.

This per-effect compilation strategy avoids the overhead of a general-purpose effect runtime or continuation-passing transform, but also prevents generic composition across effects.

---

## Composability Model

### The Function Coloring Problem

Each effect introduces a "color" that propagates through the call graph. An async function can only be awaited from another async function (or a runtime entry point). A `const fn` can only call other `const fn`s. This creates parallel ecosystems:

```rust
// Sync version
fn read_file(path: &str) -> Result<String, io::Error> {
    std::fs::read_to_string(path)
}

// Async version -- different color, different ecosystem
async fn read_file(path: &str) -> Result<String, io::Error> {
    tokio::fs::read_to_string(path).await
}
```

Library authors must often maintain both sync and async versions of their APIs, leading to code duplication. Crates like `maybe_async` attempt to paper over this with macros, but the solution is limited.

### The Keyword Generics Initiative

The keyword generics initiative (led by Yoshua Wuyts and Oli Scherer) proposes making functions generic over effects. The proposed syntax uses `#[maybe(async)]` annotations:

```rust
// Proposed syntax (not yet implemented)
#[maybe(async)]
fn copy<R: Read, W: Write>(reader: &mut R, writer: &mut W) -> Result<u64, Error> {
    let mut buf = vec![0u8; 8192];
    loop {
        let n = reader.read(&mut buf).await?;
        if n == 0 { break; }
        writer.write_all(&buf[..n]).await?;
    }
}
```

The initiative frames this as effect generics: a function that is generic over whether it runs synchronously or asynchronously, similar to how generic functions are parameterized over types. The key insight is that the API surface explosion is combinatorial -- with five effects, a single trait family like `Fn` would need up to 96 variants.

### Coroutines as a Unifying Mechanism

without.boats has argued that Rust's async functions and generators are both instances of stackless coroutines, and that coroutines and algebraic effect systems are "in some ways isomorphic to one another." The coroutine frame is the universal lowering target: each effect operation becomes a yield point in the state machine, and the handler (executor, for-loop, match) drives the coroutine by resuming it.

This analysis suggests that Rust already has the low-level machinery for a general effect system but lacks the high-level abstraction to unify the per-effect syntax and trait families.

---

## Strengths

- Zero-cost compilation for every effect -- no runtime overhead, no boxing, no vtables (unless explicitly opted into)
- Each effect is well-understood in isolation with clear, predictable semantics
- Ownership and borrowing provide compile-time guarantees about resource safety that interact naturally with effects
- The `?` operator is arguably the most ergonomic error handling in any systems language
- Async/await enables high-performance concurrent I/O without garbage collection or a heavy runtime
- The per-effect approach avoids the complexity of a full effect type system

## Weaknesses

- Function coloring creates parallel ecosystems (sync vs async, const vs non-const) with code duplication
- No way to abstract over effects generically -- library authors must choose or duplicate
- Combining multiple effects (async + fallible + generator) requires ad-hoc composition rather than principled effect rows
- No first-class effect handlers -- cannot swap the interpretation of an effect at the call site
- Pin and self-referential state machines add significant complexity to async Rust
- No equivalent to algebraic effect handler resumption (one-shot or multi-shot continuations)
- The "effect" framing is implicit -- Rust programmers must learn each feature individually rather than understanding a unified concept

## Key Design Decisions and Trade-offs

| Decision                        | Rationale                                                       | Trade-off                                                  |
| ------------------------------- | --------------------------------------------------------------- | ---------------------------------------------------------- |
| Per-effect keywords             | Each effect gets optimized syntax and compilation               | No generic composition; combinatorial API explosion        |
| State machine lowering          | Zero-cost; no heap allocation for coroutine frames              | Pin complexity; self-referential types are hard            |
| Result instead of exceptions    | Explicit, zero-cost error handling; no hidden control flow      | Verbose for deep call chains; no stack traces by default   |
| No effect polymorphism          | Simpler type system; each effect independently stable           | Code duplication between sync/async, const/non-const       |
| unsafe is not an effect         | Keeps effect system compositional; unsafe is a proof obligation | Cannot abstract over safety boundaries generically         |
| External iteration (pull-based) | Composable with ownership; lazy by default                      | Cannot express push-based or concurrent iteration natively |

---

## Sources

- [Coroutines and effects -- without.boats](https://without.boats/blog/coroutines-and-effects/)
- [The registers of Rust -- without.boats](https://without.boats/blog/the-registers-of-rust/)
- [Extending Rust's effect system -- Yoshua Wuyts](https://blog.yoshuawuyts.com/extending-rusts-effect-system/)
- [Keyword Generics Initiative](https://rust-lang.github.io/keyword-generics-initiative/)
- [Announcing the Keyword Generics Initiative -- Inside Rust Blog](https://blog.rust-lang.org/inside-rust/2022/07/27/keyword-generics.html)
- [A universal lowering strategy for control effects in Rust -- Abubalay](https://www.abubalay.com/blog/2024/01/14/rust-effect-lowering)
- [RFC 3513: gen blocks](https://rust-lang.github.io/rfcs/3513-gen-blocks.html)
- [Const traits -- Rust Project Goals 2024h2](https://rust-lang.github.io/rust-project-goals/2024h2/const-traits.html)
- [Rust async is colored, and that's not a big deal -- More Stina Blog](https://morestina.net/1686/rust-async-is-colored)
- [In Defense of Async: Function Colors Are Rusty -- The Coded Message](https://www.thecodedmessage.com/posts/async-colors/)
