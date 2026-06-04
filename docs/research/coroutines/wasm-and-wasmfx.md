# Compiling D Stackless Coroutines to WebAssembly (and where WasmFX fits)

This is the WebAssembly leaf of the _Stackless Coroutines for LDC_ survey. It establishes the central, evidence-backed claim that LLVM's coroutine lowering is a **middle-end IR transform** that finishes before any backend runs, so a D stackless coroutine compiles to ordinary wasm 1.0 with **zero engine support** — the WebAssembly backend never sees a `llvm.coro.*` intrinsic, let alone a stack-switch instruction. It then surveys the three strategies for giving D suspension semantics on wasm (LLVM `Coro*` → state machine; Binaryen Asyncify / Emscripten JSPI; and WasmFX stack-switching), frames LLVM stackless lowering and WasmFX as **orthogonal, composable** layers, and gauges LDC's current wasm maturity and the concrete gaps. For the standards-track stack-switching mechanism itself — its continuation type, seven instructions, and effect-handler grounding — this doc defers to the survey's WasmFX deep-dive ([wasmfx]) rather than re-deriving it.

**Last reviewed:** June 4, 2026

---

## Where this sits

The other survey docs explain _what_ a stackless coroutine is ([concepts]), how LLVM lowers one ([llvm-coroutines], [llvm-internals]), and what LDC would have to emit to drive that lowering ([ldc-codegen]). This doc answers a narrower, load-bearing question for the "port D to wasm + support WasmFX" goal: **does targeting WebAssembly change any of that, and does WasmFX make it easier or harder?** The short answers are _no_ and _complementary, not required_. The longer answers, grounded in LLVM 23.0.0git, LDC v1.42, and the stack-switching spec, follow.

> [!NOTE]
> Two distinct "stackless vs stackful" axes appear in this survey and must not be
> conflated. (1) A _D coroutine_ is stackless when its suspendable state is a
> compiler-materialized **frame struct** rather than a real OS/segmented stack —
> this is what `CoroSplit` produces (see [concepts], [d-fiber]). (2) A _wasm
> suspension mechanism_ is stackful when the unit of suspension is an entire call
> stack (Asyncify, JSPI, WasmFX continuations) versus per-coroutine (LLVM Coro).
> The two axes interact in the strategy table below.

---

## 1. LDC's WebAssembly target maturity

LDC already targets WebAssembly, but only for the betterC-shaped subset of D. The plumbing is real; the runtime surface is thin.

### 1.1 Triples and predefined versions

LDC predefines D `version` identifiers per OS in `driver/main.cpp`. The four WASI triples collapse to the same two idents:

```cpp
// driver/main.cpp:908-914
  case llvm::Triple::WASI:
  case llvm::Triple::WASIp1:
  case llvm::Triple::WASIp2:
  case llvm::Triple::WASIp3:
    VersionCondition::addPredefinedGlobalIdent("WASI");
    VersionCondition::addPredefinedGlobalIdent("CRuntime_WASI");
    break;
```

Emscripten is treated as a musl-Linux-flavoured POSIX target — it predefines `Emscripten`, `linux`, `Posix`, `CRuntime_Musl`, `CppRuntime_LLVM` (`driver/main.cpp:915-923`), with the comment `// Emscripten uses musl and libc++, so mimic a musl Linux platform`. The DMD frontend mirrors the WASI C-runtime mapping (`dmd/target.d:273`, `dmd/target.d:1503`). The codegen tests (`tests/codegen/wasm_wasip1.d`, `wasm_wasip2.d`, `wasm_emscripten.d`) only assert the predefined `version` ident and the LLVM `target datalayout` string — they exercise no functional codegen.

### 1.2 The wasm BasicCABI ABI

`gen/abi/wasm.cpp` implements the struct/array-passing rules from the wasm tool-conventions BasicCABI document, cited in the header:

```cpp
// gen/abi/wasm.cpp:10
// see https://github.com/WebAssembly/tool-conventions/blob/main/BasicCABI.md
```

