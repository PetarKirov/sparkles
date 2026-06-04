# Green Threads and M:N User-Mode Runtimes

A **green thread** is the stackful baseline ([`core.thread.Fiber`][d-fiber]) wearing two more layers: an **M:N scheduler** that multiplexes many user threads onto a few OS threads, and an **I/O integration** that parks a user thread on a would-block and unparks it on readiness. Strip those two layers and you are left with the bare fiber; add them and you get Go's goroutines, Java's virtual threads, GHC's green threads, or OCaml's Eio fibers. This doc is the **hub** for that thesis: it extracts the common M:N machinery, grounds the canonical reference (Go's G-M-P scheduler and assembly stack switch) in the runtime source, summarizes the other mature runtimes the corpus already documents (cross-linking rather than duplicating), and maps the result back onto where D sits and what a first-class D green-thread story would need.

**Last reviewed:** June 4, 2026

---

> [!NOTE]
> This is deliberately a **survey hub** that leans on the corpus. The _I/O_ half of each runtime is already a deep dive elsewhere — Go's netpoller in [go-netpoller][go-netpoller], Loom's NIO integration and pinning in [java][java], GHC's MIO manager in [haskell][haskell], Eio's `io_uring` backend in [ocaml-effects][ocaml-effects]. **This** doc owns the _scheduler + stack-switch + suspension-primitive_ half and the synthesis ("green thread = stackful coroutine + scheduler + I/O"). Where a runtime's park/unpark touches the poller, it cross-links; it does not restate.

All Go runtime paths below are under `$REPOS/go/go/src/runtime/` (note the doubled `go/go`); the checkout is Go tip/dev (June 2026), so line numbers may drift ±a few lines against upstream master — the quoted text is the stable anchor, and the G-M-P core, the asm switch, and the stack-copy model are stable since ~Go 1.4.

---

## The decomposition: a green thread is a fiber plus a scheduler

The one-sentence thesis of the stackful half of this survey:

> **A green thread _is_ a stackful coroutine plus a scheduler plus I/O integration.**

```text
  green-thread runtime
  ──────────────────────────────────────────────────────────
  = stackful coroutine        (the suspension primitive — a fiber)
  + M:N scheduler             (run queues, work-stealing, park/unpark)
  + I/O integration           (a readiness/completion poller driving unpark)
  + [structured concurrency / cancellation / channels]   (the eventual extras)
```

- The **stackful coroutine** — full call stack, suspend from any depth, opaque context switch — is the _suspension primitive_. D ships exactly this as [`core.thread.Fiber`][d-fiber], and [Concepts][concepts] defines the stackful/stackless axis it sits on. A bare fiber can `yield()` but has nowhere to yield _to_: there is no run queue, no notion of "what runs next."
- A **green-thread runtime** supplies that "what runs next": an **M:N scheduler** multiplexing N user threads onto M ≪ N OS threads, plus an **I/O integration** that turns a blocking-looking call into a park-the-fiber + submit-the-op + resume-on-completion round-trip.

The decomposition is not just conceptual — it is _literally_ how the runtimes are built. Java names a virtual thread "continuation + scheduler" in its own internals ([java-loom][java-loom]); OCaml's Eio is an _ordinary library_ that combines one-shot continuations with an effect-handler scheduler ([ocaml-effects][ocaml-effects]). The rest of this doc is the proof, runtime by runtime.

---

## The M:N model in the abstract

### Vocabulary

The defining property is **N ≫ M**: millions of user threads, a handful of OS threads (typically one per core). Suspending a user thread costs a heap/stack-pointer operation, not a kernel thread block — as the Go netpoller doc puts it, parking "costs a park/unpark, not an OS thread" ([go-netpoller][go-netpoller]).

| Concept                       | Go                           | Java Loom                     | GHC                       | OCaml / Eio                     | D                           |
| ----------------------------- | ---------------------------- | ----------------------------- | ------------------------- | ------------------------------- | --------------------------- |
| User thread (the "N")         | goroutine (`g`)              | virtual thread                | green thread (`ThreadId`) | fiber                           | `Fiber` / vibe `Task`       |
| Carrier / OS thread (the "M") | `m`                          | carrier (platform thread)     | capability OS thread      | domain's systhread              | OS thread                   |
| Scheduling context            | `p` (= `GOMAXPROCS`)         | — (FJ-pool worker)            | capability / HEC (= `-N`) | per-domain scheduler            | —                           |
| Suspension primitive          | `mcall`/`gogo` (asm SP swap) | `Continuation.yield` (hidden) | RTS `yield` / MVar block  | `perform`/`continue` (one-shot) | `fiber_switchContext` (asm) |
| Park reason                   | `waitReason*`                | blocking JDK call             | `BlockedOnMVar`, I/O      | `Suspend` effect                | library-defined             |

The terms "fiber," "green thread," and "virtual thread" are used roughly interchangeably across this corpus; the distinction is mostly historical. A useful operational reading: a **fiber** is often the bare suspension primitive (D's `Fiber`), while **green thread** / **virtual thread** names a fiber that a runtime _schedules_.

### The scheduler: work-stealing vs global run queue

Two structural choices recur:

- **Per-worker local run queues + work-stealing** (Go, Java's `ForkJoinPool`, GHC per-capability). Each worker owns a local deque; an idle worker _steals_ from a busy peer. This scales because the common case (push/pop on your own queue) is lock-free; stealing is the rare contended path.
- **Global run queue** — one shared queue behind a lock. Used as an overflow/fairness fallback in all of the above (Go's `globrunq`), never as the sole mechanism in a high-perf runtime.

Go is the canonical work-stealing reference and the corpus's most source-grounded one; §"Go" below quotes `runqsteal`/`stealWork`.

### Park / unpark on I/O — the universal round-trip

This is where the green-thread scheduler meets the OS poller. The shape is identical across runtimes:

1. A user thread issues a blocking-looking I/O call.
2. The runtime tries the syscall **non-blocking**; on `EAGAIN` it registers the fd with a readiness poller (or submits a completion op) and **parks** the user thread, yielding its carrier.
3. The carrier runs another user thread (or goes polling).
4. The poller (`epoll`/`kqueue`/IOCP readiness, or `io_uring` completion) reports the fd ready; the runtime **unparks** the user thread and re-queues it.
5. The user thread resumes and re-issues (or completes) the syscall.

Go's version is fully grounded in [go-netpoller][go-netpoller]: `gopark` is "the universal 'suspend this goroutine' primitive — the same one used by channels, mutexes, and `time.Sleep`", and crucially there is **no dedicated poller thread** — "whichever M finds itself idle does the polling" ([go-netpoller][go-netpoller]). GHC, Loom, and Eio implement the identical round-trip with different pollers (MIO `epoll`, JDK NIO, `io_uring`/`kqueue`); see those docs for the wiring.

### Cooperative vs preemptive

| Runtime         | Model                                | Preemption mechanism                                                                                                                               |
| --------------- | ------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Go**          | mostly cooperative + true preemption | **async preemption** since Go 1.14: `sysmon` signals a goroutine running >10ms to a safe-point; also synchronous safe-points at function prologues |
| **Java Loom**   | cooperative                          | yields only on blocking JDK calls — **no time-slice preemption**; a tight CPU loop monopolizes its carrier ([java][java])                          |
| **GHC**         | quasi-preemptive                     | yields at _allocation points_ (heap-check); a timer sets a context-switch flag — a non-allocating tight loop can still hog a HEC                   |
| **OCaml / Eio** | purely cooperative                   | suspends only at `perform`; a CPU-bound fiber never yields                                                                                         |

The trade-off: cooperative scheduling is cheaper and simpler, but a non-yielding user thread starves its carrier. Go's `sysmon`-driven signal preemption is the most robust of the four; the rest rely on I/O-bound workloads yielding "often enough."

---

## Go — the reference: G-M-P, asm switch, work-stealing

Go is the canonical "millions of cheap green threads" runtime, and the only major production runtime to abandon segmented stacks for copying ones (that history, and the growable-stack mechanics, get their own deep dive in [stack management][stack-management]). This section grounds the **scheduler + stack-switch** half. The **I/O** half — netpoller, `pollDesc`, the four scheduler poll sites, deadlines — lives in [go-netpoller][go-netpoller] and is not restated here.

### G-M-P: the three structs

Go's scheduler is M:N: M goroutines on N OS threads, mediated by a fixed number of logical processors P. The canonical definition is `HACKING.md:16-42`:

> "A 'G' is simply a goroutine. It's represented by type `g`. When a goroutine exits, its `g` object is returned to a pool of free `g`s and can later be reused …" … "An 'M' is an OS thread … There can be any number of Ms at a time since any number of threads may be blocked in system calls." … "a 'P' represents the resources required to execute user Go code … There are exactly `GOMAXPROCS` Ps. A P can be thought of like a CPU in the OS scheduler …"
>
> "The scheduler's job is to match up a G (the code to execute), an M (where to execute it), and a P (the rights and resources to execute it). When an M stops executing user Go code, for example by entering a system call, it returns its P to the idle P pool."

A key invariant for write-barrier-free scheduler code:

> "All `g`, `m`, and `p` objects are heap allocated, but are never freed, so their memory remains type stable. As a result, the runtime can avoid write barriers in the depths of the scheduler." (`HACKING.md:40-42`)

**`g` — the goroutine** (`runtime2.go:471`). Its first three fields _are_ the stack-management state — the stack bounds and the prologue's growth-check guard:

```go
type g struct {
    // Stack parameters.
    // stack describes the actual stack memory: [stack.lo, stack.hi).
    stack       stack   // offset known to runtime/cgo
    stackguard0 uintptr // offset known to cmd/internal/obj/*
    stackguard1 uintptr // offset known to cmd/internal/obj/*
    ...
    m         *m      // current m
    sched     gobuf
    ...
    atomicstatus atomic.Uint32
    goid         uint64
    waitreason   waitReason // if status==Gwaiting
    preempt      bool       // preemption signal, duplicates stackguard0 = stackpreempt
    ...
}
```

(`runtime2.go:471-596`, elided). `stack` is `{lo, hi uintptr}` (`runtime2.go:460`); `sched gobuf` is the saved register context used to resume; `atomicstatus` holds the `_G*` state.

**`m` — the OS thread** (`runtime2.go:616`). Its first field is the scheduling stack `g0`, on which every context switch runs:

```go
type m struct {
    g0      *g     // goroutine with scheduling stack
    morebuf gobuf  // gobuf arg to morestack
    ...
    curg     *g       // current running goroutine
    p        puintptr // attached P (nil if not executing Go code)
    spinning bool     // m is out of work and is actively looking for work
    ...
}
```

(`runtime2.go:616-705`, elided). An M needs a P to run Go code; on entering a syscall it hands its P back to the idle pool, which is why "any number of Ms may be blocked in system calls."

**`p` — the scheduling context** (`runtime2.go:774`). The fields that matter for green-threading are the **per-P local run queue** (a lock-free ring) and `runnext`:

```go
type p struct {
    ...
    // Queue of runnable goroutines. Accessed without lock.
    runqhead uint32
    runqtail uint32
    runq     [256]guintptr
    // runnext, if non-nil, is a runnable G that was ready'd by
    // the current G and should be run next ...
    runnext guintptr
    gFree   gList // Available G's (status == Gdead)
    ...
}
```

(`runtime2.go:774-823`, elided). `runq` (`runtime2.go:807`) is a single-producer/multi-consumer ring: the owner P pushes/pops one end, thieves steal from the other. `runnext` (`runtime2.go:820`) is a one-slot LIFO bypass giving producer→consumer locality (a channel send that wakes a receiver runs it next, inheriting the time slice). `gFree` is a per-P freelist of dead `g`s _with their stacks_, for cheap reuse.

### The state machine: park ⇄ ready ⇄ run

The `_G*` lifecycle states (`runtime2.go:35-119`) _are_ the green-thread state machine. The transitions that constitute the stackful suspend/resume:

```text
_Grunning  ──gopark / park_m──▶  _Gwaiting   (parked; e.g. "[IO wait]"; NOT on a run queue)
_Gwaiting  ──ready / goready──▶  _Grunnable  (re-queued onto a P's local run queue)
_Grunnable ──execute / gogo───▶  _Grunning   (resumed)
```

All transitions go through `casgstatus`. `gopark`/`goready` are the universal suspend/resume used by channels, mutexes, `time.Sleep`, _and_ the netpoller alike — the netpoller doc covers their I/O-side usage; here they are the scheduler-side drivers of the stack switch.

### The stack switch: `mcall` (suspend) and `gogo` (resume)

Go does **not** use a hand-written callee-saved register-bank push/pop like D's `fiber_switchContext` ([d-fiber][d-fiber]). It saves a tiny `gobuf {sp, pc, g, ctxt, lr, bp}` (`runtime2.go:303`) and jumps. The callee-saved GPRs are **not** in the `gobuf`: a goroutine is only ever suspended at a call boundary (`mcall`/`morestack`) where the Go ABI has already spilled callee-saved registers to the goroutine's own stack, so only `{sp, pc, bp}` need to transit.

`gogo` (resume) restores SP/BP/PC from the gobuf and `JMP`s — a `longjmp` into a `gobuf` (`asm_amd64.s:408`):

```asm
TEXT gogo<>(SB), NOSPLIT, $0
    get_tls(CX)
    MOVQ    DX, g(CX)
    MOVQ    DX, R14        // set the g register
    MOVQ    gobuf_sp(BX), SP    // restore SP
    MOVQ    gobuf_bp(BX), BP
    MOVQ    gobuf_pc(BX), BX
    JMP    BX
```

`mcall(fn)` (suspend) saves the caller's `{pc, sp, bp}` into `g.sched`, switches to the M's `g0` scheduling stack, and calls `fn(g)` there — `fn` must never return; it parks/reschedules `g` and ends in `schedule()` (`asm_amd64.s:425`). One comment in `mcall` is the load-bearing one for the stackful/D contrast:

```asm
    MOVQ    $0, BP    // clear frame pointer, as caller may execute on another M
```

The goroutine may resume on a **different OS thread**, which is exactly the migration that breaks D/LDC's `Fiber` (the LLVM TLS-address caching hazard, [d-fiber][d-fiber]). Go has no such hazard precisely because the **compiler emits** the switch and re-reads the TLS-resident `g` on resume via `get_tls` — there is no opaque asm boundary across which a TLS load could be hoisted. This is the deep reason the corpus argues a _compiler-lowered_ coroutine sidesteps the migration hazard ([context-switching][context-switching]).

The park-and-resume cycle is the pairing `mcall(park_m)` (in `gopark`) → later `gogo(&g.sched)` (in `execute`). `gopark`'s body ends in exactly that `mcall` (`proc.go:450-467`):

```go
func gopark(unlockf func(*g, unsafe.Pointer) bool, lock unsafe.Pointer, reason waitReason, ...) {
    ...
    mp.waitlock = lock
    mp.waitunlockf = unlockf
    gp.waitreason = reason
    ...
    // can't do anything that might move the G between Ms here.
    mcall(park_m)
}
```

`park_m` runs on `g0`: it CASes `_Grunning`→`_Gwaiting`, `dropg()`s to sever `m.curg`, runs the unlock function, then calls `schedule()`. The resume side `ready`/`goready` flips `_Gwaiting`→`_Grunnable`, `runqput`s onto a P's local run queue, and `wakep()`s. `execute` (`proc.go:3339`) closes the loop: it assigns `gp` to the M, CASes `_Grunnable`→`_Grunning`, resets the stack guard, and its last line is `gogo(&gp.sched)`.

> [!NOTE]
> Mechanically, the Go switch is _cheaper_ than D's `Fiber` switch (save `{sp,pc,bp}`, swap SP, `JMP` — no callee-GPR push/pop, no XMM saves) but _wrapped in more_: it picks its target via a whole scheduler (`schedule`→`findRunnable`→`execute`), whereas `Fiber.call`/`Fiber.yield` switch to a target the caller already named. The bare fiber is the primitive; the scheduler is what a green-thread runtime adds.

### Goroutine creation — no syscall per spawn

`go f()` compiles to `newproc(fn)` → `newproc1` (`proc.go:5345`), which reuses a dead `g` from the P freelist (`gfget`) or `malg(stackMin)`s a fresh one with a **2 KiB stack** (`stackMin = 2048`, `stack.go:78`), fabricates a call frame so the first `gogo` lands at `fn`'s entry with `goexit` as the return address, CASes `_Gdead`→`_Grunnable`, and `runqput`s it onto the local run queue with `next=true` (a freshly-spawned goroutine often runs next). **No `mmap`, no syscall per goroutine** — `g` and stack come from per-P pools. Contrast the per-fiber cost of D's `Fiber`: one `mmap` + one `mprotect` + one GC `new StackContext` ([d-fiber][d-fiber]). The 2 KiB growable stack (vs D's fixed 16 KiB) is the subject of [stack management][stack-management].

### Work-stealing: `findRunnable` → `stealWork` → `runqsteal`

`findRunnable` (`proc.go:3397`) searches in a fixed priority: a fairness pull from the global queue every 61st tick, then the **local** run queue, then a **global** batch, then opportunistic `netpoll`, then **work-stealing**, then block. Work-stealing makes **4 randomized passes** over all Ps (`proc.go:3841`):

```go
const stealTries = 4
for i := 0; i < stealTries; i++ {
    stealTimersOrRunNextG := i == stealTries-1
    for enum := stealOrder.start(cheaprand()); !enum.done(); enum.next() {
        // ... if gp := runqsteal(pp, p2, stealTimersOrRunNextG); gp != nil { return ... }
    }
}
```

`runqsteal` **grabs half** the victim's queue (`runqgrab` computes `n = (tail-head) - (tail-head)/2`, `proc.go:7710-7711`):

```go
n := t - h
n = n - n/2
```

Stealing the victim's `runnext` slot is the last resort, and even backs off ~3µs first "to give pp a chance to schedule runnext … avoid thrashing gs between different Ps" (`proc.go:7715-7745`). The spinning-M count is capped at half the busy-P count "to prevent excessive CPU consumption when GOMAXPROCS>>1 but the program parallelism is low" (`proc.go:3523`). This is a Chase-Lev-style work-stealing deque specialized to a fixed 256-slot ring — the **reference design** for the scheduler layer any M:N runtime needs, stackful or stackless. D's `Fiber` ships none of it; Photon and vibe-core build it library-side (§"Where D sits").

### Preemption — closing the cooperative starvation hole

A purely cooperative scheduler has a hole: a tight loop that never calls a function never hits a safe-point. Go closes it with **two** mechanisms (`preempt.go:7-19`):

> "1. A blocked safe-point occurs for the duration that a goroutine is descheduled … 2. Synchronous safe-points occur when a running goroutine checks for a preemption request. 3. Asynchronous safe-points occur at any instruction in user code where the goroutine can be safely paused and a conservative stack and register scan can find stack roots. The runtime can stop a goroutine at an async safe-point using a signal."

**Synchronous** preemption overloads the stack-growth check: the runtime poisons `gp.stackguard0` to `stackPreempt`, so the next function prologue's bound check "fails," calls `morestack`→`newstack`, which detects the poison and diverts to preemption handling instead of growing — the preemption path _is_ the stack-growth path. **Asynchronous** preemption (Go 1.14+) signals the thread (`SIGURG`), rewrites the signal context to look like a call to `asyncPreempt`, which spills all registers and enters the scheduler — this is what makes `for {}` preemptible. Async-preempted goroutines pay a conservative register scan (the one place Go's otherwise-precise GC goes conservative), detailed in [stack management][stack-management]. Among the four runtimes here, only Go has real time-slice preemption of user threads.

---

## Java Loom — virtual thread = continuation + scheduler

**Corpus:** the continuation deep dive is [java-loom][java-loom]; the NIO integration and pinning are in [java][java]. Summary, not duplication:

- A **virtual thread is a `java.lang.Thread`** scheduled by the JVM and multiplexed onto a small **carrier pool** — a `ForkJoinPool` of platform threads. "Millions can exist at once."
- The suspension primitive is a **hidden, scoped, stackful, one-shot delimited continuation**: `jdk.internal.vm.Continuation` with `yield(scope)` / `run()`. On a blocking JDK call the JVM calls `Continuation.yield`, releases the carrier to the `ForkJoinPool`, and `run`s the continuation on remount. This is deliberately **not a public API** (thread identity can change mid-method) — so Java users get virtual threads but cannot build their own coroutines/schedulers on the continuation, _unlike_ OCaml where the continuation _is_ the public primitive.
- **Scheduler = `ForkJoinPool` work-stealing.** Per [java-loom][java-loom]: "Work-stealing provides good load balancing for I/O workloads" but is "Suboptimal for CPU-bound work; scheduling latency under contention." Because vthreads have **no preemption**, a CPU-bound vthread monopolizes its carrier (observed ~50-55% throughput on CPU-bound benches, [java][java]).
- **Pinning** is Loom's signature failure mode: a vthread _pinned_ to its carrier (can't unmount) when it blocks inside `synchronized` or a native method ([java-loom][java-loom]). **JEP 491 (JDK 24) removed nearly all monitor pinning**; filesystem I/O and some class-loading remain ([java][java]). Pinning has no analogue in Go (nothing blocks a goroutine park) — it is specific to retrofitting continuations under a pre-existing locking model.
- **Structured concurrency** via `StructuredTaskScope` forks subtasks as vthreads and joins them as a unit ([java-loom][java-loom]) — Loom's analogue of Eio's `Switch` and Go's `errgroup`/`context`.

**The bridge:** a virtual thread is _literally_ "continuation + scheduler" — Loom's own internals name it so. The continuation is the stackful coroutine; the `ForkJoinPool` + NIO netpoller is the scheduler + I/O. This is the cleanest statement of this doc's thesis in any mainstream runtime, and it maps onto the algebraic-effects framing in [the effects corpus][ae-index].

---

## GHC Haskell — green threads on capabilities, the RTS scheduler

**Corpus:** [haskell][haskell] (the threaded RTS IO manager). Summary:

- The **threaded RTS** (`-threaded`) runs a few OS threads — **capabilities** (`-N`, ≈ HECs, Haskell Execution Contexts) — and multiplexes **millions of lightweight green threads** onto them. Same "runtime owns the loop" model as Go.
- **Park/unpark on readiness:** `threadWaitRead`/`threadWaitWrite` register fd interest with the in-RTS **MIO** event manager and block the green thread (an MVar-style wait), yielding the capability — "The OS thread is _not_ blocked." The IO manager sits in `epoll_wait`/`kqueue` and wakes the green thread on readiness.
- **MIO = one event manager per capability** ("Mio: A High-Performance Multicore IO Manager for GHC", Voellmy et al., Haskell '13) — replaced the single-dispatcher design, "scaling to 40+ cores and >20M requests/s" ([haskell][haskell]). This is GHC's analogue of Go's per-P sharding, and the reason `-N` matters for server throughput.
- **MVars** are the core synchronization/communication primitive — a green thread blocked on `takeMVar` parks until another `putMVar`s. Parking is cheap _because_ green-thread parking is cheap. MVars are GHC's channels/locks/futures rolled into one.
- **Quasi-preemptive:** GHC yields at allocation points (heap-checks); a timer sets a context-switch flag — a non-allocating tight loop can still hog a HEC.

> [!NOTE]
> The corpus doc focuses on the IO manager (MIO) and the `blockio-uring` library; it does **not** quote the GHC RTS scheduler source or the green-thread stack representation. GHC green threads use **heap-allocated, growable `StgTSO` stack objects** that the GC chunks and relocates — closest to Go's movable/copying model and _unlike_ D's fixed `mmap` stack — but this digest did not open the RTS C source (`rts/Schedule.c`, `rts/sm/Stack.c`, `includes/rts/storage/TSO.h`) to cite it `path:line`. **Treat the StgTSO stack-chunk / relocation detail as needing primary-source confirmation** before relying on it; the per-capability scheduling and MVar parking above _are_ corpus-grounded.

---

## OCaml 5 + Eio — fibers via one-shot effects (the bridge to algebraic effects)

**Corpus:** [ocaml-effects][ocaml-effects] (the runtime mechanism) and the Eio writeup it cross-links. This is the **stackful-via-effects** entry — the bridge from the green-thread story to the [algebraic-effects corpus][ae-index].

- OCaml 5's **effect handlers** give **one-shot delimited continuations** implemented as **heap-allocated fiber stacks** switched in pure userland. A `perform` captures the delimited continuation between the perform site and its handler; `continue`/`discontinue` resume it _exactly once_. "`perform`/`resume` swap an `sp` register and update one parent pointer — there is no kernel transition" ([ocaml-effects][ocaml-effects]). Fresh fiber ≈ 64 words (~512 B), growable by double-`memcpy`-and-relocate — the _same_ copy-and-relocate strategy as Go, again contrasting D's fixed stack (see [stack management][stack-management]).
- **Eio = the green-thread runtime built on top, as an _ordinary library_.** It defines three private effects — `Fork` (new fiber), `Suspend` (block + hand to scheduler), `Get_context`. The **scheduler _is_ the effect handler**: the per-domain run loop matches on the effects; on `Suspend f` it captures the one-shot continuation, registers how the fiber resumes (submit an `io_uring` SQE + a cancel fn), and runs the next ready fiber. On the CQE the continuation is resumed directly — vs Go/GHC where the poller just flips a flag and re-queues.
- **Structured concurrency via `Switch`** (a "nursery"/"bundle" that cannot finish until every attached fiber terminates), plus capability-based security and per-domain cancellation trees — the most feature-complete structured-concurrency model in the survey.

**Why it is _the_ bridge:** unlike Go/GHC (parking is a runtime primitive) or Loom (continuation is hidden), OCaml exposes the continuation as a _public, user-level_ primitive — so Eio is an ordinary library, proving "green-thread runtime = stackful coroutine + scheduler" by **building one in userland**. This is also the direct conceptual ancestor of **WasmFX** (`cont`/`resume`/`suspend`), which is effect handlers lowered into the Wasm engine — see [WasmFX as a target][wasmfx-target] and the [WasmFX deep dive][wasmfx].

---

## The comparison table

| Runtime         | Unit             | Stack model                                                    | Scheduler                                             | Preemption                                | I/O integration                                  | Cross-link                                                         |
| --------------- | ---------------- | -------------------------------------------------------------- | ----------------------------------------------------- | ----------------------------------------- | ------------------------------------------------ | ------------------------------------------------------------------ |
| **Go**          | goroutine        | contiguous, **growable by copy** (2 KiB→, movable, precise GC) | per-P deque + randomized half-steal + global overflow | **async (signals) + sync (guard poison)** | `epoll`/`kqueue`/IOCP netpoller in the scheduler | [go-netpoller][go-netpoller], [stack-management][stack-management] |
| **Java Loom**   | virtual thread   | JVM-managed continuation stack (grows)                         | `ForkJoinPool` carriers (work-stealing)               | none (cooperative on blocking calls)      | JDK NIO netpoller                                | [java-loom][java-loom], [java][java]                               |
| **GHC**         | green thread     | heap `StgTSO` stack chunks (growable, GC-relocated)¹           | per-capability scheduler + work-steal                 | quasi (at allocation points)              | MIO `epoll`/`kqueue` per capability              | [haskell][haskell]                                                 |
| **OCaml / Eio** | fiber            | **heap fiber, growable by copy** (~512 B→, GC-relocated)       | per-domain run loop = the effect handler              | none (purely cooperative)                 | `io_uring` / `kqueue` per backend                | [ocaml-effects][ocaml-effects], [ae-index][ae-index]               |
| **D `Fiber`**   | `Fiber` / `Task` | **fixed `mmap` stack** (16 KiB + guard, never grows)           | **none — primitive only**                             | none (cooperative `yield()`)              | **none — primitive only**                        | [d-fiber][d-fiber], [d-landscape][d-landscape]                     |

¹ GHC `StgTSO` stack representation flagged uncertain above (not corpus-grounded).

The single most differentiating implementation axis is **how the user thread's stack is stored and whether it can grow/move**:

- **Fixed reserved stack** (D `Fiber`): cheap switch, but you over-provision (16 KiB whether you use 200 B or 200 KiB), no growth (overflow → guard-page `SIGSEGV`), and one conservative GC scan range per fiber — the "M:N memory tax" ([d-fiber][d-fiber]).
- **Growable-by-copying stack** (Go, OCaml, GHC): start tiny (512 B–2 KiB), double-`memcpy`-and-relocate on demand. This requires **precise GC + compiler cooperation** (stack maps / fiber pointer-rewriting), and it is what makes "millions of goroutines" affordable. The mechanics and the segmented-stacks history are in [stack management][stack-management].
- D's `Fiber` is stuck with the _fixed_ model **because** its GC is conservative and the asm switch is opaque to the compiler — the runtime cannot find and rewrite the pointers needed to relocate a stack. This is the same opacity behind the LDC TLS-migration hazard ([context-switching][context-switching]).

---

## Where D sits, and what a first-class green-thread story needs

**Corpus:** [d-landscape][d-landscape] (the ecosystem) and [d-fiber][d-fiber] (the primitive's cost model). Summary, not duplication:

- **`core.thread.Fiber` is the bare primitive** — a stackful coroutine with a fixed 16 KiB + guard `mmap` stack, an asm `fiber_switchContext`, and **no scheduler or I/O integration** ([d-fiber][d-fiber]). `std.concurrency.Generator` and `FiberScheduler` are thin library layers on it. This is the fiber _before_ the two green-thread layers are added.
- **vibe.d / vibe-core / eventcore** = the dominant D green-thread runtime: stackful fibers (`Task`) + a Proactor driver abstraction (`epoll`/`kqueue`/IOCP, experimental `io_uring`), direct-style blocking-looking I/O ([d-landscape][d-landscape]). It is single-loop-plus-workers rather than full M:N, and GC/exception-coupled.
- **Photon** = a _transparent_ M:N stackful scheduler that **overrides the libc syscall wrappers** so unmodified blocking code (even inside C libraries) becomes fiber-aware ("Golang-style concurrency to D transparently"); `epoll`/`kqueue`, GC scheduler, no `io_uring` in the D version ([d-landscape][d-landscape]). This is the closest D analogue to Go's "runtime owns the loop."
- **`during`** = a `@nogc nothrow betterC` `io_uring` SQE/CQE binding with **no scheduler, no fibers** — the raw kernel surface ([d-landscape][d-landscape]).

To turn D's `Fiber` (a bare stackful coroutine) into a green-thread runtime you must add exactly the three missing layers — the decomposition at the top of this doc, instantiated for D ([d-landscape][d-landscape]):

1. **A scheduler** — a run queue keyed by ready fibers and a `Fiber.call`/`Fiber.yield` loop; ideally per-core deques + work-stealing for true M:N (Go's `runqsteal` is the reference). vibe.d is single-loop-plus-workers; Photon is M:N.
2. **I/O integration** — park a fiber on a would-block by submitting an op and `Fiber.yield()`-ing; resume it from the completion by looking up the fiber via the CQE's `user_data` and calling `fib.call()`. This is exactly the loop pattern [d-landscape][d-landscape] describes for a `during`-based runtime.
3. **Structured concurrency / cancellation / channels** — the part every mature runtime eventually grows (Go: channels + `context`; Loom: `StructuredTaskScope`; Eio: `Switch`). On `io_uring` this maps onto `IOSQE_IO_LINK` + `LINK_TIMEOUT` + `ASYNC_CANCEL`.

> [!IMPORTANT]
> The deeper limitation — the through-line to the _stackless_ half of this survey — is that D's `Fiber` is permanently the **fixed-stack, conservative-scan, opaque-switch** kind because its GC is conservative and LDC cannot see through `fiber_switchContext`. It therefore cannot adopt the growable-movable-stack trick that makes Go/OCaml/GHC green threads cheap, **and it does not exist on wasm at all** (`assert(0, "Fibers not supported on WASI")`, [d-fiber][d-fiber]). A green-thread runtime built on `Fiber` inherits every one of those costs. A _stackless_ compiler-lowered coroutine sidesteps them all — precise frame, `@nogc`-constructible, thread-movable, compiles to plain wasm — which is why the rest of this survey argues for it ([concepts][concepts]). On wasm specifically, a _stackful_ green-thread runtime would have to retarget its switch onto **WasmFX** `cont`/`resume`/`suspend` ([wasmfx-target][wasmfx-target]); a stackless coroutine needs nothing of the sort.

The landscape doc's conclusion for a Sparkles `io_uring`-first runtime: **build the scheduler + I/O layers on `during` + `core.thread.Fiber`** ([d-landscape][d-landscape]) — i.e. supply the two missing green-thread layers directly, rather than adopting vibe-core or Photon wholesale — while keeping a clear eye on the stackless alternative that the rest of this survey develops.

---

## Sources

- Go runtime (`$REPOS/go/go/src/runtime/`, Go tip/dev June 2026):
  - `runtime2.go` — `g` (`:471`), `gobuf` (`:303`), `m` (`:616`), `p` (`:774`), `stack` (`:460`), `runq`/`runnext` (`:807`/`:820`), `_G*` status constants (`:35-119`).
  - `proc.go` — `gopark`/`mcall(park_m)` (`:450`/`:467`), `goready`/`ready` (`:486`/`:1126`), `park_m` (`:4261`), `execute` (`:3339`), `schedule` (`:4143`), `findRunnable` (`:3397`), `stealWork`/`stealTries` (`:3836`/`:3841`), `runqgrab`/`runqsteal` (`:7706`/`:7774`), spinning-M cap (`:3523`), `newproc`/`newproc1`/`malg` (`:5327`/`:5345`/`:5305`).
  - `stack.go` — `stackMin = 2048` (`:78`), `stackPreempt` (`:131-133`), `copystack`/`newstack` (`:900`/`:1026`).
  - `asm_amd64.s` — `gogo` (`:408`), `mcall` (`:425`), `systemstack` (`:489`).
  - `preempt.go` — preemption design comment / sync + async safe-points (`:7-51`).
  - `HACKING.md` — G-M-P model and type-stability invariant (`:16-42`).
- LDC druntime (`$REPOS/dlang/ldc/runtime/druntime/src/core/thread/fiber/`) — `Fiber`/`FiberBase`, `fiber_switchContext`, stack/guard allocation, WASI `assert(0)`: covered in [d-fiber][d-fiber].
- WasmFX / stack-switching proposal (`$REPOS/wasm/stack-switching/proposals/stack-switching/Explainer.md`) — `cont`/`resume`/`suspend`: covered in [wasmfx-target][wasmfx-target] and [wasmfx][wasmfx].
- Corpus cross-links: [go-netpoller][go-netpoller], [java][java], [haskell][haskell] (async-io); [java-loom][java-loom], [ocaml-effects][ocaml-effects], [wasmfx][wasmfx], [ae-index][ae-index] (algebraic-effects); [d-landscape][d-landscape] (async-io); [concepts][concepts], [d-fiber][d-fiber], [context-switching][context-switching], [stack-management][stack-management], [wasmfx-target][wasmfx-target] (this survey).
- External (not in any source tree): "Mio: A High-Performance Multicore IO Manager for GHC" (Voellmy et al., Haskell Symposium 2013); Loom JEPs 425/444/491 and the `jdk.internal.vm.Continuation` internals; OCaml 5 effect-handler / `multicont` documentation. Each is attributed where cited; the Go-side claims above are source-grounded except the segmented-stacks history (the Go 1.3 "Contiguous stacks" design doc, Morsing/Randall, 2014), which is treated as external in [stack management][stack-management].

<!-- References -->

[concepts]: ../concepts.md
[d-fiber]: ./d-fiber.md
[context-switching]: ./context-switching.md
[stack-management]: ./stack-management.md
[wasmfx-target]: ./wasmfx-as-target.md
[wasmfx]: ../../algebraic-effects/wasmfx.md
[ae-index]: ../../algebraic-effects/index.md
[ocaml-effects]: ../../algebraic-effects/ocaml-effects.md
[java-loom]: ../../algebraic-effects/java-loom.md
[d-landscape]: ../../async-io/d-landscape.md
[go-netpoller]: ../../async-io/go-netpoller.md
[java]: ../../async-io/java.md
[haskell]: ../../async-io/haskell.md
