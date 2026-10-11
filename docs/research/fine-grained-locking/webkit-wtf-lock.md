# WebKit `WTF::Lock` and `WTF::ParkingLot` (C++)

The origin of the parking-lot design: a 1-byte adaptive lock and a 1-byte
condition variable whose queues live in a single process-wide, address-keyed
hashtable of thread queues — "a portable user-level implementation of the core
futex API" — introduced in WebKit in August 2015 and described by Filip Pizlo
in "Locking in WebKit" (2016-05-06).

|                       |                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**              | library (WebKit's Web Template Framework, `Source/WTF/wtf`)                                                                                                                                                                                                                                                                                                                                                                                                       |
| **Language**          | C++                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| **License**           | BSD-2-Clause (Apple copyright headers on every file read)                                                                                                                                                                                                                                                                                                                                                                                                         |
| **Repository**        | [`WebKit/WebKit`][wk-repo], `Source/WTF/wtf/` (sparse checkout)                                                                                                                                                                                                                                                                                                                                                                                                   |
| **Year**              | 2015-08 (replacement of all spinlocks and OS mutexes in WebKit); blog post 2016-05-06                                                                                                                                                                                                                                                                                                                                                                             |
| **Lock word**         | `Lock`: `Atomic<uint8_t>`, `isHeldBit = 1`, `hasParkedBit = 2`; `Condition`: `Atomic<bool> m_hasWaiters`; `WordLock`: `Atomic<uintptr_t>` holding two bits + queue-head pointer                                                                                                                                                                                                                                                                                   |
| **Parking substrate** | process-wide hashtable of lazily allocated `Bucket`s (each a `WordLock` + FIFO of refcounted `ThreadData` + a fairness deadline + 64 bytes of padding); each thread sleeps on its own `Mutex` + `ThreadCondition` (pthread or `SRWLOCK`/`CONDITION_VARIABLE`)                                                                                                                                                                                                     |
| **Source read**       | [`Lock.h`][lock-h], [`Lock.cpp`][lock-cpp], [`LockAlgorithm.h`][algo-h], [`LockAlgorithmInlines.h`][algo-inl], [`ParkingLot.h`][pl-h], [`ParkingLot.cpp`][pl-cpp], [`Condition.h`][cond-h], [`WordLock.h`][wl-h], [`WordLock.cpp`][wl-cpp], [`SpinBackoff.h`][spin-h], [`CountingLock.h`][counting-h], [`ThreadingPrimitives.h`][tprim-h], [`WeakRandom.h`][weakrandom-h], [`posix/ThreadingPOSIX.cpp`][threading-posix]; the blog post [Locking in WebKit][blog] |

## Overview

### What it solves

The blog opens with the change and its claims ([Locking in WebKit][blog]):

> Back in August 2015 we replaced all spinlocks and OS-provided mutexes in
> WebKit with the new WTF::Lock (WTF stands for Web Template Framework). We
> also replaced all OS-provided condition variables with WTF::Condition.

> Compared to OS-provided locks like pthread_mutex, WTF::Lock is 64 times
> smaller and up to 180 times faster. Compared to OS-provided condition
> variables like pthread_cond, WTF::Condition is 64 times smaller. Using
> WTF::Lock instead of pthread_mutex means that WebKit is 10% faster on
> JetStream, 5% faster on Speedometer, and 5% faster on our page loading test.

The motivating constraint is lock **count**: WebKit "usually runs a small
number of threads (about ten on my system) but can easily allocate millions of
locks (in the worst case, one per JavaScript object)", so "locks don't have to
pay the price for space for a queue." Before `WTF::Lock` the engine picked
between spinlocks and OS mutexes per site and got it wrong both ways: "we had a
spinlock in CodeBlock that should have been adaptive because it protected long
critical sections, and we had an OS mutex in our parallel GC that accounted for
3% of our time in the Octane Splay benchmark."

### Design philosophy

**Separate atomic state from the queue.** "The lock object contains only the
atomic state, while the queue is created on-demand inside the ParkingLot. This
allows our locks to only require two bits." The ParkingLot is the futex idea in
user space: "Like with futexes, we materialize most of the data for a lock only
when that lock experiences contention, and we locate that data by hashing the
address of the lock. Unlike futexes, our implementation does not rely on kernel
support and so it will work on any OS. The ParkingLot API has some
functionality that futexes lack, like invoking callbacks while holding internal
ParkingLot locks."

**[Barging][c-barging] beats FIFO for tiny critical sections.** "FIFO locks force
contenders to form a convoy where they only get to hold the lock once per
turn. This makes the program run much slower than with a barging lock because
of the huge number of context switches – one per lock acquisition!" Fairness is
bounded stochastically, not enforced ([`Lock.h`][lock-h-doc]):

> This lock guarantees eventual stochastic fairness, even in programs that
> relock the lock immediately after unlocking it. Except when there are
> collisions between this lock and other locks in the ParkingLot, this lock
> will guarantee that at worst one call to unlock() per millisecond will do a
> direct hand-off to the thread that is at the head of the queue.

**Memory is O(threads), never O(locks).** "the size of ParkingLot is bounded
by the number of threads … the number of locks and even the rate at which you
contend on them has no impact on the hard O(threads) space bound."

## How it works

Four layers:

1. **`LockAlgorithm<LockType, isHeldBit, hasParkedBit, Hooks>`**
   ([`LockAlgorithm.h`][algo-h]) — the lock "projected onto any atomic field.
   The limit of one lock is due to the use of the field's address as a key to
   find the lock's queue." `Hooks` (`lockHook`, `unlockHook`, `parkHook`,
   `handoffHook`) let a client keep other bits in the same word:
   `CountingLock` keeps a counter above the two bits for optimistic reads
   ("largely inspired by StampedLock from Java", [`CountingLock.h`][counting-h]),
   and per `LockAlgorithmInlines.h` the slow path is also instantiated from
   `JSCell.cpp`, where JavaScriptCore keeps a per-object lock in a cell's
   header byte.
