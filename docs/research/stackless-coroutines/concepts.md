# Stackless vs Stackful Coroutines: The Foundational Concepts

This is the concepts leaf of the _Stackless Coroutines for LDC_ survey. It fixes the
vocabulary the rest of the corpus uses — what a _coroutine frame_ is, what a _suspend
point_ is, why a **stackless** coroutine can suspend only at lexical points in its own
body while a **stackful** fiber can suspend from any nested call, and how an ordinary
function plus a handful of suspension intrinsics becomes a _ramp + resume/destroy_
state machine. It grounds those definitions in N4134 (the paper that mandated stackless
coroutines for C++) and in LLVM's `Coroutines.rst`, then distils the survey's central
thesis — the **tradeoff** between the two models — into a single comparison table. The
mechanism that realises stackless lowering is detailed in [llvm-coroutines]; the
stackful baseline D already ships is dissected in [d-fiber]; the C++ template the design
copies lives in [cpp].

**Last reviewed:** June 4, 2026

---

## Two ways to remember "where you were"

A coroutine is a function that can **suspend** — return control to its caller before it
finishes — and later be **resumed** to continue from exactly where it left off. The only
hard problem in implementing one is _preserving the in-progress state across the
suspension_: live local variables, the position in the body, any in-flight temporaries.
There are precisely two strategies, and they are the two poles this entire survey is
organised around.

- **Stackful**: keep the coroutine's _whole call stack_ alive on the side. Suspension is
  a stack switch — swap the CPU stack pointer to a saved one and keep going. The state
  _is_ a real machine stack, addressable and opaque to the compiler. This is what D's
  `core.thread.Fiber` does today (see [d-fiber]).
- **Stackless**: keep _only the live locals of the coroutine's own frame_ in a compiler-
  synthesised struct (the **coroutine frame**), and rewrite the function into a state
  machine that can re-enter itself at the right resumption point. The call stack is _not_
  captured; it is the ordinary thread stack, which has already unwound back to the caller
  by the time the coroutine is suspended. This is what C++20 coroutines do, and what
  LLVM's `llvm.coro.*` intrinsics lower — the mechanism a D-on-LDC port would target
  (see [llvm-coroutines]).

The names come from the only question that distinguishes them: _does the saved state
include the call stack, or not?_

---

## Precise definitions (N4134)

The canonical definitions are in N4134, "Resumable Functions v.2" (Nishanov & Radigan, 2014) — the paper that drove C++ toward stackless coroutines and whose promise/awaiter
machinery LLVM later targeted. They are worth quoting verbatim because every downstream
design decision hangs on the single clause "does not include the call stack."

> "A stackless coroutine is a coroutine which state includes variables and temporaries
> with automatic storage duration in the body of the coroutine and **does not include
> the call stack**." — `n4134:102-104`

> "A stackful coroutine state includes the **full call stack** associated with its
> execution enabling suspension from nested stack frames. Stackful coroutines are
> equivalent to fibers or user-mode threads." — `n4134:106-108`

So the distinction is exactly:

|               | what the saved state contains                                                                               |
| ------------- | ----------------------------------------------------------------------------------------------------------- |
| **Stackless** | automatic-duration locals/temporaries of _this_ coroutine's body — **not** the call stack                   |
| **Stackful**  | the _full call stack_ — enabling suspension from nested frames; "equivalent to fibers or user-mode threads" |

> [!NOTE]
> "Stackful coroutine" and "fiber" are the _same concept_ under N4134's definition. When
> this survey says "fiber" it means a stackful coroutine; D's `Fiber` ([d-fiber]) is the
> concrete instance. "Stackless coroutine" has no D analog today — D has no compiler-
> lowered stackless coroutine at all, which is the gap this survey exists to fill.

N4134 also pins down what the stackless coroutine's saved state — the **frame** —
actually holds:

> "Coroutine state includes a coroutine promise, formal parameters, variables and
> temporaries with automatic storage duration declared in the coroutine body and an
> implementation defined platform context." — `n4134:79-81`

That sentence is the spec of the coroutine frame.

---

## The coroutine frame

The **coroutine frame** is the heart of stackless lowering: a compiler-synthesised
struct that holds exactly the state that must survive a suspension. LLVM names and
defines it identically:

> "In addition to the function stack frame, which exists when a coroutine is executing,
> there is an additional region of storage that contains objects that keep the coroutine
> state when a coroutine is suspended. This region of storage is called the **coroutine
> frame**. It is created when a coroutine is called and destroyed when a coroutine either
> runs to completion or is destroyed while suspended." — `Coroutines.rst:40-45`

