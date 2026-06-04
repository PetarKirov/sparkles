# Stackful Coroutines for LDC

This is the section hub for the **stackful** half of the _Coroutines for LDC_ survey.
A stackful coroutine — a **fiber** — captures its _whole call stack_, so it can suspend
from arbitrarily nested frames; D already ships one as [`core.thread.Fiber`][d-fiber],
and a fiber plus a scheduler plus I/O integration is a **green thread**. This index
fixes the stackful thesis, maps the five deep-dives below it, and pins the one fact that
makes this half _separate_ from the [stackless half][stackless-index]: a fiber cannot be
`CoroSplit`, so on WebAssembly it needs an engine-level stack-switch primitive ([WasmFX])
or a whole-program CPS transform (Asyncify) — there is no `sp` to swap.

**Last reviewed:** June 4, 2026

---

## The stackful thesis

The vocabulary is fixed in [concepts] (the cross-cutting glossary for both halves); this
section is the _stackful_ instantiation of it. The defining property, in N4134's words
(quoted in [concepts]), is that a stackful coroutine's saved state "includes the **full
call stack** associated with its execution enabling suspension from nested stack frames"
— and that "stackful coroutines are equivalent to fibers or user-mode threads." Four
consequences organize this whole section:

- **Suspend anywhere.** Because the _entire_ call stack is preserved across a suspension,
  a fiber can `yield` from any call depth, behind any indirect call — no function
  "colouring," no `await` at the call site. The suspension is a raw **stack switch**: swap
  the CPU stack pointer to a saved one and keep going. This is the one axis where stackful
  wins outright over stackless (direct-style code where any nested call may block), and it
  is exactly what D's [`Fiber.yield()`][d-fiber] does.
- **D already ships one.** D's only first-class coroutine is the stackful
  `core.thread.Fiber`, with `std.concurrency.Generator` (a `Fiber` subclass whose
  `popFront` is `Fiber.call()`) and `FiberScheduler` layered on it. There is **no**
  compiler-lowered stackless coroutine in D today — that gap is the subject of the
  [stackless half][stackless-index]; this half characterizes the baseline that already
  exists.
- **The cost is a real reserved stack.** A fiber's per-instance footprint is dominated by
  a whole machine stack reserved at construction — a 16 KiB stack + a guard page on Linux
  by default, larger elsewhere ([d-fiber], [stack-management]). It is **fixed**: it never
  grows (overflow traps on the guard page) and it is over-provisioned regardless of how
  little state is actually live. The constructor `mmap`s the stack and GC-allocates
  bookkeeping, so it is **not `@nogc`** — unlike a stackless frame, there is no
  compiler-computed minimum frame size and no per-suspend allocation-freedom in the same
  sense. (Note the asymmetry: `Fiber.yield()` _is_ `nothrow @nogc`, precisely because the
  expensive resource was reserved in the non-`@nogc` constructor; see [d-fiber].)
- **A green thread = fiber + scheduler + I/O.** Strip the scheduler and the I/O poller off
  Go's goroutines, Java's virtual threads, GHC's green threads, or OCaml/Eio's fibers and
  you are left with the bare stackful coroutine. Add an M:N scheduler (run queues,
  work-stealing, park/unpark) and a readiness/completion poller and you get a green-thread
  runtime. That decomposition is the spine of [green-threads].

> [!IMPORTANT]
> **On WebAssembly the stackful model has nothing to implement.** D's `Fiber` literally
> `assert(0, "Fibers not supported on WASI")` in both its context switch and its stack
> priming (`package.d:576-578`, `:1650-1652`), because wasm exposes no addressable machine
> stack, no `sp` register, and no callee-saved register bank to swap ([d-fiber],
> [wasmfx-target]). A fiber **cannot** be turned into a stackless state machine by LLVM's
> `CoroSplit`, because its suspend points are _not_ statically visible — `yield()` can fire
> from any depth, behind any indirect call. So on wasm a stackful coroutine needs **WasmFX**
> (engine-level `cont.new`/`resume`/`suspend`) or **Asyncify** (a whole-program CPS
> transform), whereas a stackless coroutine compiles to plain wasm directly. This is the
> design fork [wasmfx-target] develops; the spec deep-dive lives cross-tree in [WasmFX].

