# D's Stackful Baseline: `core.thread.Fiber` and `std.concurrency.Generator`

D already ships a coroutine primitive — but it is **stackful**: `core.thread.Fiber` allocates a full machine stack per instance and switches contexts with hand-written assembly. This doc characterizes that baseline narrowly: how the stack is allocated and sized, what the context switch costs, and why `Fiber.yield` can be `nothrow @nogc`. It is the cost model a compiler-lowered _stackless_ coroutine (the subject of the rest of this survey) is meant to improve on, and the reason D has **no** coroutine story on WebAssembly today.

**Last reviewed:** June 4, 2026

---

> [!NOTE]
> The broad D async/event-loop landscape — vibe.d / vibe-core / eventcore, Photon's transparent M:N scheduler, the `during` `io_uring` binding, `std.concurrency` message passing, and the Sparkles `io_uring`-first gap — is already surveyed in the sibling [D async landscape][d-landscape]. That doc treats `core.thread.Fiber` as a _runtime primitive for a loop designer_ (switch cost, default stack, the "M:N memory tax"). **This** doc does not restate it; it goes one layer deeper into the stackful primitive itself — the assembly switch, the GC stack-scan coupling, the LLVM TLS-migration hazard, and the `assert(0)` on wasm — to ground the contrast with [stackless coroutines][concepts]. Read the landscape doc for the ecosystem; read this for the cost model.

All druntime paths below are under `runtime/druntime/src/` in the LDC v1.42 tree (`$REPOS/dlang/ldc`); Phobos paths under `$REPOS/dlang/phobos`.

---

## The primitive: `Fiber` as a stackful coroutine

D's only first-class coroutine is `core.thread.Fiber`, a cooperative-concurrency abstraction split across two files: an OS-independent base class `FiberBase` in `core/thread/fiber/base.d`, and the platform- and assembly-bearing subclass `Fiber : FiberBase` in `core/thread/fiber/package.d`. Its own class documentation frames it as a blocking-call abstraction (`base.d:285`):

> "This class provides a cooperative concurrency mechanism integrated with the threading and garbage collection functionality. Calling a fiber may be considered a blocking operation that returns when the fiber yields (via `Fiber.yield()`)."

A fiber moves through a three-state machine (`base.d:511`):

```d
enum State { HOLD, EXEC, TERM }
```

`HOLD` is suspended, `EXEC` is running, `TERM` is finished — and a `TERM` fiber must be explicitly `reset()` before it can be reused. The control-surface is small and, crucially, the suspension operations carry strong attributes:

| Operation       | Signature                                                      | Source       | Notes                                                        |
| --------------- | -------------------------------------------------------------- | ------------ | ------------------------------------------------------------ |
| Resume          | `final Throwable call(Rethrow rethrow = Rethrow.yes)`          | `base.d:411` | Deliberately **un-attributed** — "calls arbitrary user code" |
| Suspend         | `static void yield() nothrow @nogc`                            | `base.d:583` | The defining yield point                                     |
| Suspend + throw | `static void yieldAndThrow(Throwable t) nothrow @nogc`         | `base.d:608` |                                                              |
| Current fiber   | `static FiberBase getThis() @safe nothrow @nogc`               | `base.d:642` | Reads TLS `sm_this`                                          |
| State query     | `final @property State state() const @safe pure nothrow @nogc` | `base.d:531` |                                                              |

The whole `call`/`yield` cycle is direct-style: a `Fiber` body is an ordinary `void function()` or `void delegate()` that can `yield()` from _any_ call depth, because the suspension is a raw stack switch rather than a return up a state machine. That generality — suspend anywhere, no function coloring — is exactly the ergonomic advantage of stackful coroutines noted in the [techniques taxonomy][async-io-index] and the cost the stackless model trades away for memory density (see [Concepts: stackful vs stackless][concepts]).

### Why `yield` is `static nothrow @nogc`

The single most load-bearing fact for the cost-model contrast is that **`Fiber.yield()` allocates nothing**. The body is just a state flip around a context switch (`base.d:583-595`):

```d
static void yield() nothrow @nogc
{
    FiberBase cur = getThis();
    assert( cur, "Fiber.yield() called with no active fiber" );
    assert( cur.m_state == State.EXEC );
    // ...
    cur.m_state = State.HOLD;
    cur.switchOut();
    cur.m_state = State.EXEC;
}
```

