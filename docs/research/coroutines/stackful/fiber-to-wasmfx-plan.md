# Implementation Plan: Porting `core.thread.Fiber` to WebAssembly Stack Switching (WasmFX)

This is the engineering payload for the [stackful-track survey][stackful-index]: a
concrete plan to make D druntime's stackful `core.thread.Fiber` run on the WasmFX
(typed-continuations / stack-switching) instruction set, with the public API
unchanged. The thesis is that
the entire portable surface — the `base.d` API and the `HOLD`/`EXEC`/`TERM` lifecycle
machine — survives verbatim, and only `package.d`'s stack-poking backend is replaced,
at the two `assert(0, "Fibers not supported on WASI")` stubs that already mark the
seam. But three cross-cutting problems gate a _correct_ port: no toolchain can emit
`cont.*` today, the GC cannot scan a suspended continuation's engine-owned stack, and
wasm exception handling is stubbed. This plan sequences those blockers into phases a
maintainer can act on — what is doable now versus blocked on upstream — building on the
encoding worked out in [wasmfx-target] and the primitive characterized in [d-fiber].

**Last reviewed:** June 5, 2026

---

> [!NOTE]
> **What the sibling docs already cover — cite them, don't re-derive.** The encoding
> deep-dive ([wasmfx-target]) owns the operation-by-operation `Fiber`-op → `cont.*`
> mapping, the one-shot↔reusable impedance, and `resume_throw` cancellation; the
> WasmFX spec deep-dive ([wasmfx]) owns the instruction typing; the primitive baseline
> ([d-fiber]) owns the `Fiber` API, GC coupling, and TLS-migration hazard; the
> cross-cutting overview ([wasm]) owns the three-strategy framing and the LLVM-wasm
> negative evidence. **This** doc adds only the non-overlapping delta: the _plan_ —
> the seam, the three gating problems settled as decisions, the phase graph, and the
> exit criteria.

All druntime paths below are under `runtime/druntime/src/` in the LDC v1.42 tree
(`$REPOS/dlang/ldc`); WasmFX paths under
`$REPOS/wasm/stack-switching/proposals/stack-switching/` (the `Explainer.md` and the
runnable `examples/*.wast`); LLVM paths under `$REPOS/llvm-project`.

---

## Goal and scope

**Goal.** Run `core.thread.Fiber` on WasmFX `cont.*` stack switching, with the public
`Fiber` API byte-for-byte source-compatible. A program that constructs a `Fiber`,
`call`s it, `yield`s, `reset`s, and iterates a `std.concurrency.Generator` should
compile and run on a WasmFX-capable engine with no source change.

**The thesis, stated crisply.** The public API and the three-state lifecycle machine
live in `base.d` (class `FiberBase`) and are **machine-independent — they survive
verbatim**. Only `package.d`'s stack-poking backend — `allocStack`, `freeStack`,
`initStack`, and `fiber_switchContext` — is replaced, and the two
`assert(0, "Fibers not supported on WASI")` stubs (`package.d:576-578` in
`fiber_switchContext`, `package.d:1650-1652` in `initStack`) are the **exact insertion
points**. Everything that assumes an addressable linear machine stack lives behind
those two seams; nothing else needs to move.

**But three cross-cutting problems gate a _correct_ port,** and each must be settled as
a design decision _before_ codegen, not discovered during it:

1. **No toolchain can emit `cont.*` today** (LLVM 23 / LDC have no intrinsics, opcodes,
   ISel, or `cont` feature; the generic `Coro*` passes are stackless and cannot
   transform a stackful suspend). Resolved by a hand-written `.wat` primitives module.
2. **The GC cannot scan a suspended continuation's engine-owned stack** — a GC root
   living only on a suspended fiber's stack is invisible and may be freed (a
   use-after-free). This is _the_ gating blocker.
3. **wasm exception handling is stubbed** (`rt/wasi_exceptions.d` makes every throw
   `abort()`), so the `m_unhandled` capture/rethrow contract is inert and
   `resume_throw`-based cancellation cannot unwind D frames.

**In scope.** The bare `Fiber` primitive: construct / `call` / `yield` / `reset` /
state machine / cancellation, plus the druntime backend wiring and the toolchain to
emit and run it.

**Out of scope (sequenced as later phases).** The green-thread scheduler
(`FiberScheduler`) and symmetric `switch` hand-off (Phase 7); the async-I/O loop
([green-threads], [d-fiber]); and the _fully general_ cross-`yield`-GC-roots case
(Phase 6) — which the early phases handle by a documented restriction rather than a
compiler pass. The Component-Model boundary is flagged as a future blocker, not
addressed.

---

## The seam: what survives vs. what `cont.*` replaces

The port plugs into the **exact same dispatch seam** the existing asm/`ucontext`
backends use. There are three `version(...)` dispatch points, all in `package.d`: the
platform→backend ladder (`package.d:54-191`), the `fiber_switchContext` body dispatch
(`package.d:204-591`, where the WASI stub lives at `:576-578`), and the `initStack`
body dispatch (`package.d:1093-1668`, WASI stub at `:1650-1652`). A new
`version(WasmFX)` branch slots in exactly where `AsmX86_64_Posix` and the `ucontext`
fallback already slot in.