`WasmTargetABI::passByVal` returns true for in-memory POD aggregates that are _not_ a single-scalar wrapper (`gen/abi/wasm.cpp:60-62`); `isDirectlyPassedAggregate` passes a POD struct/static-array directly iff it wraps a single scalar type, size ≤ 16, and is not over-aligned (`gen/abi/wasm.cpp:43-58`). This matters for coroutines because the **coroutine frame struct** that `CoroFrame` materializes (§2.2) is exactly the kind of aggregate this ABI governs once it is passed by pointer to the resume/destroy functions — i.e. nothing special is needed; the frame is an ordinary struct under an ordinary ABI.

`real` / `long double` maps to `fp128` on wasm (`gen/target.cpp:90-92`):

```cpp
// gen/target.cpp:90-92
  case Triple::wasm32:
  case Triple::wasm64:
    return LLType::getFP128Ty(ctx);
```

The Component Model targets force position-independent code: `driver/targetmachine.cpp:563-565` sets `relocModel = llvm::Reloc::PIC_` for `WASIp2`/`WASIp3`.

### 1.3 Exceptions are stubbed out

D exceptions are **not** implemented on wasm. `rt/wasi_exceptions.d` aborts on throw and resume:

```d
// rt/wasi_exceptions.d:3-20
// Exception handling is currently stubbed out for WebAssembly/WASI.

extern(C) void _d_throw_exception(Throwable o)
{
    import core.stdc.stdlib : abort;
    abort();
}

extern(C) int _d_eh_personality(int version_, ...)
{
    return 0; // _URC_NO_REASON
}

extern(C) void _Unwind_Resume(void* exception_object)
{
    import core.stdc.stdlib : abort;
    abort();
}
```

This is the most consequential gap for the coroutine port, because LLVM's `coro.resume` / `coro.destroy` intrinsics are typed `[Throws]` and the coroutine cleanup machinery is unwind-aware (see [attributes] and §3.1 below). A no-EH / betterC-style coroutine ABI is what is realistic on LDC-wasm _today_; full D-exception interop across suspend points needs the wasm exception-handling proposal wired into druntime first.

### 1.4 Minimal WASI runtime surface

`core/sys/wasi/` is thin. `core/sys/wasi/package.d:12` is just `public import core.sys.wasi.core;`. `core/sys/wasi/core.d` declares only three preview-1 syscalls behind `version (WASI): extern (C): @nogc: nothrow:` (`core.d:12-31`):

```d
// core/sys/wasi/core.d:19-26
/// Fills a buffer with high-quality random data.
__wasi_errno_t __wasi_random_get(void* buf, size_t buf_len);

/// Returns the resolution of a clock.
__wasi_errno_t __wasi_clock_res_get(uint id, ulong* resolution);

/// Returns the time value of a clock.
__wasi_errno_t __wasi_clock_time_get(uint id, ulong precision, ulong* time);
```

There are **no fd/socket/poll bindings** — no `poll_oneoff`, no async I/O syscall surface. If D coroutines are meant to drive an event loop on WASI (the connection to the [async-io-index] survey), that surface has to be added first. See [effects-event-loops] for how completions resume suspended computations once such a surface exists.

### 1.5 Bare-metal / freestanding wasm works

`tests/baremetal/wasm.d` compiles and links to wasm with the internal LLD (`-mtriple=wasm32-unknown-unknown-wasm -link-internally`), exporting `_start` and `add` as `extern(C)`. `tests/baremetal/wasm2.d` goes further: `-betterC` plus templated Phobos range pipelines (`iota().stride(2).take(5).sum()`) that link into a `.wasm` whose exported symbol is verified. So **betterC + templated Phobos → plain wasm works today; GC, EH, threads, and full druntime do not.**

### 1.6 Maturity summary

> [!IMPORTANT]
> **Works today** (wasm 1.0, no engine extensions):
>
> - triple/version plumbing for `wasip1`/`wasip2`/`wasip3`/`emscripten`;
> - the BasicCABI struct/array passing (`gen/abi/wasm.cpp`);
> - betterC codegen including templated Phobos pipelines;
> - internal-LLD linking to `.wasm`; PIC defaults for the Component Model.
>
> **Stubbed or missing:**
>
> - exceptions (`rt/wasi_exceptions.d` → `abort()`);
> - GC, threads, broad WASI/libc surface;
> - async-I/O syscalls (only random + clock exposed);
> - **no coroutine-specific codegen in LDC at all** (no `llvm.coro.*` emitted — §4).