`yield` can be `@nogc` precisely because the expensive resource — the machine stack — was already reserved in the **constructor**, not at the yield point. The constructor is the opposite: `nothrow` but **not** `@nogc`, because it does `new StackContext` and `mmap`s a stack (`package.d:783`, `:805`):

```d
this( void function() fn, size_t sz = pageSize * defaultStackPages,
      size_t guardPageSize = pageSize ) nothrow;
this( void delegate() dg, size_t sz = pageSize * defaultStackPages,
      size_t guardPageSize = pageSize ) nothrow;
```

So the stackful model front-loads its allocation cost into construction and amortizes it across many cheap yields. This is excellent when fibers are long-lived and few; it is the _memory tax_ when fibers are numerous and short-lived (one per connection, one per generator), because every one of them pays for a full reserved stack whether it uses 200 bytes of live state or 200 KiB.

---

## The stack: allocation, sizing, and guard pages

### Default size — a multi-KiB floor per fiber

The default stack is `pageSize * defaultStackPages`. On most platforms `defaultStackPages` is 4 (`package.d:766`):

```d
else
    enum defaultStackPages = 4;
```

Windows uses 8 (DbgHelp.dll needs the headroom, `package.d:754`) and macOS-x86_64 uses 8 (libunwind on macOS 11+, `package.d:761`). With a 4 KiB page that is a **16 KiB stack on Linux** (32 KiB on Windows/macOS-x86_64); on macOS AArch64, whose page is 16 KiB, four pages is **64 KiB**. Every fiber then adds at least one **guard page** on top (`guardPageSize = pageSize`, default one page).