| API that stays identical (all `base.d`, portable)                                                                                                                                                                                                 | Internals replaced by `cont.*` (all `package.d` backend)                                                                                                                                          |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Constructors `this(void function(), size_t sz, size_t guardPageSize)` (`base.d:327`) and `this(void delegate(), …)` (`base.d:354`); subclass defaults (`package.d:783`,`:805`). `sz`/`guardPageSize` kept for source-compat, become **advisory**. | `allocStack` (`package.d:857`): `mmap`/`VirtualAlloc` + guard page + `m_pmem` + `m_size` → continuation bookkeeping (a `cont_slot` field).                                                        |
| `call(Rethrow)` / `call(Rethrow)()` (`base.d:411`,`:417`); `enum Rethrow` (`base.d:465`). Deliberately un-attributed (runs arbitrary user code).                                                                                                  | `freeStack` (`package.d:1021`): `munmap`/`VirtualFree` → drop the `cont` reference (engine reclaims it).                                                                                          |
| `static yield()` (`base.d:583`), `static yieldAndThrow(Throwable)` (`base.d:608`) — both `static nothrow @nogc`. Only the `switchOut()` line inside them changes.                                                                                 | `initStack` (`package.d:1054`): per-arch fake initial frame → `cont.new $ct (ref.func $entry)`. **No fake frame at all.**                                                                         |
| `reset()` / `reset(fn)` / `reset(dg)` (`base.d:478`,`:492`,`:499`) — `nothrow @nogc`.                                                                                                                                                             | `fiber_switchContext(void** oldp, void* newp)` (`package.d:206`,`:395`): swap-`sp` asm / `swapcontext` → `suspend` / `resume` (or `switch`). `oldp`/`newp` (raw stack pointers) have no analogue. |
| `enum State { HOLD, EXEC, TERM }` (`base.d:511`) + `state` property (`base.d:531`) + all legal transitions.                                                                                                                                       | `switchIn`/`switchOut` (`base.d:760`,`:854`): their _bodies_ (which call `fiber_switchContext` and juggle `m_lock`/`pushContext`) get a `version(WasmFX)` form emitting the stack-switching ops.  |
| `getThis()`/`setThis()`/`sm_this` (`base.d:642`,`:743`,`:748`) — the TLS slot tracking the running fiber.                                                                                                                                         | The fake initial frame, `m_pmem`/`m_size`/`m_ctxt` stack pointers, guard pages, `defaultStackPages` (`package.d:749`) — all gone; the engine owns and grows the continuation stack.               |
| `m_unhandled` capture/rethrow contract (`base.d:144-151`,`:420-428`) — present, but **inert** until wasm EH works (Problem 3).                                                                                                                    | The two `assert(0, "Fibers not supported on WASI")` stubs (`package.d:576-578`, `:1650-1652`) — the **exact insertion points** for the `version(WasmFX)` branch.                                  |

### `fiber_entryPoint` survives almost verbatim as the continuation function

The first-resume landing pad `fiber_entryPoint` (`base.d:129-158`) is the function that
the fake initial frame currently "returns into" on the first switch. With WasmFX there
_is_ no fake frame: `cont.new $ct (ref.func $fiber_entryPoint_shim)` creates a
continuation whose top function _is_ the entry shim, and the first `resume` enters it
normally. Its body survives essentially verbatim:

```d
extern (C) void fiber_entryPoint() nothrow @assumeUsed     // base.d:129
{
    FiberBase obj = FiberBase.getThis();
    ...
    obj.m_state = FiberBase.State.EXEC;
    try { obj.run(); }                          // run() => m_call()  (base.d:665)
    catch ( Throwable t ) { obj.m_unhandled = t; }
    obj.m_state = Fiber.State.TERM;
    obj.switchOut();                            // final switch back to resumer
}
```

The only change is the final `switchOut()`: when the continuation function simply
_returns_, the engine treats the return as "continuation done" and control falls back
to the `resume`'s parent (`Explainer.md:248-256`). `run()` returning maps naturally to
that, so the explicit final `switchOut()` may be replaced by a plain return — the
fall-through arm of the resumer's `resume` _is_ the `State.TERM` signal.

---

## The target encoding (`Fiber` op → `cont.*`)

The full op→encoding table and verbatim `.wast` grounding live in [wasmfx-target] §"The
core mapping" and the encoding digest; the condensed correspondence the backend
implements is:

| D `Fiber` op (`base.d`)                           | WasmFX encoding                                                                                                                                       |
| ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| construct / `reset`                               | `cont.new $ct (ref.func $entry)` → store in `cont_slot` (runs nothing yet); optional `cont.bind` to fold the delegate env.                            |
| `call()` (first and Nth resume)                   | `(block $on_yield (result <payload> (ref $ct)) (resume $ct (on $yield $on_yield) (cont_slot)) <TERM arm>)` then `<suspend arm: local.set cont_slot>`. |
| `yield()` (suspend from any depth)                | `suspend $yield` — engine routes to the innermost dynamic handler.                                                                                    |
| `State.TERM`                                      | the **fall-through arm** of `resume` (the cont ran off its end and returned to the parent).                                                           |
| cancel a live fiber (`reset`-of-live / GC unwind) | `try_table (catch $cancel _) (resume_throw $ct $cancel (cont_slot))` — raise at the suspension point, run dtors, swallow.                             |
| scheduler task→task hand-off (Phase 7)            | symmetric `switch $ct $yield (next)` with `(on $yield switch)` at the resumer.                                                                        |
| bind delegate env / entry args                    | `cont.bind $ct1 $ct2 <prefix> (cont)` — allocation-free.                                                                                              |

### The one-shot model is the heart of the encoding

WasmFX continuations are **one-shot (linear)** (`Explainer.md:906-915`):

> "Continuations in the current proposal are single-shot (aka linear), meaning that
> they should be invoked exactly once. A continuation can be invoked either by resuming
> it (with `resume`); by aborting it (with `resume_throw`); or by switching to it (with
> `switch`). An attempt to invoke a continuation more than once results in a trap."