Combining N4134 (`n4134:79-81`) and the LLVM lowering, the frame holds:

| Frame slot                                 | What it is                                                                                                     | Source                                                        |
| ------------------------------------------ | -------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| **Promise**                                | the customization object that bridges coroutine ↔ caller (results, yields, exceptions)                        | `n4134:79`, `Coroutines.rst:84-87`                            |
| **Parameter copies**                       | each coroutine parameter is _copied into the frame_ (automatic-duration), so it outlives the original argument | `n4134:79-81`; copy-into-frame is mandated in C++ (see [cpp]) |
| **Live-across-suspend locals/temporaries** | any value whose def-use chain crosses a suspend point — _only_ those, computed by the compiler                 | `Coroutines.rst:339-346`                                      |
| **Resume/destroy function pointers**       | so the manipulation intrinsics work when the coroutine's identity is unknown to the holder                     | `Coroutines.rst:111-113`, `:339-355`                          |
| **Resume index**                           | which suspend point we are parked at, so resume/destroy can `switch` back to it                                | `Coroutines.rst:104-109`                                      |
| **Platform context**                       | "an implementation defined platform context" — slack for ABI-specific state                                    | `n4134:79-81`                                                 |

The decisive contrast with stackful is in the **locals/temporaries** row. A stackful
fiber keeps its _entire_ reserved stack alive — kilobytes, regardless of how little is
live (see [d-fiber] for D's 16 KiB-default tax). A stackless frame keeps _only the
values the compiler proves are live across a suspension_:

> "The def-use chains are analyzed to determine which objects need to be kept alive
> across suspend points." — `Coroutines.rst:340-341`

A value that is computed and consumed entirely between two suspend points never touches
the frame at all — it stays in registers or on the ordinary stack like any other local.
The frame is therefore _exactly the minimal persistent state_, often a handful of bytes.

> [!IMPORTANT]
> "The function stack frame ... exists when a coroutine is executing" (`Coroutines.rst:40-41`):
> a stackless coroutine still uses the normal thread stack _while running_. The frame only
> captures what must persist _while suspended_. When the coroutine is parked, its
> activation record on the real stack is gone — it has returned to its caller. This is the
> single fact that produces the stackless suspend-scope limitation below.

---

## Suspend points, and the central limitation

A **suspend point** is a place in a coroutine where execution can pause and return to the
caller:

> "LLVM coroutines are functions that have one or more `suspend points`. When a suspend
> point is reached, the execution of a coroutine is suspended and control is returned back
> to its caller. A suspended coroutine can be resumed to continue execution from the last
> suspend point or it can be destroyed." — `Coroutines.rst:17-20`

In a C++/D-shaped surface (see [cpp]) the suspend points are _lexical_: a `co_await` /
`co_yield` (or `await` / `yield` in the proposed D spelling), plus the compiler-injected
_initial_ and _final_ suspend points that bracket the body. They are syntactic markers in
**this coroutine's own source text**.

Here is the limitation that defines the stackless model, and that the survey returns to
again and again:

> [!WARNING]
> **A stackless coroutine can suspend only at a lexical suspend point in its _own_ body —
> never from inside a function it calls.** When the coroutine calls an ordinary function,
> that callee's activation record is on the _real_ thread stack, which the frame does not
> capture. The callee cannot reach back and suspend the coroutine, because suspending
> means unwinding the real stack back to the caller — and the callee's frame would be
> destroyed in the process. Only the coroutine's own state machine knows how to spill its
> live values into the frame and return.

This is the _direct_ cost of "the state does not include the call stack" (`n4134:104`). A
**stackful** fiber has the opposite property by construction: because it _does_ capture
the full call stack (`n4134:106-108`), it can suspend "from nested stack frames" — the
yield can come from arbitrarily deep inside a chain of ordinary calls, and the whole stack
slice is preserved by the context switch (this is exactly what `Fiber.yield()` does in D;
see [d-fiber]). Stackful = _suspend anywhere_; stackless = _suspend only at lexical points
you wrote in this function_.

### N4134's workaround: recursive composition

N4134 is candid about this limitation and offers the standard mitigation — **recursive
composition of coroutines**, where a coroutine forwards another coroutine's yields instead
of calling an ordinary helper that would need to suspend:

> "Recursive application of generators allows to mitigate stackless coroutine inability to
> suspend from nested stack frames." — `n4134:219-220`

The illustration is a `recursive_generator<int> range(...)` that splits a range and yields
two sub-ranges (`yield range(a, mid); yield range(mid, b)`), so the recursion is expressed
as _await/yield chaining between coroutines_ rather than as a nested ordinary call
(`n4134:222-247`). Each level is itself a coroutine with its own frame and its own lexical
suspend points; control threads through the chain by suspending and resuming, never by a
plain function call that would try to yield from a non-coroutine frame. The general form of
this — awaiting one coroutine from another, with the resume re-routed as a tail call so the
stack never grows — is **symmetric transfer**, detailed in [cpp] and lowered via
`llvm.coro.await.suspend.handle` (see [llvm-coroutines]).

The precise tradeoff to carry forward:

> **Stackful** = suspend anywhere (including deep inside ordinary nested calls), at the
> cost of a whole reserved stack per instance. **Stackless** = suspend only at the lexical
> await/yield points in the coroutine body, with a frame that is exactly the live state
> (often bytes), composing across call-like boundaries via await-chaining + symmetric
> transfer rather than by suspending from a callee's frame.

---

## The state-machine model: from ordinary function to ramp + resume/destroy

How does "an ordinary function with a few suspension intrinsics" become something that can
pause and re-enter itself? LLVM's answer — the mechanism a D frontend on LDC would emit —
is to **split** the function into a small family of functions sharing a frame. (The full
intrinsic catalog and lowering pipeline are in [llvm-coroutines]; here we cover only the
shape.)

> "an LLVM coroutine is initially represented as an ordinary LLVM function that has calls
> to coroutine intrinsics defining the structure of the coroutine. The coroutine function
> is then ... rewritten by the coroutine lowering passes to become the "ramp function",
> the initial entrypoint of the coroutine, which executes until a suspend point is first
> reached. The remainder of the original coroutine function is split out into some number
> of "resume functions". Any state which must persist across suspensions is stored in the
> coroutine frame." — `Coroutines.rst:52-59`

In the default **switched-resume** lowering (the right ABI for a general C++/D surface —
see [llvm-coroutines]), the original function becomes three functions, "representing three
different ways that control can enter the coroutine" (`Coroutines.rst:92-93`):

| Function    | Role                                                         | Signature                                                                 | Source                   |
| ----------- | ------------------------------------------------------------ | ------------------------------------------------------------------------- | ------------------------ |
| **ramp**    | initial entry; runs to the first suspend, returns the handle | "takes arbitrary arguments and returns a pointer to the coroutine object" | `Coroutines.rst:95-96`   |
| **resume**  | re-enter at the parked suspend point and continue            | "takes a pointer to the coroutine object and returns `void`"              | `Coroutines.rst:97-99`   |
| **destroy** | run in-scope destructors and free the frame                  | "takes a pointer to the coroutine object and returns `void`"              | `Coroutines.rst:100-102` |

The name _switched-resume_ comes from how resume/destroy find their way back in:

> "Because the resume and destroy functions are shared across all suspend points, suspend
> points must store the index of the active suspend in the coroutine object, and the
> resume/destroy functions must switch over that index to get back to the correct point.
> Hence the name of this lowering." — `Coroutines.rst:105-109`

### The `i8` suspend switch

The single most important micro-pattern in the lowering is what each suspend point
compiles to. The suspension intrinsic `llvm.coro.suspend` returns an `i8` that a `switch`
fans out into three edges:

> "Conditional branches consuming the result of this intrinsic lead to basic blocks where
> coroutine should proceed when suspended (-1), resumed (0) or destroyed (1)." —
> `Coroutines.rst:1706-1708`

The canonical IR pattern (from `Coroutines.rst:287-308`, distilled):

```llvm
%0 = call i8 @llvm.coro.suspend(token none, i1 false)
switch i8 %0, label %suspend [i8 0, label %resume    ; coro.resume came in   → continue
                              i8 1, label %cleanup]   ; coro.destroy came in  → tear down
```

Reading the three outcomes:

- **default / `-1`** → `%suspend`: the coroutine is _suspending_; control returns to the
  caller/resumer (the ramp or resume function `ret`s).
- **`0`** → `%resume`: the coroutine was resumed (someone called `llvm.coro.resume` on the
  handle); continue executing the body past this point.
- **`1`** → `%cleanup`: the coroutine is being destroyed (`llvm.coro.destroy`); run cleanup
  and free the frame.

When a coroutine has _several_ suspend points, the frame gains a small index field and the
shared resume function loads it and branches — the literal "switch over that index"
(`Coroutines.rst:462-536`):

```llvm
%index = load i8, ptr %index.addr, align 1
%switch = icmp eq i8 %index, 0
br i1 %switch, label %loop.resume, label %loop
```

### The suspend / resume / destroy lifecycle

The three functions plus the frame give a coroutine object that supports a uniform set of
operations _without the holder needing to know the implementation_ (`Coroutines.rst:74-87`):

- **resume** — `llvm.coro.resume(handle)`: re-enter via the resume function; UB if not
  suspended (`Coroutines.rst:885-903`).
- **destroy** — `llvm.coro.destroy(handle)`: run in-scope destructors and free the frame.
  "This must be done separately even if the coroutine has reached completion normally."
  (`Coroutines.rst:80-82`).
- **done** — `llvm.coro.done(handle)`: test whether the coroutine is parked at its _final_
  suspend point, i.e. has run to completion (`Coroutines.rst:74-75`, `:905-929`).
- **promise** — `llvm.coro.promise(...)`: project the promise out of the frame so the
  caller can read results/yields (`Coroutines.rst:84-87`).

A completed coroutine is "represented with a null resume function" (`Coroutines.rst:113`),
and resuming or destroying while it is _running_ is undefined behavior
(`Coroutines.rst:89-90`). This uniform handle ABI is what lets a D `task` / `generator`
wrapper drive a coroutine of unknown shape — resume it, ask if it is `done`, read its
promise — exactly as `coroutine_handle` does in C++ ([cpp]).

> [!NOTE]
> LLVM offers two other lowerings — _returned-continuation_ (`coro.id.retcon[.once]`) and
> _async_ (`coro.id.async`) — that hand the frontend more explicit control over frame
> ownership and resumption. They matter for `@nogc` caller-owned buffers and for
> wasm/WasmFX-style tail-call transfer respectively, and are surveyed in
> [llvm-coroutines]. The state-machine _mental model_ above (frame + resume index +
> per-edge switch) is shared by all three; switched-resume is the turnkey match for a
> C++20/D-shaped surface.

---

## The tradeoff analysis — the survey thesis

N4134 did not merely _define_ the two models; it argued that the design goals **force**
stackless. That argument is the spine of this survey, so it is worth laying out in full.
The design goals were (`n4134:122-131`): scalability "to billions of concurrent
coroutines"; resume/suspend "comparable in cost to a function call overhead"; "seamless
interaction with existing facilities with no overhead"; library-extensible machinery; and
usability "in environments where exception are forbidden." From those goals:

> "Design goals of scalability and seamless interaction with existing facilities without
> overhead (namely calling into existing libraries and OS APIs without restrictions)
> **necessitates stackless coroutines**." — `n4134:138-140`

### Memory: a few bytes vs reserved megabytes

The dominant argument is memory. A stackful coroutine must reserve a whole stack up front:

> "General purpose stackful coroutines that reserve default stack for every coroutine (1MB
> on Windows, 2MB on Linux) will exhaust all available virtual memory in 32-bit address
> space with only a few thousand coroutines. Besides consuming virtual memory, stackful
> coroutines lead to memory fragmentation, since with common stack implementations,
> besides reserving virtual memory, the platform also commits first two pages of the stack
> ... even though the actual state required by a coroutine could be as small as a few
> bytes." — `n4134:142-148`

