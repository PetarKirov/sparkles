# Function Attributes and the Coroutine Frame

How D's function-attribute system (`@nogc`, `@safe`, `nothrow`, `pure`, `scope`, `-betterC`) interacts with the _memory_ of a stackless coroutine frame. The thesis of this doc is a single observation: **a coroutine frame is a closure that always escapes** — it must outlive the function that created it so it can be resumed later — so the frontend's _existing_ closure-attribute rules predict the entire coroutine-attribute story before a line of new code is written. From that observation we derive what breaks, the grounded escape hatches (stack elision / HALO, custom allocators), the `@safe`/`scope`/DIP1000 escape-analysis story across suspends, the C++20 exception-free customization points as the design template for a `@nogc nothrow` D coroutine, and the wasm exception-handling caveat that forces a no-EH ABI shape as the first realistic target. It closes with a decision table mapping frame-allocation strategies against attribute regimes.

**Last reviewed:** June 4, 2026

---

## 1. The governing insight: the frame is a closure that always escapes

D's frontend already computes, per function, exactly the data a coroutine frame needs: which locals are referenced from a nested scope (`FuncDeclaration.closureVars`, `func.d:309` — "local variables in this function which are referenced by nested functions (They'll get put into the 'closure')"), and whether those captures force a heap frame (`requiresClosure` / `needsClosure`, decision at `funcsem.d:3264`). The `needsClosure` rules say a heap closure is required when the captured variables are referenced by a function that _escapes_ — the doc comment lists the conservative triggers:

> "1) is a virtual function 2) has its address taken 3) has a parent that escapes 4) calls another nested function that needs a closure"

with the concrete escape trigger being `fx.isThis() || fx.tookAddressOf` (`funcsem.d:3318`). When the nested function does **not** escape, the frame is stack-allocated; when it does, it is heap-allocated.

A stackless coroutine frame holds "everything that must survive across suspends" — the live locals, the resume-index, and (for a C++20-shaped surface) the promise. By construction it **outlives the call that created it**: the ramp function returns a handle/generator object while the coroutine is suspended, and the consumer resumes it later. That is precisely the escape condition. So under today's rules a coroutine frame would always take the "escapes → heap" path — and a GC heap frame is exactly what the attribute checker is built to reject in `@nogc`/`-betterC` code. The closure machinery is therefore not just the _implementation_ analog of a coroutine frame (see [the LDC codegen survey][ldc-codegen] for `gen/nested.cpp`'s `_d_allocmemory`-vs-`alloca` split); it is also the _attribute-rule oracle_ for it.

> [!IMPORTANT]
> Everything in this doc follows from that one equivalence. "What does `@nogc` do to a coroutine?" is answered by "what does `@nogc` do to a closure that escapes?" — and the frontend already answers that, with hard errors, in `checkClosure`.

For the broader design space (where coroutine lowering lives, surface syntaxes, the `_d_*` hook precedent) see [the D language-design survey][d-design]; for the stackful baseline these attributes contrast against see [the Fiber baseline][d-fiber].

---

## 2. `@nogc` × closure: the check that predicts everything

The governing check is `checkClosure` (`semantic3.d:1850`), called from `semantic3.d:1329`. It runs `needsClosure()` and, if a closure is needed, routes through `setGC`:

```d
extern (D) bool checkClosure(FuncDeclaration fd)
{
    if (!fd.needsClosure())
        return false;

    if (setGC(null, fd, fd.loc, "allocating a closure for `%s()`", fd))
    {
        .error(fd.loc, "%s `%s` is `@nogc` yet allocates closure for `%s()` with the GC", fd.kind, fd.toPrettyChars(), fd.toChars());
        ...
    }
    else if (!global.params.useGC)
    {
        .error(fd.loc, "%s `%s` is `-betterC` yet allocates closure for `%s()` with the GC", fd.kind, fd.toPrettyChars(), fd.toChars());
        ...
    }
    else
    {
        fd.printGCUsage(fd.loc, "using closure causes GC allocation");
        return false;
    }
    ...
}
```

(verbatim, `semantic3.d:1850-1871`). There are three outcomes, and a default GC-heap coroutine frame inherits all three:

| Regime             | Outcome for an escaping closure / GC-heap coro frame                        | Cite               |
| ------------------ | --------------------------------------------------------------------------- | ------------------ |
| `@nogc` function   | **hard error**: "is `@nogc` yet allocates closure for `…()` with the GC"    | `semantic3.d:1858` |
| `-betterC` (no GC) | **hard error**: "is `-betterC` yet allocates closure for `…()` with the GC" | `semantic3.d:1864` |
| plain GC code      | `vgc` advisory: "using closure causes GC allocation" (with `-vgc`)          | `semantic3.d:1870` |

`setGC` is the single chokepoint. The free function (`nogc.d:326`) either errors (when the function `isNogc()`) or, during attribute _inference_, flips the function off `@nogc`:

```d
if (fd.nogcInprocess)
{
    fd.nogcInprocess = false;
    if (fmt)
        fd.nogcViolation = new AttributeViolation(loc, fmt, args);
    ...
    fd.type.toTypeFunction().isNogc = false;
    if (fd.fes)
        sc.setGC(fd.fes.func, Loc.init, null, null);
}
else if (fd.isNogc())
    return true;
```

(`nogc.d:348-364`). The `NOGCVisitor.setGC` member emits the general GC-allocation message form — "`%s causes a GC allocation in @nogc %s %s`" (`nogc.d:107`) — and `new`, array literals, `~`/`~=`, AA literals and `arr.length =` all route through it (`nogc.d:190`, `136`, `241`/`236`, `171`, `125`/`223`). A GC-heap coroutine frame allocated through `_d_allocmemory` (the same call `gen/nested.cpp` already uses for escaping closures — see [ldc-codegen][ldc-codegen] §3.2) is identical in the eyes of this checker.

> [!WARNING]
> **Prediction: a default GC-heap coroutine frame breaks `@nogc` and `-betterC`.** The frame is an escaping closure; `checkClosure`/`setGC` will reject it exactly as they reject an escaping nested-function closure today. To get a `@nogc` (or `-betterC`) coroutine, the lowering _must not_ GC-allocate the frame. The next two sections are the grounded ways out.

This is not a hypothetical: it is the same machinery that already makes a `@nogc` function containing an escaping lambda fail to compile. The coroutine design inherits the rule for free — and the diagnostic, helpfully, already names "closure".

---

## 3. Escape hatch #1 — scope / stack-elided frames (HALO)

The first way to keep a coroutine out of the GC is the one the frontend _already_ uses for non-escaping nested functions: when the closure provably does not outlive its creator, the frame is `alloca`'d on the caller's stack instead of heap-allocated. `gen/nested.cpp` selects this by querying `needsClosure` — heap via `_d_allocmemory` when `true`, `DtoRawAlloca` when `false` (see [ldc-codegen][ldc-codegen] §3.2). Stack memory is not GC memory, so a stack-elided frame sails past `checkClosure`.

The wrinkle is that a coroutine _fundamentally suspends and resumes later_, so true stack allocation is only valid when the compiler can prove the coroutine is **fully created, consumed, and destroyed within the enclosing scope**. That is exactly the condition LLVM's heap-allocation-elision optimization (HALO) checks for, and LLVM exposes it through the coroutine alloc/free intrinsic protocol so the allocation can be removed:

> "There is a somewhat complex protocol of intrinsics for allocating and deallocating the coroutine object. It is complex in order to allow the allocation to be elided due to inlining." (`Coroutines.rst:115-118`)

The elidable pattern and its precondition (both verbatim from the .rst, quoted in [the C++ coroutine survey][cpp] §3):

> "where a coroutine is created, manipulated and destroyed by the same calling function … is suitable for allocation elision optimization which avoid dynamic allocation by storing the coroutine frame as a static `alloca` in its caller." (`Coroutines.rst:408-413`)

The mechanism is `llvm.coro.alloc` returning **false** (no dynamic allocation needed) and `llvm.coro.free` returning **null** (nothing to free), substituted by the `CoroElide` pass once the ramp function is inlined into the caller (`Coroutines.rst:1227-1228`, `1135-1137`, `2216-2224`; see [cpp][cpp] §3.2–3.3 and [the LLVM coroutine intro][llvm-coroutines] for the elision path). The D frontend's obligation is only to **emit the full alloc/free protocol rather than a hard `malloc`**, and to keep the ramp inline-able.

