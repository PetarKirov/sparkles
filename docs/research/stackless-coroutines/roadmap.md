# Roadmap: Adding Stackless Coroutines to LDC

The synthesis document for this survey. It distills the nine grounding digests into a
concrete, phased engineering plan a maintainer could act on: a library prototype that
proves the existing LLVM pipeline already does the hard part, an ABI decision, a
shared-frontend surface lowering, the `@nogc`/exception story, the WebAssembly path that
ships essentially for free, and WasmFX as a future complementary track. Each phase names
the grounded mechanism (with file:line citations into LLVM 23.0.0git, LDC v1.42, and the
shared DMD frontend) and is followed by consolidated risks, open questions, and a final
recommendation.

**Last reviewed:** June 4, 2026

---

## Where we stand

Three load-bearing facts frame the entire plan. They are each established in detail by a
sibling deep-dive; the cross-links carry the evidence.

1. **The LLVM half is largely solved and already wired into LDC's pipeline.** LLVM 23
   ships the full `llvm.coro.*` intrinsic family (`Intrinsics.td:1875-1968`) and the
   transformation passes (`CoroEarly`, `CoroSplit`, `CoroElide`, `CoroAnnotationElide`,
   `CoroCleanup`) that turn an ordinary function marked `presplitcoroutine` into a state
   machine plus out-of-line resume/destroy functions. Crucially, LDC drives the _stock_
   pipeline builders (`gen/optimizer.cpp:557` `pb.buildPerModuleDefaultPipeline(level)`),
   and those embed a `CoroConditionalWrapper` that self-activates the moment a module
   declares any coro intrinsic — `if (!coro::declaresAnyIntrinsic(M)) return
PreservedAnalyses::all();` (`CoroConditionalWrapper.cpp:18-23`). So no new pass
   registration is needed: emit the intrinsics and the split happens, even at `-O0`. See
   [LLVM coroutine model][llvm-coroutines], [LLVM pass internals][llvm-internals], and
   [LDC code generation][ldc-codegen].

2. **D has no surface and emits no intrinsics today — this is greenfield.** D's only
   coroutine primitive is the _stackful_ `core.thread.Fiber` (and
   `std.concurrency.Generator` built on it), which reserves a multi-KiB machine stack per
   instance, GC-scans a `StackContext`, has a non-`@nogc` allocating constructor, an
   LDC-specific TLS thread-migration hazard, and `assert(0, "Fibers not supported on
WASI")` on wasm (`core/thread/fiber/package.d:576-578`). There is no `await`/`yield`
   keyword (`grep` of `dmd/tokens.{h,d}` → 0), no DIP, and LDC's `gen/` emits no
   `llvm.coro.*` (`grep` of `dlang/ldc/gen` → 0). But the frontend already contains every
   _mechanism_ a lowering needs — loop-body→delegate (`foreachBodyToFunction`), capture
   analysis (`closureVars`/`needsClosure`), `_d_*`-template lowering, and attribute
   propagation (`mergeFuncAttrs`). See [D fiber baseline][d-fiber] and
   [D language design][d-design].

3. **Wasm works stackless today; WasmFX is a future, complementary track.** LLVM's coro
   passes run in the middle-end CGSCC pipeline, _before_ WebAssembly instruction selection
   (`PassBuilderPipelines.cpp:480`), and lower a coroutine to an ordinary state machine +
   frame struct. The WebAssembly backend has _no_ coroutine or stack-switching intrinsics
   at all (`IntrinsicsWebAssembly.td`, full read; `grep` of `lib/Target/WebAssembly` for
   stack-switching → 0), so it compiles the residual IR to plain wasm 1.0 on any engine.
   WasmFX (`cont.new`/`suspend`/`resume`/`switch`) is a _backend/engine_ feature for the
   cases stackless lowering handles poorly — stackful fibers and scheduler-heavy green
   threads — not a prerequisite and not how `async`/`await` should be implemented. See
   [wasm and WasmFX][wasm] and the WasmFX deep-dive [wasmfx][wasmfx].

> [!IMPORTANT]
> The whole `llvm.coro.*` contract is version-unstable: the spec opens with
> ".. warning:: Compatibility across LLVM releases is not guaranteed." (`Coroutines.rst:9-10`).
> Every decision below is pinned to the LLVM that LDC v1.42 links (23.0.0git) and must be
> re-validated against the actual headers on any LLVM bump.

---

## The phased plan

The phases are ordered by risk and dependency, not by ambition. Phase 0 is a throwaway
prototype that de-risks everything after it. Phases 1-4 build the real feature on LDC;
Phase 5 is the wasm payoff; Phase 6 is the optional WasmFX track. Phases 0, 1, 5 can begin
immediately; Phase 2 (frontend) is the long pole.

| Phase | Goal                                            | Risk   | Blocks on               |
| ----- | ----------------------------------------------- | ------ | ----------------------- |
| **0** | Library prototype, no compiler change           | low    | nothing                 |
| **1** | ABI choice (decision)                           | low    | Phase 0 evidence        |
| **2** | Surface syntax + shared-frontend lowering       | high   | Phase 1                 |
| **3** | Memory + attributes (`@nogc`/`@safe`/allocator) | medium | Phase 2                 |
| **4** | Exception handling (no-EH first)                | medium | Phase 3                 |
| **5** | WebAssembly (ships ~for free)                   | low    | Phases 0-2              |
| **6** | WasmFX (future, complementary)                  | high   | upstream LLVM + engines |

---

### Phase 0 — Library prototype (no compiler change)