That last clause is the whole point: _the live state can be a few bytes, but the stackful
model pays for a whole stack anyway._ D's `Fiber` is a concrete witness — its default is a
16 KiB stack plus a guard page on Linux, all reserved regardless of how little is live (see
[d-fiber] for the exact sizing). A stackless frame is _exactly_ the live-across-suspend
state.

N4134 considers — and rejects — the two obvious mitigations that try to make stackful
cheaper:

| Mitigation                   | Why N4134 rejects it                                                                                                                                                                                                            | Source          |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------- |
| **Split / segmented stacks** | "requires the entire program (including all the libraries and OS facilities it calls) to be either compiled with split-stacks or to incur run-time penalties when invoking code that is not compiled with split-stack support." | `n4134:150-152` |
| **Small fixed-size stacks**  | "limits what can be called from such coroutines as it must be guaranteed that none of the functions called shall ever consume more memory than allotted in a small fixed sized stack."                                          | `n4134:154-156` |

Both mitigations break the "seamless interaction with existing facilities without
overhead" goal — they tax or restrict calls into ordinary (non-coroutine-aware) code.
Stackless sidesteps the whole problem: the coroutine calls ordinary functions on the
_ordinary_ stack, with no special stack discipline, and pays nothing per call.

### The other axes of the tradeoff

