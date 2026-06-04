# Stack Management for Stackful Coroutines: Fixed, Segmented, Growable

A stackful coroutine — fiber, green thread, user-mode thread — captures its _whole call stack_, so its per-instance memory footprint is dominated by a real machine stack. This doc is the design-space layer beneath the [D `Fiber` baseline][d-fiber]: the one cost knob the entire stackful model lives or dies on, _how big is the stack and does it grow?_ There are exactly three answers — **fixed reserved**, **segmented/split**, and **contiguous growable** — and the choice is decided by a single question: does the runtime have **precise stack maps**? D does not, which is why D `Fiber` is stuck with fixed reserved stacks and pays the full N4134 memory tax that a [stackless frame][concepts] avoids.

**Last reviewed:** June 4, 2026

---

> [!NOTE]
> This doc deliberately does _not_ restate what its two siblings already establish. The [D `Fiber` deep-dive][d-fiber] owns the concrete D numbers — the 16 KiB default, the `mmap` + `mprotect` mechanism, the conservative GC-scan coupling, the WASI `assert(0)`. The [concepts leaf][concepts] owns the N4134 stackless-vs-stackful framing — the address-space-exhaustion quote and the segmented/fixed-stack rejection table. **This** doc is the _growth design space_: it cites those two for the quotes and the D specifics, and spends its words on the three growth strategies, the Go contiguous-copy machinery in detail, and where D's fixed choice sits in that space.

All `runtime/*` paths below are under `$REPOS/go/go/src/runtime/` (note the doubled `go/go`); the Go checkout is tip/dev (June 2026), so line numbers may drift a few lines against upstream master — the quoted text is the stable anchor. D druntime paths are under `$REPOS/dlang/ldc/runtime/druntime/src/`.

---

## The taxonomy: three answers to "how big, and does it grow?"

| Strategy                | "How big"                                      | Growth mechanism                                                             | Needs a managed runtime?                         | Used by                                                                                            |
| ----------------------- | ---------------------------------------------- | ---------------------------------------------------------------------------- | ------------------------------------------------ | -------------------------------------------------------------------------------------------------- |
| **Fixed reserved**      | one size chosen at creation; never changes     | none — overflow **traps** on a guard page                                    | no                                               | D `Fiber`, POSIX `makecontext`/`ucontext`, Win32 Fibers, Boost.Context, most C/C++ fiber libraries |
| **Segmented / split**   | starts tiny; **linked chunks** added on demand | allocate a non-contiguous segment, chain it; free on unwind                  | needs compiler split-stack prologues             | **Go 2011–2014** (abandoned), **Rust pre-1.0** (abandoned), gccgo (`-fsplit-stack`)                |
| **Contiguous growable** | starts tiny (~2 KiB); **doubles**              | allocate a 2× stack, **copy** old → new, **relocate** every interior pointer | **yes** — precise stack maps + GC-grade metadata | **Go today**                                                                                       |

