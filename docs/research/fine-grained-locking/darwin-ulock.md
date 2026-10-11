# Darwin `__ulock` and `os_sync_wait_on_address`

XNU's futex: `__ulock_wait`, `__ulock_wait2` and `__ulock_wake`, private system
calls (515, 516, 544) behind `os_unfair_lock`, `pthread` and libdispatch, and —
since macOS 14.4 (2024) — a public, documented wrapper family,
`os_sync_wait_on_address` / `os_sync_wake_by_address_any` / `_all`. The kernel
keeps a global hashed table of per-address `ull_t` objects, each with a
turnstile, so the same machinery that gives `os_unfair_lock` priority
inheritance also serves plain compare-and-wait.

|                     |                                                                                                                                                                                                                                                                                     |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**            | kernel mechanism (OS wait primitive) + public libplatform wrapper                                                                                                                                                                                                                   |
| **Language**        | C (XNU `bsd/kern`, libplatform `src/os`)                                                                                                                                                                                                                                            |
| **License**         | APSL-2.0 (XNU); Apache-2.0 (libplatform)                                                                                                                                                                                                                                            |
| **Repository**      | [`apple-oss-distributions/xnu`][xnu] at `f6217f891ac0` (`xnu-12377.1.9`, 2025-10-16); [`apple-oss-distributions/libplatform`][libplatform] at `2512ffd8bb5c` (`libplatform-375.100.10`, 2026-04-17)                                                                                 |
| **Versions**        | `__ulock_wait`/`__ulock_wake` (private); `__ulock_wait2` from XNU 7195.50.7 / macOS 11; `os_sync_wait_on_address` family macOS 14.4, iOS 17.4, tvOS 17.4, watchOS 10.4                                                                                                              |
| **Word sizes**      | 4 or 8 bytes (`UL_COMPARE_AND_WAIT`, `UL_COMPARE_AND_WAIT64`)                                                                                                                                                                                                                       |
| **Process scope**   | private by default (key: task + address); `*_SHARED` opcodes key by VM object + offset                                                                                                                                                                                              |
| **Event-loop hook** | none: kqueue has no address filter; `EVFILT_USER` is the bridge                                                                                                                                                                                                                     |
| **Source read**     | [`bsd/kern/sys_ulock.c`][sys-ulock], [`bsd/sys/ulock.h`][ulock-h], [`bsd/kern/syscalls.master`][syscalls-master], [`bsd/sys/event.h`][event-h]; libplatform [`include/os/os_sync_wait_on_address.h`][os-sync-h], [`src/os/lock.c`][lock-c]; Rust and Zig `std` comments cited below |

## Overview

### What it solves

Apple's locks needed a kernel wait keyed by a user address that also knows
**who owns the lock**, so a blocked high-priority thread can boost the owner.
The operation code selects which: `UL_UNFAIR_LOCK` reads the lock word as the
owner's thread port name and pushes a priority promotion onto that thread;
`UL_COMPARE_AND_WAIT` is the futex-shaped variant with no owner. The header
comment in [`sys_ulock.c`][sys-ulock-promotion]:

> ulock wait applies a promotion to the owner communicated through
> UL_UNFAIR_LOCK as waiters block, and that promotion is saturated as long as
> there is still an owner. In ulock wake, if the waker is still the owner,
> then it clears its ownership and drops the boost. It does NOT transfer
> ownership/priority boost to the new thread. Instead, it selects the waiting
> thread with the highest base priority to be woken next, and relies on that
> thread to carry the torch for the other waiting threads.

### Design philosophy

Keep the raw interface private and publish a narrow wrapper. The public header
introduces itself as "Low-level Darwin's futex style APIs" and steers lock
authors away ([`os_sync_wait_on_address.h`][os-sync-h-purpose]):

> This function is expected to be used for implementing synchronization
> primitives that do not have a sense of ownership (e.g. condition variables,
> semaphores) as it does not provide priority inversion avoidance. For locking
> primitives, it is recommended that you use existing OS primitives such as
> os_unfair_lock API family / pthread mutex or std::mutex.

Until 14.4 there was no public option at all, which shaped every portable
runtime. Rust `std` still says ([`darwin.rs`][rust-darwin]):

> Darwin actually has futex syscalls (`__ulock_wait`/`__ulock_wake`), but they
> cannot be used in `std` because they are non-public (their use will lead to
> rejection from the App Store).

and parks on a libdispatch semaphore instead. Zig's `std` calls
`__ulock_wait2` directly ([`Threaded.zig`][zig-ulock]).

## How it works

**Operation word.** One `uint32_t`: bits 0–7 the opcode, 8–15 wake flags,
16–23 wait flags, 24–31 generic flags ([`ulock.h`][ulock-h-ops]):