Memory is the headline, but the stackless/stackful choice ripples through every property a
D coroutine design cares about:

- **Suspend across nested frames.** Already covered: stackful can, stackless cannot
  (`n4134:104` vs `n4134:106-108`). This is the _one_ axis where stackful wins outright —
  direct-style code where any nested call may block. Everything below favours stackless.
- **Function "colouring".** Because a stackless coroutine can only suspend at its own
  lexical await points, "I can suspend here" is a _static property of the function's
  signature_ — a coroutine is a different kind of thing from an ordinary function, and the
  distinction is visible at the call site (you must `await` it). This "colouring" is the
  price of the no-call-stack model; the stackful model has no colours because any function
  can yield. See [comparison] for how Rust, C++, Go, and others make this choice.
- **`@nogc` / determinism.** A stackful `Fiber` cannot be constructed `@nogc` — its
  constructor `mmap`s a stack and GC-allocates a `StackContext` (see [d-fiber]). A
  stackless frame is a plain struct: it can be placed on the caller's stack via heap-
  allocation-elision, or in a caller-supplied buffer, with no GC involvement — directly
  aligning with D's `@nogc nothrow` + `Expected!(T,E)` idioms. The frame-allocation
  protocol that enables this is in [attributes] and [llvm-coroutines].
- **Debuggability / stack traces.** A stackful fiber's saved stack is a real, walkable
  call stack — debuggers and unwinders can see it (modulo the trampoline tricks D needs;
  see [d-fiber]). A stackless coroutine's suspended state is a flat frame struct with no
  call stack; "where is this generator parked?" is answered by a resume index, not by a
  backtrace. This is a genuine ergonomic cost of stackless and an open design question for
  D tooling — flagged in [roadmap].
