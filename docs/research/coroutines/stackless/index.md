# Stackless Coroutines for LDC — Section Index

This is the hub for the **stackless** half of the _Coroutines for LDC_ survey: the
eight deep-dives that map LLVM's stackless-coroutine machinery, the C++20 design it
was built for, how production compilers lower `async`/`await`/`yield`, and what it
would take to give D a stackless surface on top. The stackless track is the
near-term, portable win — a coroutine is rewritten into an ordinary state machine
plus a heap-or-elided frame entirely in the compiler, so it needs **no** runtime
stack-switch and **no** wasm engine support. For the suspend-from-any-call-depth
model (`core.thread.Fiber`, green threads, WasmFX), see the sibling
[stackful track][stackful-index]; for the shared vocabulary both tracks use, see
[concepts][concepts].

**Last reviewed:** June 4, 2026

---

## The stackless thesis

Three load-bearing claims frame this entire track. Each is grounded in the local
LLVM 23.0.0git, LDC v1.42, and DMD checkouts and developed in the deep-dives below.

**(1) The LLVM half is a mature, target-neutral, reusable framework — and LDC
already runs it.** LLVM 23 ships three lowering ABIs (switched-resume,
returned-continuation, async), the full `llvm.coro.*` intrinsic family (38 generic
intrinsics in `Intrinsics.td:1875-1967`), and the `CoroSplit` transform —
"Converts a coroutine into a state machine" (`CoroSplit.cpp:1`). Crucially, **LDC
already runs the `Coro*` passes in its default pipeline at every optimization level**,
including `-O0`: `buildO0DefaultPipeline` runs `MPM.addPass(buildCoroWrapper(Phase))`
near its tail (`PassBuilderPipelines.cpp:2490`), and that wrapper self-activates the
moment a module declares any `llvm.coro.*` intrinsic
(`CoroConditionalWrapper.cpp:18-23`). No new pass plumbing is required — an LDC that
merely _emits_ the intrinsics inherits the whole state-machine transform for free.
See [llvm-coroutines][llvm-coroutines], [llvm-internals][llvm-internals], and
[ldc-codegen][ldc-codegen].

