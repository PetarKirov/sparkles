# `os_unfair_lock` (Apple)

Apple's replacement for `OSSpinLock`: a 4-byte word that holds the owner's
Mach thread port, blocks in the kernel's `__ulock_wait` on contention, and lets
the kernel boost the owner's priority — an owner-tid lock whose defining
choice is to _not_ spin in user space, with the Darwin `pthread_mutex_t`
running beside it on a separate, older kernel path.

|                       |                                                                                                                                                                                                                                                                                                                                                                                             |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**              | OS user-space library (`libplatform`, exported from `libsystem_platform.dylib`) + kernel wait queue (`xnu`)                                                                                                                                                                                                                                                                                 |
| **Language**          | C                                                                                                                                                                                                                                                                                                                                                                                           |
| **License**           | Apple Public Source License 2.0                                                                                                                                                                                                                                                                                                                                                             |
| **Repository**        | [`apple-oss-distributions/libplatform`][lp-repo] (`libplatform-375.100.10`); [`apple-oss-distributions/xnu`][xnu-repo]; [`apple-oss-distributions/libpthread`][pt-repo] (`libpthread-539`)                                                                                                                                                                                                  |
| **Availability**      | `OS_UNFAIR_LOCK_AVAILABILITY`: macOS 10.12, iOS 10.0, tvOS 10.0, watchOS 3.0 ([`lock.h`][lock-h-avail]); `OS_UNFAIR_LOCK_ADAPTIVE_SPIN` option macOS 10.15; public `os_unfair_lock_lock_with_flags` macOS 15.0 / iOS 18.0                                                                                                                                                                   |
| **Lock word**         | `uint32_t` holding the owner's `mach_port_name_t`, low bit cleared to mean "waiters may exist"                                                                                                                                                                                                                                                                                              |
| **Parking substrate** | `__ulock_wait2(UL_UNFAIR_LOCK, …)` / `__ulock_wake`: a kernel hash table of `ull_t` keyed by (task, address), each with a priority-ordered turnstile                                                                                                                                                                                                                                        |
| **Source read**       | [`include/os/lock.h`][lock-h], [`private/os/lock_private.h`][lock-priv], [`src/os/lock.c`][lock-c], [`include/libkern/OSSpinLockDeprecated.h`][osspin-h] (libplatform); [`bsd/kern/sys_ulock.c`][ulock-c] (xnu); [`src/pthread_mutex.c`][pt-mutex], [`src/types_internal.h`][pt-types], [`kern/kern_synch.c`][pt-ksynch], [`include/sys/_pthread/_pthread_types.h`][pt-ptypes] (libpthread) |

## Overview

### What it solves

`OSSpinLock` spun in user space. The SPI header's note on the equivalent
`os_lock_spin_s` names the failure: the critical section must not block or
fault "in particular if the critical section may be executing on threads of
widely differing priorities or on a mix of IO-throttled and unthrottled
threads" ([`lock_private.h`][lock-priv-spin]) — a spinning high-priority waiter
starves the low-priority owner it waits for. The public header defines the
replacement by what it records rather than how it waits
([`lock.h`][lock-h-doc]):

> The values stored in the lock should be considered opaque and implementation
> defined, they contain thread ownership information that the system may use
> to attempt to resolve priority inversions.
>
> This lock must be unlocked from the same thread that locked it, attempts to
> unlock from a different thread will cause an assertion aborting the process.

and states the starvation trade-off in its name:

> The name 'unfair' indicates that there is no attempt at enforcing
> acquisition fairness, e.g. an unlocker can potentially immediately reacquire
> the lock before a woken up waiter gets an opportunity to attempt to acquire
> the lock. This is often advantageous for performance reasons, but also makes
> starvation of waiters a possibility.

### Design philosophy

**No spinning, by design.** The SPI header says it twice, once per lock type
([`lock_private.h`][lock-priv-spi]): "Replacement for the deprecated
OSSpinLock. Does not spin on contention but waits in the kernel to be woken up
by an unlock." Spinning is reintroduced only as an opt-in, kernel-side,
owner-on-core policy (below).

