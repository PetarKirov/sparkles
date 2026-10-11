# Comparison and synthesis

What the survey's thirteen lock implementations, four operating-system wait
primitives, four async runtimes and twelve papers agree on, where they split,
and what that settles for `sparkles.base.sync` and event-horizon's `WaitWord`.

**Last reviewed:** October 12, 2026

> [!IMPORTANT]
> This page answers the four questions the survey was commissioned for. It
> recommends; the binding decisions are made in the `sparkles.base.sync`
> specification, which cites the sections below.

## At a glance

| Subject                     | Lock word                              | Waiters live in                           | Spin before sleeping                         | Fairness                                   | Condvar requeue                | Fibers / tasks                              |
| --------------------------- | -------------------------------------- | ----------------------------------------- | -------------------------------------------- | ------------------------------------------ | ------------------------------ | ------------------------------------------- |
| [Rust std][rust-std]        | 3-state futex, `u32` (`u8` on Windows) | the kernel's futex queue                  | 100 reads, stops at contended                | barging, no bound                          | no (sequence counter)          | none                                        |
| [Zig][zig]                  | 3-state futex, `u32`                   | kernel futex; own table on Windows        | none                                         | barging, no bound                          | no (epoch + counts)            | `Io` vtable: ring `FUTEX_WAIT` under uring  |
| [glibc][glibc]              | 3-state `lll_lock`                     | the kernel's futex queue                  | none by default; adaptive type opt-in        | barging, no bound                          | no (G1/G2 groups, 2016)        | none                                        |
| [parking_lot][parking-lot]  | 1 byte: `LOCKED`, `PARKED`             | global hashed table, per-thread parker    | 3 pause rounds + 7 yields, only if no parked | barging; explicit fair unlock only at HEAD | yes (`unpark_requeue`)         | none                                        |
| [WebKit `WTF::Lock`][wtf]   | 2 bits: `isHeld`, `hasParked`          | global hashed table, per-thread condvar   | tuned `pause` bursts per platform            | random handoff, ~1 ms per bucket           | no (herds)                     | none                                        |
| [Go][go]                    | 8-byte word: lock bits + waiter count  | runtime `semaRoot` treap, 251 buckets     | 4 × 30 `PAUSE`, only if another P runs       | barging, FIFO handoff after 1 ms           | no (ticket list)               | **native**: `gopark` parks the goroutine    |
| [Abseil][abseil]            | 8 bytes: flags + queue pointer         | queue hanging off the word                | 1500 CAS retries                             | designated waker; long-wait bit            | yes (`Fer`, without a wake)    | none                                        |
| [nsync][nsync]              | word + queue (spinlock bit inside)     | queue hanging off the lock                | none                                         | after 30 failed wakes, waiter goes first   | yes (onto the mutex's queue)   | `nsync_wait_n` over a vtable                |
| [Folly][folly]              | `DistributedMutex`: tail pointer       | waiters' stack nodes (LIFO, combining)    | ~2 µs                                        | combining; no FIFO                         | —                              | `fibers::Baton`: one word, thread or fiber  |
| [Java AQS][aqs]             | `int state` + queue head/tail          | CLH-style queue per lock                  | retries growing to 256                       | barging; fair mode opt-in                  | yes (node moves to lock queue) | **native**: `park` yields a virtual thread  |
| [`os_unfair_lock`][unfair]  | owner's Mach port                      | kernel turnstile                          | kernel-side, while the owner runs (20 µs)    | none, by name                              | —                              | none                                        |
| [SRWLOCK][srw]              | pointer-sized, zero-initialized        | unpublished; Wine: `RtlWaitOnAddress`     | none documented; Wine: none                  | barging since 2003 SP1                     | no                             | none; no handle                             |
| [Linux kernel mutex][queue] | owner pointer + flag bits              | MCS/OSQ while spinning, list when asleep  | while the owner is on a CPU                  | `HANDOFF` flag after a lost race           | —                              | —                                           |
| [tokio][tokio]              | semaphore permits                      | intrusive list in the semaphore           | none                                         | strict FIFO handoff                        | `Notify` stores a permit       | native (tasks); `blocking_lock` for threads |
| [event-listener][smol]      | `async-lock`: state word               | intrusive list; `Waker` **or** `Unparker` | none                                         | barging, starvation mode after 500 µs      | —                              | native, threads and tasks share one list    |
| [Seastar][seastar]          | shard-local counters                   | per-shard intrusive lists                 | none (one thread)                            | FIFO                                       | —                              | native; cross-shard by message only         |
| [Trio][trio]                | `ParkingLot` per object                | per-object ordered dict                   | none (one thread)                            | FIFO handoff                               | —                              | native; `from_thread` to enter              |
| [kotlinx `Mutex`][cqs]      | CQS segments + counter                 | infinite array of cells (CQS)             | none                                         | FIFO, abortable                            | —                              | native (coroutines)                         |

## (a) The mutex word

**Recommendation: a parking-lot lock — two bits of state plus a
designated-waker bit, with waiters in a fixed, statically allocated table of
address-keyed queues.** The three-state futex word is the simpler design and
the one three standard libraries chose; the parking lot is the faster and more
expressive one once its one pathology is fixed.

What the parking lot buys:

- **Throughput, with the designated waker.** On a 32-thread machine
  ([mutex benchmark][ex-mutex]), a parking lock that wakes at most one waiter
  at a time — nsync's `MU_DESIG_WAKER`, Abseil's `kMuDesig`
  ([nsync § fairness][nsync-fair], [Abseil][abseil]) — runs about 2.2× the
  three-state word's throughput at 32 and 64 threads (≈ 90 against ≈ 41
  acquisitions per microsecond) and 3.5–4.5× at 2 and 4 threads, sleeping on
  0.002 acquisitions where the three-state word sleeps on 0.04. The benchmark
  does not give the three-state word an equivalent bit.
