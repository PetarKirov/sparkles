# `SRWLOCK`, `CONDITION_VARIABLE` and `CRITICAL_SECTION` (Windows)

The Win32 user-mode locks: a pointer-sized, zero-initialised, never-destroyed
reader-writer lock and condition variable (Vista, 2006), beside the older
recursive `CRITICAL_SECTION` — documented only by their contracts, with the
implementation reconstructed here from Wine's `ntdll`, which builds both on
its own `RtlWaitOnAddress`.

|                       |                                                                                                                                                                                                                                                                                    |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**              | OS user-mode synchronization API (`kernel32`/`kernelbase` exports over `ntdll` `Rtl*` routines)                                                                                                                                                                                    |
| **Language**          | C (Win32 API)                                                                                                                                                                                                                                                                      |
| **License**           | Windows: proprietary, source not public. Wine reimplementation: LGPL-2.1-or-later                                                                                                                                                                                                  |
| **Repository**        | Contract: Microsoft Learn ([SRW locks][ms-srw], [condition variables][ms-cv], [`EnterCriticalSection`][ms-ecs], [`InitializeCriticalSectionAndSpinCount`][ms-icsasc]). Implementation studied: [`wine/wine`][wine-repo] `dlls/ntdll/sync.c`                                        |
| **Availability**      | `SRWLOCK`, `CONDITION_VARIABLE`: Windows Vista / Server 2008 ("Windows Server 2003 and Windows XP: Condition variables are not supported", [MS Learn][ms-cv]); `CRITICAL_SECTION`: all Win32                                                                                       |
| **Lock word**         | `SRWLOCK`, `CONDITION_VARIABLE`: one pointer (`RTL_SRWLOCK { PVOID Ptr; }`); `CRITICAL_SECTION`: 6 fields (`DebugInfo`, `LockCount`, `RecursionCount`, `OwningThread`, `LockSemaphore`, `SpinCount`)                                                                               |
| **Parking substrate** | Windows: undocumented for `SRWLOCK` (keyed events and thread alerts are covered in [Windows WaitOnAddress](./windows-wait-on-address.md)); `CRITICAL_SECTION`: a semaphore per section; Wine: `RtlWaitOnAddress` over a 256-bucket hashed queue table + `NtWaitForAlertByThreadId` |
| **Source read**       | MS Learn pages above; Wine [`dlls/ntdll/sync.c`][wine-sync] and [`include/winnt.h`][wine-winnt]; [microsoft/STL#4448][stl-4448]; [rust-lang/rust#121949][rust-121949]; Joe Duffy, [_Anti-convoy locks in Windows Server 2003 SP1 and Windows Vista_][duffy] (2006-12-14)           |

> [!IMPORTANT]
> Microsoft does not publish the `SRWLOCK` implementation. Everything on this
> page about _semantics_ comes from MS Learn and the two 2024 bug reports;
> everything about _algorithms_ comes from Wine, a clean-room reimplementation
> that matches the documented contract but is not Windows' algorithm (Wine's
> SRW lock is writer-preferring and keeps two 16-bit counters in the word). Neither source shows Windows' internal word layout.

## Overview

### What it solves

The SRW page states the two properties that matter — size and process scope —
and then disclaims ordering ([MS Learn, SRW locks][ms-srw]):

> Slim reader/writer (SRW) locks enable the threads of a single process to
> access shared resources; they are optimized for speed and occupy very little
> memory. Slim reader-writer locks cannot be shared across processes.
>
> […] There is no guarantee about the order in which threads that request
> ownership will be granted ownership; SRW locks are neither fair nor FIFO.
>
> An SRW lock is the size of a pointer. The advantage is that it is fast to
> update the lock state. The disadvantage is that very little state
> information can be stored, so SRW locks do not detect incorrect recursive use
> in shared mode. In addition, a thread that owns an SRW lock in shared mode
> cannot upgrade its ownership of the lock to exclusive mode.

Initialisation is either `InitializeSRWLock` or assigning `SRWLOCK_INIT`;
there is no delete function. `CONDITION_VARIABLE` follows the same pattern
(`CONDITION_VARIABLE_INIT`) and pairs with either lock type.

### Design philosophy

**Give up fairness to kill convoys.** Duffy's 2006 post records the change
that Windows Server 2003 SP1 and Vista made to all Windows locks. Before it, a
releaser "would modify the lock's state so that it appeared as if the next
thread in the wait queue already owned it"; after it ([Duffy][duffy]):

