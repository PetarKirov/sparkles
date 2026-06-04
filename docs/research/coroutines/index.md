# Coroutines for LDC

A breadth-first survey of **coroutine** implementation — both halves of the field —
framed against one concrete engineering goal: giving **LDC** (the LLVM-based D
compiler) suspendable, resumable functions, and in the same motion advancing the
port of **D to WebAssembly** (and eventually WasmFX stack-switching). The survey
splits along the field's one load-bearing axis. **Stackless** coroutines capture
only the coroutine's _own_ frame and become a compiler-built state machine; that is
the [stackless track][stackless-index]. **Stackful** coroutines capture the _whole
call stack_ and become a fiber / green thread with a real, switchable machine stack;
that is the [stackful track][stackful-index]. This page is the umbrella that ties
the two tracks together; the deep-dives it points to are the source of truth.

**Last reviewed:** June 4, 2026

---

## Thesis: one definition, two implementations

A **coroutine** is a function that can **suspend** — return control to its caller
before it finishes — and later be **resumed** to continue from exactly where it left
off. The only hard problem in building one is _preserving in-progress state across
the suspension_: live locals, the position in the body, in-flight temporaries. There
are precisely two strategies, and the entire survey is organised around them
([concepts] develops both in full):

- **Stackless** — keep _only the live locals of the coroutine's own frame_ in a
  compiler-synthesised struct (the **coroutine frame**), and rewrite the function
  into a state machine that re-enters itself at the right resumption point. The call
  stack is _not_ captured; it has unwound back to the caller by the time the
  coroutine is suspended. This is what C++20 coroutines do and what LLVM's
  `llvm.coro.*` intrinsics lower — the substrate a D-on-LDC stackless port would
  target. Per-instance memory is _exactly the across-suspend live set_, "as small as
  a few bytes" (`n4134:148`). The cost: a coroutine can suspend **only at a lexical
  await/yield point in its own body**, never from inside an ordinary callee.
- **Stackful** — keep the coroutine's _whole call stack_ alive on the side.
  Suspension is a **stack switch**: swap the CPU stack pointer to a saved one and
  keep going. The state _is_ a real machine stack, addressable and opaque to the
  compiler. This is what D's `core.thread.Fiber` does today ([d-fiber]). It can
  suspend "from nested stack frames" (`n4134:106-108`) — from arbitrary call depth,
  with no function colouring — at the cost of a whole reserved stack per instance
  (16 KiB + a guard page in D's `Fiber`; 1–2 MB by N4134's general-purpose default).

The names come from the only question that distinguishes them: _does the saved state
include the call stack, or not?_ N4134 fixes the definitions verbatim
(`n4134:102-108`, quoted in [concepts]); every downstream design decision in this
survey hangs on that single clause.

> [!IMPORTANT]
> "Stackful coroutine" and "fiber" and "green thread" are the _same concept_ at
> different layers. A **fiber** is the bare stackful coroutine (suspension primitive
> only). A **green thread / virtual thread** is a fiber plus a scheduler plus I/O
> integration — "a green thread _is_ a stackful coroutine plus a scheduler plus I/O
> integration" ([green-threads]). D ships the bare fiber (`core.thread.Fiber`) and
> several green-thread runtimes built on it (vibe.d, Photon); it ships **no**
> compiler-lowered stackless coroutine at all. That gap is what this survey exists to
> map.

---

## Catalog of approaches

One master table spanning **both** models, from the most portable to the most
engine-dependent. _Model_ is the stackless/stackful split; _Lowering / runtime_ is
where the suspension machinery is built; _Frame / stack_ names the persistent-state
model; _wasm story_ is what reaches WebAssembly. Each approach is the subject of (or
a thread through) the linked tracks.