- **Wait morphing, exact notifications, handoff.** Only a lock whose queue
  the library owns can have its condition variable requeue waiters onto it,
  report exactly how many it woke, and hand the lock to a chosen waiter with a
  token ([parking_lot § condition variables][parking-cv];
  [concepts § wait morphing][c-morph]).
- **Locks in two bits of any word.** WebKit's `LockAlgorithm` projects the lock
  onto any atomic field, so a per-object lock lives in an object header and
  `CountingLock` keeps an optimistic-read counter beside it
  ([WebKit][wtf]). A futex lock needs its own 32-bit word.
- **Richer wakes.** `unpark_filter` wakes all readers and one writer in one
  pass; `forEach` and parking_lot's wait-for graph make the waiters
  inspectable for deadlock detection ([parking_lot][parking-lot]).
- **One registry for threads and fibers.** The table's queue node can hold a
  thread's parker or a fiber's loop waker; see [(d)](#d-fibers-waiting-on-a-word-the-waitword-registry).
- **No empty-wake system calls.** An unlock with no sleeper never enters the
  kernel, and a wake targets one thread's own word, so the kernel's futex hash
  sees one waiter per word. An empty `FUTEX_WAKE` costs about 270 ns against
  1.6 ns for an uncontended acquire and release ([Linux § cost][futex-cost]).

Why the standard libraries chose otherwise, and why it does not bind here:

- **Simplicity.** Rust's 2022 decision: a futex lock "is simple and easy to
  implement and verify, as it leaves most of the complexity to the kernel"
  ([Rust § overview][rust-std]). An implementation-cost argument.
- **Bootstrapping.** Rust also rejected `parking_lot` because its table grows
  by allocating, and an allocator may itself take a lock
  ([Rust § overview][rust-std]). Growth is `parking_lot`'s choice, not the
  design's: Go's runtime table has 251 buckets, Zig's 256, Wine's
  `WaitOnAddress` 256 and Folly's `ParkingLot` 4096, all fixed
  ([Go][go], [Zig § parking substrate][zig-substrate],
  [Windows § how it works][woa-how], [Folly][folly]). With a fixed table and
  waiter records in thread-local storage or a fiber's frame, the lock never
  allocates.
- **The convoy.** `parking_lot` as shipped collapses once the cores are
  saturated: its own benchmark, built from HEAD and from 0.12.5, runs 6–8×
  slower than `std::sync::Mutex` at 32 and 64 threads while winning by
  1.3–1.6× at 2 and 4 (8 iterations inside the lock, 16 outside, one second
  per cell, measured locally on 2026-10-11). Its `PARKED` bit is exact, so
  every unlock while the queue is non-empty wakes a waiter that loses the race
  to a running thread and parks again — 0.8–0.97 sleeps per acquisition in the
  port. Spinning despite `PARKED` does not cure it; the designated-waker bit
  does ([concepts § convoys][c-convoys]).

What the specification must still decide:

- **Collisions.** Locks whose addresses share a bucket share its lock and its
  queue scan; the table's size and per-bucket structure (a list, Go's treap)
  set the cost.