This is not foreign to D — the frontend has two precedents for _forcing_ or _eliding_ a closure based on escape:

- **`lazy ⇒ scope`.** A `lazy` parameter is converted to a delegate at the call site (`expressionsem.d:3609`) and is treated as `scope` for escape purposes ("Allow 'lazy' to imply 'scope'", `expressionsem.d:3629-3648`). A non-escaping thunk does not force a heap closure — the same logic a `scope` coroutine wants.
- **DIP1000 `opApply` closure elision.** `applyOpApply` _increments_ `tookAddressOf` under DIP1000 to force a closure unless the `opApply` takes its delegate `scope` (`statementsem.d:3844-3845`), with the user-facing message:

```d
message(loc, "To enforce `@safe`, the compiler allocates a closure unless `opApply()` uses `scope`");
```

(`statementsem.d:3838`, verbatim). The contrapositive is the elision precedent: when the callee promises `scope`, no heap frame is allocated. A `scope` coroutine whose frame provably does not escape the enclosing scope is the same deal — and `nogc.d` already skips the GC check for stack-placed `new` (`if (e.onstack) return;`, `nogc.d:185`).

> [!NOTE]
> Stack elision is the **`@nogc`/`-betterC`-friendly default** when it applies — a generator consumed by a `foreach` in the same function, a task `co_await`ed and dropped in-scope. But it only applies when the consumer's lifetime is statically bounded by the producer's. The moment a coroutine handle is stored, returned, or passed to a scheduler that outlives the call, HALO cannot fire and the frame must live somewhere heap-shaped — which is escape hatch #2.

---

## 4. Escape hatch #2 — a custom (non-GC) frame allocator

When the frame genuinely escapes the creating scope (the common case for tasks handed to an event loop), stack elision is unavailable, so the frame must be heap-allocated — but **heap does not have to mean GC**. Routing the frame allocation through a user-supplied or `@nogc` runtime allocator means a `@nogc` coroutine function never touches the GC, so `checkClosure`/`setGC` never fire.

The precedent is in `nogc.d` itself: the GC checker deliberately skips a `new` whose allocation is performed by a separate allocator:

```d
if (nogcExceptions && e.thrownew)
    return;                     // separate allocator is called for this, not the GC
```

(`nogc.d:187-188`, the `NewExp` visitor). The companion case — a `NewExp` with a non-`@nogc` `e.member` — is checked in `NewExp::semantic` rather than here (`nogc.d:180-184`: "`@nogc`-ness is already checked in `NewExp::semantic`"). The principle generalizes: when the allocation is the responsibility of an explicit, attribute-checked allocator, the GC check yields.

On the LDC side this maps onto the coroutine alloc protocol cleanly. CoroSplit computes the frame size (`llvm.coro.size`) and the ramp branches on `llvm.coro.alloc`; the "yes, allocate" arm calls **whatever function the frontend names**. The default could be the GC (`_d_allocmemory`, breaking `@nogc`), but a `@nogc` coroutine would instead emit a call to a dedicated hook (e.g. `_d_coro_alloc` / `_d_coro_free`, or a user allocator threaded through the promise) — registered in `gen/runtime.cpp` exactly as `_d_allocmemory` is (see [ldc-codegen][ldc-codegen] §4, which sketches this `coro.id → coro.size → coro.alloc → _d_coro_alloc → coro.begin` path). Because the frontend chooses the allocator symbol, a `@nogc` signature simply selects a `@nogc` one.

The C++20 model anticipated this precisely: the promise type may define its own `operator new` / `operator delete` for custom frame allocation (`n4775:562-570`, `628-636`; see [cpp][cpp] §1.3). A D promise can do the same — expose an allocator the coroutine machinery calls instead of the GC. This is the cleanest bridge between "the frame must escape" and "the function is `@nogc`": neither stack elision nor the GC is involved.

