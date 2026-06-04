# The D Language & Frontend Design Space for Stackless Coroutines

D has **no coroutine syntax today** — the only "coroutine" story is the stackful
[`core.thread.Fiber`][d-fiber] and the `std.concurrency.Generator` built on it. Yet
the shared DMD frontend (vendored into LDC at `dmd/`) already contains _every
mechanism_ a stackless lowering needs: loop-body→delegate conversion, arg→delegate
conversion, statement→nested-function conversion, the closure/frame-struct machinery,
and an established habit of lowering language constructs to `object._d_*` druntime
templates. This document maps those precedents onto a coroutine design, argues _where_
in the DMD-frontend-vs-LDC-glue split a stackless lowering should live, and sketches
three concrete D surface syntaxes onto the [`llvm.coro.*`][llvm-coroutines] family.
It is the language-design counterpart to the [C++20 model digest][cpp] (the surface
template) and the [cross-compiler comparison][comparison] (Option A vs Option B).

**Last reviewed:** June 4, 2026

---

## 1. The thesis: no syntax, but every mechanism

The frontend's job is to turn typed source into a checked AST plus per-function
metadata; LDC's glue (`gen/`) then emits LLVM IR. Adding stackless coroutines is not a
from-scratch endeavour because four existing transformations are, structurally, _partial
coroutine lowerings already_:

| Existing transform                                     | What it does                                                                               | Coroutine analogue                                                     |
| ------------------------------------------------------ | ------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------- |
| `foreach`/`opApply` body → delegate (§2.1)             | turns a loop body into a resumable callable + an integer control-code state machine        | "turn user code into a resumable function dispatched by a state index" |
| range `foreach` → `for` (§2.2)                         | pure AST desugar emitting `.empty`/`.front`/`.popFront` calls                              | the _consumer_ side of a generator (`InputRange`)                      |
| `lazy` param → delegate (§2.3)                         | converts an _expression argument_ into a thunk; `lazy` implies `scope`                     | a `yield`/`await` _expression_ that becomes a suspend point            |
| `scope(exit/failure)` → try/finally + nested fn (§2.4) | reifies cleanup bodies as nested functions to keep control flow tractable across unwinding | locals live across a suspend must be reified into the coroutine frame  |
| nested fn → frame struct (§2.5)                        | computes `closureVars`, `needsClosure`; heap- vs stack-allocates the frame                 | a coroutine frame _is_ a closure whose lifetime outlives its creator   |
| language construct → `object._d_*` (§2.6)              | portable frontend lowers `new`/`~`/`arr.length=` to druntime templates                     | a backend-neutral `object._d_coro*` lowering target                    |

> [!NOTE]
> "D has no coroutine syntax today" is verified: a `grep` across the spec, changelog,
> and DIPs of the `dlang.org` tree for `coroutine|stackless|yield expression|async`
> returns nothing but the _Fiber tutorial_ (`book/d.en/fibers.d`) and
> `std.concurrency`. Stackless coroutines are unspecified greenfield for D (§6).

Meanwhile LLVM 23 already ships the full [`llvm.coro.*`][llvm-coroutines] intrinsic
family and wires the coroutine passes (`CoroEarlyPass`, `CoroSplitPass`,
`CoroCleanupPass`, `CoroElidePass`) into the default per-module pipeline that LDC
builds — so emitting coroutine intrinsics from LDC requires _no new pass registration_.
The full plumbing trail lives in [the codegen doc][ldc-codegen]; here we focus on the
_language_ design.

---

## 2. Frontend lowering precedents (the heart)

This is the load-bearing section. Each subsection quotes the existing frontend code
that already performs a coroutine-shaped transformation. Line numbers cite the vendored
LDC copy `dmd/`; the standalone DMD tree is byte-similar.

### 2.1 `foreach`/`opApply` body → delegate — the closest analogue

`foreach` over a struct/class with `opApply`, over a delegate, or over an array _lowers
the loop body into a synthesized nested function/delegate_, then calls an applier with
that delegate. This is exactly the "turn a block of user code into a resumable callable"
transformation a generator lowering needs. `statementsem.d:4044`
`foreachBodyToFunction` builds the delegate:

```d
private FuncExp foreachBodyToFunction(Scope* sc, ForeachStatement fs, TypeFunction tfld)
{
    ...
    STC stc = mergeFuncAttrs(STC.safe | STC.pure_ | STC.nogc, fs.func);
    auto tf = new TypeFunction(ParameterList(params), Type.tint32, LINK.d, stc);
    fs.cases = new Statements();
    fs.gotos = new ScopeStatements();
    auto fld = new FuncLiteralDeclaration(fs.loc, fs.endloc, tf, TOK.delegate_, fs);
    fld.fbody = fs._body;                  // <-- loop body becomes the delegate body
    Expression flde = new FuncExp(fs.loc, fld);
    flde = flde.expressionSemantic(sc);
    fld.tookAddressOf = 0;
    ...
    return flde.isFuncExp();
}
```