**Deliverable:** a working LDC-only proof that the existing pipeline already does the heavy
lifting — a hand-written stackless generator/task driven entirely from D source, with no
DMD frontend change.

This is feasible _today_ because of two facts established in [ldc-codegen] and
[d-design]:

- LLVM intrinsics are reachable from D via `pragma(LDC_intrinsic, "...")`. The pragma sets
  the function's mangle override to the literal intrinsic name
  (`gen/pragma.cpp:353-361`); because the name begins with `llvm.`, LLVM automatically
  recognizes it as an intrinsic and `gen/tocall.cpp:1043-1052` copies the intrinsic
  attribute list. The existing `ldc.intrinsics` module is the precedent and home
  (`runtime/druntime/src/ldc/intrinsics.di:55`):

  ```d
  pragma(LDC_intrinsic, "llvm.returnaddress")
      void* llvm_returnaddress(uint level);
  ```

- The coro pipeline self-activates: `CoroConditionalWrapper` runs `CoroSplit` as soon as a
  module declares any coro intrinsic, even at LDC's default `-O0`
  (`PassBuilderPipelines.cpp:475-485`, `gen/optimizer.cpp:557`).

**Tasks.**

1. Add a `core.coro` (or `ldc.coro`) module declaring the switched-resume intrinsics as
   `pragma(LDC_intrinsic, ...)` functions. Most have plain `ptr`/`i1`/`i8` signatures and
   need no overload suffix: `coro.id`, `coro.begin`, `coro.suspend`, `coro.end`,
   `coro.free`, `coro.alloc`, `coro.resume`, `coro.destroy`, `coro.done`, `coro.promise`,
   `coro.frame` ([ldc-codegen] §2.4). The `anyint`-overloaded `coro.size`/`coro.align`
   need an explicit suffix in the name string, e.g. `"llvm.coro.size.i64"`.

2. Handle the `token` type, which **has no D representation**. `coro.id`/`coro.save`
   return `token` and `coro.begin`/`coro.suspend`/`coro.end` consume it. The escape hatch
   is `pragma(LDC_inline_ir)` (`gen/inlineir.cpp:104`): `DtoInlineIRExpr` builds an LLVM
   `define` string, parses it (`gen/inlineir.cpp:192-193`), links it into the module,
   marks it `AlwaysInline` + `PrivateLinkage`, and emits a call. The `inlineIREx` form's
   prefix/suffix can emit module-level declarations and define the token-typed sequence by
   hand. Because each instantiation defines a fresh `inline.ir.N` function that is always
   inlined, the coro intrinsics land inline in the caller, exactly where `CoroSplit`
   expects them.

3. Hand-write a switched-resume generator: mark the producer function
   `presplitcoroutine` (via a UDA or inline-IR attribute), emit the canonical
   `coro.id → coro.size → coro.alloc(branch) → malloc → coro.begin` prologue, a
   `coro.save → coro.suspend → switch i8` triple at each yield
   (`Coroutines.rst:298-308`, [llvm-coroutines] §3), and a `coro.free`/`coro.end` epilogue.
   Expose a D `Generator`-like wrapper whose `.popFront` is `coro.resume`, `.front` reads
   the promise via `coro.promise`, and `.empty` is `coro.done`.

4. **Validate the split fires and inspect the emitted state machine.** Compile with
   `-output-ll` / `--output-s` and confirm `CoroSplit` produced a ramp `@f`, plus
   `@f.resume` / `@f.destroy` clones with a frame `{ ptr, ptr, ..., index }` and the
   resume-index `switch` (`Coroutines.rst:363-403`, 462-536; the resume-entry block sketch
   in [llvm-internals] §1.3). At `-O0`, `CoroSplitPass(Level != O0)` runs with
   `OptimizeFrame=false` — frame layout is unoptimized but correct ([ldc-codegen] §5).

> [!NOTE]
> This phase costs the least and answers the most. If `CoroSplit` cleanly splits a
> hand-emitted D coroutine and the resulting `.resume`/`.destroy` functions run, then the
> entire premise — "LLVM already does the work; D only needs to emit the intrinsics" — is
> proven before any frontend commitment. It also surfaces the exact pain points (`token`
> handling, the `presplitcoroutine` attribute, the malloc/elide protocol) early.

Cross-link: [ldc-codegen], [d-design].

---

### Phase 1 — ABI choice (decision)

LLVM offers three lowering ABIs (the `.rst` says "two styles" at `Coroutines.rst:47` but
documents three — a doc bug; [llvm-coroutines] §0). The choice is _per construct_, not
global: a general task/await surface, a value-yielding generator, and an
executor-hopping/wasmFX-adjacent async function each want a different ABI. The recommended
default for a general D surface is **switched-resume**, because it is the only ABI whose
handle supports a queryable `resume`/`destroy`/`done`/`promise` without knowing the
implementation, and the only one that supports heap-allocation elision (HALO).

