# Zig `std.Io` synchronization (Zig)

Zig moved every blocking primitive into the `std.Io` interface in February
2026: `Mutex`, `Condition`, `Event`, `Semaphore` and `RwLock` are plain atomic
words whose only blocking operation is `io.futexWait`/`io.futexWake`, a virtual
call into whichever `Io` implementation the caller holds — a thread pool that
uses the OS futex, an `io_uring` fiber scheduler that submits
`IORING_OP_FUTEX_WAIT`, or a libdispatch scheduler with a hashed table of its
own. It is the one surveyed standard library whose locks can park a fiber.

|                       |                                                                                                                                                                                                                                                                                                                                                                                                                  |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**              | language standard library                                                                                                                                                                                                                                                                                                                                                                                        |
| **Language**          | Zig                                                                                                                                                                                                                                                                                                                                                                                                              |
| **License**           | MIT                                                                                                                                                                                                                                                                                                                                                                                                              |
| **Repository**        | [`ziglang/zig`][zig-repo] (Codeberg) at `1bcd8d9fe60f` (2026-06-02, `0.16.0-770`, development toward 0.17.0)                                                                                                                                                                                                                                                                                                     |
| **Primitives**        | `Io.Mutex`, `Io.Condition`, `Io.Event` (formerly `std.Thread.ResetEvent`), `Io.Semaphore`, `Io.RwLock`, `Io.Group` (formerly `WaitGroup`); the `futexWait`/`futexWake` vtable entries                                                                                                                                                                                                                            |
| **Parking substrate** | `Io.Threaded`: Linux `futex`, Darwin `__ulock_wait2`, FreeBSD `_umtx_op`, OpenBSD `futex`, DragonFly `umtx_sleep`, Wasm `memory.atomic.wait32`; Windows, NetBSD, illumos: a 256-bucket "parking futex" over `NtWaitForAlertByThreadId` / `_lwp_park`. `Io.Uring`: `IORING_OP_FUTEX_WAIT`. `Io.Dispatch`: a per-instance 256-entry table of dispatch queues                                                       |
| **Fairness**          | barging 3-state mutex, no spin, no hand-off                                                                                                                                                                                                                                                                                                                                                                      |
| **History**           | `std.Thread.Pool` deleted 2025-12-15 (`23e5a17187`); parking futex 2025-12-30 (`e57c557ad4`); `ResetEvent`/`WaitGroup` → `Io.Event`/`Io.Group` and all other `std.Thread` primitives deleted 2026-02-01 (`b191e50be5`, `550da1b676`); `ParkingMutex` 2026-02-03 (`6d6532dd9e`)                                                                                                                                   |
| **Source read**       | [`lib/std/Io.zig`][io-zig] (futex API, `Mutex`, `Condition`, `Event`), [`Io/Threaded.zig`][threaded] (OS futex backends, `parking_futex`, `ParkingMutex`, `park`/`unpark`), [`Io/Uring.zig`][uring-futex], [`Io/Dispatch.zig`][dispatch-futex], [`Io/Kqueue.zig`][kqueue], [`Io/RwLock.zig`][rwlock], [`Io/Semaphore.zig`][semaphore]; the deleted `lib/std/Thread/{Mutex,Futex,Condition}.zig` at `550da1b676^` |

## Overview

### What it solves

`std.Io` is Zig's answer to function colouring: one interface "that abstracts
all I/O operations and concurrency", explicitly including "mutexes, futexes,
events, and conditions" ([`Io.zig` L1–L14][io-head]). Code takes an `io: Io`
parameter and is agnostic about whether it runs on OS threads or on fibers.
Locks follow: a `Mutex.lock(io)` must suspend a fiber under an evented `Io`
and block a thread under `Io.Threaded`, so the lock cannot call the kernel
itself. The commit that finished the migration lists what went
([`550da1b676`][c-migrate], 2026-02-01, Andrew Kelley):

> - delete std.Thread.Futex
> - delete std.Thread.Mutex
> - delete std.Thread.Semaphore
> - delete std.Thread.Condition
> - delete std.Thread.RwLock
> - delete std.once

### Design philosophy

The primitive is the futex, raised to an interface method with
cancellation. The doc comment defines it in the conventional way
([`Io.zig` L1566–L1606][io-futex]):