2. **`Lock`** ([`Lock.h`][lock-h]) — `LockAlgorithm<uint8_t, 1, 2>` in one
   byte, with `lock`, `tryLock`, `unlock`, `unlockFairly`, `safepoint`
   (`unlockFairly` + `lock` if `hasParkedBit` is set) and Clang
   thread-safety-analysis annotations.
3. **`ParkingLot`** ([`ParkingLot.h`][pl-h]) — static functions
   `parkConditionally(address, validation, beforeSleep, timeout)`,
   `compareAndPark(address, expected)`, `unparkOne(address[, callback])`,
   `unparkCount(address, count[, callback])`, `unparkAll(address)`, `forEach`.
4. **`WordLock`** ([`WordLock.h`][wl-h]) — a pointer-sized adaptive lock with
   its own queue, used by `ParkingLot` for its buckets: "WordLock sits lower in
   the stack and is used to implement Lock."

The `ParkingLot` contract, from the header ([`ParkingLot.h`][pl-h-park]):

> Parks the thread in a queue associated with the given address, which cannot
> be null. The parking only succeeds if the validation function returns true
> while the queue lock is held. … If validation returns true, it will enqueue
> the thread, unlock the parking queue lock, call the beforeSleep function, and
> then it will sleep so long as the thread continues to be on the queue and the
> timeout hasn't fired.

and for the callback form of unpark, which is what makes 2-bit locks possible
([`ParkingLot.h`][pl-h-unpark]):

> WTF::Lock and WTF::Condition both use this form of unparkOne() because it
> allows them to use the ParkingLot's internal queue lock to serialize some
> decision-making. For example, if UnparkResult::mayHaveMoreThreads is false
> inside the callback, then we know that at that moment nobody can add any
> threads to the queue because the queue lock is still held.