**The owner identity is the lock value.** Storing the owner's thread port in
the word is what lets the kernel find the thread to boost without a user-space
registry, and is why unlock must be on the owning thread and why the lock is
process-private: "the lock implementation relies on the address of the lock
value and identity of the owning process" ([`lock.h`][lock-h-doc]).

**Do not hide waiters from the system.** `os_unfair_lock_trylock`'s doc forbids
a retry loop because it "amounts to an inefficient implementation of
`os_unfair_lock_lock()` that hides the lock waiter from the system and prevents
resolution of priority inversions" ([`lock.h`][lock-h-trylock]).

## How it works

Owner encoding relies on a property of Mach port names
([`lock.c`][lock-c-ulockval]):

```c
// This assumes that all thread mach port values always have the low bit set!
// Clearing this bit is used to communicate the existence of waiters to unlock.
#define OS_ULOCK_NOWAITERS_BIT ((os_ulock_value_t)1u)
#define OS_ULOCK_OWNER(value) ((value) | OS_ULOCK_NOWAITERS_BIT)
```

Lock and unlock are one atomic each ([`lock.c`][lock-c-fast]):

```c
void os_unfair_lock_lock(os_unfair_lock_t lock) {
    os_lock_owner_t self = _os_lock_owner_get_self();   // TSD read, no syscall
    bool r = os_atomic_cmpxchg(&l->oul_value, OS_LOCK_NO_OWNER, self, acquire);
    if (likely(r)) return;
    return (void) _os_unfair_lock_lock_slow(l, OS_UNFAIR_LOCK_NONE, 0, self);
}
void os_unfair_lock_unlock(os_unfair_lock_t lock) {
    current = os_atomic_xchg(&l->oul_value, OS_LOCK_NO_OWNER, release);
    if (likely(current == self)) return;
    return _os_unfair_lock_unlock_slow(l, self, current, 0);
}
```

The slow path ([`_os_unfair_lock_lock_slow`][lock-c-slow]) loops: abort on
recursion (`current` is our own port); CAS the low bit off (`relaxed`) to
announce a waiter; call `__ulock_wait2(UL_UNFAIR_LOCK | ULF_NO_ERRNO |
options, l, current, timeout, 0)`; treat `EINTR`/`EFAULT` as retry,
`EOWNERDEAD` as corruption (the word did not hold a live thread port),
`ETIMEDOUT` as failure for the timed `trylock_with_options`. A positive return
is the kernel's count of _remaining_ waiters, in which case the acquiring CAS
installs `self & ~NOWAITERS` so the next unlock still takes the slow path.
Unlock's slow path checks ownership (crash if not owner) and calls
`__ulock_wake(UL_UNFAIR_LOCK | ULF_NO_ERRNO, l, 0)`, ignoring `ENOENT`
([`_os_unfair_lock_unlock_slow`][lock-c-unlockslow]).

In the kernel, `ulock_wait` resolves the port in the user's value to a
`thread_t`, stores it as `ull_owner`, and makes it the turnstile's inheritor
([`sys_ulock.c`][ulock-c-wait]); the promotion protocol is described at the top
of the file ([`sys_ulock.c`][ulock-c-promo]):

> ulock wait applies a promotion to the owner communicated through
> UL_UNFAIR_LOCK as waiters block, and that promotion is saturated as long as
> there is still an owner. In ulock wake, if the waker is still the owner, then
> it clears its ownership and drops the boost. It does NOT transfer
> ownership/priority boost to the new thread. Instead, it selects the waiting
> thread with the highest base priority to be woken next, and relies on that
> thread to carry the torch for the other waiting threads.

A blocking waiter does not merely sleep: when it knows the owner it calls
`thread_handoff_parameter(owner_thread, ulock_wait_continue, …)`, donating its
CPU directly to the owner ([`sys_ulock.c`][ulock-c-handoff]).

## Analysis

### State word and fast path