| Frame strategy                                     | GC touched? | `@nogc` | `-betterC` | When applicable                         |
| -------------------------------------------------- | ----------- | ------- | ---------- | --------------------------------------- |
| GC heap (`_d_allocmemory`, default)                | yes         | breaks  | breaks     | always (default)                        |
| Stack-elided / HALO (`coro.alloc`→false)           | no          | works   | works      | created+consumed in-scope, ramp inlined |
| Custom allocator (`_d_coro_alloc` / promise `new`) | no          | works   | works      | frame escapes but allocator is `@nogc`  |

---

## 5. `@safe`, `scope`, and DIP1000: escape analysis across suspends

`@nogc` governs _where the frame lives_; `@safe`/`scope`/DIP1000 govern _what the frame may capture_ and whether those captures can dangle. A stackless coroutine introduces a new dangling axis that ordinary closures lack: a captured `ref` or `scope` reference must remain valid **across a suspend**, i.e. across the gap between when the coroutine yields and when it is resumed — potentially after the referent's scope has exited.

The frontend already has the analysis and the enforcement lever. The DIP1000 `applyOpApply` pattern (§3) is the direct model: under `-preview=dip1000` the compiler _forces a heap closure_ to keep a captured reference from dangling, trading `@nogc` for `@safe` ("To enforce `@safe`, the compiler allocates a closure unless `opApply()` uses `scope`", `statementsem.d:3838`). A `@safe` stackless coroutine faces the same tension and resolves it the same way: either the captured reference is provably `scope`-bounded by the coroutine's own lifetime, or the value must be _copied into the frame_ (reified) so the frame owns it and nothing dangles.

The escape-analysis machinery is `escape.d`, reached for argument captures via `checkParamArgumentEscape` (called from `expressionsem.d:3641`, in the same `lazy`/`scope` handling region). For coroutines this analysis must extend its notion of "lifetime" from "the call" to "until the frame is destroyed":

- A **by-value** capture is copied into the frame and is always safe across suspends (this is what C++20 does — "a copy is created for each coroutine parameter … with automatic storage duration … The lifetime of parameter copies ends immediately after … the coroutine promise object ends", `n4775:642-650`, quoted in [cpp][cpp] §1.2).
- A **`ref`/`scope`** capture is only safe across a suspend if its referent outlives the frame. Under `-preview=dip1000`, that is the kind of obligation the compiler can either prove (the reference is `return scope` / bounded) or reject. Where it cannot prove safety, the `@safe` rules force reification into the frame (the closure-allocation-for-safety pattern), which may in turn cost `@nogc` if the reification needs heap — the same `@safe`-vs-`@nogc` trade `applyOpApply` already exposes.

> [!WARNING]
> The hard case is a `scope`-qualified value captured by a coroutine that suspends and is resumed _after_ the scope that owns the value has exited. Ordinary closures can sometimes prove this away because the delegate is called synchronously within scope; a coroutine cannot, because resumption is by definition deferred. A `@safe` coroutine design must treat across-suspend `scope`/`ref` captures conservatively — copy into the frame, or require `return scope` lifetime bounds — and lean on the existing `escape.d` plumbing rather than inventing a new analysis.

The `-preview=in` / DIP1000 preview flags the Sparkles codebase already enables make this stricter, not looser: `in` parameters become `scope const`, so a coroutine capturing an `in` parameter across a suspend is exactly the case that needs frame reification.

---

## 6. `pure`, `nothrow`, and exceptions across a suspend

### 6.1 Attribute propagation into the synthesized body

A coroutine lowering synthesizes a body (and resume/destroy helpers); their attributes are bounded by the declared signature through `mergeFuncAttrs` (`clone.d:54`), the same routine the `foreach`→delegate lowering uses (`statementsem.d:4116`, `mergeFuncAttrs(STC.safe | STC.pure_ | STC.nogc, fs.func)`). It **intersects** `pure`/`nothrow`/`@nogc` and **unions** `@disable`, so a coroutine body can be at most as `pure`/`nothrow`/`@nogc` as its enclosing signature — and the synthesized resume/destroy helpers inherit accordingly. There is no way for the lowering to silently _gain_ attributes the user did not declare.

### 6.2 `nothrow` and frame allocation