A D `Fiber`, by contrast, is resumed **many times** on the same object. The resolution
([wasmfx-target] §"The one-shot ↔ reusable-fiber impedance mismatch"): a `Fiber` is a
_sequence_ of fresh one-shot continuations. The `Fiber` object holds a **mutable
`cont_slot`** — overwritten with the FRESH `(ref $ct)` reified at every `suspend`. That
slot is the WasmFX replacement for druntime's saved `sp` / `m_ctxt.tstack` that
`fiber_switchContext` swaps. Resuming a consumed `cont` traps, so the `cont_slot` must
never be resumed twice; the `in (m_state == State.HOLD)` contract on `callImpl`
(`base.d:432`) and the `TERM/HOLD` contract on `reset` (`base.d:478`) become the
host-side guards enforcing this.

### The Fiber-driver pseudo-encoding

This is the shape of the `version(WasmFX)` backend (from the encoding digest §7), with
`HOLD`/`EXEC`/`TERM` staying **host bookkeeping** — they are not wasm values:

```text
Fiber object holds:  cont_slot : (ref null $ct)    // = fresh handle, the "saved sp"
                     state     : HOLD | EXEC | TERM // host-side, not a wasm value

new Fiber(dg):  cont_slot = cont.new $ct (ref.func $entry_for_dg)  // optional cont.bind env
                state = HOLD

call():         require state == HOLD
                block $on_yield (result <yield-payload> (ref $ct)):
                   resume $ct (on $yield $on_yield) (cont_slot)
                   // fell through => fiber returned
                   state = TERM; cont_slot = null; handle m_unhandled; return
                // suspended => land here
                cont_slot = <fresh (ref $ct) from block>   // overwrite slot (one-shot!)
                state = HOLD; return

yield():        suspend $yield            // inside the fiber; engine finds the handler

reset():        require state == TERM or HOLD
                cont_slot = cont.new $ct (ref.func $entry)  // re-prime; old cont dropped
                state = HOLD

cancel(t):      require state == HOLD (live, mid-body)
                try_table (catch $cancel _):
                   resume_throw $ct $cancel (cont_slot)     // unwind + run dtors
                cont_slot = null; state = TERM
```

### This is NOT a 2-arg `swapcontext`

The single most important conceptual difference from druntime's
`fiber_switchContext(void** oldp, void* newp)` symmetric save-here/load-there asm swap:
**WasmFX `resume` is a _delimited_ operation, not a symmetric swap.** The resumer (the
entity that calls `fib.call()`) **installs the handler** `(on $yield $on_yield)` on the
`resume` instruction; that handler _delimits_ the captured continuation. `suspend` does
**not name a target** — it dispatches to the innermost dynamically-enclosing handler
for the tag (`Explainer.md:644-646`):

> "It suspends the current continuation up to the nearest enclosing handler for `$e`.
> This behaviour is similar to how raising an exception transfers control to the nearest
> exception handler that handles the exception."

This delimited dispatch is exactly _why_ WasmFX can host D's suspend-anywhere
`Fiber.yield()` even though `yield()` is a parameterless `static` call (`base.d:583`)
reachable behind any indirect call: the **engine**, not the compiler, finds the handler.

### Keep the two throw directions distinct

`yieldAndThrow` (`base.d:608`) and `resume_throw` are **opposite directions** and must
not be conflated:

- `yieldAndThrow(t)` — fiber → resumer. The fiber `suspend`s after parking `t` in
  `m_unhandled`; the resumer's _next_ `call()` rethrows it on the resumer's stack
  (`base.d:420-428`). The wasm-native form is the fiber suspending and the resumer
  re-throwing `m_unhandled` — **not** `resume_throw`.
- `resume_throw` — resumer → fiber. The resumer forces a throw _into_ the suspended
  fiber to unwind it (run scope guards / RAII). This is the encoding for "kill this
  fiber now" on `reset`-of-live / GC finalization.

---

## The three gating problems (settle BEFORE codegen)

### Problem 1 — No toolchain can emit `cont.*` today

> [!WARNING]
> **LLVM 23 / LDC cannot emit a single stack-switching instruction.**
> `IntrinsicsWebAssembly.td` defines zero `cont.*`/stack-switching intrinsics; the
> WebAssembly backend (`llvm/lib/Target/WebAssembly/`) has no `cont.new`/`RESUME`/
> `SUSPEND`/`switch`/`resume_throw` opcodes or ISel; `WebAssembly.td` has no `cont` /
> `stack-switching` subtarget feature. The generic `Coro*` passes are a **stackless**
> state-machine transform and **cannot** transform a stackful suspend deep in opaque D
> code. Inline-IR (`pragma(LDC_inline_ir)`) and `LDC_intrinsic` cannot help: inline IR
> goes through `parseAssemblyString` (`gen/inlineir.cpp:192-193`) and so can only
> express what LLVM IR can — and there is no `llvm.wasm.cont.*` intrinsic and no
> IR-level `contref` type to name. **There is no in-LLVM lowering path.** (Grounding:
> the toolchain digest §1; [wasm] §2.4.)

**The four options (toolchain digest §2):**

| Option                                                        | What it is                                                                                                                                                                                                                                                                             | Verdict                                                                      |
| ------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| (a) Add LLVM `int_wasm_cont_*` intrinsics + ISel              | Principled long-term path; new typed-reference value type for `(ref $ct)`, instruction defs at opcodes `0xe0`–`0xe6`, the `(on $e $l)` handler-clause table (no existing LLVM analogue), assembler/disassembler, `wasm-ld`, validation.                                                | **Long-term (Phase 8)** — multi-quarter upstream project. Not the bootstrap. |
| (b) Binaryen post-link pass synthesizing `cont.*`             | Binaryen v122+ _parses/validates/optimizes_ stack-switching, but will **not invent** `cont.*` from a high-level D suspend (no such pass).                                                                                                                                              | **Finalizer only** — enables (c), doesn't replace it.                        |
| (c) Hand-author `fiber-primitives.wat` + link with LDC output | A `.wat` module exposing `__fiber_new`/`__fiber_resume`/`__fiber_yield`/`__fiber_throw` over `cont.new`/`resume`/`suspend`/`resume_throw` + shared imported `$yield`/`$cancel` tags; the LDC module imports them and re-declares the structural `(cont $ft)` type. **No LLVM change.** | **RECOMMENDED bootstrap.**                                                   |
| (d) inline-IR / `LDC_intrinsic`                               | Cannot express `cont.*` (above).                                                                                                                                                                                                                                                       | **Dead end** until (a) lands.                                                |

