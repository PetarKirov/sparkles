# Koka

A strongly typed functional language with effect types and handlers, where every function's side effects are tracked in its type through row-polymorphic effect types and handled via algebraic effect handlers compiled through evidence passing.

| Field         | Value                                                               |
| ------------- | ------------------------------------------------------------------- |
| Language      | Koka                                                                |
| License       | Apache-2.0                                                          |
| Repository    | [github.com/koka-lang/koka](https://github.com/koka-lang/koka)      |
| Documentation | [Koka Book](https://koka-lang.github.io/koka/doc/book.html)         |
| Key Authors   | Daan Leijen (Microsoft Research)                                    |
| Encoding      | Row-polymorphic effect types with evidence passing compilation to C |

---

## Overview

### What It Solves

Koka addresses the fundamental tension between tracking computational effects in the type system and maintaining usability. In most languages, side effects are invisible in types; in Haskell, the monadic approach makes effects explicit but introduces composition difficulties (monad transformer stacks). Koka provides a system where every function's effects are automatically inferred and tracked through row-polymorphic types, while algebraic effect handlers allow user-defined control abstractions (exceptions, async/await, generators, nondeterminism) to be expressed as libraries rather than built-in language features.

### Design Philosophy

Koka is built around a small set of composable, well-studied features: first-class functions, algebraic data types, a polymorphic type-and-effect system, and effect handlers. The language avoids special-purpose extensions by making the core mechanisms as general as possible. The name "koka" means "effect" in Japanese, reflecting the language's central concern. The precise effect typing gives Koka semantics backed by category theory, making it easy to reason about for both humans and compilers. Many traditionally built-in features -- exceptions, early returns, async functions, generators, iterators, nondeterminism -- are absent from the core language and are instead expressed as user-defined effects.

---

## Core Abstractions and Types

### Row-Polymorphic Effect Types

Every function type in Koka includes an effect row describing its potential side effects. An effect row is a sequence of effect labels that may be closed (fully specified) or open (ending in an effect variable):

```koka
// Closed effect: only console
fun greet() : console ()
  println("hello")

// Open effect: console plus whatever else `e` is
fun greet-and(action : () -> <console|e> ()) : <console|e> ()
  println("hello")
  action()
```

The notation `<console|e>` extends the effect variable `e` with the `console` effect. When effects are inferred at a call-site, both argument effects are automatically unified and extended until they match, computing the union of all effects.

### Built-In Effect Constants

| Effect    | Meaning                               |
| --------- | ------------------------------------- |
| `total`   | No effects at all (pure, terminating) |
| `exn`     | May raise an exception                |
| `div`     | May diverge (not terminate)           |
| `pure`    | Combination of `exn` and `div`        |
| `console` | Console I/O                           |
| `ndet`    | Non-deterministic                     |
| `io`      | All I/O effects combined              |

If a function can be typed without `exn`, it will never throw an unhandled exception. If it lacks `div`, it is guaranteed to terminate. These are semantic guarantees, not merely syntactic labels.

### Type and Effect Inference

Koka uses Hindley-Milner style inference extended to row types. Programmers rarely need to write effect annotations:

```koka
fun map(xs : list<a>, f : (a) -> e b) : e list<b>
  match xs
    Nil        -> Nil
    Cons(x,xx) -> Cons(f(x), map(xx, f))
```

The effect of `map` is exactly `e` -- the effect of the applied function. The function itself adds no effects, and the type system infers this automatically.

---

## How Effects Are Declared

Effects are declared with their operations. Each operation specifies whether it is tail-resumptive (`fun`/`val`) or captures a continuation (`ctl`/`final ctl`):

```koka
// An effect with a tail-resumptive operation
effect reader<a>
  fun ask() : a

// An effect with a control operation (captures continuation)
effect yield<a>
  ctl yield(value : a) : bool

// An effect that never resumes (exception-like)
effect raise
  final ctl raise(msg : string) : a
```

The distinction between operation kinds is central to Koka's performance:

| Operation Kind | Resumes?                | Continuation Captured? | Performance            |
| -------------- | ----------------------- | ---------------------- | ---------------------- |
| `val`          | Implicitly (value)      | No                     | Fastest                |
| `fun`          | Implicitly (tail)       | No                     | Fast (in-place)        |
| `ctl`          | Explicitly via `resume` | Yes                    | General                |
| `final ctl`    | Never                   | No                     | Optimized (no capture) |

A `fun` operation always resumes exactly once and immediately returns its result -- like a callback. A `ctl` operation yields to the handler with access to the `resume` continuation, which may be called zero, one, or multiple times. A `final ctl` operation never resumes, enabling exception-like patterns without continuation capture overhead.

---

## How Handlers/Interpreters Work

### Basic Handler

A handler interprets an effect by providing clauses for each operation:

```koka
fun with-reader(x : a, action : () -> <reader<a>|e> b) : e b
  with handler
    fun ask() x
  action()
```

The `fun` clause means `ask()` is tail-resumptive: calling `ask()` in the action immediately returns `x` and continues execution. No continuation is captured.

### Control Handler with Resume

When a `ctl` clause is used, the handler receives the captured continuation as `resume`:

```koka
fun with-yield(action : () -> <yield<int>|e> ()) : e list<int>
  with handler
    return(_)        []
    ctl yield(value) Cons(value, resume(True))
  action()
```

Each time `yield(v)` is called, control transfers to the handler. The handler constructs a list by prepending `value` and resuming the rest of the computation with `True`.

### Exception-Like Handler

```koka
fun with-catch(action : () -> <raise|e> a) : e maybe<a>
  with handler
    return(x)       Just(x)
    final ctl raise(msg) Nothing
  action()
```

The `final ctl` clause never resumes, so the continuation is not captured. This compiles efficiently, similar to native exception handling.

### Named Handlers

Named handlers allow multiple instances of the same effect to coexist, distinguished by lexical identity:

```koka
named effect ref<a>
  fun get() : a
  fun set(value : a) : ()

fun with-ref(init : a, action : (ev<ref<a>>) -> <heap|e> b) : <heap|e> b
  var s := init
  with r <- named handler
    fun get()    s
    fun set(x)   s := x
  action(r)
```

The handler instance `r` is passed explicitly, allowing code to distinguish between multiple references. Named handlers integrate with scoped effects to prevent handler instances from escaping their scope via rank-2 polymorphism.

---

## Performance Approach

### Evidence Passing

Koka compiles effect handlers through a technique called evidence passing. Rather than performing dynamic stack searches to find handlers at runtime, the compiler threads an evidence vector -- a record of handler implementations -- through function calls. At each effect operation, the handler is looked up directly from this vector.

The evidence passing translation was formalized in "Effect Handlers, Evidently" (ICFP 2020, Xie, Brachthaeuser, Hillerstraem, Schuster, Leijen) and refined in "Generalized Evidence Passing for Effect Handlers" (ICFP 2021, Xie, Leijen). The key results of the ICFP 2021 paper are:

1. A sequence of refinements from algebraic effects through multi-prompt delimited control, generalized evidence passing, and yield bubbling, to a monadic translation into plain lambda calculus.
2. Compilation to C that outperforms or matches other best-in-class effect handler implementations.

### Perceus Reference Counting

Koka uses Perceus, a precise reference counting algorithm with reuse analysis. Perceus emits reference counting instructions such that (cycle-free) programs are garbage-free -- objects are deallocated as soon as they become unreachable, typically right after last use while still in cache. This is earlier than scope-based deallocation (RAII) and is fully deterministic.

Key properties of Perceus:

- **Garbage-free**: No live references are retained beyond their last use.
- **Reuse analysis**: When a uniquely-referenced data structure is destructed and a new one of the same size is constructed, Perceus reuses the memory in-place.
- **No GC runtime**: Koka compiles to C with no garbage collector or runtime system.

### FBIP: Functional But In-Place

Perceus enables a programming paradigm called FBIP (Functional But In-Place). Just as tail-call optimization lets loops be expressed as recursive functions, reuse analysis lets in-place mutating algorithms be written in a purely functional style. When a data structure has a unique reference, pattern matching and reconstruction compile to in-place mutation with zero allocation.

Koka v2.4.2 introduced `fip` and `fbip` keywords that allow the compiler to verify that a function is fully in-place (`fip`) or functionally-but-in-place (`fbip`):

```koka
fip fun map(xs : list<a>, f : (a) -> b) : list<b>
  match xs
    Nil        -> Nil
    Cons(x,xx) -> Cons(f(x), map(xx, f))
```

FIP functions require no dynamic reference counting at runtime. FBIP functions are allowed to use stack space and deallocate memory but still reuse in-place when possible.

### Compilation Targets

| Target     | Flag            | Backend         | Notes                                        |
| ---------- | --------------- | --------------- | -------------------------------------------- |
| C          | `--target=c`    | GCC/Clang       | Primary target; Perceus RC; best performance |
| JavaScript | `--target=js`   | Node.js/Browser | ES6 modules; BigInt support                  |
| WASM       | `--target=wasm` | Emscripten      | Via C backend; requires wasmtime             |
| C#         | `--target=cs`   | .NET            | Legacy; Koka v1 only                         |

---

## Composability Model

### Effect Row Unification

Effects compose via row unification. When a function with effect `<reader<int>|e>` calls a function with effect `<console|e'>`, the type system unifies the rows, producing the combined effect `<reader<int>,console|e''>`. This happens automatically during inference.

### Handler Nesting

Handlers are nested lexically. The order of nesting determines semantics:

```koka
// State is rolled back on exception
fun example1()
  with with-catch
  with with-state(0)
  // ...

// State persists through exception
fun example2()
  with with-state(0)
  with with-catch
  // ...
```

### Effect Polymorphism in Higher-Order Functions

Higher-order functions naturally propagate effects:

```koka
fun for-each(xs : list<a>, f : (a) -> e ()) : e ()
  match xs
    Nil        -> ()
    Cons(x,xx) -> { f(x); for-each(xx, f) }
```

The effect variable `e` means `for-each` has exactly the effects of `f` -- no more. This allows effect-polymorphic library functions without any special annotation.

### Linear Effects

Prefixing an effect with `linear` restricts handlers to linear use (exactly one resumption), enabling more efficient compilation at the cost of expressiveness:

```koka
linear effect pretty
  val indentation : int
  fun write(s : string) : ()
```

---

## Strengths

- Full effect inference with no programmer annotations required for effects
- Row-polymorphic effect system with deep semantic guarantees (no `exn` = no exceptions)
- Algebraic effect handlers subsume exceptions, generators, async/await, and nondeterminism as libraries
- Perceus reference counting eliminates garbage collection entirely for cycle-free code
- FBIP paradigm enables purely functional algorithms that compile to in-place mutation
- Evidence passing compilation produces C code competitive with hand-written implementations
- Graded operation kinds (`fun`/`ctl`/`final ctl`) allow performance tuning per handler clause
- Named handlers with scoped effects safely support multiple instances of the same effect

## Weaknesses

- Research language with a small community and limited ecosystem of libraries
- No support for cyclic data structures (Perceus is limited to cycle-free programs)
- Evidence vector adjustments can cause overhead in programs with deeply nested effect rows
- Named handler and scoped effect design is still evolving (redesigned in v3.1.0)
- Limited tooling compared to mainstream languages (though VS Code support exists)
- WASM and JavaScript backends are secondary; performance focus is on the C backend
- Learning curve for understanding the interaction between operation kinds and handler semantics

## Key Design Decisions and Trade-offs

| Decision                              | Rationale                                                           | Trade-off                                                                                                  |
| ------------------------------------- | ------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Row-polymorphic effects               | Full inference; union semantics; no manual effect management        | More complex type error messages; row unification can be unintuitive                                       |
| `fun` vs `ctl` distinction            | Tail-resumptive operations avoid continuation capture entirely      | Programmers must understand the performance implications of each clause kind                               |
| Evidence passing                      | Compiles handlers to direct function calls; no runtime stack search | Evidence vectors must be threaded through all calls; adjustment overhead                                   |
| Perceus reference counting            | Deterministic deallocation; no GC pauses; enables FBIP              | Cannot handle cyclic structures; reference counting has inherent overhead vs tracing GC for some workloads |
| FBIP / `fip` annotations              | Verified in-place mutation from pure functional code                | Restricts programming style; not all algorithms can be expressed as FIP                                    |
| Compile to C                          | Portable; good performance; no runtime dependency                   | Compilation times slower than direct native codegen; debugging through generated C is difficult            |
| Effects replace built-in control flow | Maximal generality; all control abstractions are user-definable     | Exceptions, generators, and async have higher overhead than dedicated built-in implementations             |

---

## Sources

- [Koka GitHub repository](https://github.com/koka-lang/koka)
- [The Koka Programming Language (Book)](https://koka-lang.github.io/koka/doc/book.html)
- [Koka: Programming with Row Polymorphic Effect Types (MSFP 2014)](https://arxiv.org/abs/1406.2061)
- [Algebraic Effects for Functional Programming (MSR-TR-2016-29)](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/08/algeff-tr-2016-v2.pdf)
- [Effect Handlers, Evidently (ICFP 2020)](https://doi.org/10.1145/3408981)
- [Generalized Evidence Passing for Effect Handlers (ICFP 2021)](https://dl.acm.org/doi/10.1145/3473576)
- [Perceus: Garbage Free Reference Counting with Reuse (PLDI 2021)](https://dl.acm.org/doi/10.1145/3453483.3454032)
- [FP2: Fully in-Place Functional Programming (ICFP 2023)](https://www.microsoft.com/en-us/research/wp-content/uploads/2023/07/fip.pdf)
- [First-class Named Effect Handlers (OOPSLA 2022)](https://dl.acm.org/doi/abs/10.1145/3563289)
- [Koka at Microsoft Research](https://www.microsoft.com/en-us/research/project/koka/)
