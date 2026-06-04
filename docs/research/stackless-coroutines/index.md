# Stackless Coroutines for LDC

A breadth-first survey of stackless-coroutine implementation, framed against one
concrete engineering goal: adding stackless coroutines to **LDC** (the LLVM-based
D compiler) and, in the same motion, advancing the port of **D to WebAssembly**
(and eventually WasmFX stack-switching). It maps the mature LLVM coroutine
framework, the C++20 design that framework was built for, the lowering strategies
of production languages (Rust, C#, Kotlin, Swift), the existing D/LDC machinery a
lowering would reuse, and the wasm story — then distils all of it into a
[roadmap][roadmap].

**Last reviewed:** June 4, 2026

---

## Thesis

The survey rests on three load-bearing claims, each grounded in the local LLVM
23.0.0git, LDC v1.42, and DMD checkouts and developed in the deep-dives this index
points to.

**(a) The LLVM half is largely a solved, reusable problem.** LLVM 23 already ships
a mature, _target-neutral_ stackless-coroutine framework: three lowering ABIs
(switched-resume, returned-continuation, async), the full `llvm.coro.*` intrinsic
family (38 generic intrinsics in `Intrinsics.td:1875-1967`), and the `CoroSplit`
state-machine transform — described as "Converts a coroutine into a state machine"
(`CoroSplit.cpp:1`). Crucially, **LDC already runs the Coro\* passes in its default
pipeline at every optimization level**, including `-O0`: `buildO0DefaultPipeline`
runs `MPM.addPass(buildCoroWrapper(Phase))` near its tail (`PassBuilderPipelines.cpp:2490`),
and that wrapper self-activates the moment a module declares any `llvm.coro.*`
intrinsic (`CoroConditionalWrapper.cpp:18-23`). No new pass plumbing is required.
See [llvm-coroutines][llvm-coroutines], [llvm-internals][llvm-internals], and
[ldc-codegen][ldc-codegen].

**(b) D has no coroutine surface — that is the actual work.** D has _no_ coroutine
syntax today; `grep` for `await`/`coroutine`/`TOKawait` in the DMD tokens finds
nothing. The only suspension story is the **stackful** `core.thread.Fiber` and the
`std.concurrency.Generator` built on it (a `Fiber` subclass whose `popFront` is
`Fiber.call()`). Adding _stackless_ coroutines therefore means designing a D
surface **and** a lowering. Two models compete: a **portable frontend state
machine** (the Rust/C#/Kotlin model — lowering lives in the shared DMD frontend, so
DMD/GDC/LDC all benefit and it compiles to plain wasm), or **LLVM coro intrinsics
in LDC glue** (the Swift model — reuses LLVM's mature frame packing and HALO, but is
LDC-only). See [d-fiber][d-fiber], [d-design][d-design], [comparison][comparison],
and [cpp][cpp].

**(c) Stackless coroutines need zero wasm engine support; WasmFX is a separate,
complementary track.** The `Coro*` passes run in the middle-end CGSCC pipeline
_before_ WebAssembly instruction selection (`PassBuilderPipelines.cpp:480`), so a
coroutine is fully lowered to an ordinary state machine + a heap/stack frame before
the wasm backend ever sees it — which is why the WebAssembly backend has **no**
coroutine or stack-switching intrinsics at all (`IntrinsicsWebAssembly.td`, full
read). Stackless coroutines thus compile to **plain wasm 1.0** on any conforming
engine today. WasmFX stack-switching (`cont.new`/`resume`/`suspend`, Phase 3) is the
right substrate for _stackful_ fibers and green threads — the workloads
`CoroSplit` handles poorly — and is a future glue/backend track, **not** a
prerequisite. See [wasm][wasm] and the [WasmFX deep-dive][wasmfx].

> [!IMPORTANT]
> "Compatibility across LLVM releases is not guaranteed." (`Coroutines.rst:9-10`).
> The whole `llvm.coro.*` IR contract is version-unstable; LDC v1.42 pins LLVM
> 23.0.0git, and any LDC lowering must be re-validated against the linked LLVM —
> especially the intrinsics that have **no** `Coroutines.rst` section
> (`coro.alloca.*`, several `coro.async.*`, `coro.subfn.addr`,
> `coro.prepare.retcon`). See [llvm-internals][llvm-internals].

---

## Catalog of approaches

One row per candidate approach to giving D suspension semantics, from the most
portable to the most engine-dependent. "Lowering layer" is _where_ the state
machine is built; "Frame/ABI" names the frame model; "wasm story" is what reaches
WebAssembly. Each approach is the subject of (or a thread through) the linked
deep-dives.

| Approach                                                      | Lowering layer                                                      | Frame / ABI                                                                           | Portable across DMD/GDC/LDC?                               | wasm story                                                       | Best for                                                                                  |
| ------------------------------------------------------------- | ------------------------------------------------------------------- | ------------------------------------------------------------------------------------- | ---------------------------------------------------------- | ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| **Portable frontend state machine**                           | Shared DMD frontend (AST → state-object struct + `switch` dispatch) | Compiler-built struct; allocation chosen by each glue (`_d_allocmemory` vs `alloca`)  | **Yes** — Rust/C#/Kotlin model; all three backends benefit | Plain wasm 1.0; no engine support                                | A _language_ `async`/`await` / generator feature that must work everywhere                |
| **LLVM switched-resume** (`coro.id`)                          | LDC glue emits intrinsics → `CoroSplit`                             | Opaque coroutine-object handle; resume/destroy/done/promise ABI; HALO-elidable        | LDC-only                                                   | Plain wasm via state-machine                                     | C++20-shaped `task`/generator surface; turnkey path with mature elision                   |
| **LLVM returned-continuation** (`coro.id.retcon[.once]`)      | LDC glue → `CoroSplit`                                              | Caller-owned fixed-size buffer; frontend supplies alloc/dealloc; no implicit `malloc` | LDC-only                                                   | Plain wasm via state-machine                                     | `@nogc`/manual-allocation generators; weak post-inline elision (`Coroutines.rst:170-174`) |
| **LLVM async** (`coro.id.async`, `swiftcc`)                   | LDC glue → `CoroSplit`                                              | Caller-allocated async context (heap-linked list); `musttail` transfer at suspend     | LDC-only                                                   | Plain wasm via state-machine (wasm coro-split status unverified) | Executor-hopping `async`/`await`; closest analogue to WasmFX/event-loop resumption        |
| **Library prototype** (`pragma(LDC_intrinsic,"llvm.coro.*")`) | druntime/library arranges the intrinsic calls; no compiler change   | Whatever ABI the calls select                                                         | LDC-only                                                   | Plain wasm via state-machine                                     | Fastest working LDC prototype / ABI testbed _before_ any syntax exists                    |
| **Stackful `Fiber`** (baseline)                               | druntime runtime (asm context switch)                               | Full machine stack per fiber (16 KiB+ guard pages)                                    | Yes (exists today)                                         | Needs Asyncify, JSPI, or WasmFX (cannot be `CoroSplit`)          | Suspend from arbitrary call depth; today's only built-in primitive                        |
| **WasmFX stack-switching** (future)                           | wasm bytecode + engine                                              | Engine-managed one-shot stacks (`cont`); 7 instructions                               | n/a (a wasm engine feature)                                | **Requires** Phase-3 engine + new LLVM/DMD backend support       | Stackful fibers, green threads, scheduler-heavy workloads on wasm                         |

> [!NOTE]
> The bottom two rows are _stackful_. They are included for contrast and because
> the survey's wasm goal spans both: stackless coroutines (rows 1–5) are the
> near-term portable win, while `Fiber`-style stackful concurrency is exactly what
> WasmFX is designed to make cheap on wasm. See [d-fiber][d-fiber] and [wasm][wasm].

---

## Taxonomy

The catalog cuts four ways. Each axis isolates a design decision the
[roadmap][roadmap] must make.

### By lowering layer

The single most consequential choice. _Where_ does the state machine get built?

| Lowering layer                      | Mechanism                                                                                                                               | Who sees a coroutine                              | Examples                                              | D consequence                                                                                                                                                   |
| ----------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------- | ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Frontend AST / IR state machine** | Compiler rewrites the function into an explicit state object + `MoveNext`/`poll`/`resume` dispatch _before_ any backend IR              | Only the frontend; the backend sees ordinary code | Rust (MIR), C# (Roslyn), Kotlin (CPS), regenerator-JS | Lives in the **shared DMD frontend** → portable across DMD/GDC/LDC; reuses the closure/`closureVars` capture machinery; re-implements liveness LLVM already has |
| **LLVM mid-end intrinsics**         | Frontend emits `llvm.coro.*` into a `presplitcoroutine` function; `CoroSplit` splits it into ramp + resume/destroy and builds the frame | LLVM's middle-end (CGSCC pass)                    | Swift (`coro.id.async`); Clang C++20 (`coro.id`)      | **LDC-only** (DMD/GDC have no equivalent); reuses LLVM's mature frame packing + HALO; intrinsic ABI is version-unstable                                         |

The two are not exclusive: the recommended hybrid keeps **syntax + semantic +
capture analysis in the shared frontend** (so all three compilers agree on what is
a coroutine and how attributes propagate via `mergeFuncAttrs`), exposes a
**backend-neutral lowering target**, and lets **LDC optionally route to
`llvm.coro.*`** as a fast path. This mirrors how D already mixes lowering strategies
per construct: `foreach`-over-array uses a portable `_aApplyXX` druntime helper
while `foreach`-over-range is a pure AST rewrite. See [d-design][d-design] §2 and
[comparison][comparison]'s "Design lessons for D / LDC".

### By frame ABI

LLVM offers three (four, counting the `retcon` variants) lowering ABIs, all
producing ordinary functions + a frame and none emitting a target stack-switch
instruction (`CoroShape.h:26-49`: `enum class ABI { Switch, Retcon, RetconOnce,
Async }`). One line each; [llvm-coroutines][llvm-coroutines] is the source of truth.

- **Switched-resume** (`llvm.coro.id`) — the frame is an opaque "coroutine object"
  handle; one shared resume and one shared destroy function switch over a
  frame-stored suspend index. Frontend allocates (e.g. `malloc`) or LLVM elides.
  The C++20 / Clang default; the turnkey match for a C++20-shaped D surface.
- **Returned-continuation** (`llvm.coro.id.retcon` / `.once`) — every suspend
  returns yielded values **plus a continuation function pointer**; resume = call
  that pointer. Frame lives in a **caller-owned fixed-size buffer** (no implicit
  `malloc`); the frontend supplies alloc/dealloc. Swift's `yield`/accessor
  coroutines; attractive for `@nogc` generators but elides poorly after inlining.
- **Async** (`llvm.coro.id.async`, `swiftcc`) — the coroutine takes the **async
  context** as an argument and returns `void`; the frame is a tail of a
  heap-allocated, linked list of caller contexts; suspend is a `musttail` transfer
  to the callee. Swift `async`/`await`; the closest analogue to event-loop /
  WasmFX-style resumption.

### By surface

What the D programmer writes. Each maps onto an ABI and a candidate lowering (see
[d-design][d-design] §6 for sketched lowerings, [cpp][cpp] for the C++20 template).

| Surface                 | Shape                                                                                                                                                      | Natural ABI | Precedent                                                                     |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ----------------------------------------------------------------------------- |
| **Generator / `yield`** | function returning a compiler-known `Generator!T` exposing `.empty`/`.front`/`.popFront`; slots into existing range `foreach` unchanged                    | retcon      | Rust generators, C++ `co_yield`, `std.concurrency.Generator` (stackful today) |
| **`async` / `await`**   | `async` function returning `Task!T`; `await e` suspends until `e` is ready                                                                                 | async       | Swift, C#, Rust, Kotlin                                                       |
| **Library-driven**      | no new keyword; a `@coroutine` UDA or `core.coro` template + a magic `coroYield`/`coroSuspend`, prototyped via `pragma(LDC_intrinsic,"llvm.coro.suspend")` | any         | D's library-over-keyword preference (`Generator`, `lazy`)                     |

### By frame memory

Where the coroutine frame lives — the axis that decides the `@nogc`/`@safe` story
(developed in [attributes][attributes]).

| Frame memory                                         | How                                                                                                                | `@nogc`?                                                                                                         | Notes                                                                                                                         |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| **GC heap** (`_d_allocmemory`)                       | the same hook `gen/nested.cpp:494` uses for escaping closures                                                      | **No** — trips `checkClosure`/`setGC`; a `@nogc` coroutine with a GC frame is a hard error, and so is `-betterC` | the simplest correct default                                                                                                  |
| **Custom allocator** (`_d_coro_alloc`/retcon buffer) | a druntime `_d_coro_alloc` hook, or the caller-owned retcon buffer                                                 | **Yes**                                                                                                          | the route to `@nogc`/`-betterC` coroutines; precedent: "separate allocator is called for this, not the GC" (`nogc.d:187-188`) |
| **Stack-elided** (HALO)                              | `coro.alloc`→`false`, `coro.begin`→caller `alloca` when the coroutine is created, used, and destroyed in one scope | **Yes** when it fires                                                                                            | requires the ramp to be inlined (`Coroutines.rst:2287-2289`); the C++/LLVM "zero-overhead" path                               |

---

## Milestones

A high-confidence timeline interleaving the **C++ paper lineage** (the design
evolution that produced the `llvm.coro.*` vocabulary), **LLVM/Swift** (the
production consumers), **D** (still no syntax in 2026), and **wasm**. C++ paper
dates and quotes are from the local PDFs in `$REPOS/papers/`; see
[cpp][cpp] for the full lineage table.

| Date    | C++ design lineage                                                                                                                   | LLVM / Swift                                                                                         | D                                                                                                   | wasm                                                                                                              |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| 2013    | **N3722** "Resumable Functions" — `resumable` keyword + `await`, tied to `future<T>`                                                 | —                                                                                                    | —                                                                                                   | —                                                                                                                 |
| 2014-01 | **N3858** evaluates **stackful ("side stacks") vs stackless ("heap-allocated activation frames")**                                   | —                                                                                                    | —                                                                                                   | —                                                                                                                 |
| 2014-10 | **N4134** (Nishanov) drops `resumable`; **mandates stackless** ("Design goals ... necessitates stackless coroutines", n4134:138-140) | —                                                                                                    | —                                                                                                   | —                                                                                                                 |
| 2017    | **Coroutines TS N4680** — `co_await`/`co_yield`/`co_return` keywords                                                                 | LLVM `llvm.coro.*` + `CoroSplit` ship for Clang C++ (switched-resume)                                | —                                                                                                   | —                                                                                                                 |
| 2018    | **N4775** — promise interface finalized (`get_return_object`/`initial_suspend`/`final_suspend`/…)                                    | —                                                                                                    | —                                                                                                   | —                                                                                                                 |
| 2019    | **P0913** symmetric transfer; **P0981** HALO; **P1745** divergence of coroutines & ranges                                            | —                                                                                                    | —                                                                                                   | —                                                                                                                 |
| 2020    | **C++20 P0057r8** — coroutines standardized                                                                                          | Swift async lowering (`coro.id.async`, `swiftcc`/`swifttailcc`) — the production LLVM-async consumer | `core.thread.Fiber` + `std.concurrency.Generator` are the only suspension story (both **stackful**) | LLVM coro → plain wasm works (passes are pre-ISel)                                                                |
| 2023    | —                                                                                                                                    | —                                                                                                    | —                                                                                                   | **WasmFX** stack-switching reaches **Phase 3** (1 type + 7 instructions)                                          |
| 2026    | P1745's `suspend_point_handle` split remains post-C++20 / unshipped                                                                  | LDC v1.42 links LLVM 23.0.0git; Coro\* passes in the default pipeline at every `-O`                  | **Still no coroutine syntax**; LDC emits no `llvm.coro.*` (greenfield)                              | LDC wasip1/p2/p3 + emscripten codegen tested; betterC+Phobos → wasm works; **no** WasmFX in the LLVM wasm backend |

> [!NOTE]
> The dependency that matters: N4134's stackless mandate (2014) → the `llvm.coro.*`
> vocabulary (built _for_ the C++20 model) → Swift's async lowering (the one
> production LLVM-async consumer). A D-on-LDC design that adopts the C++20
> promise+awaiter+handle shape is reusing a lineage that LLVM was explicitly
> engineered to lower. See [cpp][cpp] §0 and §6.