> a FIFO waking algorithm is still used, but the lock is immediately marked as
> unavailable [sic]. Another thread
> can sneak in and take the lock before the woken thread is even scheduled
> […]. If another thread steals the lock, the woken thread may subsequently
> have to rewait, meaning it must go to the back of the queue, again
> disturbing the nice FIFO ordering.

MS Learn's critical-section reference carries the same disclaimer: "There is
no guarantee about the order in which waiting threads will acquire ownership
of the critical section" ([`EnterCriticalSection`][ms-ecs]).

**No owner, no state beyond a pointer.** Wine's notes record the consequence
its tests found ([`sync.c`][wine-srw-init]): "Please note that SRWLocks do not
keep track of the owner of a lock. It doesn't make any difference which thread
for example unlocks an SRWLock (see corresponding tests)."

## How it works

Wine fits the SRW lock into 4 of the pointer's bytes
([`sync.c`][wine-srw-struct]):

```c
struct srw_lock
{
    /* bit 0 - if the lock is held exclusive. bit 1.. - number of exclusive waiters. */
    short exclusive_waiters;

    /* Number of owners.
     *
     * Sadly Windows has no equivalent to FUTEX_WAIT_BITSET, so in order to wake
     * up *only* exclusive or *only* shared waiters (and thus avoid spurious
     * wakeups), we need to wait on two different addresses.
     * RtlAcquireSRWLockShared() needs to know the values of "exclusive_waiters"
     * and "owners", but RtlAcquireSRWLockExclusive() only needs to know the
     * value of "owners", so the former can wait on the entire structure, and
     * the latter waits only on the "owners" member. Note then that "owners"
     * must not be the first element in the structure.
     */
    unsigned short owners;
};
C_ASSERT( sizeof(struct srw_lock) == 4 );
```

- **Exclusive acquire** adds 2 to `exclusive_waiters` up front, then CAS-loops:
  if `owners == 0`, set `owners = 1`, subtract the 2, set bit 0, return;
  otherwise `RtlWaitOnAddress(&owners, &new.owners, 2, NULL)` and retry
  ([`RtlAcquireSRWLockExclusive`][wine-srw-excl]).
- **Shared acquire** succeeds only when `exclusive_waiters == 0` — no holder
  _and no queued writer_ — by incrementing `owners`; otherwise it waits on the
  whole 4-byte word ([`RtlAcquireSRWLockShared`][wine-srw-shared]).
- **Exclusive release** clears `owners` and bit 0, then wakes one exclusive
  waiter (`RtlWakeAddressSingle(&owners)`) if any are counted, otherwise all
  shared waiters (`RtlWakeAddressAll(whole word)`)
  ([`RtlReleaseSRWLockExclusive`][wine-srw-rel]).
- **Shared release** decrements `owners` and, at zero, wakes one waiter on
  `&owners`.

The two wait addresses are Wine's substitute for Linux's
`FUTEX_WAIT_BITSET` (see [Linux futex](./linux-futex.md)): exclusive waiters
sleep on the 2-byte `owners` half, shared waiters on the 4-byte whole, so a
writer release can wake exactly one class. (The `RtlInitializeSRWLock` note above
the code still says "This implementation uses two keyed events" and "is
limited to 2^15-1 waiting threads" — the first is stale, the code waits on
addresses; the second still follows from the `short` counter.)

`RtlWaitOnAddress` itself is a user-space parking lot
([`sync.c`][wine-woa]): 256 `futex_queue` buckets hashed by `(addr >> 4) %
256`, each a spin-locked intrusive list of stack-allocated `futex_entry {
addr, tid }`; the compare runs under the bucket spinlock "to reduce spurious
wakeups"; the waiter blocks in `NtWaitForAlertByThreadId`, and wakers collect
thread ids under the spinlock, then call `NtAlertThreadByThreadId` (or
`NtAlertMultipleThreadByThreadId`) after dropping it — "Try not to make a
system call while holding a spinlock". The header comment explains the choice:

> On Windows they are implemented using NtAlertThreadByThreadId and
> NtWaitForAlertByThreadId, which manipulate a single flag (similar to an
> auto-reset event) per thread.

## Analysis

### State word and fast path