---

## Stackless vs stackful at a glance

> [!NOTE]
> The full, citation-grounded treatment — N4134's definitions, the coroutine-frame anatomy,
> the suspend-scope limitation, and the survey-thesis tradeoff table — is in [concepts]; the
> umbrella index spanning both halves is [index]. This callout is only the one-line contrast
> that scopes _this_ section.

| Axis                | **Stackless coroutine**                                                      | **Stackful coroutine / fiber** (this section)                                              |
| ------------------- | ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Suspend scope       | only at _lexical_ `await`/`yield` points in this coroutine's own body        | _anywhere_, including from deep inside ordinary nested calls                               |
| Per-instance memory | compiler-computed minimum (often bytes) — the live-across-suspend set        | a whole reserved stack (16 KiB + guard, Linux default; fixed, never grows)                 |
| `@nogc` to create   | yes — frame is a plain struct, caller-placeable / elidable                   | no — constructor `mmap`s a stack + GC-allocates a `StackContext`                           |
| Suspend / resume    | a `switch` on a resume index + reload of spilled locals; compiler-visible    | hand-asm register save/restore + `sp` swap + indirect jump; opaque to the optimizer        |
| Who sees it         | the compiler (it built the state machine) — thread-migratable, wasm-portable | `extern (C)` asm the optimizer cannot see through — TLS-migration hazard; WASI `assert(0)` |
| In D today          | **none** — the gap the [stackless half][stackless-index] argues to fill      | **ships**: `core.thread.Fiber` + `Generator` + `FiberScheduler`                            |

Stackful = _suspend anywhere, pay for a whole stack_. Stackless = _suspend only at the
lexical points you wrote, with a frame that is exactly the live state_. The two are
complementary, not competing: the survey's wasm goal spans both — stackless coroutines are
the near-term portable win, and stackful fibers are exactly what [WasmFX] is designed to
make cheap on wasm.

---

## Document map

The five deep-dives run from the D primitive, down to the raw machine mechanics, out to the
cross-language runtimes built on the same idea, across the stack-growth design space, and
finally to the wasm lowering target.

| Document                        | One-line                                                                                                                                                                                                           | Link                |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------- |
| **D's `Fiber` baseline**        | `core.thread.Fiber` (stackful) + `std.concurrency.Generator`: stack sizing, the asm switch, GC scan coupling, the LDC TLS-migration hazard, WASI `assert(0)` — the cost model stackless improves on                | [d-fiber]           |
| **Context-switching mechanics** | The switch _itself_: stack priming (the fake initial frame / trampolines), per-ABI callee-saved register save/restore, `sp`/IP transfer, and the POSIX `ucontext` / Windows-Fiber / Boost.Context reference points | [context-switching] |
| **Green threads (M:N)**         | "Green thread = fiber + scheduler + I/O integration": Go's G-M-P, Java Loom, GHC, OCaml/Eio — work-stealing, park/unpark, and where D's `Fiber` sits                                                               | [green-threads]     |
| **Stack management**            | The one cost knob: fixed-reserved vs segmented vs contiguous-growable stacks; why Go/OCaml grow-by-copy and D's conservative GC forces fixed `mmap` stacks                                                         | [stack-management]  |
| **WasmFX as a target**          | The operation-by-operation mapping of D's `Fiber` API onto WasmFX's seven stack-switching instructions; one-shot↔reusable impedance; the druntime-backend roadmap                                                 | [wasmfx-target]     |

> [!NOTE]
> These leaves deliberately overlap at the seams and cite rather than restate each other.
> [d-fiber] owns the _baseline cost model_; [context-switching] owns the _per-ABI
> register/`sp`/IP mechanics_ and the `ucontext`/Boost/Windows/Go reference points; they
> share the x86-64 SysV switch quote but only [context-switching] carries the
> AArch64/RISC-V trampoline detail. [stack-management] owns the _growth design space_ and
> cross-links [d-fiber]'s sizing rather than re-deriving the 16 KiB default. [green-threads]
> is a hub over the existing async-I/O and algebraic-effects corpus; [wasmfx-target] owns the
> _D-API → `cont.*` mapping_ and defers all instruction-typing questions to the cross-tree
> [WasmFX] spec deep-dive.