| Opcode                         | Value | Meaning                                        |
| ------------------------------ | ----- | ---------------------------------------------- |
| `UL_COMPARE_AND_WAIT`          | 1     | 32-bit compare-and-wait, process-private       |
| `UL_UNFAIR_LOCK`               | 2     | 32-bit lock word holding the owner's port name |
| `UL_COMPARE_AND_WAIT_SHARED`   | 3     | 32-bit, keyed by VM object (cross-process)     |
| `UL_UNFAIR_LOCK64_SHARED`      | 4     | defined; rejected by `sys_ulock_wait2`         |
| `UL_COMPARE_AND_WAIT64`        | 5     | 64-bit, private                                |
| `UL_COMPARE_AND_WAIT64_SHARED` | 6     | 64-bit, shared                                 |

Flags: `ULF_WAKE_ALL`, `ULF_WAKE_THREAD` (wake one specific thread, named by
port in `wake_value`), `ULF_WAKE_ALLOW_NON_OWNER`; `ULF_WAIT_WORKQ_DATA_CONTENTION`,
`ULF_WAIT_CANCEL_POINT`, `ULF_WAIT_ADAPTIVE_SPIN`; `ULF_NO_ERRNO` (return
`-errno` instead of setting `errno`) and `ULF_DEADLINE`.

**Table.** `ulock_initialize` sizes a global array of
`ull_bucket_t { queue_head_t; lck_spin_t }` to the power of two at or above
`thread_max`, divided by 4 ([`sys_ulock.c`][sys-ulock-init]). A key is
`(address, task)` — "We use the task address as a hashing key, so that ulock
wakes across exec can't be confused" — or `(VM object, offset)` for the
shared opcodes, Jenkins-hashed. Each key with waiters gets a heap-allocated
`ull_t` holding its own spinlock, `ull_nwaiters`, the opcode, the last known
owner and a turnstile ([`struct ull`][sys-ulock-ull]); it is freed when the
last waiter leaves.