Two facts here are _directly_ the coroutine state-machine pattern:

- **The synthesized delegate returns `int`** — a control-flow code (0 = continue,
  nonzero = break/return with a value). `fs.cases`/`fs.gotos` are populated so that
  `break`/`continue`/`return`/labelled-`goto` inside the body are rewritten into
  returning distinct integer codes, and the _caller side dispatches on them_. This is a
  hand-rolled state machine over a single suspend point; a stackless coroutine
  generalizes it to _N_ suspend points with a frame-resident resume index. (Compare the
  switched-resume `llvm.coro.suspend` whose `i8` result `switch`es to
  resume/destroy/suspend — [the C++ digest's §4.6][cpp] worked example.)
- **Attribute inference flows from the enclosing function via `mergeFuncAttrs`**
  (`statementsem.d:4116`):
  ```d
  STC stc = mergeFuncAttrs(STC.safe | STC.pure_ | STC.nogc, fs.func);
  ```
  `mergeFuncAttrs` is defined at `clone.d:54` (`STC mergeFuncAttrs(STC s1, const
FuncDeclaration f) pure @safe`): it _ANDs_ `pure`/`nothrow`/`@nogc` and _ORs_
  `@disable`, i.e. the delegate is no more attributed than its enclosing function. This
  is the precedent for how a coroutine body's attributes (and its synthesized
  resume/destroy helpers) would be derived. The `@nogc`-vs-heap-frame consequences are
  worked out in [the attributes & memory doc][attributes].

The applier-dispatch side (`statementsem.d`) shows the three lowering _strategies_ the
frontend already mixes per construct:

- `applyOpApply` (`statementsem.d:3831`): rewrites to `aggr.apply(flde)`. Crucially it
  bumps `tookAddressOf` under DIP1000 to _force a closure allocation_ unless `opApply`
  takes the delegate `scope` (`statementsem.d:3844`):
  ```d
  if (sc2.useDIP1000 == FeatureState.enabled)
      ++flde.isFuncExp().fd.tookAddressOf;  // allocate a closure unless the opApply() uses 'scope'
  ```
  with the disabled-branch message _"To enforce @safe, the compiler allocates a closure
  unless opApply() uses scope"_. This "force a heap frame to keep a captured reference
  from dangling" pattern is exactly the `@safe`-vs-`@nogc` tension a `@safe` coroutine
  frame faces (see [attributes][attributes]).
- `applyDelegate` (`statementsem.d:3866`): `aggr(flde)` for `foreach` over a delegate.
- `applyArray` (`statementsem.d:3892`): rewrites to a _druntime helper_ `_aApplyXX`
  (name built from the element/value char widths, `fntab = ["cc","cw","cd", ...]`).

> [!IMPORTANT]
> The same construct (`foreach`) uses **both** lowering strategies depending on the
> aggregate: a runtime helper (`_aApplyXX`) for arrays, a pure AST rewrite (`for`-loop,
> §2.2) for ranges. D already proves "runtime helper _or_ AST desugar, chosen per
> construct" is a coherent design. That is the precedent the recommended _hybrid_ (§4)
> leans on.

### 2.2 Range `foreach` → explicit `for` loop — pure AST desugar (the consumer side)

When the aggregate exposes `.empty`/`.front`/`.popFront`, `foreach` is rewritten to a
`for` loop with **no delegate at all** (`statementsem.d:1246`–~1400). The comment at
`statementsem.d:1251` spells out the rewrite:

```text
foreach (e; aggr) { ... }
=>
for (auto __r = aggr[]; !__r.empty; __r.popFront()) {
    auto e = __r.front;
    ...
}
```

Mechanics: a temp `__r` via `copyToTemp(STC.none, "__r", fs.aggr)`
(`statementsem.d:1290`); `condition = new NotExp(... DotIdExp(__r, Id.Fempty))`
(`statementsem.d:1298-1300`); `increment = new CallExp(... DotIdExp(__r, idpopFront))`
(`statementsem.d:1303-1304`). This is a pure desugaring into existing statements.

It matters twice for coroutines. First, it is the model for a **library-driven**
generator (Proposal A/C below): the compiler emits range-primitive calls and the
_runtime template_ holds the state machine, so a `Generator!T` that exposes
`.empty`/`.front`/`.popFront` slots into this lowering **with zero frontend changes**.
Second, it is the portable, no-intrinsics fallback shape for DMD/GDC: a frontend state
machine is "just data plus a `switch`", desugared the same way.

### 2.3 `lazy` parameter → delegate — arg-to-thunk conversion

A `lazy` argument is converted to a delegate _at the call site_
(`expressionsem.d:3609`):

```d
else if (p.isLazy())
{
    // Convert lazy argument to a delegate
    auto t = (p.type.ty == Tvoid) ? p.type : arg.type;
    arg = toDelegate(arg, t, sc);
}
```

and _reading_ a `lazy` parameter is rewritten into a delegate **call**
(`expressionsem.d:2877`):

```d
/* Look for e1 being a lazy parameter; rewrite as delegate call ... */
auto ve = e1.isVarExp();
if (ve && ve.var.storage_class & STC.lazy_ && !ve.delegateWasExtracted)
{
    Expression e = new CallExp(loc, e1);
    return e.expressionSemantic(sc);
}
```

`lazy` parameters are also treated as `scope` for escape purposes
(`expressionsem.d:3629-3648`, _"Allow 'lazy' to imply 'scope'"_). This is the _arg-side_
analogue of the body-side `foreach` lowering: a user _expression_ becomes a callable the
frontend synthesizes. A `yield`/`await` expression could be lowered similarly — an
expression that, instead of becoming a thunk, becomes a _suspend point_. The
`lazy ⇒ scope` inference is also the precedent a `scope` (stack-elidable) coroutine
frame would copy (§3, [attributes][attributes]).

### 2.4 `scope(exit/success/failure)` → try/finally + nested function

`scope(...)` statements are semantically rewritten into `TryFinallyStatement` /
try-catch. `statementsem.d:3502` is `visitScopeGuard`; the note at `statementsem.d:3516`
records _"scope(success) and scope(failure) are rewritten to try-catch(-finally)
statement"_. The destructor-cleanup path also synthesizes `ScopeGuardStatement`
(`statementsem.d:1671`) and `TryFinallyStatement` (`statementsem.d:3182`, `:3226`). The
`catchSemantic` comment (`statementsem.d:4143-4148`) is directly on point for coroutine
state machines:

> "the `_d_local_unwind()` gets the stack munged up on this. The workaround is to place
> any try-catches into a separate function ... To fix, have the compiler automatically
> convert the finally body into a nested function."

i.e. the frontend _already_ converts statement bodies into nested functions to keep
control flow tractable across cleanup boundaries — the same need arises across coroutine
suspend points, where locals that are live across a suspend must be reified into the
frame and unwinding must thread through resume/destroy paths. (This is also why a
coroutine carrying an in-flight exception across a suspend interacts with DIP1008; see
[attributes][attributes].)

### 2.5 Nested functions / delegates → frame structs (closures) — the frame data structure

This is the core data structure a stackless coroutine frame would reuse. The frontend
computes, per function:

- `FuncDeclaration.closureVars` (`func.d:309`): _"local variables in this function which
  are referenced by nested functions (They'll get put into the 'closure')"_ — exactly
  the set of locals that must outlive a frame.
- `FuncDeclaration.outerVars` (`func.d:314`) — the inverse direction.
- `FuncDeclaration.requiresClosure` (`func.d:304`): _"this function needs a closure"_.
- `FuncLiteralDeclaration.fes` (`func.d:274`): _"if foreach body, this is the foreach"_
  — a backlink connecting a synthesized loop-body delegate to its origin (the same
  backlink a coroutine body would carry to its declaration).

The `needsClosure` decision lives at `funcsem.d:3264`. A heap closure is required when
the captured vars are referenced by a function that _escapes_ — the conservative rules
(doc comment `funcsem.d:3269-3279`):

> "1) is a virtual function 2) has its address taken 3) has a parent that escapes 4) calls another nested function that needs a closure"

The escape trigger is `fx.isThis() || fx.tookAddressOf` (`funcsem.d:3318`). When the
nested function does _not_ escape, the frame is stack-allocated; when it does, it is
heap-allocated.

> [!IMPORTANT]
> A coroutine frame is _exactly_ a closure whose lifetime outlives its creating frame
> — it **must**, since it is resumed later. Under today's rules it always takes the
> "escapes → heap" path, which is the root of the `@nogc` story: a default GC-heap
> coroutine frame breaks `@nogc` and `-betterC` (the governing `checkClosure`/`setGC`
> check is dissected in [the attributes doc][attributes]). The escape hatches — `scope`
> stack-elision, custom allocators — map onto LLVM's `CoroElide`/`coro.alloc` HALO
> machinery (see [C++ §3][cpp], [codegen][ldc-codegen]).

### 2.6 Language features → `object._d_*` druntime templates — the portable-lowering precedent

The portable frontend already lowers several language constructs into calls to a
druntime _template_, leaving codegen identical across DMD/GDC/LDC:

| Construct        | Lowered to                           | Cite                        |
| ---------------- | ------------------------------------ | --------------------------- |
| `arr.length = n` | `_d_arraysetlengthT`                 | `expressionsem.d:11898`     |
| `a ~= x`         | `_d_arrayappendcTX`                  | `expressionsem.d:12665`     |
| `a ~ b`          | `_d_arraycatnTX`                     | `expressionsem.d:12965`     |
| `new T(args)`    | `core.lifetime._d_newclassT!T(args)` | `expressionsem.d:5957-5973` |

The whitelist of recognized hook names is at `expressionsem.d:2611`. The
**critical fact for the split argument** is that the `_d_newclassT` lowering is
explicitly gated `!IN_LLVM` (`expressionsem.d:5952`):

```d
else if (!IN_LLVM && // LDC: not using the `_d_newclassT` lowering yet
         sc.needsCodegen() && // interpreter doesn't need this lowered
         !exp.placement &&
         !exp.onstack && !exp.type.isScopeClass()) // these won't use the GC
{
    /* replace `new T(arguments)` with `core.lifetime._d_newclassT!T(arguments)` ... */
```

So **LDC opts _out_ of that frontend lowering and performs `new` allocation in its own
glue instead.** This single `!IN_LLVM` proves two things at once: both lowering models
(portable-template _and_ glue-emits-IR) coexist in the same codebase, and **LDC can
choose, per construct, where the lowering happens.** A coroutine lowering can exploit
exactly that freedom (§4).

---

## 3. The frontend ↔ glue-layer split

### What the shared frontend produces

The frontend runs `semantic`/`semantic2`/`semantic3` and produces a fully-typed,
attribute-checked AST plus per-function metadata. For nested functions it computes the
**frame shape**: which locals are captured (`closureVars`), the capture direction
(`outerVars`), and whether a heap closure is needed
(`requiresClosure`/`needsClosure`, `funcsem.d:3264`). It performs IR-agnostic
_lowerings_ (the `_d_*` rewrites and the `foreach`/`scope`/`lazy` desugarings above). It
does **not** decide stack-vs-heap memory or emit any allocation instruction.

### What each backend glue emits

LDC's glue consumes that metadata. `gen/nested.cpp` `DtoCreateNestedContext`
(`gen/nested.cpp:473`) builds the actual frame and chooses the allocation strategy _by
querying the frontend's `needsClosure`_:

```cpp
bool needsClosure = dmd::needsClosure(fd);
if (needsClosure) {
    LLFunction *fn = getRuntimeFunction(fd->loc, gIR->module, "_d_allocmemory");
    auto size = getTypeAllocSize(frameType);
    ...
    LLValue *mem = gIR->CreateCallOrInvoke(fn, DtoConstSize_t(size), ".gc_frame");
    ...
} else {
    frame = DtoRawAlloca(frameType, frameAlignment, ".frame");  // stack
}
```

So the division of labour is crisp: **frontend decides frame layout + whether a closure
is needed; glue decides `_d_allocmemory` (GC heap) vs `alloca` (stack) and emits the
LLVM.** DMD's own backend and GDC do the analogous emission against their own IR. (The
full LLVM-IR-emission story is in [the codegen doc][ldc-codegen].)

### Where coroutine lowering _should_ live — the argument

Two coherent designs, both with in-tree precedent — mirroring [Option A vs Option B in
the comparison digest][comparison]:

**Option A — portable frontend lowering to a neutral target (the Clang / Rust / C# /
Kotlin model).** Clang lowers C++20 coroutines in its frontend by emitting
`llvm.coro.*`; the D analogue would either (a) have the shared frontend emit a
_frontend-synthesized state machine_ (pure-AST, à la §2.2/§2.4 — most portable, but
loses LLVM's mature `CoroSplit` frame-packing and `CoroElide` allocation-elision), or
(b) lower to **backend-neutral frontend intrinsics / a druntime template** that each
glue maps to its own coroutine mechanism. Precedent: the entire `_d_*` hook family
(§2.6) shows the frontend already lowers language features to a portable template
surface. This is the only model that serves DMD _and_ GDC, neither of which has
`llvm.coro` intrinsics.

**Option B — glue-layer lowering (LDC-specific, exploit `llvm.coro.*`, the Swift
model).** The frontend's job stops at: parse `yield`/`async`/`await`, mark the function
a coroutine, and compute the frame-relevant capture set (reuse `closureVars`, which
already identifies exactly the locals that must outlive a frame). LDC glue then emits
`llvm.coro.id`/`begin`/`save`/`suspend`/`end`/`free` and lets `CoroSplit` build the
frame and the resume/destroy functions. Precedent: LDC already overrides the
`_d_newclassT` frontend lowering with `!IN_LLVM` (§2.6) and already owns frame emission
in `gen/nested.cpp`. The catch (from [comparison][comparison]): this is _LDC-only_, and
"Compatibility across LLVM releases is not guaranteed" (`Coroutines.rst:9-10`) — the
intrinsic ABI can shift, so it must be pinned to the LDC-linked LLVM.

### The recommended hybrid

Grounded in both precedents and in the way D _already_ mixes lowering strategies per
construct (§2.1 runtime-helper arrays vs §2.2 AST-rewrite ranges):

> [!NOTE]
> **Do the syntax + semantic + capture analysis in the shared frontend** (so
> DMD/GDC/LDC agree on which functions are coroutines, what their signatures lower to,
> and how attributes propagate via `mergeFuncAttrs`); **expose a backend-neutral
> lowering target** — a druntime template like `object._d_coro*` or a small set of
> frontend intrinsics; and let **LDC glue map that to `llvm.coro.*`** (so it gets
> `CoroSplit` + HALO for free) while **DMD/GDC map it to an explicit frontend-emitted
> state machine** (a `switch` on a frame-resident resume index, à la §2.1's `int`-code
> dispatch). The frontend stays the source of truth and the design-by-introspection
> surface; LDC's `llvm.coro` path is an implementation detail behind it.

This is precisely the `foreach` story generalized: portable `_aApplyXX` helpers for one
shape, pure AST desugar for another, the frontend choosing per construct.

The `@nogc`/`nothrow`/`@safe`/`pure`/`scope` interaction with a heap coroutine frame —
the `checkClosure`/`setGC` chokepoint, the `scope`-elision and custom-allocator escape
hatches, and DIP1008 exceptions-across-suspend — is deep enough to warrant its own
treatment: **see [Attributes & Memory][attributes].** Here it suffices to say the
frontend already has the _exact_ check (`semantic3.d:1850` `checkClosure`) that predicts
the coroutine `@nogc` story, because a coroutine frame is a closure that always escapes.

---

## 4. Three candidate D surface syntaxes

All three reuse existing frontend machinery: capture analysis
(`closureVars`/`needsClosure`), the body→delegate transform (`foreachBodyToFunction`),
the `_d_*` hook lowering surface, and `mergeFuncAttrs` attribute propagation. They map
onto distinct [`llvm.coro.*`][llvm-coroutines] ABIs (`SwitchABI`, `RetconABI`,
`AsyncABI` — see [the codegen doc][ldc-codegen] for ABI selection mechanics). The
surface design itself should follow the C++20 promise+awaiter+handle shape that
`llvm.coro.*` was _built_ to lower — that correspondence is established in detail in
[the C++ digest][cpp].

### Proposal A — `Generator!T` function with `yield` (RetconABI / `coro.id.retcon`)

Surface (mirrors range `foreach`, returns an `InputRange`):

```d
Generator!int counter(int n) @safe nothrow {
    foreach (i; 0 .. n)
        yield i;                 // suspend, hand `i` to the consumer
}
foreach (x; counter(3)) { ... }  // reuses §2.2 range foreach as-is
```

- **Frontend work.** Parse `yield e`; mark `counter` a coroutine (a new
  `FuncDeclaration` flag, set the way the presence of `co_await`/`co_yield` makes a
  function a coroutine in C++ — [cpp][cpp]). The _return type_ is a compiler-known
  `Generator!T` (a druntime struct exposing `.empty`/`.front`/`.popFront`), so it slots
  into the existing range-`foreach` lowering (§2.2) with **zero changes**.
- **Capture analysis.** Locals live across a `yield` become frame fields — reuse the
  `closureVars` data flow; they are exactly the vars "referenced across a suspend".
- **The lowering (RetconABI, the natural generator ABI).** Wrap the body in a
  `coro.id.retcon` + `coro.begin`; each `yield e` becomes a
  `call i1 @llvm.coro.suspend.retcon(...)` returning `e` to the ramp's continuation;
  `coro.end` at function end. `.popFront` resumes the returned continuation pointer;
  `.front` reads the last yielded value; `.empty` is true after `coro.end`. `CoroSplit`
  synthesizes the frame and resume function; `CoroElide` can stack-elide the frame when
  the generator is fully consumed in-scope (the `@nogc` escape hatch).
- **Portable fallback (DMD/GDC).** Lower to a frontend-emitted state machine — a
  `switch` on a resume-index frame field, à la the `int`-code dispatch of
  `foreach`/`opApply` (§2.1) — with the frame as an explicit struct (the closure frame
  type, §2.5).
- **Attribute story.** `mergeFuncAttrs` makes the body at most as `pure`/`nothrow`/
  `@nogc` as its signature. A `@nogc` generator needs the frame _not_ heap-allocated
  (`scope`/elision or custom allocator); see [attributes][attributes].
- **Portability.** Best of the three: the consumer side is _already_ a portable
  desugar, and RetconABI is the generator-shaped ABI.

### Proposal B — `async`/`await` returning `Task!T` (AsyncABI / `coro.id.async`)

Surface:

```d
async Task!Response fetch(Url u) {
    auto conn = await connect(u);    // suspend until conn is ready
    return await conn.get();
}
```

- **Frontend work.** `async` marks the function a coroutine returning a compiler-known
  `Task!T`/awaitable; `await e` requires `e` to model an awaitable
  (`isReady`/`onSuspend`/`getResult`, detected by a trait search exactly like the range
  primitives `.empty`/`.front`/`.popFront` in §2.2). The awaiter protocol mirrors C++20's
  `await_ready`/`await_suspend`/`await_resume` — [the C++ digest §1.4][cpp] is the spec.
- **The lowering.** `llvm.coro.id.async` + `llvm.coro.suspend.async`, designed for
  callee-driven resumption (the awaited operation calls the continuation). The async
  context is a heap-allocated linked list of caller contexts threaded by guaranteed
  tail calls (`swifttailcc`) — the model that maps cleanly onto an event loop or WasmFX
  (see [wasm & WasmFX][wasm]). Symmetric transfer
  (`coro.await.suspend.handle` → `musttail call coro.resume`) is what keeps a long
  await-chain from growing the native stack ([cpp §2][cpp]).
- **Attribute story.** The `Task` frame defaults to a GC/heap allocation (**breaks
  `@nogc`**) unless a custom allocator or stack-elision is used. The exception-free
  customization points (a `getReturnObjectOnAllocationFailure`-style nothrow path,
  `await_suspend` returning `bool false` to abort) align with D's
  `@nogc nothrow` + `Expected!(T, E)` idioms — detailed in [attributes][attributes].
- **Portability.** AsyncABI is largely Swift-tuned (`swiftcc`/`swiftasync`/`swifterror`)
  and _LDC-only_; DMD/GDC would need a frontend state machine. The async lowering is
  also "ineffective at statically eliminating allocations after fully inlining" — i.e.
  worse HALO than switched-resume ([cpp §6][cpp]). This is the most ergonomic surface
  but the heaviest runtime-design commitment.

### Proposal C — Library-driven `@generator` / `core.coro` + `pragma(LDC_intrinsic, …)`

Surface: **no keyword change.** A `@coroutine`/`@generator` UDA or a `core.coro`
template plus a magic `coroYield`/`coroSuspend` intrinsic, prototyped _today_ via:

```d
pragma(LDC_intrinsic, "llvm.coro.suspend")
    ubyte llvm_coro_suspend(/* token */ void*, bool isFinal);
```

— exactly how `ldc.intrinsics` exposes other LLVM builtins (e.g.
`runtime/druntime/src/ldc/intrinsics.di:55`'s
`pragma(LDC_intrinsic, "llvm.returnaddress")`). LDC can expose _any_ LLVM intrinsic this
way (`gen/pragma.cpp:121`, `gen/pragma.h:28` `LLVMintrinsic`), and raw LLVM via
`pragma(LDC_inline_ir)` (`gen/pragma.cpp:316`).

- **Frontend work.** Minimal or none initially; LDC glue recognizes the intrinsic and
  `CoroSplit` does the rest. Because the default pipeline already runs the coro passes
  (the `CoroConditionalWrapper` no-ops when no coro intrinsics are present), **no new
  pass registration is needed** — see [codegen][ldc-codegen].
- **Attribute story.** Whatever the library author writes; the frame is whatever the
  intrinsic protocol allocates, so `@nogc` is the author's responsibility.
- **Portability.** No portable frontend state-machine fallback — DMD/GDC would not
  support it without their own work. But it is the **fastest path to a working LDC
  prototype** and a testbed for the ABI choice (Retcon vs Async vs Switch) _before_
  committing to any syntax. It also matches D's standing preference for _library
  solutions over keywords_ (cf. `std.concurrency.Generator` being a library type, and
  `lazy` being the lone existing "thunk" keyword). The recommended sequencing
  ([roadmap][roadmap]) is to use Proposal C to validate the lowering, then promote the
  winning ABI into the hybrid frontend design (§3) under Proposal A's surface.

|                  | A — `Generator!T`/`yield`                          | B — `async`/`await`                                      | C — library + intrinsic       |
| ---------------- | -------------------------------------------------- | -------------------------------------------------------- | ----------------------------- |
| LLVM ABI         | RetconABI (`coro.id.retcon`)                       | AsyncABI (`coro.id.async`)                               | author-chosen (Switch/Retcon) |
| Consumer side    | range `foreach` (§2.2) **free**                    | `Task` await-chain + symmetric transfer                  | manual                        |
| Frontend work    | parse `yield`, known return type, capture analysis | parse `async`/`await`, awaitable trait, capture analysis | ~none initially               |
| `@nogc` default  | breaks unless elided/`scope`                       | breaks (heap context)                                    | author's responsibility       |
| DMD/GDC fallback | frontend state machine (`switch` on resume index)  | frontend state machine                                   | **none**                      |
| Best for         | generators / lazy sequences                        | event-loop / async I/O                                   | LDC prototype + ABI testbed   |

---

## 5. The current (stackful) story, for contrast

The motivation for _any_ of the above is cost. D's only built-in coroutine primitive is
the stackful [`Fiber`][d-fiber]: `class FiberBase` (`core/thread/fiber/base.d:312`)
allocates a _real machine stack_ and context-switches; `static void yield() nothrow
@nogc` (`base.d:583`) suspends by saving/restoring the whole stack — suspension can
happen at arbitrary call depth, but every fiber pays for a full stack (default large,
guard pages included). `std.concurrency.Generator!T` (`std/concurrency.d:1692`) _is_ a
`Fiber` subclass presenting an `InputRange`, whose `popFront` is `Fiber.call()`
(resume); the producer's free-function `yield` (`std/concurrency.d:1903`) delegates to
the stackful `Fiber.yield`.

The cost contrast is the whole point: a `Generator` allocates a full fiber stack
regardless of how little state it needs, whereas a **stackless coroutine allocates only
a frame sized to the live-across-suspend state** (which `CoroSplit` computes),
eliminating per-generator stacks and the context-switch cost. The full baseline —
stack sizing, `fiber_switchContext`, the `@nogc`-because-preallocated subtlety — is in
[the D Fiber baseline doc][d-fiber].

---

## 6. DIP / spec / branch trace

### DIPs, spec, changelog

**No DIP, spec page, or changelog entry mentions stackless coroutines or generator
syntax.** A search across `spec/*.dd`, `changelog/`, and `DIPs/` (the `DIPs/` directory
does not even exist in the checkout) of the `dlang.org` tree for
`coroutine|stackless|yield expression|async` returns nothing. The only coroutine
material is the _Fiber tutorial_ (`book/d.en/fibers.d`, which confirms the framing —
_"Fibers are similar to coroutines and green threads."_) and `std.concurrency`. Stackless
coroutines are unspecified greenfield for D — there is no prior design to reconcile
against, which is both a freedom and an obligation for this survey's roadmap.

### Feature branches (one line each)

- **`dmd-feat-wasm`** (branch `feat/wasm`) builds a **native WebAssembly core-module
  emitter inside DMD** — a new `dmd.wasm` package (`compiler/src/dmd/wasm/{binary,
instructions,modulefile,types}.d`, ~2025 lines) that reads/validates/writes wasm core
  binary modules, _independent of target plumbing, WASI, linking, druntime, and backend
  codegen_. **No coroutine / stack-switching opcodes yet** — `grep` for
  `cont/resume/suspend/stack_switch` in `instructions.d` finds only ordinary control
  flow. This is the DMD-side direct-to-wasm path, parallel to LDC's LLVM→wasm path, and
  where WasmFX `cont.new`/`resume`/`suspend` opcodes would eventually be modelled (see
  [wasm & WasmFX][wasm]).
- **`dmd-issue-20970`** (branch `fix/issue-20970/ensure-druntime-hooks-support-copy-ctors`)
  ensures the **`_d_*` druntime lowering hooks support copy constructors** — relevant
  because it touches the exact `object._d_*` hook surface (§2.6) a coroutine lowering
  might extend.
- **`dmd-pr-review-22745`** (branch `test/pr/22745`) is a **test/review branch for
  static-array length inference** (PR 22745) — not coroutine-related; general frontend
  type-inference work.

---

## 7. Synthesis

D arrives at stackless coroutines from an unusually favourable position: _zero_ surface
syntax, but a frontend that already performs every constituent transformation —
body→delegate (§2.1), expression→thunk (§2.3), statement→nested-function (§2.4), and
capture→frame-struct (§2.5) — plus a proven habit of choosing, per construct, between a
portable druntime-template lowering and a glue-emitted one (§2.6). The recommended
design keeps **syntax, semantic checking, and capture analysis in the shared frontend**
(so all three D compilers agree and the feature stays introspectable), targets a
**backend-neutral lowering** (`object._d_coro*` / frontend intrinsics), and lets **LDC
map it to `llvm.coro.*`** for `CoroSplit` + HALO while **DMD/GDC emit a frontend state
machine**. Proposal C (library + `pragma(LDC_intrinsic)`) is the fastest route to a
working LDC prototype and an ABI testbed; Proposal A (`Generator!T`/`yield`) is the most
natural first _language_ feature because its consumer side is already a portable
desugar. The attribute/`@nogc` depth — the single most consequential constraint, since
a coroutine frame is a closure that always escapes — is carried in
[Attributes & Memory][attributes], and the WasmFX porting angle in
[WebAssembly & WasmFX][wasm]. The end-to-end sequencing is the subject of the
[roadmap][roadmap].

---

## Sources

Primary artifacts consulted (all local paths on this machine):

- **DMD frontend (vendored in LDC v1.42):** `$REPOS/dlang/ldc/dmd/` —
  `statementsem.d` (`foreachBodyToFunction` :4044, `mergeFuncAttrs` call :4116,
  `applyOpApply`/`applyDelegate`/`applyArray` :3831/:3866/:3892, DIP1000 closure force
  :3844, range `foreach`→`for` :1246-1304, `visitScopeGuard` :3502, "finally body into
  a nested function" :4143-4148), `expressionsem.d` (`lazy`→delegate :3609, lazy read
  :2877, `lazy⇒scope` :3629-3648, `_d_newclassT` gate `!IN_LLVM` :5952-5973, hook
  whitelist :2611, `_d_arraysetlengthT`/`_d_arrayappendcTX`/`_d_arraycatnTX`
  :11898/:12665/:12965), `func.d` (`requiresClosure`/`closureVars`/`outerVars`/`fes`
  :304/:309/:314/:274), `funcsem.d` (`needsClosure` :3264, escape trigger :3318),
  `semantic3.d` (`checkClosure` :1850), `nogc.d` (`setGC` :96/:326), `clone.d`
  (`mergeFuncAttrs` :54).
- **LDC v1.42 glue:** `$REPOS/dlang/ldc/gen/` — `nested.cpp`
  (`DtoCreateNestedContext` :473, `_d_allocmemory` vs `alloca`), `pragma.cpp`
  (`LDC_intrinsic` :121, `LDC_inline_ir` :316), `pragma.h:28`, `optimizer.cpp`
  (`buildPerModuleDefaultPipeline` :557); `runtime/druntime/src/ldc/intrinsics.di:55`.
- **druntime / phobos:** `core/thread/fiber/base.d` (`FiberBase` :312, `yield` :583),
  `std/concurrency.d` (`Generator` :1692, `yield` :1903).
- **LLVM 23.0.0git:** `$REPOS/llvm-project/llvm/` —
  `include/llvm/IR/Intrinsics.td:1875-1930` (`llvm.coro.*`),
  `lib/Passes/PassBuilderPipelines.cpp:475-484` (coro passes in default pipeline),
  `include/llvm/Transforms/Coroutines/ABI.h:67-93` (Switch/Async/Retcon ABIs),
  `docs/Coroutines.rst`.
- **Feature branches:** `dmd-feat-wasm` (`feat/wasm`, `compiler/src/dmd/wasm/`),
  `dmd-issue-20970`, `dmd-pr-review-22745`.
- **dlang.org tree** (negative result for `coroutine|stackless|yield expression|async`;
  `book/d.en/fibers.d`).

<!-- References -->

[cpp]: ./cpp-coroutines.md
[comparison]: ./comparison.md
[llvm-coroutines]: ./llvm-coroutines.md
[ldc-codegen]: ./ldc-codegen.md
[attributes]: ./attributes-and-memory.md
[d-fiber]: ./d-fiber-baseline.md
[wasm]: ./wasm-and-wasmfx.md
[roadmap]: ./roadmap.md
