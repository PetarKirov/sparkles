# `parking_lot` (Rust)

Amanieu d'Antras's Rust port and extension of WebKit's parking lot: a 1-byte
`Mutex`, a word-sized `Condvar`/`RwLock`, and a separate `parking_lot_core`
crate that exposes the global address-keyed wait-queue table as a public API
for building further primitives.

|                       |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**              | library (thread synchronization primitives + parking-lot core)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| **Language**          | Rust (edition 2024, MSRV 1.95 at the pinned SHA)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| **License**           | Apache-2.0 OR MIT                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| **Repository**        | [`Amanieu/parking_lot`][pl-repo] — crates `parking_lot` 0.12.5, `parking_lot_core` 0.9.12, `lock_api` 0.4.14 (manifest versions; the `[Unreleased]` changelog section is the pinned tree)                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| **Lineage**           | "based on the WebKit `WTF::ParkingLot` class" ([`README.md`][readme]); see [WebKit WTF::Lock](./webkit-wtf-lock.md)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| **Lock word**         | `Mutex`: `AtomicU8`, bits `LOCKED_BIT`/`PARKED_BIT`; `RwLock`: `AtomicUsize`; `Condvar`: `AtomicPtr<RawMutex>`; `Once`: `AtomicU8`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| **Parking substrate** | global hashed table of `Bucket`s (64-byte aligned, each a `WordLock` + intrusive FIFO of per-thread `ThreadData`); per-thread `ThreadParker` (futex word / `WaitOnAddress` / keyed event / pthread mutex+cond)                                                                                                                                                                                                                                                                                                                                                                                                                    |
| **Source read**       | [`core/src/parking_lot.rs`][core-pl], [`core/src/word_lock.rs`][core-wl], [`core/src/spinwait.rs`][core-spin], [`core/src/thread_parker/mod.rs`][tp-mod], [`linux.rs`][tp-linux], [`unix.rs`][tp-unix], [`windows/mod.rs`][tp-win], [`windows/keyed_event.rs`][tp-keyed], [`windows/waitaddress.rs`][tp-waddr]; [`src/raw_mutex.rs`][raw-mutex], [`src/raw_condvar.rs`][raw-condvar], [`src/raw_rwlock.rs`][raw-rwlock], [`src/once.rs`][once], [`src/deadlock.rs`][deadlock]; [`README.md`][readme], [`CHANGELOG.md`][changelog]; the 0.9.12 release of [`core/src/parking_lot.rs`][core-pl-0912] for the removed fairness timer |

## Overview

### What it solves

The README states the size argument first ([`README.md`][readme]):

> `Mutex` and `Once` only require 1 byte of storage space, while `Condvar`
> and `RwLock` only require 1 word of storage space. The small size of `Mutex`
> in particular encourages the use of fine-grained locks to increase
> parallelism.

and then the mechanism that buys it ([`README.md`][readme], "The parking lot"):

> To keep these primitives small, all thread queuing and suspending
> functionality is offloaded to the _parking lot_. The idea behind this is
> based on the WebKit `WTF::ParkingLot` class, which essentially consists of a
> hash table mapping of lock addresses to queues of parked (sleeping) threads.
> The WebKit parking lot was itself inspired by Linux futexes, but it is more
> powerful since it allows invoking callbacks while holding a queue lock.

The remaining README claims are the ones this page tests against the source:
an uncontended acquire/release is "a single atomic operation"; microcontention
is absorbed by "spinning a few times"; `Condvar` "is guaranteed not to produce
spurious wakeups"; and "`Condvar::notify_all` requeues waiters directly onto
the associated `Mutex` … This avoids a thundering herd where every thread
immediately tries to acquire the mutex."

### Design philosophy

**Primitives keep state, the lot keeps queues.** Every primitive is a few bits
of atomic state plus calls into `parking_lot_core::{park, unpark_one,
unpark_all, unpark_requeue, unpark_filter}`, keyed by the primitive's own
address. The core API is public and separately versioned — "It is separate
from the synchronization primitives in the `parking_lot` crate so that changes
to the core API do not cause breaking changes" ([`README.md`][readme]) — which
is why third-party crates build their own primitives on it.

