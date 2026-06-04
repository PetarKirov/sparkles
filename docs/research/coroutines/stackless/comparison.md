# How Production Compilers Lower Stackless Coroutines

A comparison chapter for the _Stackless Coroutines for LDC_ survey: it surveys how
seven production language toolchains turn `async`/`await`/`yield` into a stackless
coroutine — a heap- or inline-allocated state object plus a resumable function — and
distils the lessons for adding the feature to D. The recurring split is between a
**frontend-emitted state machine** (Rust, C#, Kotlin, regenerator-JS, Python) where
the backend sees ordinary code, and **backend/IR-intrinsic lowering** (Swift via
LLVM's coro-async pass) where a mid-level transform does the split. Swift is the only
production consumer of LLVM's async coroutine lowering, which makes it the single
most relevant model for LDC — and the one this survey scrutinizes hardest. The
chapter closes with the concrete D/LDC tradeoff: a portable shared-frontend lowering
versus an LDC-only `llvm.coro.*` fast path, and the hybrid the [roadmap][roadmap]
adopts.

**Last reviewed:** June 4, 2026

---

## Two lowering strategies

Every toolchain below resolves the same problem — a function must be able to _return
to its caller before it finishes_, then later _resume from the middle_ — into one of
two architectural choices. The axis is **where the state-machine transform lives**.

| Strategy                               | What the transform produces                                                                                                          | What the backend sees                                                                          | Examples                                                      |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| **(1) Frontend-emitted state machine** | An explicit state object (struct/class/enum) + a `MoveNext`/`poll`/`resume` dispatch, synthesized _before_ any backend IR            | Ordinary code (LLVM IR, JVM bytecode, CIL, CPython bytecode) — no coroutine construct          | Rust (MIR), C# (Roslyn), Kotlin (CPS), regenerator-JS, Python |
| **(2) Backend/IR-intrinsic lowering**  | Ordinary-looking IR sprinkled with `llvm.coro.*` intrinsics; a mid-level pass (`CoroSplit`) does the split and synthesizes the frame | Intrinsics until `CoroSplit` runs; the frame layout and function split are the _backend's_ job | Swift (LLVM coro-async)                                       |

The distinction matters enormously for D because D has **three** backends behind one
shared frontend (DMD's own backend, GDC's GCC backend, and LDC's LLVM backend). Only
strategy (2) requires LLVM; only LDC has it. This single fact drives the entire
recommendation at the end of this doc and in [d-design][d-design] / [roadmap][roadmap].

A third, _orthogonal_ axis — exercised here only by Go — is **stackful** coroutines:
no source rewrite at all, just a real growable stack switched by the runtime. That is
the [wasm][wasm]/WasmFX axis, not the stackless one, and is treated as a separate
track throughout the survey.

---

## 1. Rust — MIR coroutine (generator) transform

**Surface.** `async fn` / `async {}` blocks; `.await`. An `async fn` desugars to a
function returning `impl Future<Output = T>`; the body becomes an `async` block, which
is a _coroutine_ in compiler terms.

**Mechanism.** The body is lowered to a compiler-generated **state machine in MIR**
(Rust's mid-level IR) by the pass `rustc_mir_transform::coroutine`. This is the same
machinery historically exposed as the unstable "generators" feature, later renamed
**coroutines** (the `coroutines` / `coroutine_trait` features; `yield` and the
`Coroutine` / `CoroutineState` traits). `async`/`await` is built on top of it: an
`async` block is a coroutine whose resume argument is a `&mut Context<'_>` and whose
yields are the suspensions at each `.await`.

- The transform builds a **`CoroutineLayout`** — effectively an enum of states:
  `Unresumed` (state 0), `Returned`, `Panicked`, plus one `Suspend(n)` variant per
  await/yield point. Each variant stores exactly the locals **live across that
  suspension** (computed by liveness analysis in MIR), and storage for locals never
  simultaneously live is **overlapped** → a compact frame.
- `Future::poll(self: Pin<&mut Self>, cx: &mut Context) -> Poll<T>` is synthesized:
  state 0 starts execution; when a sub-future returns `Poll::Pending` the coroutine
  records its resume state and returns `Pending`; resumption re-enters `poll`, matches
  on the discriminant, and jumps to the saved point.

**Frame allocation.** The Future _is_ the state enum — a plain value. It is **not
heap-allocated by the language**; the caller decides where it lives: on the caller's
stack frame, embedded in another future, or boxed via `Box::pin`. There is no built-in
allocator, and the future does nothing until first `poll`.

**Self-reference handling — `Pin`.** Because a borrow can live across an `.await`
(e.g. a `&local` held while awaiting), the state machine can be **self-referential**:
a field may point into another field of the _same_ frame. Moving such a frame would
invalidate the internal pointer. Rust solves this in the **type system** with `Pin<P>`
and the `Unpin` auto-trait: `Future::poll` takes `self: Pin<&mut Self>`, guaranteeing
the frame will not move once polling begins; self-referential coroutine state types are
`!Unpin`. This is purely static — there is _no runtime relocation barrier_.

**`Send`/`Sync` auto-trait propagation.** `Send`/`Sync` are auto-traits computed
structurally over the fields the state machine actually stores. A future is `Send` iff
every value held _across an await point_ is `Send` — which is exactly why holding a
non-`Send` value (an `Rc`, a `MutexGuard`) across `.await` makes the whole future
`!Send` and breaks `tokio::spawn`. The propagation is automatic from the generated
frame's fields, with no annotation. (Contrast the `#[async_trait]` macro, which boxes
to `Pin<Box<dyn Future + Send>>` and must add explicit `Send` bounds.)

**Runtime coupling — none built in.** The compiler emits only the state machine and
the `Future` impl. A `Waker`/`Context` is passed into `poll`; an external executor
(Tokio, async-std, embassy) drives polling. The language ships the trait machinery
(`Future`, `Poll`, `Context`, `Waker`, `Pin`) but no executor or reactor. This is the
"library-level scheduler" pattern that [d-landscape][d-landscape] and
[effects-event-loops][effects-event-loops] discuss on the async-I/O side.

**Lowering layer — frontend (MIR).** LLVM sees an _ordinary function_. Rust emits **no
`llvm.coro.*` intrinsics** and does not use LLVM coroutine lowering at all.

> [!NOTE]
> Rust is the closest existing analog to the recommended D design: a state machine
> built in the language's own mid-level IR, with self-reference handled by the type
> system rather than the runtime. The `CoroutineLayout` liveness-overlap trick and the
> `Pin`/`Unpin` policy are the two ideas the [d-design][d-design] chapter borrows most
> directly.

---

## 2. C# — Roslyn `IAsyncStateMachine` struct + `MoveNext`

**Surface.** `async` methods returning `Task` / `Task<T>` / `ValueTask` / `void` (or
any type with an associated builder); `await expr`.

**Mechanism.** The **Roslyn** compiler rewrites the method body into a generated
**struct (Release; class in Debug) implementing `IAsyncStateMachine`** with two
members: `void MoveNext()` and `void SetStateMachine(IAsyncStateMachine)`.

- `MoveNext()` is the resumable body: a `switch`/`goto` over an `int _state` field
  (`-1` initial, `0..N` per await point, `-2` completed). Locals live across awaits
  become struct fields.
- An `AsyncMethodBuilder` field (`AsyncTaskMethodBuilder` / `AsyncTaskMethodBuilder<T>`
  / `AsyncValueTaskMethodBuilder<T>`, or a custom `[AsyncMethodBuilder(...)]`) drives
  it: `Start` calls `MoveNext` the first time; `SetResult`/`SetException` complete the
  returned task; `AwaitUnsafeOnCompleted(ref awaiter, ref stateMachine)` schedules the
  continuation when an awaiter is not yet complete.

**Frame allocation — "struct on stack until first suspension, then boxed".** The state
machine starts as a **struct on the caller's stack**. If the method completes
synchronously (every awaited operation already complete — the _fast path_), **no heap
allocation happens at all**. The **first time a real `await` suspends** (awaiter not
complete), the builder _boxes_ the struct to the heap: assigning the struct to the
`IAsyncStateMachine` _interface_ (a reference type) triggers the box, and
`SetStateMachine` patches the builder so the heap copy's `MoveNext` becomes the
continuation. `AwaitUnsafeOnCompleted` is where this lift happens.

**Self-reference handling — none needed.** C# value types/locals are not
self-referential in the Rust sense, and the GC moves only managed heap objects under
runtime control (fixing references as it goes), so there is **no `Pin`-equivalent
problem**. Boxing copies the struct once; subsequent continuations operate on the
stable heap box.

**Runtime coupling — tight.** Bound to the .NET runtime plus `Task` /
`SynchronizationContext` / `ExecutionContext`. `ExecutionContext` (ambient
`AsyncLocal<T>` flow, security context) is captured and restored across continuations
by the builder/awaiter machinery; `SynchronizationContext`/`TaskScheduler` decides the
resumption thread (unless `ConfigureAwait(false)`). The builder types and `Task` live
in the BCL.

**Lowering layer — frontend (Roslyn → CIL).** The CLR JIT sees an ordinary struct with
methods; there is no special IR construct.

---

## 3. Kotlin — CPS transform + label state machine

**Surface.** `suspend fun`; suspension via the library primitives `suspendCoroutine {}`
/ `suspendCancellableCoroutine {}`; structured concurrency (`launch`, `async`) from
`kotlinx.coroutines` — a _library_, not the compiler.

**Mechanism — Continuation-Passing Style.** The Kotlin compiler rewrites each
`suspend` function to take a **hidden extra parameter `Continuation<T>`** (named
`$completion`). So `suspend fun foo(): T` compiles to `fun foo(c: Continuation<T>):
Any?`, returning _either_ the value _or_ the sentinel `COROUTINE_SUSPENDED`.

- The body becomes a **state-machine class** (a generated subclass of
  `ContinuationImpl`/`SuspendLambda`) with an **`int label` field** for the current
  state and fields for locals live across suspensions; the body is a `when`/`switch`
  over `label`. The generated class **is itself the `Continuation`** passed downward,
  so resumption calls back into the same `invokeSuspend()`/`resumeWith()`.
- **Calling convention:** "a suspendable function may either suspend or return." If it
  has a result it returns it directly; if it suspends it returns `COROUTINE_SUSPENDED`.
  The caller checks for that marker to decide whether to itself suspend (propagating up)
  or continue. Resumption invokes the saved continuation, re-entering with the recorded
  state.

**Frame allocation.** The continuation/state-machine object is a **JVM heap object**
(a class instance) created when suspension actually happens; lambdas reuse the
continuation instance, mutating `label`. It is a normal GC object.

**Self-reference handling — none needed.** As with C#/JVM, references are GC-managed,
the JVM relocates objects with reference fix-up, and locals are copied into fields. No
`Pin` analog is required.

**Runtime coupling — split.** The compiler emits only the CPS state machine plus the
`Continuation` interface (in the stdlib, `kotlin.coroutines`). **Dispatch, scheduling,
structured concurrency, and `Job`/`CoroutineScope`/`Dispatchers` are a separate
library** (`kotlinx.coroutines`) — analogous to Rust's "no built-in executor", except
the _suspension primitive_ (`Continuation`, `COROUTINE_SUSPENDED`) lives in the
language stdlib.

**Lowering layer — frontend → JVM bytecode** (or Kotlin/Native, Kotlin/JS). No backend
coroutine intrinsic; the JVM sees ordinary classes and methods.

---

## 4. Swift — LLVM coroutine **async** lowering (the LLVM-intrinsic exemplar)

**This is the key comparison point for LDC.** Swift is the production consumer of
LLVM's async coroutine lowering, and the survey's [llvm-coroutines][llvm-coroutines] /
[llvm-internals][llvm-internals] chapters dissect the same intrinsics from the LLVM
side. All quotes below are re-verified against the local LLVM 23.0.0git checkout.

**Surface.** `func f() async -> T`; `await expr`; `async let`, actors, `Task` (the
runtime). Standardized by SE-0296.

**Mechanism — frontend emits `llvm.coro.id.async` + intrinsics; `CoroSplit` does the
work.** The async lowering is "signaled by the use of `llvm.coro.id.async`"
(`Coroutines.rst:179`), and crucially:

> In async-continuation lowering, signaled by the use of `llvm.coro.id.async`,
> handling of control-flow must be handled explicitly by the frontend.

> In this lowering, a coroutine is assumed to take the current `async context` as
> one of its arguments (the argument position is determined by `llvm.coro.id.async`).
> It is used to marshal arguments and return values of the coroutine. Therefore, an
> async coroutine returns `void`.
> — `Coroutines.rst:179-185`

The canonical shape (`Coroutines.rst:189`):

```llvm
  define swiftcc void @async_coroutine(ptr %async.ctxt, ptr, ptr) {
  }
```

- **The async context _is_ the frame.** "Values live across a suspend point need to be
  stored in the coroutine frame to be available in the continuation function. This
  frame is stored as a tail to the `async context`." (`Coroutines.rst:192-194`). The
  context is a linked structure (`Coroutines.rst:208-211`):

  ```c
  struct async_context {
    struct async_context *caller_context;
    ...
  }
  ```

  So async frames form a **heap-allocated linked list of caller contexts**, _not_ a
  contiguous thread stack — every `await` can hop executors/threads while the context
  pointer travels.

- **`llvm.coro.id.async(i32 ctxsize, i32 align, ptr ctxarg, ptr asyncfnptr)`:** the
  frontend gives the _initial_ context size/alignment; "Lowering will update the size
  entry with the coroutine frame requirements." (`Coroutines.rst:227-228`). The
  frontend is "responsible for allocating the memory for the `async context` but can
  use the `async function pointer` struct to obtain the required size."
  (`Coroutines.rst:228-230`). That struct (`Coroutines.rst:234-237`):

  ```c
  struct async_function_pointer {
    uint32_t relative_function_pointer_to_async_impl;
    uint32_t context_size;
  }
  ```

- **Splitting at await points.** "Lowering will split an async coroutine into a ramp
  function and one resume function per suspend point." (`Coroutines.rst:239-240`).
  These are Swift's "partial functions": the body between two `await`s is one partial
  function that `musttail`-calls the next.
- **`llvm.coro.suspend.async(resume_fn, ctx_projection_fn, suspend_fn, args...)`:**
  marks the suspend point. "How control-flow is passed between caller, suspension
  point, and back to resume function is left up to the frontend."
  (`Coroutines.rst:242-243`). The suspend "takes a function and its arguments [...]
  intended to model the transfer to the callee function. It will be tail called by
  lowering and therefore must have the same signature and calling convention as the
  async coroutine." (`Coroutines.rst:245-248`). So **suspension = a tail call to the
  callee's async impl**, threading the context.
- **`llvm.coro.async.resume()`** yields the **resume function pointer** for a suspend
  point; the coroutine is resumed by calling that function with the async context. The
  **context projection function** (`ptr (ptr)`) recovers the caller's context from the
  callee context on resume. `CoroSplit` implements exactly this for the Async ABI: it
  calls the projection function on the callee context, then offsets to the frame
  (`CoroSplit.cpp:765-771`):

  ```cpp
    // The frame is located after the async_context header.
    auto &Context = Builder.getContext();
    auto *FramePtrAddr = Builder.CreateInBoundsPtrAdd(
        CallerContext,
        ConstantInt::get(Type::getInt64Ty(Context),
                         Shape.AsyncLowering.FrameOffset),
        "async.ctx.frameptr");
  ```

- The frontend must also emit **`presplitcoroutine`** on the function and
  **`llvm.coro.prepare.async`** to "block inlining of the async coroutine until after
  coroutine splitting" — so the optimizer defers other transforms until `CoroSplit`
  runs (see [llvm-internals][llvm-internals] for the pass ordering).

**Calling-convention support in LLVM.** Swift's async ABI leans on dedicated LLVM
features, _all defined for Swift's benefit_:

- **`swiftasync` parameter attribute** — `LangRef.rst:1637-1641`:

  > This indicates that the parameter is the asynchronous context parameter and
  > triggers the creation of a target-specific extended frame record to store this
  > pointer. This is not a valid attribute for return values and can only be applied
  > to one parameter.

  The "extended frame record" lets debuggers/unwinders find the async context off the
  native frame.

- **`swifttailcc` calling convention** — `LangRef.rst:506-509`:

  > This calling convention is like `swiftcc` in most respects, but also the callee
  > pops the argument area of the stack so that mandatory tail calls are possible as in
  > `tailcc`.

  This is what lets the partial functions chain via guaranteed `musttail` _without
  growing the native stack_.

- **`swiftcc`** (`LangRef.rst:502`) and **`swifterror`** (`LangRef.rst:1643`) for error
  propagation through the split functions. The `attributes-and-memory` chapter
  ([attributes][attributes]) covers the `swifterror`/coro-frame-alloca interaction in
  detail.

**Frame allocation.** Heap (Swift's task allocator), as a **linked list of async
contexts** rather than a contiguous stack. The allocation size is computed by LLVM and
back-patched into the `async_function_pointer` global. (The exact task-allocator symbol
names — `swift_task_alloc`/`swift_task_dealloc` — are recalled from memory; the
mechanism, a per-task bump allocator backing the contexts, is well-established, but the
precise symbols are unverified here.)

**Self-reference handling.** Swift values are mostly trivially relocatable or managed,
and the context is **heap-stable once allocated**, so cross-suspend pointers into the
frame stay valid. There is no `Pin` type — stability comes from the never-moved
heap-allocated async context, the same property C# gets from its boxed state machine.

**Runtime coupling — tight.** Bound to the **Swift concurrency runtime** (`Task`,
executors/actors, the task allocator, continuation primitives like
`withUnsafeContinuation`). The compiler emits the coro intrinsics; the runtime provides
allocation, scheduling, and executor hopping.

**Lowering layer — frontend emits intrinsics → LLVM mid-level `CoroSplit` does the
transform.** Uniquely among these languages, the heavy lifting is in the _shared LLVM
backend_, not the language frontend.

> [!IMPORTANT]
> Swift demonstrates a sobering fact for an LDC-only design: even with `CoroSplit`
> doing the frame layout and the function split, **LLVM does not hand you a runtime**.
> "How control-flow is passed [...] is left up to the frontend." (`Coroutines.rst:242`).
> The intrinsics save the _split_, not the _semantics_ — Swift still had to design the
> context allocation, projection functions, resume wiring, and the entire task/executor
> model. The `swiftcc`/`swiftasync`/`swifterror`/`swifttailcc` features are _also_
> Swift-shaped. And the spec opens with a blunt warning: "Compatibility across LLVM
> releases is not guaranteed." (`Coroutines.rst:10`). See [llvm-coroutines][llvm-coroutines]
> for the full intrinsic catalog and [cpp][cpp] for how C++ uses the _switched-resume_
> flavor (`llvm.coro.id`) instead of the async flavor.

---

## 5. Contrast cases — Python, JS, and the stackful Go analog

### Python — interpreter-level frame objects

`def gen(): yield` and `async def` create **generator/coroutine objects** whose
suspended state is a CPython **frame object**. The generator holds a frame
(`gi_frame`/`cr_frame`); locals live in the frame's `f_localsplus`; resumption
re-enters the eval loop at the saved instruction index (`f_lasti`). These **frames are
heap-allocated and embedded in the generator object, not on the C thread stack**. So
Python generators _are_ stackless coroutines — the "state machine" is the interpreter's
program counter plus the frame, with **no source rewrite**. `async`/`await` reuse the
same machinery (a coroutine is a generator that yields awaitables). There is no
LLVM/native transform; it is an interpreter facility. (This is _not_ the old "Stackless
Python" fork, which avoided the C stack for the eval loop itself.)

### JavaScript — two implementations

- **Babel `regenerator` (transpilation):** `@babel/plugin-transform-regenerator`
  rewrites `function*`/`async` "into a state machine" — the body becomes a `switch` over
  a context object tracking prev/next positions, with `regeneratorRuntime.mark`/`.wrap`
  supplying a generic ES5 state-machine emulation. This is the **frontend-state-machine
  model done as a source-to-source transform** — directly analogous to Rust/C#/Kotlin
  but at the syntax-tree level for ES5 targets.
- **Native engines (V8/JSC/SpiderMonkey):** mark async/generator functions as
  **resumable** in the bytecode and suspend/resume at `await`/`yield` with generator
  state stored off the interpreter stack, returning an implicit promise and attaching
  continuations to it. Interpreter/JIT-level, like Python — no source rewrite.

### Go — STACKFUL goroutines (the contrast)

Go's `go f()` is **not** a stackless coroutine. Each goroutine has its **own
contiguous, growable stack** (starting ~2–8 KB). When a frame would overflow, the
runtime **allocates a bigger stack and copies the whole stack over** (contiguous
stacks, rounding up — historically segmented stacks, abandoned over the "hot split"
problem). The Go runtime scheduler (M:N, work-stealing) multiplexes goroutines onto OS
threads; suspension is a **runtime stack switch**, not a compiler-generated state
object.

The consequences versus stackless are exactly inverted: no function-color split, no
`async`/`await` keyword, no per-suspend frame layout — but every goroutine pays for a
heap stack, and the runtime must own stack-copying, pointer fix-up, and preemption.
This is the closest analog to **WasmFX / wasm stack switching** and to a _stackful_
coroutine/fiber design for D — the explicit opposite of the frontend-state-machine and
LLVM-coro approaches above, and the subject of [wasm][wasm], [wasmfx][wasmfx], and the
[d-fiber][d-fiber] baseline.

---

## The big comparison

| Language          | Surface                             | IR/transform                                                                                                                        | Frame allocation                                                                                                          | Runtime coupling                                                                | Self-reference handling                                                                                              | Lowering layer                                                                                 |
| ----------------- | ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| **Rust**          | `async fn` / `async{}`, `.await`    | MIR coroutine transform → `CoroutineLayout` enum + `Future::poll` switch                                                            | Caller-decided value; stack-embedded or `Box::pin`; no built-in alloc; lazy                                               | **None built in** (executor is a crate; lang ships `Future`/`Waker`/`Pin`)      | **`Pin`/`Unpin`** static guarantee; `!Unpin` self-ref frames; `Send`/`Sync` auto-trait from fields held across await | Frontend (MIR); LLVM sees plain fn — **no coro intrinsics**                                    |
| **C#**            | `async`, `await`                    | Roslyn → `IAsyncStateMachine` struct, `MoveNext()` switch over `int _state`, `AsyncMethodBuilder`                                   | **Struct on stack** until first real suspend → **boxed to heap** (assign to interface)                                    | **Tight**: `Task`, `ExecutionContext`, `SynchronizationContext`/`TaskScheduler` | None needed (GC moves & fixes refs; no internal self-pointers)                                                       | Frontend (Roslyn → CIL); JIT sees ordinary struct                                              |
| **Kotlin**        | `suspend fun`, `suspendCoroutine{}` | CPS: hidden `Continuation<T>` param; state-machine class with `int label`; `COROUTINE_SUSPENDED` sentinel                           | JVM heap object (the continuation/state class), created on suspend                                                        | Suspension primitive in stdlib; **scheduling = `kotlinx.coroutines` library**   | None needed (JVM GC)                                                                                                 | Frontend → JVM bytecode                                                                        |
| **Swift**         | `func ... async`, `await`           | **LLVM coro async**: `llvm.coro.id.async` + `suspend.async`/`async.resume`/`end.async`; `CoroSplit` → ramp + per-suspend resume fns | **Heap async context**, linked list of caller contexts; frame is _tail_ of context; size computed by LLVM; task allocator | **Tight**: Swift `Task`/executors/actors runtime + task allocator               | Heap context never moves → stable cross-suspend pointers; no `Pin`; `swiftasync` extended frame record               | **LLVM mid-level intrinsics** (`CoroSplit`); + `swiftcc`/`swifttailcc`/`swifterror` CC support |
| **Python**        | `yield`, `async def`, `await`       | Interpreter resumable frame; PC (`f_lasti`) + frame object as state                                                                 | Heap frame embedded in generator/coroutine object (off C stack)                                                           | Interpreter + event loop (asyncio)                                              | N/A (interpreter manages frame)                                                                                      | Interpreter (CPython); no native transform                                                     |
| **JS (Babel)**    | `function*`, `async`                | `regenerator` source→source: `switch` state machine + `regeneratorRuntime.wrap`                                                     | Runtime closure/context object (heap)                                                                                     | regenerator-runtime + Promise/event loop                                        | N/A                                                                                                                  | Frontend source transform (for ES5)                                                            |
| **JS (V8)**       | same                                | Bytecode "resumable" function; engine suspend/resume                                                                                | Generator state off interpreter stack                                                                                     | Engine + microtask queue/Promise                                                | N/A                                                                                                                  | Interpreter/JIT                                                                                |
| **Go (contrast)** | `go f()`, channels                  | **STACKFUL**: real growable contiguous stack per goroutine; runtime stack-copy on growth                                            | **Own heap stack** (≈2–8 KB start, copied/doubled on growth)                                                              | **Tight**: M:N runtime scheduler owns stacks, GC pointer fix-up, preemption     | N/A — real stack, runtime relocates & fixes pointers                                                                 | Runtime, not compiler transform; analog of WasmFX stack switching                              |

Two patterns jump out of the table. First, **five of the seven stackless designs put
the transform in the frontend** and ship to a backend that knows nothing about
coroutines — that is the _majority_ approach and the one matching D's multi-backend
reality. Second, the only outlier — Swift's LLVM-intrinsic path — buys mature frame
packing at the cost of being LLVM-specific, Swift-runtime-shaped, and version-unstable.

---

## Design lessons for D / LDC

D's situation is fixed by one structural constraint: **a single DMD frontend is shared
by DMD, GDC, and LDC**, and only LDC is LLVM-based. A _language_ feature must work on
all three. Both candidate models below are greenfield — re-verified against the local
trees, **there is no coroutine support today** in either the shared frontend or LDC's
glue:

- The DMD frontend has no `async`/`await`/coroutine lowering. The only hit for
  "coroutine" across `dmd/*.d` is `dmd/dtoh.d` (C++ header generation emitting
  `co_await`), which is unrelated to D-side lowering.
- LDC's `gen/` emits **no** `llvm.coro.*` intrinsics — `grep -rn "llvm.coro" gen/`
  returns nothing. LLVM's coroutine passes are present in LDC's bundled LLVM but
  entirely unused by the D code generator.

So either option is a build-from-scratch effort; the question is _which layer_.

### Option A — Frontend-emitted state machine (Rust / C# / Kotlin / regenerator model)

The DMD frontend lowers `async`/`await` (or a `yield`/generator construct) into an
explicit state-object struct plus a `resume`/`poll` dispatch over an `int state` field,
emitting **ordinary D AST/glue code**. The backend (LLVM in LDC, GCC in GDC, the DMD
backend) sees plain code.

**Pros for D specifically.**

- **Portable across all three D backends.** Because the lowering lives in the shared
  frontend, GDC and the DMD backend get coroutines "for free" — neither has LLVM coro
  intrinsics. Only Option A serves DMD/GDC.
- **Compiles to WebAssembly without WasmFX.** A frontend state machine is just data
  plus a switch; it lowers to ordinary wasm. WasmFX/stack-switching becomes an
  _optional optimization_ for stackful needs, not a prerequisite. (Rust async already
  targets `wasm32` with no stack switching.) See [wasm][wasm].
- **Self-reference is a frontend/type-system concern**, where D can choose a policy: a
  `Pin`-like wrapper, restricting borrows across `await`, or copying. D's
  `@safe`/`scope`/`dip1000` machinery already reasons about escaping references — the
  alignment is exactly the [d-design][d-design] chapter's `scope`-based proposal, and
  echoes the survey's `scope`/lifetime thread.
- **Predictable, introspectable frame layout**, suiting D's design-by-introspection
  ethos (the frontend can expose the state-object shape to `__traits`).

**Cons.**

- The frontend must compute cross-suspend liveness and synthesize the state
  enum/struct — substantial frontend work, re-implementing logic LLVM's `CoroSplit`
  already has.
- It misses LLVM's coro frame-packing/allocation-elision optimizations unless those are
  re-implemented frontend-side.

### Option B — LLVM coro-intrinsic lowering (the Swift model)

LDC's glue emits `llvm.coro.id.async`/`llvm.coro.suspend.async`/`llvm.coro.end.async`
(or the switched-resume `llvm.coro.id` flavor) and lets `CoroSplit` build the frame and
split the function.

**Pros.**

- Reuses LLVM's mature frame layout, **allocation elision** (`coro.alloc`/`coro.free`
  collapse to a stack `alloca` when a coroutine is created and consumed locally —
  `Coroutines.rst:405-460`), and splitting. Less frontend code (see
  [ldc-codegen][ldc-codegen] for where the glue would hook in).
- The **async** flavor gives heap-linked contexts plus guaranteed tail-call chaining
  (`swifttailcc`) and an extended frame record (`swiftasync`) — battle-tested by Swift,
  ideal if D wanted executor-hopping with no native-stack growth.
- Plays naturally with LLVM's WebAssembly backend in principle (Swift compiles async to
  wasm via these intrinsics — though the **maturity of `CoroSplit` + async lowering on
  the wasm target is not verified here**, flagged in [wasm][wasm]).

**Cons for D specifically.**

- **LDC-only.** GDC and the DMD backend have no equivalent, so D would have a _language_
  feature that does not exist on two of its three compilers — unacceptable unless the
  feature is explicitly scoped LDC-specific. The shared DMD frontend cannot emit LLVM
  intrinsics.
- The async ABI is "**Compatibility across LLVM releases is not guaranteed.**"
  (`Coroutines.rst:10`) and largely **Swift-specific** — `swiftcc`/`swiftasync`/
  `swifterror`/`swifttailcc` are tuned for the Swift runtime. Coupling D to it risks
  churn and a Swift-shaped runtime.
- Async lowering "leaves control-flow up to the frontend" (`Coroutines.rst:242`) —
  LLVM gives no free runtime. D would still have to design context allocation,
  projection functions, resume wiring, and a task/executor model — exactly the parts
  Swift's runtime supplies. **The intrinsics save the split, not the semantics.**

### Recommendation — a hybrid, frontend-first

Given the shared-DMD-frontend constraint, the **language-level** `async`/`await` should
be lowered in the **frontend as a state machine (Option A)** so DMD/GDC/LDC all support
it and it compiles to plain wasm. This mirrors Rust (MIR), C# (Roslyn), and Kotlin
(CPS) — all three put coroutine lowering in the frontend and ship to a backend that
knows nothing about coroutines, which is precisely D's multi-backend situation.

The pragmatic **hybrid** the [roadmap][roadmap] adopts: keep the **surface lowering +
capture/liveness analysis + state-object layout + self-reference policy in the shared
frontend**, but allow LDC to **optionally** route to `llvm.coro.*` intrinsics as a
_backend fast path_ (Option B) where it wins on frame packing / allocation elision —
analogous to how some D features carry a portable lowering plus a per-backend
optimization. The frontend stays the **source of truth** (for DMD/GDC and for
introspection); LDC's coro path is an implementation detail behind it.

> [!WARNING]
> Do not conflate the stackless and stackful tracks. The **WasmFX/stackful** goal is
> the **Go-style** axis, _orthogonal_ to the stackless state machine. A frontend state
> machine is the right base for stackless coroutines on wasm **today**; WasmFX
> stack-switching is the substrate for a _stackful_ coroutine/fiber API (or for a cheap
> context switch of the stackless tasks) **once the proposal is available** — pursue it
> as a separate, complementary track per [wasm][wasm]/[wasmfx][wasmfx], not as the
> implementation of `async`/`await`.

---

## Open questions surfaced

- **Swift task-allocator symbols.** The exact names `swift_task_alloc`/
  `swift_task_dealloc` are recalled from memory; the mechanism (a per-task bump
  allocator backing the async contexts) is reliable, but the symbols/signatures are
  unverified against Swift's runtime source.
- **LLVM async lowering on the WebAssembly target.** Whether `CoroSplit` + the async
  flavor (and `swifttailcc` mandatory tail calls) are production-ready on `wasm32` is
  not verified against source here — it materially affects how attractive Option B's
  wasm story is. Tracked in [wasm][wasm].
- **C# state-machine struct vs class.** Struct in Release, class in Debug is
  well-established but compiler-version-dependent; not pinned to a specific Roslyn
  version here.

---

## Sources

- LLVM 23.0.0git (local): `llvm/docs/Coroutines.rst` (async lowering §`179-256`,
  allocation elision §`405-460`, compatibility warning `:10`),
  `llvm/lib/Transforms/Coroutines/CoroSplit.cpp` (Async ABI frame projection
  `:752-777`), `llvm/docs/LangRef.rst` (`swifttailcc` `:506-509`, `swiftasync`
  `:1637-1641`, `swiftcc` `:502`, `swifterror` `:1643`).
- LDC v1.42 (local): `ldc/gen/*.cpp` — verified **no** `llvm.coro` emission today.
- DMD frontend (local): `dmd/*.d` — verified **no** `async`/coroutine lowering today
  (only `dmd/dtoh.d` emits C++ `co_await` in generated headers).
- Rust: `rustc_mir_transform::coroutine` (nightly rustc docs); "Lowering async/await in
  Rust" (`wiki.cont.run/lowering-async-await-in-rust/`); "Inside Rust's async
  transform" (`blag.nemo157.com/2018/12/09/inside-rusts-async-transform.html`); "Pin
  and Unpin in Rust" (`blog.cloudflare.com/pin-and-unpin-in-rust/`); Rust Book ch.17.5.
- C#: "Exploring the async/await state machine"
  (`vkontech.com/exploring-the-async-await-state-machine-concrete-implementation/`).
- Kotlin: Kotlin spec, "Asynchronous programming with coroutines"
  (`kotlinlang.org/spec/asynchronous-programming-with-coroutines.html`); "Kotlin
  coroutine CPS" (`sobyte.net/post/2022-01/kotlin-coroutine-cps/`).
- Swift: SE-0296 (`swift-evolution/proposals/0296-async-await.md`); "Async Functions in
  Swift" (LLVM Dev Mtg 2021, McCall & Schwaighofer); LLVM `Coroutines.rst` async
  section. Local paper: `papers/llvm-coroutines-nishanov-devmtg-2016`.
- Python: `cpython/InternalDocs/frames.md`; `docs.python.org/3/c-api/gen.html`,
  `/frame.html`.
- JavaScript: `babeljs.io/docs/babel-plugin-transform-regenerator`;
  `v8.dev/blog/fast-async`; `wingolog.org/archives/2013/05/08/generators-in-v8`.
- Go: `agis.io/post/contiguous-stacks-golang/`;
  `blog.cloudflare.com/how-stacks-are-handled-in-go/`.

<!-- References -->

[d-design]: ./d-language-design.md
[ldc-codegen]: ./ldc-codegen.md
[cpp]: ./cpp-coroutines.md
[llvm-coroutines]: ./llvm-coroutines.md
[llvm-internals]: ./llvm-coro-internals.md
[attributes]: ./attributes-and-memory.md
[d-fiber]: ../stackful/d-fiber.md
[wasm]: ../wasm-and-wasmfx.md
[roadmap]: ./roadmap.md
[wasmfx]: ../../algebraic-effects/wasmfx.md
[effects-event-loops]: ../../async-io/effects-and-event-loops.md
[d-landscape]: ../../async-io/d-landscape.md