One `uint32_t`: `0` = unlocked; otherwise the owner's port name, whose low bit
is `1` when no waiter has announced itself and `0` when one may have. Lock is a
CAS `0 → self` with `acquire`; unlock is an exchange `→ 0` with `release`,
whose result tells the unlocker both whether it was the owner and whether to
call the kernel. The owner port comes from a direct TSD load
(`_os_tsd_get_direct(__TSD_MACH_THREAD_SELF)`), so identity costs nothing. The
waiter bit is a "maybe": a woken waiter sets it again if the kernel reports
more waiters, so the word never under-reports. This is the
[futex](./concepts.md#futex) 3-state word with "locked" widened to "locked by
whom".

### Waiting: spin, yield, park

None in user space for `os_unfair_lock_lock`. With
`OS_UNFAIR_LOCK_ADAPTIVE_SPIN` (SPI since macOS 10.15, public via
`OS_UNFAIR_LOCK_FLAG_ADAPTIVE_SPIN` since macOS 15), the **kernel** spins: it
copies in the word once, resolves the owner, and while
`machine_thread_on_core(owner_thread)` it waits for the word to change with
`copyin_atomic32_wait_if_equals`, bounded by `ulock_adaptive_spin_usecs = 20`
microseconds (a `kern.ulock_adaptive_spin_usecs` sysctl), before falling into
the blocking path ([`sys_ulock.c`][ulock-c-spin]). The header limits it to
"locks where the protected critical section is always extremely short"
([`lock_private.h`][lock-priv-opts]). Spinning thus costs one syscall but is
conditioned on the one fact user space cannot see cheaply — whether the owner
is running — which is the same test as Linux's
[`mutex_spin_on_owner`](./queue-locks.md#waiting-spin-yield-park).

The deprecated `OSSpinLock` is now a forwarding shim: `OSSpinLockLock` calls
`_os_nospin_lock_lock`, which waits with `UL_COMPARE_AND_WAIT` and a timeout
that starts at 1 ms ([`lock.c`][lock-c-nospin]) — the "spin lock" no longer
spins.

### The parking substrate

`__ulock_wait2`/`__ulock_wake` (detailed in [Darwin ulock](./darwin-ulock.md)).
The kernel keeps a global hash table of `ull_t` records keyed by
`(task, user address)`, sized from `thread_max`
(`ull_hash_buckets = 1 << (bit_ceiling(thread_max) - 2)`), each holding a
waiter count, the last known owner and a turnstile
([`sys_ulock.c`][ulock-c-ull]). So Darwin is a
[parking](./concepts.md#parking)-lot design in the kernel: waiter records live
in kernel turnstiles, not in the lock. `UL_UNFAIR_LOCK` differs from the plain
`UL_COMPARE_AND_WAIT` only in that the value is interpreted as an owner, which
turns on priority inheritance and directed handoff of the CPU.

### Fairness, handoff and starvation

Unfair by name. Unlock releases the word before calling the kernel, so the
unlocker or any running thread can take it again ([barging](./concepts.md#barging-and-handoff)).
The kernel wakes "the highest priority waiter" from a priority-ordered
turnstile, not the oldest ([`sys_ulock.c`][ulock-c-wake]), and does not
transfer ownership. A late `__ulock_wake` from a thread that is no longer the
recorded owner is dropped: "This current owner already knows the lock is
contended and will redrive wakes, just bail out." There is no starvation bound
and no eventual-fairness timer; the design trades both for
[priority-inversion](./concepts.md#priority-inversion) avoidance.

### Condition variables and predicates

None. The header points elsewhere ([`lock.h`][lock-h-doc]): "For situations
where something more sophisticated like condition waits or FIFO ordering is
needed, use appropriate higher level APIs such as those from the pthread or
dispatch subsystems." Darwin's `pthread_cond_t` has a ulock-based
implementation that it selects only when the associated mutex is a ulock mutex
(a signature state machine: "the first `_cond_wait()` transitions to one of
SIG_psynch or SIG_ulock according to the mutex being waited on",
[`pthread_cond.c`][pt-cond]).

`os_once` (`_os_once`) is built on the same word and wait: the once word holds
`OS_ONCE_INIT` (0), the initializer's thread port while running, or
`OS_ONCE_DONE`; waiters call `__ulock_wait(UL_UNFAIR_LOCK, …)` on it, so a
thread blocked on a once boosts the initializer, and completion is one
`__ulock_wake(… | ULF_WAKE_ALL)` ([`lock.c`][lock-c-once]). On non-x86 targets
it first stores a generation from `_COMM_PAGE_CPU_QUIESCENT_COUNTER` and only
writes `DONE` after observing that every CPU has context-switched enough times;
the inline `os_once` fast path is a plain load compared with `~0l` followed by
only a compiler barrier ([`once_private.h`][once-h]), and the quiescence wait is
what makes that sound without a hardware acquire.

### Footprint and layout

4 bytes, zero-initialised (`OS_UNFAIR_LOCK_INIT` is `{0}`), no destroy
function. The word must not move while in use (the Swift note in
[`lock.h`][lock-h-doc] warns that `&` "can copy or move the lock memory").
`os_unfair_recursive_lock` adds a 4-byte count. Contrast Darwin's
`pthread_mutex_t`: 64 bytes on LP64 (`long __sig` + 56 opaque bytes,
[`_pthread_types.h`][pt-ptypes]).

### Portability

Darwin only, and process-private only: no `PTHREAD_PROCESS_SHARED`
equivalent, because the kernel key is `(task, address)` and the owner is a
per-task port name. Darwin's `pthread_mutex_t` is the portable API and is a
different mechanism. Its default policy is `_PTHREAD_MTX_OPT_POLICY_FIRSTFIT`
([`types_internal.h`][pt-types]); the alternative `FAIRSHARE` orders waiters by
sequence number. Both use the older `psynch` kernel extension
(`__psynch_mutexwait`/`__psynch_mutexdrop`) with lock/unlock generation
counters in the mutex; in the kernel, firstfit waiters are inserted "firstfit,
arriving order" ([`kern_synch.c`][pt-ksynch-fit]), and a woken firstfit waiter
can find the lock "stolen out from under a locker between the unlock from the
kernel and this lock path" and must wait again
([`pthread_mutex.c`][pt-firstfit]). A ulock-backed mutex path exists — owner
port in a `uint32_t`, `UL_UNFAIR_LOCK` waits, optional adaptive spin — but it
is gated: only `PTHREAD_MUTEX_NORMAL`, firstfit, process-private mutexes
qualify ([`pthread_mutex.c`][pt-ulock-criteria]), and the default is off
(`_PTHREAD_MTX_OPT_ULOCK_DEFAULT false`), enabled per process by the
`PTHREAD_MUTEX_USE_ULOCK` environment variable or registration data.

### Async and fiber integration

None at the lock: the waiter is always a kernel thread blocked in
`__ulock_wait`, and the header marks every entry point
`OS_SWIFT_UNAVAILABLE_FROM_ASYNC`, with the message "Use OSAllocatedUnfairLock.performWhileLocked() for
async-safe scoped locking". The owner-must-unlock
rule also forbids holding the lock across a suspension point that might
resume on another thread. The option that bears on event loops is
`OS_UNFAIR_LOCK_DATA_SYNCHRONIZATION`, which tells the workqueue subsystem
"to not create new threads to offset for threads waiting for the lock"
([`lock_private.h`][lock-priv-opts]) — in the kernel it marks the wait
`THREAD_WAIT_NOREPORT` ([`sys_ulock.c`][ulock-c-wait]). It exists because a
thread pool that compensates for blocked workers would otherwise overcommit
on a lock whose owner needs no help. Cross-thread wake into an event loop
must go through a different primitive (a kqueue `EVFILT_USER` or
`os_sync_wake_by_address_*`).

## Strengths

- One CAS to lock, one exchange to unlock; owner identity is free.
- Kernel priority inheritance and CPU handoff to the owner: the waiter's
  quantum runs the critical section.
- Adaptive spin is kernel-side and gated on the owner being on core.
- 4 bytes, zero-init, no destroy.

## Weaknesses

- Unfair with no starvation bound; wake order is priority, not arrival.
- Owner-thread unlock only; no condition variable; process-private only.
- Every contended acquire is a syscall (no user-space spin by default).
- Darwin-only; `pthread_mutex_t` uses a different, larger, generation-counter
  mechanism unless an environment flag opts in.

## Key design decisions and trade-offs

| Decision                                 | Rationale                                                         | Trade-off                                                   |
| ---------------------------------------- | ----------------------------------------------------------------- | ----------------------------------------------------------- |
| Owner port in the word                   | Kernel can boost the owner; recursion and wrong-owner unlock trap | Unlock is pinned to the owning thread; no cross-process use |
| Low bit = "no waiters"                   | Port names are odd, so the bit is free                            | Depends on a Mach port-name invariant                       |
| No user-space spinning                   | Spinning caused priority inversion under QoS                      | Short contended sections pay a syscall                      |
| Kernel adaptive spin while owner on core | Spins only when it can pay off                                    | Opt-in flag; one syscall even when the spin wins            |
| Wake highest-priority waiter, no handoff | Priority over FIFO; no convoy                                     | Starvation of low-priority waiters                          |
| `DATA_SYNCHRONIZATION` hint              | Stops workqueue thread compensation                               | Caller promises the owner needs no other thread to progress |

## Sources

- libplatform at `libplatform-375.100.10`: [`include/os/lock.h`][lock-h],
  [`private/os/lock_private.h`][lock-priv], [`src/os/lock.c`][lock-c],
  [`include/libkern/OSSpinLockDeprecated.h`][osspin-h].
- xnu: [`bsd/kern/sys_ulock.c`][ulock-c].
- libpthread at `libpthread-539`: [`src/pthread_mutex.c`][pt-mutex],
  [`src/pthread_cond.c`][pt-cond], [`src/types_internal.h`][pt-types],
  [`kern/kern_synch.c`][pt-ksynch],
  [`include/sys/_pthread/_pthread_types.h`][pt-ptypes].

<!-- References -->

[lp-repo]: https://github.com/apple-oss-distributions/libplatform/tree/2512ffd8bb5c6caff3c8ea83331ab8a0adc820c3
[xnu-repo]: https://github.com/apple-oss-distributions/xnu/tree/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea
[pt-repo]: https://github.com/apple-oss-distributions/libpthread/tree/42d026df5b07825070f60134b980a1ec2552dfee
[lock-h]: https://github.com/apple-oss-distributions/libplatform/blob/2512ffd8bb5c6caff3c8ea83331ab8a0adc820c3/include/os/lock.h
[lock-h-avail]: https://github.com/apple-oss-distributions/libplatform/blob/2512ffd8bb5c6caff3c8ea83331ab8a0adc820c3/include/os/lock.h#L41-L42
[lock-h-doc]: https://github.com/apple-oss-distributions/libplatform/blob/2512ffd8bb5c6caff3c8ea83331ab8a0adc820c3/include/os/lock.h#L44-L89
[lock-h-trylock]: https://github.com/apple-oss-distributions/libplatform/blob/2512ffd8bb5c6caff3c8ea83331ab8a0adc820c3/include/os/lock.h#L116-L141
[lock-priv]: https://github.com/apple-oss-distributions/libplatform/blob/2512ffd8bb5c6caff3c8ea83331ab8a0adc820c3/private/os/lock_private.h
[lock-priv-spin]: https://github.com/apple-oss-distributions/libplatform/blob/2512ffd8bb5c6caff3c8ea83331ab8a0adc820c3/private/os/lock_private.h#L143-L161
[lock-priv-spi]: https://github.com/apple-oss-distributions/libplatform/blob/2512ffd8bb5c6caff3c8ea83331ab8a0adc820c3/private/os/lock_private.h#L236-L259
[lock-priv-opts]: https://github.com/apple-oss-distributions/libplatform/blob/2512ffd8bb5c6caff3c8ea83331ab8a0adc820c3/private/os/lock_private.h#L261-L298
[lock-c]: https://github.com/apple-oss-distributions/libplatform/blob/2512ffd8bb5c6caff3c8ea83331ab8a0adc820c3/src/os/lock.c
[lock-c-ulockval]: https://github.com/apple-oss-distributions/libplatform/blob/2512ffd8bb5c6caff3c8ea83331ab8a0adc820c3/src/os/lock.c#L426-L445
[lock-c-slow]: https://github.com/apple-oss-distributions/libplatform/blob/2512ffd8bb5c6caff3c8ea83331ab8a0adc820c3/src/os/lock.c#L559-L614
[lock-c-unlockslow]: https://github.com/apple-oss-distributions/libplatform/blob/2512ffd8bb5c6caff3c8ea83331ab8a0adc820c3/src/os/lock.c#L615-L643
[lock-c-fast]: https://github.com/apple-oss-distributions/libplatform/blob/2512ffd8bb5c6caff3c8ea83331ab8a0adc820c3/src/os/lock.c#L645-L736
[lock-c-nospin]: https://github.com/apple-oss-distributions/libplatform/blob/2512ffd8bb5c6caff3c8ea83331ab8a0adc820c3/src/os/lock.c#L963-L1000
[lock-c-once]: https://github.com/apple-oss-distributions/libplatform/blob/2512ffd8bb5c6caff3c8ea83331ab8a0adc820c3/src/os/lock.c#L1107-L1340
[osspin-h]: https://github.com/apple-oss-distributions/libplatform/blob/2512ffd8bb5c6caff3c8ea83331ab8a0adc820c3/include/libkern/OSSpinLockDeprecated.h
[once-h]: https://github.com/apple-oss-distributions/libplatform/blob/2512ffd8bb5c6caff3c8ea83331ab8a0adc820c3/private/os/once_private.h#L48-L60
[ulock-c]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/sys_ulock.c
[ulock-c-promo]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/sys_ulock.c#L72-L93
[ulock-c-ull]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/sys_ulock.c#L167-L263
[ulock-c-spin]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/sys_ulock.c#L586-L623
[ulock-c-wait]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/sys_ulock.c#L682-L740
[ulock-c-handoff]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/sys_ulock.c#L766-L775
[ulock-c-wake]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/sys_ulock.c#L1007-L1058
[pt-mutex]: https://github.com/apple-oss-distributions/libpthread/blob/42d026df5b07825070f60134b980a1ec2552dfee/src/pthread_mutex.c
[pt-firstfit]: https://github.com/apple-oss-distributions/libpthread/blob/42d026df5b07825070f60134b980a1ec2552dfee/src/pthread_mutex.c#L706-L752
[pt-ulock-criteria]: https://github.com/apple-oss-distributions/libpthread/blob/42d026df5b07825070f60134b980a1ec2552dfee/src/pthread_mutex.c#L1765-L1779
[pt-cond]: https://github.com/apple-oss-distributions/libpthread/blob/42d026df5b07825070f60134b980a1ec2552dfee/src/pthread_cond.c#L250-L262
[pt-types]: https://github.com/apple-oss-distributions/libpthread/blob/42d026df5b07825070f60134b980a1ec2552dfee/src/types_internal.h#L174-L213
[pt-ksynch]: https://github.com/apple-oss-distributions/libpthread/blob/42d026df5b07825070f60134b980a1ec2552dfee/kern/kern_synch.c
[pt-ksynch-fit]: https://github.com/apple-oss-distributions/libpthread/blob/42d026df5b07825070f60134b980a1ec2552dfee/kern/kern_synch.c#L2372-L2381
[pt-ptypes]: https://github.com/apple-oss-distributions/libpthread/blob/42d026df5b07825070f60134b980a1ec2552dfee/include/sys/_pthread/_pthread_types.h#L35-L82