**Wait** ([`sys_ulock_wait2`][sys-ulock-wait2]): validate opcode and alignment,
build the key, optionally adaptive-spin, look up or allocate the `ull_t`
(locked), `ull_nwaiters++`, refuse with `EDOM` if the `ull_t` already belongs
to a different opcode, read the user word under the `ull` lock with
`copyin_atomic32/64` — a fault is returned to user space rather than taken
("holding the ull spinlock across copyin forces any vm_fault we encounter to
fail") — and, if it still equals `value`, `waitq_assert_wait64` on the
turnstile and block. For `UL_UNFAIR_LOCK` the owner thread becomes the
turnstile's inheritor and the waiter blocks with `thread_handoff_parameter`,
donating its CPU to the owner.

**Wake** ([`ulock_wake`][sys-ulock-wake]): find the `ull_t` (`ULL_MUST_EXIST`);
none means `ENOENT`. Then wake one, all, or one named thread. For the lock
opcode, a wake from a thread that is no longer the recorded owner is dropped:
"This current owner already knows the lock is contended and will redrive
wakes, just bail out."

**`os_sync_*`.** The wrappers in [`lock.c`][lock-c-wrap] map size 4/8 and the
`SHARED` flag onto the four compare-and-wait opcodes, always pass
`ULF_NO_ERRNO`, and call `__ulock_wait2` / `__ulock_wake`.
`os_sync_wake_by_address_any` passes no flags — "The default behaviour of
\_\_ulock_wake is to wake any."

## Analysis

### Semantics

Atomic compare-and-wait, documented as such: "This sequence of operations is
done atomically with respect to other concurrent operations that can be
performed on this @addr" ([header][os-sync-h-purpose]). Wake one or all — no
count, no bitset, no requeue, no wait-on-many. Wake order is priority: the
wait queue is a turnstile waitq, "priority ordered", and the public header
promises nothing ("No guarantee is provided about which specific waiter is
woken up"). `ULF_WAKE_THREAD` is unusual among the OS primitives here: a
directed wake of a specific thread — but it is private, and the public
wrapper does not expose it.

**`EDOM` / `EINVAL` on mixed use.** The first waiter fixes the `ull_t`'s opcode;
waiting or waking the same address with a different opcode fails (`EDOM` in
the kernel, documented as `EINVAL` "The operation associated with existing
kernel state at this @addr is inconsistent with what the caller has
requested"). So one address cannot be waited on as both 32- and 64-bit, or as
both private and shared, at the same time.

### Sizes and alignment

4 or 8 bytes, "aligned to @size"; the kernel checks
`args->addr & (lock_size - 1)`. For size 4 "the upper 4 bytes of @value are
ignored". No byte or halfword waits. The 64-bit opcode is the one OS
primitive in this catalog besides `WaitOnAddress` that can wait on a
pointer-sized word.

### Timeouts and clocks

Three encodings ([`ulock.h`][ulock-h-timeout]): `__ulock_wait` takes a 32-bit
**microsecond** relative timeout; `__ulock_wait2` takes 64-bit nanoseconds
relative, or with `ULF_DEADLINE` an absolute `mach_absolute_time` deadline.
`0` means wait forever in all three — Zig maps a requested zero timeout to `1`
for that reason ([`Threaded.zig`][zig-ulock]). The public API makes zero an
error ("Passing zero for the @deadline results in an error being returned")
and accepts only `OS_CLOCK_MACH_ABSOLUTE_TIME`: "The default kernel
implementation uses MAT today" ([`lock.c`][lock-c-mat]). `__ulock_wait2`'s
fifth argument `value2` is plumbed but unused by the compare-and-wait path.

### Spurious wakeups and wake counts

The public contract lists early returns to retry on: `EINTR` ("The syscall was
interrupted / spurious wake up"), `ENOMEM`, and `EFAULT` for a transient
copyin failure ("this is a transient error such as due to low memory
conditions"), and gives the retry loop. A value mismatch returns **success**,
not an error: the return value on success is "the number of outstanding
waiters blocked on this address" — `--ull_nwaiters` in
[`ulock_wait_cleanup`][sys-ulock-cleanup] — so a waiter cannot distinguish
"woken" from "value had changed". Wake returns 0 or `ENOENT` ("No waiter(s)
found waiting on the @addr"), so the waker learns whether anyone was queued
but not how many it woke.

### Process scope

Private by default — the key includes the task, so even shared memory waited
on without `SHARED` stays process-local. `OS_SYNC_WAIT_ON_ADDRESS_SHARED` (or
the `*_SHARED` opcodes) keys by VM object and offset via `uaddr_findobj`, and
"it is important to pass OS_SYNC_WAKE_BY_ADDRESS_SHARED flag along with the
exact same @addr" on the wake side. The header asks callers not to use it for
intra-process work because private keys "allow the kernel to perform
performance optimizations".

### Cost

Not measured here (no macOS host). Structurally: one syscall per wait and
wake; a wait may allocate an `ull_t` (`ENOMEM` is a documented outcome); a
wake with no waiters takes the bucket lock and returns `ENOENT`. Every wait
prepares a turnstile even for compare-and-wait. The only in-kernel spin is
`ULF_WAIT_ADAPTIVE_SPIN`, limited to `UL_UNFAIR_LOCK`: spin while the owner is
on core, up to `kern.ulock_adaptive_spin_usecs` (default 20 µs)
([`sys_ulock.c`][sys-ulock-spin]).

### Event-loop integration

None native. kqueue's public filters are `READ`, `WRITE`, `AIO`, `VNODE`,
`PROC`, `SIGNAL`, `TIMER`, `MACHPORT`, `FS`, `USER`, `VM` and `EXCEPT`
([`event.h`][event-h]); none watches a user address, and there is no
io_uring-style "wait completes as an event". A loop-resident fiber that must
be woken by an arbitrary thread therefore needs a user-space registry: the
fiber records itself against the word, the waker updates the word and then
triggers the loop's `EVFILT_USER` knote (`NOTE_TRIGGER`) or writes to a pipe.
Wine does exactly this to implement NT thread alerts on macOS — one kqueue
per thread with an `EVFILT_USER` event ([Wine `unix/sync.c`][wine-kq]) — which
also shows the cost: a kqueue per waiter, or a shared one plus a table.

### Availability and versions

`__ulock_*` are private SPI: declared under `#if PRIVATE` in `ulock.h`, not in
the public SDK, and their use risks App Store rejection (Rust's comment
above). `__ulock_wait2` exists from XNU 7195.50.7 — "This XNU version appears
to correspond to 11.0.1" ([Zig][zig-ulock2]). The `os_sync_*` family is public
API from macOS 14.4 / iOS 17.4 / tvOS 17.4 / watchOS 10.4
(`OS_WAIT_ON_ADDR_AVAILABILITY`), so a runtime that supports older systems
must weak-link it and fall back (to `__ulock`, to a semaphore, or to
`pthread` condvars).

## Strengths

- **Priority-aware**: the same table drives `os_unfair_lock`'s owner boost and
  CPU handoff through turnstiles.
- **4- and 8-byte words**; directed wake (`ULF_WAKE_THREAD`) in the SPI.
- **Wake tells you if nobody waited** (`ENOENT`) and wait returns the
  remaining-waiter count.
- **A public, documented futex** since 14.4, with deadline and timeout forms.

## Weaknesses

- **Private before 14.4**; portable code needs weak linking and a fallback.
- **Mach absolute time only** for public deadlines; microsecond resolution in
  the original SPI; zero means infinite in the SPI and is an error in the API.
- **Per-address kernel allocation**, so a wait can fail with `ENOMEM`.
- **No event-loop hook**: kqueue cannot watch an address.
- A value mismatch and a real wake both return success.

## Key design decisions and trade-offs

| Decision                                        | Rationale                                                 | Trade-off                                                    |
| ----------------------------------------------- | --------------------------------------------------------- | ------------------------------------------------------------ |
| Opcode distinguishes lock from compare-and-wait | Lock words carry the owner, enabling priority inheritance | One address is locked to one opcode while waited on (`EDOM`) |
| Turnstile per `ull_t`                           | Priority-ordered queues and owner boosting                | Heavier than a bare wait queue; allocation on first wait     |
| Key includes the task                           | Exec cannot confuse old and new wakers                    | Shared memory needs the separate `SHARED` opcodes            |
| Fault in copyin returns to user space           | Never hold the `ull` spinlock across a VM fault           | Callers must retry on `EFAULT`                               |
| Keep SPI private, publish a narrow wrapper      | Freedom to change the SPI; ownership-free API only        | Runtimes built on semaphores or private calls until 2024     |

## Sources

- XNU `xnu-12377.1.9`: [`bsd/kern/sys_ulock.c`][sys-ulock], [`bsd/sys/ulock.h`][ulock-h], [`bsd/kern/syscalls.master`][syscalls-master], [`bsd/sys/event.h`][event-h]
- libplatform `libplatform-375.100.10`: [`include/os/os_sync_wait_on_address.h`][os-sync-h], [`src/os/lock.c`][lock-c] (`os_sync_*` wrappers and `os_unfair_lock`)
- Rust `std` at `3bf5c6d99bc8`: [`thread_parking/darwin.rs`][rust-darwin]
- Zig `std` at `1bcd8d9fe60f`: [`Io/Threaded.zig`][zig-ulock]
- Wine `a15ee2ccf20e`: [`dlls/ntdll/unix/sync.c`][wine-kq] — `EVFILT_USER` as a per-thread alert

> [!NOTE]
> No Darwin host was available; all behaviour is from source.

<!-- References -->

[xnu]: https://github.com/apple-oss-distributions/xnu/tree/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea
[libplatform]: https://github.com/apple-oss-distributions/libplatform/tree/2512ffd8bb5c6caff3c8ea83331ab8a0adc820c3
[sys-ulock]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/sys_ulock.c
[sys-ulock-promotion]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/sys_ulock.c#L73
[sys-ulock-ull]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/sys_ulock.c#L167
[sys-ulock-spin]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/sys_ulock.c#L186
[sys-ulock-init]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/sys_ulock.c#L255
[sys-ulock-wait2]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/sys_ulock.c#L511
[sys-ulock-cleanup]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/sys_ulock.c#L812
[sys-ulock-wake]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/sys_ulock.c#L909
[ulock-h]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/sys/ulock.h
[ulock-h-timeout]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/sys/ulock.h#L67
[ulock-h-ops]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/sys/ulock.h#L84
[syscalls-master]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/syscalls.master#L818
[event-h]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/sys/event.h#L70
[os-sync-h]: https://github.com/apple-oss-distributions/libplatform/blob/2512ffd8bb5c6caff3c8ea83331ab8a0adc820c3/include/os/os_sync_wait_on_address.h
[os-sync-h-purpose]: https://github.com/apple-oss-distributions/libplatform/blob/2512ffd8bb5c6caff3c8ea83331ab8a0adc820c3/include/os/os_sync_wait_on_address.h#L84
[lock-c]: https://github.com/apple-oss-distributions/libplatform/blob/2512ffd8bb5c6caff3c8ea83331ab8a0adc820c3/src/os/lock.c
[lock-c-wrap]: https://github.com/apple-oss-distributions/libplatform/blob/2512ffd8bb5c6caff3c8ea83331ab8a0adc820c3/src/os/lock.c#L1383
[lock-c-mat]: https://github.com/apple-oss-distributions/libplatform/blob/2512ffd8bb5c6caff3c8ea83331ab8a0adc820c3/src/os/lock.c#L1411
[rust-darwin]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/sync/thread_parking/darwin.rs#L3
[zig-ulock]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io/Threaded.zig#L999
[zig-ulock2]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io/Threaded.zig#L14885
[wine-kq]: https://gitlab.winehq.org/wine/wine/-/blob/a15ee2ccf20e2fc9f470badd916855801933d31f/dlls/ntdll/unix/sync.c#L3525
