# D's Stackful Coroutine Primitive: `core.thread.Fiber`

This is the foundation leaf of the **stackful** track of the _Coroutines for LDC_
survey. D already ships a first-class coroutine — `core.thread.Fiber` — and it is
**stackful**: it allocates a full machine stack per instance and switches contexts
with hand-written assembly, so it can suspend from any nested call via `Fiber.yield()`.
This doc is the canonical characterization of that primitive: its API and lifecycle
(`call`/`yield`/`reset`, the `HOLD`/`EXEC`/`TERM` state machine), why the stack is
reserved in the constructor so that `Fiber.yield()` can be `nothrow @nogc`, the GC
coupling every fiber imposes, where D uses it today (`std.concurrency.Generator`,
vibe.d, Photon), and the per-instance costs that motivate **both** the stackless track
([concepts], [stackless-index]) and a future WasmFX target ([wasmfx-target], [wasm]).
The per-ABI register/SP/IP mechanics, the stack-sizing/growth design, and the
scheduling layer are delegated to sibling docs and only summarized here.

**Last reviewed:** June 4, 2026

---

## Where this sits

This doc is the **entry point to the stackful half** of the survey. It owns the D
primitive — what `Fiber` _is_, its surface, its cost — and hands every deeper question
to a dedicated leaf:

| Question                                                                                                   | Owned by                          |
| ---------------------------------------------------------------------------------------------------------- | --------------------------------- |
| What does the context switch _physically do_ per ABI (registers, SP, IP swap, `ucontext`/Boost reference)? | [context-switching]               |
| How big should a fiber stack be, and why can't it grow (segmented/copying stacks, Go's `copystack`)?       | [stack-management]                |
| Who multiplexes fibers onto threads (M:N schedulers, work-stealing, `FiberScheduler`, Go's G-M-P)?         | [green-threads]                   |
| What replaces the missing `sp`-swap on WebAssembly (`cont.new`/`resume`/`suspend`)?                        | [wasmfx-target], [wasm], [wasmfx] |
| What does the D async ecosystem _build_ on `Fiber` (vibe.d, Photon, `io_uring`)?                           | [d-landscape]                     |

> [!NOTE]
> The broad D async/event-loop landscape — vibe.d / vibe-core / eventcore, Photon's
> transparent M:N scheduler, the `during` `io_uring` binding, `std.concurrency` message
> passing, and the Sparkles `io_uring`-first gap — is surveyed in the sibling [D async
> landscape][d-landscape]. That doc treats `core.thread.Fiber` as a _runtime primitive a
> loop designer reaches for_ (switch cost, default stack, the "M:N memory tax"). **This**
> doc goes one layer deeper into the primitive itself — its API contract, the GC
> coupling, the LLVM TLS-migration hazard — to ground the stackful track. Read the
> landscape doc for the ecosystem; read this for the primitive.

All druntime paths below are under `runtime/druntime/src/` in the LDC v1.42 tree
(`$REPOS/dlang/ldc`); Phobos paths under `$REPOS/dlang/phobos`.

---

## The primitive: `Fiber` as a stackful coroutine

D's only first-class coroutine is `core.thread.Fiber`, a cooperative-concurrency
abstraction split across two files: an OS-independent base class `FiberBase` in
`core/thread/fiber/base.d`, and the platform- and assembly-bearing subclass
`Fiber : FiberBase` in `core/thread/fiber/package.d`. Its own class documentation frames
it as a blocking-call abstraction (`base.d:285`):

> "This class provides a cooperative concurrency mechanism integrated with the threading
> and garbage collection functionality. Calling a fiber may be considered a blocking
> operation that returns when the fiber yields (via `Fiber.yield()`)."

This is the defining stackful property, in N4134's vocabulary ([concepts]): a fiber's
saved state _is_ the full call stack, so `Fiber.yield()` can fire from **any call
depth** — behind any number of ordinary, non-coroutine-aware function frames — and the
whole stack slice survives the suspension. There is no function "coloring": a `Fiber`
body is an ordinary `void function()` or `void delegate()` that can yield from anywhere
it (transitively) calls. That _suspend-anywhere_ generality is exactly the ergonomic
advantage of stackful coroutines, and the cost the stackless model trades away for memory
density (see [Concepts: the tradeoff][concepts]).

---

## API & lifecycle

The control surface is small. A fiber moves through a **three-state machine**
(`base.d:510-521`):

```d
/// A fiber may occupy one of three states: HOLD, EXEC, and TERM.
enum State
{
    HOLD,   // suspended and ready to be resumed, or not yet started
    EXEC,   // currently executing
    TERM    // terminated; must be reset() before it may be called again
}
```

`HOLD` is suspended (this is also a fiber's state immediately after construction, before
its first `call`); `EXEC` is running; `TERM` is finished. The lifecycle threads through
these states via four operations, and — crucially — the suspension operations carry strong
attributes while resumption deliberately carries none:

| Operation       | Signature                                                      | Source       | Notes                                      |
| --------------- | -------------------------------------------------------------- | ------------ | ------------------------------------------ |
| Resume          | `final Throwable call(Rethrow rethrow = Rethrow.yes)`          | `base.d:411` | Deliberately **un-attributed** (see below) |
| Suspend         | `static void yield() nothrow @nogc`                            | `base.d:583` | The defining yield point                   |
| Suspend + throw | `static void yieldAndThrow(Throwable t) nothrow @nogc`         | `base.d:608` | Resumes the caller _and_ injects a throw   |
| Reset / reuse   | `final void reset() nothrow @nogc`                             | `base.d:478` | A `TERM` (or `HOLD`) fiber → fresh `HOLD`  |
| Current fiber   | `static FiberBase getThis() @safe nothrow @nogc`               | `base.d:642` | Reads TLS `sm_this`                        |
| State query     | `final @property State state() const @safe pure nothrow @nogc` | `base.d:531` |                                            |

### The `call` → run → `yield` cycle

`call()` resumes a `HOLD` fiber (`base.d:397`: "This fiber must be in state HOLD"). It
runs the body until the body either calls `Fiber.yield()` (back to `HOLD`) or returns /
throws (to `TERM`). On the producer side, `Fiber.yield()` is the symmetric suspend: flip
to `HOLD`, switch out to the resumer, and — when next `call`ed — resume right after the
`yield` (`base.d:583-595`):

```d
static void yield() nothrow @nogc
{
    FiberBase cur = getThis();
    assert( cur, "Fiber.yield() called with no active fiber" );
    assert( cur.m_state == State.EXEC );
    // ...
    cur.m_state = State.HOLD;
    cur.switchOut();           // suspend; control returns to whoever call()ed us
    cur.m_state = State.EXEC;  // a later call() resumes execution exactly here
}
```

The first `call` is special only in where it lands: the very first switch jumps to
`fiber_entryPoint`, the synthetic bottom frame of every fiber stack, which runs the user
body and on completion performs a final, never-returning `switchOut` to its resumer
(`base.d:129-158`):

```d
extern (C) void fiber_entryPoint() nothrow @assumeUsed
{
    FiberBase obj = FiberBase.getThis();
    // ... obj.m_state = State.EXEC ...
    try { obj.run(); }                       // run() -> the user fn/delegate
    catch ( Throwable t ) { obj.m_unhandled = t; }
    obj.m_state = Fiber.State.TERM;
    obj.switchOut();                          // final switch back; never returns
}
```

How that first switch is _primed_ to look like a return into `fiber_entryPoint` — the
"fake initial frame" `initStack` hand-builds, and the per-ABI register layout it must
mirror — is the subject of [context-switching]; this doc treats `call`/`yield` as the
black-box surface.

### Why `call` is un-attributed but `yield` is `nothrow @nogc`

`call` is the only operation in the table with **no** safety attributes, and the reason is
documented inline (`base.d:406-410`):

> "Not marked with any attributes, even though `nothrow @nogc` works because it calls
> arbitrary user code. Most of the implementation is already `@nogc nothrow`, but in order
> for `Fiber.call` to propagate the attributes of the user's function, the `Fiber` class
> needs to be templated."

So the un-attributed surface is a deliberate ergonomic choice: `call` runs arbitrary user
code, and rather than fix a too-strict attribute set, the class leaves `call` open. The
`nothrow @nogc` engine underneath (`callImpl`, `base.d:432`) drives `switchIn` and, when
the body has reached `TERM`, resets the stack pointers so a dead fiber's stack is no longer
GC-scanned (`base.d:455-462`). `yield`, by contrast, _is_ `nothrow @nogc` — and that fact
is the most load-bearing one in the entire cost model.

### `reset` — fibers are reusable

A `TERM` fiber is not garbage; it is _spent_. `reset()` rewinds it to a fresh `HOLD` so the
same allocated stack can run a new (or the same) body (`base.d:472-486`):

```d
final void reset() nothrow @nogc
in (m_state == State.TERM || m_state == State.HOLD)
{
    // ... rewind the stack pointer, re-prime the initial frame ...
    m_state = State.HOLD;
}
```

This is what makes a `Fiber` _pool_ viable: the expensive resource (the stack) is allocated
once and recycled across many bodies, amortizing the non-`@nogc` construction cost. `reset`
itself is `nothrow @nogc`.

---

## Why the constructor pays and `yield` does not

`yield` can be `@nogc` precisely because the expensive resource — the machine stack — was
already reserved in the **constructor**, not at the yield point. The constructor is the
opposite: `nothrow` but **not** `@nogc`, because it `new`s a `StackContext` and `mmap`s a
stack (`package.d:783`, `:805`):

```d
this( void function() fn, size_t sz = pageSize * defaultStackPages,
      size_t guardPageSize = pageSize ) nothrow;
this( void delegate() dg, size_t sz = pageSize * defaultStackPages,
      size_t guardPageSize = pageSize ) nothrow;
```

The stackful model front-loads its allocation cost into construction and amortizes it
across many cheap yields (and, via `reset`, across many bodies). This is excellent when
fibers are long-lived and few; it is the _memory tax_ when fibers are numerous and
short-lived (one per connection, one per generator), because every one of them pays for a
full reserved stack whether it holds 200 bytes of live state or 200 KiB.

The default stack is `pageSize * defaultStackPages`, which is **16 KiB on Linux** (4 pages
× 4 KiB), 32 KiB on Windows/macOS-x86_64, and 64 KiB on macOS-AArch64 (4 × 16 KiB page) —
plus at least one guard page on top (`package.d:766`, `:783`). The mechanism (`allocStack`
→ `mmap` + a `PROT_NONE`/`PAGE_GUARD` guard page, `package.d:857-1015`), the per-platform
sizing rationale, the **fixed, never-growing** nature of the stack (overflow traps on the
guard page rather than copying to a bigger stack the way Go does), and the
over-provisioning dilemma it forces are all developed in [stack-management]. The
single fact this doc needs from it is the shape of the cost.

### The per-fiber tax, summarized

| Cost                  | Stackful `Fiber` (today)                                                                                                      | Source                                                   |
| --------------------- | ----------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| Reserved memory       | **16 KiB stack + ≥4 KiB guard** (Linux default); 32–64 KiB elsewhere — _reserved whole_, even if a few hundred bytes are live | `package.d:766`, `:783`, `:955` (see [stack-management]) |
| Allocation            | 1 `mmap` + 1 GC alloc (`StackContext`) + 1 `mprotect` per fiber                                                               | `package.d:876`, `:961`, `:1003`                         |
| `@nogc` construction? | **No** — `new StackContext` + `mmap`                                                                                          | `package.d:876`, `:961`                                  |
| mmap-region pressure  | ≥1 mapping per fiber (+1 for the guard); an "OS-imposed limit may be hit"                                                     | `base.d:319-322` doc                                     |
| Stack growth          | **None** — fixed at creation; overflow traps on the guard page (SIGSEGV), it does not grow                                    | `package.d:1000-1005` (see [stack-management])           |
| Context switch        | hand-asm `fiber_switchContext`: callee-saved push/pop + sp swap + indirect jump; **no heap alloc per switch**                 | `package.d:543-575` (see [context-switching])            |
| GC scan range         | each live fiber = one conservative scan range on a global intrusive list                                                      | `context.d:17`, `package.d:1014`                         |

The context switch itself — `fiber_switchContext(void** oldp, void* newp)`, the
callee-saved register save/restore, the SP/IP swap, and the per-ABI assembly (x86-64 SysV,
AArch64, RISC-V, the `ucontext` fallback, Boost.Context and Windows Fibers as reference
points) — is the entire subject of [context-switching]. The one property this doc carries
forward is that a switch does **no heap allocation** and **no syscall**: it is a dozen-odd
user-space memory ops plus one indirect branch, which is why `yield` is `@nogc` and why a
fiber switch is orders of magnitude cheaper than an OS thread switch.

---

## GC coupling: every fiber is a conservative scan range

Each live fiber registers a `StackContext` on a global intrusive list
(`ThreadBase.add(m_ctxt)` at `package.d:1014`). The struct _is_ the scan descriptor
(`core/thread/context.d:17`):

```d
struct StackContext
{
    void* bstack, tstack;                 // base / top-of-stack (conservative scan range)
    void* ehContext;                      // EH per-stack state
    StackContext* within;                 // enclosing context (thread or outer fiber)
    StackContext* next, prev;             // intrusive global list
    version (SupportSanitizers_ABI) void* asan_fakestack;
}
```

The GC **conservatively** scans `[bstack .. tstack)` for every registered context. So _N_
fibers add _N_ extra conservative scan ranges to every collection, and the range depth
grows with how deep each fiber's stack got — a GC-pause cost that scales with both fiber
count and reserved depth. The `switchIn`/`switchOut` wrappers (`base.d:760`, `:854`) exist
largely to keep this safe under a concurrent collection; their key invariant
(`base.d:807-817`) is that the stack top must be published before `m_lock` is set,
otherwise "a badly timed collection could cause the GC to scan from the bottom of one stack
to the top of another." Both wrappers are `nothrow @nogc` and forced
`pragma(inline, false)` on LDC.

The context switch deliberately cooperates with this: it positions the saved `sp` (the
value written to `*oldp`) _above_ the saved FP registers and return address, so the GC,
which scans from a fiber's stack base down to that saved `sp`, never scans the
register-spill region (`package.d:636-643`):

> "By storing registers which can not contain references to memory managed by the GC
> outside of the region marked by the stack base pointer and the stack pointer saved in
> `fiber_switchContext` we can prevent the GC from scanning them."

The full FP-below-SP layout, and how each ABI biases its published SP to achieve it, are in
[context-switching].

> [!NOTE]
> This conservative, per-fiber scan range is one of the costs a **stackless** lowering
> drops outright. A stackless coroutine frame is a flat, precisely-typed struct: the GC can
> scan it _exactly_ (following only the typed pointer fields), or skip it entirely if the
> coroutine is `@nogc`. See [Concepts][concepts] and the stackless [attributes & memory][attributes]
> doc.

---

## The LDC thread-migration hazard

Because the compiler cannot see _through_ `fiber_switchContext` (it is `extern (C)` asm),
LDC has a documented thread-migration hazard. The note lives right in `getThis()`
(`base.d:644-647`):

> "Currently, it is not safe to migrate fibers across threads when they use TLS at all, as
> LLVM might cache the TLS address lookup across a context switch (see
> https://github.com/ldc-developers/ldc/issues/666)."

The mitigation is precisely to defeat the optimizer: `getThis`, `switchIn`, and `switchOut`
are all `version (LDC) pragma(inline, false)` (`base.d:653`) so the TLS load is not hoisted
across the switch. Even so, `version (CheckFiberMigration)` — set for Darwin, Android,
AArch64, PPC64, and any sanitizer build (`base.d:41-52`) — makes resuming a fiber on a
_different_ thread throw a `ThreadException` unless `allowMigration()` was called.

This hazard is **inherent to opaque stack switching**: the compiler emits a TLS load
assuming the thread does not change under it, and the asm switch violates that assumption
invisibly. It is the same hazard Java Loom hits ("`Thread.currentThread()` can change
mid-method", see [java-loom]) and that Windows answers with Fiber-Local Storage. A stackless
lowering the compiler _does_ see through has no such gap: there is no hidden control transfer
to cache a TLS address across, so moving a suspended coroutine between threads is just moving
a struct ([concepts]).

---

## `std.concurrency.Generator`: a range _built on_ the fiber

D's closest analog to a stackless generator is `std.concurrency.Generator`, and it is
illuminating precisely because it is **library-level over `Fiber`, not a compiler
lowering**. It literally _is_ a `Fiber` subclass that presents an `InputRange`
(`std/concurrency.d:1754`):

```d
class Generator(T) :
    Fiber, IsGenerator, InputRange!T
```

Construction runs the body once to prime `front` (`std/concurrency.d:1768-1772`):

```d
this(void function() fn)
{
    super(fn);
    call();
}
```

The range surface maps one-to-one onto the fiber's resume/state primitives
(`std/concurrency.d:1872-1891`):

```d
final bool empty() @property { return m_value is null || state == State.TERM; }
final void popFront()        { call(); }              // resume the fiber to the next yield
final T    front() @property { return *m_value; }
```

`popFront` **is** `Fiber.call` (resume); `front` dereferences a pointer-to-yielded-value
stashed on the fiber; `empty` reads the `TERM` state. The producer side uses the free
`yield(T)` function, which just routes to `Fiber.yield()` (`std/concurrency.d:1965-1974`):

```d
void yield(T)(ref T value)
{
    Generator!T cur = cast(Generator!T) Fiber.getThis();
    if (cur !is null && cur.state == Fiber.State.EXEC)
    {
        cur.m_value = &value;
        return Fiber.yield();
    }
    throw new Exception("yield(T) called with no active generator for the supplied type");
}
```

The canonical example reads like a stackless generator from any other language
(`std/concurrency.d:1947-1953`):

```d
auto r = new Generator!int({ foreach (i; 1 .. 10) yield(i); });
foreach (e; r)
    tid.send(e);
```

But the surface is a thin disguise over a full stackful fiber. Every `Generator!int` over
that nine-element loop reserves a **16 KiB stack + guard page** (Linux), GC-allocates a
`StackContext`, registers a conservative scan range, and inherits the non-`@nogc`
constructor and the migration hazard — to hold what is, in live state, a single `int`
counter and a return point. The same is true of `FiberScheduler` (`std/concurrency.d:1481`),
which multiplexes `InfoFiber`s (another `Fiber` subclass, `std/concurrency.d:1573`) over one
thread — the simplest cooperative scheduler in the standard library, and the entry point to
the scheduling discussion in [green-threads].

**D today has no compiler-lowered stackless coroutine**; `Generator` is the proof that the
abstraction people want is achievable on the stackful primitive, and the per-instance bill
is the proof of why a stackless lowering is worth building.

> [!NOTE]
> A compiler-computed stackless frame is sized to _exactly the state live across suspension
> points_ — for the nine-`int` generator above, on the order of _tens of bytes_, against the
> fiber's tens of _kilobytes_. LLVM's `CoroSplit` performs precisely this frame-layout
> computation. See [stackless coroutines][stackless-index] and [Concepts][concepts].

---

## Where D uses `Fiber` today

`Fiber` is not a curiosity; it is the substrate of D's entire direct-style async story. The
[D async landscape][d-landscape] is the full map; the short version of what builds on the
primitive:

| Consumer                             | What it does with `Fiber`                                                                                                                                                                                                    |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`std.concurrency.Generator`**      | A `Fiber` subclass presenting an `InputRange` (above); the standard-library "generator".                                                                                                                                     |
| **`std.concurrency.FiberScheduler`** | Multiplexes `InfoFiber`s over one thread — the stdlib's minimal cooperative scheduler (`std/concurrency.d:1481`).                                                                                                            |
| **vibe.d / vibe-core**               | A `Task` _is_ a vibe fiber. It issues a read, the event driver registers the FD, the fiber `yield`s, and vibe-core resumes it from the completion callback. To user code the call simply _blocks_. The dominant D web stack. |
| **Photon (DLang)**                   | A transparent M:N scheduler: it intercepts libc syscalls and parks the calling fiber on a would-block, resuming it on readiness — so unmodified blocking code runs cooperatively.                                            |

The unifying pattern is **fiber-per-task, direct-style blocking-looking code**: you write
code that _looks_ synchronous, and the framework parks the fiber on a would-block and
resumes it on readiness. This is exactly the _suspend-anywhere_ property — the yield happens
deep inside an ordinary socket-read call, not at a lexical `await` the user wrote — and it is
why D's async ecosystem reached for stackful fibers in the first place. The scheduling half
of this story (how readiness re-injects a fiber, M:N vs 1:1, work-stealing) is [green-threads];
the I/O half is [d-landscape] and the cross-tree [async-io survey][async-io-index].

---

## The costs that motivate the rest of the survey

The stackful `Fiber` is mature, direct-style, and ergonomically excellent — but every
property above carries a cost that the survey's two forward tracks exist to address. The
costs cluster into two motivations.

### Motivation 1 — a stackless track ([stackless-index], [concepts])

A compiler-lowered stackless coroutine eliminates the per-instance tax, point for point:

| Property             | Stackful `Fiber` (today)                                               | Stackless (target)                                                              | Evidence                                 |
| -------------------- | ---------------------------------------------------------------------- | ------------------------------------------------------------------------------- | ---------------------------------------- |
| Frame size           | Whole reserved stack (≥16 KiB + guard, Linux) regardless of live state | Exactly the across-suspend live set; compiler-computed minimum                  | `package.d:766`, `:955`; `CoroSplit`     |
| `@nogc` construction | No — `new StackContext` + `mmap`                                       | Frame is a plain struct, caller-placeable, `@nogc`-constructible                | `package.d:876`, `:961`                  |
| Reserved mappings    | ≥1 `mmap` (+guard) per instance; "OS-imposed limit may be hit"         | None — frames packed in linear memory / a heap of the caller's choosing         | `base.d:319-322`, `package.d:961`        |
| Context switch       | hand-asm `fiber_switchContext` (see [context-switching])               | resume = a `switch` on a state index + reload of saved locals; compiler-visible | `package.d:543-575`                      |
| GC pressure          | each fiber = one conservative scan range on a global list              | precise (typed) or zero scanning of the frame                                   | `context.d:17`, `package.d:1014`         |
| Thread migration     | unsafe under LDC (TLS-address caching across an opaque switch)         | compiler-lowered; moving a suspended frame is moving a struct                   | `base.d:644-647`                         |
| Suspend scope        | **anywhere** — from any nested call depth                              | only at _lexical_ await/yield points in this coroutine's own body               | (the one axis stackful wins; [concepts]) |

Note the last row: the stackful model is **not strictly worse**. Suspend-anywhere is a real
capability the stackless model cannot match — direct-style code where any nested call may
block. The survey's thesis is not "stackless replaces stackful" but "D needs _both_, and a
stackless track is the missing one" ([concepts], [stackless-index]).

### Motivation 2 — a WasmFX target ([wasmfx-target], [wasm])

The decisive fact for the WebAssembly porting goal is blunt: **`Fiber` does not exist on
wasm.** Both halves of the stackful machinery `assert(0)` on WASI — in the context switch
(`package.d:576-578`) and identically in `initStack` (`package.d:1650-1652`):

```d
else version (WASI)
    assert(0, "Fibers not supported on WASI");
```

This is structural, not an oversight. The entire stackful design rests on a **native,
addressable, downward-growing machine stack** with a raw `sp` register to swap and
callee-saved registers to push. WebAssembly exposes none of that: there is no linear machine
stack you can point at, no `sp` register to overwrite, and the call stack lives in the
engine, out of the module's reach. `fiber_switchContext` therefore has _nothing to
implement_ on wasm, and so it asserts.

> [!IMPORTANT]
> A stackful `Fiber` **cannot** be turned into a stackless state machine by `CoroSplit`,
> because its suspension points are _not statically visible_ — `yield()` can fire from any
> call depth, behind any indirect call. So on wasm a fiber needs Asyncify (whole-program CPS
> transform) or **WasmFX** (engine-level stack switching: `cont.new`/`resume`/`suspend`),
> while a stackless coroutine compiles to plain wasm directly. WasmFX is the native
> suspension primitive a _stackful_ `Fiber` could be retargeted onto — the missing `sp`-swap,
> supplied at the engine level. This is the entire subject of [WasmFX as a Fiber
> target][wasmfx-target], the survey's [wasm] doc, and the algebraic-effects [WasmFX
> deep-dive][wasmfx].

---

## Bottom line

D's only coroutine primitive today is the **stackful** `Fiber` (with `Generator` and
`FiberScheduler` layered on it, and vibe.d / Photon building real async stacks on top of
it). It is mature and direct-style — its `suspend-anywhere` `yield()` is its defining
strength — but it imposes a fixed multi-KiB reserved stack per instance, a GC-scanned
`StackContext` on every collection, a non-`@nogc` allocating constructor, an LLVM-TLS
thread-migration hazard, and — decisively for the porting goal — **does not exist at all on
wasm**. Those costs are the reason the survey has two forward tracks: a **stackless** track
([stackless-index], [concepts]) that gives D a memory-dense, `@nogc`-friendly,
plain-wasm-compatible coroutine for the cases where lexical suspend points suffice, and a
**WasmFX target** ([wasmfx-target], [wasm]) that gives the stackful `Fiber` a native
suspension primitive on WebAssembly. The deeper mechanics of the primitive itself continue
in [context-switching] (the switch), [stack-management] (the stack), and [green-threads]
(the scheduler).

---

## Sources

- `core/thread/fiber/base.d` (LDC v1.42 druntime) — `FiberBase`, `State`,
  `call`/`callImpl`/`yield`/`yieldAndThrow`/`reset`/`getThis`/`state`, `fiber_entryPoint`,
  `switchIn`/`switchOut`, the GC-suspend invariant, the LDC migration note and
  `CheckFiberMigration`: `$REPOS/dlang/ldc/runtime/druntime/src/core/thread/fiber/base.d`
- `core/thread/fiber/package.d` (LDC v1.42 druntime) — constructors, `allocStack`,
  `defaultStackPages`, guard page, `fiber_switchContext` (x86-64 SysV), the FP-below-SP GC
  comment, the WASI `assert(0)`:
  `$REPOS/dlang/ldc/runtime/druntime/src/core/thread/fiber/package.d`
- `core/thread/context.d` — `StackContext` layout / GC scan range:
  `$REPOS/dlang/ldc/runtime/druntime/src/core/thread/context.d`
- `std/concurrency.d` (Phobos) — `Generator(T) : Fiber, InputRange!T`, `empty`/`popFront`/`front`,
  free `yield(T)`, `FiberScheduler`/`InfoFiber`: `$REPOS/dlang/phobos/std/concurrency.d`
- ldc-developers/ldc issue #666 — TLS-address caching across a fiber context switch:
  https://github.com/ldc-developers/ldc/issues/666
- Sibling stackful-track docs (mechanism, stack, scheduler, wasm): [context-switching],
  [stack-management], [green-threads], [wasmfx-target]; the stackless contrast: [concepts],
  [stackless-index]; the D ecosystem on `Fiber`: [d-landscape].

<!-- References -->

[concepts]: ../concepts.md
[wasm]: ../wasm-and-wasmfx.md
[stackless-index]: ../stackless/index.md
[attributes]: ../stackless/attributes-and-memory.md
[context-switching]: ./context-switching.md
[green-threads]: ./green-threads.md
[stack-management]: ./stack-management.md
[wasmfx-target]: ./wasmfx-as-target.md
[wasmfx]: ../../algebraic-effects/wasmfx.md
[java-loom]: ../../algebraic-effects/java-loom.md
[async-io-index]: ../../async-io/index.md
[d-landscape]: ../../async-io/d-landscape.md