- **Thread migration.** A stackful fiber switch is opaque to the optimizer, which under
  LDC causes a real TLS-address-caching hazard across migration (see [d-fiber]). A
  compiler-lowered stackless coroutine is _visible_ to the optimizer — migrating it is just
  moving a struct, with no opaque stack switch to defeat TLS reasoning.
- **Zero-overhead resume/suspend.** N4134 reports that resume/suspend are meant to be
  "comparable in cost to a function call overhead" (`n4134:127`), and its implementation
  experience backs this: an async-I/O example "incurs **only one memory allocation and no
  virtual function calls** ... as good as or better than what could be written in C over
  raw OS facilities" because the I/O control block lives _on the coroutine frame_ instead
  of in a separate heap allocation (`n4134:185-193`); the `future` shared state is "combined
  with coroutine frame allocation and does not incur an extra allocation"
  (`n4134:192-193`). A resume is a `switch` on the index plus reloads of spilled locals —
  not a dozen register saves and a stack-pointer swap as in a fiber context switch (the
  per-arch assembly cost of which is dissected in [d-fiber]).

> [!IMPORTANT]
> The exception-free angle matters for D specifically. N4134 deliberately makes coroutines
> usable "in environments where exception are forbidden" (`n4134:131`): nothrow
> allocation-failure paths, an `await_suspend` returning `bool false` to abort a launch,
> and generalized error reporting over arbitrary error types. These map cleanly onto D's
> `@nogc nothrow` + `Expected!(T,E)` error model — a D promise can avoid the GC and
> exceptions entirely. See [attributes] and [cpp].

---

## Compact comparison: stackless vs stackful

The whole tradeoff, on one screen. "Stackful" is instantiated by D's `Fiber` ([d-fiber]);
"Stackless" by the C++20/LLVM model ([cpp], [llvm-coroutines]).