The takeaway for the roadmap ([roadmap]): the wasm target is a _betterC_ target. A first D-coroutine-on-wasm milestone should aim at the no-EH, no-GC subset, which aligns with both the wasm maturity ceiling above and the `@nogc` / `@safe` posture analyzed in [attributes].

---

## 2. The central claim: LLVM coroutines compile to ordinary wasm — no engine feature needed

This is the load-bearing result of the doc. **The generic `Coro*` passes run at the LLVM-IR level inside the optimization (CGSCC) pipeline, _before_ WebAssembly instruction selection, and lower a coroutine to an ordinary state machine plus a heap/stack frame struct.** The WebAssembly backend then compiles that residual IR like any other function. No `cont.new`/`suspend`/`resume`, no stack-switching, no wasm engine support is involved at any point.

### 2.1 The Coro intrinsics and passes are target-independent

The coroutine intrinsics live in the **generic** `llvm/include/llvm/IR/Intrinsics.td` (the `int_coro_*` family, 38 definitions starting at `Intrinsics.td:1875`), not in any target file. The passes live in `llvm/lib/Transforms/Coroutines/` — `CoroEarly.cpp`, `CoroSplit.cpp`, `CoroCleanup.cpp`, `CoroElide.cpp`, `CoroFrame.cpp`, `SuspendCrossingInfo.cpp`, `SpillUtils.cpp`, `Coroutines.cpp`. These are middle-end transforms; see [llvm-coroutines] for the intrinsic catalogue and [llvm-internals] for the pass internals. The crucial point here is purely about _location_: none of this is under `llvm/lib/Target/`.

### 2.2 `CoroSplit` literally builds a state machine + frame struct

`CoroSplit.cpp` says so in its filename and header:

```text
// CoroSplit.cpp:1-19
//===- CoroSplit.cpp - Converts a coroutine into a state machine ----------===//
// ...
// This pass builds the coroutine frame and outlines resume and destroy parts
// of the coroutine into separate functions.
//
// We present a coroutine to an LLVM as an ordinary function with suspension
// points marked up with intrinsics. We let the optimizer party on the coroutine
// as a single function for as long as possible. Shortly before the coroutine is
// eligible to be inlined into its callers, we split up the coroutine into parts
// corresponding to an initial, resume and destroy invocations of the coroutine,
// add them to the current SCC and restart the IPO pipeline...
```

`CoroFrame.cpp` describes the frame struct construction, which is exactly what a hand-written stackless coroutine does — but compiler-generated:

```text
// CoroFrame.cpp:8-15
// This file contains classes used to discover if for a particular value
// its definition precedes and its uses follow a suspend block. This is
// referred to as a suspend crossing value.
//
// Using the information discovered we form a Coroutine Frame structure to
// contain those values. All uses of those values are replaced with appropriate
// GEP + load from the coroutine frame. At the point of the definition we spill
// the value into the coroutine frame.
```

So suspend-crossing live values are _spilled into an ordinary struct_ (the coro frame) reached by GEP+load — the materialized "stack" of a stackless coroutine. The lowering ABI is one of four, all of which produce ordinary functions plus a frame and none of which emit a target stack-switch instruction (`CoroShape.h:26-49`):

```cpp
// CoroShape.h:26-49
enum class ABI {
  /// The "resume-switch" lowering, where there are separate resume and
  /// destroy functions that are shared between all suspend points...
  Switch,
  /// The "returned-continuation" lowering, where each suspend point creates a
  /// single continuation function...
  Retcon,
  /// The "unique returned-continuation" lowering... known to
  /// suspend at most once during its execution, and the return value of
  /// the continuation is void.
  RetconOnce,
  /// The "async continuation" lowering...
  Async,
};
```

`Switch` is the C++20 / clang default (and the natural choice for a multi-suspend D generator); `RetconOnce` is the single-suspend, void-return shape that maps well to a no-EH wasm target. The ABI choice is analyzed for the D case in [ldc-codegen] and [comparison].

