# CPS-Based Effects in Rust (Rust)

A design pattern for encoding algebraic effects and handlers on stable Rust using continuation-passing style (CPS) and traits, where effects are trait interfaces in CPS form and handlers are trait implementations monomorphized at compile time.

| Field         | Value                                                                                                |
| ------------- | ---------------------------------------------------------------------------------------------------- |
| Language      | Rust (stable)                                                                                        |
| License       | N/A (design pattern, not a published crate)                                                          |
| Repository    | N/A                                                                                                  |
| Documentation | [Faking Algebraic Effects with Traits](https://blog.shtsoft.eu/2022/12/22/effect-trait-dp.html)      |
| Key Authors   | SHTSoft (blog), various community contributors                                                       |
| Encoding      | Traits as effect interfaces in CPS; trait implementations as handlers; monomorphization for dispatch |

---

## Overview

### What It Solves

On stable Rust, there are no coroutines, no delimited continuations, and no built-in effect system. The CPS-based approach works around these limitations by encoding the "rest of the computation" (the continuation) as a closure parameter passed explicitly through the program. Effects become trait methods that receive both the effect's arguments and a continuation closure. Handlers are trait implementations that decide what to do with the arguments and whether (and how) to invoke the continuation.

This pattern allows programmers to write code that is parameterized over effect handlers on stable Rust, achieving a form of dependency injection that is resolved and monomorphized at compile time.

### Design Philosophy

The approach is explicitly described as a "fake" -- it cannot match the ergonomics of a real algebraic effect system because it forces the programmer to write in continuation-passing style. The major promise of algebraic effects is to abstract and modularize control flow without CPS, so the pattern works against the original spirit. However, it offers real practical value: it works on stable Rust, compiles to efficient code via monomorphization, and provides a type-safe way to parameterize computations over their side effects.

---

## Core Abstractions and Types

### The CPS Effect Pattern

The fundamental pattern transforms an effect operation with signature `e(A) -> B` into a trait method that takes an argument of type `A` and a continuation `K: FnOnce(B) -> R`, returning `R`:

```rust
// A direct-style effect signature:
//   read_file(path: &str) -> String
//
// Becomes a CPS trait method:
trait FileSystem<R> {
    fn read_file<K>(self, path: &str, k: K) -> R
    where
        K: FnOnce(String) -> R;

    fn write_file<K>(self, path: &str, contents: &str, k: K) -> R
    where
        K: FnOnce(()) -> R;
}
```

The continuation `k` represents "what happens next" after the effect is handled. The handler (trait implementation) decides whether to call `k`, what value to pass it, or whether to short-circuit entirely.

### The Exception Effect

The exception (or error) effect demonstrates how CPS naturally encodes early return:

```rust
trait Exception<E, R> {
    fn raise<A, K>(self, error: E, k: K) -> R
    where
        K: FnOnce(A) -> R;
}
```

The generic type `A` on `raise` is key: since the continuation `k` expects an `A` that the handler cannot produce (it only has `E`), a correct handler implementation cannot call `k`. This enforces at the type level that `raise` is a non-local exit -- the continuation is dead code:

```rust
struct AbortOnError;

impl<E: std::fmt::Debug, R: Default> Exception<E, R> for AbortOnError {
    fn raise<A, K>(self, error: E, _k: K) -> R
    where
        K: FnOnce(A) -> R,
    {
        eprintln!("Error: {error:?}");
        // k is NOT called -- we short-circuit
        R::default()
    }
}
```

### The State Effect

The state effect shows how CPS can thread mutable state without actual mutation:

```rust
trait State<S, R> {
    fn get<K>(self, k: K) -> R
    where
        K: FnOnce(Self, S) -> R;

    fn put<K>(self, new_state: S, k: K) -> R
    where
        K: FnOnce(Self) -> R;
}

struct PureState<S>(S);

impl<S: Clone, R> State<S, R> for PureState<S> {
    fn get<K>(self, k: K) -> R
    where
        K: FnOnce(Self, S) -> R,
    {
        let value = self.0.clone();
        k(self, value)
    }

    fn put<K>(self, new_state: S, k: K) -> R
    where
        K: FnOnce(Self) -> R,
    {
        k(PureState(new_state))
    }
}
```

Notice that `get` passes `self` back into the continuation so the handler can be reused. This is the "shallow handler" pattern -- the handler is consumed by each operation and must be explicitly threaded through.

---

## How Effects Are Declared

Effects are declared as generic traits parameterized by the return type `R`. Each operation is a method that takes the effect's arguments plus a continuation:

```rust
// Logging effect
trait Logger<R> {
    fn log<K>(self, message: &str, k: K) -> R
    where
        K: FnOnce(Self) -> R;
}

// Console I/O effect
trait Console<R> {
    fn read_line<K>(self, k: K) -> R
    where
        K: FnOnce(Self, String) -> R;

    fn print_line<K>(self, message: &str, k: K) -> R
    where
        K: FnOnce(Self) -> R;
}
```

An effectful computation is then a function generic over the handler type:

```rust
fn my_program<H, R>(handler: H) -> R
where
    H: Console<R> + Logger<R>,
{
    handler.print_line("Enter your name:", |h| {
        h.read_line(|h, name| {
            h.log(&format!("User entered: {name}"), |h| {
                h.print_line(&format!("Hello, {name}!"), |_h| {
                    // computation complete
                })
            })
        })
    })
}
```

---

## How Handlers/Interpreters Work

Handlers are trait implementations. Different handler types provide different interpretations of the same effectful computation:

```rust
// Production handler: real I/O
struct RealConsole;

impl Console<()> for RealConsole {
    fn read_line<K>(self, k: K) -> ()
    where
        K: FnOnce(Self, String) -> (),
    {
        let mut input = String::new();
        std::io::stdin().read_line(&mut input).unwrap();
        k(RealConsole, input.trim().to_string())
    }

    fn print_line<K>(self, message: &str, k: K) -> ()
    where
        K: FnOnce(Self) -> (),
    {
        println!("{message}");
        k(RealConsole)
    }
}

// Test handler: scripted I/O
struct ScriptedConsole {
    inputs: Vec<String>,
    outputs: Vec<String>,
}

impl Console<Vec<String>> for ScriptedConsole {
    fn read_line<K>(mut self, k: K) -> Vec<String>
    where
        K: FnOnce(Self, String) -> Vec<String>,
    {
        let input = self.inputs.remove(0);
        k(self, input)
    }

    fn print_line<K>(mut self, message: &str, k: K) -> Vec<String>
    where
        K: FnOnce(Self) -> Vec<String>,
    {
        self.outputs.push(message.to_string());
        k(self)
    }
}
```

The same `my_program` function works with both handlers:

```rust
// Production use
my_program(RealConsole);

// Test use
let test_console = ScriptedConsole {
    inputs: vec!["Alice".to_string()],
    outputs: vec![],
};
let captured = my_program(test_console);
```

---

## Performance Approach

The CPS-based pattern has favorable performance characteristics on paper:

- **Monomorphization**: Because the handler type is a generic parameter, the compiler generates specialized code for each handler. There is no dynamic dispatch or vtable lookup.
- **Inlining**: Continuations are closures that the compiler can often inline, collapsing the CPS overhead into direct-style code in the optimized output.
- **No heap allocation**: Continuations are stack-allocated closures. No boxing is required unless the programmer explicitly uses trait objects.
- **Zero-cost potential**: In the ideal case, a monomorphized and inlined CPS computation compiles to the same machine code as a hand-written direct-style version.

However, there are significant practical costs:

- **Stack depth**: Each continuation adds a stack frame. Deep effectful computations can overflow the stack, especially because loops must be rewritten as recursion in CPS.
- **No tail-call optimization**: Rust does not guarantee TCO. Recursive CPS code may consume O(n) stack space where n is the number of effect operations.
- **Closure size**: Each continuation closure captures its environment, and deeply nested closures can accumulate large captured states.
- **Compile time**: Heavy use of generics and closures increases monomorphization work and can slow compilation.

---

## Composability Model

### Combining Multiple Effects

Multiple effects are composed via trait bounds on the handler type:

```rust
fn combined_program<H, R>(handler: H) -> R
where
    H: Console<R> + Logger<R> + State<Config, R>,
{
    handler.get(|h, config| {
        h.log(&format!("Config: {config:?}"), |h| {
            h.print_line("Ready.", |_h| {
                // ...
            })
        })
    })
}
```

This is straightforward when all effects share the same handler type. When effects need different handler types, composition becomes more complex and may require wrapper structs or tuples.

### Shallow vs. Deep Handlers

The CPS-trait pattern naturally produces shallow handlers: the handler is consumed by each effect operation and must be explicitly passed back into the continuation. This contrasts with deep handlers (as in effing-mad or most algebraic effect libraries) where the handler is implicitly available for the entire scope of the computation.

To simulate deep handlers, the handler must either implement `Clone` (to be copied back into each continuation) or be threaded explicitly through every continuation parameter.

### The Higher-Order Closure Challenge

Rust's closure traits (`FnOnce`, `FnMut`, `Fn`) interact with the CPS pattern in important ways:

- **`FnOnce`**: The continuation can only be called once. This is the natural fit for most effects but prevents multi-shot continuations (needed for nondeterminism or backtracking).
- **`FnMut` / `Fn`**: Would allow multi-shot continuations but require the continuation to be cloneable, which is rarely practical in Rust due to ownership semantics.
- **Lifetime constraints**: Continuations that capture references must satisfy Rust's lifetime rules, which can make deeply nested CPS code difficult to write when borrowed data must flow through multiple continuation layers.

### Limitations from Rust's Type System

Several features that would make CPS-based effects more ergonomic are absent or limited in Rust:

| Missing Feature           | Impact on CPS Effects                                                                                  |
| ------------------------- | ------------------------------------------------------------------------------------------------------ |
| Higher-Kinded Types (HKT) | Cannot abstract over effect-parameterized type constructors (e.g., `M<A>` for any effect `M`)          |
| GATs (limited)            | Available since Rust 1.65 but cannot fully substitute for HKT; cannot guarantee container preservation |
| Tail-call optimization    | CPS recursion may overflow the stack; no `become` keyword yet                                          |
| `impl Trait` in closures  | Complex continuation types are difficult to name; sometimes requires boxing                            |
| Variadic generics         | Cannot write effect rows as variable-length type-level lists without external crates                   |

---

## Strengths

- Works on stable Rust with no feature gates or nightly compiler
- Zero-cost abstraction potential through monomorphization and inlining
- Type-safe: the compiler enforces that all effects are handled and injection types are correct
- No external dependencies required -- the pattern uses only standard Rust traits and generics
- Handler swapping enables dependency injection and testability without dynamic dispatch
- Shallow handler semantics naturally align with Rust's ownership model (handlers are consumed)
- Predictable compilation: no proc macros, no code generation, no hidden complexity

## Weaknesses

- Ergonomically painful: deeply nested continuations produce "callback hell" reminiscent of pre-async JavaScript
- Effectful loops must be rewritten as recursion, risking stack overflow without TCO
- Shallow handlers require explicit handler threading through every continuation
- No multi-shot continuations: cannot express nondeterminism, backtracking, or cooperative multitasking
- Boilerplate scales with the number of effect operations and nesting depth
- Complex type errors when trait bounds interact with closure lifetimes
- Not a real effect system: lacks the modularity and composability guarantees of language-level algebraic effects
- Community adoption is minimal -- this remains a niche design pattern rather than an ecosystem tool

## Key Design Decisions and Trade-offs

| Decision                       | Rationale                                           | Trade-off                                                         |
| ------------------------------ | --------------------------------------------------- | ----------------------------------------------------------------- |
| CPS via closures               | Works on stable Rust; no language extensions needed | Callback nesting; loss of direct-style readability                |
| Traits as effect interfaces    | Idiomatic Rust; monomorphized dispatch              | One trait per effect; composition via trait bounds grows linearly |
| FnOnce continuations           | Matches Rust's ownership model; one-shot is safe    | No multi-shot continuations; limits expressible effects           |
| Handler consumed per operation | Natural for affine types; prevents use-after-handle | Shallow handlers only; must explicitly thread handler state       |
| Generic return type R          | Handler determines the computation's result type    | Every effect trait must be parameterized by R; adds noise         |
| No external crate dependency   | Pure pattern; no build complexity                   | No ecosystem tooling, no proc macros to reduce boilerplate        |

---

## Sources

- [Faking Algebraic Effects and Handlers With Traits: A Rust Design Pattern -- SHTSoft](https://blog.shtsoft.eu/2022/12/22/effect-trait-dp.html)
- [A universal lowering strategy for control effects in Rust -- Abubalay](https://www.abubalay.com/blog/2024/01/14/rust-effect-lowering)
- [Continuation Passing Style for Effect Handlers -- Hillerström et al. (academic paper)](https://homepages.inf.ed.ac.uk/slindley/papers/handlers-cps.pdf)
- [Simplifying Continuation-Passing Style in Rust -- Inferara](https://medium.com/@inferara/simplifying-continuation-passing-style-cps-in-rust-e43621d98fb5)
- [Algebraic Effects, Ownership, and Borrowing -- Ante language blog](https://antelang.org/blog/effects_ownership_and_borrowing/)
- [GATs encode higher-order functions on types -- Will Crichton](https://willcrichton.net/notes/gats-are-hofs/)
- [Pre-RFC: CPS transform for generators -- Rust Internals](https://internals.rust-lang.org/t/pre-rfc-cps-transform-for-generators/7120)