**(2) D has no coroutine surface — that is the actual work.** D has _no_ coroutine
syntax today; the only suspension story is the **stackful** `core.thread.Fiber` and
the `std.concurrency.Generator` built on it (see [d-fiber][d-fiber]). Adding
_stackless_ coroutines therefore means designing a D surface **and** a lowering. The
shared DMD frontend already contains every mechanism a lowering needs (loop-body →
delegate conversion, the closure/frame-struct machinery, the `object._d_*` lowering
habit), so the question is _where_ the state machine gets built: a **portable
frontend state machine** (the Rust/C#/Kotlin model — lives in the shared frontend, so
DMD/GDC/LDC all benefit) or **LLVM coro intrinsics in LDC glue** (the Swift model —
reuses LLVM's mature frame packing and HALO, but is LDC-only). See
[d-design][d-design], [comparison][comparison], and [cpp][cpp].

**(3) Stackless coroutines compile to plain wasm with zero engine support.** The
`Coro*` passes run in the middle-end CGSCC pipeline _before_ WebAssembly instruction
selection (`PassBuilderPipelines.cpp:480`), so a coroutine is fully lowered to an
ordinary state machine + a heap/stack frame before the wasm backend ever sees it —
which is why the WebAssembly backend has **no** coroutine or stack-switching
intrinsics at all. Stackless coroutines thus compile to **plain wasm 1.0** on any
conforming engine today. WasmFX stack-switching is the right substrate for _stackful_
fibers — the workloads `CoroSplit` handles poorly — and is a future, complementary
track, **not** a prerequisite. See [wasm][wasm] and the [stackful track][stackful-index].

> [!IMPORTANT]
> "Compatibility across LLVM releases is not guaranteed." (`Coroutines.rst:9-10`).
> The whole `llvm.coro.*` IR contract is version-unstable; LDC v1.42 pins LLVM
> 23.0.0git, and any LDC lowering must be re-validated against the linked LLVM —
> especially the intrinsics with **no** `Coroutines.rst` section. See
> [llvm-internals][llvm-internals].

---

## Document map

One row per deep-dive in this stackless subtree, in the order the survey builds the
argument: the LLVM mechanism, the C++20 template, the cross-language comparison, the
D surface, the LDC glue, the attribute/memory story, and the synthesized plan.

| Document                  | One-line                                                                                                                                                 | Link                               |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------- |
| **LLVM coroutine model**  | The three ABIs, the `llvm.coro.*` intrinsic catalog, the worked switched-resume transformation, HALO, exception handling, custom-ABI plugins             | [llvm-coroutines][llvm-coroutines] |
| **LLVM coro internals**   | What the passes _do_: `CoroEarly`/`CoroSplit`/`CoroFrame`/`CoroElide`/`CoroCleanup`, frame discovery & layout, the undocumented intrinsics               | [llvm-internals][llvm-internals]   |
| **C++20 coroutines**      | The design template: promise + awaiter + handle, the compiler-synthesized body rewrite, symmetric transfer, HALO, the surface → intrinsic bridge tables  | [cpp][cpp]                         |
| **Cross-language survey** | How Rust, C#, Kotlin, Swift, Python, JS lower `async`/`await`/`yield`; frontend-state-machine vs LLVM-intrinsic; the design lessons for D                | [comparison][comparison]           |
| **D language design**     | Candidate D surfaces (generator / `async` / library), frontend lowering precedents (`foreach`/`lazy`/`scope`/`_d_*`/`closureVars`), frontend-vs-glue     | [d-design][d-design]               |
| **LDC code generation**   | Where `coro.id`/`begin`/`suspend`/`end` would be emitted; `pragma(LDC_intrinsic)`/inline-IR; the closure-frame analog; the pipeline already runs `Coro*` | [ldc-codegen][ldc-codegen]         |
| **Attributes & memory**   | `@nogc`/`@safe`/`nothrow`/`pure`/`scope` × a heap frame; the frame-is-an-escaping-closure insight; `checkClosure`/`setGC`; custom allocator and HALO     | [attributes][attributes]           |
| **Roadmap**               | The synthesized, phased plan: library prototype → ABI decision → shared-frontend surface → `@nogc`/EH → wasm → WasmFX as a future track                  | [roadmap][roadmap]                 |

> [!NOTE]
> The roadmap is the synthesis leaf — it consumes every other document in this
> subtree (plus the [stackful track][stackful-index]) and turns them into a phased
> engineering plan. Read it last, or read it first for the executive summary and
> follow the cross-links back into the evidence.

---

## Reading paths within the stackless track

Pick the entry point that matches what you are after. All paths assume the shared
vocabulary in [concepts][concepts]; start there if "ramp", "frame", "suspend point",
or "promise/awaiter/handle" are unfamiliar.

- **"I want the mechanism — how does a coroutine become a state machine?"**
  [llvm-coroutines][llvm-coroutines] → [llvm-internals][llvm-internals]. The
  intrinsic surface a frontend emits, then what `CoroSplit`/`CoroFrame` _do_ with it.
- **"I want the C++ design template."** [cpp][cpp] →
  [llvm-coroutines][llvm-coroutines] (§ the construct → intrinsic bridge). The
  promise + awaiter + handle shape `llvm.coro.*` was explicitly built to lower.
- **"I am designing the D surface."** [comparison][comparison] → [d-design][d-design]
  → [cpp][cpp]. Frontend-state-machine vs LLVM-intrinsic across seven production
  compilers, then the existing `foreach`/`lazy`/`closureVars` machinery and three
  candidate syntaxes mapped onto an ABI.
- **"How would LDC actually emit this?"** [ldc-codegen][ldc-codegen] →
  [llvm-internals][llvm-internals]. The glue-layer insertion strategies
  (library-via-`pragma` vs first-class emission) and what the passes expect to see.
- **"I care about `@nogc`/`@safe`/`-betterC`."** [attributes][attributes] →
  [d-design][d-design] (§ the allocation choice) → [ldc-codegen][ldc-codegen]
  (§ the `_d_allocmemory` frame hook). The GC-frame hard error and the
  custom-allocator / HALO escape hatches.
- **"Just give me the plan."** → [roadmap][roadmap].

For the wasm angle — plain-wasm stackless today vs WasmFX stack-switching for
stackful fibers later — see [wasm][wasm].

---

## Where this sits in the survey

```text
Coroutines for LDC  (umbrella)        [index]
├── concepts            stackless vs stackful, the shared glossary   [concepts]
├── wasm-and-wasmfx     plain wasm today; WasmFX for stackful later  [wasm]
├── stackless/  ◀── YOU ARE HERE      the compiler-built state machine
│   └── 8 deep-dives (mapped above)
└── stackful/           the runtime stack-switch model   [stackful-index]
    └── d-fiber, context-switching, green-threads, stack-management, wasmfx-as-target
```

- **Up** to the umbrella [index][index] for the cross-track thesis, the full catalog
  of approaches, and the milestone timeline.
- **Across** to the [stackful track][stackful-index] for `core.thread.Fiber`, green
  threads, and WasmFX-as-target — the suspend-from-any-call-depth model stackless
  coroutines deliberately do _not_ provide.
- **Sideways** to [concepts][concepts] (vocabulary) and [wasm][wasm] (the wasm story
  both tracks share).

Cross-tree, the parallel [algebraic-effects corpus][ae-index] and
[async-io survey][async-io-index] are siblings: the [WasmFX deep-dive][wasmfx] is the
authority on stack-switching, [OCaml effects][effects-event-loops] and the
[D landscape][d-landscape] tie coroutine resumption to completion-driven I/O.

---

## Sources

This is a navigational hub; each deep-dive carries its own citations. The artifacts
behind the thesis above:

- **LLVM 23.0.0git** (local, `$REPOS/llvm-project`):
  `llvm/docs/Coroutines.rst`, `llvm/include/llvm/IR/Intrinsics.td`,
  `llvm/lib/Transforms/Coroutines/{CoroSplit,CoroConditionalWrapper}.cpp`,
  `llvm/lib/Passes/PassBuilderPipelines.cpp`,
  `llvm/include/llvm/IR/IntrinsicsWebAssembly.td`.
- **LDC v1.42** (local, `$REPOS/dlang/ldc`):
  `runtime/druntime/src/core/thread/fiber/base.d`,
  `runtime/phobos/std/concurrency.d`, `gen/nested.cpp`.
- The eight stackless deep-dives this index points to, and the cross-track
  [stackful section][stackful-index].

<!-- References -->

<!-- Umbrella + cross-track siblings -->

[index]: ../index.md
[concepts]: ../concepts.md
[wasm]: ../wasm-and-wasmfx.md
[stackful-index]: ../stackful/index.md
[d-fiber]: ../stackful/d-fiber.md

<!-- Stackless deep-dives -->

[llvm-coroutines]: ./llvm-coroutines.md
[llvm-internals]: ./llvm-coro-internals.md
[cpp]: ./cpp-coroutines.md
[comparison]: ./comparison.md
[d-design]: ./d-language-design.md
[ldc-codegen]: ./ldc-codegen.md
[attributes]: ./attributes-and-memory.md
[roadmap]: ./roadmap.md

<!-- Cross-tree siblings -->

[wasmfx]: ../../algebraic-effects/wasmfx.md
[ae-index]: ../../algebraic-effects/index.md
[effects-event-loops]: ../../async-io/effects-and-event-loops.md
[async-io-index]: ../../async-io/index.md
[d-landscape]: ../../async-io/d-landscape.md