### 2.3 The Coro passes sit in the CGSCC/IR pipeline, before any backend

`llvm/lib/Passes/PassBuilderPipelines.cpp` registers the Coro passes as **middle-end IR passes**:

```cpp
// PassBuilderPipelines.cpp:475-484
static CoroConditionalWrapper buildCoroWrapper(ThinOrFullLTOPhase Phase) {
  // TODO: Skip passes according to Phase.
  ModulePassManager CoroPM;
  CoroPM.addPass(CoroEarlyPass());
  CGSCCPassManager CGPM;
  CGPM.addPass(CoroSplitPass());
  CoroPM.addPass(createModuleToPostOrderCGSCCPassAdaptor(std::move(CGPM)));
  CoroPM.addPass(CoroCleanupPass());
  CoroPM.addPass(GlobalDCEPass());
  return CoroConditionalWrapper(std::move(CoroPM));
}
```

`CoroSplitPass` is added inside a `createModuleToPostOrderCGSCCPassAdaptor` (`PassBuilderPipelines.cpp:480-481`) — i.e. it runs in the **CGSCC** (call-graph SCC) pipeline, and `CoroElidePass` runs in the function pipeline so a coroutine frame can be elided to the caller's stack when the lowering proves it safe. The CGSCC/IPO pipeline runs entirely on LLVM IR and finishes before the per-target backend (`addPassesToEmitFile` → instruction selection → WebAssembly MC). Therefore, by the time the WebAssembly backend runs, `CoroSplit`/`CoroCleanup` have already replaced every `llvm.coro.*` intrinsic with branches, allocas / heap allocations, GEP+load/store, and indirect resume/destroy calls — _plain IR_. See [llvm-internals] for the per-pass detail of that rewrite.

### 2.4 Negative evidence: the WebAssembly backend has no coroutine or stack-switch support

The claim is provable from absence. Two checks in this checkout confirm there is nothing wasm-specific:

1. **`llvm/include/llvm/IR/IntrinsicsWebAssembly.td` (387 lines, read in full)** defines only memory/ref/table/EH/SIMD/atomic/TLS/half-precision intrinsics. The only non-local-control-flow family is the exception-handling block (`IntrinsicsWebAssembly.td:126`, with `int_wasm_throw` at `:132`, `int_wasm_rethrow` at `:134`, `int_wasm_catch` at `:147`). A grep of the whole file for `coro|cont\.new|stack.?switch|suspend|resume` returns **zero** matches.

2. **A grep of the target itself** — `grep -rniE 'cont\.new|stack.?switch|wasmfx|StackSwitch|coro' llvm/lib/Target/WebAssembly/` — returns **0 matches.** (The only `Stack*` files there, `WebAssemblyCFGStackify.cpp` and `WebAssemblyRegStackify.cpp`, concern the wasm _value stack_ / operand stackification, which is unrelated to stack-switching.)

> [!IMPORTANT]
> **Conclusion.** An LLVM coroutine is lowered to an ordinary state machine + frame
> struct _in the middle-end_ (`CoroSplit.cpp:1-19`, `CoroFrame.cpp:8-15`,
> `CoroShape.h:26-49`, `PassBuilderPipelines.cpp:480`), and the WebAssembly backend
> compiles the residual ordinary IR to plain wasm 1.0. The WebAssembly backend has
> **no** coroutine or stack-switch intrinsics at all (`IntrinsicsWebAssembly.td`
> full read; `lib/Target/WebAssembly` grep = 0). **D stackless coroutines therefore
> run on any conforming wasm 1.0 engine with zero engine support** — exactly the
> same code paths C++20 and Swift already use.

---

## 3. Three strategies for D suspension semantics on wasm

There are three families of mechanism for giving D code suspendable semantics on WebAssembly. They differ in _where_ the lowering happens, _what engine feature_ they need, and _what shape_ of code they can suspend.

### Strategy (1) — LLVM `Coro*` → state machine → ordinary wasm _(works on wasm 1.0 today)_

The mechanism of §2. The D frontend/codegen emits `llvm.coro.*` intrinsics into a function marked `presplitcoroutine`; `CoroSplit`/`CoroFrame`/`CoroCleanup` rewrite it into an ordinary state machine + frame; the WebAssembly backend lowers the residual IR to plain wasm.