---

## Suggested reading paths

- **"I want D's primitive and why it's the baseline."** [d-fiber] → [stack-management] →
  [context-switching]. The cost model, then the stack-growth design space it sits in, then
  the raw switch mechanics underneath it.
- **"I want the machine-level mechanics."** [context-switching] → [d-fiber] (§the context
  switch). Stack priming, callee-saved save/restore, `sp`/IP transfer per ABI, and the
  `ucontext`-avoidance rationale.
- **"I'm building a scheduler / green-thread runtime."** [green-threads] → [d-fiber] →
  cross to [go-netpoller], [java], [haskell], and [ocaml-effects]. The M:N machinery and
  the park/unpark cycle, grounded in the runtimes that ship it.
- **"I'm targeting wasm with fibers."** [wasmfx-target] → [wasm] → cross to the [WasmFX]
  spec deep-dive and the [algebraic-effects corpus][ae-index]. Why stackful needs an engine
  primitive, and how the seven instructions map onto the `Fiber` API.
- **"How does this relate to stackless?"** [concepts] (the shared model) → [stackless-index]
  (the other half) → [index] (the umbrella thesis).

Across to the [stackless half][stackless-index]: that section argues for a compiler-lowered
stackless coroutine that sidesteps _every_ cost catalogued here — a precise frame, a
`@nogc`-constructible state object, thread-migratability, and plain-wasm portability — while
giving up only the suspend-from-nested-frames generality. The two halves meet at [concepts]
(the model), [wasm] (the wasm fork), and the [umbrella roadmap][index].

---

## Sources

The deep-dives below carry their own citations; the authoritative artifacts behind this
index's synthesis are:

- **LDC v1.42 druntime** (`$REPOS/dlang/ldc`): the stackful primitive —
  `runtime/druntime/src/core/thread/fiber/{base.d,package.d,switch_context_asm.S,switch_context_riscv.S}`
  (`FiberBase`, `State`, `call`/`yield`, `fiber_switchContext`, `initStack`, `allocStack`,
  the WASI `assert(0)`), `runtime/druntime/src/core/thread/context.d` (`StackContext` GC scan
  range), and `runtime/phobos/std/concurrency.d` (`Generator`, `FiberScheduler`).
- **Go runtime** (`$REPOS/go/go/src/runtime`): `proc.go`, `stack.go`, `runtime2.go`,
  `asm_amd64.s` — the canonical M:N scheduler with contiguous growable stacks (the
  green-thread and stack-management contrast).
- **WasmFX** (`$REPOS/wasm/stack-switching/proposals/stack-switching`): `Explainer.md` and
  `examples/*.wast` — the engine-level stack-switching substrate a stackful `Fiber` would
  retarget onto.
- **Cross-tree corpus**: the [WasmFX spec deep-dive][WasmFX] and the [algebraic-effects
  index][ae-index]; the [async-I/O survey][async-io-index] ([go-netpoller], [java],
  [haskell], [D landscape][d-landscape]); and the shared [concepts] glossary and survey
  [umbrella][index].

<!-- References -->

<!-- Within-section siblings -->

[d-fiber]: ./d-fiber.md
[context-switching]: ./context-switching.md
[green-threads]: ./green-threads.md
[stack-management]: ./stack-management.md
[wasmfx-target]: ./wasmfx-as-target.md

<!-- Within-coroutines-tree -->

[index]: ../index.md
[concepts]: ../concepts.md
[wasm]: ../wasm-and-wasmfx.md
[stackless-index]: ../stackless/index.md

<!-- Cross-tree siblings -->

[WasmFX]: ../../algebraic-effects/wasmfx.md
[ae-index]: ../../algebraic-effects/index.md
[ocaml-effects]: ../../algebraic-effects/ocaml-effects.md
[async-io-index]: ../../async-io/index.md
[d-landscape]: ../../async-io/d-landscape.md
[go-netpoller]: ../../async-io/go-netpoller.md
[java]: ../../async-io/java.md
[haskell]: ../../async-io/haskell.md