- **Owner identity.** Spinning only while the owner runs, and priority
  inheritance, both need the owner in the word ([queue locks § spinning][queue-spin],
  [`os_unfair_lock` § state word][unfair-word]). Neither design has it in
  two bits.
- **Scope.** A parking lot is process-private, and its operations are not
  async-signal-safe ([parking_lot § async][parking-async]).

## (b) The condition variable

**Recommendation: wait morphing over the parking lot** — `parking_lot`'s
`Condvar`: one pointer naming the mutex, `notify_one` requeuing a waiter onto
the mutex's queue when the mutex is held, `notify_all` requeuing all of them,
and exact notification results with no spurious wakeups
([parking_lot § condition variables][parking-cv]).

- **glibc's case against requeue does not apply.** Riegel dropped
  `FUTEX_CMP_REQUEUE` in 2016 because, over a futex word, requeue forces every
  waiter to drive the mutex into `contended` so each release pays a wake; it
  prevented lock elision; and "it should be the mutex who decides"
  ([glibc § condition variables][glibc-cv]). In a parking lot the requeue runs
  under the bucket lock and `have_more_threads` keeps `PARKED` exact, so no
  release pays an unneeded wake; glibc itself deprecated elision in 2.42 and
  removed it in 2.43 ([glibc][glibc]); and `parking_lot`'s condvar asks the
  mutex (`mark_parked_if_locked`) before choosing requeue or wake.
- **It removes the herd.** WebKit's `Condition`, with no requeue, makes every
  `notifyAll` herd ([WebKit § condition variables][wtf-cv]); Abseil's `Fer`,
  nsync and Java AQS move signalled waiters onto the lock queue instead
  ([Abseil][abseil], [nsync § condition variables][nsync-cv],
  [AQS § fairness][aqs-fair]).
- **Exactness is cheap here, not there.** glibc's G1/G2 groups bought ordering
  over a futex at 48 bytes, an internal lock per signal and a lost-wakeup bug
  that stood from 2.25 to 2.41 ([glibc § condition variables][glibc-cv]). Over
  an owned queue, ordering is the queue's order.
- **The kernel's wake counts never matter.** Only Linux reports how many it
  woke ([FreeBSD § wake counts][umtx-wake]); the parking lot counts its own
  queue.

**Predicate waits** (Abseil's `Await`, nsync's `nsync_mu_wait`) evaluate
predicates on the unlocking thread and grow with the number of distinct false
predicates ([nsync § condition variables][nsync-cv]); over an owned queue they
are an addition the design permits, not a primitive it needs.

## (c) Fairness and spinning

**Recommendation: barge by default; bound starvation by a count of failed
wakes, handing the lock to the designated waker once it is exceeded; spin
briefly before parking.**

- **Handoff convoys are why everyone barges.** MCS's own 1991 paper recommends
  against FIFO spinning when waiters can be preempted; Windows SRW and Java AQS
  moved to barging for the same reason ([AQS § fairness][aqs-fair],
  [SRW][srw]), and the CQS evaluation finds strict FIFO does not pay for a
  single-permit mutex ([CQS][cqs]).
- **Bounds without a clock exist.** The Linux kernel mutex lets a woken waiter
  that lost the race set `HANDOFF`, and the next unlock hands it the lock
  ([queue locks § fairness][queue-fair]); nsync's waiter takes the front after
  30 failed wakeups ([nsync § fairness][nsync-fair]). The parking lot's
  `UnparkToken` is the handoff channel. Timer bounds — Go's 1 ms, WebKit's
  random ~1 ms, async-lock's 500 µs — read a clock on the slow path, and
  `parking_lot` removed its timer at HEAD without a stated reason
  ([parking_lot § fairness][parking-fair]).
- **No OS gives FIFO wakeups.** Linux wakes by priority then FIFO, Darwin's
  turnstiles by priority; Windows documents FIFO but calls it descriptive
  ([Windows § semantics][woa-sem]). A parking lot's own queue is the only
  ordered one.