> Atomically checks if the value at `ptr` equals `expected`, and if so, blocks
> until either: a matching (same `ptr` argument) `futexWake` call occurs, or a
> spurious ("random") wakeup occurs. […] The caller is responsible for
> identifying spurious wakeups if necessary, typically by checking the value at
> `ptr.*`.

Every primitive is then written once against `futexWait`/`futexWake`, and
every waiting operation comes in a cancelable form (a cancelation point
returning `error.Canceled`) and an `…Uncancelable` form. The word is exactly 4
bytes: "Asserts that `T` is 4 bytes in length".

Where the OS lacks a futex, Zig builds one from thread parking rather than from
pthread — the reverse of [Rust](./rust-std-sync.md)'s choice — and does so on
Windows too, replacing `RtlWaitOnAddress` ([`e57c557ad4`][c-parking]):

> Thread parking tends to be the primitive provided by systems which do not
> have a futex primitive, such as NetBSD, so this implementation is far more
> efficient than the pthread one. It is also useful on Windows, where
> `RtlWaitOnAddress` is itself a userland implementation based on thread
> park/unpark; we can implement it ourselves including support for features
> which Windows' implementation lacks, such as cancelation and waking a number
> of waiters with `1<n<infinity`.

## How it works

`Io` is `{ userdata, vtable }`; the vtable carries
`futexWait(userdata, *const u32, expected, Timeout) Cancelable!void`,
`futexWaitUncancelable` and `futexWake(userdata, ptr, max_waiters)`
([`Io.zig` L140–L142][io-vtable]). Three implementations matter:

| `Io` implementation    | `futexWait` becomes                                                                                                                                               | Waker side                                                             |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| `Io.Threaded`          | an OS wait on the calling thread ([`Threaded.zig` L940–L1103][t-wait])                                                                                            | OS wake, or the parking-futex bucket scan                              |
| `Io.Uring` (Linux)     | an `IORING_OP_FUTEX_WAIT` SQE (`FUTEX2` `U32`, private), optional `LINK_TIMEOUT`; the fiber yields ([`Uring.zig` L1921–L2006][uring-futex])                       | an `IORING_OP_FUTEX_WAKE` SQE on the caller's ring, `CQE_SKIP_SUCCESS` |
| `Io.Dispatch` (Darwin) | the fiber yields with a `Futex.Waiter` appended to one of 256 per-instance buckets, each a serial `dispatch_queue` ([`Dispatch.zig` L1489–L1690][dispatch-futex]) | a `Futex.Waker` posted to that bucket's queue                          |

`Io.Kqueue`'s vtable at this SHA has no `futexWait` entry ([`Kqueue.zig`
L610–L690][kqueue]); `Io.Evented` selects it for the BSDs.

## Analysis

### State word and fast path

`Io.Mutex` is an `extern struct` over one `u32` enum — `unlocked`,
`locked_once`, `contended` ([`Io.zig` L1613–L1677][io-mutex]):

```zig
pub fn lock(m: *Mutex, io: Io) Cancelable!void {
    const initial_state = m.state.cmpxchgStrong(.unlocked, .locked_once, .acquire, .monotonic) orelse {
        @branchHint(.likely);
        return;
    };
    if (initial_state == .contended) {
        try io.futexWait(State, &m.state.raw, .contended);
    }
    while (m.state.swap(.contended, .acquire) != .unlocked) {
        try io.futexWait(State, &m.state.raw, .contended);
    }
}
```

`unlock` is `swap(.unlocked, .release)` and calls `futexWake(…, 1)` only if the
old state was `contended`. The fast path never touches `io`; `tryLock` takes no
`io` at all. `Io.Threaded` exposes the same algorithm as free functions
`mutexLock`/`mutexUnlock` for code that has no `Io` ([`Threaded.zig`
L18862–L18890][t-mutexlock]).

The deleted `std.Thread.Mutex.FutexImpl` used the same three states but encoded
`contended = 0b11` "must contain the `locked` bit for x86 optimization" so
`tryLock` could be a `lock bts` instead of `lock cmpxchg`: "`lock bts` is
smaller instruction-wise which makes it better for inlining" (`Mutex.zig` at
[`550da1b676^`][old-mutex]). That micro-optimization did not survive the move.