`unparkCount` (the bulk form `unparkOne` is built on) runs its callback even
when nothing was dequeued: "The callback runs under the queue lock even when
nothing was dequeued, which is what makes operating on an empty queue safe: a
thread on its way to parking must take that same lock to validate and enqueue,
so it either gets dequeued here or observes whatever the callback published
and declines to park" ([`ParkingLot.h`][pl-h-unpark]).

The blog shows the ParkingLot is enough to emulate `FUTEX_WAIT`/`FUTEX_WAKE`
— it uses that to build the comparison locks `ThunderLock`, `CascadeLock`
("similar to glibc's lowlevellock"), `HandoffLock` and `BargingLock`, and it
names `SharedArrayBuffer` atomics as a client.

## Analysis

### State word and fast path

`Lock` is `Atomic<uint8_t> m_byte` with `isHeldBit = 1` and `hasParkedBit = 2`
([`Lock.h`][lock-h-bits]). The inline paths are one weak CAS each
([`LockAlgorithm.h`][algo-h-fast]):

```cpp
static bool lockFastAssumingZero(Atomic<LockType>& lock)
{
    return lock.compareExchangeWeak(0, Hooks::lockHook(isHeldBit), std::memory_order_acquire);
}
static bool unlockFastAssumingZero(Atomic<LockType>& lock)
{
    return lock.compareExchangeWeak(isHeldBit, Hooks::unlockHook(0), std::memory_order_release);
}
```

A spurious weak-CAS failure on unlock is absorbed by `unlockSlow`, whose loop
handles the plain `isHeldBit` state too: "We could get here because the weak
CAS in unlock() failed spuriously, or because there is someone parked."
`lockFast`/`unlockFast` use `transaction` loops instead and are the forms used
when other bits share the word. The blog notes the price of the CAS unlock:
"for a single thread, the fastest locks are always spinlocks. This is because
spinlocks do not have to use CAS when unlocking."

### Waiting: spin, yield, park

`lockSlow` ([`LockAlgorithmInlines.h`][algo-inl-lock]) loops: barge if
`isHeldBit` is clear; spin (`SpinBackoff::shouldParkAfterSpinOnce`) only while
`hasParkedBit` is clear; set `hasParkedBit` by CAS; then
`ParkingLot::compareAndPark(&lock, isHeld|hasParked)`.

The spin policy has changed since the blog. The 2016 post describes 40
iterations of `sched_yield` borrowed from JikesRVM, with "a broad plateau of
near-optimal settings between about 10 and 60 spins" ([blog][blog]). The
pinned tree uses `SpinBackoff` ([`SpinBackoff.h`][spin-h-consts]): exponential
`pause` bursts (`1 << step` `_mm_pause`s per step) for `s_pauseSteps`, then
`Thread::yield()` for `s_yieldSteps`, then park, with per-platform constants
"tuned empirically":

| Platform              | `s_pauseSteps` | `s_yieldSteps` | Spin budget before parking                     |
| --------------------- | -------------- | -------------- | ---------------------------------------------- |
| ARM64 macOS           | 9              | 5              | 511 `pause`, then 5 yields                     |
| ARM64 iOS family      | 9              | 10             | 511 `pause`, then 10 yields                    |
| other Darwin, Windows | 0              | 40             | 40 yields (the 2016 policy)                    |
| everything else       | 6 (+2 non-x86) | 0              | 63 `pause` on x86-64 (255 elsewhere), no yield |

The header's long rationale names the three variables in play —
time-to-park, "niceness", poll rate — and the asymmetry that drives them:
"hits to the heavily-contended case tend to be localized to a few scenarios,
but have a very large effect-size … E.g. on Darwin, omitting thread_switch
entirely can more than double the runtime of certain benchmarks!"
`Thread::yield()` is `thread_switch(MACH_PORT_NULL, SWITCH_OPTION_DEPRESS, 1)`
on Darwin, `SwitchToThread()` on Windows, and a 1 ns `nanosleep` elsewhere,
because "A one nanosecond sleep costs a whole timer slack period, 50us by
default on Linux" ([`ThreadingPOSIX.cpp`][threading-posix]).