The axis that decides which is _feasible_ is **whether the runtime can find and rewrite every pointer that points into the stack**. Fixed reserved needs nothing — the stack never moves. Segmented needs cooperative prologues (every function bounds-checks `SP`). Contiguous-growable needs the runtime to relocate all interior pointers when it moves the stack — which is GC-grade per-frame metadata, present in Go and absent for arbitrary C-ABI frames. That single fact is what puts "Go-style growable stacks" off the table for D/LDC (see [§Why this matters for D/LDC](#why-this-matters-for-d--ldc)).

---

## Fixed reserved stacks — the classic fiber model

**Mechanism.** Reserve `N` bytes of stack per coroutine at creation; the stack never moves and never grows. Overflow is caught _structurally_ by a **guard page** — an unmapped / `PROT_NONE` page below the stack — that faults the moment the running code touches it. This is exactly what D's `Fiber` does, and what nearly every non-managed fiber library ships.

### D `Fiber` is the canonical witness

D's `Fiber.allocStack` (`package.d:857`) rounds the request to a page multiple, then `mmap`s (POSIX) or `VirtualAlloc`s (Windows) a single fixed region plus one guard page. The guard sits at the low address (stacks grow down) and is `mprotect`'d to `PROT_NONE` so a stack-depth overflow faults rather than silently scribbling past the end. The concrete D mechanism and its exact sizing — 4 pages = 16 KiB on Linux by default, 8 on Windows/macOS-x86_64 — are dissected in the [baseline doc][d-fiber]; the load-bearing property here is the one in its cost table (`d-fiber.md`):

> "Stack growth — **None** — fixed at creation; overflow traps on the guard page (SIGSEGV), it does not grow."

There is no `morestack`-equivalent in `package.d`: the POSIX path installs the guard with `mprotect(guard, guardPageSize, PROT_NONE)` (`package.d:1000-1005`) and stops there. Nothing catches the resulting `SIGSEGV` to grow the stack — a body that recurses past the reserved size simply faults. (Some C fiber libraries _do_ install a SIGSEGV handler that auto-grows; D does not.)

### A virtual / resident split worth stating precisely

The two D paths differ in _commit_ granularity, and it matters for the address-space argument:

- **POSIX** — `mmap(..., PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, ...)` reserves _and_ makes the whole region accessible, but Linux is **demand-paged**, so physical pages are allocated only on first touch. Virtual address space is consumed up front (the full `sz`), but RSS grows lazily with the depth actually used. So a Linux fiber is "16 KiB virtual, but only as-many-KiB-as-touched resident."
- **Windows** — `MEM_RESERVE` reserves address space without backing pages; this druntime path then `MEM_COMMIT`s the _entire_ reserved stack eagerly (`package.d:886-907`), rather than leaning on Windows' auto-grow guard-page mechanism.

### Memory cost & the 32-bit address-space exhaustion problem

This is N4134's headline argument against general-purpose stackful coroutines. The full quote — "reserve default stack for every coroutine (1MB on Windows, 2MB on Linux) will exhaust all available virtual memory in 32-bit address space with only a few thousand coroutines" — is already in the [concepts leaf][concepts] (§Memory, `n4134:142-148`); see there rather than re-quoting it. The arithmetic: a 32-bit process has ~2–3 GiB of usable user address space, so at 1 MiB reserved per fiber it exhausts the address space at only **~2,000–3,000 fibers**, even when each holds "as small as a few bytes" of live state.

On 64-bit the _virtual_ exhaustion mostly disappears (a 48-bit address space holds millions of 1 MiB reservations), but three costs survive:

1. **RSS** still grows with stacks actually touched — demand paging helps only if stacks stay shallow.
2. **mmap-region pressure** — each fiber is ≥1 mapping (+1 for the guard); the [baseline][d-fiber] flags that "an OS-imposed limit may be hit" (`base.d:322`). Linux's default `vm.max_map_count` is 65 530, and a guard page **doubles** the VMA count per fiber, so ~32 k fibers can exhaust the VMA table independently of how much memory is free.
3. **Fragmentation** (below).

### Fragmentation

Fixed reserved stacks are large, individually-mapped regions of _heterogeneous lifetime_. Freeing one leaves a coroutine-stack-sized hole that only another similarly-sized stack can fill, fragmenting both the virtual address space (on 32-bit) and the page tables. N4134 makes the same point — that the platform "also commits first two pages of the stack ... even though the actual state required by a coroutine could be as small as a few bytes" (quoted in [concepts][concepts], `n4134:142-148`). Go's contiguous model routes around this by allocating small stacks from a **span-based pool keyed by size order** rather than one ad-hoc `mmap` per stack (see [§The allocator](#the-allocator-span-pool-not-per-stack-mmap)).

### Why fixed reserved is still the default everywhere

Despite the costs, fixed reserved is what almost every non-managed fiber library ships, because it requires **zero runtime metadata and zero compiler cooperation**: a fiber body is an _ordinary_ `void function()` that calls _ordinary_ C-ABI code, and the only overflow mechanism is a hardware guard page the OS provides for free. N4134's own analysis (in [concepts][concepts], `n4134:150-156`) rejects _both_ cheaper alternatives — segmented (needs whole-program split-stack support) and small-fixed (restricts what you can call) — precisely because they break "seamless interaction with existing facilities." Fixed reserved is the conservative floor: pay the memory, keep the generality.

---

## Segmented / split stacks — and why Go and Rust abandoned them

**Mechanism.** Start with a tiny stack chunk (a few KiB). Every function prologue checks `SP` against the chunk's limit; if the next frame will not fit, allocate a **new, non-contiguous segment**, link it to the old one, and continue there. On return past a segment boundary, free the segment. The stack becomes a _linked list of chunks_. This is what gccgo's `-fsplit-stack` still implements, and what early Go (through Go 1.2) and pre-1.0 Rust used.

> [!IMPORTANT]
> **The "hot-split" history below is _external_ to this source tree, not a code comment.** The current Go `stack.go` is already the rewritten contiguous version (its header reads `// Copyright 2013`) and documents _no_ segmented-stack prologue mechanism. What survives is only loose vocabulary, not the old machinery: the overflow message `"runtime: split stack overflow"` (`stack.go:1118-1119`), the historical _name_ `morestack` (`asm_amd64.s:597`), and the word "segment" used informally for a stack region (e.g. `"Allocate a bigger segment and move the stack"`, `stack.go:1148`). The mechanism is gone; only the words survived. The narrative is grounded in the Go 1.3 "Contiguous stacks" design doc (Daniel Morsing / Keith Randall, 2014) and Cloudflare's "How Stacks are Handled in Go" (2013). Attribute it to those, not to a comment in this tree.

**The "hot-split" problem (the killer).** If a tight loop or a frequently-called function sits _right at_ a segment boundary, every call crosses the boundary → allocate a new segment; every return crosses back → free it. The program thrashes the segment allocator on its hottest path, turning a cheap call into a malloc+free pair. Because the boundary falls wherever the stack happened to be at entry, a small change in call depth can move a hot function onto a boundary and produce a sudden, hard-to-diagnose performance cliff.

**Go's rationale for abandoning it (Go 1.3, 2014).** The Go team moved from segmented to **contiguous copying** stacks in Go 1.3, for the hot-split reason plus two others: segment boundaries complicated the cgo/FFI boundary (foreign code cannot run the split-stack prologue, so calls into C needed large fallback segments), and contiguous stacks give **predictable O(1)-amortized** growth with no per-call boundary tax. The decisive point for this survey is that **Go controlled its entire toolchain and _still_ abandoned segmented stacks** — even within a uniform compiler the hot-split cost was unacceptable.

**Rust's rationale.** Rust shipped segmented stacks early (via the same LLVM `-fsplit-stack` support gccgo uses) and **removed them before 1.0** (~2013). Its reasons mirror Go's, plus one more: Rust decided _not to have a managed runtime at all_, so it could neither pay the hot-split cost nor justify a runtime-heavy copying scheme. It dropped green threads from `std` entirely and standardized on **1:1 OS threads** with ordinary fixed OS stacks. So Rust's answer to "segmented is bad" was _remove the green-thread runtime_, whereas Go's was _replace segments with copying_.

**N4134 independently rejects segmented**, for the same FFI-boundary reason Go hit at the cgo boundary — "requires the entire program ... to be either compiled with split-stacks or to incur run-time penalties when invoking code that is not compiled with split-stack support" (`n4134:150-152`, in [concepts][concepts]). Go is the _empirical_ proof behind that abstract argument.

---

## Contiguous growable stacks — Go today

This is the only model in the design space that is _both_ memory-dense (starts tiny) _and_ boundary-cliff-free (one contiguous region). Its price: it **requires a managed runtime with precise stack maps**, because growing the stack means _moving_ it, which means _relocating every pointer into it_.

### Start small, double on overflow

A fresh goroutine on Linux starts with a **2 KiB stack** — eight times smaller than D `Fiber`'s 16 KiB default and ~4000× smaller than a default `pthread` (8 MiB reserved). The minimum is `stackMin` (`stack.go:78`):

```go
// The minimum size of stack used by Go code
stackMin = 2048
```

`fixedStack` is `stackMin + stackSystem` rounded up to a power of two (`stack.go:80-89`); `stackSystem` is **0 on Linux/macOS** and only nonzero on Windows (+4096), Plan 9 (+512), and iOS-arm64 (+1024) (`stack.go:75`). The **maximum** is set in `schedinit` — "Max stack size is 1 GB on 64-bit, 250 MB on 32-bit" (`proc.go:160`):

```go
if goarch.PtrSize == 8 {
    maxstacksize = 1000000000
} else {
    maxstacksize = 250000000
}
maxstackceiling = 2 * maxstacksize  // proc.go:172
```

Exceeding it `throw`s `"stack overflow"` (`stack.go:1178`).

### Overflow detection is a SOFTWARE bound check, not a guard page

This is the structural inversion versus D `Fiber`. Go does **not** use a hardware guard page for user stacks; instead every splittable function carries a **prologue** that compares `SP` against the G's stack bound `g.stackguard0` and calls `morestack` if the next frame will not fit. The header comment of `stack.go` is canonical (`stack.go:24-30`):

> "The per-goroutine `g->stackguard` is set to point `StackGuard` bytes above the bottom of the stack. Each function compares its stack pointer against `g->stackguard` to check for overflow. To cut one instruction from the check sequence for functions with tiny frames, the stack is allowed to protrude `StackSmall` bytes below the stack guard. Functions with large frames don't bother with the check and always call `morestack`."

The amd64 prologue, from the same comment (`stack.go:37-41`):

```asm
stack frame size <= StackSmall:
    CMPQ guard, SP
    JHI 3(PC)
    MOVQ m->morearg, $(argsize << 32)
    CALL morestack(SB)
```

`morestack` (`asm_amd64.s:597`, `TEXT runtime·morestack(SB),NOSPLIT|NOFRAME`) saves the faulting frame, switches to the M's system (`g0`) stack, and calls `newstack`. `morestack` itself is `NOSPLIT` — it _is_ the growth handler and must not trigger another growth — and the linker statically verifies that any chain of `NOSPLIT` functions fits in the reserved bottom region:

> "The linkers explore all possible call traces involving non-splitting functions to make sure that this limit cannot be violated." — `stack.go:66-67`

A neat side benefit: `stackguard0` doubles as a **preemption** channel. Poisoning it to the sentinel `stackPreempt` (`stack.go:133`, low bits `0xfffffade`) forces the next prologue check to "fail" and divert into the scheduler — Go's synchronous preemption _is_ the stack-growth path, reused (the `newstack` preempt branch, `stack.go:1093`). See the [green-threads deep-dive][green-threads] for that mechanism.

### Growth = allocate 2×, **copy**, then **relocate pointers** (`copystack`)

`newstack` computes the new size — "Stack growth is multiplicative, for constant amortized cost" (`stack.go:1016`) — by doubling, growing further only if a single huge frame demands it (`stack.go:1150-1161`):

```go
oldsize := gp.stack.hi - gp.stack.lo
newsize := oldsize * 2
// grow further if a single huge frame needs it:
for newsize-used < needed {
    newsize *= 2
}
```

It then flips the goroutine into `_Gcopystack` (so the concurrent GC will not scan a stack mid-move) and calls `copystack(gp, newsize)` (`stack.go:1183-1191`). `copystack` (`stack.go:900-1003`) is the heart of the contiguous model:

```go
func copystack(gp *g, newsize uintptr) {
    if gp.syscallsp != 0 {
        throw("stack growth not allowed in system call")
    }
    old := gp.stack
    used := old.hi - gp.sched.sp
    // allocate new stack
    new := stackalloc(uint32(newsize))
    // Compute adjustment.
    var adjinfo adjustinfo
    adjinfo.old = old
    adjinfo.delta = new.hi - old.hi
    ...
    // Copy the stack (or the rest of it) to the new location
    memmove(unsafe.Pointer(new.hi-ncopy), unsafe.Pointer(old.hi-ncopy), ncopy)
    // Adjust remaining structures that have pointers into stacks.
    adjustctxt(gp, &adjinfo)
    adjustdefers(gp, &adjinfo)
    adjustpanics(gp, &adjinfo)
    // Swap out old stack for new one
    gp.stack = new
    gp.stackguard0 = new.lo + stackGuard
    gp.sched.sp = new.hi - used
    // Adjust pointers in the new stack.
    var u unwinder
    for u.init(gp, 0); u.valid(); u.next() {
        adjustframe(&u.frame, &adjinfo)
    }
    ...
    stackfree(old)
}
```

The five-step shape: (1) `stackalloc` the bigger stack; (2) compute `adjinfo.delta = new.hi - old.hi`; (3) `memmove` the _used_ bytes; (4) **relocate every pointer that points into the old stack** — first the off-stack roots (`adjustctxt`/`adjustdefers`/`adjustpanics`/`adjustsudogs`), then frame-by-frame via the `unwinder`; (5) swap the new stack in and `stackfree` the old.

Step 4 is where **precise stack maps** are load-bearing. `adjustframe` (`stack.go:701`) asks the compiler-emitted maps which slots are pointers and rewrites only those (`stack.go:733-746`):

```go
locals, args, objs := frame.getStackMap(true)
// Adjust local variables if stack frame has been allocated.
if locals.n > 0 {
    size := uintptr(locals.n) * goarch.PtrSize
    adjustpointers(unsafe.Pointer(frame.varp-size), &locals, adjinfo, f)
}
// Adjust arguments.
if args.n > 0 {
    adjustpointers(unsafe.Pointer(frame.argp), &args, adjinfo, funcInfo{})
}
```

And `adjustpointer` only rewrites a word if it actually points into the old stack range (`stack.go:626-627`):

```go
if adjinfo.old.lo <= p && p < adjinfo.old.hi {
    *pp = p + adjinfo.delta
}
```

**The cost.** Each growth is `O(used bytes)` for the `memmove` _plus_ `O(pointer slots in all live frames)` for the relocation walk. Because the stack doubles, the _amortized_ cost across a goroutine's life is O(1) per byte pushed, but any single growth pauses _that_ goroutine for a full copy + pointer-fixup pass. This is acceptable in Go because (a) it is amortized and (b) the runtime already maintains these stack maps for the GC anyway — the growth machinery is _reusing GC metadata_.

> [!IMPORTANT]
> Copying _demands_ precision in a way conservative scanning does not. A conservative collector can _tolerate_ not knowing whether a word is a pointer — it just over-retains. A _mover_ cannot: rewrite an integer that merely _looks_ like a stack pointer and you corrupt it; _fail_ to rewrite a real pointer after the move and you leave it dangling. So the same precise per-frame maps that let Go scan stacks exactly (`scanstack`, `mgcmark.go:904`, sharing the very same `unwinder` as `copystack`) are the prerequisite for cheap growth.

### The allocator (span pool, not per-stack mmap)

`stackalloc`/`stackfree` do not `mmap` each stack. Small stacks come from per-order free lists keyed by `order = log_2(size/FixedStack)` (`stackpool`, `stack.go:147-153`) and per-P caches; large stacks come from `stackLarge` (`stack.go:164-168`) backed by a dedicated heap span. On goroutine exit, a default-sized stack is **kept with the `g` for reuse** while a grown stack is **freed**. This pooling is what avoids the fixed-reserved fragmentation problem above — the consumer of these stacks, the G-M-P scheduler, is covered in [green threads][green-threads] and (from the I/O angle) the [Go netpoller][go-netpoller].

### Go shrinks stacks too — during GC

Contiguous stacks shrink as well, using the _same_ `copystack` machinery in reverse. `shrinkstack` (`stack.go:1257`) halves the stack but never below the minimum, and only if the goroutine is using less than a quarter of it (`stack.go:1285-1299`):

```go
oldsize := gp.stack.hi - gp.stack.lo
newsize := oldsize / 2
if newsize < fixedStack {
    return
}
// only shrink if using < 1/4 of the stack:
if used := gp.stack.hi - gp.sched.sp + stackNosplit; used >= avail/4 {
    return
}
...
copystack(gp, newsize)
```

Shrinking is gated on safety: `isShrinkStackSafe` (`stack.go:1212`) refuses when there is no precise map to rely on —

> "Shrinking the stack is only safe when we have precise pointer maps for all frames on the stack." — `stack.go:1212-1214`

— and it is normally **triggered by the GC** at stack-scan time. This bidirectional adaptivity (start at 2 KiB, double up on demand, halve back down on GC, plus an adaptive starting size re-derived each GC from the average scanned stack, `stack.go:1386`) is a property fixed-reserved stacks fundamentally _cannot_ have: they can only ever sit at their reserved size.

> [!NOTE]
> Even Go does not make _everything_ growable. The M's `g0` (system) and signal stacks are themselves **fixed and non-growable** — contiguous-growable is a luxury layered on top of a fixed base, used only for _user_ goroutine stacks, with a fixed stack underneath to run the growth machinery itself. `stackalloc` must even run on the scheduler stack "so that we never try to grow the stack during the code that stackalloc runs" (`stack.go`).

---

## Guard pages & overflow detection — the two paradigms side by side

|               | **Hardware guard page** (D `Fiber`, POSIX/Win fibers)            | **Software bound check** (Go)                                   |
| ------------- | ---------------------------------------------------------------- | --------------------------------------------------------------- |
| Mechanism     | unmapped / `PROT_NONE` page below the stack; CPU faults on touch | per-function prologue: `CMPQ guard, SP` → `morestack`           |
| Cost per call | **zero** (no instructions)                                       | a compare + predicted-not-taken branch on every splittable call |
| On overflow   | `SIGSEGV` / `PAGE_GUARD` fault → crash (no growth)               | divert to `newstack` → grow & copy, transparently               |
| Can grow?     | no (trap only)                                                   | yes                                                             |
| Citation      | `package.d:1000-1005` (`mprotect PROT_NONE`)                     | `stack.go:24-30`, `morestack` `asm_amd64.s:597`                 |

Two clarifications worth pinning down:

- **Guard-page false economy at scale.** Each guard page is its own VMA, and on POSIX it is a _second_ `mprotect`'d region per fiber — cheap per-fiber, costly in aggregate VMA count (the `vm.max_map_count` ceiling above).
- **Stack canaries are a different thing.** `-fstack-protector`'s `__stack_chk_guard` cookie detects _buffer overruns within a frame_, not _stack-depth overflow_. It is orthogonal to coroutine stack management and does not help size or grow a fiber stack — mentioned only to disambiguate the overloaded word "guard."

---

## Comparison matrix

| Property                      | Fixed reserved (D `Fiber`)                                 | Segmented (old Go/Rust)                      | Contiguous growable (Go)                           |
| ----------------------------- | ---------------------------------------------------------- | -------------------------------------------- | -------------------------------------------------- |
| **Who**                       | D `Fiber`, ucontext, Win32 Fibers, Boost.Context           | gccgo `-fsplit-stack`, Go ≤1.2, Rust pre-1.0 | Go ≥1.3                                            |
| Initial size                  | full reserve (16 KiB+ in D)                                | tiny chunk (~KiB)                            | tiny (2 KiB, `stack.go:78`)                        |
| **Growth**                    | none — trap                                                | link a new segment                           | 2× alloc + copy + relocate (`stack.go:1150`)       |
| Shrink                        | no                                                         | free segment on unwind                       | yes, during GC (`stack.go:1257`)                   |
| **Overflow**                  | hardware guard page (`package.d:1000`)                     | software bound check                         | software bound check → grow                        |
| Per-call overhead             | zero                                                       | bound check + maybe segment alloc            | bound check (compare + branch)                     |
| **Per-instance memory**       | full reserve up front (32-bit exhaustion, `n4134:142-148`) | low                                          | low (2 KiB start, span pool)                       |
| Fragmentation                 | high (per-fiber `mmap`)                                    | medium                                       | low (span pool, `stack.go:147`)                    |
| **Needs precise stack maps?** | **no**                                                     | no (needs split prologues)                   | **yes** — GC-grade per-frame maps                  |
| FFI / C-ABI calls             | trivial (ordinary stack)                                   | penalty at the boundary (`n4134:150`)        | forbidden to grow mid-syscall (`stack.go:901-902`) |
| Pathology / downside          | over/under-provision; trap on overflow                     | **hot-split** thrash                         | copy pause; demands a managed runtime              |
| Who can implement it          | anyone                                                     | a cooperating compiler                       | **a managed runtime only**                         |

---

## Why this matters for D / LDC

**The decisive constraint: D is not a fully-managed runtime.** D has a GC, but it is a **conservative** collector — it scans a fiber's stack word-by-word _without_ precise per-frame pointer maps. The [baseline doc][d-fiber] states this directly: the GC "conservatively scans `[bstack .. tstack)` for every registered context," so each fiber is "one conservative scan range." Conservative scanning _reads_ a stack and treats anything that _looks like_ a heap pointer as one; it deliberately does **not** know which words are _actually_ pointers — and it certainly cannot know that for the arbitrary **C-ABI frames** that D code calls into. That is exactly the metadata Go's `adjustframe`/`getStackMap` (`stack.go:733`) depends on.

**Consequence: Go-style contiguous-growable stacks are infeasible for general D.** Growing a stack the Go way _moves_ it, which requires _relocating every interior pointer_ (`copystack`/`adjustframe`). Without precise stack maps you cannot distinguish a pointer-into-stack from an integer that happens to look like one, so you cannot safely rewrite it — and as the callout above notes, a _mover_ has no slack the way a conservative scanner does. D could in principle build a copying stack for _pure-D, fully-mapped_ call chains, but the moment a fiber calls **any** C/C++ function (which holds `&local`s the D runtime cannot see), the move would silently invalidate those pointers. This is the same FFI-boundary objection N4134 raises against _segmented_ stacks (`n4134:150-152`, in [concepts][concepts]) — it bites _contiguous_ just as hard, and it is why **segmented is off the table for D for the same reason it died in Go and Rust**: D's entire value proposition includes seamless C/C++ interop.

**Therefore a stackful D story keeps FIXED reserved stacks** — which is exactly what `Fiber` already does. The implications, tied back to the stackless-vs-stackful [tradeoff][concepts]:

- D `Fiber` pays the **full N4134 memory tax**: a whole reserved stack per instance regardless of live state, with no shrinking and no Go-style "start at 2 KiB." This is precisely the cost the _stackless_ model is designed to avoid — a stackless frame is _"exactly the live-across-suspend state"_ ([concepts][concepts]), often a handful of bytes against the fiber's tens of kilobytes.
- The memory floor is **structural**, not an implementation wart. It follows from "stackful captures the full call stack" + "D cannot precisely map C-ABI frames" ⇒ "cannot move/grow the stack" ⇒ "must reserve up front." You can _tune_ the reserved size (the `sz` constructor parameter) but not escape the reserve-vs-trap dilemma.
- **Net:** if D ever wants _millions_ of cheap suspendable tasks (the one-task-per-in-flight-IO pattern), the route is **stackless compiler-lowered coroutines** — a frame sized to exactly the live set, in linear memory — _not_ a smarter fiber stack. A stackful fiber will always carry a real machine stack; the only stack-management knobs available to D are (a) the reserved size and (b) lazy commit (demand paging on POSIX), and neither closes the order-of-magnitude gap to a stackless frame. The C++ scalability rationale that drives this conclusion — "billions of concurrent coroutines," resume cost "comparable to a function call" — is N4134's, summarized in [cpp].

> [!IMPORTANT]
> **On wasm the question is moot for stackful — there is no stack to manage.** Even fixed reserved stacks do not exist on WebAssembly: D's `Fiber` is `assert(0, "Fibers not supported on WASI")` ([d-fiber][d-fiber]), because wasm exposes no addressable linear stack to swap an `sp` into. None of the three CPU-stack strategies applies. A _stackful_ wasm story needs **WasmFX** — engine-managed stacks via `cont.new` / `resume` / `suspend`, where the engine owns the call stack and sizes/grows it out of the module's reach — which is a fourth answer ("the engine decides") orthogonal to the three above. See [WasmFX as a target][wasmfx-target] for whether a goroutine-style growable-stack runtime could sit on `cont` the way it sits on `gogo` today, and the [WebAssembly overview][wasm] for the broader picture.

---

## Sources

- Go runtime (`$REPOS/go/go/src/runtime/`, tip/dev June 2026) —
  - `stack.go` — design/prologue comment (`:20-68`), `stackMin = 2048` (`:78`), `fixedStack` (`:80-89`), `stackGuard`/`stackSystem` (`:75`,`:102`), `stackpool`/`stackLarge` (`:147-168`), `adjustpointer` (`:608-631`), `adjustframe`/`getStackMap` (`:701-746`), `copystack` (`:900-1003`), `"split stack overflow"` (`:1118-1119`), `newstack` doubling (`:1014-1016`, `:1150-1161`), `"stack overflow"` (`:1178`), `copystack` call (`:1183-1191`), `isShrinkStackSafe` "precise pointer maps" (`:1212-1214`), `shrinkstack` (`:1257`, `:1285-1299`), `startingStackSize`/`gcComputeStartingStackSize` (`:1386`).
  - `proc.go` — `maxstacksize` 1 GB / 250 MB (`:160-167`), `maxstackceiling` (`:172`).
  - `asm_amd64.s` — `morestack` (`:597`).
  - `mgcmark.go` — `scanstack`, the shared precise per-frame `unwinder` (`:904`).
- D druntime `Fiber` (`$REPOS/dlang/ldc/runtime/druntime/src/core/thread/fiber/`) — `allocStack` (`package.d:857`), `defaultStackPages` (`package.d:766`), guard `mprotect PROT_NONE` (`package.d:1000-1005`), `MEM_RESERVE`/`MEM_COMMIT` Windows path (`package.d:886-907`), `"OS-imposed limit may be hit"` (`base.d:322`).
- Corpus cross-references: [D `Fiber` baseline][d-fiber] (concrete D sizing, GC-scan coupling, WASI `assert(0)`); [concepts][concepts] (N4134 address-space-exhaustion and segmented/fixed-stack rejection quotes, `n4134:142-156`); [green threads][green-threads] (the G-M-P scheduler that consumes these stacks); [context switching][context-switching] and [WasmFX as a target][wasmfx-target].
- **External (not in this source tree):** Go 1.3 "Contiguous stacks" design doc (Daniel Morsing / Keith Randall, 2014) and Cloudflare "How Stacks are Handled in Go" (2013), for the segmented-stacks history and the "hot-split" term; Rust's pre-1.0 removal of segmented stacks / green threads (~2013).

<!-- References -->

[concepts]: ../concepts.md
[wasm]: ../wasm-and-wasmfx.md
[cpp]: ../stackless/cpp-coroutines.md
[d-fiber]: ./d-fiber.md
[context-switching]: ./context-switching.md
[green-threads]: ./green-threads.md
[wasmfx-target]: ./wasmfx-as-target.md
[go-netpoller]: ../../async-io/go-netpoller.md
