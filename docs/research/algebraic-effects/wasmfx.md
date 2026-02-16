# WasmFX (WebAssembly)

A minimal extension to WebAssembly adding typed, first-class continuations via effect handlers, enabling efficient compilation of non-local control flow features such as async/await, generators, lightweight threads, and coroutines.

| Field         | Value                                                                                    |
| ------------- | ---------------------------------------------------------------------------------------- |
| Language      | WebAssembly (WAT / Wasm bytecode)                                                        |
| License       | Apache-2.0 (W3C Software License for spec)                                               |
| Repository    | [github.com/WebAssembly/stack-switching](https://github.com/WebAssembly/stack-switching) |
| Documentation | [wasmfx.dev](https://wasmfx.dev/)                                                        |
| Key Authors   | Daniel Hillerstr&ouml;m, Sam Lindley, Luna Phipps-Costin, Andreas Rossberg               |
| Approach      | Typed delimited continuations with named control tags                                    |

---

## Overview

### What It Solves

WebAssembly provides no direct support for non-local control flow. Languages with features like async/await, generators, lightweight threads, or first-class continuations must resort to whole-program transformations (continuation-passing style, Asyncify, or state machines) when compiling to Wasm. These transformations impose significant code size overhead, runtime performance penalties, and destroy the natural call stack structure that debuggers and profilers rely on.

WasmFX solves this by adding a small set of typed instructions for creating, suspending, and resuming continuations directly at the Wasm level. Source language compilers can translate their non-local control flow features directly into WasmFX instructions without program-wide transformations.

### Design Philosophy

The proposal follows Wasm's core design principles: **minimal**, **typed**, and **composable**. It extends the existing instruction set and type system rather than introducing a parallel abstraction. The extension adds only six new instructions and one new reference type. Continuations are typed using named control tags (an extension of Wasm's exception tags), which integrates naturally with Wasm's block-structured type system.

The design is based on the theory of algebraic effect handlers, but presents itself as a low-level stack-switching primitive rather than a high-level effect system. Language runtimes build their own abstractions (async/await, green threads, generators) on top of WasmFX's primitives.

---

## Core Abstractions and Types

### Control Tags

Control tags are the central typing mechanism. They extend Wasm's exception tags with a return type, making them "resumable exceptions":

```wat
(tag $yield (param i32) (result i32))
;;          ^^^^^^^^^   ^^^^^^^^^^^
;;          payload      return value when resumed
```

A tag declares the type of value sent when suspending (`param`) and the type of value expected when resumed (`result`). Tags are declared at the module level and can be exported/imported.

### Continuation Type

A new reference type `(ref $ct)` represents a suspended computation:

```wat
(type $ft (func (param i32) (result i32)))  ;; function type
(type $ct (cont $ft))                        ;; continuation over that function type
```

A `(cont $ft)` describes a suspended stack that can be resumed with the parameter types of `$ft` and will eventually produce values of the result types of `$ft`.

### Linearity

Continuations are **one-shot** (linear): each continuation must be invoked exactly once, either by resuming it or by aborting it. After invocation, the continuation object is destructively consumed -- any subsequent use traps. This avoids the need for garbage collection of continuation objects and prevents cyclic references.

---

## How Effects Are Declared

Effects are declared as control tags at the module level. Each tag specifies the types of values exchanged between the suspending computation and the handler:

```wat
(module
  ;; A yield effect: sends an i32, expects an i32 back on resume
  (tag $yield (param i32) (result i32))

  ;; A read effect: sends nothing, expects a string reference back
  (tag $read (result (ref string)))

  ;; An await effect: sends a promise reference, expects the resolved value
  (tag $await (param (ref $promise)) (result (ref $value)))
)
```

Tags can be imported from other modules, allowing effect interfaces to be shared across module boundaries:

```wat
(import "effects" "yield" (tag $yield (param i32) (result i32)))
```

---

## How Handlers/Interpreters Work

### The Three Core Instructions

WasmFX adds three primary instructions for working with continuations:

**`cont.new`** -- Create a continuation from a function reference:

```wat
(cont.new $ct (ref.func $generator))
;; Creates a new stack, ready to execute $generator when resumed
```

**`suspend`** -- Suspend the current computation, yielding control to the handler:

```wat
(suspend $yield)
;; Reifies the current stack as a continuation
;; Transfers control to the nearest handler for $yield
;; The handler receives the continuation + the suspend payload
```

**`resume`** -- Resume a suspended continuation with handler clauses:

```wat
(resume $ct
  (on $yield $handler_block)   ;; handler clause for $yield tag
)
;; Switches to the continuation's stack and continues execution
;; If the continuation suspends with $yield, control jumps to $handler_block
```

### Additional Instructions

**`cont.bind`** -- Partially apply a continuation, shrinking its parameter list:

```wat
(cont.bind $ct_with_params $ct_fewer_params)
;; Binds leading parameters to specific values
;; Useful for returning continuations from blocks with uniform types
```

**`resume_throw`** -- Resume a continuation by raising an exception inside it (for aborting):

```wat
(resume_throw $exn_tag $ct)
;; Resumes the continuation but immediately throws $exn_tag inside it
;; Used to abort/cancel a suspended computation with cleanup
```

**`switch`** -- Direct stack switch between continuations (optimization):

```wat
(switch $ct $tag)
;; Transfers control directly from one continuation to another
;; Avoids intermediate switch through the parent stack
```

### Generator Example (Complete)

A generator that yields values 1, 2, 3 and a consumer that sums them:

```wat
(module $generator_example
  (type $ft (func))
  (type $ct (cont $ft))
  (tag $yield (param i32))

  ;; Generator function: yields 1, 2, 3
  (func $generate
    (i32.const 1)
    (suspend $yield)   ;; yield 1
    (i32.const 2)
    (suspend $yield)   ;; yield 2
    (i32.const 3)
    (suspend $yield)   ;; yield 3
  )

  ;; Consumer: sums all yielded values
  (func $sum (export "sum") (result i32)
    (local $k (ref null $ct))
    (local $total i32)

    ;; Create continuation from generator function
    (local.set $k (cont.new $ct (ref.func $generate)))

    (block $done (result)
      (loop $next
        ;; Resume the generator; if it suspends on $yield, jump to handler
        (block $on_yield (result i32 (ref null $ct))
          (local.get $k)
          (resume $ct (on $yield $on_yield))
          ;; Generator returned normally (finished)
          (br $done)
        )
        ;; Handler: received yielded value and continuation on stack
        (local.set $k)                          ;; save continuation
        (local.get $total)
        (i32.add)
        (local.set $total)                      ;; total += yielded value
        (br $next)                              ;; resume loop
      )
    )
    (local.get $total)  ;; return sum (1+2+3 = 6)
  )
)
```

### Lightweight Threads Example

Cooperative multithreading using a single `$yield` tag:

```wat
(module $lwt
  (type $ft (func))
  (type $ct (cont $ft))
  (tag $yield)                ;; no payload, no return -- just a context switch signal

  ;; A cooperative thread that yields periodically
  (func $worker (param $id i32)
    ;; ... do some work ...
    (suspend $yield)          ;; voluntarily yield to scheduler
    ;; ... do more work ...
    (suspend $yield)
    ;; ... finish ...
  )

  ;; Round-robin scheduler would resume each thread's continuation in turn
)
```

### Handler Semantics: Sheep Handlers

WasmFX uses "sheep handlers" -- a hybrid of shallow and deep handler semantics:

- Like **shallow handlers**: The handler is not automatically reinstalled after handling a suspension. The continuation returned to the handler is "bare."
- Like **deep handlers**: A new handler is installed explicitly as part of each `resume` instruction via `(on ...)` clauses.

This gives the programmer explicit control over handler installation while keeping the instruction set minimal.

---

## Performance Approach

### Stack Switching Without Copying

A core design requirement is that continuation operations never copy or move stack frames. Instead, the runtime maintains multiple stack segments and switches between them by adjusting pointers. This is critical because Wasm engines use heterogeneous stack representations that cannot be efficiently relocated.

### Implementation in Wasmtime

The WasmFX prototype has been implemented in Wasmtime (Bytecode Alliance's production Wasm runtime) in two phases:

1. **Host-based prototype**: Piggybacked on Wasmtime's existing fibers API, performing stack switches through the host runtime
2. **Native implementation**: Stack switching stays entirely within the Wasm execution environment, avoiding host transitions

The native implementation achieved up to **6x performance improvement** over the host-based prototype in micro-benchmarks.

### No GC Dependency

Continuations are one-shot and cannot form cyclic references, so they do not require garbage collection. This is essential because not all Wasm target languages use GC-managed memory.

### Debugging Friendliness

WasmFX preserves the natural call stack structure. Suspended continuations appear as stack segments in debugging tools, and the design is compatible with DWARF stack unwind tables. This avoids the debugging nightmare caused by CPS or Asyncify transformations, which flatten the call stack into state machines.

---

## Composability Model

### Language Compilation Targets

WasmFX provides a universal compilation target for diverse non-local control flow features:

| Source Feature            | Languages                         | WasmFX Encoding                        |
| ------------------------- | --------------------------------- | -------------------------------------- |
| Async/await               | C#, Dart, JavaScript, Rust, Swift | Tag per async boundary; suspend/resume |
| Generators/iterators      | C#, JavaScript, Kotlin, Python    | Yield tag; resume loop in consumer     |
| Coroutines                | C++, Kotlin, Python               | Symmetric switch or suspend/resume     |
| Lightweight threads       | Erlang, Go, Haskell, OCaml        | Yield tag; round-robin scheduler       |
| First-class continuations | Haskell, OCaml, Scheme            | Direct mapping to cont type            |
| Effect handlers           | Koka, OCaml 5, Eff                | Direct mapping to tags + resume        |

### Nesting and Composition

Multiple effects can be active simultaneously. Each `resume` instruction specifies which tags it handles, and unhandled suspensions propagate to the next enclosing handler -- the same semantics as nested exception handlers, but with resumption:

```wat
(resume $ct
  (on $yield $handle_yield)
  (on $await $handle_await)
)
;; Handles both $yield and $await; other tags propagate outward
```

### Cross-Module Effects

Tags can be imported/exported across Wasm module boundaries, enabling effect interfaces between independently compiled modules. A module can suspend with a tag defined in another module, and the handler can be in a third module.

### Relation to Other Wasm Proposals

| Proposal               | Relationship to WasmFX                                     |
| ---------------------- | ---------------------------------------------------------- |
| Exception Handling     | WasmFX tags extend exception tags with return types        |
| Function References    | Required for `cont.new` (creating continuations from refs) |
| GC                     | Independent; WasmFX does not require GC                    |
| JS Promise Integration | Alternative approach for async; WasmFX is more general     |
| Threads                | Orthogonal; WasmFX handles concurrency within a thread     |

---

## Strengths

- **Minimal extension**: Only six instructions and one type added to core Wasm
- **Fully typed**: Continuation types and tag signatures integrate with Wasm's type system
- **Universal target**: A single mechanism covers async/await, generators, threads, effects, and more
- **No stack copying**: Efficient implementation via pointer-based stack switching
- **No GC dependency**: One-shot continuations avoid cyclic reference problems
- **Debugger-friendly**: Preserves natural call stack structure unlike CPS transformations
- **Formally verified**: The design has been proven type-sound
- **Production runtime**: Implemented in Wasmtime with encouraging performance results

## Weaknesses

- **One-shot only**: Continuations cannot be cloned or reused; multi-shot effects (backtracking, nondeterminism) require additional machinery
- **Not yet standardized**: The proposal is in Phase 3 (Implementation) of the Wasm CG process; not yet available in browsers
- **Complexity for engine implementors**: Stack switching requires significant changes to Wasm runtime internals
- **Low-level API**: Language toolchains must build higher-level abstractions on top of raw instructions
- **Limited browser support**: Currently only implemented in Wasmtime (off-the-web engine); V8 and SpiderMonkey implementations pending
- **Linear traversal for handler lookup**: Finding the matching handler requires walking the handler chain, though practical depths are typically small

## Key Design Decisions and Trade-offs

| Decision                                 | Rationale                                                  | Trade-off                                                           |
| ---------------------------------------- | ---------------------------------------------------------- | ------------------------------------------------------------------- |
| Named control tags (not a single prompt) | Enables Wasm's simple type system to type continuations    | Slightly more verbose than single-prompt delimited continuations    |
| One-shot continuations                   | Avoids GC dependency and cyclic references                 | Cannot directly express multi-shot effects like backtracking        |
| Sheep handlers (explicit reinstall)      | Minimal instruction set; programmer controls handler scope | More manual than deep handlers; each resume must redeclare handlers |
| No stack copying                         | Critical for engines with heterogeneous stacks             | Continuation must be consumed exactly once; no forking              |
| Extension of exception tags              | Reuses existing Wasm tag infrastructure                    | Depends on exception handling proposal reaching maturity            |
| Destructive consumption                  | Prevents use-after-resume bugs                             | Cannot inspect or duplicate a continuation                          |

---

## Sources

- [WasmFX project site](https://wasmfx.dev/)
- [WasmFX Explainer document](https://wasmfx.dev/specs/explainer/)
- [WebAssembly/stack-switching proposal](https://github.com/WebAssembly/stack-switching)
- [wasmfx/wasmfxtime](https://github.com/wasmfx/wasmfxtime) -- Wasmtime fork with WasmFX support
- [Continuing WebAssembly with Effect Handlers](https://dl.acm.org/doi/10.1145/3622814) -- Phipps-Costin et al., OOPSLA 2023
- [WasmFX: Stack Switching via Effect Handlers](https://effect-handlers.org/talks/wasmfx-huawei23.pdf) -- Hillerstr&ouml;m, presentation
- [Continuing Stack Switching in Wasmtime](https://dhil.net/research/papers/wasmfxtime-waw2025.pdf) -- Hillerstr&ouml;m, WAW 2025
- [Typed continuations to model stacks](https://github.com/WebAssembly/design/issues/1359) -- WebAssembly design discussion
- [Generator example in WAT](https://github.com/wasmfx/wasmfxtime/blob/main/examples/generator.wat) -- wasmfxtime repository
- [The State of WebAssembly 2025 and 2026](https://platform.uno/blog/the-state-of-webassembly-2025-2026/) -- Uno Platform
