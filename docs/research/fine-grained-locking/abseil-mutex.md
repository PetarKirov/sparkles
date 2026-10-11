# Abseil `absl::Mutex` (C++)

Google's production mutex: one pointer-sized word that is simultaneously a
reader/writer lock, a waiter-queue head, and a spinlock over that queue, with
waiters stored intrusively in per-thread records — plus predicate waits
(`Condition`, `Await`, `LockWhen`) evaluated by the _unlocker_, and a
`CondVar` that morphs its waiters onto the mutex queue.

|                        |                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**               | library (`absl/synchronization`)                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| **Language**           | C++17                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| **License**            | Apache-2.0                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| **Repository**         | [`abseil/abseil-cpp`][absl-repo] at `30bc83809d16` (2026-10-10)                                                                                                                                                                                                                                                                                                                                                                                                         |
| **Primitives covered** | `Mutex` (exclusive + shared), `Condition`, `Mutex::Await` / `LockWhen` / `*WithTimeout` / `*WithDeadline`, `CondVar`, deadlock detection, `PerThreadSem` and its waiter backends                                                                                                                                                                                                                                                                                        |
| **Parking substrate**  | a per-thread counting semaphore (`PerThreadSem`) inside the thread's `ThreadIdentity`; waiters form an intrusive circular list headed from the mutex word                                                                                                                                                                                                                                                                                                               |
| **Fairness**           | "approximately fair over long periods, and starvation-free for threads at the same priority"; priority-ordered queue; woken waiters re-compete                                                                                                                                                                                                                                                                                                                          |
| **Source read**        | [`mutex.h`][mutex-h], [`mutex.cc`][mutex-cc], [`internal/per_thread_sem.h`][pts-h], [`internal/per_thread_sem.cc`][pts-cc], [`internal/waiter.h`][waiter-h], [`internal/waiter_base.h`][waiter-base-h], [`internal/futex_waiter.cc`][futex-waiter-cc], [`internal/futex.h`][futex-h], [`internal/win32_waiter.h`][win32-waiter-h], [`base/internal/thread_identity.h`][thread-identity-h], [`base/internal/low_level_scheduling.h`][lls-h], [`base/config.h`][config-h] |

## Overview

### What it solves

`absl::Mutex` replaces `std::mutex` + `std::condition_variable` with one type
that is a reader/writer lock and owns its own predicate waits. The header
lists what it adds ([`mutex.h` L24–L28][mutex-h-features]):

> Unlike a `std::mutex`, the Abseil `Mutex` provides the following additional
> features:
>
> - Conditional predicates intrinsic to the `Mutex` object
> - Shared/reader locks, in addition to standard exclusive/writer locks
> - Deadlock detection and debug support.

### Design philosophy

Predicates over signals. `Condition` is marked "(Preferred)" over `CondVar`
([L45–L50][mutex-h-features]), because a predicate registered with the mutex
cannot miss a wakeup: whoever releases the mutex re-evaluates it. Conditions
must therefore be pure functions of mutex-protected state
([L340–L354][mutex-h-cond-rules]):

> The condition will always be invoked with the mutex held in at least read
> mode, so you should not block it for long periods or sleep it on a timer.
>
> Since a condition must not depend directly on the current time, use
> `*WithTimeout()` member function variants to make your condition
> effectively true after a given duration […]

Fairness is deliberately approximate ([L145–L147][mutex-h-fair]): "`Mutex` is
not guaranteed to be "fair" in prioritizing waiting threads; it is, however,
approximately fair over long periods, and starvation-free for threads at the
same priority."

## How it works

The whole state is `std::atomic<intptr_t> mu_` ([L545][mutex-h-mu]). The low
byte holds flags; the high bits hold either a reader count or a pointer to the
**last** waiter of a circular queue of `PerThreadSynch` records — which is why
every `PerThreadSynch` is 256-byte aligned (`kLowZeroBits = 8`,
[`thread_identity.h` L51–L58][pts-align]). The layout comment
([`mutex.cc` L630–L689][mu-bits]):

