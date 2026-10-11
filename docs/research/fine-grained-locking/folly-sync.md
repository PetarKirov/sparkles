# Folly `synchronization` (C++)

Meta's toolbox of specialised locks rather than one general mutex: an
8-byte `DistributedMutex` that queues waiters as an MCS-like LIFO chain on
their own stacks and can _combine_ critical sections, a 4-byte `SharedMutex`
with per-core deferred readers, a 1-byte `MicroLock`, futex-word `Baton`s, a
WebKit-style `ParkingLot` that emulates futex everywhere but Linux, and
coroutine (`coro::Mutex`) and fiber (`fibers::Baton`) primitives that wait
without blocking a thread.

|                        |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Kind**               | library (`folly/synchronization`, `folly/detail`, `folly/coro`, `folly/fibers`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| **Language**           | C++17/20                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| **License**            | Apache-2.0                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| **Repository**         | [`facebook/folly`][folly-repo] at `643e26aee8e2` (2026-10-11)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| **Primitives covered** | `DistributedMutex`, `SharedMutex`, `MicroLock`, `Baton`, `ParkingLot`, `detail::Futex`, `atomic_wait`/`atomic_notify_*`, `WaitOptions`, `coro::Mutex`, `coro::Baton`, `fibers::Baton`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| **Parking substrate**  | Linux: `futex` (`FUTEX_WAIT_BITSET`, private); elsewhere and for non-32-bit words: `ParkingLot`, a 4096-bucket hash table of `std::mutex` + `std::condition_variable` wait nodes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| **Fairness**           | per primitive: `DistributedMutex` hands off along LIFO chains; `coro::Mutex` strict FIFO; `SharedMutex` writer-priority by default                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| **Source read**        | [`DistributedMutex.h`][dm-h], [`DistributedMutex-inl.h`][dm-inl], [`test/SmallLocksBenchmark.cpp`][slb], [`SharedMutex.h`][shm-h], [`MicroLock.h`][microlock-h], [`Baton.h`][baton-h], [`WaitOptions.h`][waitopts-h], [`ParkingLot.h`][pl-h], [`ParkingLot.cpp`][pl-cc], [`detail/Futex.h`][futex-h], [`detail/Futex.cpp`][futex-cc], [`AtomicNotification.h`][an-h], [`AtomicNotification-inl.h`][an-inl], [`coro/Mutex.h`][cmutex-h], [`coro/Mutex.cpp`][cmutex-cc], [`coro/Baton.h`][cbaton-h], [`fibers/Baton.h`][fbaton-h], [`fibers/Baton.cpp`][fbaton-cc], [`fibers/Baton-inl.h`][fbaton-inl], [`fibers/Fiber.cpp`][fiber-cc], [`fibers/FiberManager.cpp`][fm-cc] |

## Overview

### What it solves

Folly targets server workloads where a contended lock is the bottleneck, and
attacks the coherence traffic of the lock word itself.
`DistributedMutex`'s header comment states the thesis
([`DistributedMutex.h` L31–L143][dm-doc]):

> Theoretically, write locks promote concurrency when the critical sections
> are small as most of the work is done outside the lock. […] However, most
> times, the synchronization and scheduling overhead of a write lock in the
> critical path is so high, that after a certain point, making critical
> sections smaller does not actually increase the concurrency of the
> application and throughput plateaus. DistributedMutex moves this breaking
> point to the level of hardware atomic instructions, so applications keep
> getting concurrency even under very high contention. It does this by
> reducing cache misses and contention in userspace and in the kernel by
> making each thread wait on a thread local node and futex.

`SharedMutex` applies the same reasoning to readers ([`SharedMutex.h` L45–L52][shm-doc]):
"Unlike most other reader-writer locks, its throughput with concurrent readers
scales linearly; it is able to acquire and release the lock in shared mode
without cache line ping-ponging."

### Design philosophy

Spin briefly, then sleep precisely. `WaitOptions` gives the shared rationale
for a 2 µs default spin ([`WaitOptions.h` L33–L55][waitopts]):

> In this state, we lose big 50% of the time if the wait blocks immediately.
> […] We use a default maximum of 2 usec of spinning. As partial
> consolation, since spinning as implemented in folly uses the pause
> instruction where available, we give a small speed boost to the colocated
> hyperthread.
>
> On circa-2013 devbox hardware, it costs about 7 usec to FUTEX_WAIT and then
> be awoken. Spins on this hw take about 7 nsec, where all but 0.5 nsec is
> the pause instruction.

Each primitive is narrow and states its narrowness: `Baton` is "basically a
stripped-down semaphore that supports only a single call to sem_post and a
single call to sem_wait"; `DistributedMutex` "does not satisfy the Lockable
concept"; `MicroLock` tells readers to prefer `std::mutex` unless space is
the constraint.

## How it works

**`DistributedMutex`** has one `std::uintptr_t state_` ([L328][dm-state]).
`lock()` builds a `Waiter` _on the caller's stack_, ORs `kLocked` (bit 0) into
its address, and does one `exchange(address, acq_rel)` on the word
([`lockImplementation` L1156–L1276][dm-lockimpl]). If the previous value was
`kUnlocked` (0) the lock is held. Otherwise the previous value is the address
of the thread that enqueued just before — the new thread's successor — so
contended threads form an intrusive **LIFO contention chain** threaded through
their stacks, and each spins on the `futex_` word in its own `Waiter`. The
returned proxy carries `next_` and `expected_`; `unlock()`
([L1550–L1612][dm-unlock]) either commits `expected → kUnlocked` with one CAS,
or, when the word changed, `exchange(kLocked)`s the whole chain off the word
and hands the lock to its head by storing `kWake` into that waiter's `futex_`.
The waker writes `WakerMetadata` (its own address and a list of sleepers it is
responsible for) into the woken waiter before signalling.

`lock_combine(task)` stores a type-erased task (48 bytes inline) in the waiter.
A lock holder walking the chain may run that task itself and report
`kCombined` (or `kExceptionOccurred`, with the exception transported back)
instead of handing over the lock — combining "up to a constant factor of 2
contention chains" (`kMaxCombineIterations = 2`).

**`ParkingLot`** is folly's user-space futex: `park(key, data, toPark, preWait)`
runs `toPark` under the bucket lock, and `unpark(key, func)` lets a lambda
decide, per waiter, whether to remove and wake it ([`ParkingLot.h` L144–L163][pl-doc]),
citing WebKit's design ([`webkit-wtf-lock`](./webkit-wtf-lock.md)).
`detail::Futex` and `atomic_wait` route to the real `futex` on Linux for
32-bit words and to the `ParkingLot` otherwise.

## Analysis

### State word and fast path

- **`DistributedMutex`:** bit 0 `kLocked`, bit 1 `kTimedWaiter`, upper bits a
  `Waiter*` ([L51–L76][dm-consts]). `tryLockNoLoad` is a single
  `atomic_fetch_set(state_, 0, acquire)` of bit 0, "slightly faster than using
  `std::atomic::exchange()`"; `try_lock` first loads to avoid pulling the line
  exclusive when the lock is visibly held ([L1121–L1150][dm-trylock]). The
  benchmark notes the uncontended case "is a few cycles faster than
  `folly::MicroLock` but a bit slower than `std::mutex`".
- **Per-waiter word:** the waiter's `futex_` (64-bit) carries a signal in its
  low 8 bits — `kUninitialized`, `kWaiting`, `kWake`, `kSkipped`,
  `kAboutToWait`, `kSleeping`, `kCombined`, `kCombineUninitialized`,
  `kCombineWaiting`, `kExceptionOccurred` ([L91–L148][dm-consts]) — and a
  56-bit TSC timestamp above them.
- **`SharedMutex`:** a 32-bit `Futex state_` with the reader count in bits
  12–31 (`kIncrHasS = 1 << 12`) and flag bits `kHasE`, `kBegunE`, `kHasU`,
  `kMayDefer`, `kPrevDefer`, plus _wait-identity_ bits `kWaitingNotS`,
  `kWaitingESingle`/`kWaitingEMultiple`, `kWaitingU`, `kWaitingS`
  ([L1097–L1192][shm-bits]). Shared acquisitions past the second concurrent
  reader (`kNumSharedToStartDeferring = 2`) set `kMayDefer` and record
  themselves in a global, per-core-striped `deferredReaders[]` array instead of
  the word: "Each SharedMutex instance is only 4 bytes, but all locks together
  share a 2K area in which they make a core-local record of lock acquisitions"
  ([L160–L182][shm-deferred]). A writer must scan those slots.
- **`MicroLock`:** "Tiny exclusive lock that uses 2 bits. It is stored as 1
  byte and has APIs for using the remaining 6 bits for storing user data"
  ([`MicroLock.h` L31–L84][microlock-doc]).
- **`Baton`:** 4 bytes, states `INIT`, `EARLY_DELIVERY`, `WAITING`,
  `LATE_DELIVERY`, `TIMED_OUT` ([`Baton.h` L301–L305][baton-states]); `post`
  is a store when nobody waits and an exchange + `futexWake` otherwise.

### Waiting: spin, yield, park

- **`DistributedMutex` spins on its own stack line** and publishes a
  timestamp each iteration ([`publish` L839–L890][dm-publish], [`spin` L892–L922][dm-spin]):
  `pause` while `elapsed < kMaxSpinTime` (40,000 TSC ticks), then
  `sleep_for(kMinYieldingSleep)`. A gap of more than
  `kScheduledAwaySpinThreshold` (200 ticks, "just a magic number from
  benchmarks") between two of its own iterations means it was descheduled.
  The **waker** reads the published timestamp: if the waiter looks preempted,
  it stores `kSkipped` and moves on along the chain
  ([`preempted` L1278–L1289][dm-preempted], [`tryWake` L1368–L1474][dm-trywake]),
  so the lock never stalls behind a thread that is not running. A skipped
  thread re-enqueues in `kAboutToWait` mode — the second of the "two phased
  sleeping" — and then sleeps on a futex in its `WakerMetadata`
  ([`doFutexWait` L961–L1011][dm-futexwait]). This is the
  [lock-holder-preemption](./concepts.md#lock-holder-preemption) answer for
  _waiters_: hand-off skips preempted successors instead of waiting on them.
- **`SharedMutex`:** spin up to `max_spin_cycles = 4000`, then up to
  `max_soft_yield_count = 1` "soft yields" (~900 ns: two `sched_yield` plus a
  `getrusage` preemption check), then `futexWait`
  ([`SharedMutexPolicyDefault` L260–L265][shm-policy], [L1194–L1203][shm-bits]).
- **`Baton::tryWaitSlow`:** `spin_pause_until` for `WaitOptions::spin_max`
  (2 µs), then `spin_yield_until`, then CAS `INIT → WAITING` and
  `MemoryIdler::futexWaitUntil` ([L309–L395][baton-slow]) — `MemoryIdler` may
  release the thread's stack and arena memory before a long sleep.
- **`MicroLock`:** `MaxSpins` + `MaxYields` template parameters, then
  `atomic_wait` — which, for an 8-bit word, means the `ParkingLot`.

### The parking substrate

- **Linux futex, with bitsets.** `nativeFutexWaitImpl` uses
  `FUTEX_WAIT_BITSET | FUTEX_PRIVATE_FLAG` (absolute timeouts) and
  `futexWake` takes a `wakeMask` ([`Futex.cpp` L48–L160][futex-cc-native]).
  `SharedMutex` uses the masks to keep several wait identities on one
  32-bit word ("We give this a separate wait identity … so that we can
  perform partial wakeups (wake one instead of wake all)", [L1154–L1158][shm-bits]).
- **Everything else is the `ParkingLot`.** On any non-Linux OS, and for any
  `atomic_wait` on a word that is not 32 bits wide, waits go to a single
  static table: "Our emulated futex uses 4096 lists of wait nodes. There are
  two levels of locking: a per-list mutex that controls access to the list
  and a per-node mutex, condvar, and bool that are used for the actual
  wakeups. The per-node mutex allows us to do precise wakeups without
  thundering herds" ([`ParkingLot.h` L76–L80][pl-bucket]). The table has 256
  buckets on mobile builds ([`ParkingLot.cpp` L24–L31][pl-cc-buckets]); keys are
  `twang_mix64(address)`; each bucket keeps an atomic `count_` so `unpark`
  can return without locking when it is zero, guarded by a matched pair of
  `seq_cst` operations ("A: Must be seq_cst. Matches B.",
  [`park_until` L250–L295, `unpark` L297–L330][pl-park]). Wait nodes live on
  the parked thread's stack.
- **No `__ulock`, `WaitOnAddress` or `_umtx_op`.** `futexWaitImpl` is
  `#ifdef __linux__` native, else emulated ([`Futex.cpp` L229–L260][futex-cc-dispatch]),
  so macOS and Windows park every Folly primitive on a
  `std::condition_variable`.
- **`DistributedMutex` parks on its own stack, too.** Non-timed waiters sleep
  on `WakerMetadata::sleeper_` in their stack `Waiter`; the waker that
  collected them later calls `doFutexWake`, which stores `kWake` and calls
  `futexWake` on that address — the comment works through why a wake on a
  possibly-dangling stack address is still safe, because "`futexWake()` does
  not actually change the memory of the futex word"
  ([L925–L958][dm-futexwake]). Timed waiters instead set `kTimedWaiter` and
  sleep on the 64-bit central word via `atomic_wait_until` — the `ParkingLot`,
  even on Linux.

### Fairness, handoff and starvation

- **`DistributedMutex` hands off directly** (`futex_.store(kWake)` passes
  ownership; the central word keeps `kLocked`), so threads already queued are
  not barged by arrivals during a chain. Chains are LIFO, but a chain is
  detached as a whole at wake-up and new arrivals start a new chain, which
  "preserves global fairness through a constant factor which is limited to the
  number of concurrent failed mutex acquisition attempts" ([L83–L101][dm-doc]).
  The LIFO order is deliberate: "the head of the chain is likely to not have
  slept on futex() after exhausting its spin quantum". Combining is capped at
  two chains "to ensure that we don't starve the combiner thread".
- **`coro::Mutex` is strict FIFO** ("This mutex guarantees a FIFO scheduling
  algorithm", [`coro/Mutex.h` L39–L41][cmutex-doc]): the unlocker reverses the
  LIFO arrival stack into a FIFO list and resumes its head.
- **`SharedMutex`** defaults to writer priority, "because writer starvation is
  more likely than reader starvation for the read-heavy workloads targeted by
  SharedMutex", with a `SharedMutexReadPriority` variant.
- **`ParkingLot`** buckets are FIFO lists; `unpark`'s callback can stop at any
  waiter.

### Condition variables and predicates

Folly has **no general condition variable** in `folly/synchronization`;
blocking-on-predicate is expressed through narrower tools:

- **`ParkingLot` is the predicate primitive.** `toPark` is evaluated under the
  bucket lock (a validate-then-sleep, like a futex compare but arbitrary), and
  `preWait` "is usually used to implement condition variable like things, such
  that you can unlock the condition variable's lock at the appropriate time"
  ([`ParkingLot.h` L183–L190][pl-doc]). `unpark`'s per-waiter callback can
  select waiters by their `Data`, implementing selective wakeups, but there is
  no requeue to a mutex queue (no [wait morphing](./concepts.md#wait-morphing)).
- **`Baton`** is a one-shot event, `SaturatingSemaphore` a multi-waiter
  latch, `EventCount` a prepare/commit/cancel wait protocol for lock-free
  structures (not analysed here).
- **`DistributedMutex` combining** is an alternative to waiting on a
  condition: instead of the waiter sleeping until it can run its critical
  section, the holder runs it. The header lists the constraint this imposes:
  the task must not depend on thread-local state or lock other mutexes.

### Footprint and layout

| Primitive          | Size                               | Where waiter state lives                                                              |
| ------------------ | ---------------------------------- | ------------------------------------------------------------------------------------- |
| `DistributedMutex` | 8 bytes (one pointer)              | `Waiter` on each contending thread's stack, padded to its own cache line(s)           |
| `SharedMutex`      | 4 bytes                            | in-word bits; deferred readers in a global striped slot array shared by all instances |
| `MicroLock`        | 1 byte (2 bits used)               | `ParkingLot` nodes on the waiter's stack                                              |
| `Baton`            | 4 bytes                            | the word itself (futex) or `ParkingLot`                                               |
| `ParkingLot` table | 4096 (mobile: 256) buckets, static | `WaitNode` (`std::mutex` + `std::condition_variable` + links) on the waiter's stack   |
| `coro::Mutex`      | two pointers                       | `LockAwaiter` in the awaiting coroutine's frame                                       |
| `fibers::Baton`    | one `intptr_t`                     | a `Waiter` subclass on the fiber's stack                                              |

The `DistributedMutex` header compares itself to "`std::mutex` and
`pthread_mutex_t` [which] are both 40 bytes", and argues small locks often
waste the difference in alignment padding. The cost of on-stack waiters is
stated as a usage restriction: no thread, fiber or coroutine migration inside
a critical section, and no segmented stacks ([L176–L199][dm-api]).

### Portability

Linux gets native `futex` for 32-bit words; every other platform, and every
other width, gets the `ParkingLot` over `std::mutex`/`std::condition_variable`
(which in turn sit on pthreads or Windows SRW/condition variables). The TSC
read in `DistributedMutex` ("faster than `std::chrono::steady_clock` because it
avoids a VDSO access") is architecture-specific; `TimePublishing` is a
template parameter so it can be disabled. All primitives are templated on an
`Atom` type so `DeterministicSchedule` can model-check them in tests.

### Async and fiber integration

Folly has the clearest split in this catalog between thread, fiber and
coroutine waiting, and one primitive that bridges two of them.

- **`coro::Mutex`** ([`coro/Mutex.h`][cmutex-h], [`Mutex.cpp` L33–L106][cmutex-impl])
  stores in one `std::atomic<void*> state_` either `this` (unlocked),
  `nullptr` (locked, no new waiters) or the head of a LIFO stack of
  `LockAwaiter`s living in the awaiting coroutines' frames. `co_lock` is a
  CAS; a contended `co_await` pushes the awaiter with a release CAS and
  suspends. `unlock` pops from a holder-private FIFO list `waiters_`
  (refilling it by exchanging the stack out of `state_` and reversing it) and
  calls `awaitingCoroutine_.resume()` **on the unlocking thread** — ownership
  is not tied to a thread. Which executor the resumed coroutine continues on
  is decided by `viaIfAsync`: "Chain a call to `.viaIfAsync()` to specify the
  executor to resume on when the lock is eventually acquired", implicit when
  awaited from a `Task`. Thread wake-up is therefore the executor's job, not
  the mutex's.
- **`coro::Baton`** uses the same `void*` state (`this` = signalled, else a
  waiter stack); `post` exchanges in the signalled state and resumes every
  waiter ([`coro/Baton.h` L29–L64][cbaton-doc]). "As a primitive, this is not
  cancellation-aware."
- **`fibers::Baton` is a word that serves both a thread and a fiber**
  ([`fibers/Baton.h` L236–L262][fbaton-word]). Its
  `std::atomic<intptr_t> waiter_` holds a sentinel (`NO_WAITER = 0`, `POSTED = -1`, `TIMEOUT = -2`,
  `THREAD_WAITING = -3`) or a pointer to a `Waiter` object, and is unioned
  with a 32-bit `Futex` over its low half. A thread waits by CASing
  `THREAD_WAITING` in and `futexWait`ing; a fiber waits by installing a
  `FiberWaiter` from the fiber manager's main context and yielding
  ([`Baton-inl.h` L50–L72][fbaton-wait]). `post` ([`Baton.cpp` L94–L130][fbaton-post])
  either `futexWake`s the thread or calls `Waiter::post()`, which for a fiber
  is `Fiber::resume` ([`Fiber.cpp` L51–L61][fiber-resume]): on the fiber's own
  loop thread it pushes onto `readyFibers_`; from any other thread it calls
  `remoteReadyInsert`, which inserts into a lock-free intrusive list and
  calls `loopController_->scheduleThreadSafe()` **only if the list was empty**
  ([`FiberManager.cpp` L143–L147][fm-remote]). That one-word, two-kinds-of-waiter
  design and the empty-to-non-empty wake deduplication are the closest prior
  art in this catalog for a Sparkles `WaitWord`.
- **Thread primitives are not fiber-aware.** `DistributedMutex` explicitly
  forbids fiber or coroutine migration within a critical section, and
  `SharedMutex`, `Baton` and `MicroLock` block the OS thread.

## Evaluation

The numbers below are Folly's own, recorded in
[`SmallLocksBenchmark.cpp`][slb-results] on an Intel Xeon E5-2680 v4 @
2.40 GHz (time per critical section, relative to `std::mutex`; higher % is
faster):

| Benchmark (16 threads)                    | Time/iter | vs `std::mutex` |
| ----------------------------------------- | --------- | --------------- |
| `std_mutex_simple`                        | 12.26 µs  | 100%            |
| `folly_microlock_simple`                  | 18.46 µs  | 66.39%          |
| `folly_sharedmutex_simple`                | 18.85 µs  | 65.00%          |
| `folly_distributedmutex_simple`           | 7.15 µs   | 171.32%         |
| `folly_flatcombining_no_caching_simple`   | 5.95 µs   | 206.11%         |
| `folly_distributedmutex_combining_simple` | 2.75 µs   | 445.11%         |
| `atomics_fetch_add`                       | 2.48 µs   | 494.82%         |

At 64 threads `DistributedMutex` runs at 161% and its combining mode at 604%
of `std::mutex`, the latter between `atomic_cas` (607%) and `atomic_fetch_xor`
(756%). These support the header's claims of "~2x faster than std::mutex"
contended and "2-3x faster than flat combining" when combining; the "4-5x
faster than the smaller locks" claim compares against `MicroLock` and
`PicoSpinLock`. The header's tail-latency claim ("up to 10x lower") is not
reproduced here.

## Strengths

- `DistributedMutex`: 8 bytes, no allocation, local spinning on a private
  cache line, direct hand-off, preemption-aware skipping, and combining that
  approaches raw atomic throughput.
- `SharedMutex`: 4 bytes with linear read scaling through shared per-core
  stripes; futex wait masks give precise, per-role wakeups.
- `ParkingLot` gives any-width `atomic_wait` and arbitrary park/unpark
  callbacks on every platform.
- `fibers::Baton` shows one word serving thread and fiber waiters, with
  deduplicated cross-thread wakeups of the fiber loop.
- `WaitOptions` centralises the spin budget with a measured justification.

## Weaknesses

- No general mutex: `DistributedMutex` is not `Lockable`, forbids migration
  inside a critical section, and needs a proxy passed to `unlock`.
- On macOS and Windows every primitive parks on a `std::condition_variable`
  through the emulated futex; native wait-on-address APIs are unused.
- `MicroLock` and timed `DistributedMutex` waits go through `ParkingLot` even
  on Linux, because their words are not 32 bits.
- `SharedMutex`'s global deferred-reader slots couple unrelated locks; a
  writer on any lock may scan slots dirtied by readers of others.
- No condition variable with wait morphing; `coro::Mutex::unlock` runs the
  next waiter inline on the unlocker's stack unless an executor is attached.
- TSC-based preemption detection is a heuristic tuned by "magic numbers from
  benchmarks".

## Key design decisions and trade-offs

| Decision                                                                | Rationale                                                                               | Trade-off                                                                        |
| ----------------------------------------------------------------------- | --------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| Waiter nodes on the contending thread's stack, linked by `exchange`     | no allocation, each waiter spins on a private line, one RMW to enqueue                  | no migration while holding; unlock needs the proxy; segmented stacks unsupported |
| LIFO contention chains, detached whole on wake                          | head is likely still spinning, avoiding syscalls; bounded unfairness                    | not FIFO; fairness bounded only by the number of concurrent failed attempts      |
| Timestamp publishing + skip preempted waiters                           | hand-off never waits for a descheduled successor                                        | TSC dependence; heuristic thresholds; skipped threads must re-enqueue            |
| Combining critical sections                                             | holder runs waiters' work; no line transfer per critical section                        | tasks must be thread-agnostic and not take other locks                           |
| Emulated futex (`ParkingLot`) for non-Linux and non-32-bit words        | one portable, any-width `atomic_wait`                                                   | `std::condition_variable` per waiter; no `WaitOnAddress`/`__ulock` fast path     |
| Futex bitsets for wait identities (`SharedMutex`)                       | readers, writers and upgraders on one word can be woken separately                      | Linux-only optimisation; emulated path must replicate masks                      |
| `fibers::Baton` word = sentinel or `Waiter*`, futex in low half         | one primitive serves threads and fibers; remote wakes deduplicated by empty-queue check | 64-bit word with a 32-bit futex view; pointer waiter must outlive the wait       |
| `coro::Mutex` resumes the next waiter inline, executor via `viaIfAsync` | no thread or loop dependency in the mutex                                               | deep resumption on the unlocker's stack when no executor is attached             |

## Sources

- Folly source at commit `643e26aee8e27c7f32e331402992af04b5080f10`
  (2026-10-11): [`folly/synchronization/DistributedMutex.h`][dm-h],
  [`DistributedMutex-inl.h`][dm-inl], [`test/SmallLocksBenchmark.cpp`][slb],
  [`folly/SharedMutex.h`][shm-h], [`folly/MicroLock.h`][microlock-h],
  [`Baton.h`][baton-h], [`WaitOptions.h`][waitopts-h],
  [`ParkingLot.h`][pl-h], [`ParkingLot.cpp`][pl-cc],
  [`folly/detail/Futex.h`][futex-h], [`folly/detail/Futex.cpp`][futex-cc],
  [`AtomicNotification.h`][an-h], [`AtomicNotification-inl.h`][an-inl],
  [`folly/coro/Mutex.h`][cmutex-h], [`folly/coro/Mutex.cpp`][cmutex-cc],
  [`folly/coro/Baton.h`][cbaton-h], [`folly/fibers/Baton.h`][fbaton-h],
  [`folly/fibers/Baton.cpp`][fbaton-cc], [`folly/fibers/Baton-inl.h`][fbaton-inl],
  [`folly/fibers/Fiber.cpp`][fiber-cc], [`folly/fibers/FiberManager.cpp`][fm-cc].
- Hendler, Incze, Shavit, Tzafrir, "Flat Combining and the
  Synchronization-Parallelism Tradeoff", SPAA 2010 — cited by
  `DistributedMutex.h` as the inspiration for `lock_combine`.
- WG21 P1135R0 (`atomic_wait`), cited by `AtomicNotification.h`.
- Siblings: [`webkit-wtf-lock`](./webkit-wtf-lock.md) (the `ParkingLot`
  model), [`queue-locks`](./queue-locks.md) (MCS and combining),
  [`abseil-mutex`](./abseil-mutex.md), [`linux-futex`](./linux-futex.md).

> [!NOTE]
> The benchmark figures are copied from the comment block in
> `SmallLocksBenchmark.cpp`; they were not re-run. `EventCount`,
> `SaturatingSemaphore`, `LifoSem` and `Hazptr`/`Rcu` exist in the same
> directory but are outside this page's scope.

<!-- References -->

[folly-repo]: https://github.com/facebook/folly/tree/643e26aee8e27c7f32e331402992af04b5080f10
[dm-h]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/synchronization/DistributedMutex.h
[dm-doc]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/synchronization/DistributedMutex.h#L31-L143
[dm-api]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/synchronization/DistributedMutex.h#L156-L199
[dm-state]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/synchronization/DistributedMutex.h#L328
[dm-inl]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/synchronization/DistributedMutex-inl.h
[dm-consts]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/synchronization/DistributedMutex-inl.h#L51-L165
[dm-publish]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/synchronization/DistributedMutex-inl.h#L839-L890
[dm-spin]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/synchronization/DistributedMutex-inl.h#L891-L922
[dm-futexwake]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/synchronization/DistributedMutex-inl.h#L924-L958
[dm-futexwait]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/synchronization/DistributedMutex-inl.h#L960-L1019
[dm-trylock]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/synchronization/DistributedMutex-inl.h#L1120-L1152
[dm-lockimpl]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/synchronization/DistributedMutex-inl.h#L1154-L1276
[dm-preempted]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/synchronization/DistributedMutex-inl.h#L1278-L1289
[dm-trywake]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/synchronization/DistributedMutex-inl.h#L1366-L1474
[dm-unlock]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/synchronization/DistributedMutex-inl.h#L1520-L1612
[slb]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/synchronization/test/SmallLocksBenchmark.cpp
[slb-results]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/synchronization/test/SmallLocksBenchmark.cpp#L1040-L1120
[shm-h]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/SharedMutex.h
[shm-doc]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/SharedMutex.h#L45-L75
[shm-deferred]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/SharedMutex.h#L148-L182
[shm-policy]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/SharedMutex.h#L260-L265
[shm-bits]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/SharedMutex.h#L1084-L1203
[microlock-h]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/MicroLock.h
[microlock-doc]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/MicroLock.h#L30-L84
[baton-h]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/synchronization/Baton.h
[baton-states]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/synchronization/Baton.h#L299-L306
[baton-slow]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/synchronization/Baton.h#L309-L400
[waitopts-h]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/synchronization/WaitOptions.h
[waitopts]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/synchronization/WaitOptions.h#L33-L56
[pl-h]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/synchronization/ParkingLot.h
[pl-bucket]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/synchronization/ParkingLot.h#L76-L86
[pl-doc]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/synchronization/ParkingLot.h#L143-L192
[pl-park]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/synchronization/ParkingLot.h#L250-L330
[pl-cc]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/synchronization/ParkingLot.cpp
[pl-cc-buckets]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/synchronization/ParkingLot.cpp#L24-L31
[futex-h]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/detail/Futex.h
[futex-cc]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/detail/Futex.cpp
[futex-cc-native]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/detail/Futex.cpp#L48-L160
[futex-cc-dispatch]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/detail/Futex.cpp#L229-L260
[an-h]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/synchronization/AtomicNotification.h
[an-inl]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/synchronization/AtomicNotification-inl.h
[cmutex-h]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/coro/Mutex.h
[cmutex-doc]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/coro/Mutex.h#L32-L48
[cmutex-cc]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/coro/Mutex.cpp
[cmutex-impl]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/coro/Mutex.cpp#L33-L106
[cbaton-h]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/coro/Baton.h
[cbaton-doc]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/coro/Baton.h#L29-L64
[fbaton-h]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/fibers/Baton.h
[fbaton-word]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/fibers/Baton.h#L236-L262
[fbaton-cc]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/fibers/Baton.cpp
[fbaton-post]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/fibers/Baton.cpp#L94-L130
[fbaton-inl]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/fibers/Baton-inl.h
[fbaton-wait]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/fibers/Baton-inl.h#L50-L72
[fiber-cc]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/fibers/Fiber.cpp
[fiber-resume]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/fibers/Fiber.cpp#L51-L61
[fm-cc]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/fibers/FiberManager.cpp
[fm-remote]: https://github.com/facebook/folly/blob/643e26aee8e27c7f32e331402992af04b5080f10/folly/fibers/FiberManager.cpp#L143-L147