**Decisions happen under the queue lock.** `park` runs a `validate` closure,
and every `unpark_*` runs a `callback` closure, while the bucket lock is held.
That is where a primitive clears its "someone is parked" bit, decides between
a normal wake and a direct handoff, or picks requeue over wake. The lock word
never has to encode a waiter count.

**Explicit fairness only (new).** The pinned tree has removed the WebKit-style
eventual-fairness timer. The `[Unreleased]` changelog says: "Removed automatic
eventual fairness. Fair unlocking remains available through the explicit
fair-unlock APIs" ([`CHANGELOG.md`][changelog]). Released `parking_lot_core`
0.9.12 still had it (see
[Fairness, handoff and starvation](#fairness-handoff-and-starvation)).

## How it works

`parking_lot_core` keeps one global `HASHTABLE: AtomicPtr<HashTable>`. A table
is a boxed slice of `Bucket`s sized `(num_threads * LOAD_FACTOR)
.next_power_of_two()` with `LOAD_FACTOR = 3` ("Even with 3x more buckets than
threads, the memory overhead per thread is still only a few hundred bytes per
thread", [`parking_lot.rs`][core-pl-table]):

```rust
#[repr(align(64))]
struct Bucket {
    // Lock protecting the queue
    mutex: WordLock,

    // Linked list of threads waiting on this bucket
    queue_head: Cell<Option<NonNull<ThreadData>>>,
    queue_tail: Cell<Option<NonNull<ThreadData>>>,
}
```

The key is hashed with Fibonacci hashing —
`key.wrapping_mul(0x9E3779B97F4A7C15) >> (64 - bits)` on 64-bit targets
([`parking_lot.rs`][core-pl-hash]) — and colliding keys share one FIFO queue;
every scan compares each node's `key` field and skips the rest.

**Growth.** Creating a `ThreadData` (once per thread, lazily, in a
`thread_local!`) bumps `NUM_THREADS` and calls `grow_hashtable`. Growth locks
**every** bucket of the current table, re-checks that the table is still
current, rehashes all queued `ThreadData` into a new table, publishes it with a
`Release` store, then unlocks the old buckets. Old tables are never freed: "Any
`HashTable` this global static has ever pointed to must never be freed"; the
new table keeps a `_prev` pointer "only … to keep leak detectors happy". Every
operation therefore starts with `lock_bucket(key)`: load the table, lock the
bucket, and retry if `HASHTABLE` moved in between
([`parking_lot.rs`][core-pl-lockbucket]).

**`park(key, validate, before_sleep, timed_out, park_token, timeout)`**
([`parking_lot.rs`][core-pl-park]):

1. Lock the bucket; run `validate()`; on `false` unlock and return
   `ParkResult::Invalid`.
2. Store `key` and `park_token` in this thread's `ThreadData`, call
   `parker.prepare_park()`, append to the bucket queue, unlock.
3. Run `before_sleep()` — outside the bucket lock; it "is allowed to call
   `unpark_one`, `unpark_all`, `unpark_requeue` or `unpark_filter`, but it is
   not allowed to call `park`". `Condvar` unlocks its mutex here.
4. `parker.park()` / `park_until(timeout)`.
5. On timeout, re-lock the bucket with `lock_bucket_checked(&thread_data.key)`
   (the key may have changed through a requeue), re-check
   `parker.timed_out()` under the lock, unlink itself, and call
   `timed_out(key, was_last_thread)` so the primitive can clear its parked bit.

**`unpark_one(key, callback)`** locks the bucket, unlinks the first node whose
key matches, scans on to compute `have_more_threads`, calls
`callback(UnparkResult)` for the `UnparkToken` to hand over, stores it in the
target, and calls `parker.unpark_lock()` **before** releasing the bucket lock
and `handle.unpark()` **after** it — "Commit the unpark before unlocking the
queue. The target may now destroy its ThreadData, but the handle remains valid
for the deferred wake" ([`parking_lot.rs`][core-pl-unparkone]). `unpark_all`
and `unpark_filter` collect handles into a `SmallVec<[_; 8]>` and wake them
after unlocking.

**`unpark_requeue(key_from, key_to, validate, callback)`** locks both buckets
in index order (`lock_bucket_pair`), asks `validate()` for a `RequeueOp` —
`Abort`, `UnparkOneRequeueRest`, `RequeueAll`, `UnparkOne`, `RequeueOne` — and
moves matching nodes from one queue to the other by rewriting their `key`
field, without waking them ([`parking_lot.rs`][core-pl-requeue]).

**`unpark_filter(key, filter, callback)`** walks the queue calling
`filter(ParkToken)` per waiter for `Unpark`/`Skip`/`Stop`
([`parking_lot.rs`][core-pl-filter]); `RwLock` uses it to wake "all readers and
one upgrader/writer" in one pass.

The other public pieces: `SpinWait` (the shared backoff counter),
`ParkToken`/`UnparkToken` (`usize` payloads in each direction), and
`deadlock::{acquire_resource, release_resource, check_deadlock}`.

## Analysis

### State word and fast path

`RawMutex` is one `AtomicU8` with two bits ([`raw_mutex.rs`][raw-mutex-state]):

| `PARKED_BIT` | `LOCKED_BIT` | Meaning                                                                       |
| ------------ | ------------ | ----------------------------------------------------------------------------- |
| 0            | 0            | free, no waiters                                                              |
| 0            | 1            | held, no waiters                                                              |
| 1            | 0            | free; a waiter is about to be unparked or a parking thread may abort the park |
| 1            | 1            | held; one or more threads parked or about to park                             |

The source's invariant: in the held-and-parked state, "`PARKED_BIT` is only
ever cleared when a bucket lock is held (i.e. in a `parking_lot_core`
callback). This ensures that we never end up in a situation where there are
parked threads but `PARKED_BIT` is not set."

- `lock`: `compare_exchange_weak(0, LOCKED_BIT, Acquire, Relaxed)`, else the
  `#[cold]` `lock_slow` ([`raw_mutex.rs`][raw-mutex-lock]).
- `unlock`: `compare_exchange(LOCKED_BIT, 0, Release, Relaxed)`, else
  `unlock_slow` — which runs whenever `PARKED_BIT` is set.
- `try_lock`: a `try_update` loop that sets `LOCKED_BIT` even when `PARKED_BIT`
  is set (barging is allowed on every path).

The unlock is a CAS, not a store, for the same reason WebKit gives: the
releaser must learn atomically whether anyone parked.

### Waiting: spin, yield, park

`lock_slow` ([`raw_mutex.rs`][raw-mutex-slow]) loops: take the lock if
`LOCKED_BIT` is clear (even with a queue); else, **only if no one is parked**,
`spinwait.spin()`; else CAS in `PARKED_BIT`; else `park` with
`validate = state == LOCKED_BIT | PARKED_BIT`. On `ParkResult::Unparked(_)`
or `Invalid` it `spinwait.reset()`s and starts over.

`SpinWait::spin` is the whole spin policy ([`spinwait.rs`][core-spin]):

```rust
pub fn spin(&mut self) -> bool {
    if self.counter >= 10 {
        return false;
    }
    self.counter += 1;
    if self.counter <= 3 {
        cpu_relax(1 << self.counter);
    } else {
        thread_parker::thread_yield();
    }
    true
}
```

That is 2 + 4 + 8 = 14 `spin_loop()` hints, then 7 OS yields
(`std::thread::yield_now` on Unix, `Sleep(0)` on Windows — "We don't use
`SwitchToThread` here because it doesn't consider all threads in the system",
[`windows/mod.rs`][tp-win]), then park. It is not adaptive: there is no
measured spin length and no owner-running check. `spin_no_yield` (cap at
`1 << 10` relaxes, never yields) is used by `RwLock` to back off contended
reader-count CAS loops.

### The parking substrate

Two layers. **Where waiter records live:** each thread's `ThreadData` is a
`thread_local!`, created lazily on first park (falling back to a stack-local
`ThreadData` during TLS teardown) and linked intrusively into one bucket queue
at a time. The ownership protocol is spelled out in the source — while linked,
the record "is owned by the parking lot. Its queue fields and lifetime are
protected by the lock of the bucket that currently contains it"; a timeout
"does not by itself transfer ownership back" ([`parking_lot.rs`][core-pl-td]).
Nothing is allocated per lock or per wait; the only allocations are table
growth and the per-thread record.

**What a thread blocks on:** a `ThreadParker` selected per target
([`thread_parker/mod.rs`][tp-mod]). The trait has `prepare_park`, `park`,
`park_until`, `timed_out`, and `unpark_lock` returning an `UnparkHandle` whose
`unpark` runs after the bucket lock is dropped. On Linux and Android it is a
private futex on a per-thread `AtomicI32` ([`linux.rs`][tp-linux]):
`prepare_park` stores 1, `park` loops `FUTEX_WAIT|FUTEX_PRIVATE_FLAG` while the
word is non-zero, `unpark_lock` stores 0 with `Release`, and the deferred
`FUTEX_WAKE` tolerates `EFAULT` because "The thread data may have been freed
at this point, but it doesn't matter since the syscall will just return
`EFAULT` in that case." The futex is per-thread, not per-lock: the kernel only
ever sees one waiter per futex word.

The `WordLock` that guards each bucket cannot use the parking lot, so it keeps
its own queue: a pointer-sized word whose low bits are `LOCKED_BIT = 1` and
`QUEUE_LOCKED_BIT = 2` and whose remaining bits point to the head of an
intrusive queue of `word_lock::ThreadData` ([`word_lock.rs`][core-wl]); new
nodes are pushed lock-free and "processed" (back-linked) under the queue bit.

### Fairness, handoff and starvation

Default unlock is **[barging][c-barging]**: `unlock_slow` calls `unpark_one` and, in the
callback, stores `PARKED_BIT` or `0` — the lock is released and the woken
thread must re-race for it (`TOKEN_NORMAL`). With `fair == true` the callback
keeps `LOCKED_BIT` set and returns `TOKEN_HANDOFF`; the woken thread's
`lock_slow` returns on `ParkResult::Unparked(TOKEN_HANDOFF)` without touching
the word ([`raw_mutex.rs`][raw-mutex-unlockslow]). Fair unlock is reachable
three ways: `MutexGuard::unlock_fair`, `MutexGuard::bump` (fair unlock then
relock if `PARKED_BIT` is set), and `FairMutex`, which always unlocks fairly.

**The fairness timer is gone at the pinned SHA.** In released
`parking_lot_core` 0.9.12, each `Bucket` carried a `FairTimeout` and every
unpark set `UnparkResult::be_fair` from it ([0.9.12 `parking_lot.rs`][core-pl-0912]):

```rust
// Determine whether we should force a fair unlock, and update the timeout
#[inline]
fn should_timeout(&mut self) -> bool {
    let now = TimeoutInstant::now();
    if now > self.timeout {
        // Time between 0 and 1ms.
        let nanos = self.gen_u32() % 1_000_000;
        self.timeout = now + Duration::new(0, nanos);
        true
    } else {
        false
    }
}
```

documented as "set to true on average once every 0.5ms for any given key. It
should be used to switch to a fair unlocking mechanism for a particular
unlock", with a per-bucket xorshift PRNG. `RawMutex::unlock_slow` did
`if result.unparked_threads != 0 && (force_fair || result.be_fair)`. At
`6be7fac` `UnparkResult` has only `unparked_threads`, `requeued_threads` and
`have_more_threads`, `Bucket` has no timer, and the condition is
`result.unparked_threads != 0 && fair` — a default `Mutex` now gives **no
starvation bound** to a parked thread that keeps losing the race to running
threads. Within a bucket, wake order is FIFO; a thread that loses after a
`TOKEN_NORMAL` wake re-parks at the **tail**.

`RwLock` is "task-fair … which generally gives waiting writers priority over
new readers" ([`README.md`][readme]); the nonrecursive variant makes readers
block behind `PARKED_BIT`, and the separate `RecursiveRwLock` "may starve
writers" ([`raw_rwlock.rs`][raw-rwlock]).

### Condition variables and predicates

`RawCondvar` is one `AtomicPtr<RawMutex>`: null when no one waits, else the
mutex the waiters use ([`raw_condvar.rs`][raw-condvar]). Wait
(`wait_until_internal`):

- `validate` (bucket lock held): record the mutex pointer, or return `false`
  if a different mutex is recorded — this becomes the panic "attempted to use
  a condition variable with more than one mutex".
- `before_sleep`: `mutex.unlock_inner(false)`. The thread is already queued, so
  a notify between unlock and sleep still finds it.
- On wake: if the token is `TOKEN_HANDOFF` the mutex is already owned;
  otherwise `mutex.lock()`.

Notify is **[wait morphing][c-morph] through `unpark_requeue`**:

- `notify_one`: if the state is null, return `false` (one relaxed load). Else
  `validate` calls `mutex.mark_parked_if_locked()` — if the mutex is held, set
  its `PARKED_BIT` and return `RequeueOne` (move one waiter onto the mutex's
  queue, no wake); if free, `UnparkOne`.
- `notify_all`: clear the state, then `RequeueAll` if the mutex is held,
  else `UnparkOneRequeueRest`; the callback `mark_parked()`s the mutex when it
  requeued anyone.

A requeued waiter sleeps on the mutex key and is woken by a later
`unlock_slow` like any lock waiter. The timeout path checks whether its key
changed — "If we were requeued to a mutex, then we did not time out" — so
`Condvar` returns exact notification results; the changelog records
`notify_one` returning "exactly whether a waiting thread was selected" and
`notify_all` "the exact number" ([`CHANGELOG.md`][changelog]). The README's
"no spurious wakeups" holds because `park` returns only on unpark, timeout, or
failed validation.

**Predicate waits** are not in the core: `lock_api::Condvar` offers
`wait_while`, a loop over `wait`. There is no nsync-style evaluation of
predicates by the unlocker (contrast [nsync](./nsync.md#condition-variables-and-predicates)).

### Footprint and layout

| Object             | Size                                                                                  |
| ------------------ | ------------------------------------------------------------------------------------- |
| `RawMutex`, `Once` | 1 byte (`AtomicU8`; `Once` uses `DONE_BIT`, `POISON_BIT`, `LOCKED_BIT`, `PARKED_BIT`) |
| `RawCondvar`       | 1 pointer                                                                             |
| `RawRwLock`        | 1 `usize`: 4 flag bits + reader count in units of `ONE_READER = 0b10000`              |
| `Bucket`           | `#[repr(align(64))]`: `WordLock` + head + tail                                        |
| table              | `next_power_of_two(3 × threads)` buckets, grown never shrunk, old tables leaked       |
| per thread         | one `ThreadData` (parker + atomic key + queue link + tokens) in TLS                   |

A lock can share a cache line with the data it protects — the point of a
1-byte lock. Buckets are padded to a cache line; there is no padding inside a
queue, and a collision means two keys share one `WordLock`.

`Mutex<T>` must not move while a thread is parked on it, since the address is
the key; Rust's borrow rules guarantee this for a borrowed `Mutex`.

### Portability

Per-target parker ([`thread_parker/mod.rs`][tp-mod]):

| Target                              | Parker                                                                                                                     |
| ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Linux, Android                      | per-thread private futex word; `futex_time64` preferred on 32-bit, `ENOSYS` cached in a static ([`linux.rs`][tp-linux])    |
| other Unix (macOS, BSDs)            | `pthread_mutex_t` + `pthread_cond_t` per thread, `CLOCK_MONOTONIC` condattr; `pthread_cond_timedwait_relative_np` on Apple |
| Windows                             | `WaitOnAddress`/`WakeByAddressSingle` (Win8+) if `GetProcAddress` finds them, else NT keyed events (XP+); panic if neither |
| Redox, SGX, wasm (+ atomics), other | per-target files; `generic.rs` spins                                                                                       |

Notably, macOS gets the pthread fallback, not `__ulock_wait`; `os_unfair_lock`
is not used anywhere. The Windows backend is chosen once in a `LazyLock`
([`windows/mod.rs`][tp-win]).

### Async and fiber integration

None. `park` blocks the OS thread; there is no way to enqueue a waker, a
fiber, or an event-loop completion instead of a `ThreadData`, because the
`ThreadParker` is selected at compile time and the queue node is the
thread-local record. Three facts matter for a fiber-aware design anyway:

- The core API is already a **registry keyed by address with callbacks under
  the queue lock** — the shape a loop-resident `WaitWord` registry needs —
  and the `UnparkToken` is a ready-made "why you were woken" channel.
- The **two-phase wake** (`unpark_lock` under the bucket lock, `unpark` after)
  is what lets a waker hand off to a different wake mechanism (a futex wake, an
  `io_uring` message, a loop doorbell) without holding the bucket lock.
- The changelog's warning — primitives "must not be used internally by global
  allocators" and parking-lot operations "are not reentrant … from an
  asynchronous signal handler" ([`CHANGELOG.md`][changelog],
  [`parking_lot.rs`][core-pl-park]) — would carry over to any D port.

### Deadlock detection

With the `deadlock_detection` feature (pulling in `petgraph` and `backtrace`),
`acquire_resource`/`release_resource` record ownership per thread and
`check_deadlock()` builds a wait-for graph — first a fast approximate graph
locking one bucket at a time, then, only if a cycle shows up, a precise graph
with all buckets locked and `kosaraju_scc` to report components
([`parking_lot.rs`][core-pl-deadlock]). Reporting is destructive: "detected
threads are removed from their parking queues, capture their backtraces, and
then remain blocked permanently" ([`deadlock.rs`][deadlock]). The feature is
incompatible with `send_guard`.

## Strengths

- **1-byte mutex with a one-CAS fast path in both directions**, and a
  parking table whose size is O(threads), not O(locks).
- **A public, reusable core**: `park`/`unpark_*` with validation and callbacks
  under the queue lock, plus tokens in both directions, is a complete toolkit
  for new primitives.
- **Condvar requeue** removes the thundering herd and gives exact notify
  counts and no spurious wakeups.
- **Two-phase unpark** keeps syscalls out of the bucket lock and makes a late
  wake harmless.
- **Explicit fair unlock** (`unlock_fair`, `bump`, `FairMutex`) when a caller
  needs handoff.

## Weaknesses

- **No starvation bound by default** at the pinned SHA: the eventual-fairness
  timer was removed; a parked waiter can lose every race.
- **Fixed, non-adaptive spin** (14 relax hints + 7 yields) and spinning only
  when no one is parked; no owner-running check.
- **A convoy once the cores are saturated.** The crate's own
  `benchmark/src/bin/mutex.rs`, built from this SHA and from 0.12.5 (8
  iterations inside the lock, 16 outside, one second per cell; run locally on
  2026-10-11, 32 hardware threads), beats `std::sync::Mutex` 1.3–1.6× at 2 and
  4 threads and loses 6–8× at 32 and 64. `PARKED` is exact, so every
  `unlock_slow` wakes a waiter that then loses the race to a running thread
  and parks again; there is no designated-waker bit to limit the woken to one
  ([comparison § (a)](./comparison.md#a-the-mutex-word),
  [mutex benchmark](./examples/mutex-throughput.d)).
- **Global table growth stops the world**: every bucket is locked to rehash,
  and old tables leak by design.
- **Hash collisions serialize unrelated locks** on one `WordLock` and one
  queue scan.
- **No async integration**: waiters are OS threads only.
- **macOS and BSDs use per-thread pthread mutex + condvar**, not
  `__ulock`/`_umtx_op`.

## Key design decisions and trade-offs

| Decision                                              | Rationale                                                                                  | Trade-off                                                                    |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------- |
| Global address-keyed table instead of per-lock queues | 1-byte locks; memory bounded by threads                                                    | Collisions share a bucket; growth locks every bucket; leaked old tables      |
| Callbacks under the bucket lock                       | Lock word can clear `PARKED_BIT` exactly; no waiter count needed                           | Callbacks must not panic, park, or call the lot (enforced by `AbortOnPanic`) |
| Per-thread parker, wake deferred past the bucket lock | Keeps syscalls out of critical sections; late wake is harmless (`EFAULT` ignored)          | Each wait touches two words (lock word, parker word)                         |
| Barging unlock by default                             | Throughput under microcontention                                                           | No FIFO; with the timer removed, no starvation bound                         |
| Remove automatic eventual fairness (`[Unreleased]`)   | Changelog gives no rationale; "Fair unlocking remains available through the explicit APIs" | Callers needing bounded waits must use `unlock_fair`/`FairMutex`             |
| `Condvar` notify requeues onto the mutex              | No thundering herd; exact notify counts                                                    | `Condvar` binds to one mutex at a time (panic otherwise)                     |
| Spin 3 relax rounds + 7 yields, only with no queue    | Microcontention without burning CPU once a queue exists                                    | Not tuned per platform; yields are scheduler-dependent                       |

## Sources

- [`README.md`][readme] — features list, the parking-lot paragraph, WebKit lineage
- [`CHANGELOG.md`][changelog] — `[Unreleased]`: removal of eventual fairness, exact `Condvar` notifications, `Once` additions, allocator/signal warnings
- [`core/src/parking_lot.rs`][core-pl] — `HashTable`, `Bucket`, `ThreadData` ownership protocol, `grow_hashtable`, `park`, `unpark_one`, `unpark_all`, `unpark_requeue`, `unpark_filter`, deadlock detector
- [`core/src/parking_lot.rs` at `parking_lot_core-v0.9.12`][core-pl-0912] — `FairTimeout`, `be_fair`
- [`core/src/word_lock.rs`][core-wl] — the bucket lock
- [`core/src/spinwait.rs`][core-spin] — `SpinWait`
- [`core/src/thread_parker/`][tp-mod] — [`linux.rs`][tp-linux], [`unix.rs`][tp-unix], [`windows/mod.rs`][tp-win], [`keyed_event.rs`][tp-keyed], [`waitaddress.rs`][tp-waddr]
- [`src/raw_mutex.rs`][raw-mutex], [`src/raw_condvar.rs`][raw-condvar], [`src/raw_rwlock.rs`][raw-rwlock], [`src/once.rs`][once], [`src/deadlock.rs`][deadlock]

> [!NOTE]
> The clone is a single-commit checkout of `6be7fac` (2026-10-02). The
> rationale for removing automatic eventual fairness is not stated in the
> changelog entry, and the pull request that removed it was not read. The
> removed `FairTimeout` code and the `force_fair || result.be_fair` test are
> quoted from commit `d7828ff`, which both the `parking_lot_core-v0.9.12` and
> `parking_lot-v0.12.5` tags point at, fetched directly rather than from the
> clone.

<!-- References -->

[pl-repo]: https://github.com/Amanieu/parking_lot/tree/6be7fac301b81bee512005ce529aabfa4d07aa0e
[readme]: https://github.com/Amanieu/parking_lot/blob/6be7fac301b81bee512005ce529aabfa4d07aa0e/README.md
[changelog]: https://github.com/Amanieu/parking_lot/blob/6be7fac301b81bee512005ce529aabfa4d07aa0e/CHANGELOG.md
[core-pl]: https://github.com/Amanieu/parking_lot/blob/6be7fac301b81bee512005ce529aabfa4d07aa0e/core/src/parking_lot.rs
[core-pl-table]: https://github.com/Amanieu/parking_lot/blob/6be7fac301b81bee512005ce529aabfa4d07aa0e/core/src/parking_lot.rs#L35-L96
[core-pl-td]: https://github.com/Amanieu/parking_lot/blob/6be7fac301b81bee512005ce529aabfa4d07aa0e/core/src/parking_lot.rs#L98-L154
[core-pl-hash]: https://github.com/Amanieu/parking_lot/blob/6be7fac301b81bee512005ce529aabfa4d07aa0e/core/src/parking_lot.rs#L336-L346
[core-pl-lockbucket]: https://github.com/Amanieu/parking_lot/blob/6be7fac301b81bee512005ce529aabfa4d07aa0e/core/src/parking_lot.rs#L256-L371
[core-pl-park]: https://github.com/Amanieu/parking_lot/blob/6be7fac301b81bee512005ce529aabfa4d07aa0e/core/src/parking_lot.rs#L547-L713
[core-pl-unparkone]: https://github.com/Amanieu/parking_lot/blob/6be7fac301b81bee512005ce529aabfa4d07aa0e/core/src/parking_lot.rs#L715-L808
[core-pl-requeue]: https://github.com/Amanieu/parking_lot/blob/6be7fac301b81bee512005ce529aabfa4d07aa0e/core/src/parking_lot.rs#L877-L1019
[core-pl-filter]: https://github.com/Amanieu/parking_lot/blob/6be7fac301b81bee512005ce529aabfa4d07aa0e/core/src/parking_lot.rs#L1021-L1129
[core-pl-deadlock]: https://github.com/Amanieu/parking_lot/blob/6be7fac301b81bee512005ce529aabfa4d07aa0e/core/src/parking_lot.rs#L1323-L1530
[core-pl-0912]: https://github.com/Amanieu/parking_lot/blob/d7828fff7b5d6327ae608e82db45f888b344449a/core/src/parking_lot.rs#L114-L149
[core-wl]: https://github.com/Amanieu/parking_lot/blob/6be7fac301b81bee512005ce529aabfa4d07aa0e/core/src/word_lock.rs
[core-spin]: https://github.com/Amanieu/parking_lot/blob/6be7fac301b81bee512005ce529aabfa4d07aa0e/core/src/spinwait.rs
[tp-mod]: https://github.com/Amanieu/parking_lot/blob/6be7fac301b81bee512005ce529aabfa4d07aa0e/core/src/thread_parker/mod.rs
[tp-linux]: https://github.com/Amanieu/parking_lot/blob/6be7fac301b81bee512005ce529aabfa4d07aa0e/core/src/thread_parker/linux.rs
[tp-unix]: https://github.com/Amanieu/parking_lot/blob/6be7fac301b81bee512005ce529aabfa4d07aa0e/core/src/thread_parker/unix.rs
[tp-win]: https://github.com/Amanieu/parking_lot/blob/6be7fac301b81bee512005ce529aabfa4d07aa0e/core/src/thread_parker/windows/mod.rs
[tp-keyed]: https://github.com/Amanieu/parking_lot/blob/6be7fac301b81bee512005ce529aabfa4d07aa0e/core/src/thread_parker/windows/keyed_event.rs
[tp-waddr]: https://github.com/Amanieu/parking_lot/blob/6be7fac301b81bee512005ce529aabfa4d07aa0e/core/src/thread_parker/windows/waitaddress.rs
[raw-mutex]: https://github.com/Amanieu/parking_lot/blob/6be7fac301b81bee512005ce529aabfa4d07aa0e/src/raw_mutex.rs
[raw-mutex-state]: https://github.com/Amanieu/parking_lot/blob/6be7fac301b81bee512005ce529aabfa4d07aa0e/src/raw_mutex.rs#L18-L49
[raw-mutex-lock]: https://github.com/Amanieu/parking_lot/blob/6be7fac301b81bee512005ce529aabfa4d07aa0e/src/raw_mutex.rs#L58-L97
[raw-mutex-slow]: https://github.com/Amanieu/parking_lot/blob/6be7fac301b81bee512005ce529aabfa4d07aa0e/src/raw_mutex.rs#L189-L269
[raw-mutex-unlockslow]: https://github.com/Amanieu/parking_lot/blob/6be7fac301b81bee512005ce529aabfa4d07aa0e/src/raw_mutex.rs#L271-L310
[raw-condvar]: https://github.com/Amanieu/parking_lot/blob/6be7fac301b81bee512005ce529aabfa4d07aa0e/src/raw_condvar.rs
[raw-rwlock]: https://github.com/Amanieu/parking_lot/blob/6be7fac301b81bee512005ce529aabfa4d07aa0e/src/raw_rwlock.rs
[once]: https://github.com/Amanieu/parking_lot/blob/6be7fac301b81bee512005ce529aabfa4d07aa0e/src/once.rs
[deadlock]: https://github.com/Amanieu/parking_lot/blob/6be7fac301b81bee512005ce529aabfa4d07aa0e/src/deadlock.rs
[c-barging]: ./concepts.md#barging-and-handoff
[c-morph]: ./concepts.md#wait-morphing