---

## Document map

| Document                      | One-line                                                                                                                                                | Link                               |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------- |
| **Concepts & vocabulary**     | Stackless vs stackful, frame/ramp/resume/destroy, suspend points, promise/awaiter/handle — the shared glossary                                          | [concepts][concepts]               |
| **LLVM coroutine model**      | The three ABIs, the `llvm.coro.*` intrinsic catalog, the switched-resume transformation, HALO, custom ABIs                                              | [llvm-coroutines][llvm-coroutines] |
| **LLVM coro internals**       | `CoroEarly`/`CoroSplit`/`CoroElide`/`CoroCleanup` pass internals, frame building, the undocumented intrinsics                                           | [llvm-internals][llvm-internals]   |
| **C++20 coroutines**          | The design template: promise + awaiter + handle, symmetric transfer, HALO, and the construct→intrinsic bridge table                                     | [cpp][cpp]                         |
| **Cross-language comparison** | How Rust, C#, Kotlin, Swift, Python, JS, Go lower coroutines; frontend-state-machine vs LLVM-intrinsic; design lessons for D                            | [comparison][comparison]           |
| **D fiber baseline**          | `core.thread.Fiber` (stackful) + `std.concurrency.Generator`; the cost model stackless coroutines improve on                                            | [d-fiber][d-fiber]                 |
| **D language design**         | Candidate D surfaces (generator/`async`/library), frontend lowering precedents (`foreach`/`lazy`/`scope`/`_d_*`), the frontend-vs-glue split            | [d-design][d-design]               |
| **LDC code generation**       | Where `coro.id`/`begin`/`suspend`/`end` would be emitted; `pragma(LDC_intrinsic)`/inline-IR; the closure-frame analog; the pipeline already runs Coro\* | [ldc-codegen][ldc-codegen]         |
| **Attributes & memory**       | `@nogc`/`@safe`/`nothrow`/`pure`/`scope` × a heap frame; `checkClosure`/`setGC`; custom allocator and HALO escape hatches                               | [attributes][attributes]           |
| **wasm & WasmFX**             | LLVM coro → plain wasm (today); Asyncify/JSPI stopgaps; WasmFX stack-switching (future, stackful); the orthogonality argument                           | [wasm][wasm]                       |
| **Roadmap**                   | The synthesized, milestoned plan to add stackless coroutines to LDC and to wasm                                                                         | [roadmap][roadmap]                 |