- **Spin budgets span three orders of magnitude** — none (Zig, nsync,
  `os_unfair_lock`), 14 pauses and 7 yields (`parking_lot`), 100 reads (Rust),
  4 × 30 `PAUSE` (Go), 2 µs (Folly), 1500 CAS (Abseil) — and only the
  owner-aware ones are principled; WebKit tunes its `pause` bursts per
  platform ([WebKit § spinning][wtf-spin]).
- **Fibers change the spin.** A cooperative scheduler can deadlock a pure
  spinner whose holder yielded; spin → yield → suspend is the safe ladder, and
  its best mix depends on the runtime ([Skazhenik 2025][skazhenik]).

## (d) Fibers waiting on a word: the `WaitWord` registry

A loop-resident fiber must wait on a word without blocking its loop's thread,
and be woken by any thread. The survey offers three shapes.

1. **The kernel futex queue, through the ring.** Under io_uring (6.7+), a
   fiber's wait is `IORING_OP_FUTEX_WAIT` and any thread's plain `FUTEX_WAKE`
   produces a completion ([Linux § event-loop integration][futex-loop]); Zig's
   `Io.Uring` does exactly this ([Zig § async][zig-async]). Linux only.
2. **One parking entry point that knows the waiter's kind.** Java's
   `LockSupport.park` yields a virtual thread and blocks a platform thread, so
   every `java.util.concurrent` lock became fiber-safe unchanged
   ([AQS § async][aqs-async]); event-listener stores a task `Waker` or a thread
   `Unparker` per entry ([smol § async][smol-async]); Folly's `fibers::Baton`
   holds a thread or a fiber waiter in one word ([Folly][folly]); Go's
   `gopark` is the runtime-native version ([Go][go]).
3. **A user-space registry plus a doorbell.** Where the OS cannot report an
   address wait as a completion — `WaitOnAddress` has no handle for IOCP,
   kqueue has no address filter — the waker finds the fiber in a user-space
   table and posts to its loop ([Windows § event-loop integration][woa-loop],
   [Darwin § event-loop integration][ulock-loop]).

**Recommendation: the parking lot of (a) is the registry** — shape 2 built on
shape 3. A queue node carries either a thread's parker or a fiber's loop
waker; `park` asks the current context which, and every primitive — `Mutex`,
`Condition`, `RwLock`, `Semaphore`, `WaitWord` — becomes fiber-aware on every
OS at once, as Java's did. Shape 1 remains an optimization for a plain
`WaitWord` on Linux, not the mechanism. The registry's rules come from the
survey:

- **Two-phase wake.** Choose the waiter and commit the token under the bucket
  lock; deliver the wake — a futex wake, an io_uring message, an IOCP packet,
  an `EVFILT_USER` trigger — after releasing it, as `parking_lot`'s
  `unpark_lock`/`unpark` does ([parking_lot § async][parking-async]).
- **Address-keyed, tolerant of stale wakes.** A wake can reach freed or reused
  memory ([glibc][glibc]; [concepts § spurious wakeups][c-spurious]).
- **A `seq_cst` edge between publishing and reading the waiter's state.** The
  "announce sleeping, re-check, block" handshake loses wakeups with only
  release/acquire ([Enberg 2019][enberg]).
- **Cancellation never loses a wake.** A cancelled waiter that was already
  chosen passes its wake or token on (tokio, event-listener, Seastar, Trio —
  [tokio § fairness][tokio-fair]; [CQS][cqs]).
- **Multi-wait by one state cell.** A fiber waiting on several words gets one
  `WAITING → SYNCHED` cell, entered in every queue, won by one CAS; losing
  queues keep dead entries to sweep ([Reppy 1991][reppy]).