`Io.Event` is a `u32` enum `unset`/`waiting`/`is_set`; `set` is an exchange to
`is_set` that wakes all only if the old value was `waiting` ([L1847–L1951][io-event]).

### Waiting: spin, yield, park

**No spinning.** `Io.Mutex.lock` goes straight from the failed CAS to
`futexWait`. Neither `Condition` nor `Event` spins. The only bounded retry loops
are CAS-retry loops. The deleted `std.Thread.Mutex` did not spin either; on
Darwin and Windows it delegated to `os_unfair_lock` and `SRWLOCK`, whose own
spinning is the OS's business ("`os_unfair_lock` on darwin supports priority
inheritance and is generally faster than Futex solutions"; "SRWLOCK on windows
is almost always faster than Futex solution", [`550da1b676^`][old-mutex]). The
migration dropped both, so on Darwin `Io.Threaded` locks now lose
`os_unfair_lock`'s priority donation.

### The parking substrate

`Io.Threaded` calls the OS directly ([`Threaded.zig` L940–L1103][t-wait]):
Linux `futex(FUTEX_WAIT | FUTEX_PRIVATE_FLAG)` with a relative timeout; Darwin
`__ulock_wait2(UL_COMPARE_AND_WAIT | ULF_NO_ERRNO)` on macOS 11+ (64-bit
nanosecond timeout) and `__ulock_wait` before (32-bit microseconds, `0` =
infinite, so a requested `0` becomes `1`) ([L14885–L14893][t-ulock2]);
FreeBSD `_umtx_op(UMTX_OP_WAIT_UINT_PRIVATE)`; OpenBSD `futex`; DragonFly
`umtx_sleep`; Wasm `memory.atomic.wait32`. Zig, unlike Rust, uses the private
`__ulock` API.

On Windows, NetBSD and illumos, `use_parking_futex` replaces the OS call with a
user-space futex ([L17375–L17380][t-use-parking]):

```zig
const use_parking_futex = switch (native_os) {
    .windows => true, // RtlWaitOnAddress is a userland implementation anyway
    .netbsd => true, // NetBSD has `futex(2)`, but it's historically been quite buggy. TODO: evaluate whether it's okay to use now.
    .illumos => true, // Illumos has no futex mechanism
    else => false,
};
```

`parking_futex` is a global 256-entry array of cache-line-aligned `Bucket`s —
"assuming a 128-byte `Bucket` (due to cache line alignment), this uses 32 KiB of
memory" — indexed by Fibonacci hashing of the address ([L17401–L17460][t-parking]).
Each bucket holds `num_waiters` (an atomic, so `wake` can return without
locking "to avoid having to acquire `mutex` to discover there are no waiters"),
a `ParkingMutex`, and an intrusive list of stack-allocated `Waiter`s carrying
`address`, `tid` and a pointer to the thread's cancellation status. `wait`
increments `num_waiters`, re-checks `*ptr == expect` under the bucket lock, and
parks. `wake` unlinks up to `max_waiters` matching waiters under the lock and
unparks them in batches of 128 outside it ([L17570–L17635][t-wake]). Because
`wake` emulates a release-load with `fetchAdd(0, .release)`, a store to the
futex word before `wake` is ordered before the `num_waiters` check.

The bucket lock is `ParkingMutex`: a pointer-sized word whose value is
`unlocked = 1`, `locked_once = 0`, or a pointer to the head of a stack of
contending `Waiter`s — a [WordLock](./parking-lot.md)-shaped queue lock built
directly on parking ([L17722–L17760][t-parking-mutex]).

`park` on Windows is `NtWaitForAlertByThreadId(addr_hint, timeout)`, and the
comment records why the address is passed at all ([L17899–L17930][t-park]):

> `RtlWaitOnAddress` passes the futex address in as the first argument to this
> call, but it's unclear what that actually does, especially since
> `NtAlertThreadByThreadId` does _not_ accept the address so the kernel can't
> really be using it as a hint. […] to err on the side of caution, let's match
> the behavior of `RtlWaitOnAddress` and pass the pointer, in case the kernel
> ever does something stupid such as trying to dereference it.