Cross-tree, the parallel [algebraic-effects corpus][ae-index] and [async-io
survey][async-io-index] are siblings: the [WasmFX deep-dive][wasmfx] is the
authority on stack-switching, [theory/compilation][theory-compilation] and [OCaml
effects][ocaml-effects] cover continuation-based suspension, and
[effects & event loops][effects-event-loops] / [the D landscape][d-landscape] tie
coroutine resumption to completion-driven I/O.

---

## Suggested reading paths

- **"I want the mechanism."** [concepts][concepts] → [llvm-coroutines][llvm-coroutines] → [llvm-internals][llvm-internals]. How an LLVM coroutine becomes a state machine + frame.
- **"I want the C++ template."** [cpp][cpp] → [llvm-coroutines][llvm-coroutines] (§ the construct→intrinsic bridge). The promise+awaiter+handle shape `llvm.coro.*` was built for.
- **"I am designing the D surface."** [comparison][comparison] → [d-fiber][d-fiber] → [d-design][d-design] → [cpp][cpp]. Frontend-state-machine vs LLVM-intrinsic, the existing `foreach`/`lazy`/`closureVars` machinery, and candidate syntaxes.
- **"I care about `@nogc`/`@safe`."** [attributes][attributes] → [d-design][d-design] (§3) → [ldc-codegen][ldc-codegen] (§ the `_d_allocmemory` frame hook). The GC-frame error and the custom-allocator / HALO escape hatches.
- **"I am targeting wasm."** [wasm][wasm] → [WasmFX deep-dive][wasmfx] → [ae-index][ae-index]. Plain-wasm stackless coroutines today; WasmFX stack-switching for stackful fibers later.
- **"Just give me the plan."** → [roadmap][roadmap].