- **Resume locally when handing off.** Dispatching the woken fiber to a ready
  queue leaves the lock idle for the queueing delay; resuming it on the
  releasing thread and requeuing the releaser fixes that (CES:
  [König 2025][koenig]; Go's starvation mode already does it).

## Delta: Sparkles today

| Capability                          | Prior art                                          | Sparkles today                                                   |
| ----------------------------------- | -------------------------------------------------- | ---------------------------------------------------------------- |
| Wait-on-address seam per OS         | Rust `sys::futex`, Zig `Futex`                     | raw `FUTEX_WAKE` in event-horizon's `Waker` only (Linux)         |
| Parking lot with callbacks          | WebKit `ParkingLot`, `parking_lot_core`, Go `sema` | none                                                             |
| Parking-lot mutex, designated waker | `parking_lot`, nsync, Abseil                       | none; `core.sync.mutex` (`pthread_mutex_t`) everywhere           |
| Wait-morphing condvar               | `parking_lot`, Abseil, nsync, Java AQS             | `core.sync.condition` (pthread)                                  |
| `Once` without pthread              | `parking_lot` `Once`, Go `sync.Once`               | a static `pthread_mutex_t` guards the shared blocking pool       |
| Fiber-aware waiting                 | Java `park`, event-listener, Folly `Baton`         | in-ring `FUTEX_WAIT` for the loop's own waker; no user-facing op |
| Cross-thread wake into a loop       | Seastar `membarrier`, Go netpoll break             | `Waker`: futex word (uring), `EVFILT_USER` (kqueue), IOCP packet |

## Sources

Every row above cites the deep-dive it summarizes; the deep-dives cite source
trees pinned to commits and the papers' full texts.

<!-- References -->

[rust-std]: ./rust-std-sync.md
[zig]: ./zig-std-sync.md
[zig-async]: ./zig-std-sync.md#async-and-fiber-integration
[glibc]: ./glibc-nptl.md
[glibc-cv]: ./glibc-nptl.md#condition-variables-and-predicates
[parking-lot]: ./parking-lot.md
[parking-fair]: ./parking-lot.md#fairness-handoff-and-starvation
[parking-async]: ./parking-lot.md#async-and-fiber-integration
[parking-cv]: ./parking-lot.md#condition-variables-and-predicates
[wtf-cv]: ./webkit-wtf-lock.md#condition-variables-and-predicates
[wtf-spin]: ./webkit-wtf-lock.md#waiting-spin-yield-park
[zig-substrate]: ./zig-std-sync.md#the-parking-substrate
[wtf]: ./webkit-wtf-lock.md
[go]: ./go-sync.md
[abseil]: ./abseil-mutex.md
[nsync]: ./nsync.md
[nsync-cv]: ./nsync.md#condition-variables-and-predicates
[nsync-fair]: ./nsync.md#fairness-handoff-and-starvation
[folly]: ./folly-sync.md
[aqs]: ./java-aqs.md
[aqs-fair]: ./java-aqs.md#fairness-handoff-and-starvation
[aqs-async]: ./java-aqs.md#async-and-fiber-integration
[unfair]: ./apple-os-unfair-lock.md
[unfair-word]: ./apple-os-unfair-lock.md#state-word-and-fast-path
[srw]: ./windows-srwlock.md
[queue]: ./queue-locks.md
[queue-spin]: ./queue-locks.md#waiting-spin-yield-park
[queue-fair]: ./queue-locks.md#fairness-handoff-and-starvation
[tokio]: ./tokio-sync.md
[tokio-fair]: ./tokio-sync.md#fairness-handoff-and-starvation
[smol]: ./smol-event-listener.md
[smol-async]: ./smol-event-listener.md#async-and-fiber-integration
[seastar]: ./seastar-sync.md
[trio]: ./trio-sync.md
[cqs]: ./koval-2023-cqs.md
[futex-cost]: ./linux-futex.md#cost
[futex-loop]: ./linux-futex.md#event-loop-integration
[woa-how]: ./windows-wait-on-address.md#how-it-works
[woa-sem]: ./windows-wait-on-address.md#semantics
[woa-loop]: ./windows-wait-on-address.md#event-loop-integration
[ulock-loop]: ./darwin-ulock.md#event-loop-integration
[umtx-wake]: ./freebsd-umtx.md#spurious-wakeups-and-wake-counts
[skazhenik]: ./skazhenik-2025-lightweight-locks.md
[enberg]: ./enberg-2019.md
[reppy]: ./reppy-1991-cml.md
[koenig]: ./koenig-2025-combine-and-exchange.md
[c-convoys]: ./concepts.md#convoys
[c-morph]: ./concepts.md#wait-morphing
[c-spurious]: ./concepts.md#spurious-wakeups
[ex-mutex]: ./examples/mutex-throughput.d