NetBSD's `park` loops on `_lwp_park` until a per-thread `unpark_flag` is
consumed, because `_lwp_park` can return spuriously (`6d6532dd9e`, "deal with
spurious unparks on NetBSD"). The same parking path implements `sleep` on these
OSes because `NtWaitForAlertByThreadId` "must reliably trigger this behavior
[unpark-before-park returns immediately] because `RtlWaitOnAddress` relies on
it" ([L17381–L17399][t-use-parking]). See
[Windows WaitOnAddress](./windows-wait-on-address.md).

### Fairness, handoff and starvation

Pure barging. A woken waiter races `swap(.contended)` against newcomers; there
is no hand-off, no FIFO guarantee, no starvation bound. The parking futex wakes
bucket waiters in list order (append on wait, scan from head on wake), so it is
FIFO per address within a bucket, but the lock built on it is not.

### Condition variables and predicates

`Io.Condition` is two words: `state`, a packed `{ waiters: u16, signals: u16 }`,
and `epoch: u32`, the futex word "Incremented whenever the condition is
signaled" ([L1679–L1844][io-cond]). A waiter loads `epoch`, increments
`waiters`, unlocks the mutex, and `futexWait`s on `epoch`. On every wake-up —
including timeout or cancellation — it first tries to consume a signal by
CAS-decrementing both counters: "Even on error, try to consume a pending signal
first. Otherwise a race might cause a signal to get stuck in the state with no
corresponding waiter." `signal` increments `signals` only while
`waiters > signals`, then bumps `epoch` and wakes one; `broadcast` sets
`signals = waiters` and wakes `waiters − signals`. Signals are therefore tokens
counted against registered waiters: a waiter that registers after a signal can
consume it (no eligibility ordering, unlike [glibc](./glibc-nptl.md#condition-variables-and-predicates)),
and the 2^32 ABA on `epoch` is accepted ("extraordinarily unlikely due to the
precise number of calls required"). At most 65 535 concurrent waiters (`u16`,
asserted). No requeue: `broadcast` wakes all onto the mutex. `waitTimeout`
re-acquires the mutex with `lockUncancelable` in a `defer`, so cancellation
never leaves the caller without the lock.

`Io.Semaphore` is `Mutex` + `Condition` + `permits: usize`
([`Semaphore.zig`][semaphore]); `Io.RwLock` is a `usize` state (writer count,
reader count, `is_writing`) plus an `Io.Mutex` that writers hold and an
`Io.Semaphore` readers drain through ([`RwLock.zig`][rwlock]) — the classic
"mutex + reader counter" construction, not a dedicated futex rwlock. There are
no predicate waits.

### Footprint and layout

| Type                   | Size                                                              |
| ---------------------- | ----------------------------------------------------------------- |
| `Io.Mutex`, `Io.Event` | 4 B                                                               |
| `Io.Condition`         | 8 B                                                               |
| `Io.Semaphore`         | 4 + 8 + 8 = 20 B before padding (24 B on 64-bit)                  |
| `Io.RwLock`            | `usize` + `Mutex` + `Semaphore`                                   |
| parking-futex table    | 256 × one cache line, static (32 KiB per its comment)             |
| `Io.Dispatch` table    | 256 `Futex` buckets per `Evented` instance, each a dispatch queue |

All are statically initializable (`.init`), need no `deinit`, and none pads to a
cache line; only the parking-futex buckets do, "to prevent false sharing
between buckets".

### Portability

The lock algorithms have no platform branches; portability lives entirely in
`Thread.futexWaitInner`/`futexWake` and in `park`/`unpark`. The per-OS quirks
it absorbs: Darwin `EFAULT` when the page is paged out ("pthread/libdispatch on
darwin bother to handle it"), FreeBSD relative timeouts with `CLOCK_MONOTONIC`,
DragonFly's `EAGAIN` "maybe timed out, or paged out, or hit 2s kernel refresh",
OpenBSD `ECANCELED` under `SA_RESTART`. illumos `park` is
`@panic("TODO: illumos lwp_park")` at this SHA. A batch-unpark path for Windows
11 (`NtAlertMultipleThreadByThreadId`) is written but disabled "because
mingw-w64 does not contain this symbol" ([L17968–L17975][t-unpark]).

### Async and fiber integration

This is the defining property. The same `Io.Mutex` value parks a thread under
`Io.Threaded` and suspends a fiber under `Io.Uring`/`Io.Dispatch`, because the
lock only ever calls `io.futexWait`. Two distinct designs sit behind that one
call:

- **`Io.Uring` delegates to the kernel futex.** `futexWait` enqueues
  `IORING_OP_FUTEX_WAIT` with `user_data` = the fiber, links an optional
  `IORING_OP_LINK_TIMEOUT`, and yields; the CQE resumes the fiber
  ([`Uring.zig` L1921–L2006][uring-futex]). `futexWake` submits
  `IORING_OP_FUTEX_WAKE` on the calling thread's ring with
  `IOSQE_CQE_SKIP_SUCCESS` ([L2042–L2063][uring-wake]). Since both sides are the
  kernel's futex hash, a fiber waiting through the ring is woken by a plain
  `futex(FUTEX_WAKE)` from any thread, and vice versa — the cross-world wake is
  free.
- **`Io.Dispatch` keeps a private table.** Waiters live in one of 256 buckets of
  _that_ `Evented` instance, serialized by a dispatch queue per bucket, with a
  dispatch timer source for timeouts ([`Dispatch.zig` L1489–L1560][dispatch-futex-struct]).
  A `futexWake` issued through a different `Io` (or by the OS) cannot see them:
  both sides must use the same `Io`. `futexWake` checks the bucket's
  `num_waiters` with a release-RMW before yielding to post the waker.

Cancellation is first-class: a fiber or thread blocked in a cancelable
`futexWait` is removed from its bucket (`removeCanceledWaiter`) and unparked
when its task is canceled ([`Threaded.zig` L1199–L1225][t-cancel]).

## Strengths

- One lock implementation works for threads and fibers; the futex is an
  interface method, not a syscall.
- Under `io_uring`, fiber waits and thread wakes meet in the kernel futex table:
  no user-space registry, no cross-thread signalling protocol.
- Cancellation and timeouts on every wait, including inside `Condition.wait`.
- The parking futex gives Windows and NetBSD a futex with features the OS lacks
  (wake-_n_, cancellation) in ~250 lines, with no pthread underneath.
- 4-byte mutex, 8-byte condition, all statically initializable.

## Weaknesses

- No spinning at all: every contended acquire is a futex round-trip (or, under
  `Io.Uring`, an SQE and a fiber switch).
- Barging with no starvation bound.
- `Io.Dispatch`'s futex table is per instance: two `Io`s cannot wake each
  other's waiters through a shared word.
- `Io.Kqueue` has no futex entries at this SHA; illumos parking is a `@panic`.
- Darwin locks lost `os_unfair_lock`'s priority inheritance in the migration.
- `Condition` caps waiters at 65 535 and lets late waiters steal signals.
- The API is young (February 2026) and still churning.

## Key design decisions and trade-offs

| Decision                                                   | Rationale                                                                   | Trade-off                                                                    |
| ---------------------------------------------------------- | --------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Futex as an `Io` vtable method                             | locks become executor-agnostic; one `Mutex` for threads and fibers          | every slow path is an indirect call; the lock needs an `io` argument         |
| Delete `std.Thread.{Mutex,Condition,Futex,…}`              | a single set of primitives, all cancelable                                  | lost the `SRWLOCK` and `os_unfair_lock` backends and their OS-level features |
| Parking futex on Windows instead of `RtlWaitOnAddress`     | `RtlWaitOnAddress` is user-space anyway; gain cancelation and wake-_n_      | Zig now owns a hashed waiter table and its correctness                       |
| `IORING_OP_FUTEX_WAIT` under `Io.Uring`                    | fibers and threads share the kernel futex namespace                         | needs Linux 6.7+ `io_uring` futex ops; one SQE per contended wait            |
| Per-instance futex table under `Io.Dispatch`               | libdispatch has no futex opcode; serial queues give lock-free bucket access | waiters invisible to any other `Io` or to OS futex wakes                     |
| No spin                                                    | simplicity; under fibers a spin burns the loop thread                       | short critical sections pay a full park/unpark                               |
| Token-counting `Condition` (`waiters`, `signals`, `epoch`) | no lost signals across cancel/timeout; two words                            | no eligibility ordering; `u16` waiter cap; broadcast herd                    |
| Use private `__ulock_wait2` on Darwin                      | it is the only futex Darwin offered before macOS 14.4                       | private API (Rust rejects it for App Store reasons)                          |

## Sources

- `ziglang/zig` at [`1bcd8d9fe60f`][zig-repo]: [`lib/std/Io.zig`][io-zig],
  [`lib/std/Io/Threaded.zig`][threaded], [`lib/std/Io/Uring.zig`][uring-futex],
  [`lib/std/Io/Dispatch.zig`][dispatch-futex], [`lib/std/Io/Kqueue.zig`][kqueue],
  [`lib/std/Io/RwLock.zig`][rwlock], [`lib/std/Io/Semaphore.zig`][semaphore].
- Commits: [`550da1b676`][c-migrate] "std: migrate remaining sync primitives to
  Io" (Andrew Kelley, 2026-02-01); [`b191e50be5`][c-event] "std.Thread: remove
  ResetEvent and WaitGroup" (2026-02-01); [`e57c557ad4`][c-parking]
  "std.Io.Threaded: hugely improve Windows and NetBSD support" (Matthew Lugg,
  2025-12-30); [`6d6532dd9e`][c-parking-mutex] "Io.Threaded: add ParkingMutex,
  and deal with spurious unparks on NetBSD" (2026-02-03); [`23e5a17187`][c-pool]
  "std: delete Thread.Pool in favour of Io" (2025-12-15).
- The pre-migration `lib/std/Thread/Mutex.zig` at [`550da1b676^`][old-mutex].

> [!NOTE]
> Zig's canonical repository moved to Codeberg; citations use Codeberg URLs
> pinned to the commit. The `Io.Kqueue` futex gap is read from its vtable
> literal at this SHA, not from a build; the BSD evented backend may be
> incomplete rather than deliberately futex-less.

<!-- References -->

[zig-repo]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa
[io-zig]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io.zig
[io-head]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io.zig#L1-L14
[io-vtable]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io.zig#L140-L142
[io-futex]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io.zig#L1566-L1606
[io-mutex]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io.zig#L1613-L1677
[io-cond]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io.zig#L1679-L1844
[io-event]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io.zig#L1847-L1951
[threaded]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io/Threaded.zig
[t-wait]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io/Threaded.zig#L940-L1103
[t-cancel]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io/Threaded.zig#L1199-L1225
[t-ulock2]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io/Threaded.zig#L14885-L14893
[t-use-parking]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io/Threaded.zig#L17375-L17399
[t-parking]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io/Threaded.zig#L17401-L17460
[t-wake]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io/Threaded.zig#L17570-L17635
[t-parking-mutex]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io/Threaded.zig#L17722-L17760
[t-park]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io/Threaded.zig#L17899-L17966
[t-unpark]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io/Threaded.zig#L17968-L17975
[t-mutexlock]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io/Threaded.zig#L18862-L18890
[uring-futex]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io/Uring.zig#L1921-L2006
[uring-wake]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io/Uring.zig#L2042-L2063
[dispatch-futex]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io/Dispatch.zig#L1489-L1690
[dispatch-futex-struct]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io/Dispatch.zig#L1489-L1560
[kqueue]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io/Kqueue.zig#L610-L690
[rwlock]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io/RwLock.zig
[semaphore]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io/Semaphore.zig
[old-mutex]: https://codeberg.org/ziglang/zig/src/commit/255aeb57b24bc24b604744460a61ebf7c44e42ea/lib/std/Thread/Mutex.zig
[c-migrate]: https://codeberg.org/ziglang/zig/commit/550da1b676d059ae39a629d60da0f9cd155a5e89
[c-event]: https://codeberg.org/ziglang/zig/commit/b191e50be58cde6589a70410fb2f40ec43d0ffad
[c-parking]: https://codeberg.org/ziglang/zig/commit/e57c557ad41188f85984cb8e6b79c8432cb95ec2
[c-parking-mutex]: https://codeberg.org/ziglang/zig/commit/6d6532dd9eb862dfd6e59ceed5c762342d2cc0d5
[c-pool]: https://codeberg.org/ziglang/zig/commit/23e5a17187dc3a1f61dcb40b681f6730334d3667