`SRWLOCK` is one pointer, zero meaning unlocked; Windows' use of the other
bits is undocumented. In Wine the uncontended exclusive acquire is two RMWs
(an `InterlockedExchangeAdd16` of the waiter count, then a 32-bit
`InterlockedCompareExchange`) — the up-front increment is what makes the lock
writer-preferring — and release is one CAS plus an unconditional
`RtlWakeAddress*` call; Wine does not skip the wake when nobody waits, though
its `RtlWakeAddress*` is a bucket-spinlock scan, not a syscall, when the queue
is empty. All `Interlocked*` operations are full barriers. `CRITICAL_SECTION`
is a classic counter lock ([`RtlEnterCriticalSection`][wine-cs-enter]):
`LockCount` starts at `-1`; `InterlockedIncrement` to `0` acquires; a positive
result is either recursion (`OwningThread` is us → `RecursionCount++`) or
contention; leave decrements, and a result `>= 0` means someone is waiting.

### Waiting: spin, yield, park

`SRWLOCK`: MS Learn documents no spin policy, and Wine's SRW lock does not
spin. `CRITICAL_SECTION` is the documented spinner
([MS Learn][ms-icsasc]): "On single-processor systems, the spin count is
ignored and the critical section spin count is set to 0 (zero). On
multiprocessor systems, if the critical section is unavailable, the calling
thread spins _dwSpinCount_ times before performing a wait operation on a
semaphore associated with the critical section", and "the heap manager uses a
spin count of roughly 4,000 for its per-heap critical sections". Wine follows
it, with one refinement: the spin loop gives up early when `LockCount > 0`,
"more than one waiter, don't bother spinning", and uses `YieldProcessor()`
(`pause`) between probes ([`RtlEnterCriticalSection`][wine-cs-enter]).

### The parking substrate

How Windows parks an `SRWLOCK` waiter is undocumented. What a pointer-sized
lock with no destructor rules out is a kernel object per lock, so the waiter
must block on something keyed by address or thread; Wine's comment records
that Windows' own `WaitOnAddress` uses "NtAlertThreadByThreadId and
NtWaitForAlertByThreadId" (see [Windows WaitOnAddress](./windows-wait-on-address.md)
for keyed events and thread alerts). `CRITICAL_SECTION` is documented to wait
"on a semaphore associated with the critical section" ([MS Learn][ms-icsasc]),
the `LockSemaphore` field; [`InitializeCriticalSectionAndSpinCount`][ms-icsasc] notes
that since Vista it "always succeeds, even in low memory situations". Wine
mirrors that: `wait_semaphore` uses a real semaphore only if one was installed,
otherwise it treats `LockSemaphore` as a word and waits on it with
`RtlWaitOnAddress`, with a 5-second timeout that logs and retries
([`wait_semaphore`][wine-cs-wait]). Waiter records are always on the waiter's
stack (Wine's `futex_entry`; `RtlRunOnceBeginInitialize` even links waiters
through the `RTL_RUN_ONCE` pointer itself, `next = val & ~3`, and parks each on
a keyed event keyed by its stack slot, [`sync.c`][wine-runonce]).

### Fairness, handoff and starvation

