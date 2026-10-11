# Go `sync` and the runtime semaphore table (Go)

Go's user-level locks are two words of state over a runtime-wide hashed table
of goroutine wait queues: `sync.Mutex` barges by default and switches to FIFO
hand-off after a waiter starves for 1 ms, and every wait parks a _goroutine_,
never the OS thread — the canonical design for M:N fibers that wait on a lock.

|                        |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**               | language runtime + standard library                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| **Language**           | Go (runtime parts in Go + assembly)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| **License**            | BSD-3-Clause                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| **Repository**         | [`golang/go`][go-repo] at `015343854b5d` (2026-06-01)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| **Primitives covered** | `sync.Mutex` (implemented in `internal/sync`), `sync.RWMutex`, `sync.Cond`, `sync.Once`; runtime `semacquire`/`semrelease`, `notifyList`, the runtime-internal `mutex` (`lock_spinbit.go`), `note`                                                                                                                                                                                                                                                                                                                                                    |
| **Parking substrate**  | goroutines: a 251-bucket global table of address-keyed treaps of `sudog`s; Ms (OS threads): a per-M semaphore (futex / pthread condvar / Win32 event)                                                                                                                                                                                                                                                                                                                                                                                                 |
| **Fairness**           | barging ("normal mode") with a 1 ms starvation threshold that switches to direct hand-off                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| **Source read**        | [`internal/sync/mutex.go`][imutex], [`internal/sync/runtime.go`][iruntime], [`sync/mutex.go`][smutex], [`sync/cond.go`][cond], [`sync/rwmutex.go`][rwmutex], [`sync/once.go`][once], [`runtime/sema.go`][sema], [`runtime/lock_spinbit.go`][spinbit], [`runtime/lock_futex.go`][lockfutex], [`runtime/lock_sema.go`][locksema], [`runtime/proc.go`][proc], [`runtime/runtime2.go`][runtime2], [`runtime/os_linux.go`][oslinux], [`runtime/os_darwin.go`][osdarwin], [`runtime/os_windows.go`][oswindows], [`runtime/netpoll_epoll.go`][netpoll-epoll] |

## Overview

### What it solves

Go multiplexes goroutines onto OS threads (Ms) holding scheduler slots (Ps).
A lock that blocked its OS thread would starve every other goroutine queued on
that P, so `sync` never calls the kernel to wait: a contended `Lock` parks the
goroutine through the runtime semaphore, and the M runs something else. The
semaphore's header says what it is for ([`sema.go` L5–L18][sema-head]):

> Semaphore implementation exposed to Go. Intended use is provide a sleep and
> wakeup primitive that can be used in the contended case of other
> synchronization primitives. Thus it targets the same goal as Linux's futex,
> but it has much simpler semantics.
>
> That is, don't think of these as semaphores. Think of them as a way to
> implement sleep and wakeup such that every sleep is paired with a single
> wakeup, even if, due to races, the wakeup happens before the sleep.

The runtime itself cannot use that machinery (it runs on the scheduler's own
stack, sometimes without a P), so it carries a second, thread-level lock —
`runtime.mutex` — whose waiters are whole Ms sleeping on per-M semaphores.

### Design philosophy

Throughput first, with a bounded escape hatch for tail latency. The fairness
comment in [`internal/sync/mutex.go` L31–L54][mutex-fair] is the design
statement:

> Mutex can be in 2 modes of operations: normal and starvation. In normal mode
> waiters are queued in FIFO order, but a woken up waiter does not own the
> mutex and competes with new arriving goroutines over the ownership. New
> arriving goroutines have an advantage -- they are already running on CPU and
> there can be lots of them, so a woken up waiter has good chances of losing.
> In such case it is queued at front of the wait queue. If a waiter fails to
> acquire the mutex for more than 1ms, it switches mutex to the starvation
> mode.
>
> […] Normal mode has considerably better performance as a goroutine can
> acquire a mutex several times in a row even if there are blocked waiters.
> Starvation mode is important to prevent pathological cases of tail latency.

