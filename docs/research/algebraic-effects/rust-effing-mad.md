# effing-mad (Rust)

An algebraic effects library for Rust built on nightly coroutines, providing typed effect handlers with composable effect rows in a style analogous to async/await.

| Field         | Value                                                                                    |
| ------------- | ---------------------------------------------------------------------------------------- |
| Language      | Rust (nightly)                                                                           |
| License       | MIT OR Apache-2.0                                                                        |
| Repository    | [github.com/rosefromthedead/effing-mad](https://github.com/rosefromthedead/effing-mad)   |
| Documentation | [docs.rs/effing-mad](https://docs.rs/effing-mad/latest/effing_mad/)                      |
| Key Authors   | Rose Hudson                                                                              |
| Encoding      | Coroutine-based yield/resume with typed effect traits and macro-generated state machines |

---

## Overview

### What It Solves

effing-mad brings algebraic effects and effect handlers to Rust. It addresses the function coloring problem by allowing a single effectful function to be handled differently depending on the call site -- the same I/O-performing function can be called from a synchronous context, an async context, or a test context, with different handlers providing different semantics each time.

The library demonstrates that Rust's nightly coroutine feature (originally built for async/await compilation) is general enough to implement full algebraic effects. Effectful functions yield typed effect values to their callers, which handle those effects and resume the function with a typed injection value.

### Design Philosophy

The design mirrors Rust's async/await model: just as an `async fn` returns a `Future` that must be driven by an executor, an `#[effectful(...)]` function returns a `Computation` that must have its effects handled before it can be run. Effects are peeled off one at a time through `handle`, and once all effects are discharged, the bare computation is executed with `run`.

This creates a clear separation between effect declaration (what a function needs) and effect interpretation (what a caller provides), which is the core promise of algebraic effect systems.

---

## Core Abstractions and Types

### The Effect Trait

Every effect is a type implementing the `Effect` trait. The `Injection` associated type specifies what value the handler passes back into the effectful function when resuming it:

```rust
use effing_mad::Effect;

struct Log<'a>(std::borrow::Cow<'a, str>);

impl<'a> Effect for Log<'a> {
    // The handler returns () after logging -- nothing to inject back
    type Injection = ();
}

struct FileRead(String);

impl Effect for FileRead {
    // The handler returns the file contents as a String
    type Injection = String;
}

struct Cancel;

impl Effect for Cancel {
    // Cancel never resumes -- the Never type encodes this
    type Injection = effing_mad::Never;
}
```

### The Computation Type

An effectful function returns a `Computation` -- an opaque coroutine frame parameterized by its effect set and return type. This is analogous to how `async fn` returns an opaque `Future`:

```rust
// Calling an effectful function produces a Computation
let computation = combined();
// The computation's effects must be handled before it can run
```

### EffectGroup

The `EffectGroup` trait represents a set of multiple effects, enabling composition of effect rows. When an effectful function declares `#[effectful(A, B, C)]`, the macro generates the appropriate group type.

---

## How Effects Are Declared

Effects are declared as structs implementing the `Effect` trait. Effectful functions are annotated with the `#[effectful(...)]` attribute macro, listing the effects they use:

```rust
#![feature(coroutines)]
#![feature(coroutine_trait)]

use effing_mad::{effectful, Effect};

// Declare effects as types
struct Ask;
impl Effect for Ask {
    type Injection = String;
}

struct Tell(String);
impl Effect for Tell {
    type Injection = ();
}

// Declare an effectful function using the attribute macro
#[effectful(Ask, Tell)]
fn greet() {
    let name: String = yield Ask;
    yield Tell(format!("Hello, {name}!"));
}
```

Inside an effectful function, `yield` performs an effect operation: it suspends execution, sends the effect value to the handler, and receives the injection value when resumed. The `do_` operator calls one effectful function from another, provided the callee's effects are a subset of the caller's:

```rust
#[effectful(Ask, Tell)]
fn greet_twice() {
    greet().do_;
    greet().do_;
}
```

---

## How Handlers/Interpreters Work

Effects are handled one at a time using the `handle` function paired with the `handler!` macro. Handlers are composed by chaining `handle` calls from innermost to outermost effect:

```rust
use effing_mad::{handle, handler, run};

fn main() {
    // Create the effectful computation
    let computation = combined();

    // Handle Cancel: break out of the computation
    let without_cancel = handle(computation, handler!(Cancel => break));

    // Handle Log: print to stdout
    let without_log = handle(without_cancel, handler!(Log(msg) => {
        println!("log: {msg}");
    }));

    // Handle FileRead: provide mock file contents
    let without_effects = handle(without_log, handler!(FileRead(name) => {
        assert_eq!(name, "~/my passwords.txt");
        "hunter2".into()
    }));

    // All effects handled -- run the computation
    run(without_effects);
}
```

The `handler!` macro constructs a handler function that pattern-matches on the effect value and produces an injection. Special forms include:

- `handler!(Effect => break)` -- terminates the computation (for effects with `Injection = Never`)
- `handler!(Effect(args) => expr)` -- handles the effect and resumes with the expression's value
- `handler!(Effect(args) => { block })` -- handles with a block

### Async Handlers

For bridging into async Rust, `handle_async` allows the last effect to be handled by an async function:

```rust
use effing_mad::handle_async;

async fn handle_io(effect: IoEffect) -> IoResult {
    match effect {
        IoEffect::Read(path) => tokio::fs::read_to_string(path).await.unwrap(),
        IoEffect::Write(path, data) => { tokio::fs::write(path, data).await.unwrap(); }
    }
}

// The last effect can be handled asynchronously
let result = handle_async(computation, handle_io).await;
```

The `effects::future` module provides bidirectional conversion between futures and effectful computations via `effectfulise` and `futurise`.

---

## Performance Approach

effing-mad inherits the performance characteristics of Rust's coroutine machinery:

- **State machine compilation**: Effectful functions compile to coroutine state machines, the same mechanism used for async/await. Each yield point becomes a state transition with no heap allocation for the frame itself.
- **Monomorphization**: Handlers are generic and monomorphized at each call site, so the compiler can inline handler logic directly into the state machine driver loop.
- **No boxing by default**: Effect values are passed through the coroutine's yield/resume protocol without heap allocation.
- **Zero-cost when inlined**: In the best case, the compiler can see through the handler chain and optimize the entire effect handling into straight-line code.

However, there are costs:

- **Coroutine frame size**: The state machine must hold all live variables across each yield point, which can lead to large frames for complex effectful functions.
- **Dynamic dispatch ceiling**: If handlers are passed as trait objects (for runtime flexibility), the monomorphization benefit is lost.
- **frunk dependency**: Effect row composition uses the `frunk` crate for heterogeneous list operations, which adds some compile-time cost.

---

## Composability Model

### Effect Rows

Effects compose as type-level lists. An effectful function with `#[effectful(A, B, C)]` requires all three effects to be handled before execution. Handlers peel off one effect at a time:

```rust
// Type-level effect composition
// combined: Computation<(Cancel, Log, FileRead), ()>
let computation = combined();

// After handling Cancel: Computation<(Log, FileRead), ()>
let step1 = handle(computation, cancel_handler);

// After handling Log: Computation<(FileRead,), ()>
let step2 = handle(step1, log_handler);

// After handling FileRead: Computation<(), ()>
let step3 = handle(step2, file_handler);

// No effects left -- can run
run(step3);
```

### Effect Subsetting with do\_

The `do_` operator allows calling an effectful function from another, provided the callee's effect set is a subset of the caller's:

```rust
#[effectful(Log<'a>, FileRead)]
fn read_and_log<'a>() {
    let contents: String = yield FileRead("data.txt".into());
    yield Log(format!("Read: {contents}").into());
}

#[effectful(Cancel, Log<'a>, FileRead)]
fn main_computation<'a>() {
    // read_and_log's effects {Log, FileRead} are a subset of {Cancel, Log, FileRead}
    read_and_log().do_;
    yield Cancel;
}
```

### Handler Reuse

Because effect handling is decoupled from the effectful function, the same computation can be run with different handlers in different contexts:

```rust
// Production: real filesystem
let prod = handle(read_and_log(), handler!(FileRead(name) => {
    std::fs::read_to_string(name).unwrap()
}));

// Testing: mock filesystem
let test = handle(read_and_log(), handler!(FileRead(name) => {
    "mock contents".into()
}));
```

---

## Strengths

- Demonstrates that Rust's coroutine machinery is sufficient for full algebraic effects
- Familiar syntax modeled after async/await -- low conceptual overhead for Rust developers
- Type-safe effect rows ensure all effects are handled at compile time
- Handlers are decoupled from effectful functions, enabling dependency injection and testability
- Solves the function coloring problem: the same effectful function works in sync, async, or test contexts
- Composable effect handling via chained `handle` calls
- Async interop through `handle_async` and the `effects::future` module

## Weaknesses

- Requires nightly Rust with `#![feature(coroutines)]` and `#![feature(coroutine_trait)]` -- not usable on stable
- The coroutine feature has no stabilization timeline, making the library's future uncertain
- Limited ecosystem adoption due to nightly requirement
- No multi-shot continuations -- handlers cannot resume a computation more than once (no backtracking or nondeterminism)
- Ownership interactions with effect handlers can be subtle -- yielded values must satisfy the coroutine's lifetime constraints
- The `do_` operator is a syntactic workaround rather than native language support
- Error messages from coroutine-related type errors can be difficult to interpret
- Dependency on `frunk` for heterogeneous list manipulation adds compile-time overhead

## Key Design Decisions and Trade-offs

| Decision                               | Rationale                                                                                      | Trade-off                                                              |
| -------------------------------------- | ---------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| Built on nightly coroutines            | Coroutines provide exactly the suspend/resume semantics needed; reuses compiler infrastructure | Nightly-only; no stability guarantee; feature may change               |
| Effects as structs with Injection type | Simple, idiomatic Rust; effect and response types are explicit                                 | More boilerplate than language-level effect declarations               |
| Handlers peel one effect at a time     | Compositional; handler order is explicit and predictable                                       | Verbose for many effects; nesting depth grows linearly                 |
| yield for effect operations            | Direct mapping to coroutine yield; no additional abstraction layer                             | Overloads yield semantics; may conflict with gen blocks                |
| frunk for effect row types             | Provides type-level heterogeneous list operations                                              | Compile-time cost; complex type errors; additional dependency          |
| No multi-shot continuations            | Rust's ownership model makes copying continuations unsafe/expensive                            | Cannot express nondeterminism, backtracking, or cooperative scheduling |

---

## Sources

- [effing-mad GitHub repository](https://github.com/rosefromthedead/effing-mad)
- [effing-mad on crates.io](https://crates.io/crates/effing-mad)
- [effing-mad API documentation](https://docs.rs/effing-mad/latest/effing_mad/)
- [effing-mad basic example](https://github.com/rosefromthedead/effing-mad/blob/main/examples/basic.rs)
- [Effing-mad discussion on Hacker News](https://news.ycombinator.com/item?id=35358336)
- [Effing-mad discussion on Lobsters](https://lobste.rs/s/blkfub/effing_mad_algebraic_effects_for_rust)
- [Generators are dead, long live coroutines, generators are back -- Inside Rust Blog](https://blog.rust-lang.org/inside-rust/2023/10/23/coroutines/)