- **Engine support:** none. Runs on any wasm 1.0 engine.
- **Stack model:** stackless — the "stack" is the materialized frame struct (`CoroFrame.cpp:8-15`).
- **Cost:** the standard state-machine codegen cost — a frame allocation (heap, or elided to stack/caller by `CoroElide`), a state index, spills/reloads of suspend-crossing values via GEP+load, and indirect resume/destroy calls. Suspension is a `return` from the resume function; there is no per-suspend stack switch. Predictable, and it composes with the existing wasm port unchanged.
- **What LDC still has to do:** _generate_ the coro intrinsics. This is frontend/codegen work (see §4 and [ldc-codegen]); the LLVM lowering itself is mature.

> [!WARNING]
> **EH caveat.** `coro.resume`/`coro.destroy` are typed `[Throws]` and LLVM's
> coroutine cleanup is unwind-aware, but LDC-wasm stubs exceptions to `abort()`
> (`rt/wasi_exceptions.d:3-20`). The realistic first target is therefore a no-EH
> coroutine ABI — the `RetconOnce`/`Switch`-without-cleanup-unwind shape
> (`CoroShape.h:33-43`). See [attributes] for the attribute/lifetime consequences.

### Strategy (2) — Binaryen Asyncify + Emscripten JSPI _(no engine stack-switch primitive)_

These are _whole-program / post-IR_ techniques that synthesize suspension on engines that have **no** stack-switching primitive. They are not represented as source files in this checkout; the summary below is framed against the contrast the WasmFX explainer itself draws ([wasmfx], which cites the whole-program-transform downsides directly).

- **Binaryen Asyncify** (`wasm-opt --asyncify`): a whole-module CPS / state-unwinding transform applied to the _wasm binary_, after LLVM produced it. It instruments every function on a path that may suspend so it can (a) _unwind_ — spill locals into a side data structure in linear memory and return up the stack — and (b) _rewind_ — re-enter, skipping already-executed code via a per-function state check, and reload locals. It is essentially a global, runtime-driven version of what `CoroSplit` does per-coroutine, applied to arbitrary call graphs. **Costs:** significant code-size blow-up (commonly cited ~2× on instrumented paths) and hot-path runtime overhead; and the natural call stack is destroyed, hurting stack traces and debugging. The WasmFX overview names exactly these downsides for whole-program transforms ([wasmfx]: "bloat code, destroy the natural call-stack structure ... and compose poorly across module boundaries"). Emscripten used Asyncify to implement `emscripten_sleep` and synchronous-looking async before JSPI existed.

- **Emscripten JSPI (JS Promise Integration):** uses the host JS engine's _own_ stack-switching at the wasm↔JS boundary. A wasm import is marked "suspending"; when it returns a `Promise`, the engine suspends the _entire wasm stack_ into a JS-managed suspender and yields a `Promise` to JS; on resolution the wasm stack is resumed. There is no Binaryen instrumentation, so wasm code-size and runtime cost are near-zero versus Asyncify — but (i) it only suspends at calls _out to JS_ (host-driven, not arbitrary in-wasm suspension points), (ii) it requires a JS host with JSPI (browser/Node, historically flag-gated), so it is **not** a pure-wasm/WASI solution, and (iii) it is "stackful" at the boundary — the whole wasm stack is the unit of suspension — unlike the per-coroutine frame of Strategy (1). The WasmFX deep-dive lists JSPI as an "alternative async path; stack switching is more general" ([wasmfx]).

- **Relation to Strategy (1):** Asyncify/JSPI are needed only when you must suspend code you _cannot_ re-shape into LLVM coroutines — a synchronous C library you call into, or arbitrary blocking I/O. For D code you control and can express as coroutines, Strategy (1) is strictly cheaper and engine-independent.

### Strategy (3) — WasmFX stack-switching _(future engine primitive)_

The standards-track **stack-switching** proposal adds a real engine primitive for first-class one-shot continuations. The mechanism is the subject of the survey's [wasmfx] deep-dive and is only summarized here:

- **One new reference type** `cont $ft` and **seven instructions** (`Explainer.md:1185-1195`, opcodes `0xe0`–`0xe6`): `cont.new`, `cont.bind`, `suspend`, `resume`, `resume_throw`, `resume_throw_ref`, `switch`. **Tags are reused from exception handling**, generalized to carry result types — "a control tag may be thought of as a _resumable_ exception" ([wasmfx]).
- **Asymmetric** `suspend`/`resume` is the core: `resume` installs a handler _and_ delimits the continuation; `suspend $e` transfers to the innermost ancestor `resume` that installed `(on $e $l)`, handing the handler a reified continuation + payload. **Symmetric** `switch` is a peer-to-peer transfer in a single stack switch — the scheduler hand-off primitive. `cont.bind` partial-applies with no allocation because continuations are single-shot. See [wasmfx] for the full typing.
- **One-shot (linear):** invoking a continuation more than once traps; the engine can therefore _move_ a real stack on suspend/resume rather than copy it ([wasmfx], performance section).
- **Status:** Phase 3 (active implementation); engine and toolchain coverage is still uneven ([wasmfx]).

The proposal ships runnable encodings of exactly the workloads D would care about: green-thread schedulers (`examples/scheduler1.wast`, `scheduler2.wast`, `scheduler2-throw.wast`), lightweight threads (`lwt.wast`, `fun-lwt.wast`), a generator (`generators.wast`), and an async/await encoding defining `$async`/`$await`/`$yield`/`$fulfill` tags (`async-await.wast`). The algebraic-effects corpus connects these to source effect systems and event loops via [ae-index] and [effects-event-loops].

#### How D would lower onto WasmFX

- **A D stackless coroutine** (already `CoroSplit`-able): you would map the D coroutine's `suspend` directly to a wasm `suspend $tag` and the driver/scheduler to a `resume $ct (on $tag $l)` loop — skipping the frame-struct materialization and letting the _engine_ hold the suspended state. This needs **LLVM to grow a WebAssembly lowering of the coro intrinsics to `cont.*`**, which **does not exist today** (§2.4), plus engine support. It would trade compiler-managed frame structs for engine-managed stacks — a different cost model, not obviously a win for the stackless case.

- **A D stackful fiber** (`core.thread.fiber.Fiber` style — see [d-fiber]) maps _even more naturally_: `Fiber.call` → `cont.new` + `resume`, `Fiber.yield` → `suspend`, the scheduler loop → `switch`. **This is the case where WasmFX wins over Strategy (1):** a stackful fiber **cannot be `CoroSplit`**, because its suspension points are not statically known (it can yield from arbitrary depth in code the compiler never sees as a coroutine). On a pure-wasm engine without WasmFX, a stackful fiber falls back to Asyncify (Strategy 2) with all its costs; _with_ WasmFX it is a direct, cheap engine primitive — the WasmFX `scheduler`/`lwt` examples _are_ a green-thread runtime.

- **Cancellation / EH interop:** `resume_throw` / `resume_throw_ref` cancel a suspended continuation by raising a wasm exception at its suspension point, composing with `try_table` ([wasmfx]). This is the wasm-native analogue of unwinding a coroutine frame on `coro.destroy`, but it requires wasm EH in druntime first — which is the very thing that is stubbed today (§1.3).

### Strategy comparison

| Axis                     | (1) LLVM Coro → wasm                | (2) Asyncify / JSPI                            | (3) WasmFX                                     |
| ------------------------ | ----------------------------------- | ---------------------------------------------- | ---------------------------------------------- |
| Engine feature needed    | **none** (wasm 1.0)                 | none (Asyncify) / JSPI host                    | stack-switching (Phase 3)                      |
| Where lowered            | LLVM mid-end (CGSCC), pre-ISel      | Binaryen post-link / JS boundary               | wasm bytecode + engine                         |
| Stack model              | stackless (frame struct)            | stackful unwind (Asyncify) / host stack (JSPI) | engine stacks, one-shot                        |
| Suspends arbitrary code? | only `CoroSplit`-able fns           | yes (whole program) / only at JS calls         | yes (any `suspend` site)                       |
| Code size                | low (per-coro state machine)        | high (Asyncify ~2×) / low (JSPI)               | low                                            |
| Stack traces / debug     | OK                                  | poor (Asyncify)                                | good (natural stacks)                          |
| Multi-shot               | n/a (compiler frame)                | n/a                                            | **no** (linear, traps)                         |
| Available in LDC today   | needs frontend emit (§4)            | external tool / Emscripten                     | not in LLVM wasm backend (§2.4)                |
| Best for                 | D stackless coroutines / generators | legacy/blocking code you can't reshape         | stackful fibers, scheduler-heavy green threads |