The package doc steers users away from the primitives altogether: "Higher-level
synchronization is better done via channels and communication"
([`sync/mutex.go`][smutex]).

## How it works

`sync.Mutex` is a thin wrapper (`_ noCopy; mu isync.Mutex`) over
`internal/sync.Mutex`, which is two 32-bit words ([L20–L23][imutex-struct]):

```go
type Mutex struct {
	state int32
	sema  uint32
}
```

`state` packs `mutexLocked` (bit 0), `mutexWoken` (bit 1), `mutexStarving`
(bit 2), and a waiter count in bits 3–31 (`mutexWaiterShift = 3`). `sema` is
never waited on by the kernel; its _address_ is the key into the runtime's
semaphore table, and its _value_ is a hand-off token count.

`Lock` is one CAS `0 → mutexLocked` ([L61–L71][mutex-lock]); `Unlock` is one
`atomic.AddInt32(&m.state, -mutexLocked)`, and only a non-zero result takes
`unlockSlow` ([L187–L200][mutex-unlock]). In `lockSlow` ([L95–L182][mutex-lockslow])
a goroutine spins while the lock is held and not starving, setting
`mutexWoken` so the unlocker does not wake a sleeper it would only compete
with; then it CASes in either the lock bit or one more waiter and calls
`runtime_SemacquireMutex(&m.sema, queueLifo, 2)`. A waiter that was already
woken once re-queues with `queueLifo = true` — at the **head** of the wait
queue — and measures its total wait against `starvationThresholdNs = 1e6`.