| Bit     | Name        | Meaning                                                                      |
| ------- | ----------- | ---------------------------------------------------------------------------- |
| `0x01`  | `kMuReader` | a reader holds the lock                                                      |
| `0x02`  | `kMuDesig`  | a designated waker exists (a woken thread that has not yet acquired)         |
| `0x04`  | `kMuWait`   | threads are waiting; high bits are the queue head                            |
| `0x08`  | `kMuWriter` | a writer holds the lock                                                      |
| `0x10`  | `kMuEvent`  | events are recorded for this mutex (logging, invariants)                     |
| `0x20`  | `kMuWrWait` | a runnable writer waits for readers; new readers must queue                  |
| `0x40`  | `kMuSpin`   | spinlock protecting the waiter list                                          |
| `0x80`  | —           | unused                                                                       |
| `~0xff` | `kMuHigh`   | reader count (in units of `kMuOne = 0x100`) when no waiters, else queue head |

The values are chosen so the debug allocator's fill patterns `0xab` and `0xcd`
both decode as "reader and writer both hold the lock" — an invalid state that
`CheckForMutexCorruption` catches. When waiters exist, the reader count moves
out of the word into `PerThreadSynch::readers` of the queue head.

Acquisition is table-driven: `MuHowS` records, per mode, which bits must be
zero for a fast acquire and what to OR and ADD ([L699–L735][muhow]); for
shared mode that is "add `kMuOne`, OR `kMuReader`, unless writer/wait/event".

The slow path `LockSlowLoop` ([L2004–L2122][lockslowloop]) either CASes the
lock bits in (if `slow_need_zero` bits are clear), or takes `kMuSpin`, calls
`Enqueue` to splice the thread's `PerThreadSynch` into the circular list,
releases `kMuSpin` with the new head pointer, and calls `Block`. `Block`
([L1186–L1212][block]) loops `while (s->state == kQueued)` on
`DecrementSynchSem` — the thread's own semaphore. A waker removes the record
from the list, stores `kAvailable` with release order, and posts the
semaphore (`Wakeup`, [L1215–L1222][wakeup]).

## Analysis

### State word and fast path

- **Exclusive lock** ([`lock()` L1539–L1555][lock]): relaxed load; if none
  of `kMuWriter | kMuReader | kMuEvent` is set,
  `compare_exchange_strong(v, kMuWriter | v, acquire, relaxed)`. Note that the
  fast path succeeds even with `kMuWait` set: a running thread barges past
  queued waiters.
- **Shared lock** ([`lock_shared()` L1557–L1577][lock-shared]): CAS
  `(kMuReader | v) + kMuOne` unless `kMuWriter | kMuWait | kMuEvent` — readers
  do _not_ barge past waiters.
- **Exclusive unlock** ([`unlock()` L1717–L1775][unlock]) has one CAS
  (`v & ~(kMuWrWait | kMuWriter)`, release) when the word shows a writer, no
  event, and either no waiters or a designated waker. The condition is
  computed with an XOR-and-compare that the source explains bit by bit
  ("should_try_cas is true iff the bits satisfy the following conditions …"),
  and the bit ordering constraints are `static_assert`ed. Everything else
  takes `UnlockSlow`.
