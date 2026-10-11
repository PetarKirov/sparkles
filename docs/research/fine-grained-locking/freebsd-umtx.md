# FreeBSD `_umtx_op`

FreeBSD's one multiplexed synchronisation syscall, `_umtx_op(obj, op, val,
uaddr, uaddr2)`: a futex-shaped `UMTX_OP_WAIT`/`WAKE` pair (plus 32-bit and
process-private variants) beside kernel-implemented mutex, condvar, rwlock and
semaphore operations, all sharing one hashed table of sleep queues. libthr
builds POSIX threads on it — and, notably, keeps its own user-space hashed
sleep queue for condition variables, waking deferred waiters in batches with
`UMTX_OP_NWAKE_PRIVATE`.

|                     |                                                                                                                                                                                                                                                                                                                                                                 |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**            | kernel mechanism (OS wait primitive) + the libthr consumer                                                                                                                                                                                                                                                                                                      |
| **Language**        | C                                                                                                                                                                                                                                                                                                                                                               |
| **License**         | BSD-2-Clause                                                                                                                                                                                                                                                                                                                                                    |
| **Repository**      | [`freebsd/freebsd-src`][freebsd] at `7c75c96d176f` (`main`, 2026-10-11)                                                                                                                                                                                                                                                                                         |
| **Word sizes**      | `long` (`UMTX_OP_WAIT`: 8 bytes on LP64) or `u_int` (`UMTX_OP_WAIT_UINT*`: 4 bytes)                                                                                                                                                                                                                                                                             |
| **Process scope**   | `WAIT`/`WAKE` and `WAIT_UINT` choose by mapping (`AUTO_SHARE`); `*_PRIVATE` force process-private                                                                                                                                                                                                                                                               |
| **Event-loop hook** | none; kqueue's `EVFILT_USER` is the bridge                                                                                                                                                                                                                                                                                                                      |
| **Source read**     | [`sys/kern/kern_umtx.c`][kern-umtx], [`sys/sys/umtx.h`][umtx-h], [`sys/sys/_umtx.h`][umtx-time], [`sys/sys/umtxvar.h`][umtxvar], [`sys/sys/event.h`][event-h]; libthr [`thr_umtx.c`][thr-umtx], [`thr_cond.c`][thr-cond], [`thr_sleepq.c`][thr-sleepq], [`thr_kern.c`][thr-kern], [`thr_mutex.c`][thr-mutex]; the [`_umtx_op(2)`][man-umtx] manual (2020-11-23) |

## Overview

### What it solves

The manual's framing ([`_umtx_op(2)`][man-umtx]): "The `_umtx_op()` system call
provides kernel support for userspace implementation of the threading
synchronization primitives. The 1:1 Threading Library (libthr, -lthr) uses the
syscall to implement IEEE Std 1003.1-2001 ("POSIX.1") pthread locks". The
futex-shaped core is `UMTX_OP_WAIT`:

> The comparison and sleep are atomic. In other words, if another thread
> writes a new value to \*obj and then issues UMTX_OP_WAKE, the request is
> guaranteed to not miss the wakeup, which might otherwise happen between
> comparison and blocking.

### Design philosophy

Unlike Linux, FreeBSD moved whole lock protocols into the kernel:
`UMTX_OP_MUTEX_LOCK` writes the owner TID into `struct umutex` itself,
`UMTX_OP_CV_WAIT` unlocks the mutex and sleeps atomically, and
`UMTX_OP_SEM2_WAIT`, `UMTX_OP_RW_*` and robust lists live there too. The simple
`WAIT`/`WAKE` pair is the escape hatch for everything else. The sleep-queue key
carries a **type**, so "The sleep queue to which a sleeping thread is
assigned is an individual one for simple wait requests, mutexes, rwlocks,
condvars and other primitives, even when the physical address of the key is
same" ([`_umtx_op(2)`][man-umtx]).

## How it works

**Keys.** [`umtx_key_get`][kern-umtx-key] yields either a private key
`(vmspace, address)` or, after a `vm_map_lookup`, a shared key
`(VM object, offset)` with a reference on the object. `THREAD_SHARE` (the
`*_PRIVATE` ops) skips the map lookup entirely; `AUTO_SHARE` (plain `WAIT`,
`WAIT_UINT`, `WAKE`) uses the shared key only if the mapping's inheritance is
`VM_INHERIT_SHARE`.

**Chains.** `static struct umtxq_chain umtxq_chains[2][UMTX_CHAINS]` with
`UMTX_CHAINS` = 512 ([`kern_umtx.c`][kern-umtx-chains]); the second index
separates simple/semaphore keys from lock keys. The hash is
`((a + b) * GOLDEN_RATIO_32) >> UMTX_SHIFTS) % UMTX_CHAINS`
([`umtxq_hash`][kern-umtx-hash]). A chain holds a kernel `mtx`, a busy flag
for operations that may sleep while holding the chain, two queue lists
(shared/exclusive) and spare queue heads ([`umtxvar.h`][umtxvar-chain]). Each
thread owns one `umtx_q` (`td->td_umtxq`) — its waiter record — plus one spare
queue head it donates to the chain when it is first to wait on a key, so
enqueueing never allocates.

**Wait** ([`do_wait`][kern-umtx-wait]): compute the key, lock the chain,
**insert the waiter first**, unlock, read the user word with `fueword` (no
lock held, faults allowed), relock, and sleep only if the value still equals
`val` and the waiter is still queued. A wake landing between insert and sleep
dequeues the waiter, and `umtxq_sleep` returns at once when `UQF_UMTXQ` is
clear ([`umtxq_sleep`][kern-umtx-sleep]). This is the opposite order to
Linux's (read under the bucket lock with faults disabled) and to XNU's (copyin
under the `ull` lock, fault returned to user space); FreeBSD can take the
fault because nothing is locked during the read.

**Wake** ([`kern_umtx_wake`][kern-umtx-wake]): key, lock chain, dequeue up to
`n_wake` from the head of the key's queue (`TAILQ_FOREACH` from
`TAILQ_INSERT_TAIL` order, [`umtxq_signal_mask`][kern-umtx-signal]), `wakeup_one`
each, unlock. `UMTX_OP_NWAKE_PRIVATE` takes an array of addresses and wakes
all waiters on each, 128 addresses per copyin batch
([`__umtx_op_nwake_private_native`][kern-umtx-nwake]).

## Analysis

### Semantics

Compare-and-sleep, wake-n, plus batched wake-all-of-many. The manual says
"the highest priority threads that have been blocked for the longest on the
queue are selected" ([`_umtx_op(2)`][man-umtx]); for simple waits the queue is
a plain FIFO `TAILQ`. Memory ordering is the caller's job: "The read of the
current value of the variable pointed to by the obj argument is not guarded by
barriers." A per-waiter `uq_bitset` exists (`umtxq_signal_mask`) but the
`WAIT`/`WAKE` ops always use the full mask. Kernel-side condvars
(`UMTX_OP_CV_WAIT` with `CVWAIT_CHECK_UNPARKING`) and the
[wait morphing](./concepts.md#wait-morphing) in libthr cover what Linux does
with requeue.

### Sizes and alignment

`UMTX_OP_WAIT` compares a **`long`** ("Pointer to a variable of type long") —
64 bits on LP64; `UMTX_OP_WAIT_UINT` and `UMTX_OP_WAIT_UINT_PRIVATE` compare
32 bits. The key is the start address only: "The size of the variable does not
matter, so, for example, sleep on the same address interpreted as uint32_t and
long on a little-endian 64-bit platform would collide." Alignment: "All
objects require ABI-mandated alignment, but this is not currently enforced
consistently on all architectures." No 8- or 16-bit waits.

### Timeouts and clocks

The most flexible of the four primitives. `uaddr` carries the **size** of the
timeout object in `uaddr2`: a bare `struct timespec` is a relative
`CLOCK_REALTIME`-labelled interval; a `struct _umtx_time { struct timespec
_timeout; uint32_t _flags; uint32_t _clockid; }` ([`_umtx.h`][umtx-time])
selects any `clock_gettime` clock and, with `UMTX_ABSTIME`, an absolute
deadline ([`umtx_copyin_umtx_time`][kern-umtx-time]). "Interval counting is
always performed by the monotonic wall clock." Realtime absolute deadlines
re-arm when the RTC is stepped (`td_rtcgen`). `UMTX_OP_SET_MIN_TIMEOUT` sets a
per-process floor that stretches every short timeout
([`umtx_abs_timeout_enforce_min`][kern-umtx-mintimeout]). Rust `std` uses
`WAIT_UINT_PRIVATE` with `UMTX_ABSTIME` on `CLOCK_MONOTONIC`
([`futex.rs`][rust-futex-freebsd]).

### Spurious wakeups and wake counts

`UMTX_OP_WAIT` "is not restartable. An unblocked signal delivered during the
wait always results in sleep interruption and EINTR error"
([`_umtx_op(2)`][man-umtx]); `ERESTART` is mapped to `EINTR` in `do_wait`. A
value mismatch returns **0**, the same as a wake — there is no `EAGAIN`.
`UMTX_OP_WAKE` returns 0 regardless: `kern_umtx_wake` discards
`umtxq_signal`'s count. Rust records the consequence: "FreeBSD doesn't tell us
how many threads are woken up, so this always returns false"
([`futex.rs`][rust-futex-freebsd-wake]).

### Process scope

The shared key is the physical page (VM object + offset), so "same variable
mapped multiple times will give one key value. This mechanism enables the
construction of process-shared locks." `*_PRIVATE` ops never consult the VM
map. On a private mapping, `AUTO_SHARE` produces the same private key as
`THREAD_SHARE`, so a plain `WAKE` reaches `WAIT_UINT_PRIVATE` waiters there; on
a shared mapping it does not.

### Cost

Not measured here (no FreeBSD host). Structurally: one syscall per wait and
wake; a chain `mtx` lock/unlock **twice** per wait (insert, then sleep); a
`vm_map_lookup` and object reference for non-private keys; no allocation (the
waiter record and spare queue head are per thread). A wake with no waiters
still enters the kernel and locks the chain. 512 chains are global, so
unrelated processes share them, as on Linux before 6.16.

### Event-loop integration

None. FreeBSD's kqueue filters are `READ`, `WRITE`, `AIO`, `VNODE`, `PROC`,
`SIGNAL`, `TIMER`, `PROCDESC`, `FS`, `LIO`, `USER`, `SENDFILE`, `EMPTY`,
`JAIL` and `JAILDESC` ([`event.h`][event-h]); none watches an address, and
there is no completion-based wait. A loop-resident waiter needs a user-space
registry and an `EVFILT_USER` trigger (or a pipe/eventfd-like descriptor) from
the waker.

libthr shows the user-space-registry pattern in production for its condition
variables ([`thr_cond.c`][thr-cond-user]):

> Thread waits in userland queue whenever possible, when thread is signaled or
> broadcasted, it is removed from the queue, and is saved in curthread's
> defer_waiters[] buffer, but won't be woken up until mutex is unlocked.

The queue is a 512-chain hashed table in user memory keyed by the condvar
address ([`thr_sleepq.c`][thr-sleepq-hash]); each thread sleeps on its own
32-bit `wake_addr->value` with `UMTX_OP_WAIT_UINT` ([`_thr_sleep`][thr-kern-sleep]);
waking sets the words to 1 and issues one `UMTX_OP_NWAKE_PRIVATE` for all of
them ([`_thr_wake_all`][thr-kern-wakeall]). It falls back to the kernel condvar
(`cond_wait_kernel`) for process-shared, priority-protocol or non-`SCHED_OTHER`
cases. This is a parking lot with per-thread wake words — the same shape a
fiber `WaitWord` registry would have, with the "per-thread word" replaced by a
per-fiber record and the batched wake by a loop notification.

### Availability and versions

FreeBSD only (DragonFly BSD has its own `umtx_sleep`/`umtx_wakeup`). libc
exposes `_umtx_op` and `_umtx_op_err` in `sys/umtx.h`. Op codes 0 and 1 are
`COMPAT10`; `UMTX_OP_MUTEX_WAKE`, `SEM_WAIT`, `SEM_WAKE` are deprecated in
favour of `MUTEX_WAKE2`/`SEM2_*`; `GET_MIN_TIMEOUT`/`SET_MIN_TIMEOUT` (27, 28)
are the newest. The clone is shallow, so per-op introduction releases are not
established here.

libthr's own spin policy, for reference: adaptive mutexes
(`PTHREAD_MUTEX_ADAPTIVE_NP`) spin `MUTEX_ADAPTIVE_SPINS` = 2000 iterations of
`CPU_SPINWAIT`, then optional `sched_yield` loops, then
`UMTX_OP_MUTEX_LOCK`/`WAIT` in the kernel ([`thr_mutex.c`][thr-mutex-spin]),
tunable through `LIBPTHREAD_SPINLOOPS`/`LIBPTHREAD_YIELDLOOPS`; the default
mutex type does not spin.

## Strengths

- **Clock and absolute/relative choice per call**, via a size-tagged timeout
  argument — the most complete timeout model of the four.
- **Batched wake** of many addresses in one syscall (`NWAKE_PRIVATE`).
- **No allocation** on wait: per-thread waiter record and donated queue head.
- Faults during the compare are taken normally (no retry protocol needed).
- Key types keep unrelated primitives on the same address in separate queues.

## Weaknesses

- **No wake count**, and a value mismatch is indistinguishable from a wake.
- `UMTX_OP_WAIT` compares a `long`, an easy trap when porting futex code; the
  32-bit ops must be chosen explicitly.
- Two chain-lock round trips per wait; global 512-chain table.
- No event-loop hook.
- Non-restartable: every signal is an `EINTR` the caller must loop on.

## Key design decisions and trade-offs

| Decision                                         | Rationale                                                   | Trade-off                                                         |
| ------------------------------------------------ | ----------------------------------------------------------- | ----------------------------------------------------------------- |
| One syscall carrying whole lock protocols        | Kernel-assisted mutex/condvar/rwlock with PI and robustness | Large ABI; the futex-like ops are a small corner of it            |
| Insert waiter, then read the word unlocked       | The read may fault normally                                 | Extra lock round trip; correctness rests on the wake dequeueing   |
| Key typed by primitive kind                      | Different primitives on one address cannot steal wakes      | A simple `WAKE` cannot reach a mutex waiter on the same word      |
| `uaddr` as the timeout-object size               | Extensible timeout ABI (`timespec` or `_umtx_time`)         | An unusual calling convention                                     |
| `WAKE` returns 0                                 | Simple                                                      | Callers cannot skip work based on "nobody was woken"              |
| libthr condvar queue in user space, batched wake | Wake after mutex unlock; one syscall for many waiters       | Process-shared and priority cases fall back to the kernel condvar |

## Sources

- FreeBSD `main` at `7c75c96d176f`: [`sys/kern/kern_umtx.c`][kern-umtx], [`sys/sys/umtx.h`][umtx-h], [`sys/sys/_umtx.h`][umtx-time], [`sys/sys/umtxvar.h`][umtxvar], [`sys/sys/event.h`][event-h]
- libthr: [`thr_umtx.c`][thr-umtx], [`thr_cond.c`][thr-cond], [`thr_sleepq.c`][thr-sleepq], [`thr_kern.c`][thr-kern], [`thr_mutex.c`][thr-mutex], [`thr_private.h`][thr-private]
- [`_umtx_op(2)`][man-umtx], FreeBSD 15.1 manual, dated 2020-11-23
- Rust `std` at `3bf5c6d99bc8`: [`sys/pal/unix/futex.rs`][rust-futex-freebsd]

<!-- References -->

[freebsd]: https://github.com/freebsd/freebsd-src/tree/7c75c96d176f600c7d17cb4652a1e655b44b2943
[kern-umtx]: https://github.com/freebsd/freebsd-src/blob/7c75c96d176f600c7d17cb4652a1e655b44b2943/sys/kern/kern_umtx.c
[kern-umtx-chains]: https://github.com/freebsd/freebsd-src/blob/7c75c96d176f600c7d17cb4652a1e655b44b2943/sys/kern/kern_umtx.c#L118
[kern-umtx-hash]: https://github.com/freebsd/freebsd-src/blob/7c75c96d176f600c7d17cb4652a1e655b44b2943/sys/kern/kern_umtx.c#L378
[kern-umtx-signal]: https://github.com/freebsd/freebsd-src/blob/7c75c96d176f600c7d17cb4652a1e655b44b2943/sys/kern/kern_umtx.c#L577
[kern-umtx-mintimeout]: https://github.com/freebsd/freebsd-src/blob/7c75c96d176f600c7d17cb4652a1e655b44b2943/sys/kern/kern_umtx.c#L711
[kern-umtx-sleep]: https://github.com/freebsd/freebsd-src/blob/7c75c96d176f600c7d17cb4652a1e655b44b2943/sys/kern/kern_umtx.c#L821
[kern-umtx-key]: https://github.com/freebsd/freebsd-src/blob/7c75c96d176f600c7d17cb4652a1e655b44b2943/sys/kern/kern_umtx.c#L863
[kern-umtx-wait]: https://github.com/freebsd/freebsd-src/blob/7c75c96d176f600c7d17cb4652a1e655b44b2943/sys/kern/kern_umtx.c#L1282
[kern-umtx-wake]: https://github.com/freebsd/freebsd-src/blob/7c75c96d176f600c7d17cb4652a1e655b44b2943/sys/kern/kern_umtx.c#L1336
[kern-umtx-time]: https://github.com/freebsd/freebsd-src/blob/7c75c96d176f600c7d17cb4652a1e655b44b2943/sys/kern/kern_umtx.c#L3838
[kern-umtx-nwake]: https://github.com/freebsd/freebsd-src/blob/7c75c96d176f600c7d17cb4652a1e655b44b2943/sys/kern/kern_umtx.c#L3992
[umtx-h]: https://github.com/freebsd/freebsd-src/blob/7c75c96d176f600c7d17cb4652a1e655b44b2943/sys/sys/umtx.h#L79
[umtx-time]: https://github.com/freebsd/freebsd-src/blob/7c75c96d176f600c7d17cb4652a1e655b44b2943/sys/sys/_umtx.h#L77
[umtxvar]: https://github.com/freebsd/freebsd-src/blob/7c75c96d176f600c7d17cb4652a1e655b44b2943/sys/sys/umtxvar.h
[umtxvar-chain]: https://github.com/freebsd/freebsd-src/blob/7c75c96d176f600c7d17cb4652a1e655b44b2943/sys/sys/umtxvar.h#L166
[event-h]: https://github.com/freebsd/freebsd-src/blob/7c75c96d176f600c7d17cb4652a1e655b44b2943/sys/sys/event.h#L35
[thr-umtx]: https://github.com/freebsd/freebsd-src/blob/7c75c96d176f600c7d17cb4652a1e655b44b2943/lib/libthr/thread/thr_umtx.c#L194
[thr-cond]: https://github.com/freebsd/freebsd-src/blob/7c75c96d176f600c7d17cb4652a1e655b44b2943/lib/libthr/thread/thr_cond.c
[thr-cond-user]: https://github.com/freebsd/freebsd-src/blob/7c75c96d176f600c7d17cb4652a1e655b44b2943/lib/libthr/thread/thr_cond.c#L283
[thr-sleepq]: https://github.com/freebsd/freebsd-src/blob/7c75c96d176f600c7d17cb4652a1e655b44b2943/lib/libthr/thread/thr_sleepq.c
[thr-sleepq-hash]: https://github.com/freebsd/freebsd-src/blob/7c75c96d176f600c7d17cb4652a1e655b44b2943/lib/libthr/thread/thr_sleepq.c#L32
[thr-kern]: https://github.com/freebsd/freebsd-src/blob/7c75c96d176f600c7d17cb4652a1e655b44b2943/lib/libthr/thread/thr_kern.c
[thr-kern-sleep]: https://github.com/freebsd/freebsd-src/blob/7c75c96d176f600c7d17cb4652a1e655b44b2943/lib/libthr/thread/thr_kern.c#L189
[thr-kern-wakeall]: https://github.com/freebsd/freebsd-src/blob/7c75c96d176f600c7d17cb4652a1e655b44b2943/lib/libthr/thread/thr_kern.c#L201
[thr-mutex]: https://github.com/freebsd/freebsd-src/blob/7c75c96d176f600c7d17cb4652a1e655b44b2943/lib/libthr/thread/thr_mutex.c
[thr-mutex-spin]: https://github.com/freebsd/freebsd-src/blob/7c75c96d176f600c7d17cb4652a1e655b44b2943/lib/libthr/thread/thr_mutex.c#L660
[thr-private]: https://github.com/freebsd/freebsd-src/blob/7c75c96d176f600c7d17cb4652a1e655b44b2943/lib/libthr/thread/thr_private.h#L161
[man-umtx]: https://man.freebsd.org/cgi/man.cgi?query=_umtx_op&sektion=2
[rust-futex-freebsd]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/pal/unix/futex.rs#L50
[rust-futex-freebsd-wake]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/pal/unix/futex.rs#L119