---

## 4. Gap analysis — what LDC/DMD lack today

Four concrete gaps stand between the current state and a working D-coroutine-on-wasm pipeline:

- **No native D coroutine syntax / no `await` keyword.** `grep -rniE '\bawait\b|coroutine|TOKawait' dmd/tokens.d dmd/tokens.h` → **0 matches.** D has no language-level async/await; today's coroutine-like semantics come from the library — `core.thread.fiber.Fiber` and ranges/generators — i.e. _stackful_. The language-design space for a D stackless construct is the subject of [d-design].

- **LDC emits no `llvm.coro.*`.** `grep -rniE 'coro\.|llvm\.coro|Intrinsic::coro|CoroSplit|presplitcoroutine' gen driver` → **0 matches.** LDC does not currently generate any coroutine intrinsics. Strategy (1) requires new frontend/codegen work to lower a D stackless-coroutine construct to the `int_coro_*` intrinsics; once they are emitted, the existing LLVM passes (§2) do the rest with no wasm-specific code. This is the central LDC task — see [ldc-codegen] and [roadmap].

- **Exceptions are stubbed on wasm** (`rt/wasi_exceptions.d:3-20`), so the first coroutine target should be no-EH (§1.3, §3.1).

- **No async-I/O syscall surface** in `core/sys/wasi/` (`core.d:19-26` exposes only random + clock). A coroutine-driven event loop on WASI needs `poll_oneoff` / fd bindings added before the suspension machinery has anything to wait on. See [effects-event-loops] and [async-io-index].

---

## 5. Orthogonality and composition (the crucial framing)

**LLVM stackless-coroutine lowering is orthogonal to, and composes with, the wasm port.** They are independent layers, and recognizing this is what lets the roadmap ship incrementally without re-architecting.

- **Stackless coroutines are a middle-end IR transform.** `CoroSplit`/`CoroFrame`/`CoroCleanup` run in the CGSCC/IR pipeline (`PassBuilderPipelines.cpp:480`) and finish _before_ any target backend. They give D suspension semantics on wasm with **zero engine support** — the residual IR is ordinary code that the coroutine-unaware WebAssembly backend compiles to plain wasm 1.0. This is provable from the backend having no coroutine or stack-switch intrinsics whatsoever (`IntrinsicsWebAssembly.td` full read; `lib/Target/WebAssembly` grep = 0).

- **WasmFX is an optimization / alternative, not a prerequisite.** It is a _backend / engine_ feature (`Explainer.md:1185-1195`) that targets exactly the cases stackless coroutines handle poorly: **stackful** fibers (`core.thread.fiber.Fiber`, which cannot be `CoroSplit`d) and **scheduler-heavy** green-thread workloads where engine-managed stacks plus symmetric `switch` beat materialized frame structs. The WasmFX scheduler/lwt examples are precisely that workload class ([wasmfx]).

- **They stack cleanly.** A port can ship Strategy (1) _now_ — engine-independent stackless coroutines and generators — and _later_ add a WasmFX lowering path for stackful / green-thread workloads as engines (Wasmtime et al.) ship the Phase-3 feature, **without re-architecting the stackless path.** Asyncify / JSPI (Strategy 2) is the stopgap for code that can be neither `CoroSplit`d nor (yet) run on a WasmFX engine, at the documented code-size / performance / debuggability cost.

> [!NOTE]
> Restated as a single sentence for the roadmap: _stackless coroutines are a wasm-1.0
> middle-end feature that needs no engine support and should ship first; WasmFX is a
> later, complementary engine track for the stackful/scheduler cases; Asyncify/JSPI
> is a host-dependent stopgap._ The dependency ordering — coroutine intrinsic
> emission in LDC, then a no-EH wasm coroutine ABI, then (independently) wasm EH and
> a WASI I/O surface, with WasmFX as a parallel track — is carried forward in
> [roadmap].