Documented as unfair ("neither fair nor FIFO"). The cost of that freedom
surfaced in 2024: Microsoft's STL team reported that `SRWLOCK` "can grant
exclusive ownership when we requested shared ownership"
([microsoft/STL#4448][stl-4448], opened 2024-03-05). The issue attributes it
to a convoy-avoidance optimisation present since Windows Server 2003 SP1 that
lets a shared acquire that races an exclusive release be granted the lock
exclusively; with several readers arriving together, shared holders could be
limited to one at a time, deadlocking programs (a barrier inside a read lock)
that rely on concurrent readers. Rust hit the same deadlock
([rust-lang/rust#121949][rust-121949], 2024-03-03) and moved `RwLock` off
`SRWLOCK` onto `WaitOnAddress` (PR `#121956`, merged 2024-03-06; see
[Rust std::sync](./rust-std-sync.md)). The STL issue was closed on 2024-05-08
noting that Windows removed the implicit upgrade in a future release, with
backporting described as highly unlikely. Wine's lock is writer-preferring:
any counted exclusive waiter blocks new readers, so writers cannot starve but
readers can. `CRITICAL_SECTION` in Wine is the opposite of Windows: leave
decrements `LockCount` and wakes one waiter, and the woken thread owns the lock
without re-checking — a [handoff](./concepts.md#barging-and-handoff) lock,
which is the pre-2003-SP1 behaviour Duffy describes.

### Condition variables and predicates

The contract ([MS Learn][ms-cv]): `SleepConditionVariableSRW`/`CS` release the
lock and sleep "as an atomic operation"; after waking the thread "re-acquires
the lock it released"; and "Condition variables are subject to spurious
wakeups (those not associated with an explicit wake) and stolen wakeups
(another thread manages to run before the woken thread). Therefore, you should
recheck a predicate (typically in a **while** loop)". MS Learn also advises
that "It is usually better to release the lock before waking other threads to
reduce the number of context switches" — i.e. no
[wait morphing](./concepts.md#wait-morphing) is promised. Wine's
implementation is the minimal sequence-counter condvar
([`RtlSleepConditionVariableSRW`][wine-cv]):

```c
int value = *(int *)&variable->Ptr;   /* read sequence */
RtlReleaseSRWLockExclusive( lock );   /* or Shared, per flags */
status = RtlWaitOnAddress( &variable->Ptr, &value, sizeof(value), timeout );
RtlAcquireSRWLockExclusive( lock );
```

`Wake` and `WakeAll` increment the counter and call `RtlWakeAddressSingle` or
`RtlWakeAddressAll` ([`sync.c`][wine-cv]). The counter read before release
closes the lost-wakeup window; `WakeAll` is a
[thundering herd](./concepts.md#thundering-herd) onto the lock, with no
requeue. The `RTL_CONDITION_VARIABLE_LOCKMODE_SHARED` flag lets a reader sleep
and re-acquire shared.

### Footprint and layout

`SRWLOCK` and `CONDITION_VARIABLE`: 8 bytes on 64-bit, zero-initialised, no
destroy, process-private, must not move while waited on (Wine's waits key on
the address). `CRITICAL_SECTION`: 40 bytes on 64-bit (pointer, two `LONG`s,
two `HANDLE`s, `ULONG_PTR`; [`winnt.h`][wine-winnt-cs]), requires
`InitializeCriticalSection*` and `DeleteCriticalSection`, and "cannot be moved
or copied" ([MS Learn][ms-icsasc]). MS Learn's SRW page adds that "Shared mode
SRW locks should not be acquired recursively as this can lead to deadlocks
when combined with exclusive acquisition" ([MS Learn][ms-srw]) — Wine's
writer preference makes that concrete.

### Portability

Windows only; the primitives are what `std::mutex`/`std::shared_mutex` in the
MSVC STL and many runtimes sit on, which is why the 2024 bug reached C++ and
Rust. Wine provides the same ABI on Linux and macOS on top of its own
wait-on-address. For a D library the transferable contract is the one MS
Learn states: pointer-sized, `0` = unlocked, no destructor, process-private,
not fair. `SleepConditionVariable*` is the only Windows condvar, and it accepts
either lock type.

### Async and fiber integration

None. Neither object has a `HANDLE`, so it cannot be passed to
`WaitForMultipleObjects`, registered with `RegisterWaitForSingleObject`, or
associated with an I/O completion port; a thread blocked in `AcquireSRWLock*`
or `SleepConditionVariable*` is unavailable to its event loop. Fibers
(`ConvertThreadToFiber`) do not help: SRW and critical sections block the
whole thread, and Wine's `RtlWaitOnAddress` records the waiter by
`GetCurrentThreadId()`. A wake that must reach an IOCP loop has to be
delivered separately (`PostQueuedCompletionStatus`) — which is the gap a
loop-aware `WaitWord` registry fills.

## Strengths

- Pointer-sized, static-initialisable (`SRWLOCK_INIT`), no destroy: the
  property set a D `Mutex` wants.
- One condition variable works with both lock types and both lock modes.
- No owner tracking means release from any thread works (Wine tests).
- `CRITICAL_SECTION` offers a documented, tunable spin count.

## Weaknesses

- Implementation unpublished; behaviour beyond the contract (fairness,
  reader/writer preference) has changed between Windows releases.
- The 2005–2024 implicit-upgrade bug violated the shared-ownership contract.
- No recursion detection in shared mode, no upgrade, no owner for priority
  inheritance.
- No `HANDLE`: unusable in `WaitForMultipleObjects`/IOCP.
- `WakeAllConditionVariable` has no requeue.

## Key design decisions and trade-offs

| Decision                                    | Rationale                                           | Trade-off                                                          |
| ------------------------------------------- | --------------------------------------------------- | ------------------------------------------------------------------ |
| Pointer-sized lock, no destroy              | Embed anywhere; no allocation, no cleanup           | Little room for state: no owner, no recursion checks               |
| Unfair (since 2003 SP1)                     | Avoid convoys from handing off to a sleeping thread | Starvation; woken waiters "go to the back of the queue"            |
| Park on keyed events / thread alerts        | No kernel object per lock                           | Waiting is per-thread; nothing an event loop can poll              |
| Shared→exclusive implicit upgrade (pre-fix) | Convoy avoidance on release races                   | Broke concurrent-reader guarantees; removed after the 2024 reports |
| Wine: two wait addresses in one word        | Wake only writers or only readers without bitsets   | Writer preference; 15-bit waiter count                             |
| Sequence-counter condvar (Wine)             | Minimal, correct, no waiter list                    | Spurious wakes and herds; no wait morphing                         |

## Sources

- Microsoft Learn: [Slim Reader/Writer (SRW) Locks][ms-srw],
  [Condition Variables][ms-cv], [`EnterCriticalSection`][ms-ecs],
  [`InitializeCriticalSectionAndSpinCount`][ms-icsasc].
- Wine at `a15ee2ccf20e2fc9f470badd916855801933d31f`:
  [`dlls/ntdll/sync.c`][wine-sync], [`include/winnt.h`][wine-winnt].
- [microsoft/STL#4448][stl-4448]; [rust-lang/rust#121949][rust-121949].
- Joe Duffy, [Anti-convoy locks in Windows Server 2003 SP1 and Windows
  Vista][duffy], 2006-12-14.

<!-- References -->

[ms-srw]: https://learn.microsoft.com/en-us/windows/win32/sync/slim-reader-writer--srw--locks
[ms-cv]: https://learn.microsoft.com/en-us/windows/win32/sync/condition-variables
[ms-ecs]: https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-entercriticalsection
[ms-icsasc]: https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-initializecriticalsectionandspincount
[wine-repo]: https://gitlab.winehq.org/wine/wine/-/tree/a15ee2ccf20e2fc9f470badd916855801933d31f
[wine-sync]: https://gitlab.winehq.org/wine/wine/-/blob/a15ee2ccf20e2fc9f470badd916855801933d31f/dlls/ntdll/sync.c
[wine-runonce]: https://gitlab.winehq.org/wine/wine/-/blob/a15ee2ccf20e2fc9f470badd916855801933d31f/dlls/ntdll/sync.c#L56-L100
[wine-cs-wait]: https://gitlab.winehq.org/wine/wine/-/blob/a15ee2ccf20e2fc9f470badd916855801933d31f/dlls/ntdll/sync.c#L170-L189
[wine-cs-enter]: https://gitlab.winehq.org/wine/wine/-/blob/a15ee2ccf20e2fc9f470badd916855801933d31f/dlls/ntdll/sync.c#L348-L449
[wine-srw-struct]: https://gitlab.winehq.org/wine/wine/-/blob/a15ee2ccf20e2fc9f470badd916855801933d31f/dlls/ntdll/sync.c#L471-L489
[wine-srw-init]: https://gitlab.winehq.org/wine/wine/-/blob/a15ee2ccf20e2fc9f470badd916855801933d31f/dlls/ntdll/sync.c#L491-L504
[wine-srw-excl]: https://gitlab.winehq.org/wine/wine/-/blob/a15ee2ccf20e2fc9f470badd916855801933d31f/dlls/ntdll/sync.c#L506-L547
[wine-srw-shared]: https://gitlab.winehq.org/wine/wine/-/blob/a15ee2ccf20e2fc9f470badd916855801933d31f/dlls/ntdll/sync.c#L549-L586
[wine-srw-rel]: https://gitlab.winehq.org/wine/wine/-/blob/a15ee2ccf20e2fc9f470badd916855801933d31f/dlls/ntdll/sync.c#L588-L634
[wine-cv]: https://gitlab.winehq.org/wine/wine/-/blob/a15ee2ccf20e2fc9f470badd916855801933d31f/dlls/ntdll/sync.c#L700-L812
[wine-woa]: https://gitlab.winehq.org/wine/wine/-/blob/a15ee2ccf20e2fc9f470badd916855801933d31f/dlls/ntdll/sync.c#L814-L1000
[wine-winnt]: https://gitlab.winehq.org/wine/wine/-/blob/a15ee2ccf20e2fc9f470badd916855801933d31f/include/winnt.h
[wine-winnt-cs]: https://gitlab.winehq.org/wine/wine/-/blob/a15ee2ccf20e2fc9f470badd916855801933d31f/include/winnt.h#L6340-L6359
[stl-4448]: https://github.com/microsoft/STL/issues/4448
[rust-121949]: https://github.com/rust-lang/rust/issues/121949
[duffy]: https://joeduffyblog.com/2006/12/14/anticonvoy-locks-in-windows-server-2003-sp1-and-windows-vista/