`nothrow` interacts with the _allocation_, not just the body. Today an escaping closure does not violate `nothrow` on allocation because the GC allocator is itself `nothrow`: `_d_allocmemory` is declared `nothrow` (it is the GC-alloc call `gen/nested.cpp` uses, and the whole `ldc.intrinsics` surface around it is `nothrow @nogc`). So a `nothrow` coroutine whose frame is GC-allocated does not break `nothrow` on the allocation step — only on `@nogc`. A custom `_d_coro_alloc` hook (§4) would need to be `nothrow` too (or report failure out-of-band) to preserve the attribute; the C++20 model's `get_return_object_on_allocation_failure` is the design template for exactly this nothrow-allocation-failure path (§7).

### 6.3 Carrying an in-flight exception across a suspend

The deeper question is an exception that is _live across_ a suspend point. C++20 handles this by wrapping the user body in `try { F } catch(...) { p.unhandled_exception(); }` (`n4775:537-543`; see [cpp][cpp] §1.2), so an escaping exception is routed to a promise method rather than unwinding through the suspend machinery. A D coroutine needs the analogous discipline. Two D features bear on it:

- **DIP1008** (`-preview=dip1008`, `sc.previews.dip1008`, surfaced in `nogc.d` as `gcv.nogcExceptions = sc.previews.dip1008`) makes thrown exceptions `@nogc`-allocatable — the `if (nogcExceptions && e.thrownew) return;` skip in `nogc.d:187-188` is precisely the DIP1008 path ("separate allocator is called for this, not the GC"). A `@nogc` coroutine that may carry an exception across a suspend wants this: the exception object lives in (or alongside) the frame and is allocated without the GC.
- **`nothrow`** coroutines simply cannot have a live exception cross a suspend, so the `unhandled_exception`-equivalent slot can be omitted entirely — a strictly simpler frame.

The unwind machinery itself is EH-aware on the LLVM side: `llvm.coro.resume` and `llvm.coro.destroy` are typed `[Throws]` (`Intrinsics.td:1941-1942`, verbatim):

```text
def int_coro_resume : Intrinsic<[], [llvm_ptr_ty], [Throws]>;
def int_coro_destroy : Intrinsic<[], [llvm_ptr_ty], [Throws]>;
```

so LDC's `callOrInvoke` will correctly emit them as `invoke`s inside try/catch scopes (see [ldc-codegen][ldc-codegen] appendix). That EH-awareness is a feature on native targets — and a problem on wasm (§8).

---

## 7. The C++20 exception-free customization points as the `@nogc nothrow` template

N4134 (Nishanov) made one of its explicit design goals "Usable in environments where exception are forbidden" (`n4134:131`), and the resulting customization points are a near-exact blueprint for a `@nogc nothrow` D coroutine that reports failure through `Expected!(T, E)` rather than the GC and exceptions. Three points matter (all from [cpp][cpp] §5.5):

| C++20 customization point                                      | What it provides                                                                                                                                                                   | D analog                                                                                                                                          |
| -------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `get_return_object_on_allocation_failure()` (static, optional) | nothrow alloc-failure path; selects `operator new(size_t, nothrow_t)` so frame allocation failure returns a "broken" object instead of throwing (`n4775:571-578`; `n4134:944-965`) | a `nothrow` `_d_coro_alloc` that returns null → promise yields `err!E(...)` instead of throwing                                                   |
| `await_suspend` returning `bool false`                         | abort a launch without an exception: the coroutine is immediately resumed instead of suspended (`n4134:1023-1039`; semantics `n4775:279`)                                          | a D awaiter whose `awaitSuspend` returns `bool false` → no suspend, no throw; LDC lowers via `llvm.coro.await.suspend.bool` (see [cpp][cpp] §4.3) |
| generalized `set_exception(E)` over arbitrary error types      | report failure as a value of _any_ error type, not just `std::exception` (`n4134:971-976`)                                                                                         | route the failure into an `Expected!(T, E)` carried by the promise — no `Throwable`, no GC                                                        |

These three together let a coroutine express the full create → suspend → fail → consume lifecycle without ever allocating with the GC or throwing. That maps directly onto the Sparkles `@nogc nothrow` + `Expected!(T, E)` idiom: a D promise's `getReturnObject`/`yieldValue`/`returnValue` can produce and consume `Expected` values, an allocation-failure hook returns `err!E`, and an awaiter aborts a launch by returning `false`. The exception-free C++20 path is not a fallback in this design — it _is_ the `@nogc nothrow` D coroutine. (See [cpp][cpp] §5.5–6 for the full promise/awaiter shape and §6 for the synthesis notes.)