---

## Sources

Each deep-dive carries its own citations; the authoritative artifacts behind this
index's synthesis are:

- **LLVM 23.0.0git** (local, `$REPOS/llvm-project`): `llvm/docs/Coroutines.rst`, `llvm/include/llvm/IR/Intrinsics.td`, `llvm/include/llvm/IR/Attributes.td`, `llvm/include/llvm/IR/IntrinsicsWebAssembly.td`, `llvm/lib/Transforms/Coroutines/{CoroSplit,CoroFrame,CoroConditionalWrapper,CoroEarly}.cpp`, `llvm/include/llvm/Transforms/Coroutines/CoroShape.h`, `llvm/lib/Passes/PassBuilderPipelines.cpp`.
- **LDC v1.42** (local, `$REPOS/dlang/ldc`): `gen/{functions,nested,toir,optimizer,pragma,runtime,inlineir}.cpp`, `gen/abi/{abi,wasm}.cpp`, `runtime/druntime/src/ldc/intrinsics.di`, `runtime/druntime/src/core/thread/fiber/base.d`, `runtime/phobos/std/concurrency.d`, `driver/main.cpp`, `rt/wasi_exceptions.d`.
- **DMD frontend** (shared, vendored in `dlang/ldc/dmd`): `statementsem.d`, `expressionsem.d`, `func.d`, `funcsem.d`, `semantic3.d`, `nogc.d`, `clone.d`, `target.d`.
- **C++ papers** (local PDFs, `$REPOS/papers/`): N3722, N3858, N4134, N4680, N4775, P0057r8, P1745. P0913 (symmetric transfer) and P0981 (HALO) are HTML-only at <https://wg21.link/p0913> and <https://wg21.link/p0981>.
- **WasmFX**: `$REPOS/wasm/stack-switching/proposals/stack-switching/Explainer.md`, and the survey's [WasmFX deep-dive][wasmfx].

<!-- References -->

<!-- Within-tree siblings -->

[concepts]: ./concepts.md
[llvm-coroutines]: ./llvm-coroutines.md
[llvm-internals]: ./llvm-coro-internals.md
[cpp]: ./cpp-coroutines.md
[comparison]: ./comparison.md
[d-fiber]: ./d-fiber-baseline.md
[d-design]: ./d-language-design.md
[ldc-codegen]: ./ldc-codegen.md
[attributes]: ./attributes-and-memory.md
[wasm]: ./wasm-and-wasmfx.md
[roadmap]: ./roadmap.md

<!-- Cross-tree siblings -->

[wasmfx]: ../algebraic-effects/wasmfx.md
[ae-index]: ../algebraic-effects/index.md
[theory-compilation]: ../algebraic-effects/theory-compilation.md
[ocaml-effects]: ../algebraic-effects/ocaml-effects.md
[effects-event-loops]: ../async-io/effects-and-event-loops.md
[async-io-index]: ../async-io/index.md
[d-landscape]: ../async-io/d-landscape.md