`semacquire1` ([`sema.go` L146–L201][sema-acquire]) is the classic
check-count-then-sleep under a bucket lock: increment the bucket's `nwait`,
retry `cansemacquire` (a CAS decrement of `*addr` if non-zero), otherwise
`root.queue(addr, s, lifo)` and `goparkunlock(&root.lock, …)`, which releases
the bucket lock only after the goroutine is marked waiting. `semrelease1`
([L207–L289][sema-release]) does `atomic.Xadd(addr, 1)`, returns at once if
`nwait == 0` ("This check must happen after the xadd, to avoid a missed
wakeup"), and otherwise dequeues the first waiter for `addr` and `goready`s it.

## Analysis

### State word and fast path

- **User mutex:** `state` bits as above; the uncontended acquire is
  `CompareAndSwapInt32(&state, 0, 1)` and the release is
  `AddInt32(&state, -1)`. Go's `sync/atomic` operations are sequentially
  consistent, so both are full `LOCK`-prefixed RMWs on x86. The slow paths are
  outlined explicitly so the fast paths inline ("Slow path (outlined so that
  the fast path can be inlined)").
- **Waiter count lives in the word.** Up to 2^29 waiters are counted in
  `state`; unlock can therefore decide "nobody to wake" from the word alone
  ([`unlockSlow` L215][mutex-unlockslow]): no waiters, or someone already
  `mutexLocked|mutexWoken|mutexStarving`, means return without touching the
  table.
- **Runtime mutex (`lock_spinbit.go`):** one `uintptr` `key`
  ([`runtime2.go` L170–L177][runtime2-mutex]). The low byte carries
  `mutexLocked` (0x001) and `mutexSleeping` (0x002) and is acquired and
  released with an **8-bit `Xchg8`**; bit 8 is `mutexSpinning`, bit 9
  `mutexStackLocked`, and the upper bits a partial pointer to the
  most-recently-sleeping M ([L29–L51][spinbit-head]):

  > The fast paths for locking and unlocking the mutex are based on atomic
  > 8-bit swap operations on the low byte; bits 2 through 7 are unused.

  Reconstructing the M pointer from the high bits requires Ms to be allocated
  in a size class aligned to 2048 bytes (`mutexMMask = 0x3FF`), which
  `lockVerifyMSize` checks at start-up ([L102–L128][spinbit-mptr]).

### Waiting: spin, yield, park

- **User mutex:** `runtime_canSpin(iter)` ([`proc.go` L7982–L7996][canspin])
  allows at most `active_spin = 4` iterations, each `procyield(30)` (30 `PAUSE`
  instructions on amd64), and only when all of these hold:

  > sync.Mutex is cooperative, so we are conservative with spinning. Spin only
  > few times and only if running on a multicore machine and GOMAXPROCS>1 and
  > there is at least one other running P and local runq is empty. As opposed
  > to runtime mutex we don't do passive spinning here, because there can be
  > work on global runq or on other Ps.

  The local-runqueue test is the fiber-specific part: spinning when the P has
  other runnable goroutines would delay them, possibly including the lock
  holder. A spinner sets `mutexWoken` so `Unlock` skips waking a sleeper.
  There is no `osyield` and no backoff growth. Spinning is disabled entirely
  in starvation mode.

- **Runtime mutex:** only one M may spin at a time — the one that wins the
  `mutexSpinning` try-lock bit ("Most other Ms must attempt to spend their time
  sleeping to reduce traffic on the cache line"). The spinner does
  `mutexActiveSpinCount = 4` rounds of `procyield(30)`, then
  `mutexPassiveSpinCount = 1` `osyield()`, then pushes itself on the waiter
  stack and `semasleep(-1)` ([`lock2` L164–L267][spinbit-lock2]). An M woken
  from the bottom of the stack (`atTail`) is also allowed to spin, and
  `sched.lock` is exempt (`mutexPreferLowLatency`), letting every waiter spin.

### The parking substrate

- **Goroutine waits — a hashed table of wait queues.** `semtable` is
  `[251]struct{ root semaRoot; pad … }`, each bucket padded to a cache line,
  indexed by `(addr >> 3) % 251` ([L40–L58][sema-table]): "Prime to not
  correlate with any user patterns." Each `semaRoot` holds a runtime `mutex`,
  an atomic `nwait`, and a **treap** of `sudog`s with distinct addresses, each
  heading a FIFO list of further waiters on the same address:

  > The operations on the inner lists of sudogs with the same address are all
  > O(1). The scanning of the top-level semaRoot list is O(log n), where n is
  > the number of distinct addresses with goroutines blocked on them that hash
  > to the given semaRoot.

  The second level was added after `golang.org/issue/17953`, a program that
  collided many addresses in one bucket. Treap priority is
  `cheaprand() | 1`. This is the same shape as WebKit's and Rust
  `parking_lot`'s global table (see [`parking-lot`](./parking-lot.md),
  [`webkit-wtf-lock`](./webkit-wtf-lock.md)): the lock carries no queue, the
  queue lives off-object, keyed by address — but the table is **fixed-size**,
  with the treap absorbing collisions instead of a resize.

- **Waiter records are `sudog`s** ([`runtime2.go` L404][runtime2-sudog]) — the
  same record channels use — taken from a per-P cache by `acquireSudog`, never
  from the lock. A `sudog` stores `g`, `elem` (the address), the treap links,
  a `ticket`, and profiling timestamps.
- **Thread waits — a per-M semaphore.** `runtime.mutex` waiters form an
  intrusive stack through `m.mWaitList.next`, so the lock needs no table at
  all. `semasleep`/`semawakeup` are per-OS: on Linux, FreeBSD and DragonFly
  a futex on `m.waitsema` ([`lock_futex.go` L136–L163][lockfutex-sema]); on
  Darwin a `pthread_mutex` + `pthread_cond` per M ([`os_darwin.go` L26–L90][osdarwin-sema]);
  on Windows an auto-reset event from `CreateEventA` waited with
  `WaitForSingleObject` ([`os_windows.go` L660–L735][oswindows-sema]).
  One-shot `note`s (used to park idle Ms) are a futex word on Linux.

### Fairness, handoff and starvation

Three mechanisms, layered:

1. **Barging with front-of-queue re-insertion.** In normal mode a woken
   waiter races fresh arrivals; if it loses it re-enters the semaphore queue
   with `lifo = true`. `root.queue` then substitutes the new `sudog` at the
   head of the per-address list, copying the old head's `acquiretime` "to
   preserve head acquiretime as oldest time".
2. **Starvation mode.** A waiter whose cumulative wait exceeds 1 ms sets
   `mutexStarving`. In that mode `Lock` neither spins nor tries the lock bit
   ("new arriving goroutines must queue"), and `Unlock` calls
   `runtime_Semrelease(&m.sema, true, 2)` with `handoff = true`. The woken
   waiter owns the mutex without `mutexLocked` being set and fixes the word
   itself, leaving starvation mode if it is the last waiter or waited under
   1 ms ([L152–L170][mutex-starve]):

   > Exit starvation mode. Critical to do it here and consider wait time.
   > Starvation mode is so inefficient, that two goroutines can go lock-step
   > infinitely once they switch mutex to starvation mode.

3. **Direct goroutine hand-off.** With `handoff`, `semrelease1` consumes the
   token on the waiter's behalf (`s.ticket = 1`), puts the waiter in `runnext`
   on the current P, and `goyield()`s so it runs immediately and "inherits our
   time slice" ([`sema.go` L260–L287][sema-handoff]). Without `handoff` the
   unlocker does not yield, because "it is possible for a different waiter to
   acquire the semaphore while we are yielding/scheduling, and this would be
   wasteful" (issue 33747).

The runtime mutex has a probabilistic bound instead of a timer: `unlock2Wake`
wakes the M at the **bottom** of the LIFO waiter stack with probability 1/16
(`mutexTailWakePeriod = 16`, [L346–L361][spinbit-wake]): "On occasion, seek
out and wake the M at the bottom of the stack so it doesn't starve."

### Condition variables and predicates

`sync.Cond` is `{ L Locker; notify notifyList; checker copyChecker }`
([`cond.go` L37–L45][cond-struct]). The runtime's `notifyList`
([`sema.go` L544–L565][notifylist]) is **ticket-based**: `wait` is an atomic
counter of issued tickets, `notify` the next ticket to be notified, plus a
lock-protected singly-linked `sudog` list.

`Wait` ([`cond.go` L67][cond-wait]) is `t := notifyListAdd()`, `L.Unlock()`,
`notifyListWait(t)`, `L.Lock()`. Taking the ticket _before_ releasing `L` closes
the lost-wakeup window without holding any internal lock across the unlock:
`notifyListWait` returns immediately if `less(t, notify)`. `Signal` advances
`notify` by one and searches the list for the `sudog` holding that exact
ticket — "This scan looks linear but essentially always stops quickly";
`Broadcast` sets `notify = wait` and readies the whole detached list. Both
fast-path out without the lock when `wait == notify`. Tickets wrap and are
compared as `int32(a-b) < 0`, valid while fewer than 2^31 goroutines wait.

Findings for the condvar design:

- **No spurious wakeups by contract:** "Unlike in other systems, Wait cannot
  return unless awoken by [Cond.Broadcast] or [Cond.Signal]"
  ([L55][cond-nospurious]). The ticket makes this cheap.
- **No wait morphing.** A woken waiter is made runnable and then calls
  `L.Lock()` itself; `Broadcast` readies every waiter, who then contend for
  `L` ([thundering herd](./concepts.md#thundering-herd)). Because the waker
  and the waiters are goroutines on a handful of Ps, the cost is scheduler
  queue traffic rather than kernel wakeups, which is presumably why the
  requeue optimisation was never needed. `L` is any `Locker`, so the runtime
  could not requeue onto it anyway.
- **No predicate waits** (`Await`, conditions); the doc recommends channels.

`sync.RWMutex` ([L39–L47][rwmutex-struct]) is a writer `Mutex` plus two
semaphores and two counters; a pending writer subtracts
`rwmutexMaxReaders = 1 << 30` from `readerCount`, so new readers see a negative
count and block on `readerSem` — writer-preferring, which "prohibits recursive
read-locking". `sync.Once` ([L20–L80][once]) is an `atomic.Bool` fast path plus
a `Mutex` slow path, with the comment explaining why a CAS-only `Once` is wrong:
"Do guarantees that when it returns, f has finished."

### Footprint and layout

- `sync.Mutex`: **8 bytes** (`int32` + `uint32`), no allocation, zero value
  unlocked. `RWMutex`: 24 bytes. `Cond`: an interface (16) + `notifyList`
  (4 + 4 + runtime mutex 8 + two pointers) + checker — with a run-time size
  check `notifyListCheck` that the `sync` and `runtime` layouts agree.
- The global table is 251 cache-line-padded buckets, statically allocated.
- Per-waiter state is a pooled `sudog` (≈ 100 bytes); nothing is reserved per
  lock.
- `runtime.mutex`: one `uintptr`; waiter state lives in the M itself
  (`mWaitList`), so the runtime mutex costs no allocation even under
  contention — the payoff for the 2048-byte alignment trick.

### Portability

User-level locks are OS-independent: `semacquire` parks goroutines in the
scheduler. Only the M-level primitives touch the OS:

| Platform                      | `semasleep` / `note`                                                                                        |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------- |
| Linux, FreeBSD, DragonFly     | futex word on `m.waitsema` / `note.key` (`FUTEX_WAIT_PRIVATE` on Linux, [`os_linux.go` L66][oslinux-futex]) |
| Darwin                        | `pthread_mutex_t` + `pthread_cond_t` per M, counted                                                         |
| Windows                       | auto-reset Win32 event per M                                                                                |
| AIX, NetBSD, OpenBSD, Solaris | OS-specific semaphore / `lwp_park` (via `lock_sema.go`)                                                     |
| `js`, `wasip1`                | single-threaded `lock_js.go` / `lock_wasip1.go`                                                             |

Go does **not** use `__ulock_wait` on Darwin, `WaitOnAddress` on Windows, or
`_umtx_op` on FreeBSD (FreeBSD's `futexsleep` is implemented with
`_umtx_op(UMTX_OP_WAIT_UINT_PRIVATE)` in `os_freebsd.go`, which is how it shares
`lock_futex.go`). The Darwin choice keeps the runtime on public libc API.

### Async and fiber integration

This is Go's whole point, and the mechanism is the template for a
loop-resident fiber registry:

1. **Park.** `gopark(unlockf, lock, …)` ([`proc.go` L450][gopark]) switches to
   the M's scheduler stack (`mcall(park_m)`), marks the G `_Gwaiting`, and only
   then runs `unlockf` — for semaphores, `parkunlock_c`, which releases the
   bucket lock. Ordering "mark waiting, then drop the queue lock" is what makes
   enqueue-then-sleep race-free without a futex-style compare in the kernel.
   The M then calls `schedule()` and runs another goroutine.
2. **Wake from any thread.** `goready` → `ready` ([L1126][ready]) CASes the G
   to `_Grunnable`, `runqput`s it on the **waker's** P (with `next = true`,
   so it runs next), and calls `wakep()` ([L3220][wakep]) to start a spinning
   M for an idle P if none is spinning. The woken goroutine migrates to the
   waker's P rather than returning to the P it slept on — Go has no thread
   affinity to preserve.
3. **Cross the poller.** An idle M with nothing to run blocks in
   `netpoll(delay)` ("block until new work is available", [L3762][findrunnable-netpoll])
   when there are network waiters or timers, or in `stopm` on its `note`
   otherwise. Work that must reach that thread uses `netpollBreak`, which on
   Linux writes to an eventfd, deduplicated by a CAS on `netpollWakeSig`
   ("Failing to cas indicates there is an in-flight wakeup",
   [`netpoll_epoll.go` L67][netpoll-break]); `wakeNetPoller` does this when a
   new timer is earlier than the poller's deadline ([L4010][wakenetpoller]).

Two facts bear directly on a Sparkles `WaitWord`. First, Go never makes a
goroutine wait on a kernel word: the wait queue is entirely user space (the
semtable), and the only kernel object involved is the per-M sleep primitive
of whatever thread ends up idle. Second, a waker on another thread does not
need to know which thread the waiter's scheduler runs on — it appends to a
run queue it already owns and kicks an idle thread; a per-thread event loop
(the Sparkles model) has no such shared run queue, so it needs the
eventfd-style break (`netpollBreak`) aimed at the _owning_ loop instead.

## Strengths

- 8-byte mutex, inlined one-instruction fast paths, and an unlock that reads
  "anyone to wake?" from the word.
- Starvation mode bounds tail latency at ~1 ms of barging, then degrades
  gracefully to FIFO hand-off and exits as soon as the queue drains.
- One substrate (semtable + `gopark`) serves `Mutex`, `RWMutex`, `WaitGroup`,
  and `internal/poll`; one more (`notifyList`) serves `Cond`.
- Spin policy consults scheduler state (idle Ps, local runqueue), not just a
  counter.
- `Cond` has no spurious wakeups and no internal lock held across `L.Unlock`.

## Weaknesses

- The 251-bucket table is fixed; heavy contention on many distinct locks
  shares bucket locks (a treap mitigates scanning, not lock contention).
- `Cond.Broadcast` wakes every waiter to fight for `L`; no requeue.
- `RWMutex` is writer-preferring and forbids recursive read locks; readers
  bounce one `readerCount` cache line.
- Starvation mode, by the source's own admission, is "so inefficient" that
  exit must be forced.
- The scheduler-aware spin and hand-off rely on a global runtime (Ps, run
  queues); they do not transfer to a library mutex on top of OS threads.
- The runtime mutex's pointer-packing needs an allocator guarantee (2048-byte
  alignment) a general library cannot assume.

## Key design decisions and trade-offs

| Decision                                                            | Rationale                                                                               | Trade-off                                                                       |
| ------------------------------------------------------------------- | --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Waiter count in the lock word; queue in a global hashed table       | unlock decides without touching shared tables; lock stays 8 bytes                       | 29-bit waiter count; table bucket locks are shared across unrelated mutexes     |
| Barging by default, FIFO hand-off after 1 ms                        | running goroutines reacquire hot locks cheaply; tail latency still bounded              | a wall-clock threshold; lock-step pathology needs an explicit exit rule         |
| Woken loser re-queued at the head (`lifo`)                          | preserves FIFO-ish order for the oldest waiter without hand-off                         | the queue head is churned on every lost race                                    |
| Spin ≤ 4 × 30 `PAUSE`, only if other Ps run and local runq is empty | never delay runnable goroutines (possibly the holder) by spinning                       | very short spin; relies on scheduler introspection                              |
| Hand-off yields the time slice to the waiter (`goyield`)            | a highly contended lock cannot let the releaser re-grab it                              | only in starvation mode; a context switch per hand-off                          |
| Ticket-based `notifyList` for `Cond`                                | no lost wakeups without holding an internal lock across `L.Unlock`; no spurious wakeups | linear search for the ticket on `Signal`; `Broadcast` stampedes                 |
| Runtime mutex: 8-bit swap + one spinner bit + intrusive M stack     | cheap fast path, limited cache-line traffic, zero allocation in the runtime             | LIFO stack needs a 1/16 random tail wake; needs 2048-byte-aligned M allocations |
| Park goroutines, not threads; wake via run queue + `wakep`          | a lock wait never removes an OS thread from service                                     | requires the runtime to own every thread's scheduler                            |

## Sources

- Go source at commit `015343854b5d9e2829481df30dbcae2ca6682d25` (2026-06-01):
  [`src/internal/sync/mutex.go`][imutex], [`src/internal/sync/runtime.go`][iruntime],
  [`src/sync/mutex.go`][smutex], [`src/sync/cond.go`][cond],
  [`src/sync/rwmutex.go`][rwmutex], [`src/sync/once.go`][once],
  [`src/runtime/sema.go`][sema], [`src/runtime/lock_spinbit.go`][spinbit],
  [`src/runtime/lock_futex.go`][lockfutex], [`src/runtime/lock_sema.go`][locksema],
  [`src/runtime/proc.go`][proc], [`src/runtime/runtime2.go`][runtime2],
  [`src/runtime/os_linux.go`][oslinux], [`src/runtime/os_darwin.go`][osdarwin],
  [`src/runtime/os_windows.go`][oswindows], [`src/runtime/netpoll_epoll.go`][netpoll-epoll].
- Mullender and Cox, "Semaphores in Plan 9", cited by `sema.go`:
  [swtch.com/semaphore.pdf][plan9-sema].
- Siblings: [`parking-lot`](./parking-lot.md) and
  [`webkit-wtf-lock`](./webkit-wtf-lock.md) (the same address-keyed table, in
  a library), [`linux-futex`](./linux-futex.md) (the kernel analogue),
  [`tokio-sync`](./tokio-sync.md) (task-level waiting without a runtime-owned
  scheduler).

> [!NOTE]
> The Go clone is a single-commit checkout, so no claim here dates when a
> mechanism landed (for example, when `lock_spinbit.go` replaced the earlier
> futex/sema-based `lock2`); the files describe the state at the pinned SHA.
> `sudog` size is an estimate from its field list, not a measurement.

<!-- References -->

[go-repo]: https://github.com/golang/go/tree/015343854b5d9e2829481df30dbcae2ca6682d25
[imutex]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/internal/sync/mutex.go
[imutex-struct]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/internal/sync/mutex.go#L20-L23
[mutex-fair]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/internal/sync/mutex.go#L31-L55
[mutex-lock]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/internal/sync/mutex.go#L61-L71
[mutex-lockslow]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/internal/sync/mutex.go#L95-L182
[mutex-starve]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/internal/sync/mutex.go#L152-L170
[mutex-unlock]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/internal/sync/mutex.go#L187-L200
[mutex-unlockslow]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/internal/sync/mutex.go#L202-L234
[iruntime]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/internal/sync/runtime.go
[smutex]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/sync/mutex.go
[cond]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/sync/cond.go
[cond-struct]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/sync/cond.go#L37-L45
[cond-nospurious]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/sync/cond.go#L55
[cond-wait]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/sync/cond.go#L67
[rwmutex]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/sync/rwmutex.go
[rwmutex-struct]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/sync/rwmutex.go#L39-L47
[once]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/sync/once.go#L20-L80
[sema]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/sema.go
[sema-head]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/sema.go#L5-L18
[sema-table]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/sema.go#L28-L58
[sema-acquire]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/sema.go#L146-L201
[sema-release]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/sema.go#L207-L289
[sema-handoff]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/sema.go#L260-L287
[notifylist]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/sema.go#L544-L722
[spinbit]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/lock_spinbit.go
[spinbit-head]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/lock_spinbit.go#L29-L80
[spinbit-mptr]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/lock_spinbit.go#L102-L128
[spinbit-lock2]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/lock_spinbit.go#L164-L267
[spinbit-wake]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/lock_spinbit.go#L346-L361
[lockfutex]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/lock_futex.go
[lockfutex-sema]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/lock_futex.go#L135-L163
[locksema]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/lock_sema.go
[proc]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/proc.go
[canspin]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/proc.go#L7978-L8001
[gopark]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/proc.go#L421-L474
[ready]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/proc.go#L1125-L1145
[wakep]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/proc.go#L3207-L3245
[findrunnable-netpoll]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/proc.go#L3740-L3770
[wakenetpoller]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/proc.go#L4007-L4025
[runtime2]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/runtime2.go
[runtime2-mutex]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/runtime2.go#L170-L177
[runtime2-sudog]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/runtime2.go#L404-L446
[oslinux]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/os_linux.go
[oslinux-futex]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/os_linux.go#L66-L83
[osdarwin]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/os_darwin.go
[osdarwin-sema]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/os_darwin.go#L26-L90
[oswindows]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/os_windows.go
[oswindows-sema]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/os_windows.go#L660-L735
[netpoll-epoll]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/netpoll_epoll.go
[netpoll-break]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/netpoll_epoll.go#L66-L89
[plan9-sema]: https://swtch.com/semaphore.pdf