> [!NOTE]
> This is the single strongest argument that stackless coroutines fit D's `@nogc nothrow -betterC` corner at all: the canonical C++20 model was _deliberately designed_ to work without exceptions or mandatory heap allocation, the LLVM intrinsics encode those exact return-type variants (`coro.await.suspend.{void,bool,handle}`), and D's `Expected` error model slots into the customization points where C++ would use `std::exception_ptr`.

---

## 8. The EH-on-wasm caveat: the first realistic target is a no-EH ABI shape

The exception machinery that works on native targets is **stubbed on LDC-wasm**, which constrains the first coroutine target. `rt/wasi_exceptions.d` does not implement D exceptions — it aborts:

```d
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

(`rt/wasi_exceptions.d:1-20`, verbatim). Combined with the fact that `llvm.coro.resume`/`llvm.coro.destroy` are `[Throws]` (§6.3) and LLVM's coroutine cleanup machinery is unwind-aware, this means **full D-exception interop across suspend points is not available on wasm today** — it would need wasm EH (the WebAssembly exception-handling proposal) wired into druntime first, which the stubs above show is not done.

The consequence for sequencing is decisive and convergent with §2–§7:

- On **wasm**, the realistic first coroutine target is a **no-EH ABI shape**: `@nogc nothrow` coroutines whose frames are either stack-elided or allocated through a non-GC hook, reporting failure via `Expected!(T, E)` (§7) rather than thrown exceptions. This needs no wasm EH and no GC.
- That is the _same_ shape that `@nogc` and `-betterC` demand on native targets (§2–§4). The constraints reinforce rather than conflict: the no-EH, no-GC coroutine is portable across the `@nogc`/`-betterC`/wasm corner simultaneously.

Stackless coroutines are also the _only_ route to D coroutines on wasm at all: the stackful `Fiber` simply `assert(0, "Fibers not supported on WASI")`s (see [the Fiber baseline][d-fiber]), and a stackless state-machine frame in linear memory needs no native stack to swap. The full wasm/WasmFX target analysis — including why the stackless `SwitchABI` frame is the near-term path and WasmFX stack-switching a later glue/backend swap — is in [the wasm survey][wasm].

> [!IMPORTANT]
> Design the first D coroutine ABI for the intersection of `@nogc`, `nothrow`, `-betterC`, and wasm: **no GC frame, no thrown exceptions across suspends, failures as `Expected` values.** This corner is the most constrained, and a coroutine that fits it fits everywhere; relaxing later (GC frames, EH interop) is additive. The [roadmap][roadmap] sequences this.

---

## 9. Decision table: frame strategy × attribute regime

Putting it together. Rows are the four frame-allocation strategies; columns are the attribute/target regimes. "works" = compiles and runs in that regime; "breaks" = the frontend rejects it (or it cannot run there); "conditional" = depends on the analysis succeeding.

| Frame strategy                                           | `@nogc`                                                          | `@safe`                                                       | `nothrow`                                                                  | `-betterC`                                                                            | wasm (today)                                                                                  |
| -------------------------------------------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| **Default GC frame** (`_d_allocmemory`)                  | **breaks** — `checkClosure`/`setGC` error (`semantic3.d:1858`)   | conditional — captures must not dangle across suspend (§5)    | works — `_d_allocmemory` is `nothrow` (§6.2)                               | **breaks** — "is `-betterC` yet allocates closure … with the GC" (`semantic3.d:1864`) | conditional — GC frame needs a GC (broadly unavailable on wasm); EH on resume/destroy stubbed |
| **Scope / stack-elided (HALO)**                          | **works** — `alloca`, no GC (`coro.alloc`→false, §3)             | conditional — same across-suspend escape analysis (§5)        | works                                                                      | **works** — no GC allocation                                                          | works — no GC, no EH needed; requires ramp inlined + in-scope consume                         |
| **Custom allocator** (`_d_coro_alloc` / promise `new`)   | **works** — non-GC allocator, GC check yields (`nogc.d:187`, §4) | conditional — captures still subject to §5                    | conditional — allocator must be `nothrow` (else report via `Expected`, §7) | **works** — no GC                                                                     | works — allocator can be a WASI/linear-memory hook                                            |
| **No-EH `betterC` shape** (`@nogc nothrow` + `Expected`) | **works**                                                        | conditional — by-value capture/reification keeps it safe (§5) | **works** — no thrown exceptions; failure via `Expected` (§7)              | **works**                                                                             | **works** — the recommended first wasm target (§8)                                            |

Reading the table top-to-bottom is the migration path: the default GC frame is the easiest to emit but the most constrained; stack elision and custom allocators recover `@nogc`/`-betterC`; the no-EH `betterC` shape is the portable intersection that also unlocks wasm. The `@safe` column is "conditional" throughout because escape analysis across suspends (§5) is orthogonal to _where the frame lives_ — a `@safe` coroutine in any row must still prove its `ref`/`scope` captures do not dangle across a suspend, or reify them into the frame.

---

## Sources

**LDC frontend (vendored DMD), v1.42** — `$REPOS/dlang/ldc/dmd/`:

- `semantic3.d:1850-1871` — `checkClosure`: the `@nogc`/`-betterC` "allocates closure … with the GC" hard errors and the `vgc` advisory; caller at `semantic3.d:1329`.
- `nogc.d:96/107` — `NOGCVisitor.setGC` and the "causes a GC allocation in `@nogc`" message; `nogc.d:180-188` — `NewExp` visitor, `e.onstack` skip and the DIP1008 "separate allocator is called for this, not the GC" skip; `nogc.d:326/348-364` — the free `setGC`, inference flipping `isNogc = false`.
- `funcsem.d:3264/3318` — `needsClosure` decision and the `isThis()||tookAddressOf` escape trigger; `func.d:309` — `closureVars`; `func.d:304` — `requiresClosure`.
- `clone.d:54` — `mergeFuncAttrs` (intersect `pure`/`nothrow`/`@nogc`, union `@disable`); used at `statementsem.d:4116`.
- `statementsem.d:3838/3844-3845` — `applyOpApply` DIP1000 closure-forcing message and `tookAddressOf` bump.
- `expressionsem.d:3609/3629-3648/3641` — `lazy`→delegate, "Allow 'lazy' to imply 'scope'", `checkParamArgumentEscape`; `escape.d` (escape analysis).

**LDC glue & runtime** — `$REPOS/dlang/ldc/`:

- `gen/nested.cpp` — `_d_allocmemory`-vs-`alloca` closure frame allocation (analyzed in [ldc-codegen][ldc-codegen]).
- `runtime/druntime/src/rt/wasi_exceptions.d:1-20` — EH stubbed out (abort) on wasm/WASI.

**LLVM 23.0.0git** — `$REPOS/llvm-project/`:

- `llvm/include/llvm/IR/Intrinsics.td:1941-1942` — `int_coro_resume`/`int_coro_destroy` typed `[Throws]`.
- `llvm/docs/Coroutines.rst:115-118, 408-413, 1135-1137, 1227-1228, 2216-2224` — the alloc/free elision protocol, the HALO-elidable pattern, `CoroElide`.

**C++ papers** — `$REPOS/papers/`:

- N4134 (Nishanov, Radigan, "Resumable Functions v.2") — exception-free design goals (`n4134:131`), `get_return_object_on_allocation_failure` (`n4134:944-965`), `await_suspend`→`bool false` (`n4134:1023-1039`), generalized `set_exception` (`n4134:971-976`).
- N4775 (Coroutines TS) — synthesized body rewrite (`n4775:537-543`), parameter copies into the frame (`n4775:642-650`), promise `operator new`/`operator delete` (`n4775:562-570, 628-636`), `await_suspend` `bool false` semantics (`n4775:279`).

<!-- References -->

[d-design]: ./d-language-design.md
[ldc-codegen]: ./ldc-codegen.md
[cpp]: ./cpp-coroutines.md
[llvm-coroutines]: ./llvm-coroutines.md
[wasm]: ./wasm-and-wasmfx.md
[d-fiber]: ./d-fiber-baseline.md
[roadmap]: ./roadmap.md