### The parking substrate

**Table.** `Atomic<Hashtable*> hashtable`, an array of `Atomic<Bucket*>`
created lazily per slot ([`ParkingLot.cpp`][pl-cpp-bucket]). A `Bucket` holds
`RefPtr<ThreadData> queueHead/queueTail`, a `WordLock`, a `MonotonicTime
nextFairTime`, a `WeakRandom`, and `char padding[64]` ("one of several
mitigations against false sharing"). Colliding addresses interleave in one
FIFO; dequeue skips nodes whose `address` differs.

**Growth** ([`ParkingLot.cpp`][pl-cpp-resize]): `ThreadData`'s constructor
increments `numThreads` and calls `ensureHashtableSize`; if
`size / numThreads < maxLoadFactor` (3) the resizer locks every bucket (sorted
by address, to avoid deadlock with another resizer), dequeues every waiter in
queue order, builds a table of `numThreads * growthFactor * maxLoadFactor`
slots, reinserts waiters reusing the old `Bucket` objects, and swaps the
pointer. Old spines are leaked and registered in a global `hashtables` vector
"so that hashtable resizing doesn't anger leak detectors"; the blog argues the
leak is a geometric series bounded by the current table's size, and that only
pointer arrays leak because buckets are reused. Every `enqueue`/`dequeue`
re-checks `hashtable.load() != myHashtable` after locking its bucket.

**Per-thread sleep.** `ThreadData` (refcounted, in a `ThreadSpecific`) holds
`Mutex parkingLock`, `ThreadCondition parkingCondition`, the `address` it
waits on, `nextInQueue` and the `token`. `parkConditionallyImpl` waits while
`me->address` is non-null and the timeout has not passed; `unparkCountImpl`
dequeues under the bucket lock, runs the callback, stores the token into each
dequeued thread, and **after** releasing the bucket lock clears each target's
`address` under its `parkingLock` and signals its condition
([`ParkingLot.cpp`][pl-cpp-park]). "Only large overheads matter on this code
path, since its performance is dominated by the work that the OS has to do to
make the thread not runnable anymore. Hence, it's fine for ParkingLot to bottom
out in OS condition variable code" ([blog][blog]).

A timed-out parker re-enters the bucket to remove itself; if someone else
already dequeued it, it **waits** for that unparker to clear its `address`
("otherwise, they may set our address to null in some distant future when
we're already trying to wait for other things") — the same ownership-transfer
problem `parking_lot` solves with `lock_bucket_checked`.

### Fairness, handoff and starvation

Default unlock barges; the queue head gets a handoff when either the caller
asked (`unlockFairly`) or the bucket says it is "time to be fair"
([`LockAlgorithmInlines.h`][algo-inl-unlock]):

```cpp
if (result.unparkedCount && (fairness == Fair || result.timeToBeFair)) {
    // We don't unlock anything. Instead, we hand the lock to the thread that was
    // waiting.
    ...
    return DirectHandoff;
}
```

`timeToBeFair` is computed per **bucket** in `genericDequeue`: it is true when
`MonotonicTime::now() > nextFairTime`, and after a dequeue at such a moment
`nextFairTime = time + Seconds::fromMilliseconds(random.get())`, where
`WeakRandom::get()` is uniform in [0, 1) ([`ParkingLot.cpp`][pl-cpp-fair],
[`WeakRandom.h`][weakrandom-h]). So a contended lock does a direct handoff at
least once per ~0–1 ms (mean 0.5 ms) of unlock traffic through its bucket; the
`Lock.h` comment's caveat is that collisions in the same bucket share that
budget ("each collision increases the fair unlock delay by one millisecond in
the worst case"). The woken thread distinguishes the two outcomes by token:
`DirectHandoff` means "The lock was never released"; `BargingOpportunity` means
loop and try again.

The blog's fairness measurement (10 threads, 100 ms, 4-core MacBook Pro): the
OS mutex was perfectly fair at "3010, the best that the OS mutex threads could
do", while "the least lucky WTF::Lock thread still got to acquire the lock
about 180x more times than any OS Mutex thread: thread 8 … with only 556797
acquisitions, 15% less than the thread 10, which was the luckiest." A
`HandoffLock` built on ParkingLot "performs almost exactly like the OS mutex",
from which the post concludes "the OS mutex's performance is likely to be due
entirely to its deterministic fairness guarantee."

### Condition variables and predicates

`Condition` is one `Atomic<bool> m_hasWaiters`, used only as a cache and as
the ParkingLot key ([`Condition.h`][cond-h]):

- `waitUntil`: `parkConditionally(&m_hasWaiters, validation = { store true;
return true; }, beforeSleep = { lock.unlock(); }, timeout)`, then
  `lock.lock()`. Because the thread is already enqueued when `beforeSleep`
  unlocks, "as soon as the lock is unlocked, any notify operations are
  guaranteed to release this thread from the condition variable" ([blog][blog]).
- `notifyOne`: return `false` on a plain load of `false`; else `unparkOne`
  with a callback that clears `m_hasWaiters` when `!mayHaveMoreThreads`.
- `notifyAll`: store `false` without a lock ("It's totally safe … because this
  thread is guaranteed to then unparkAll() anyway"), then `unparkAll`.

It works "with any lock-like object" (`template<typename LockType>`), and
documents "No spurious wake-up: in order for this to return before the
timeout, some notifyOne() or notifyAll() call must have happened." Header
claim: "This condition variable, when used with WTF::Lock, can outperform a
system condition variable and lock by up to 58x."

There is **no requeue** ([wait morphing][c-morph]): `ParkingLot` has no `unparkRequeue`, so `notifyAll`
wakes every waiter, and each then contends for the lock — the thundering herd
`parking_lot` later removed with `unpark_requeue`. Predicate waits
(`wait(lock, predicate)`, `waitUntil(lock, timeout, predicate)`) are plain
loops over `wait`.

### Footprint and layout

| Object              | Size                                                                                        |
| ------------------- | ------------------------------------------------------------------------------------------- |
| `Lock`, `Condition` | 1 byte each (the blog: "OS mutexes often require 64 bytes or more")                         |
| `WordLock`          | `sizeof(void*)`; head-of-queue `ThreadData` holds `queueTail`, so no other storage          |
| `CountingLock`      | `unsigned`: 2 lock bits + a lock counter for optimistic reads                               |
| `Bucket`            | heap object, lazily allocated per slot, ≥ 64 bytes of padding                               |
| per thread          | refcounted `ThreadData` with an OS mutex + OS condition variable                            |
| table               | `3 × 2 × threads` slots after growth; "memory usage per thread will still be less than 1KB" |

### Portability

Portable by construction: the only OS dependency is the per-thread
`Mutex`/`ThreadCondition`, which are `pthread_mutex_t`/`pthread_cond_t` on
POSIX and `SRWLOCK`/`CONDITION_VARIABLE` on Windows
([`ThreadingPrimitives.h`][tprim-h]). No futex, `WaitOnAddress` or `__ulock`
is used. Timeouts are `TimeWithDynamicClockType`; the header regrets that the
OS wait takes `WallTime` and so "specifying timeouts in MonotonicTime is
semantically better" — the loop re-checks `nowWithSameClock()`. On Cocoa,
`ENABLE(UNFAIR_LOCK)` additionally provides a separate `UnfairLock` wrapping
`os_unfair_lock`; it is not used by `Lock`.

### Async and fiber integration

None at this layer: `parkConditionally` blocks the calling thread on its
`ThreadCondition`. Two parts of the design are nevertheless the template for
an event-loop registry:

- **Validation + `beforeSleep` + callback-under-queue-lock** is a complete
  "wait on a word" protocol independent of how the waiter sleeps; the sleep
  itself is three lines (`while (me->address && …) timedWait`).
- **`forEach`** walks every parked thread and its address under all bucket
  locks — "useful primarily for debugging" — a registry that can be audited.

The `Lock.cpp` slow paths wrap themselves in
`DisableMallocRestrictionsForCurrentThreadScope`: "In some rare cases, the
lockSlow() algorithm may cause allocations" (first `ThreadData`, first
`Bucket` of a slot, table growth) — so the slow path is not allocation-free.
`tryLockWithTimeout` is signal-safe by polling `tryLock` with `sleep(1)`.

## Evaluation

All numbers below are the blog's, measured in 2016 on the 2016 algorithm (40
yields, no `SpinBackoff`); none were re-run.

| Benchmark                                       | Setup                                                                        | Result as stated                                                                                                       |
| ----------------------------------------------- | ---------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| JetStream 1.1, Speedometer 1.0, PLT3            | Mac Pro, 2 × 6-core 2.7 GHz Xeon E5 (24 logical), El Capitan, WebKit r199680 | "10% faster on JetStream, 5% faster on Speedometer, and 5% faster on our page loading test"                            |
| Microcontention, 1-iteration critical section   | MacBook Pro, 2.6 GHz 4-core i7 with HT                                       | OS mutex and `HandoffLock` "for 10 threads … are about 160x slower"; WTF::Lock "not so great for two or three threads" |
| Spin-limit sweep, 4 threads                     | same                                                                         | "this chart precisely confirms that 40 is still optimal"                                                               |
| Critical-section length sweep, 4 threads        | same                                                                         | "even for long critical sections (1000 double multiplies and 1000 double adds), WTF::Lock is still almost 2x faster"   |
| Fairness, 10 threads, 100 ms                    | same                                                                         | least lucky WTF::Lock thread 556797 acquisitions vs 3010 for the best OS-mutex thread                                  |
| vs `std::synchronic` TTAS lock and HLE spinlock | same                                                                         | "WTF::Lock is always significantly faster than either of these kinds of locks"                                         |

The post is candid about the gaps: "CascadeLock and ThunderLock exhibit
wonderful performance for smaller numbers of threads … this microbenchmark is
quite extreme and it doesn't decisively favor any of these algorithms", and
"it's clear that the x86 pause instruction is not useful for our spinlocks" —
a finding the current `SpinBackoff` reverses on every non-Darwin platform.

## Strengths

- **1-byte lock and condition variable** with one-CAS fast paths and a
  load-and-branch `notify` when nobody waits.
- **Bounded fairness without FIFO**: random ~1 ms handoff deadline per bucket
  plus an explicit `unlockFairly`/`safepoint`.
- **`LockAlgorithm` with hooks** lets a lock live inside any atomic field next
  to other bits (`CountingLock`, JSC cell headers).
- **Portable**: only per-thread OS mutex/condvar underneath.
- **Precise condition variable**: no spurious wakeups, exact "did I notify"
  result.

## Weaknesses

- **No requeue**: `notifyAll` herds every waiter onto the lock.
- **Allocations and refcounting on the slow path** (`RefPtr<ThreadData>`,
  lazy `Bucket`s, table growth).
- **Per-thread OS condition variable** means two OS objects per sleeping
  thread and a mutex round-trip per wake, where a futex word would do.
- **Fairness budget is per bucket**, so colliding locks share it.
- **No async integration**, and wall-clock-based OS waits under a
  monotonic-time API.

## Key design decisions and trade-offs

| Decision                                      | Rationale                                                                                                      | Trade-off                                                                     |
| --------------------------------------------- | -------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| Queues in one global address-keyed table      | Millions of locks, ~ten threads: memory O(threads)                                                             | Bucket collisions; stop-the-world growth; leaked spines                       |
| Callback under the queue lock on unpark       | Lets a 2-bit word clear `hasParkedBit` exactly; enables handoff decisions                                      | Not expressible with kernel futexes; callbacks run under a `WordLock`         |
| Barging unlock + random ~1 ms forced handoff  | Convoys cost "one context switch per lock acquisition"; long sections still get fairness                       | No FIFO; stochastic bound, shared across bucket collisions                    |
| Per-platform tuned `pause` + yield budget     | Semi-contended speed vs heavy-contention collapse; "omitting thread_switch … can more than double the runtime" | Empirical constants per OS/CPU; diverges from the blog's measured "40 yields" |
| Sleep on a per-thread OS condition variable   | Portability; park cost is dominated by the OS anyway                                                           | Two OS objects per thread; no kernel-assisted wake                            |
| `Condition` as a 1-byte "has waiters" cache   | Free `notify` with no waiters; no spurious wakeups                                                             | `notifyAll` wakes all; no wait morphing                                       |
| Generic `LockAlgorithm` over any atomic field | Embed locks in object headers and bitfields                                                                    | One lock per address — the key is the field's address                         |

## Sources

- [Locking in WebKit][blog] (Filip Pizlo, 2016-05-06) — motivation, ParkingLot API, BargingLock, Condition, WordLock, resize/leak argument, all benchmark numbers
- [`Lock.h`][lock-h], [`Lock.cpp`][lock-cpp] — the 1-byte lock, fairness guarantee wording, `unlockFairly`, `safepoint`, `tryLockWithTimeout`
- [`LockAlgorithm.h`][algo-h], [`LockAlgorithmInlines.h`][algo-inl] — fast paths, `lockSlow`, `unlockSlow`, `DirectHandoff`/`BargingOpportunity`
- [`ParkingLot.h`][pl-h], [`ParkingLot.cpp`][pl-cpp] — API contracts, `Bucket`, `genericDequeue` fairness timer, `ensureHashtableSize`, `parkConditionallyImpl`, `unparkCountImpl`
- [`Condition.h`][cond-h] — the condition variable
- [`WordLock.h`][wl-h], [`WordLock.cpp`][wl-cpp] — the bucket lock
- [`SpinBackoff.h`][spin-h], [`posix/ThreadingPOSIX.cpp`][threading-posix] — spin constants, `Thread::yield`
- [`CountingLock.h`][counting-h], [`ThreadingPrimitives.h`][tprim-h], [`WeakRandom.h`][weakrandom-h]

> [!NOTE]
> The WebKit clone is a sparse checkout of `Source/WTF/wtf` at `bb5913e`
> (2026-10-11), so JavaScriptCore's use of `LockAlgorithm` in `JSCell` and of
> `ParkingLot` for `Atomics.wait` is stated from the `LockAlgorithmInlines.h`
> comment and the blog, not read. The blog's charts are images; the numbers
> above are the ones its prose states. The blog does not mention the random
> fairness deadline; that is read from the source only.

<!-- References -->

[wk-repo]: https://github.com/WebKit/WebKit/tree/bb5913e37d019186e368a72dbde122306da9d75d/Source/WTF/wtf
[lock-h]: https://github.com/WebKit/WebKit/blob/bb5913e37d019186e368a72dbde122306da9d75d/Source/WTF/wtf/Lock.h
[lock-h-doc]: https://github.com/WebKit/WebKit/blob/bb5913e37d019186e368a72dbde122306da9d75d/Source/WTF/wtf/Lock.h#L48-L57
[lock-h-bits]: https://github.com/WebKit/WebKit/blob/bb5913e37d019186e368a72dbde122306da9d75d/Source/WTF/wtf/Lock.h#L139-L157
[lock-cpp]: https://github.com/WebKit/WebKit/blob/bb5913e37d019186e368a72dbde122306da9d75d/Source/WTF/wtf/Lock.cpp
[algo-h]: https://github.com/WebKit/WebKit/blob/bb5913e37d019186e368a72dbde122306da9d75d/Source/WTF/wtf/LockAlgorithm.h
[algo-h-fast]: https://github.com/WebKit/WebKit/blob/bb5913e37d019186e368a72dbde122306da9d75d/Source/WTF/wtf/LockAlgorithm.h#L50-L85
[algo-inl]: https://github.com/WebKit/WebKit/blob/bb5913e37d019186e368a72dbde122306da9d75d/Source/WTF/wtf/LockAlgorithmInlines.h
[algo-inl-lock]: https://github.com/WebKit/WebKit/blob/bb5913e37d019186e368a72dbde122306da9d75d/Source/WTF/wtf/LockAlgorithmInlines.h#L42-L99
[algo-inl-unlock]: https://github.com/WebKit/WebKit/blob/bb5913e37d019186e368a72dbde122306da9d75d/Source/WTF/wtf/LockAlgorithmInlines.h#L102-L160
[pl-h]: https://github.com/WebKit/WebKit/blob/bb5913e37d019186e368a72dbde122306da9d75d/Source/WTF/wtf/ParkingLot.h
[pl-h-park]: https://github.com/WebKit/WebKit/blob/bb5913e37d019186e368a72dbde122306da9d75d/Source/WTF/wtf/ParkingLot.h#L52-L90
[pl-h-unpark]: https://github.com/WebKit/WebKit/blob/bb5913e37d019186e368a72dbde122306da9d75d/Source/WTF/wtf/ParkingLot.h#L104-L161
[pl-cpp]: https://github.com/WebKit/WebKit/blob/bb5913e37d019186e368a72dbde122306da9d75d/Source/WTF/wtf/ParkingLot.cpp
[pl-cpp-bucket]: https://github.com/WebKit/WebKit/blob/bb5913e37d019186e368a72dbde122306da9d75d/Source/WTF/wtf/ParkingLot.cpp#L55-L259
[pl-cpp-fair]: https://github.com/WebKit/WebKit/blob/bb5913e37d019186e368a72dbde122306da9d75d/Source/WTF/wtf/ParkingLot.cpp#L137-L181
[pl-cpp-resize]: https://github.com/WebKit/WebKit/blob/bb5913e37d019186e368a72dbde122306da9d75d/Source/WTF/wtf/ParkingLot.cpp#L338-L438
[pl-cpp-park]: https://github.com/WebKit/WebKit/blob/bb5913e37d019186e368a72dbde122306da9d75d/Source/WTF/wtf/ParkingLot.cpp#L557-L736
[cond-h]: https://github.com/WebKit/WebKit/blob/bb5913e37d019186e368a72dbde122306da9d75d/Source/WTF/wtf/Condition.h
[wl-h]: https://github.com/WebKit/WebKit/blob/bb5913e37d019186e368a72dbde122306da9d75d/Source/WTF/wtf/WordLock.h
[wl-cpp]: https://github.com/WebKit/WebKit/blob/bb5913e37d019186e368a72dbde122306da9d75d/Source/WTF/wtf/WordLock.cpp
[spin-h]: https://github.com/WebKit/WebKit/blob/bb5913e37d019186e368a72dbde122306da9d75d/Source/WTF/wtf/SpinBackoff.h
[spin-h-consts]: https://github.com/WebKit/WebKit/blob/bb5913e37d019186e368a72dbde122306da9d75d/Source/WTF/wtf/SpinBackoff.h#L96-L153
[counting-h]: https://github.com/WebKit/WebKit/blob/bb5913e37d019186e368a72dbde122306da9d75d/Source/WTF/wtf/CountingLock.h
[tprim-h]: https://github.com/WebKit/WebKit/blob/bb5913e37d019186e368a72dbde122306da9d75d/Source/WTF/wtf/ThreadingPrimitives.h
[weakrandom-h]: https://github.com/WebKit/WebKit/blob/bb5913e37d019186e368a72dbde122306da9d75d/Source/WTF/wtf/WeakRandom.h
[threading-posix]: https://github.com/WebKit/WebKit/blob/bb5913e37d019186e368a72dbde122306da9d75d/Source/WTF/wtf/posix/ThreadingPOSIX.cpp#L864-L874
[blog]: https://webkit.org/blog/6161/locking-in-webkit/
[c-barging]: ./concepts.md#barging-and-handoff
[c-morph]: ./concepts.md#wait-morphing