| Approach                                                 | Model         | Lowering / runtime                                                    | Frame / stack                                                           | Portable across DMD/GDC/LDC?                                  | wasm story                                                 | Best for                                                                   |
| -------------------------------------------------------- | ------------- | --------------------------------------------------------------------- | ----------------------------------------------------------------------- | ------------------------------------------------------------- | ---------------------------------------------------------- | -------------------------------------------------------------------------- |
| **Portable frontend state machine**                      | **Stackless** | shared DMD frontend (AST → state-object struct + `switch`)            | compiler-built frame struct; per-glue allocation                        | **Yes** — Rust/C#/Kotlin model; all three benefit             | plain wasm 1.0; no engine support                          | a _language_ `async`/`await` / generator feature that must work everywhere |
| **LLVM switched-resume** (`llvm.coro.id`)                | **Stackless** | LDC glue emits `llvm.coro.*` → `CoroSplit` builds ramp/resume/destroy | opaque coroutine-object handle; HALO-elidable to caller `alloca`        | LDC-only                                                      | plain wasm via state machine                               | C++20-shaped `task`/generator; turnkey path with mature elision            |
| **LLVM returned-continuation** (`coro.id.retcon[.once]`) | **Stackless** | LDC glue → `CoroSplit`                                                | caller-owned fixed-size buffer; no implicit `malloc`                    | LDC-only                                                      | plain wasm via state machine                               | `@nogc` / manual-allocation generators; weak post-inline elision           |
| **LLVM async** (`coro.id.async`, `swiftcc`)              | **Stackless** | LDC glue → `CoroSplit`                                                | caller-allocated async context (heap linked-list); `musttail` transfer  | LDC-only                                                      | plain wasm via state machine                               | executor-hopping `async`/`await`; closest analogue to WasmFX resumption    |
| **D `Fiber`** (baseline; exists today)                   | **Stackful**  | druntime runtime; hand-written asm `fiber_switchContext`              | full machine stack per fiber (16 KiB + guard, **fixed**, never grows)   | **Yes** (ships now)                                           | **none** — `assert(0, "Fibers not supported on WASI")`     | suspend from arbitrary call depth; today's only built-in primitive         |
| **Go-style growable green threads**                      | **Stackful**  | managed runtime: scheduler + `copystack` + precise stack maps         | contiguous stack, starts ~2 KiB, **doubles by copy + pointer-relocate** | n/a (a runtime model; **infeasible for D's conservative GC**) | needs WasmFX or Asyncify (no native wasm stack)            | millions of cheap goroutine-style tasks — _the model D cannot adopt_       |
| **WasmFX engine continuations** (future)                 | **Stackful**  | wasm bytecode + engine                                                | engine-managed one-shot stacks (`cont`); 1 type + 7 instructions        | n/a (a wasm engine feature)                                   | **requires** Phase-3 engine + new LLVM/DMD backend support | stackful fibers, green threads, scheduler-heavy workloads on wasm          |

> [!NOTE]
> Two rows describe models D _cannot_ ship as-is. **Go-style growable stacks** need
> precise per-frame stack maps to relocate interior pointers on every `copystack`
> move (`stack.go:733`, `adjustframe`); D's GC is _conservative_ and C-ABI callees
> are never mapped, so D's fiber is permanently stuck with **fixed** reserved stacks
> ([stack-management] §6). **WasmFX** is a future engine primitive, not in the LLVM
> wasm backend today. Both are in the catalog because the survey's wasm goal spans
> both models. See [stack-management] and [wasmfx-target].

---

## Taxonomy by model

The catalog collapses onto the one axis that decides everything: _who captures
what?_ Each row isolates a property a D coroutine design must reason about. The full
treatment with verbatim N4134 / `Coroutines.rst` quotes is in [concepts].

| Axis                     | **Stackless coroutine**                                                          | **Stackful coroutine / fiber**                                                        |
| ------------------------ | -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| **Who captures what**    | only this coroutine's own frame (live across-suspend locals)                     | the _full call stack_ — "enabling suspension from nested frames" (`n4134:106-108`)    |
| **Suspend scope**        | only at _lexical_ await/yield points in this coroutine's body                    | _anywhere_, including deep inside ordinary nested calls                               |
| **Per-instance memory**  | the compiler-computed minimum live set — "as small as a few bytes" (`n4134:148`) | a whole reserved stack: 16 KiB + guard in D's `Fiber`; 1–2 MB by N4134's default      |
| **Frame / stack sizing** | derived from def-use chains across suspends (`Coroutines.rst:339-346`)           | fixed at creation; over-provisioned; overflow traps on a guard page (no growth for D) |
| **`@nogc`**              | yes — frame is a plain struct, caller-placeable / HALO-elidable, no GC           | no — constructor `mmap`s a stack + GC-allocates a `StackContext` ([d-fiber])          |
| **Who lowers it**        | the **compiler** (frontend state machine, or LLVM `CoroSplit`) — _visible_       | the **runtime** (asm `fiber_switchContext`) — _opaque_ to the optimizer               |
| **wasm**                 | a state machine in linear memory; the _only_ viable path on wasm today           | needs WasmFX / Asyncify — D's `Fiber` `assert(0)`s on WASI ([d-fiber], [wasm])        |
| **Function colouring**   | yes — "is a coroutine" / "must `await`" is a static, signature-level fact        | no — any function may yield                                                           |

### When to use which

**Reach for stackless** when suspension points are statically visible (generators,
`async`/`await`), when memory density matters (millions of in-flight tasks, one per
I/O operation), when `@nogc` / `-betterC` / wasm are targets, or when the compiler
should _see through_ the suspension (thread migration, precise GC scanning). **Reach
for stackful** when you must suspend from _arbitrary call depth_ behind code you do
not control — a synchronous library, a deep recursion, any ordinary callee that may
block — which is the one axis where stackful wins outright and stackless cannot
follow. The pragmatic D synthesis: stackless is the near-term portable win and the
_only_ route to D coroutines on wasm; the stackful `Fiber` stays the primitive for
direct-style "suspend anywhere" concurrency and is what WasmFX is designed to make
cheap on wasm. The two are complementary tracks, not competitors — the
orthogonality argument is in [wasm].

---

## Milestones

A unified timeline interleaving the **stackless lineage** (the C++ paper evolution
that produced the `llvm.coro.*` vocabulary, plus LLVM/Swift as the production
consumers) and the **stackful lineage** (the fiber / green-thread runtimes), with
**D** and **wasm** columns throughout. Per-track detail and the full citation tables
live in the deep-dives ([cpp] for the C++ papers; [context-switching], [green-threads],
[stack-management] for the fiber lineage).

| Date   | Stackless lineage (C++ / LLVM / Swift)                                                                 | Stackful lineage (fibers / green threads)                                                              | D                                                                                         | wasm                                                                                 |
| ------ | ------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| ~2003  | —                                                                                                      | **POSIX `ucontext`** (`getcontext`/`makecontext`/`swapcontext`) — the portable fiber primitive         | —                                                                                         | —                                                                                    |
| ~2000s | —                                                                                                      | **Windows Fibers** (`CreateFiber`/`SwitchToFiber`); Boost.Context later supersedes both for speed      | —                                                                                         | —                                                                                    |
| 2008   | —                                                                                                      | `ucontext` marked **obsolescent** in POSIX.1-2008 — pushing libraries to hand-written asm              | —                                                                                         | —                                                                                    |
| 2009   | —                                                                                                      | **Go goroutines** ship (segmented stacks); the canonical M:N work-stealing runtime                     | —                                                                                         | —                                                                                    |
| 2013   | **N3722** "Resumable Functions"; **N3858** weighs stackful "side stacks" vs stackless frames           | **Rust drops** segmented stacks + green threads, standardises on 1:1 OS threads                        | D's `core.thread.Fiber` is the established stackful primitive                             | —                                                                                    |
| 2014   | **N4134** (Nishanov) **mandates stackless** ("Design goals ... necessitates stackless", n4134:138-140) | **Go 1.3** abandons segmented for **contiguous, copying** stacks (the "hot-split" fix)                 | —                                                                                         | —                                                                                    |
| 2017   | **Coroutines TS N4680** — `co_await`/`co_yield`/`co_return`; LLVM `llvm.coro.*` + `CoroSplit` ship     | —                                                                                                      | —                                                                                         | —                                                                                    |
| 2019   | **P0913** symmetric transfer; **P0981** HALO; promise interface finalised (N4775)                      | —                                                                                                      | —                                                                                         | —                                                                                    |
| 2020   | **C++20** coroutines standardised (P0057r8); Swift async lowering (`coro.id.async`, `swiftcc`)         | —                                                                                                      | `Fiber` + `std.concurrency.Generator` are the _only_ suspension story (both **stackful**) | LLVM coro → plain wasm works (passes are pre-ISel)                                   |
| 2021   | —                                                                                                      | **OCaml 5 effect handlers** = one-shot delimited continuations (heap fiber stacks); Eio builds on them | —                                                                                         | —                                                                                    |
| 2023   | —                                                                                                      | **Java 21 virtual threads** (Loom, JEP 444) GA — continuation + `ForkJoinPool` scheduler               | —                                                                                         | **WasmFX** stack-switching reaches **Phase 3** (1 type + 7 instructions)             |
| 2026   | P1745's `suspend_point_handle` split remains post-C++20 / unshipped                                    | Go contiguous stacks, Loom, Eio mature; D's fiber stays **fixed-stack** (conservative GC)              | **Still no coroutine syntax**; LDC emits no `llvm.coro.*` (greenfield)                    | LDC wasip1/p2/p3 + emscripten codegen tested; **no** WasmFX in the LLVM wasm backend |

> [!NOTE]
> The two lineages converge on the same primitive from opposite ends. OCaml 5's
> effect handlers (2021) expose the stackful continuation as a _public, user-level_
> primitive, and **WasmFX is effect handlers lowered into the wasm engine**
> ([green-threads] §4, [wasmfx]) — the direct conceptual ancestor of the wasm
> stack-switching proposal. Meanwhile the stackless lineage runs N4134's stackless
> mandate (2014) → the `llvm.coro.*` vocabulary → Swift's async lowering. A D-on-LDC
> design reuses _both_: the C++20 promise+awaiter+handle shape that LLVM was
> engineered to lower (stackless), and the `Fiber` → WasmFX retargeting path
> (stackful).

---

## Document map

The survey is two tracks plus two cross-cutting leaves.

### Cross-cutting

| Document                  | One-line                                                                                                                  | Link                 |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------- | -------------------- |
| **Concepts & vocabulary** | Stackless vs stackful, the coroutine frame, suspend points, the suspend-scope limitation, ramp/resume/destroy, the thesis | [concepts][concepts] |
| **wasm & WasmFX**         | LLVM coro → plain wasm (today); Asyncify / JSPI stopgaps; WasmFX stack-switching (future, stackful); orthogonality        | [wasm][wasm]         |

### Stackless track

The compiler-built state machine: capture only the coroutine's own frame. Index:
[stackless-index].

| Document                      | One-line                                                                                                                     | Link                               |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | ---------------------------------- |
| **LLVM coroutine model**      | The three (four) ABIs, the `llvm.coro.*` intrinsic catalog, the switched-resume transform, HALO, custom ABIs                 | [llvm-coroutines][llvm-coroutines] |
| **LLVM coro internals**       | `CoroEarly`/`CoroSplit`/`CoroElide`/`CoroCleanup` pass internals, frame building, the undocumented intrinsics                | [llvm-internals][llvm-internals]   |
| **C++20 coroutines**          | The design template: promise + awaiter + handle, symmetric transfer, HALO, the construct→intrinsic bridge                    | [cpp][cpp]                         |
| **Cross-language comparison** | How Rust, C#, Kotlin, Swift, Python, JS, Go lower coroutines; frontend-state-machine vs LLVM-intrinsic; design lessons for D | [comparison][comparison]           |
| **D language design**         | Candidate D surfaces (generator / `async` / library), frontend lowering precedents, the frontend-vs-glue split               | [d-design][d-design]               |
| **LDC code generation**       | Where `coro.id`/`begin`/`suspend`/`end` would be emitted; `pragma(LDC_intrinsic)` / inline-IR; the closure-frame analog      | [ldc-codegen][ldc-codegen]         |
| **Attributes & memory**       | `@nogc`/`@safe`/`nothrow`/`pure`/`scope` × a heap frame; `checkClosure`/`setGC`; custom allocator and HALO escape hatches    | [attributes][attributes]           |
| **Roadmap**                   | The synthesized, milestoned plan to add stackless coroutines to LDC and to wasm                                              | [roadmap][roadmap]                 |

### Stackful track

The real switchable machine stack: capture the whole call stack. A fiber / green
thread. Index: [stackful-index].

| Document                         | One-line                                                                                                                            | Link                                   |
| -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| **D fiber baseline**             | `core.thread.Fiber` (stackful) + `std.concurrency.Generator`; sizing, GC scan coupling, the TLS-migration hazard, WASI `assert(0)`  | [d-fiber][d-fiber]                     |
| **Context-switching mechanics**  | `fiber_switchContext` stack priming + register save/restore + SP/IP swap; `ucontext`, Windows Fibers, Boost.Context references      | [context-switching][context-switching] |
| **Green threads / M:N runtimes** | Green thread = stackful coroutine + scheduler + I/O integration; Go G-M-P, Loom, GHC, Eio; where D sits                             | [green-threads][green-threads]         |
| **Stack management**             | Fixed-reserved vs segmented vs contiguous-growable; the hot-split cliff; why Go's `copystack` is infeasible for D's conservative GC | [stack-management][stack-management]   |
| **WasmFX as a target**           | Lowering a stackful fiber onto `cont.new`/`resume`/`suspend`; the engine-managed one-shot stack; what LLVM/DMD would need           | [wasmfx-target][wasmfx-target]         |

Cross-tree, the parallel [algebraic-effects corpus][ae-index] and [async-io
survey][async-io-index] are siblings: the [WasmFX deep-dive][wasmfx] is the authority
on engine stack-switching, [OCaml effects][ocaml-effects] and [Java Loom][java-loom]
cover continuation-based suspension, [effects & event loops][effects-event-loops] and
[the Go netpoller][go-netpoller] tie coroutine resumption to completion-driven I/O,
and [the D landscape][d-landscape] maps D's existing fiber-based async ecosystem.

---

## Suggested reading paths

- **"Stackless / adding async-await to LDC."** [concepts] → [stackless-index] →
  [roadmap]. The compiler-built state machine, from the model to the concrete plan.
- **"Stackful / fibers & green threads."** [concepts] → [stackful-index] →
  [d-fiber] → [green-threads]. The switchable machine stack, from D's baseline up to
  full M:N runtimes.
- **"I want the wasm story."** [wasm] → [wasmfx-target] → [wasmfx]. Plain-wasm
  stackless coroutines today; WasmFX engine continuations for stackful fibers later.
- **"Just give me the plan."** → [roadmap].

---

## Sources

Each deep-dive carries its own citations; the authoritative artifacts behind this
umbrella's synthesis are:

- **N4134**, "Resumable Functions v.2" (Nishanov & Radigan, 2014) — the stackless
  definitions and the stackless-mandate argument: `$REPOS/papers/n4134`. The full C++
  paper lineage (N3722, N3858, N4680, N4775, P0057r8, P0913, P0981, P1745) is tabled
  in [cpp].
- **LLVM 23.0.0git** (`$REPOS/llvm-project`): `llvm/docs/Coroutines.rst`,
  `llvm/include/llvm/IR/Intrinsics.td`, `llvm/lib/Transforms/Coroutines/`,
  `llvm/include/llvm/Transforms/Coroutines/CoroShape.h`,
  `llvm/lib/Passes/PassBuilderPipelines.cpp`,
  `llvm/include/llvm/IR/IntrinsicsWebAssembly.td` — surveyed in the stackless track.
- **LDC v1.42** (`$REPOS/dlang/ldc`):
  `runtime/druntime/src/core/thread/fiber/{base.d,package.d,switch_context_asm.S,switch_context_riscv.S}`,
  `runtime/druntime/src/core/thread/context.d`, `runtime/phobos/std/concurrency.d`,
  `gen/`, `driver/main.cpp` — the stackful baseline and the LDC wasm/codegen surface.
- **Go runtime** (`$REPOS/go/go/src/runtime`): `proc.go`, `stack.go`, `runtime2.go`,
  `asm_amd64.s`, `HACKING.md` — the M:N scheduler and contiguous-growable stacks.
- **WasmFX / stack-switching**
  (`$REPOS/wasm/stack-switching/proposals/stack-switching/Explainer.md` and
  `examples/*.wast`) and the survey's [WasmFX deep-dive][wasmfx].
- Cross-tree corpus: the [algebraic-effects][ae-index] and [async-io][async-io-index]
  surveys.

<!-- References -->

<!-- Within-tree: cross-cutting -->

[concepts]: ./concepts.md
[wasm]: ./wasm-and-wasmfx.md

<!-- Within-tree: stackless track -->

[stackless-index]: ./stackless/index.md
[llvm-coroutines]: ./stackless/llvm-coroutines.md
[llvm-internals]: ./stackless/llvm-coro-internals.md
[cpp]: ./stackless/cpp-coroutines.md
[comparison]: ./stackless/comparison.md
[d-design]: ./stackless/d-language-design.md
[ldc-codegen]: ./stackless/ldc-codegen.md
[attributes]: ./stackless/attributes-and-memory.md
[roadmap]: ./stackless/roadmap.md

<!-- Within-tree: stackful track -->

[stackful-index]: ./stackful/index.md
[d-fiber]: ./stackful/d-fiber.md
[context-switching]: ./stackful/context-switching.md
[green-threads]: ./stackful/green-threads.md
[stack-management]: ./stackful/stack-management.md
[wasmfx-target]: ./stackful/wasmfx-as-target.md

<!-- Cross-tree siblings -->

[wasmfx]: ../algebraic-effects/wasmfx.md
[ae-index]: ../algebraic-effects/index.md
[ocaml-effects]: ../algebraic-effects/ocaml-effects.md
[java-loom]: ../algebraic-effects/java-loom.md
[effects-event-loops]: ../async-io/effects-and-event-loops.md
[async-io-index]: ../async-io/index.md
[d-landscape]: ../async-io/d-landscape.md
[go-netpoller]: ../async-io/go-netpoller.md
