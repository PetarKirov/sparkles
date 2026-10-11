# Rust `std::sync` primitives (Rust)

The Rust standard library implements `Mutex`, `Condvar`, `RwLock`, `Once` and
thread parking itself, as the "thinnest possible wrapper" over each platform's
wait-on-address call: a 3-state futex word with a 100-iteration spin where a
futex exists, a pointer-sized SRW-style waiter queue where only a thread parker
exists, and `pthread` where the OS lock carries features (priority inheritance)
that a user-space lock would lose.

|                       |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**              | language standard library                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| **Language**          | Rust                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| **License**           | MIT OR Apache-2.0                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| **Repository**        | [`rust-lang/rust`][rust-repo] at `3bf5c6d99bc8` (2026-05-22), `library/std/src/sys/sync/`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| **Primitives**        | `sys::Mutex`, `sys::Condvar`, `sys::RwLock` (futex and queue variants), `sys::Once` (futex and queue variants), `sys::Parker`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| **Parking substrate** | the OS futex word itself (Linux, Android, \*BSD, Windows `WaitOnAddress`, Wasm, Fuchsia, Hermit); a per-thread parker under stack-allocated waiter queues elsewhere (Darwin: `dispatch_semaphore`; NetBSD: `_lwp_park`)                                                                                                                                                                                                                                                                                                                                                                                       |
| **Fairness**          | unfair everywhere: barging 3-state mutex, writer-preferring `RwLock`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| **History**           | tracking issue [#93740][i93740] (Mara Bos, 2022-02-07); futex `Mutex`/`Condvar` [#95035][pr95035] (2022-04-05); futex `RwLock` [#95801][pr95801] (2022-04-12); \*BSD [#96510][pr96510] (2022-05-06); queue `RwLock` [#110211][pr110211] (2024-02-12); Windows futex [#121956][pr121956] (2024-03-06)                                                                                                                                                                                                                                                                                                          |
| **Source read**       | [`mutex/futex.rs`][mutex-futex], [`mutex/mod.rs`][mutex-mod], [`mutex/pthread.rs`][mutex-pthread], [`mutex/fuchsia.rs`][mutex-fuchsia], [`condvar/futex.rs`][condvar-futex], [`condvar/mod.rs`][condvar-mod], [`rwlock/futex.rs`][rwlock-futex], [`rwlock/queue.rs`][rwlock-queue], [`rwlock/mod.rs`][rwlock-mod], [`once/futex.rs`][once-futex], [`once/queue.rs`][once-queue], [`once/mod.rs`][once-mod], [`thread_parking/*`][parking-mod], [`pal/unix/futex.rs`][pal-unix-futex], [`pal/windows/futex.rs`][pal-win-futex], [`pal/unix/sync/*`][pal-unix-mutex]; issue [#93740][i93740] and the linked PRs |

## Overview

### What it solves

Before 2022 every `std::sync` lock on Unix was a `Box<pthread_mutex_t>` (or
`pthread_rwlock_t`, `pthread_cond_t`): pthread objects may not move, Rust values
must, so each lock cost an allocation and an indirection and could not have a
`const fn new`. The tracking issue opens with exactly that
([#93740][i93740]):

> On most platforms, these structures are currently wrappers around their
> `pthread` equivalent, such as `pthread_mutex_t`. These types are not movable,
> however, forcing us to wrap them in a `Box`, resulting in an allocation and
> indirection for our lock types. This also gets in the way of a `const`
> constructor for these types, which makes `static` locks more complicated than
> necessary.

The same issue records why `parking_lot` itself was _not_ merged: its global
hash table allocates, and "a custom allocator will likely use the standard
library's locks, creating a cyclic dependency problem where you can't allocate
memory without locking, but you can't lock without first allocating the hash
table." That is the bootstrap problem any [parking-lot](./parking-lot.md)
design faces inside a runtime's allocator.

### Design philosophy

The library team's 2022-03-16 meeting settled the design; its summary
([#93740 comment][c-decisions]) is the clearest statement of intent in the
whole corpus:

> A 'trivial' futex-based implementation of these locks, like in my
> experiment, seems like a good way to go. It is simple and easy to implement
> and verify, as it leaves most of the complexity to the kernel. […]
> Not requeueing but waking up all Condvar::notify_all is fine. […]
> A theoretical deadlock on exactly 4294967296 missed notifications when
> unlocking a mutex in Condvar::wait is fine. […] Avoiding spurious wake ups
> brings more complexity than it is worth. Avoiding writer starvation in
> RwLock is important.

On platforms without a futex, the update to the issue chose a pointer-sized
user-space queue over a parking lot: "We've decided to not directly use parking
lot's one-byte (two bit) locks, but instead use the equivalent of its internal
`WordLock` or Windows' SRW locks, which are one pointer in size and require no
global state in the program. That solves the allocation problem." And for
Darwin: "To maintain priority inheritance of the native locks (e.g. on macOS),
we've kept using pthread locks on non-futex unix platforms" ([#93740][i93740]).

## How it works

Each primitive is selected per target with `cfg_select!` in its `mod.rs`
([`mutex/mod.rs`][mutex-mod], [`condvar/mod.rs`][condvar-mod],
[`rwlock/mod.rs`][rwlock-mod], [`once/mod.rs`][once-mod],
[`thread_parking/mod.rs`][parking-mod]). The futex variants call a three-function
seam, `futex_wait(&Atomic<u32>, expected, Option<Duration>) -> bool`,
`futex_wake(&…) -> bool` and `futex_wake_all(&…)`, implemented per OS in
[`pal/unix/futex.rs`][pal-unix-futex] and [`pal/windows/futex.rs`][pal-win-futex].
`futex_wake` returns whether it woke anyone, but "On some platforms, this always
returns false" — FreeBSD, DragonFly, Fuchsia and Windows cannot report it.

The seam also exports two word widths: `Futex`/`Primitive` (at least 32 bits)
and `SmallFutex`/`SmallPrimitive` ("at least 8-bits but may be larger"). On Unix
both are `u32`; on Windows `SmallPrimitive` is `u8` ([`pal/windows/futex.rs`
L17–L20][pal-win-small]), because `WaitOnAddress` accepts 1-, 2-, 4- and 8-byte
words — so the Windows `Mutex` and `Parker` are one byte.

| Platform                                | `Mutex`                           | `Condvar`              | `RwLock`            | `Once` | `Parker`                              |
| --------------------------------------- | --------------------------------- | ---------------------- | ------------------- | ------ | ------------------------------------- |
| Linux, Android, Free/Open/DragonFly BSD | futex                             | futex                  | futex               | futex  | futex                                 |
| Windows 8+ (`WaitOnAddress`)            | futex (`u8`)                      | futex                  | futex               | futex  | futex (`u8`)                          |
| Wasm with `atomics`, Hermit, Motor      | futex                             | futex                  | futex               | futex  | futex                                 |
| Fuchsia                                 | PI mutex on `zx_futex` with owner | futex                  | futex               | futex  | futex                                 |
| Darwin (macOS, iOS, …)                  | lazily boxed `pthread_mutex_t`    | boxed `pthread_cond_t` | queue (`Node` list) | queue  | `dispatch_semaphore`                  |
| NetBSD, other Unix                      | lazily boxed `pthread_mutex_t`    | boxed `pthread_cond_t` | queue               | queue  | `_lwp_park` (NetBSD) / pthread        |
| Windows 7 (`win7` vendor)               | `SRWLOCK`                         | `CONDITION_VARIABLE`   | queue               | queue  | `WaitOnAddress`, else NT keyed events |

## Analysis

### State word and fast path

The futex `Mutex` is one `SmallFutex` with three states
([`mutex/futex.rs` L11–L13][mutex-states]):

```rust
const UNLOCKED: State = 0;
const LOCKED: State = 1; // locked, no other threads waiting
const CONTENDED: State = 2; // locked, and other threads waiting (contended)
```

`lock` is one `compare_exchange(UNLOCKED, LOCKED, Acquire, Relaxed)`;
`unlock` is one `swap(UNLOCKED, Release)` followed by a `futex_wake` only if the
old value was `CONTENDED` ([L89–L97][mutex-unlock]). This is the same protocol as glibc's `lll_lock`
([glibc NPTL](./glibc-nptl.md#state-word-and-fast-path)). A woken thread
re-acquires with `swap(CONTENDED)`, never `LOCKED`, so "any other waiting threads
will also be woken up eventually" — the cost is one redundant `futex_wake` by the
last unlocker.

The futex `RwLock` is a 32-bit `state` (30-bit reader count, `0x3FFF_FFFF` =
write-locked, bit 30 `READERS_WAITING`, bit 31 `WRITERS_WAITING`) plus a second
32-bit `writer_notify` counter ([`rwlock/futex.rs` L4–L24][rwlock-futex]). Read
lock is a CAS that adds 1; write lock is `compare_exchange_weak(0, WRITE_LOCKED)`.

The queue `RwLock` (non-futex platforms) is a single `AtomicPtr` whose low four
bits are `LOCKED`, `QUEUED`, `QUEUE_LOCKED`, `DOWNGRADED`; the rest is either a
reader count (in units of `SINGLE = 1 << 4`) or a pointer to the head waiter
`Node`, whose `#[repr(align(16))]` frees those bits ([`rwlock/queue.rs`
L41–L53, L128–L135][rwlock-queue]).

`Once` (futex variant) packs four states and a `QUEUED` bit into one word, and
picks `COMPLETE = 0` so "the `is_completed` check can be a bit faster on some
platforms" — the fast path is one `load(Acquire) == 0`
([`once/futex.rs` L7–L33][once-futex]).

### Waiting: spin, yield, park

Spinning is a fixed, non-adaptive count of 100 `spin_loop()` hints (a `pause` on
x86), reading with relaxed loads only ([`mutex/futex.rs` L68–L84][mutex-spin]):

```rust
fn spin(&self) -> State {
    let mut spin = 100;
    loop {
        // We only use `load` (and not `swap` or `compare_exchange`)
        // while spinning, to be easier on the caches.
        let state = self.futex.load(Relaxed);
        // We stop spinning when the mutex is UNLOCKED,
        // but also when it's CONTENDED.
        if state != LOCKED || spin == 0 {
            return state;
        }
        crate::hint::spin_loop();
        spin -= 1;
    }
}
```

The spin stops early on `CONTENDED`: if someone is already parked, spinning only
competes with a hand-over that is about to happen. The thread spins again after
every wake-up. The futex `RwLock` uses the same 100 ("Chosen by fair dice roll.",
[`rwlock/futex.rs` L335][rwlock-spin]), stopping writers when a writer is waiting
"to keep things somewhat fair". The queue `RwLock` instead uses exponential
backoff — `SPIN_COUNT = 7`, i.e. `2^7 − 1 = 127` hints in total — and only while
no thread is queued ([L137–L141, L374–L383][rwlock-queue-spin]). There is no
`sched_yield` anywhere.

The spin was the one open question in 2022: "It's simple to add it, but some of
the most used implementations don't do it. It works out well in benchmarks, but
how it works out in realistic programs is questionable"
([#93740 comment][c-decisions]). The Windows port kept it with doubt: "I _think_
we're maybe spinning a bit much. `WaitOnAddress` seems to be looping quite a bit
too" ([#121956][pr121956]).

### The parking substrate

On futex platforms the waiter blocks on the lock word itself and the kernel (or
`ntdll`'s `RtlWaitOnAddress`) owns the queue. `futex_wait` on Linux uses
`FUTEX_WAIT_BITSET | FUTEX_PRIVATE_FLAG` with a full mask so it can pass an
absolute `CLOCK_MONOTONIC` deadline, and loops on `EINTR`; FreeBSD uses
`_umtx_op(UMTX_OP_WAIT_UINT_PRIVATE)` with `UMTX_ABSTIME`
([`pal/unix/futex.rs` L29–L95][pal-unix-futex-wait]).

Elsewhere waiter records live **on the waiting thread's stack**: the queue
`RwLock`'s `Node { next, prev, tail, write, thread, completed }` and the queue
`Once`'s `Waiter { thread, signaled, next }` are linked lock-free into the state
pointer; the waker sets `completed`/`signaled` with `Release` and calls
`Thread::unpark` ([`rwlock/queue.rs` L170–L250][rwlock-node]). Each thread owns
one `Parker` — a 3-state word (`EMPTY`, `NOTIFIED`, `PARKED`) over the futex
([`thread_parking/futex.rs`][parking-futex]), a `dispatch_semaphore` on Darwin
([`thread_parking/darwin.rs`][parking-darwin]), or an `_lwp_park` thread id
([`thread_parking/id.rs`][parking-id]). Darwin's parker explains why it is not a
futex:

> Darwin actually has futex syscalls (`__ulock_wait`/`__ulock_wake`), but they
> cannot be used in `std` because they are non-public (their use will lead to
> rejection from the App Store).

PR [#122408][pr122408] (opened 2024-03-12, still open at the pinned SHA)
proposes moving every Darwin primitive except `Mutex` onto the public
`os_sync_wait_on_address` (macOS 14.4) with `__ulock` as the fallback; see
[Darwin ulock](./darwin-ulock.md).

### Fairness, handoff and starvation

None of the primitives hands off. The mutex barges: an unlocker stores
`UNLOCKED` and wakes one thread, which must win a `swap(CONTENDED)` against any
spinner; there is no starvation bound and no fairness timer (contrast
[Go](./go-sync.md)'s 1 ms switch and [parking_lot](./parking-lot.md)'s eventual
fairness). The queue `RwLock` says so outright: "unfair, which reduces
context-switching and thus drastically improves performance", while still
waking "the tail node first (FIFO ordering)" ([`rwlock/queue.rs` L25–L33,
L68–L69][rwlock-queue]).

Writer starvation was the one fairness property the team insisted on. The futex
`RwLock` blocks new readers whenever either waiting bit is set
(`is_read_lockable`), and on unlock wakes one writer before any reader; it falls
back to waking readers only if `futex_wake` reports no writer was blocked
([`rwlock/futex.rs` L264–L330][rwlock-wake]). On FreeBSD/DragonFly `futex_wake`
always returns `false`, so readers are woken too — "That still results in
correct behavior". `downgrade` lets readers past waiting writers, deliberately.

### Condition variables and predicates

The futex `Condvar` is one 32-bit sequence counter — the sequence-counter
design at its minimum
([`condvar/futex.rs`][condvar-futex]):

```rust
unsafe fn wait_optional_timeout(&self, mutex: &Mutex, timeout: Option<Duration>) -> bool {
    // Examine the notification counter _before_ we unlock the mutex.
    let futex_value = self.futex.load(Relaxed);
    // Unlock the mutex before going to sleep.
    mutex.unlock();
    // Wait, but only if there hasn't been any
    // notification since we unlocked the mutex.
    let r = futex_wait(&self.futex, futex_value, timeout);
    // Lock the mutex again.
    mutex.lock();
    r
}
```

`notify_one` is `fetch_add(1)` + `futex_wake`; `notify_all` is `fetch_add(1)` +
`futex_wake_all`. All orderings are `Relaxed` "because synchronization is done by
unlocking and locking the mutex". There is no requeue and no
[wait morphing](./concepts.md#wait-morphing): `notify_all` wakes every waiter to
contend on the mutex (a [thundering herd](./concepts.md#thundering-herd)), which
the team accepted. Two documented holes: a waiter that misses exactly 2^32
notifications between its load and its `futex_wait` sleeps through the next one,
and [spurious wakeups](./concepts.md#spurious-wakeups) are permitted (any
`notify` wakes waiters that arrived after it). There are no predicate waits;
`Condvar::wait_while` is a loop in the public layer.

On pthread platforms `Condvar` wraps `pthread_cond_t`; on Darwin `wait_timeout`
uses `pthread_cond_timedwait_relative_np` for a monotonic clock and clamps the
timeout to `u64::MAX` ns because the "psynch" condvar overflows during the
conversion ([`pal/unix/sync/condvar.rs` L84–L116][pal-unix-condvar]).

### Footprint and layout

| Primitive (futex platforms)         | Size                                                  |
| ----------------------------------- | ----------------------------------------------------- |
| `sys::Mutex`, `sys::Parker`         | 4 B (`u32`); 1 B on Windows (`u8`)                    |
| `sys::Condvar`                      | 4 B                                                   |
| `sys::RwLock` (futex)               | 8 B (`state` + `writer_notify`)                       |
| `sys::RwLock` (queue), queue `Once` | one pointer; 16-byte-aligned `Node`s on waiter stacks |
| `sys::Mutex` (pthread)              | one pointer (`OnceBox`) + a heap `pthread_mutex_t`    |

The public `std::sync::Mutex<T>` adds a poison `Flag` (an `AtomicBool`, only
under `panic = "unwind"`) before the `UnsafeCell<T>`
([`sync/poison/mutex.rs` L227][pub-mutex]). Nothing is cache-line padded. The
pthread variants allocate lazily through `OnceBox` — "If the initialization race
is lost, the new mutex is destroyed" — which is how [#97647][pr97647] made
`Mutex::new` `const` without giving up pthread on Darwin
([`mutex/pthread.rs`][mutex-pthread]).

### Portability

The per-OS seam is the portable part. Every futex backend reduces to "wait if
`*addr == expected`, wake one / all": Linux `futex`, FreeBSD `_umtx_op`, OpenBSD
`futex`, DragonFly `umtx_sleep`/`umtx_wakeup`, Fuchsia `zx_futex_wait`,
Emscripten `emscripten_futex_wait`, Windows `WaitOnAddress`/`WakeByAddress*`.
Differences surface as documented degradations, not branches in the lock code:
DragonFly rounds timeouts up to 1 ms; OpenBSD and DragonFly take relative
timeouts; four OSes cannot report a wake count. Fuchsia keeps a separate
priority-inheriting mutex that stores the owner's handle in the word "Fuchsia's
futex operations support setting an owner thread for a futex, which can boost
that thread's priority" ([`mutex/fuchsia.rs`][mutex-fuchsia]).

The pthread mutex is created `PTHREAD_MUTEX_NORMAL` explicitly, because with the
default type glibc's lock elision made re-locking appear to succeed, yielding
two aliasing `&mut` ([`pal/unix/sync/mutex.rs` L29–L46][pal-unix-mutex]).

Windows took two steps: first unboxed `SRWLOCK` (2020–2021), then
[#121956][pr121956] (2024-03-06) replaced SRW locks with the same futex
algorithms on `WaitOnAddress`, keeping SRW only for the `win7` target.

### Async and fiber integration

None. Every wait blocks the OS thread; there is no hook for a task to wait on a
lock word, and `Condvar` cannot be awaited. The futex seam is private
(`crate::sys::futex`). Async Rust gets its locks from separate crates
([tokio](./tokio-sync.md), [async-lock](./smol-event-listener.md)) that
reimplement waiting on top of `Waker`s rather than reusing std's word protocol.

## Strengths

- Smallest possible state: 4-byte mutex and condvar, 1-byte mutex on Windows,
  `const` constructible, no allocation on futex platforms.
- One algorithm per primitive across nine futex-like OS calls; the seam is three
  functions plus two word widths.
- The rationale is public and dated: the tracking issue links comparative
  reviews of musl, glibc, Boost, Windows SRW, Wine, Darwin libpthread and
  FreeBSD libthr before the design was chosen.
- The queue `RwLock` gives non-futex platforms an allocation-free, pointer-sized
  lock that needs only a thread parker.
- Uncontended unlock is a single `swap` and no syscall.

## Weaknesses

- No fairness bound: a barging mutex can starve a woken waiter indefinitely.
- `notify_all` wakes every waiter onto the mutex; no requeue.
- Fixed spin of 100 with no adaptation and no measurement behind the number
  ("Chosen by fair dice roll").
- Darwin is a second implementation family (pthread + queue), so behaviour and
  footprint differ on the platform with the most aggressive scheduler QoS.
- The futex `Condvar` can, in principle, lose a wake-up after 2^32 notifications.
- Nothing integrates with async runtimes or fibers.

## Key design decisions and trade-offs

| Decision                                       | Rationale                                                                  | Trade-off                                                                |
| ---------------------------------------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| 3-state futex word, kernel owns the queue      | "simple and easy to implement and verify"; kernel debugging tools apply    | needs a futex; no user-space control over wake order or fairness         |
| No global parking table                        | the allocator may itself take a `std` lock: bootstrap cycle                | locks on non-futex OSes are pointer-sized, not 1 byte                    |
| SRW-style stack-node queue for non-futex OSes  | needs only a thread parker, no global state                                | complex lock-free list (`QUEUE_LOCKED`, backlinks, tail cache)           |
| Keep `pthread` mutex on Darwin                 | preserve priority inheritance of the native lock; `__ulock` is private API | lazy `Box`, a second code path, no futex `Condvar`                       |
| Sequence-counter `Condvar`, wake-all broadcast | requeue judged unnecessary; spurious wakeups allowed                       | thundering herd on `notify_all`; 2^32 ABA hole                           |
| Fixed 100-iteration spin, stop on `CONTENDED`  | cheap win in benchmarks                                                    | unmeasured in real programs; no backoff, no adaptation                   |
| Writer-preferring `RwLock`                     | "Avoiding writer starvation in RwLock is important"                        | readers block behind any waiting writer; `downgrade` is the escape hatch |
| `u8` futex words on Windows                    | `WaitOnAddress` takes 1–8-byte words                                       | the seam has two widths; Linux cannot follow (32-bit futex only)         |

## Sources

- `rust-lang/rust` source at [`3bf5c6d99bc8`][rust-repo]: the files listed in the
  metadata table.
- Tracking issue [#93740][i93740], "Tracking Issue for improving
  std::sync::{Mutex, RwLock, Condvar}", opened 2022-02-07 by Mara Bos
  (`m-ou-se`), and its [design-decisions comment][c-decisions] (2022-03-17).
- PRs: [#76919][pr76919] futex thread parker (2020-10-01), [#95035][pr95035]
  futex `Mutex`/`Condvar` (2022-04-05), [#95801][pr95801] futex `RwLock`
  (2022-04-12), [#96510][pr96510] \*BSD (2022-05-06), [#97647][pr97647] lazy
  pthread allocation (2022-06-04), [#97791][pr97791] `const fn new`
  (2022-06-19), [#110211][pr110211] queue `RwLock` by `joboet`
  (2024-02-12), [#121956][pr121956] Windows futex by Chris Denton
  (2024-03-06), [#122408][pr122408] Darwin futex (open).

> [!NOTE]
> The `rust-lang/rust` clone is shallow, so merge dates come from the GitHub
> API for each PR rather than `git log`. The Darwin `pthread_mutex_t` size is
> not stated because Darwin's libpthread was not read.

<!-- References -->

[rust-repo]: https://github.com/rust-lang/rust/tree/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21
[mutex-futex]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/sync/mutex/futex.rs
[mutex-states]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/sync/mutex/futex.rs#L11-L13
[mutex-unlock]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/sync/mutex/futex.rs#L89-L97
[mutex-spin]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/sync/mutex/futex.rs#L68-L84
[mutex-mod]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/sync/mutex/mod.rs
[mutex-pthread]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/sync/mutex/pthread.rs
[mutex-fuchsia]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/sync/mutex/fuchsia.rs#L1-L9
[condvar-futex]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/sync/condvar/futex.rs
[condvar-mod]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/sync/condvar/mod.rs
[rwlock-futex]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/sync/rwlock/futex.rs#L4-L24
[rwlock-wake]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/sync/rwlock/futex.rs#L264-L330
[rwlock-spin]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/sync/rwlock/futex.rs#L332-L358
[rwlock-queue]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/sync/rwlock/queue.rs#L1-L135
[rwlock-queue-spin]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/sync/rwlock/queue.rs#L359-L383
[rwlock-node]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/sync/rwlock/queue.rs#L170-L250
[rwlock-mod]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/sync/rwlock/mod.rs
[once-futex]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/sync/once/futex.rs#L7-L33
[once-queue]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/sync/once/queue.rs
[once-mod]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/sync/once/mod.rs
[parking-mod]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/sync/thread_parking/mod.rs
[parking-futex]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/sync/thread_parking/futex.rs
[parking-darwin]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/sync/thread_parking/darwin.rs#L1-L11
[parking-id]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/sync/thread_parking/id.rs
[pal-unix-futex]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/pal/unix/futex.rs
[pal-unix-futex-wait]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/pal/unix/futex.rs#L29-L95
[pal-win-futex]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/pal/windows/futex.rs
[pal-win-small]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/pal/windows/futex.rs#L17-L20
[pal-unix-mutex]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/pal/unix/sync/mutex.rs#L29-L46
[pal-unix-condvar]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/pal/unix/sync/condvar.rs#L84-L116
[pub-mutex]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sync/poison/mutex.rs#L227-L231
[i93740]: https://github.com/rust-lang/rust/issues/93740
[c-decisions]: https://github.com/rust-lang/rust/issues/93740#issuecomment-1070696128
[pr76919]: https://github.com/rust-lang/rust/pull/76919
[pr95035]: https://github.com/rust-lang/rust/pull/95035
[pr95801]: https://github.com/rust-lang/rust/pull/95801
[pr96510]: https://github.com/rust-lang/rust/pull/96510
[pr97647]: https://github.com/rust-lang/rust/pull/97647
[pr97791]: https://github.com/rust-lang/rust/pull/97791
[pr110211]: https://github.com/rust-lang/rust/pull/110211
[pr121956]: https://github.com/rust-lang/rust/pull/121956
[pr122408]: https://github.com/rust-lang/rust/pull/122408