| Axis                      | **Stackless coroutine**                                                                                                 | **Stackful coroutine / fiber**                                                                                        |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| **Suspend scope**         | only at _lexical_ await/yield points in this coroutine's own body                                                       | _anywhere_, including from deep inside ordinary nested calls (`n4134:106-108`)                                        |
| **Per-instance memory**   | exactly the live-across-suspend state — "could be as small as a few bytes" (`n4134:148`)                                | a whole reserved stack: 1 MB Win / 2 MB Linux default per N4134 (`n4134:142-143`); 16 KiB+ in D's `Fiber` ([d-fiber]) |
| **Frame sizing**          | compiler-computed minimum from def-use chains across suspends (`Coroutines.rst:339-346`)                                | fixed at creation; over-provisioned and uniform; overflow traps on a guard page                                       |
| **`@nogc`-friendliness**  | yes — frame is a plain struct, caller-placeable / elidable, no GC (see [attributes])                                    | no — constructor `mmap`s a stack + GC-allocates bookkeeping ([d-fiber])                                               |
| **Suspend / resume cost** | a `switch` on a resume index + reload of spilled locals; "comparable in cost to a function call overhead" (`n4134:127`) | register save/restore + stack-pointer swap + indirect jump (per-arch hand asm; see [d-fiber])                         |
| **Debugger stacks**       | flat frame struct; no walkable call stack while suspended (resume index, not a backtrace)                               | real, walkable call stack preserved by the switch                                                                     |
| **Who owns the stack**    | the _ordinary_ thread stack — used only while running; nothing reserved while suspended                                 | a dedicated per-fiber stack, reserved and addressable for the fiber's whole lifetime                                  |
| **Function colouring**    | yes — "is a coroutine" / "must `await`" is a static, signature-level distinction                                        | no — any function may yield; no colours                                                                               |
| **WebAssembly**           | works: a state machine in linear memory; the _only_ viable path on wasm (see [wasm])                                    | D's `Fiber` literally `assert(0, "Fibers not supported on WASI")` — needs a native stack ([d-fiber], [wasm])          |

The last row is decisive for the survey's porting goal. WebAssembly exposes no addressable
machine stack to swap, so the stackful model has nothing to implement — D's `Fiber`
`assert(0)`s on WASI. A stackless state machine lives entirely in linear memory and is
therefore the only route to D coroutines on wasm; WasmFX/stack-switching is a separate,
_stackful_ runtime primitive that does not change which model the _language frontend_ must
lower. The full argument is in [wasm], with the WasmFX mechanism itself in [wasmfx].

---

## Where this leads

With the vocabulary fixed, the rest of the survey divides cleanly:

- **The mechanism** — how the state machine is actually built from `llvm.coro.*`
  intrinsics, the three LLVM lowering ABIs, the split passes: [llvm-coroutines] and its
  internals companion [llvm-internals].
- **The surface template** — the C++20 promise + awaiter + handle protocol the D design
  copies, and the full N4134/TS rationale: [cpp].
- **How other languages choose** between stackless and stackful, and how they handle
  colouring: [comparison].
- **The D stackful baseline** the new design argues against, in depth (assembly, GC race,
  thread migration, the WASI `assert`): [d-fiber].
- **Why stackless wins on wasm**, and how WasmFX relates: [wasm], [wasmfx].
- **The concrete LDC plan** that ties it together: [roadmap].

The connection to event loops — how a completed I/O operation resumes a suspended stackless
coroutine, the _waker / reified continuation_ role — is the subject of the sibling async-I/O
survey ([effects-event-loops], [async-io-index]); D's existing async landscape, built on the
stackful `Fiber`, is mapped in [d-landscape].

---

## Sources

- N4134, "Resumable Functions v.2" (Nishanov & Radigan, 2014-10-10) —
  `$REPOS/papers/n4134-resumable-functions-2014.pdf` (quotes verified
  against a `pdftotext -layout` extraction; `n4134:` line numbers reference that extraction).
- LLVM 23.0.0git coroutine specification —
  `$REPOS/llvm-project/llvm/docs/Coroutines.rst`.
- D stackful baseline (cross-referenced, not re-derived here):
  `$REPOS/dlang/ldc/runtime/druntime/src/core/thread/fiber/` — see
  [d-fiber].

<!-- References -->

[llvm-coroutines]: ./llvm-coroutines.md
[llvm-internals]: ./llvm-coro-internals.md
[cpp]: ./cpp-coroutines.md
[comparison]: ./comparison.md
[d-fiber]: ./d-fiber-baseline.md
[attributes]: ./attributes-and-memory.md
[wasm]: ./wasm-and-wasmfx.md
[roadmap]: ./roadmap.md
[wasmfx]: ../algebraic-effects/wasmfx.md
[effects-event-loops]: ../async-io/effects-and-event-loops.md
[async-io-index]: ../async-io/index.md
[d-landscape]: ../async-io/d-landscape.md