| ABI                      | Signaled by             | Handle / surface                                                                                                                                    | HALO                                                                                                                                            | Best for                                                                                  | Caveat                                                                                                                                                                       |
| ------------------------ | ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Switched-resume**      | `coro.id`               | Opaque coroutine object; `resume`/`destroy`/`done`/`promise` queryable at fixed frame offsets (`Coroutines.rst:64-123`)                             | **Best** — `CoroElide` only works for Switch (resumers-array dependency, `CoroSplit.cpp:1643-1644`)                                             | general task/await; C++20-shaped surface; generators with a persistent handle             | shared resume/destroy → an index in the frame and a `switch` (the "switched" name, `Coroutines.rst:105-109`)                                                                 |
| **Retcon / retcon.once** | `coro.id.retcon[.once]` | Caller-owned fixed-size buffer; each suspend returns yielded values + a continuation fn ptr; no implicit malloc (`Coroutines.rst:128-164`)          | **Weak** — "ineffective at statically eliminating allocations after fully inlining returned-continuation coroutines" (`Coroutines.rst:170-174`) | value-yielding generators (`@nogc`-leaning, caller owns the buffer); no persistent handle | no `coro.promise`, no `coro.alloc`/`coro.free`, no separate `coro.save` (`Coroutines.rst:1883-1886`)                                                                         |
| **Async**                | `coro.id.async`         | Caller-allocated `async context` (a heap-linked list of caller contexts); `musttail` transfer at each suspend; `swiftcc` (`Coroutines.rst:179-256`) | n/a (no `coro.alloc`)                                                                                                                           | executor-hopping; WasmFX-adjacent (tail-call transfer ≈ `cont`/`resume`)                  | Swift-shaped CC (`swiftcc`/`swiftasync`/`swifterror`); "control-flow must be handled explicitly by the frontend" — LLVM gives the split, not the semantics ([comparison] §4) |