> [!IMPORTANT]
> On WASI, `pageSize` is hard-coded to 65536 (`core/memory.d:228`): `(cast() pageSize) = 65536;`. Four pages × 64 KiB would be **256 KiB per fiber** — _if_ fibers ran on wasm at all. They do not (see [§WebAssembly](#webassembly-the-stackful-model-stops-at-the-wasm-boundary)), but the number underlines how badly a 64-KiB-granularity reservation tax scales there.

### Allocation mechanism (POSIX)

`allocStack` (`package.d:857`) rounds the request up to a page multiple, then GC-allocates a `StackContext` (so the fiber object stays collectable), then `mmap`s the stack with an extra guard page (`package.d:876`, `:955`, `:961`):

```d
m_ctxt = new StackContext;           // package.d:876 — a GC allocation
// ...
sz += guardPageSize;                 // package.d:955 — extra page for the guard
int mmap_flags = MAP_PRIVATE | MAP_ANON;
m_pmem = mmap( null, sz, PROT_READ | PROT_WRITE, mmap_flags, -1, 0 );  // :961
```

Stacks grow down on nearly every arch (`StackGrowsDown`, `package.d:41`), so the base and top sit at the high end of the `mmap` region and the guard page lands at the **low** address (`package.d:984-989`):

```d
version (StackGrowsDown)
{
    m_ctxt.bstack = m_pmem + sz;
    m_ctxt.tstack = m_pmem + sz;
    void* guard = m_pmem;
}
```

The guard page is then `mprotect`'d to `PROT_NONE` (`package.d:1000-1005`):

```d
if (guardPageSize)
{
    // protect end of stack
    if ( mprotect(guard, guardPageSize, PROT_NONE) == -1 )
        abort();
}
```

The Windows path is analogous but uses `VirtualAlloc(MEM_RESERVE, PAGE_NOACCESS)`, commits the stack with `MEM_COMMIT`, and commits a `PAGE_GUARD` guard page (`package.d:886-923`). Freeing is symmetric and cheap: `freeStack()` (`package.d:1021`) `munmap`s (POSIX) or `VirtualFree`s (Windows) and is `nothrow @nogc`.

### Cost summary — the per-fiber tax

| Cost                  | Stackful `Fiber` (today)                                                                                                      | Source                           |
| --------------------- | ----------------------------------------------------------------------------------------------------------------------------- | -------------------------------- |
| Reserved memory       | **16 KiB stack + ≥4 KiB guard** (Linux default); 32–64 KiB elsewhere — _reserved whole_, even if a few hundred bytes are live | `package.d:766`, `:783`, `:955`  |
| Allocation            | 1 `mmap` + 1 GC alloc (`StackContext`) + 1 `mprotect` per fiber                                                               | `package.d:876`, `:961`, `:1003` |
| `@nogc` construction? | **No** — `new StackContext` + `mmap`                                                                                          | `package.d:876`, `:961`          |
| mmap-region pressure  | ≥1 mapping per fiber (+1 for the guard); an "OS-imposed limit may be hit"                                                     | `base.d:319-322` doc             |
| Stack growth          | **None** — fixed at creation; overflow traps on the guard page (SIGSEGV), it does not grow                                    | `package.d:1000-1005`            |
| Locality              | a deep, mostly-cold reserved stack per fiber → poor cache behavior                                                            | inherent                         |

The stack is **fixed**: there is no segmented or copying growth. A body that recurses past the reserved size faults on the guard page rather than expanding. This forces the designer to over-provision (waste memory) to be safe — the classic stackful dilemma that a compiler-computed stackless frame sidesteps.

---

## The context switch: hand-written assembly

The actual transfer is `fiber_switchContext`, an `extern (C)` symbol implemented in inline asm / `.S` files per architecture (`package.d:206`):

```d
extern (C) void fiber_switchContext( void** oldp, void* newp ) nothrow @nogc;
```

Its contract (`package.d:618-623`): `oldp` is _where to store the current stack pointer_, `newp` is _the stack pointer to switch into_. The conceptual algorithm (`package.d:625-634`) is "push return address; push registers; save sp into `*oldp`; load sp from `newp`; pop registers; pop return address; jump to it."

On the primary Linux target, x86-64 SysV, that is a tight sequence saving only the **callee-saved GPRs** (`package.d:543-575`):

```text
naked;
// save current stack state
push RBP;
mov  RBP, RSP;
push RBX; push R12; push R13; push R14; push R15;
// store oldp
mov [RDI], RSP;
// load newp to begin context switch
mov RSP, RSI;
// load saved state from new stack
pop R15; pop R14; pop R13; pop R12; pop RBX; pop RBP;
// 'return' to complete switch
pop RCX;
jmp RCX;
```

So one switch is **6 pushes + an sp store + an sp load + 6 pops + an indirect jump** — roughly a dozen memory operations and one mispredict-prone indirect branch, with **no heap allocation per switch** (the [landscape][d-landscape] summarizes this as "register save/restore + stack-pointer swap … no heap alloc per switch"). The x86-64 Windows variant is heavier — it also saves RDI, RSI, **XMM6–XMM15** (160 bytes of `movdqa`) and three `GS:[...]` TIB slots (`package.d:439-509`) — and AArch64 saves x19–x28, x29, x30 and d8–d15 (`switch_context_asm.S:833-861`). `switch_context_asm.S` carries the same routine for PPC64/PPC32, MIPS o32/64, LoongArch64, and ARM EABI; RISC-V lives in `switch_context_riscv.S`.

A subtle property: the asm deliberately positions the saved `sp` (the value written to `*oldp`) _above_ the saved FP registers and return address, so the GC, which scans from a fiber's stack base down to that saved `sp`, never scans the register-spill region (`package.d:636-643`):

> "By storing registers which can not contain references to memory managed by the GC outside of the region marked by the stack base pointer and the stack pointer saved in `fiber_switchContext` we can prevent the GC from scanning them."

### What the switch does _not_ save

The opacity of the asm switch has costs the stackless model would not pay. Floating-point **status/control** registers are per-thread, not per-fiber (`package.d:729-732`):

> "Status registers are not saved by the current implementations. This means floating point exception status bits (overflow, divide by 0), rounding mode and similar stuff is set per-thread, not per Fiber!"

And SjLj exception stacks must be swapped manually per fiber (`base.d:55-119`, `swapSjLjStackTop`). A compiler-lowered stackless coroutine, whose suspend points are ordinary stores of live SSA values into a frame struct (see [LDC codegen][ldc-codegen]), has nothing equivalent to forget.

---

## GC coupling: every fiber is a conservative scan range

Each live fiber registers a `StackContext` on a global intrusive list (`ThreadBase.add(m_ctxt)` at `package.d:1014`). The struct _is_ the scan descriptor (`core/thread/context.d:17`):

```d
struct StackContext
{
    void* bstack, tstack;                 // base / top-of-stack (scan range)
    void* ehContext;                      // EH per-stack state
    StackContext* within;                 // enclosing context (thread or outer fiber)
    StackContext* next, prev;             // intrusive global list
    version (SupportSanitizers_ABI) void* asan_fakestack;
}
```

The GC **conservatively** scans `[bstack .. tstack)` for every registered context. So _N_ fibers add _N_ extra conservative scan ranges to every collection, and the range depth grows with how deep each fiber's stack got — a GC-pause cost that scales with both fiber count and reserved depth. The `switchIn`/`switchOut` wrappers (`base.d:760`, `:854`) exist largely to keep this safe under a concurrent collection; their key invariant (`base.d:807-817`) is that the stack top must be published before `m_lock` is set, otherwise "a badly timed collection could cause the GC to scan from the bottom of one stack to the top of another." Both wrappers are `nothrow @nogc` and forced `pragma(inline, false)` on LDC.

By contrast a stackless coroutine frame is a flat, precisely-typed struct: the GC can scan it _exactly_ (following only the typed pointer fields), or skip it entirely if the coroutine is `@nogc`. The [attributes & memory][attributes] doc develops what precise scanning buys.

---

## The LDC migration hazard (an artifact of opacity)

Because the compiler cannot see _through_ `fiber_switchContext`, LDC has a documented thread-migration hazard. The note lives right in `getThis()` (`base.d:644-647`):

> "Currently, it is not safe to migrate fibers across threads when they use TLS at all, as LLVM might cache the TLS address lookup across a context switch (see https://github.com/ldc-developers/ldc/issues/666)."

The mitigation is precisely to defeat the optimizer: `getThis`, `switchIn`, and `switchOut` are all `version (LDC) pragma(inline, false)` (`base.d:653`) so the TLS load is not hoisted across the switch. Even so, `version(CheckFiberMigration)` (set for Darwin, Android, AArch64, PPC64, and any sanitizer build, `base.d:41-52`) makes resuming a fiber on a _different_ thread throw a `ThreadException` unless `allowMigration()` was called.

This hazard is **inherent to opaque stack switching** — the compiler emits a TLS load assuming the thread does not change under it, and the asm switch violates that assumption invisibly. A stackless lowering that the compiler _does_ see through has no such gap: there is no hidden control transfer to cache a TLS address across, so moving a suspended coroutine between threads is just moving a struct (see [comparison][comparison]).

---

## `std.concurrency.Generator`: a coroutine _built on_ the fiber

D's closest analog to a stackless generator is `std.concurrency.Generator`, and it is illuminating precisely because it is **library-level over `Fiber`, not a compiler lowering**. It literally _is_ a `Fiber` subclass that presents an `InputRange` (`std/concurrency.d:1754`):

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

The range surface maps one-to-one onto the fiber's resume/state primitives (`std/concurrency.d:1872-1891`):

```d
final bool empty() @property { return m_value is null || state == State.TERM; }
final void popFront()        { call(); }              // resume the fiber to the next yield
final T    front() @property { return *m_value; }
```

`popFront` **is** `Fiber.call` (resume); `front` dereferences a pointer-to-yielded-value stashed on the fiber. The producer side uses the free `yield(T)` function, which just routes to `Fiber.yield()` (`std/concurrency.d:1965-1974`):

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

The canonical example reads like a stackless generator from any other language (`std/concurrency.d:1947-1950`):

```d
auto r = new Generator!int({ foreach (i; 1 .. 10) yield(i); });
foreach (e; r)
    tid.send(e);
```

But the surface is a thin disguise over a full stackful fiber. Every `Generator!int` over that nine-element loop reserves a **16 KiB stack + guard page** (Linux), GC-allocates a `StackContext`, registers a conservative scan range, and inherits the non-`@nogc` constructor and the migration hazard — to hold what is, in live state, a single `int` counter and a return point. The same is true of `FiberScheduler` (`std/concurrency.d:1481`), which multiplexes `InfoFiber`s (another `Fiber` subclass) over one thread. **D today has no compiler-lowered stackless coroutine**; `Generator` is the proof that the abstraction people want is achievable, and the per-instance bill is the proof of why a stackless lowering is worth building.

> [!NOTE]
> A compiler-computed stackless frame is sized to _exactly the state live across suspension points_ — LLVM's `CoroSplit` pass performs precisely this frame-layout computation, turning the coroutine's live-across-suspend SSA values into fields of a heap (or caller-placed) frame struct. See [LLVM coroutines][llvm-coroutines] and [internals][llvm-internals] for how that minimum is derived. For the nine-`int` generator above, that frame is on the order of _tens of bytes_, against the fiber's tens of _kilobytes_.

---

## The scalability argument (N4134, made concrete)

The C++ coroutines proposal **N4134** ("Resumable Functions") makes the scalability case for stackless directly: a stackless coroutine's activation frame holds only the variables that must survive a suspension, so it can be **orders of magnitude smaller** than a reserved stack, and a system can keep _millions_ of suspended coroutines live where it could keep only thousands of fibers. The same argument animates Nishanov's LLVM-coroutines work (the `devmtg-2016` talk) and the design of `IORING`-driven runtimes that suspend one task per in-flight operation. The D baseline quantifies the gap exactly:

| Property             | Stackful `Fiber` (today)                                                        | Stackless (target)                                                                       | Evidence                             |
| -------------------- | ------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------ |
| Frame size           | Whole reserved stack (≥16 KiB + guard, Linux) regardless of live state          | Exactly the across-suspend live set; compiler-computed minimum                           | `package.d:766`, `:955`; `CoroSplit` |
| `@nogc` construction | No — `new StackContext` + `mmap`                                                | Frame is a plain struct, caller-placeable, `@nogc`-constructible                         | `package.d:876`, `:961`              |
| Reserved mappings    | ≥1 `mmap` (+guard) per instance; "OS-imposed limit may be hit"                  | None — frames packed in linear memory / a heap of the caller's choosing                  | `base.d:319-322`, `package.d:961`    |
| Context switch       | hand-asm `fiber_switchContext`: callee-saved push/pop + sp swap + indirect jump | resume = a `switch` on a state index + reload of saved locals; compiler-visible          | `package.d:543-575`                  |
| GC pressure          | each fiber = one conservative scan range on a global list                       | precise (typed) or zero scanning of the frame                                            | `context.d:17`, `package.d:1014`     |
| Thread migration     | unsafe under LDC (TLS-address caching across an opaque switch)                  | compiler-lowered; moving a suspended frame is moving a struct                            | `base.d:644-647`, `:769-790`         |
| FP status regs       | per-thread; silently lost across fibers                                         | nothing to save — no register-bank switch                                                | `package.d:729-732`                  |
| WebAssembly          | `assert(0, "Fibers not supported on WASI")`                                     | state-machine lowering runs in linear memory; WasmFX gives a native suspension primitive | `package.d:576-578`, `:1650-1652`    |

The framing of this matrix — _what a stackless lowering must preserve and what it gets to drop_ — is the through-line of [D language design][d-design] and the [roadmap][roadmap].

---

## WebAssembly: the stackful model stops at the wasm boundary

The decisive fact for the porting goal is blunt: **`Fiber` does not exist on wasm.** Both halves of the stackful machinery `assert(0)` on WASI. In the context switch (`package.d:576-578`):

```d
else version (WASI)
    assert(0, "Fibers not supported on WASI");
```

…and identically in `initStack` (`package.d:1650-1652`).

This is not an oversight; it is structural. The entire stackful design rests on a **native, addressable, downward-growing machine stack** with a raw `sp` register to swap and callee-saved registers to push (the asm in [§the context switch](#the-context-switch-hand-written-assembly)). WebAssembly exposes none of that: there is no linear machine stack you can point at, no `sp` register to overwrite, and the call stack lives in the engine, out of the module's reach. `fiber_switchContext` therefore has _nothing to implement_ on wasm, and so it asserts.

A **stackless** coroutine has the opposite property. Because its suspension points are statically known — they are the `await`/`yield` expressions the compiler can see — it can be lowered to a plain `switch`-on-state-index function whose frame lives in linear memory, with **no stack switching at all**. That compiles to ordinary wasm that runs on every engine. Where genuine direct-style suspension across opaque call boundaries is still wanted, **WasmFX / stack-switching** supplies a native suspension primitive at the engine level (`cont`/`resume`/`suspend`), which a _stackful_ fiber could be retargeted onto — but only WasmFX or Asyncify can stand in for the missing `sp` swap, whereas a stackless coroutine needs neither.

> [!IMPORTANT]
> The corollary for this survey: a stackful `Fiber` **cannot** be turned into a stackless state machine by `CoroSplit`, because its suspension points are _not statically visible_ — `yield()` can fire from any call depth, behind any indirect call. So on wasm a fiber needs Asyncify (whole-program CPS transform) or WasmFX (engine-level stack switching), while a stackless coroutine compiles to plain wasm directly. This split is exactly the design fork explored in [WebAssembly & WasmFX][wasm] and the [WasmFX deep-dive][wasmfx].

The bottom line: D's only coroutine primitive today is the **stackful** `Fiber` (with `Generator` and `FiberScheduler` layered on it). It is mature and direct-style, but it imposes a fixed multi-KiB reserved stack per instance, a GC-scanned `StackContext`, a non-`@nogc` allocating constructor, an LLVM-TLS thread-migration hazard, FP-status-register loss, and — decisively for the porting goal — **does not exist at all on wasm**. A compiler-lowered stackless coroutine eliminates each of these, and is the _only_ viable route to D coroutines on the WebAssembly / WasmFX target. That is the design space the rest of this survey opens; see [Concepts][concepts] for the model and the [roadmap][roadmap] for the plan.

---

## Sources

- `core/thread/fiber/base.d` (LDC v1.42 druntime) — `FiberBase`, `State`, `call`/`yield`/`getThis`/`state`, `switchIn`/`switchOut`, GC-suspend invariant, LDC migration note: `$REPOS/dlang/ldc/runtime/druntime/src/core/thread/fiber/base.d`
- `core/thread/fiber/package.d` (LDC v1.42 druntime) — constructors, `allocStack`/`freeStack`, `defaultStackPages`, guard page, `fiber_switchContext` (x86-64 SysV / Windows / ucontext), `initStack`, WASI `assert(0)`: `$REPOS/dlang/ldc/runtime/druntime/src/core/thread/fiber/package.d`
- `core/thread/context.d` — `StackContext` layout / GC scan range: `$REPOS/dlang/ldc/runtime/druntime/src/core/thread/context.d`
- `core/memory.d` — `pageSize` (WASI hard-coded 65536): `$REPOS/dlang/ldc/runtime/druntime/src/core/memory.d`
- `switch_context_asm.S` — per-arch `fiber_switchContext` (AArch64, PPC, MIPS, LoongArch, ARM): `$REPOS/dlang/ldc/runtime/druntime/src/core/thread/fiber/switch_context_asm.S`
- `std/concurrency.d` (Phobos) — `Generator(T) : Fiber, InputRange!T`, `empty`/`popFront`/`front`, free `yield(T)`, `FiberScheduler`: `$REPOS/dlang/phobos/std/concurrency.d`
- N4134 "Resumable Functions" (Gor Nishanov et al.) — stackless scalability argument: `$REPOS/papers/n4134`
- "LLVM Coroutines" (Nishanov, LLVM Dev Mtg 2016) — `CoroSplit` frame computation: `$REPOS/papers/llvm-coroutines-nishanov-devmtg-2016`
- ldc-developers/ldc issue #666 — TLS-address caching across a fiber context switch: https://github.com/ldc-developers/ldc/issues/666

<!-- References -->

[concepts]: ./concepts.md
[d-design]: ./d-language-design.md
[llvm-coroutines]: ./llvm-coroutines.md
[llvm-internals]: ./llvm-coro-internals.md
[comparison]: ./comparison.md
[ldc-codegen]: ./ldc-codegen.md
[attributes]: ./attributes-and-memory.md
[wasm]: ./wasm-and-wasmfx.md
[roadmap]: ./roadmap.md
[wasmfx]: ../algebraic-effects/wasmfx.md
[d-landscape]: ../async-io/d-landscape.md
[async-io-index]: ../async-io/index.md
