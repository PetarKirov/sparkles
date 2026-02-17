# WasmFX and Typed Continuations for WebAssembly

WasmFX is the research line that shaped WebAssembly's stack-switching / typed-continuation direction: a low-level target for compiling async/await, generators, coroutines, and effect-handler-style control flow.

**Last reviewed:** February 16, 2026.

| Field               | Value                                                                                        |
| ------------------- | -------------------------------------------------------------------------------------------- |
| Ecosystem           | WebAssembly proposal and tooling ecosystem                                                   |
| Main proposal track | [WebAssembly stack-switching proposal](https://github.com/WebAssembly/stack-switching)       |
| Research origin     | [Continuing WebAssembly with Effect Handlers (OOPSLA 2023)](https://doi.org/10.1145/3622814) |
| Primary explainer   | [wasmfx.dev](https://wasmfx.dev/)                                                            |

---

## What It Is

WasmFX (as published in OOPSLA 2023) proposes typed continuations as a minimal extension to Wasm for non-local control flow. Instead of forcing whole-program CPS/state-machine transforms, compilers can target continuation primitives directly.

The proposal is designed as a low-level substrate, not a high-level language effect API.

---

## Standardization Status (as of February 16, 2026)

The official `WebAssembly/proposals` tracker currently lists **Stack Switching** in **Phase 3 (Implementation Phase)**.

Important nuance:

- Phase 3 means active implementation work, not final standardization.
- Runtime support is still evolving by engine and toolchain.

Source: [WebAssembly proposals tracker](https://github.com/WebAssembly/proposals)

---

## Core Mechanism

The extension adds six new instructions and one new reference type to core Wasm.

### Control Tags

Control tags are the central typing mechanism. They extend Wasm's exception tags with a return type, making them "resumable exceptions":

```wat
(tag $yield (param i32) (result i32))
;;          ^^^^^^^^^   ^^^^^^^^^^^
;;          payload      return value when resumed
```

A tag declares the type of value sent when suspending (`param`) and the type of value expected when resumed (`result`).

### Continuation Type

A new reference type `(ref $ct)` represents a suspended computation:

```wat
(type $ft (func (param i32) (result i32)))  ;; function type
(type $ct (cont $ft))                        ;; continuation over that function type
```

### Key Instructions

| Instruction    | Purpose                                                            |
| -------------- | ------------------------------------------------------------------ |
| `cont.new`     | Create a continuation from a function reference                    |
| `suspend`      | Suspend the current computation, yielding control to the handler   |
| `resume`       | Resume a suspended continuation with handler clauses               |
| `cont.bind`    | Partially apply a continuation, shrinking its parameter list       |
| `resume_throw` | Resume a continuation by raising an exception inside it (aborting) |
| `switch`       | Direct stack switch between continuations (optimization)           |

### Linearity

Continuations are **one-shot** (linear): each continuation must be invoked exactly once, either by resuming it or by aborting it. After invocation, the continuation object is destructively consumed. This avoids the need for garbage collection of continuation objects and prevents cyclic references.

### Sheep Handlers

WasmFX uses "sheep handlers" -- a hybrid of shallow and deep handler semantics:

- Like **shallow handlers**: The handler is not automatically reinstalled after handling a suspension. The continuation returned to the handler is "bare."
- Like **deep handlers**: A new handler is installed explicitly as part of each `resume` instruction via `(on ...)` clauses.

This gives the programmer explicit control over handler installation while keeping the instruction set minimal.

Sources:

- [WasmFX project site](https://wasmfx.dev/)
- [Typed continuations core extensions](https://wasmfx.dev/specs/core/)
- [WasmFX explainer](https://wasmfx.dev/specs/explainer/)

---

## Generator Example (WAT)

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

This illustrates the core pattern: `suspend` reifies the current stack as a continuation; `resume` with `(on $yield ...)` clauses handles the suspension and receives both the payload and the continuation.

---

## Language Compilation Targets

WasmFX provides a universal compilation target for diverse non-local control flow features:

| Source Feature            | Languages                         | WasmFX Encoding                        |
| ------------------------- | --------------------------------- | -------------------------------------- |
| Async/await               | C#, Dart, JavaScript, Rust, Swift | Tag per async boundary; suspend/resume |
| Generators/iterators      | C#, JavaScript, Kotlin, Python    | Yield tag; resume loop in consumer     |
| Coroutines                | C++, Kotlin, Python               | Symmetric switch or suspend/resume     |
| Lightweight threads       | Erlang, Go, Haskell, OCaml        | Yield tag; round-robin scheduler       |
| First-class continuations | Haskell, OCaml, Scheme            | Direct mapping to cont type            |
| Effect handlers           | Koka, OCaml 5, Eff                | Direct mapping to tags + resume        |

---

## Why It Matters for Algebraic Effects

From an effect-systems perspective, typed continuations give Wasm a practical backend story for handler-based control abstractions:

- effect operations map to suspension points
- handlers map to resume logic with installed clauses
- continuation capture/resume happens at the runtime substrate level

This does not force one specific source-language effect system; it provides a shared target for many of them.

---

## Relation to Other Wasm Proposals

| Proposal               | Relationship to WasmFX                                     |
| ---------------------- | ---------------------------------------------------------- |
| Exception Handling     | WasmFX tags extend exception tags with return types        |
| Function References    | Required for `cont.new` (creating continuations from refs) |
| GC                     | Independent; WasmFX does not require GC                    |
| JS Promise Integration | Alternative approach for async; WasmFX is more general     |
| Threads                | Orthogonal; WasmFX handles concurrency within a thread     |

---

## Implementation Direction

Two implementation streams are visible in public artifacts:

1. Research/reference implementations tied to the WasmFX project
2. Ongoing engine-focused implementation reports (for example, Wasmtime-focused workshop reports)

The 2025 WAW report documents continued implementation experience in Wasmtime-oriented tooling.

Source: [Continuing Stack Switching in Wasmtime (WAW 2025)](https://popl25.sigplan.org/details/waw-2025-papers/7/Continuing-Stack-Switching-in-Wasmtime)

---

## Strengths

- Strong theoretical grounding (typed/sound formalization)
- A common low-level control substrate for multiple language features
- Better compilation target for non-local control than mandatory whole-program transforms
- Compatible with the broader Wasm proposal pipeline
- No GC dependency (one-shot continuations avoid cyclic references)
- Preserves natural call stack structure (debugger-friendly unlike CPS/Asyncify transforms)

## Limits / Open Risks

- Not yet a finalized core WebAssembly standard feature
- Engine/toolchain coverage is still uneven
- One-shot continuations cannot directly express multi-shot effects (backtracking, nondeterminism)
- Language implementers still need substantial frontend/runtime integration work

---

## Sources

- [WasmFX project site](https://wasmfx.dev/)
- [WasmFX explainer](https://wasmfx.dev/specs/explainer/)
- [Typed continuations core extensions](https://wasmfx.dev/specs/core/)
- [WebAssembly stack-switching proposal](https://github.com/WebAssembly/stack-switching)
- [WebAssembly proposals tracker](https://github.com/WebAssembly/proposals)
- [Continuing WebAssembly with Effect Handlers (OOPSLA 2023)](https://doi.org/10.1145/3622814)
- [Continuing Stack Switching in Wasmtime (WAW 2025 session page)](https://popl25.sigplan.org/details/waw-2025-papers/7/Continuing-Stack-Switching-in-Wasmtime)
- [Generator example in WAT](https://github.com/wasmfx/wasmfxtime/blob/main/examples/generator.wat)