**Why option (c) works — cross-module `cont`/tag/handler split is PROVEN feasible.**
The load-bearing question is whether a `cont` type, the `suspend` site, and the
`resume` handler can span a module boundary. `generators.wast` proves **yes**, in three
different modules sharing one imported tag and the structural cont type:

- The tag is **exported** from module `$generator` (`generators.wast:5`:
  `(tag $yield (export "yield") (param i32))`) and **imported** by two others
  (`generators.wast:13` and `:90`: `(tag $yield (import "generator" "yield") (param i32))`).
- `cont.new` runs in the top module over an imported funcref
  (`generators.wast:143`: `(cont.new $cont (ref.func $naturals))`), the function body
  carrying `suspend $yield` lives in `$examples`, and the `resume … (on $yield …)`
  handler lives in `$manager` — three different modules. Continuation types are
  **structural** (`(cont $ft)`), so each module re-declares `(type $cont (cont $func))`
  and they match by structure. **The handler delimits dynamically (at `resume`), not
  lexically/per-module.** Binaryen v122+ finalizes and validates the merged module.

**The single load-bearing assumption to validate in P0.** The D function that suspends
cannot itself carry `suspend` (LDC can't emit it); instead the D entry trampoline
**calls** the imported `__fiber_yield`, and the actual `suspend` lives inside that
imported primitive. The assumption — _that `suspend` inside an imported callee correctly
unwinds the D frames above it on the same continuation_ — follows from dynamic handler
dispatch (`Explainer.md:644-646`), but **must be validated end-to-end on Wasmtime**
before any druntime work. It is the most load-bearing assumption of the whole bootstrap.

**Long-term.** Option (a) — upstream LLVM `int_wasm_cont_*` intrinsics + ISel — replaces
the hand-written `.wat` with first-class LDC codegen once the approach is proven
(Phase 8).

### Problem 2 — GC cannot scan a suspended continuation's stack (THE gating blocker)

> [!IMPORTANT]
> **This is the decision to settle first, before any codegen.** A GC root that lives
> _only_ on a suspended fiber's stack is invisible to the D GC and may be freed — a
> use-after-free, not a performance issue.

**Precise framing.** Today the conservative GC scans the linear-memory byte range
`[tstack..bstack)` per `StackContext` (`threadbase.d:1131-1155`), registered via
`ThreadBase.add(m_ctxt)` (`package.d:1014`); on `TERM` the range is collapsed so a dead
stack is not scanned (`base.d:451-461`). The asm fiber works **precisely because the
suspended fiber's stack is ordinary linear memory the conservative GC can read.** A
WasmFX continuation breaks this: a suspended `(ref $ct)`'s stack is **engine-owned and
opaque** — its frames live in engine-managed memory outside the module's linear memory.
There is no `bstack`/`tstack` pair pointing at it, no host API to enumerate it
(`Explainer.md` has _zero_ GC/scan/root text; a grep for `garbage|collect|scan|root`
returns nothing), and Wasmtime#10248's GC integration is unfinished. So
`scanAllTypeImpl`'s `scan(ScanType.stack, c.tstack, c.bstack)` cannot reach fiber-local
roots → **a GC root living only on a suspended fiber's stack is invisible and may be
collected → UAF on resume.**

**The five mitigations (toolchain digest §4.2):**

| #     | Mitigation                                                                                                                                                                                                                                                                   | Verdict                                                                                                                                                                            |
| ----- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| (i)   | **Linear-memory shadow root stack.** Per-fiber side stack _in linear memory_; spill cross-`yield` GC roots before suspend, reload after resume; the D GC scans these as additional conservative ranges via the existing mechanism.                                           | **Design the ABI for it now**; needs LDC support (a wasm shadow-stack pass) or a coarse spill-all-pointer-locals discipline for the general case. The most general correct option. |
| (ii)  | **wasm-GC object model.** Make D objects engine-traced `(ref struct)` so the engine traces through suspended conts.                                                                                                                                                          | **REJECT** — fundamental impedance mismatch; a wholesale rewrite of druntime's linear-memory, conservative, manually-laid-out object model and the LDC backend.                    |
| (iii) | **Precise stack maps + engine scan API.** LDC emits precise stack maps; Wasmtime exposes an API to scan a suspended continuation's frames.                                                                                                                                   | **Blocked-on-upstream** — no such Wasmtime API exists; needs both LLVM/LDC and engine work.                                                                                        |
| (iv)  | **Restrict cross-`yield` roots.** Documented restriction: across a `yield`, a fiber may hold **no GC root only on its stack**; any cross-`yield` reference must be anchored where the GC scans (a global, a heap object reachable from a global, the `Fiber` object itself). | **Ship first** — needs no compiler change; matches how scheduler/IO-loop code is already written (state in heap structs). Soundness hole if unenforced; pair with a lint later.    |
| (v)   | **Pin / treat the contref as a root wholesale.**                                                                                                                                                                                                                             | **Insufficient alone** — the GC can't compute the contref's linear-memory closure without scanning the (unscannable) stack.                                                        |

**Recommendation: ship (iv), design the ABI for (i).** First release ships with a
**documented restriction** — "no stack-only GC roots across `yield`" (iv) — enough for
scheduler/IO-loop code where state lives in heap structs; and the runtime ABI is
designed so a **linear-memory shadow root stack** (i), scanned via the existing
conservative-range mechanism, can be added when general D code must be supported.
**Reject (ii)** (object-model rewrite); treat (iii) as **blocked-on-upstream**. This is
**the gating design decision for the whole port** and must be settled before codegen.

### Problem 3 — Exceptions are stubbed on wasm

> [!WARNING]
> **Every D `throw` on wasm currently calls `abort()`.** `rt/wasi_exceptions.d` makes
> `_d_throw_exception` and `_Unwind_Resume` `abort()` and `_d_eh_personality` return 0
> (`_URC_NO_REASON`). So the `try/catch(Throwable)` in `fiber_entryPoint` cannot catch
> anything, and `yieldAndThrow`'s rethrow in `call()` would abort. The `m_unhandled`
> capture/rethrow contract _exists_ but is **inert** until wasm EH works.

**But this is a druntime-wiring task, doable now — not an LLVM gap.** Unlike
stack-switching, wasm EH **exists in LLVM 23**: `WebAssembly.td:40` has
`FeatureExceptionHandling`, and `IntrinsicsWebAssembly.td:129-156` defines
`int_wasm_throw` (`:132`), `int_wasm_rethrow` (`:134`), `int_wasm_catch` (`:147`), and
`int_wasm_landingpad_index` (`:154`), plus `exnref` intrinsics. Wiring D EH on wasm is a
**druntime/LDC personality + unwinder task** (implement
`_d_throw_exception`/`_d_eh_personality`/`_Unwind_Resume` over wasm EH / `exnref`,
replacing the `abort()` stubs) — independently doable now, with **no stack-switching
dependency**.

**Consequences for the plan.** The `ehContext` swap (`threadbase.d:512`,`:527` via
`_d_eh_swapContext`) and the SjLj plumbing (`base.d:55-119`, `m_sjljExStackTop`) are
no-ops on wasm and should be `version`-gated _out_. **Sequence EH (Phase 4) before
`resume_throw`-based cancellation (Phase 5)** — `resume_throw` raises an exception at
the suspension point, which requires the continuation's frames to run D
cleanup/unwind code, i.e. working wasm EH in druntime must exist first (and the
unwinder must cooperate with the engine's suspended-stack representation, where
Wasmtime's backtrace-across-suspensions support is still WIP).

---

## Phased implementation plan

### P0 — Validate the encoding in WAT on Wasmtime (no D). _Doable now._

- **Objective.** Prove the WasmFX `Fiber` encoding _and_ the single load-bearing
  cross-module suspend-unwind assumption, with zero D and zero LLVM work.
- **Tasks.** Hand-write a `.wat` fiber-like call/yield plus a small scheduler over
  `cont.new`/`resume`/`suspend`. Crucially, structure it so the `suspend` lives in an
  **imported callee** with caller frames above it on the same continuation, mirroring
  the `D frames → imported __fiber_yield → suspend` pattern. Run it on Wasmtime x64
  behind `Config::wasm_stack_switching`. Use `generators.wast`, `scheduler1.wast`, and
  `scheduler2-throw.wast` as oracle encodings.
- **Deliverable.** A runnable `.wat` corpus + a Wasmtime harness exercising
  call/yield/reset/cancel and a two-task scheduler.
- **Exit criteria.** (1) `suspend` inside an imported callee correctly unwinds and
  resumes the caller frames above it; (2) a one-shot cont reused after consumption
  traps as specified; (3) `resume_throw` + `try_table` cancels a live cont and runs a
  marker "destructor". If (1) fails, option (c) is invalid and the plan reverts to
  Asyncify or blocks on option (a).
- **Dependencies.** None.

### P1 — Settle the GC model + runtime ABI (design). _Gating._

- **Objective.** Make the Problem-2 decision concrete as an ABI before any backend code.
- **Tasks.** Adopt **(iv) + design-for-(i)**. Specify the `version(WasmFX)` `Fiber`
  fields: a `cont_slot` (mutable `(ref null $ct)` handle) replacing `m_pmem`/`m_size`/
  `m_ctxt`'s stack-pointer role, plus a reserved handle for a future linear-memory
  shadow root stack. Write the `version(WasmFX)` skeleton at the two `assert(0)` seams
  (`package.d:576-578`, `:1650-1652`) and the `base.d` field/EH `version`-gating plan
  (gate out the `ucontext` fields `base.d:724-731`, `ehContext`/SjLj). Document the
  "no stack-only GC roots across `yield`" restriction.
- **Deliverable.** An ABI spec doc + the `version(WasmFX)` field/skeleton diff (compiles
  but `assert(0)`-bodies remain).
- **Exit criteria.** The shadow-root-stack handoff across the per-`yield` continuation
  rebirth is specified (even if unimplemented); the field layout is reviewed and frozen.
- **Dependencies.** P0 (validated encoding informs the ABI).

### P2 — The `fiber-primitives.wat` module + linking pipeline. _Doable now (after P0/P1)._

- **Objective.** A working `cont.*` toolchain backend with no LLVM change.
- **Tasks.** Author `fiber-primitives.wat` exposing `__fiber_new`/`__fiber_resume`/
  `__fiber_yield`/`__fiber_throw` over `cont.new`/`resume`/`suspend`/`resume_throw` +
  shared imported `$yield`/`$cancel` tags. Define the LDC import surface (the D module
  imports the primitives + tags, re-declares the structural `(cont $ft)`). Resolve the
  cross-module link: try `wasm-ld`; if it rejects `(ref $ct)`-typed imports or shared
  tags, fall back to Binaryen `wasm-merge`. Add a Binaryen finalize/validate step.
- **Deliverable.** A minimal D program that constructs a `Fiber`, `call`/`yield`s once,
  and runs on Wasmtime — **no cross-`yield` GC roots yet, no EH**.
- **Exit criteria.** The merged module validates under Binaryen and runs the call/yield
  round-trip on Wasmtime x64.
- **Dependencies.** P0, P1.

### P3 — The druntime WasmFX `Fiber` backend. _Doable now (after P2)._

- **Objective.** A real `version(WasmFX)` `Fiber` backend behind the public API.
- **Tasks.** Implement `version(WasmFX)` `switchIn`/`switchOut` over the P2 primitives;
  the host-side `cont_slot` bookkeeping and state machine; `reset` → fresh `cont.new`;
  `getThis`/`setThis` over the TLS slot (keep the `pragma(inline,false)` barrier per
  ldc#666); `version`-gate out `ehContext`/SjLj and the `ucontext` fields. Map
  `migrationUnsafe`/`allowMigration` (`base.d:545`,`:566`) to no-ops.
- **Deliverable.** A `Fiber` passing the druntime fiber-test subset that needs neither
  EH nor cross-`yield` GC roots (construct, call, yield, reset, state transitions).
- **Exit criteria.** `Generator`-style produce/consume loops run; `reset`-of-`TERM`
  works; no double-resume traps; the no-stack-only-roots restriction is documented and
  the tests honor it.
- **Dependencies.** P2 (primitives), P1 (ABI).

### P4 — Wasm EH in druntime. _Doable now, parallel and independent._

- **Objective.** Make D `throw`/`catch` work on wasm so `m_unhandled` goes live.
- **Tasks.** Replace the `rt/wasi_exceptions.d` `abort()` stubs with a real
  personality + unwinder over LLVM wasm EH (`int_wasm_throw`/`int_wasm_catch`) /
  `exnref`. Decide `Throwable` ↔ `exnref` vs tagged-EH representation (codegen choice
  tied to how LDC lowers D EH on wasm).
- **Deliverable.** D programs that `throw`/`catch` on wasm without `abort()`; the
  fiber `m_unhandled` capture/rethrow path becomes live.
- **Exit criteria.** The druntime EH test suite passes on wasm; an exception escaping a
  fiber body is captured in `m_unhandled` and rethrown at the `call()` site.
- **Dependencies.** None on stack-switching (LLVM already has the intrinsics). Can run
  **in parallel** with P0–P3.

### P5 — Cancellation + `resume_throw`. _Needs P3 + P4._

- **Objective.** Force-unwind a live fiber, and make `yieldAndThrow` rethrow.
- **Tasks.** Wire `yieldAndThrow`'s `m_unhandled` rethrow (needs P4). Implement
  `reset`-of-live and GC-finalization unwind via
  `resume_throw`/`resume_throw_ref` + `try_table (catch $cancel _)`, running scope
  destructors at the suspension point. Keep the two throw directions distinct
  (`resume_throw` ↔ kill the fiber; `m_unhandled` rethrow ↔ `yieldAndThrow`).
- **Deliverable.** `reset` of a still-`HOLD` fiber runs its pending destructors;
  `yieldAndThrow` rethrows in the resumer.
- **Exit criteria.** A fiber holding RAII state, cancelled mid-body, runs its cleanup;
  `base.d`'s exception-chaining unittest (`base.d:1237-1272`) passes.
- **Dependencies.** P3, P4, plus Wasmtime backtrace-across-suspension maturity.

### P6 — GC general case. _Needs P3._

- **Objective.** Lift the (iv) restriction for arbitrary D code.
- **Tasks.** Implement (i): the linear-memory shadow root stack + the
  spill-cross-`yield`-roots discipline. This likely needs **LDC support** — a
  wasm-specific pass that identifies roots live across a suspend (or a coarse
  "spill all pointer-typed locals live across any may-suspend call" fallback). Register
  the shadow stacks as conservative ranges so the existing scanner reaches them.
- **Deliverable.** Arbitrary D fiber code keeping class refs in locals across `yield`
  is GC-safe.
- **Exit criteria.** A stress test that holds and mutates GC-allocated state across many
  `yield`s, under forced collections, shows no UAF.
- **Dependencies.** P3. (Independent of EH.)

### P7 — Scheduler / symmetric `switch`. _Needs P3._

- **Objective.** A green-thread layer using `switch` for task→task hand-off.
- **Tasks.** Build a `FiberScheduler`/green-thread layer using symmetric `switch`
  (`(on $yield switch)`, recursive `$ct` carrying `(ref null $ct)`) to collapse the
  two-stack-switch asymmetric hand-off to one. Integrate `std.concurrency.Generator`
  (it _is_ `Fiber`-based: `popFront` is `Fiber.call`). Cross-link [green-threads].
- **Deliverable.** A cooperative scheduler over WasmFX fibers; `Generator` iterates on
  wasm.
- **Exit criteria.** A multi-task cooperative workload runs; `Generator`'s
  `empty`/`popFront`/`front` map correctly onto the state machine.
- **Dependencies.** P3.

### P8 — Upstream LLVM `int_wasm_cont_*` intrinsics. _Long-term, blocked-on-upstream._

- **Objective.** Replace the hand-written `.wat` with first-class LDC codegen.
- **Tasks.** Pursue option (a): `int_wasm_cont_new`/`_resume`/`_suspend`/`_switch`/
  `_cont_bind`/`_resume_throw` in `IntrinsicsWebAssembly.td`; a `(ref $ct)` typed
  reference value type; instruction defs + ISel at opcodes `0xe0`–`0xe6`; the
  `(on $e $l)` handler-clause table; `wasm-ld` and validation. Then retarget the
  druntime backend to emit the intrinsics directly.
- **Deliverable.** LDC emits `cont.*` natively; the primitives `.wat` becomes optional.
- **Exit criteria.** The P3 backend works with zero hand-written `.wat`.
- **Dependencies.** Multi-quarter upstream LLVM effort; gated on review cadence.

### Dependency graph and sequencing

| Phase                         | Depends on   | Track                           |
| ----------------------------- | ------------ | ------------------------------- |
| P0 (WAT validation)           | —            | doable now                      |
| P1 (GC/ABI design)            | P0           | doable now (gating)             |
| P2 (`.wat` primitives + link) | P0, P1       | doable now                      |
| P3 (druntime backend)         | P2, P1       | doable now                      |
| P4 (wasm EH)                  | — (parallel) | doable now                      |
| P5 (cancellation)             | P3 + P4      | needs P3+P4                     |
| P6 (GC general)               | P3           | needs P3 (+ likely LDC support) |
| P7 (scheduler / `switch`)     | P3           | doable after P3                 |
| P8 (LLVM intrinsics)          | —            | blocked-on-upstream (long-term) |

Critical path: **P0 → P1 → P2 → P3.** P4 runs in parallel. P5 = P3 + P4. P6 and P7 both
fan out from P3. P8 is the long-term clean-up. This ordering mirrors the survey's
broader dependency framing — stackless coroutines ship on wasm 1.0 first, the stackful
WasmFX backend follows as engines land the Phase-3 feature ([concepts], [roadmap]).

**Doable-now vs blocked-on-upstream.**

- **Doable now (in-repo + existing experimental tools):** P0 (WAT on Wasmtime x64), P1
  (pure druntime/ABI design), P2 (hand-written primitives + Binaryen link — no LLVM
  change), P3 (druntime backend), P4 (wasm EH — LLVM already has the intrinsics), P6/P7
  (modulo the LDC shadow-stack support P6 may need).
- **Blocked-on-upstream:** P8 (LLVM `cont.*` intrinsics/ISel); a Wasmtime API to scan
  suspended continuation stacks for the _fully general_ GC story (mitigation iii);
  engine breadth beyond x64; robust backtraces/unwinding across suspensions
  (Wasmtime#10248 WIP, needed for robust P5).

---

## API and ABI compatibility

The public `Fiber` surface is **unchanged** — every signature in the "API that stays
identical" column above is preserved for source compatibility (Phobos, vibe.d, Photon
all pass `sz`/`guardPageSize`). Specifics:

- **`sz` / `guardPageSize` become advisory.** The engine owns and grows the continuation
  stack; there is no `mmap`'d region and no `PROT_NONE`/`PAGE_GUARD` page to fault on, so
  `guardPageSize` has no meaning and `sz` is at most an initial-size hint. The
  constructor _signatures_ stay (`base.d:327`,`:354`); the parameters are ignored or
  hinted. `defaultStackPages` (`package.d:749`) is advisory.
- **Field changes (localized to `version(WasmFX)`).** `m_pmem`/`m_size` and the
  `m_ctxt` stack-pointer role are replaced by a `cont_slot` handle (+ a reserved
  shadow-root-stack handle); the `ucontext` fields (`base.d:724-731`) are gated out.
- **`migrationUnsafe` / `allowMigration` (`base.d:545`,`:566`) → no-ops.** There is no
  thread-migration story in the wasm baseline (single linear memory, no pthreads), so
  `migrationUnsafe = false`. Keep the `getThis`/`switchIn`/`switchOut`
  `pragma(inline,false)` barriers (ldc#666) as cheap insurance and verify how LLVM
  treats `__tls_base`/global addresses across a `resume`/`suspend`.
- **Footprint.** The entire change is localized to the two `assert(0)` seams
  (`package.d:576-578`, `:1650-1652`) plus the `switchIn`/`switchOut` bodies, plus
  `base.d` field/EH `version`-gating. No public API moves.

---

## Testing and validation

- **Engine.** Wasmtime x64 behind `Config::wasm_stack_switching` is effectively the only
  place D-emitted `cont.*` can run today; treat other arches/engines as future.
- **Reference encodings as oracles.** `generators.wast`, `scheduler1.wast`,
  `scheduler2.wast`, and `scheduler2-throw.wast` are the canonical encodings to diff the
  backend's emitted `.wat` against (cross-module split, one-shot reuse, symmetric
  `switch`, `resume_throw` cancellation).
- **The P0 assumption test.** The cross-module suspend-unwind test (D frames → imported
  `__fiber_yield` → `suspend`) is the gating validation; keep it as a permanent
  regression.
- **The druntime fiber test suite.** Run the existing fiber tests under
  `version(WasmFX)`. Note `fiber_guard_page` (and any guard-page overflow test) **will
  not apply** — there is no guard page; mark it `version`-skipped. Cross-`yield` GC-root
  tests are gated behind P6; until then they honor the (iv) restriction.
- **`std.concurrency.Generator`.** The end-to-end acceptance test: `popFront` ==
  `Fiber.call`, `empty` reads `TERM`, `front` dereferences the yielded value — iterate
  a generator on wasm with no source change.

---

## Risks and open questions

- **The cross-module suspend-unwind assumption is load-bearing.** Whether `suspend`
  inside an imported callee correctly unwinds the D frames above it on the same
  continuation _should_ hold by dynamic handler dispatch (`Explainer.md:644-646`) but
  **must be validated end-to-end** (P0). If it fails, option (c) collapses.
- **GC soundness if (iv) is unenforced.** Ordinary D code freely keeps class refs in
  locals across calls; the "no stack-only roots across `yield`" restriction is a
  soundness hole until P6 (shadow stack) lands or a lint enforces it.
- **Engine maturity.** Wasmtime stack-switching is x64-only, behind a flag,
  experimental (bugs: missing bounds checks #13028, contref-in-array #13021/#13022);
  backtrace-across-suspension is WIP (#10248), which P5 cancellation depends on; the GC
  integration TODOs (#10248) are about wasm-GC, a _different_ GC than D's.
- **LLVM upstream timeline.** Option (a) / P8 is a multi-quarter effort gated on LLVM
  review cadence; the `.wat` bootstrap (c) is the only near-term path.
- **Spec churn.** Stack Switching is Phase 3; instruction details (opcodes, handler
  clauses) may still move before standardization.
- **`wasm-ld` vs `wasm-merge`.** Whether `wasm-ld` accepts `(ref $ct)`-typed imports and
  shared tags, or whether the link must go through Binaryen `wasm-merge`, is unresolved
  (P2 decides).
- **`reset`-of-live destructor semantics.** Re-priming via a fresh `cont.new` simply
  _drops_ the old `cont_slot`; whether the engine runs the dropped continuation's
  destructors on GC, or whether the host must `resume_throw` first to be correct,
  depends on engine semantics (resolve in P5).
- **`Throwable` ↔ `exnref`.** Whether D `Throwable` is reified as a wasm `exnref`
  (→ `resume_throw_ref`) or a tagged EH exception (→ `resume_throw $exn`) is a codegen
  choice tied to how LDC lowers D EH on wasm (resolve in P4).
- **One-shot / shadow-root handoff across the per-`yield` continuation rebirth.** A
  `Fiber` is a sequence of fresh one-shot conts; the shadow root stack (i) must be
  correctly handed off across each rebirth (P1 spec, P6 impl).
- **Component-Model boundary.** Whether a `(ref $ct)` can cross a component boundary is
  unaddressed and a future blocker for componentized D on wasm.

---

## Sources

**LDC v1.42 druntime** (`$REPOS/dlang/ldc`):

- `runtime/druntime/src/core/thread/fiber/base.d` — `FiberBase`, the portable API and
  lifecycle: constructors `:327`/`:354`; `call`/`call!()` `:411`/`:417`, `enum Rethrow`
  `:465`; `yield` `:583`, `yieldAndThrow` `:608`; `reset` `:478`/`:492`/`:499`;
  `enum State` `:511`, `state` `:531`; `getThis`/`setThis`/`sm_this`
  `:642`/`:743`/`:748`; `migrationUnsafe`/`allowMigration` `:545`/`:566`;
  `fiber_entryPoint` `:129-158`; `m_unhandled` capture/rethrow `:144-151`/`:420-428`;
  the `ucontext` fields `:724-731` and SjLj plumbing `:55-119`; the exception-chaining
  unittest `:1237-1272`.
- `runtime/druntime/src/core/thread/fiber/package.d` — the machine backend and the
  dispatch seam: platform→backend ladder `:54-191`; `fiber_switchContext` `:206`/`:395`
  and the WASI stub `:576-578`; `allocStack` `:857`/`:1014`; `freeStack` `:1021`;
  `initStack` `:1054` and the WASI stub `:1650-1652`; constructors `:783`/`:805`;
  `defaultStackPages` `:749`.
- `runtime/druntime/src/core/thread/context.d` — `StackContext` `:17` (the GC scan
  descriptor).
- `runtime/druntime/src/core/thread/threadbase.d` — `ThreadBase.add` `:629`; the
  conservative scan `:1131-1155`; `ehContext` swap `:512`/`:527`.
- `runtime/druntime/src/rt/wasi_exceptions.d` — wasm EH stubbed to `abort()` /
  `_URC_NO_REASON`.

**LLVM 23** (`$REPOS/llvm-project`):

- `llvm/include/llvm/IR/IntrinsicsWebAssembly.td` — **0** stack-switching intrinsics;
  the wasm EH intrinsics `int_wasm_throw` `:132`, `int_wasm_rethrow` `:134`,
  `int_wasm_catch` `:147`, `int_wasm_landingpad_index` `:154`.
- `llvm/lib/Target/WebAssembly/` — no `cont.*` opcodes/ISel; `WebAssembly.td:40`
  (`FeatureExceptionHandling`), `:52` (`FeatureGC`); no `cont`/stack-switching feature.
- `gen/inlineir.cpp:192-193` (`parseAssemblyString`) — inline IR bounded by LLVM IR;
  cannot express `cont.*`.

**WasmFX** (`$REPOS/wasm/stack-switching/proposals/stack-switching`):

- `Explainer.md:248-256` (return-from-cont lands after `resume` in the parent),
  `:644-646` (`suspend` dispatches to the nearest enclosing handler), `:696-700`
  (destructive one-shot consumption), `:906-915` (one-shot/linear continuations).
- `examples/generators.wast:5` (export tag), `:13`/`:90` (import tag), `:143`
  (`cont.new` over an imported funcref) — the cross-module `cont`/tag/handler split.
- `examples/scheduler1.wast`, `scheduler2.wast`, `scheduler2-throw.wast` — asymmetric
  fiber-as-task, symmetric `switch`, and `resume_throw` cancellation oracles.

**External (web, June 2026):**

- [bytecodealliance/wasmtime#10248](https://github.com/bytecodealliance/wasmtime/issues/10248)
  — Stack-switching status: `Config::wasm_stack_switching`, x64-only, experimental; GC
  TODOs; backtraces-across-suspensions WIP.
- [Binaryen CHANGELOG](https://github.com/WebAssembly/binaryen/blob/main/CHANGELOG.md) —
  v122 "'typed-continuations' renamed 'stack-switching' … experimentally supported";
  v124 "Add Stack Switching support".
- [WebAssembly/proposals](https://github.com/WebAssembly/proposals) — Stack Switching =
  Phase 3 (champions McCabe & Lindley); separate from Wasm 3.0.
- ldc-developers/ldc#666 — TLS-address caching across a fiber context switch.

<!-- References -->

[concepts]: ../concepts.md
[wasm]: ../wasm-and-wasmfx.md
[stackful-index]: ./index.md
[d-fiber]: ./d-fiber.md
[wasmfx-target]: ./wasmfx-as-target.md
[green-threads]: ./green-threads.md
[roadmap]: ../stackless/roadmap.md
[wasmfx]: ../../algebraic-effects/wasmfx.md