---

## Sources

**LDC v1.42** (`$REPOS/dlang/ldc`):

- `driver/main.cpp:908-923` — WASI / Emscripten predefined `version` idents.
- `driver/targetmachine.cpp:563-565` — WASIp2/p3 → PIC.
- `gen/abi/wasm.cpp:10,42-66` — wasm BasicCABI struct/array passing.
- `gen/target.cpp:90-92` — `real` → `fp128` on wasm.
- `dmd/target.d:273,1503` — WASI ↔ `CRuntime_WASI`.
- `runtime/druntime/src/rt/wasi_exceptions.d:3-20` — EH stubbed (`abort()`).
- `runtime/druntime/src/core/sys/wasi/core.d:12-31`, `package.d:12` — minimal WASI syscalls (random/clock only).
- `tests/codegen/wasm_wasip1.d`/`wasm_wasip2.d`/`wasm_emscripten.d`, `tests/baremetal/wasm.d`/`wasm2.d` — current wasm test coverage.
- Greps: `coro.|llvm.coro|Intrinsic::coro|CoroSplit|presplitcoroutine` in `gen`/`driver` → 0; `\bawait\b|coroutine|TOKawait` in `dmd/tokens.*` → 0.

**LLVM 23.0.0git** (`$REPOS/llvm-project`):

- `llvm/include/llvm/IR/Intrinsics.td:1875+` — 38 generic, target-independent `int_coro_*` intrinsics.
- `llvm/lib/Transforms/Coroutines/CoroSplit.cpp:1-19` — "Converts a coroutine into a state machine".
- `llvm/lib/Transforms/Coroutines/CoroFrame.cpp:8-15` — frame struct = GEP+load / spill of suspend-crossing values.
- `llvm/include/llvm/Transforms/Coroutines/CoroShape.h:26-49` — `enum class ABI { Switch, Retcon, RetconOnce, Async }`.
- `llvm/lib/Passes/PassBuilderPipelines.cpp:475-484` — Coro passes in the CGSCC/IR pipeline before ISel.
- `llvm/include/llvm/IR/IntrinsicsWebAssembly.td` (387 lines, full read; EH at `:126,132,134,147`) — **no** coro/stack-switch intrinsics.
- Grep: `cont\.new|stack.?switch|wasmfx|StackSwitch|coro` in `llvm/lib/Target/WebAssembly/` → 0.

**WasmFX / stack-switching** (`$REPOS/wasm/stack-switching`):

- `proposals/stack-switching/Explainer.md:1185-1195` — seven instructions, opcodes `0xe0`–`0xe6`; semantics quoted via the survey's WasmFX deep-dive.
- `proposals/stack-switching/examples/{scheduler1,scheduler2,scheduler2-throw,lwt,fun-lwt,generators,async-await}.wast` — runnable encodings.
- `docs/research/algebraic-effects/wasmfx.md` — the survey's WasmFX deep-dive (source of truth for the mechanism).

**External (not on disk):** Binaryen Asyncify (`wasm-opt --asyncify`); Emscripten JS Promise Integration (JSPI). Summarized against the whole-program-transform contrast drawn in the WasmFX explainer.

<!-- References -->

[index]: ./index.md
[concepts]: ./concepts.md
[llvm-coroutines]: ./stackless/llvm-coroutines.md
[llvm-internals]: ./stackless/llvm-coro-internals.md
[comparison]: ./stackless/comparison.md
[d-fiber]: ./stackful/d-fiber.md
[d-design]: ./stackless/d-language-design.md
[ldc-codegen]: ./stackless/ldc-codegen.md
[attributes]: ./stackless/attributes-and-memory.md
[roadmap]: ./stackless/roadmap.md
[wasmfx]: ../algebraic-effects/wasmfx.md
[ae-index]: ../algebraic-effects/index.md
[effects-event-loops]: ../async-io/effects-and-event-loops.md
[async-io-index]: ../async-io/index.md