- **`kMuDesig` throttles wakeups**: once a waiter is woken, unlockers take the
  fast path until that thread acquires or re-blocks (INVARIANT1,
  [L639–L647][mu-bits]) — the same role as Go's `mutexWoken` (see
  [`go-sync`](./go-sync.md#state-word-and-fast-path)).

### Waiting: spin, yield, park

Two distinct loops:

1. **Pre-park spin on the lock.** `TryAcquireWithSpinning`
   ([L1523–L1537][spin]) retries the CAS up to `spinloop_iterations` times —
   1500 on a multiprocessor, set lazily on the first contended `LockSlow`
   so that "`Lock` function does not have any non-tail calls and consequently
   a stack frame" ([L1838–L1860][lockslow]). It gives up at once if a
   _reader_ holds the lock or events are enabled. There is no `pause`
   instruction and no backoff — plain relaxed loads in a `do/while` ("somewhat
   faster on AMD").
2. **Spinlock contention (`kMuSpin`, `kCvSpin`).** `MutexDelay(c, mode)`
   ([L136–L210][mutexdelay]) spins `mutex_sleep_spins[mode]` iterations
   (`AGGRESSIVE = 5000`, `GENTLE = 250` on SMP), yields once, then sleeps
   `mutex_sleep_time = 10 µs` and starts over. `UnlockSlow` uses
   `AGGRESSIVE` because "no one can proceed till we do"; waiters use `GENTLE`.
   On a uniprocessor both are zero and the sleep is calibrated to
   5 × measured `yield` time, clamped to [10 µs, 1 ms].

After the spin, the thread enqueues and parks on its `PerThreadSem`
unconditionally — there is no adaptive spin estimate.

### The parking substrate

- **Waiter records are per-thread, intrusive, and never freed.**
  `PerThreadSynch` is the first member of `ThreadIdentity`, "allocated in
  `NewThreadIdentity()` with an alignment of `PerThreadSynch::kAlignment` and
  never destroyed" and reused by later threads ([L134–L139][thread-identity]).
  It carries `next` (circular queue), `skip` (equivalence-class skip list),
  `wake`, `cond_waiter`, `priority`, `state` (`kAvailable`/`kQueued`), `waitp`
  (the current `SynchWaitParams`, on the waiter's stack), and `readers`.
- **There is no global wait table.** The queue head lives in the mutex word
  itself, which is why the word must hold an aligned pointer. Contrast the
  hashed tables of [`go-sync`](./go-sync.md#the-parking-substrate) and
  [`parking-lot`](./parking-lot.md).
- **Skip chains.** Waiters with the same condition, lock mode and priority form
  runs; `skip` lets an unlocker evaluate one condition per run, not per thread
  ([L825–L879][skip]). The header asks callers to construct identical
  `Condition`s identically "so that the mutex implementation can avoid
  redundantly evaluating the same condition for each thread"
  ([L795–L798][cond-class]).
- **`PerThreadSem`** is "a low-level synchronization primitive controlling the
  runnability of a single thread" with counting-semaphore semantics
  ([`per_thread_sem.h` L16–L23][pts-h-head]). It delegates to a compile-time
  `Waiter` ([`waiter.h`][waiter-h]); storage for it is a 256-byte
  `waiter_state` blob inside `ThreadIdentity`. The futex waiter
  ([`futex_waiter.cc` L55–L100][futex-waiter-wait]) is a counter: `Post` is
  `fetch_add(1, release)` and `FUTEX_WAKE` one only on a 0→1 transition;
  `Wait` CAS-decrements a positive count, otherwise `FUTEX_WAIT` on 0.

### Fairness, handoff and starvation

- **No hand-off.** `UnlockSlow` releases the lock and sets `kMuDesig` in the
  same store that wakes the chosen waiters ([L2328–L2365][unlockslow-wake]);
  the woken thread re-runs `LockSlowLoop` and competes with arrivals.
- **Queue order is priority-FIFO.** `Enqueue` reads the thread's
  `pthread_getschedparam` priority at most once a second ("5% of the
  block/wakeup time") and inserts above lower-priority waiters
  ([L932–L1067][enqueue]); equal priorities are FIFO.
- **Writer preference against reader floods.** Waking a writer sets
  `kMuWrWait`, which blocks new readers: "We want the writer to usually win
  this race, because if it doesn't, we can potentially keep taking a reader
  perpetually and writers will starve" ([L2251–L2265][unlockslow-wake]). A
  reader that already blocked once ignores `kMuWrWait`
  (`IgnoreWaitingWritersMask`), bounding reader starvation in turn.
- **Readers are woken in batches.** When the first wakeable waiter is a
  reader, the unlocker walks the queue and wakes every reader whose condition
  holds, stopping at a writer.

### Condition variables and predicates

**`Condition` / `Await` / `LockWhen`.** `Await(cond)` returns at once if
`cond` holds; otherwise it calls `UnlockSlow(&waitp)` with the condition in
`waitp`, which enqueues the thread _and_ releases the lock atomically under
`kMuSpin`, then `Block`s ([`AwaitCommon` L1591–L1615][await]). `LockWhen` is
`LockSlowWithDeadline` with a condition: acquire, evaluate, and if false
unlock-and-enqueue. The key mechanism is in `UnlockSlow`
([L2310–L2365][unlockslow-wake]): the releasing thread drops `kMuSpin` but
keeps the lock bit, then walks the queue evaluating each waiter's condition
with `EvalConditionIgnored` — **the unlocker evaluates the waiters'
predicates** and wakes only threads whose predicate is true. A woken thread
re-evaluates after reacquiring. Timeouts and deadlines are expressed as
`KernelTimeout`, and a timed-out waiter spins on `TryRemove` until it is off
the queue, because "the holder has the right to read the centre of the waiter
queue without holding the spinlock" ([L1186–L1212][block]).

**`CondVar`.** One `std::atomic<intptr_t> cv_` holding a circular waiter list
pointer plus `kCvSpin` and `kCvEvent` ([L2533–L2548][cv-bits]). Its
`WaitCommon` ([L2638–L2704][cv-wait]) passes `&cv_` in `waitp.cv_word`, and
`UnlockSlow` calls `CondVarEnqueue` "just before releasing the `Mutex`" — the
comment explains this ordering protects against re-entry from a `Condition`
or logging callback that might block the thread while it is already on a
condvar queue ([L2589–L2603][cv-enqueue]).

**Wait morphing.** `Signal` ([L2706–L2743][cv-signal]) pops one waiter and
calls `w->waitp->cvmu->Fer(w)`; `SignalAll` CASes the whole list out in one
step and `Fer`s each. `Fer` ([L2453–L2515][fer]) checks the mutex: if the
waiter could acquire it now, wake the thread; otherwise **enqueue it directly
on the mutex's waiter queue without waking it**, so the eventual unlocker
wakes it. The header draws the user-facing conclusion
([L1016–L1018][cv-doc]): "With this implementation it is efficient to use
`Signal()/SignalAll()` inside the locked region." Because a morphed thread
believes it was woken from the condvar, it re-enters the mutex slow path via
`Trans` with `kMuHasBlocked`, so it clears `kMuDesig` as a woken mutex waiter
would (INV1b). `CondVar::Wait` documents spurious wakeups as permitted.

**Deadlock detection.** In debug builds (`!NDEBUG`), unless TSan is active,
every `lock` checks a global lock-order graph (`GraphCycles` under the
`deadlock_graph_mu` spinlock) built from each thread's `SynchLocksHeld`, and
aborts on a cycle by default (`kDeadlockDetectionDefault = kAbort`,
[L47–L54][deadlock-default], [L1389–L1488][deadlock-check]). Per-mutex names,
logging and invariant checks live in a 1031-bucket `SynchEvent` hash table
keyed by address, flagged by `kMuEvent`.

### Footprint and layout

- `absl::Mutex`: **one `intptr_t` (8 bytes on LP64)**, `constexpr`
  constructible with `absl::kConstInit` for globals ([L184][mutex-h-ctor]).
  `CondVar`: one `intptr_t`.
- Per thread: a `ThreadIdentity` (≥ 256-byte-aligned, with 256 bytes of
  waiter storage and cache-line padding separating `scheduler_state` from
  waiter state), allocated on first contended use and recycled.
- Nothing is allocated per lock or per wait; `SynchWaitParams` live on the
  waiting thread's stack.
- Cost of the design: every lock operation reads a word that may be a pointer,
  so the pointer alignment, the spinlock bit and the reader count share one
  cache line with the lock bit.

### Portability

The `Waiter` is chosen at compile time ([`waiter.h` L25–L44][waiter-h]), in
this order:

| Mode                       | Platform                                            | Primitive                                                                        |
| -------------------------- | --------------------------------------------------- | -------------------------------------------------------------------------------- |
| `ABSL_WAITER_MODE_WIN32`   | Windows Vista+ (not MinGW)                          | `SRWLOCK` + `CONDITION_VARIABLE` per thread ([`win32_waiter.h`][win32-waiter-h]) |
| `ABSL_WAITER_MODE_FUTEX`   | Linux (≥ 2.6.28 for `FUTEX_CLOCK_REALTIME`), Bionic | `FUTEX_WAIT_BITSET` / `FUTEX_WAKE`, private ([`futex.h`][futex-h])               |
| `ABSL_WAITER_MODE_SEM`     | `<semaphore.h>` platforms (Linux, VxWorks)          | POSIX `sem_t`                                                                    |
| `ABSL_WAITER_MODE_CONDVAR` | other POSIX — **including macOS/iOS**               | `pthread_mutex_t` + `pthread_cond_t`                                             |
| `ABSL_WAITER_MODE_STDCPP`  | fallback                                            | `std::mutex` + `std::condition_variable`                                         |

`ABSL_FORCE_WAITER_MODE` overrides the choice. Apple gets the pthread waiter
because its `<semaphore.h>` "is explicitly deprecated and will cause build
failures" ([`config.h` L383–L396][config-sem]); no `__ulock` or
`os_sync_wait_on_address` path exists. Windows uses SRW locks rather than
`WaitOnAddress`. Timeouts go through `KernelTimeout`, which prefers a relative
`CLOCK_MONOTONIC` wait where the kernel supports it.

### Async and fiber integration

Abseil's open-source build has no coroutine-aware lock, but the design has
seams for a user-mode scheduler, and they are instructive:

- **Weak-symbol parking hooks.** `PerThreadSem`'s operations call
  `extern "C"` `AbslInternalPerThreadSemInit`/`Post`/`Wait`/`Poke`, defined
  `ABSL_ATTRIBUTE_WEAK` ([`per_thread_sem.h` L98–L113][pts-hooks],
  [`per_thread_sem.cc`][pts-cc]); `AbslInternalMutexYield` is weak too. A
  runtime can link its own versions to park a fiber instead of a thread.
- **Reserved scheduler state.** `ThreadIdentity::scheduler_state` is
  "Private: Reserved for use in Gloop" (Google's internal cooperative
  scheduler); `UnlockSlow` sets `waking_designated_waker` there to tell the
  scheduler the woken thread "should get an elevated priority"
  ([`thread_identity.h` L151–L169][scheduler-state]).
- **`SchedulingGuard`** marks regions where the thread must not be
  cooperatively rescheduled — `LockSlowLoop`, `UnlockSlow`, `Fer`,
  `CondVar::Signal` and `CondVar::Remove` each open a `ScopedDisable` ([`low_level_scheduling.h`][lls-h]):
  "It is an error to attempt to use a cooperatively scheduled resource (e.g.
  Mutex) within a rescheduling-disabled region."
- **Thread-blocked counters** (`SetThreadBlockedCounter`) are "used by
  autosizing threadpools to detect when threads are blocked"
  ([`per_thread_sem.h` L57–L68][pts-h]).

The waiter identity is the _thread_ (`ThreadIdentity`), so integration means
substituting the identity's sleep/wake, not registering an asynchronous
continuation. A fiber that awaits an `absl::Mutex` without such a runtime
blocks its OS thread.

## Strengths

- One word encodes lock, reader count, waiter queue and its spinlock; 8 bytes,
  `constexpr`-initialisable, no allocation per lock.
- Predicate waits evaluated by the releaser eliminate the lost-signal class of
  bugs and avoid waking threads whose condition is still false.
- Wait morphing: `Signal` under the lock costs no extra context switch.
- Skip chains make many waiters on one condition cheap to scan.
- Built-in deadlock detection, invariant checking, contention profiling and
  TSan annotations.
- Pluggable parking (weak hooks) without changing the lock word.

## Weaknesses

- Complexity: `mutex.cc` is ~2,800 lines with hand-proven invariants
  (`INV1a`/`INV1b`, skip-chain rules) and fatal "illegal recursion" checks.
- The queue lives behind a bit spinlock in the lock word; under heavy
  contention enqueuers spin (`MutexDelay`) and finally `SleepFor(10 µs)`.
- Conditions run on the unlocker's thread while it still holds the lock,
  lengthening critical sections; they must be pure and fast.
- No hand-off: woken waiters re-compete, fairness is "approximate".
- Requires 256-byte-aligned, immortal per-thread records — fine in a runtime
  that owns thread identity, awkward for a library that wants zero TLS
  footprint.
- On macOS the waiter is a pthread condvar, not a native wait-on-address.

## Key design decisions and trade-offs

| Decision                                                   | Rationale                                                                          | Trade-off                                                                     |
| ---------------------------------------------------------- | ---------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| Waiter queue head stored as a pointer in the lock word     | no global table, no per-lock allocation; queue reachable from the lock             | pointer needs 256-byte alignment; queue edits need a spinlock bit in the word |
| Per-thread immortal `PerThreadSynch` + `PerThreadSem`      | waiter record never allocated on the wait path; one sleep primitive per thread     | ties waiting to OS-thread identity; memory per thread is never returned       |
| Unlocker evaluates waiter `Condition`s                     | wakes only threads that can make progress; no lost wakeups                         | predicates run inside someone else's critical section                         |
| `CondVar::Signal` moves waiters to the mutex queue (`Fer`) | signalling under the lock costs no extra wakeup                                    | condvar and mutex code are coupled; `Trans` must fake mutex-waiter state      |
| `kMuDesig` designated waker                                | at most one woken-but-not-acquired thread; unlock stays on the fast path meanwhile | woken thread still barges; no strict FIFO                                     |
| `kMuWrWait` + reader re-entry exemption                    | writers are not starved by reader streams, readers not by writers                  | readers queue behind a waiting writer even when the lock is read-held         |
| Fixed spin (1500 CAS attempts), no `pause`, no adaptation  | cheap, branch-light fast path; spin count initialised lazily off the fast path     | not tuned per lock or per machine; burns CPU under long holds                 |
| Compile-time `Waiter` backend with weak overrides          | portable to every target; replaceable by a fiber scheduler                         | backend not chosen per lock; no native `WaitOnAddress`/`__ulock` use          |

## Sources

- Abseil source at commit `30bc83809d1653901f0a586600aedb8ff830d3df`
  (2026-10-10): [`absl/synchronization/mutex.h`][mutex-h],
  [`absl/synchronization/mutex.cc`][mutex-cc],
  [`internal/per_thread_sem.h`][pts-h], [`internal/per_thread_sem.cc`][pts-cc],
  [`internal/waiter.h`][waiter-h], [`internal/waiter_base.h`][waiter-base-h],
  [`internal/futex_waiter.cc`][futex-waiter-cc], [`internal/futex.h`][futex-h],
  [`internal/win32_waiter.h`][win32-waiter-h],
  [`absl/base/internal/thread_identity.h`][thread-identity-h],
  [`absl/base/internal/low_level_scheduling.h`][lls-h],
  [`absl/base/config.h`][config-h].
- Siblings: [`nsync`](./nsync.md) (another predicate-wait mutex with
  per-thread waiter records), [`go-sync`](./go-sync.md), [`folly-sync`](./folly-sync.md),
  [`windows-srwlock`](./windows-srwlock.md),
  [`linux-futex`](./linux-futex.md).

> [!NOTE]
> The Abseil guide referenced by the header ("Please consult the Mutex guide")
> was not read; every claim above is from the source tree. "Gloop" is named
> only in a comment; its implementation is not open source, so how it
> overrides the weak hooks is not documented here.

<!-- References -->

[absl-repo]: https://github.com/abseil/abseil-cpp/tree/30bc83809d1653901f0a586600aedb8ff830d3df
[mutex-h]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/mutex.h
[mutex-h-features]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/mutex.h#L24-L52
[mutex-h-fair]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/mutex.h#L145-L147
[mutex-h-ctor]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/mutex.h#L174-L184
[mutex-h-cond-rules]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/mutex.h#L338-L366
[mutex-h-mu]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/mutex.h#L545
[cond-class]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/mutex.h#L756-L799
[cv-doc]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/mutex.h#L1000-L1095
[mutex-cc]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/mutex.cc
[deadlock-default]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/mutex.cc#L47-L54
[mutexdelay]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/mutex.cc#L134-L210
[mu-bits]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/mutex.cc#L628-L697
[muhow]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/mutex.cc#L698-L735
[skip]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/mutex.cc#L809-L898
[enqueue]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/mutex.cc#L913-L1067
[block]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/mutex.cc#L1186-L1212
[wakeup]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/mutex.cc#L1214-L1222
[deadlock-check]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/mutex.cc#L1389-L1488
[spin]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/mutex.cc#L1521-L1537
[lock]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/mutex.cc#L1539-L1555
[lock-shared]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/mutex.cc#L1557-L1577
[await]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/mutex.cc#L1579-L1615
[unlock]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/mutex.cc#L1717-L1775
[lockslow]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/mutex.cc#L1837-L1860
[lockslowloop]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/mutex.cc#L2004-L2122
[unlockslow-wake]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/mutex.cc#L2130-L2420
[fer]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/mutex.cc#L2443-L2515
[cv-bits]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/mutex.cc#L2533-L2548
[cv-enqueue]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/mutex.cc#L2591-L2636
[cv-wait]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/mutex.cc#L2638-L2704
[cv-signal]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/mutex.cc#L2706-L2784
[pts-h]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/internal/per_thread_sem.h
[pts-h-head]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/internal/per_thread_sem.h#L16-L23
[pts-hooks]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/internal/per_thread_sem.h#L98-L113
[pts-cc]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/internal/per_thread_sem.cc
[waiter-h]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/internal/waiter.h#L25-L64
[waiter-base-h]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/internal/waiter_base.h
[futex-waiter-cc]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/internal/futex_waiter.cc
[futex-waiter-wait]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/internal/futex_waiter.cc#L55-L100
[futex-h]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/internal/futex.h
[win32-waiter-h]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/synchronization/internal/win32_waiter.h
[thread-identity-h]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/base/internal/thread_identity.h
[pts-align]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/base/internal/thread_identity.h#L51-L58
[thread-identity]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/base/internal/thread_identity.h#L134-L149
[scheduler-state]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/base/internal/thread_identity.h#L151-L169
[lls-h]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/base/internal/low_level_scheduling.h
[config-h]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/base/config.h
[config-sem]: https://github.com/abseil/abseil-cpp/blob/30bc83809d1653901f0a586600aedb8ff830d3df/absl/base/config.h#L383-L396