**Decision.** Use **switched-resume** as the default for a general task/await surface: it
gives a queryable handle (`resume`/`destroy`/`done`/`promise`), it is the C++20 model
`llvm.coro.*` was designed for ([cpp] §6), and it has the best HALO story — exactly the
property that makes a `@nogc` coroutine reachable (Phase 3). Offer **retcon** as the
generator-specialized ABI where a persistent handle is unnecessary and the caller wants to
own the buffer (no implicit malloc), accepting its weaker post-inline elision. Defer
**async** to the executor-hopping / WasmFX-adjacent track (Phase 6): its `swiftcc`-shaped
calling convention and "you still design the runtime" property ([comparison]: "The
intrinsics save the _split_, not the _semantics_") make it the wrong default for a portable
language feature.

> [!WARNING]
> Async and retcon's calling conventions are taken _verbatim_ from a frontend-supplied
> prototype/CC (`CoroShape.h:211-226` `getResumeFunctionCC`); switched-resume hard-codes
> `CallingConv::C` "so that resume/destroy function pointers stored in the coroutine frame
> are interoperable with other compilers" (`CoroShape.h:213-217`). The C-CC interop of
> switched-resume is another reason to prefer it for a language feature.

Cross-link: [llvm-coroutines], [cpp], [comparison].

---

### Phase 2 — Surface syntax + shared-frontend lowering

This is the long pole and the most consequential design decision. The constraint is the
**shared DMD frontend**: D is one language across three compilers (DMD's own backend, GDC
on GCC, LDC on LLVM), and `async`/`await`/`yield` is a _language_ feature, not an
LDC-specific one. [comparison] makes the case crisply: Rust (MIR), C# (Roslyn), and Kotlin
(CPS) all put coroutine lowering in the frontend and ship to a backend that knows nothing
about coroutines — precisely D's multi-backend situation. Swift is the lone outlier that
lowers via LLVM intrinsics, and it is single-backend.

**Three candidate surfaces** ([d-design] §6), each reusing existing frontend machinery:

- **Proposal A — generator with `yield` → retcon.** A `Generator!T counter(int n)` whose
  body contains `yield i`. The return type is a compiler-known range struct, so it slots
  into the existing range-`foreach` lowering (`statementsem.d:1246-1304`) with zero
  changes. Locals live across a `yield` become frame fields — reuse the `closureVars`
  dataflow.
- **Proposal B — `async`/`await` → async.** `async Task!T fetch(Url u) { auto c =
await connect(u); ... }`. Maps onto the callee-driven `coro.id.async` model and an event
  loop / WasmFX.
- **Proposal C — library-driven, no new keyword.** A `@coroutine` UDA plus a `core.coro`
  intrinsic library (the Phase 0 prototype), matching D's preference for library solutions
  over keywords. Fastest path to a working LDC prototype; no portable fallback for DMD/GDC.

**The recommended lowering — the C++-style body rewrite in the shared frontend, with LDC
glue routing to `llvm.coro.*` (the hybrid).** The single most important spec fragment is
the C++20 compiler-synthesized coroutine body ([cpp] §1.2, `n4775:535-543`):

```cpp
{
  P p promise-constructor-arguments;   // construct promise
  co_await p.initial_suspend();        // initial suspend point
  try { F } catch(...) { p.unhandled_exception(); }
final_suspend:
  co_await p.final_suspend();          // final suspend point
}
```

Do this rewrite — construct promise → `initialSuspend` → try-body → `finalSuspend` — in
the **shared frontend**, so DMD/GDC can emit a portable state-machine fallback (a `switch`
over a resume-index field, generalizing the single-suspend `int`-code dispatch already used
by `foreach`/`opApply` at `statementsem.d:3831`, [d-design] §1.1), while **LDC glue routes
the same rewritten AST to `llvm.coro.*`** and lets `CoroSplit` build the frame. This
mirrors how D already mixes lowering strategies per construct: `foreach`-over-array uses a
portable `_aApplyXX` druntime helper while `foreach`-over-range is a pure AST rewrite
([d-design] §2). LDC already opts out of frontend lowerings where it has a better path —
`new T` → `_d_newclassT` is gated `!IN_LLVM` (`expressionsem.d:5952`) — proving both models
coexist and LDC can choose where a construct is lowered.

**Reuse `closureVars` for cross-suspend capture analysis.** A coroutine frame _is_ a
closure whose lifetime outlives its creating frame. The frontend already computes
`FuncDeclaration.closureVars` ("local variables ... referenced by nested functions ...
put into the 'closure'", `func.d:309`) and `needsClosure` (`funcsem.d:3264`). The locals
live across a `yield`/`await` are exactly the ones `closureVars` identifies — the analysis
the portable fallback needs is already in the tree. (For the LLVM path, `CoroSplit` recomputes
suspend-crossing liveness itself via `SuspendCrossingInfo`, [llvm-internals] §2.2, so LDC
only needs the capture set for the portable fallback and for attribute checking.)

**Concrete LDC glue insertion points** ([ldc-codegen] §1.4). `DtoDefineFunction`
(`gen/functions.cpp:966`) is the natural home, structurally identical to the existing
`va_start`/`va_end` prologue/epilogue + cleanup pattern (`gen/functions.cpp:1259-1282`):
emit `coro.id` + `coro.begin` after the nested-context setup (`:1250`), `coro.suspend` at
each yield/await statement in `statements.cpp`/`toir.cpp`, and `coro.end` in the
implicit-return / cleanup epilogue (`:1290-1323`) via the same `pushCleanup` mechanism. The
`callOrInvoke` path (`gen/funcgenstate.cpp:106`) already turns `[Throws]` intrinsics like
`coro.resume`/`coro.destroy` into `invoke`s inside try/catch scopes — useful for Phase 4.

Cross-link: [d-design], [comparison], [cpp].

---

### Phase 3 — Memory + attributes

A coroutine frame that is GC-heap-allocated by default will break `@nogc` and `-betterC`.
The frontend already has the exact check that predicts this, because the frame is a closure
that always escapes ([d-design] §3, `semantic3.d:1850` `checkClosure`): a `@nogc` function
that needs a closure is a _hard error_ — "is `@nogc` yet allocates closure for `...()` with
the GC" — routed through the single `setGC` chokepoint (`nogc.d:96/326`). A default
`_d_allocmemory` frame (the same call closures use, `gen/nested.cpp:494`) would trip this
identically.

**The frame allocator hook.** Mirror the closure allocator: add
`_d_coro_alloc(size_t) -> void*` and `_d_coro_free(void*)` as two `createFwdDecl(LINK::c,
...)` lines in `buildRuntimeModule()` (the pattern `gen/runtime.cpp:599-600` uses for
`_d_allocmemory`) and call `getRuntimeFunction(loc, module, "_d_coro_alloc")` at the
coroutine prologue. The frame size comes from `llvm.coro.size.i64` and alignment from
`llvm.coro.align.i64`; the wiring is
`coro.id → coro.size → coro.alloc(branch) → _d_coro_alloc → coro.begin`, with
`coro.free → _d_coro_free` on cleanup ([ldc-codegen] §4). Routing through the GC
(`_d_allocmemory`) is the simplest correct default; a custom allocator is the `@nogc`
escape hatch.

**The `@nogc`/`@safe`/`nothrow` story.** Four grounded routes to a `@nogc` coroutine, in
preference order:

1. **HALO / stack elision (best, free).** Emit the full alloc/free intrinsic protocol —
   _not_ a hard `malloc` — so `CoroElide` can place the frame as a stack `alloca` in the
   caller and devirtualize `resume`/`destroy` (`Coroutines.rst:405-460`, 2216-2224; [cpp]
   §3). This is "common for coroutines implementing RAII idiom" — created, used, and
   destroyed by the same calling function (`Coroutines.rst:408-413`). **Prerequisite: the
   ramp must be inlined into the caller** (`Coroutines.rst:2287-2289`). When elision fires,
   `coro.alloc` returns `false` and no GC call is emitted — the `@nogc` check never trips.
2. **Custom allocator.** Route the frame through a user-supplied allocator so the `@nogc`
   function never touches the GC, mirroring the DIP1008 precedent ("separate allocator is
   called for this, not the GC", `nogc.d:187-188`).
3. **`scope` frame.** A non-escaping coroutine whose frame provably does not outlive the
   caller could be `alloca`'d (the non-escaping-nested-function path,
   `gen/nested.cpp:510-511`) — but only valid when the compiler proves the coroutine is
   fully consumed in-scope (precisely the `CoroElide` condition). The `lazy ⇒ scope`
   precedent (`expressionsem.d:3629-3648`) and the DIP1000 closure-elision in `applyOpApply`
   (`statementsem.d:3844`) are the patterns to copy.
4. **Escape analysis across suspends.** `@safe` has the same tension as the DIP1000
   closure-for-safety pattern: the compiler may _force_ a heap frame to keep a captured
   `ref`/`scope` from dangling, trading `@nogc` for `@safe`. Escape analysis
   (`escape.d`, `checkParamArgumentEscape` at `expressionsem.d:3641`) must prove the frame
   and its captures don't dangle across a suspend.

**Exception-free customization points → `Expected!(T,E)`.** N4134 deliberately made
coroutines usable "in environments where exception are forbidden" (`n4134:131`): a
`get_return_object_on_allocation_failure` nothrow alloc-failure path, an `await_suspend`
returning `bool false` to abort a launch, and a generalized `set_exception(E)` over
arbitrary error types ([cpp] §5.5). These map cleanly onto D's `@nogc nothrow` +
`Expected!(T,E)` idiom: a D promise can avoid GC/exceptions and report failures via
`Expected`, with the `bool`-returning `coro.await.suspend.bool` variant (`Coroutines.rst:2039-2040`)
modeling the abort-without-suspending path.

> [!WARNING]
> LDC's own `GarbageCollect2Stack` pass promotes `_d_allocmemory` calls to stack allocas
> and runs at the `OptimizerLast` extension point (`optimizer.cpp:508`), while `CoroSplit`
> runs in the CGSCC inliner pipeline. If a coroutine frame is GC-allocated via
> `_d_allocmemory`, the ordering of `GarbageCollect2Stack` vs `CoroSplit` is unvalidated
> and could interact badly ([ldc-codegen] §5.1). Use a dedicated `_d_coro_alloc` symbol the
> GC2Stack pass does not recognize, and validate the ordering.

Cross-link: [attributes].

---

### Phase 4 — Exception handling

**No-EH ABI first.** The realistic first target — especially for wasm, `-betterC`, and
`@nogc` — is a coroutine lowering with no D exception handling across suspends. The
`coro.resume`/`coro.destroy` intrinsics are typed `[Throws]` (`Intrinsics.td:1941-1942`),
and the lowering's cleanup machinery is unwind-aware, but a no-EH shape sidesteps all of
it: the switched-resume ABI without unwind `coro.end`, or `retcon.once` for a single-suspend
generator. On LDC-wasm exceptions are stubbed entirely — `rt/wasi_exceptions.d:3` aborts in
`_d_throw_exception` and returns `_URC_NO_REASON` from `_d_eh_personality` — so no-EH is
the _only_ coherent first target there ([wasm] §1.3).

**Full D-EH-across-suspend later.** When a D exception must propagate across a suspend
point, the lowering must integrate with the platform EH model. `coro.end(handle, true,
none)` marks the unwind path; the frontend pairs it with `coro.is_in_ramp`
(`Coroutines.rst:1546-1569`, [llvm-coroutines] §8) to branch between ramp-only cleanup and
`eh.resume` for landingpad EH, or attaches a `"funclet"` bundle to a `cleanuppad` for WinEH
(`Coroutines.rst:1571-1583`). The `coro.end` handling table:

```text
                       | In Start Function       | In Resume/Destroy Functions
unwind=false           | nothing                 | ret void
unwind=true  WinEH     | mark coroutine as done  | cleanupret unwind to caller; mark done
unwind=true  Landingpad| mark coroutine as done  | mark coroutine done
```

LDC's `callOrInvoke` already turns `[Throws]` coro intrinsics into `invoke`s inside
try/catch scopes ([ldc-codegen]), so the glue is partly in place. **Wasm EH must be wired
into druntime first** — the abort-stub `rt/wasi_exceptions.d` has to become a real wasm-EH
personality before any EH-across-suspend works on that target ([wasm] §1.3). On wasm,
WasmFX's `resume_throw`/`resume_throw_ref` (`Explainer.md:583-611`) is the eventual native
analogue of unwinding a frame on destroy, but it too requires wasm EH in druntime first.

> [!NOTE]
> Note the cross-cutting `.rst` caveat for EH on the suspend path: when `coro.suspend`
> returns -1 the coroutine may already be destroyed and its frame freed, so "We cannot
> access anything on the frame on the suspend path" — LICM was disabled for loops with
> `coro.suspend` to avoid use-after-free, and "the general problem still exists"
> (`Coroutines.rst:2275-2281`).

Cross-link: [attributes], [wasm].

---

### Phase 5 — WebAssembly

**This ships essentially for free once Phases 0-2 emit the intrinsics.** The coro passes
run in the middle-end CGSCC pipeline before WebAssembly ISel
(`PassBuilderPipelines.cpp:480`), and by the time the WebAssembly backend runs, every
`llvm.coro.*` has already been replaced with branches, allocas/heap calls, GEP+load/store,
and indirect calls — plain IR ([wasm] §2.3). The WebAssembly backend has no coroutine
support to require: `IntrinsicsWebAssembly.td` (full read) defines only
memory/ref/table/EH/SIMD/atomic intrinsics, and a `grep` of `lib/Target/WebAssembly` for
stack-switching returns 0 ([wasm] §2.4). So a D stackless coroutine lowers to a state
machine + frame struct and runs on **any wasm 1.0 engine** with zero engine support. This is
the decisive contrast with `core.thread.Fiber`, which `assert(0)`s on WASI because it needs
a native addressable machine stack ([d-fiber] §7).

**Tasks for a coroutine-driven event loop on wasm.** The wasm port already works for
betterC + templated Phobos (`tests/baremetal/wasm2.d`), struct passing (BasicCABI,
`gen/abi/wasm.cpp:42-66`), and internal-LLD linking. What's missing for a _coroutine-driven
event loop_ is the async-I/O syscall surface: `core/sys/wasi/core.d` exposes only
random/clock (`:12-31`), no fd/socket/poll bindings. Add WASI `poll_oneoff` / fd bindings so
suspended coroutines can be parked on I/O readiness and resumed from completions ([wasm]
§4) — the same park/resume pattern the async-io survey describes ([effects and event
loops][effects-event-loops], [D landscape][d-landscape]). Keep the first wasm target no-EH
(Phase 4).

> [!NOTE]
> A parallel DMD-side path exists: the `feat/wasm` branch builds a native wasm core-module
> emitter inside DMD (`compiler/src/dmd/wasm/`), but it has _no_ coroutine or
> stack-switching opcodes yet ([d-design] §5). That is where WasmFX opcodes would eventually
> live on the DMD-direct path; it does not affect the LDC→LLVM→wasm stackless path, which
> needs nothing wasm-specific.

Cross-link: [wasm].

---

### Phase 6 — WasmFX (future, complementary)

WasmFX (the standards-track stack-switching proposal, [wasmfx]) adds one reference type
`cont $ft` and seven instructions (`cont.new`, `cont.bind`, `suspend`, `resume`,
`resume_throw`, `resume_throw_ref`, `switch`; opcodes `0xe0`-`0xe6`,
`Explainer.md:1185-1195`). It is **not a prerequisite** for D coroutines on wasm and **not
how `async`/`await` should be implemented** — that is Phase 5's stackless state machine.
WasmFX is the substrate for the workloads stackless lowering handles poorly: **stackful
fibers** (`core.thread.Fiber`, which cannot be `CoroSplit` because its suspension points are
not statically known) and **scheduler-heavy green threads** where engine-managed stacks +
symmetric `switch` beat materialized frame structs ([wasm] §3, [comparison] §5: Go is the
stackful analogue).

**How D would lower onto WasmFX** ([wasm] §3, Strategy 3):

- A **D stackful fiber** maps most naturally: `Fiber.call` → `cont.new` + `resume`,
  `Fiber.yield` → `suspend`, the scheduler loop → `switch`. The WasmFX `scheduler1`/`lwt`
  examples (`Explainer.md:280-490`) are exactly a green-thread runtime.
- A **D stackless coroutine** could _optionally_ map its `suspend` to a wasm `suspend $tag`
  and let the engine hold the suspended state instead of materializing a frame struct —
  trading compiler-managed frames for engine-managed stacks.

**Why it is a separate track.** Both require LLVM's WebAssembly backend to grow a lowering
of stack-switching (which does _not_ exist — [wasm] §2.4) **and** engines to ship the
Phase-3 feature (coverage uneven, [wasmfx]). Until then, Asyncify/JSPI is the stopgap for
code that can be neither `CoroSplit` nor run on a WasmFX engine, at the documented
~2x-code-size / debuggability cost ([wasm] §3, Strategy 2). Critically, the layers _stack
cleanly_: ship Phase 5 now, add a WasmFX path later as a glue/backend swap, without
re-architecting the stackless path ([wasm] §5).

Cross-link: [wasm], [wasmfx].

---

## Consolidated risks

| #   | Risk                                                                                                                       | Source / evidence                                                                                                                                                                                                                                  | Mitigation                                                                                                                                                                           |
| --- | -------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| R1  | **LLVM IR version-instability** — the coro contract can shift between LLVM releases                                        | "Compatibility across LLVM releases is not guaranteed." (`Coroutines.rst:9-10`)                                                                                                                                                                    | Pin to LDC's linked LLVM (23.0.0git); gate emission behind an LLVM-version check; re-validate intrinsic signatures on every bump                                                     |
| R2  | **The `token` type has no D representation** — `coro.id`/`coro.save` results, `coro.end`/`coro.suspend` operands           | [ldc-codegen] §2.1, §2.2                                                                                                                                                                                                                           | Use `pragma(LDC_inline_ir)` for the token-typed sequence, or a small frontend special-case; glue-emit via `GET_INTRINSIC_DECL` ([ldc-codegen] appendix)                              |
| R3  | **Custom ABIs require C++ `CoroSplit` registration not reachable via IR/LLVM-C**                                           | "Custom ABIs are a _C++ API_ on the `CoroSplitPass` constructor + `coro::SwitchABI`/`coro::Shape`" ([llvm-coroutines] §6, `CoroSplit.cpp:2141-2207`); `presplitcoroutine_custom_abi` is _not_ an `EnumAttr` in `Attributes.td` (grep found no def) | Live within the stock Switch/retcon/async ABIs driven purely from IR; only register a custom ABI from C++ glue if a new lowering is unavoidable (likely Phase 6)                     |
| R4  | **`GarbageCollect2Stack` ordering vs `CoroSplit`** — GC2Stack could try to stack-promote a GC-allocated frame              | [ldc-codegen] §5.1; GC2Stack at `optimizer.cpp:508` (OptimizerLast), `CoroSplit` in CGSCC                                                                                                                                                          | Use a dedicated `_d_coro_alloc` symbol GC2Stack does not recognize; prefer HALO (no GC call at all); validate ordering with a test                                                   |
| R5  | **EH on wasm is stubbed** — `coro.resume`/`destroy` are `[Throws]` but wasm EH aborts                                      | `rt/wasi_exceptions.d:3-20`, `Intrinsics.td:1941-1942` ([wasm] §1.3)                                                                                                                                                                               | No-EH ABI first (Phase 4); wire wasm EH into druntime before EH-across-suspend                                                                                                       |
| R6  | **Multi-backend parity (DMD/GDC vs LDC)** — LLVM-intrinsic lowering is LDC-only; GDC/DMD have no coro intrinsics           | [comparison] §design lessons; LDC `gen/` and DMD frontend both greenfield                                                                                                                                                                          | Do the surface + capture analysis + body rewrite in the _shared frontend_; portable state-machine fallback for DMD/GDC; LDC glue routes to `llvm.coro.*` (the Phase 2 hybrid)        |
| R7  | **LICM disabled on `coro.suspend`** and other ".rst areas requiring attention" — frame may be freed on the -1 suspend path | `Coroutines.rst:2275-2281` (LICM); 2294 (`inalloca` unsupported); 2296 (alignment ignored by `coro.begin`/`coro.free`); 2298-2299 (LTO) ([llvm-coroutines] §9)                                                                                     | Accept the known limitations; avoid `inalloca` params; don't rely on `coro.begin` alignment (round up manually as `gen/nested.cpp` does for closures); validate under LTO separately |
| R8  | **Weak HALO for retcon** — "ineffective at statically eliminating allocations after fully inlining"                        | `Coroutines.rst:170-174`                                                                                                                                                                                                                           | Use switched-resume where elision matters; reserve retcon for caller-owns-buffer generators where the caller already controls allocation                                             |
| R9  | **Token-spill is a fatal error** and other frontend constraints                                                            | tokens may not cross a suspend (`SpillUtils.cpp:513-515`); one final suspend / one fallthrough `coro.end` (`CoroEarly.cpp:128-141`); non-static allocas rejected (`CoroFrame.cpp:187-189`) ([llvm-internals] §8)                                   | Ensure the lowering never lets a token live across a suspend; emit exactly one `coro.id`/`coro.begin`/final-suspend                                                                  |
| R10 | **Debug-info frame construction is C++-gated** — a D source language gets no `__coro_frame` DI                             | `CoroFrame.cpp:628-635` ([llvm-internals] §8)                                                                                                                                                                                                      | Accept missing frame DI initially, or relax the language guard upstream                                                                                                              |

---

## Open questions

Gathered across the nine digests; each preserves the original honest flag.

- **`presplitcoroutine_custom_abi` registration.** It is not an `EnumAttr` in
  `Attributes.td` (grep found no def); how is it spelled/registered in LLVM 23 source, and
  can LDC register a custom `CoroSplit` ABI generator at all from its pass-pipeline
  construction? ([llvm-coroutines] §6, [llvm-internals] §6.3.)
- **Undocumented intrinsic semantics.** `coro.alloca.{alloc,get,free}`,
  `coro.async.{context.alloc,context.dealloc,resume,size.replace}`, `coro.subfn.addr`, and
  `coro.prepare.retcon` have _no_ `.rst` section — their contract lives only in `.td` +
  source and must be re-verified before use ([llvm-coroutines] §2C).
- **Whether LDC can register custom `CoroSplit` ABIs.** The plugin mechanism is a C++ API
  on the `CoroSplitPass` ctor ([llvm-internals] §6.3); confirm LDC's pass-pipeline path can
  pass a `GenCustomABIs` vector without forking the standard builders.
- **Wasm async/`musttail` lowering status.** Does LLVM's WebAssembly backend support the
  `musttail` symmetric-transfer calls (`return_call`) that switched-resume
  `coro.await.suspend.handle` and async ABIs rely on? `TTI.supportsTailCallFor`
  (`CoroSplit.cpp:1020-1036`) is the knob; status on wasm is unverified ([comparison]
  marked-uncertain, [llvm-internals] §8).
- **Swift task-allocator symbol names.** `swift_task_alloc`/`swift_task_dealloc` are
  recalled from memory; the per-task bump-allocator _mechanism_ is reliable but the exact
  symbols/signatures are unverified — relevant only if the async ABI is pursued (Phase 6)
  ([comparison] marked-uncertain items).
- **Where to lower: shared frontend vs LDC glue.** The hybrid (frontend body-rewrite +
  capture analysis, LDC glue → intrinsics) is recommended, but the exact split — how much
  state-machine the portable fallback materializes vs. how much LDC delegates to `CoroSplit`
  — is an open design point ([d-design] §2, [comparison] §recommendation).
- **The self-reference / `Pin` policy for D.** A coroutine frame can be self-referential
  (a `&local` held across a suspend). Rust solves this with `Pin`/`Unpin` in the type
  system ([comparison] §1); C#/Kotlin/Swift rely on GC/heap-stable frames. D must choose a
  policy — a `Pin`-like wrapper, restricting `ref`/`scope` captures across a suspend, or
  copying — and it interacts with `@safe`/`scope`/dip1000 escape analysis ([d-design] §3,
  [comparison] §design lessons).
- **Whether to capture P0981 (HALO) / P0913 (symmetric transfer) prose.** Both exist only
  as open-std HTML, no PDF; the LLVM CoroElide source and the Nishanov 2016 slides cover the
  same ground ([papers-fetch] open questions).

---

## Decision matrix / recommendation

The lowest-risk path, in one line:

> **Phase 0 prototype → switched-resume → hybrid frontend lowering → `@nogc` via
> allocator + HALO → no-EH-first → wasm-for-free → WasmFX later.**

| Decision                  | Choice                                                                                                                         | Why (grounded)                                                                                                                                                                                 |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Prove the premise first   | Phase 0 library prototype via `pragma(LDC_intrinsic)` + `pragma(LDC_inline_ir)`                                                | Zero compiler change; `CoroConditionalWrapper` self-activates `CoroSplit` (`CoroConditionalWrapper.cpp:18-23`); de-risks everything downstream                                                 |
| Default ABI               | **Switched-resume**                                                                                                            | Only ABI with a queryable `resume`/`destroy`/`done`/`promise` handle and working HALO (`CoroSplit.cpp:1643-1644`); C-CC interop; the C++20 model `llvm.coro.*` was built for ([cpp] §6)        |
| Generator-specialized ABI | **Retcon** (where no persistent handle is needed)                                                                              | Caller-owned buffer, no implicit malloc (`Coroutines.rst:157-164`); accept weaker post-inline elision                                                                                          |
| Where to lower            | **Shared frontend** body rewrite + capture analysis; **LDC glue** → `llvm.coro.*`; portable state-machine fallback for DMD/GDC | Multi-backend parity (R6); mirrors Rust/C#/Kotlin frontend lowering ([comparison]) and D's own per-construct mix ([d-design] §2)                                                               |
| Capture analysis          | Reuse `closureVars`/`needsClosure`                                                                                             | A coroutine frame is an always-escaping closure; the frontend already computes exactly the cross-suspend live set (`func.d:309`, `funcsem.d:3264`)                                             |
| `@nogc` story             | **HALO first, custom allocator second** (`_d_coro_alloc`/`_d_coro_free`)                                                       | HALO emits no GC call when the frame is caller-bounded (`Coroutines.rst:405-460`); custom allocator is the explicit `@nogc` escape; default GC frame trips `checkClosure` (`semantic3.d:1850`) |
| Error model               | Exception-free customization points → `Expected!(T,E)`                                                                         | N4134's no-EH design (`n4134:131`) maps onto D's `@nogc nothrow` + `Expected` ([cpp] §5.5)                                                                                                     |
| EH                        | **No-EH ABI first**, full D-EH-across-suspend later                                                                            | wasm EH is stubbed (`rt/wasi_exceptions.d:3`); no-EH is the only coherent first wasm/betterC target                                                                                            |
| Wasm                      | **Stackless state machine, ships ~for free**                                                                                   | Coro passes run pre-ISel (`PassBuilderPipelines.cpp:480`); WebAssembly backend needs nothing (`IntrinsicsWebAssembly.td` full)                                                                 |
| WasmFX                    | **Future, complementary track** for stackful fibers / green threads                                                            | Needs LLVM wasm-backend stack-switching (absent, [wasm] §2.4) + engine support; NOT how `async`/`await` is built                                                                               |

The defining property of this plan is that the riskiest, most expensive work (the shared
frontend) is gated behind a cheap proof (Phase 0) that the LLVM half already works, and the
highest-uncertainty target (WasmFX) is explicitly _not_ on the critical path — the wasm
payoff arrives with Phase 5 at no extra engine cost. For the broader survey context — what
this replaces (D's stackful fibers), what model it adopts (the C++20 promise/awaiter shape),
and how it compares across languages — see the [index][index], [concepts][concepts], and the
[comparison][comparison] chapter.

---

## Sources

Primary artifacts synthesized for this roadmap (all paths are local to this machine):

- **LLVM 23.0.0git** (`$REPOS/llvm-project`):
  `llvm/docs/Coroutines.rst`, `llvm/include/llvm/IR/Intrinsics.td`,
  `llvm/include/llvm/IR/Attributes.td`, `llvm/include/llvm/IR/IntrinsicsWebAssembly.td`,
  `llvm/lib/Transforms/Coroutines/{CoroSplit,CoroFrame,CoroEarly,CoroCleanup,CoroElide,CoroAnnotationElide,CoroConditionalWrapper}.cpp`,
  `llvm/include/llvm/Transforms/Coroutines/{ABI,CoroShape,CoroInstr}.h`,
  `llvm/lib/Passes/PassBuilderPipelines.cpp`, `llvm/docs/LangRef.rst`.
- **LDC v1.42** (`$REPOS/dlang/ldc`):
  `gen/{functions,statements,toir,nested,pragma,inlineir,runtime,optimizer,tocall,llvmhelpers}.cpp`,
  `gen/abi/{abi,wasm}.cpp`, `gen/{irstate,funcgenstate}.h`,
  `runtime/druntime/src/ldc/intrinsics.di`,
  `runtime/druntime/src/core/thread/fiber/{base,package}.d`,
  `runtime/druntime/src/core/thread/context.d`, `rt/wasi_exceptions.d`,
  `core/sys/wasi/{core,package}.d`, `driver/{main,targetmachine}.cpp`,
  `tests/{codegen,baremetal}/wasm*.d`.
- **Shared DMD frontend** (`$REPOS/dlang/ldc/dmd`,
  `$REPOS/dlang/dmd/compiler/src/dmd`):
  `statementsem.d`, `expressionsem.d`, `func.d`, `funcsem.d`, `semantic3.d`, `nogc.d`,
  `clone.d`, `target.d`, `compiler/src/dmd/wasm/`.
- **Phobos** (`$REPOS/dlang/phobos`): `std/concurrency.d` (`Generator`).
- **C++ coroutine papers** (`$REPOS/papers/`): N3722, N3858, N4134
  (Nishanov — the stackless pivot), N4680, N4775 (Coroutines TS), P1745, P0057R8 (C++20
  wording), `llvm-coroutines-nishanov-devmtg-2016.pdf` (LLVM coroutine design slides),
  `wasmfx-continuing-webassembly-effect-handlers-2023.pdf` (the WasmFX paper). P0981 (HALO)
  and P0913 (symmetric transfer) are HTML-only:
  `https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2018/p0981r0.html`,
  `https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2018/p0913r1.html`.
- **WasmFX** (`$REPOS/wasm/stack-switching`):
  `proposals/stack-switching/Explainer.md` and the `examples/*.wast` encodings, plus the
  in-tree deep-dive [wasmfx][wasmfx].

<!-- References -->

[index]: ./index.md
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
[wasmfx]: ../algebraic-effects/wasmfx.md
[effects-event-loops]: ../async-io/effects-and-event-loops.md
[d-landscape]: ../async-io/d-landscape.md
