# Windows `WaitOnAddress`

Windows' futex: `WaitOnAddress` / `WakeByAddressSingle` / `WakeByAddressAll`
(Windows 8, 2012) compare-and-block on a 1-, 2-, 4- or 8-byte value — but the
wait-queue table lives **in user mode**, in `ntdll`, and the kernel only
provides a per-thread alert flag (`NtWaitForAlertByThreadId` /
`NtAlertThreadByThreadId`). The consequence for event loops is the defining
fact of this page: an address wait has no kernel object, so nothing can
associate it with an I/O completion port.

|                     |                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**            | OS wait primitive (user-mode table over a kernel thread-alert)                                                                                                                                                                                                                                                                                                                                                                               |
| **API**             | `WaitOnAddress`, `WakeByAddressSingle`, `WakeByAddressAll` (`synchapi.h`, `Synchronization.lib`, `api-ms-win-core-synch-l1-2-0.dll`); `RtlWaitOnAddress`/`RtlWakeAddress*` in `ntdll`; undocumented `NtWaitForAlertByThreadId`/`NtAlertThreadByThreadId`; keyed events `NtWaitForKeyedEvent`/`NtReleaseKeyedEvent` (XP)                                                                                                                      |
| **Versions**        | Windows 8 / Server 2012 ([MS Learn][ms-woa]); keyed events Windows XP; `NtAssociateWaitCompletionPacket` exported by `ntdll` (no import library); `SetIoRingCompletionEvent` build 22000                                                                                                                                                                                                                                                     |
| **Word sizes**      | 1, 2, 4 or 8 bytes                                                                                                                                                                                                                                                                                                                                                                                                                           |
| **Process scope**   | same process only                                                                                                                                                                                                                                                                                                                                                                                                                            |
| **Event-loop hook** | none for addresses; an _event handle_ can reach an IOCP via `NtAssociateWaitCompletionPacket` or a thread-pool wait                                                                                                                                                                                                                                                                                                                          |
| **Source read**     | MS Learn: [`WaitOnAddress`][ms-woa], [`WakeByAddressSingle`][ms-wbas], [`NtAssociateWaitCompletionPacket`][ms-nawcp], [`RegisterWaitForSingleObject`][ms-rwfso], [`PostQueuedCompletionStatus`][ms-pqcs], [`SetIoRingCompletionEvent`][ms-sirce]; Wine [`dlls/ntdll/sync.c`][wine-sync] and [`unix/sync.c`][wine-unix-sync] at `a15ee2ccf20e`; Raymond Chen, [_A peek behind the curtain of WaitOnAddress_][chen]; Go, Rust and Zig runtimes |

## Overview

### What it solves

The same problem as the Linux futex: wait for a variable to change without an
event object to create and keep in sync. The documentation frames it against
the alternatives ([MS Learn][ms-woa]):

> **WaitOnAddress** is more efficient than using the Sleep function inside a
> `while` loop because **WaitOnAddress** does not interfere with the thread
> scheduler. **WaitOnAddress** is also simpler to use than an event object
> because it is not necessary to create and initialize an event and then make
> sure it is synchronized correctly with the value.

### Design philosophy

Keep the table in the process. Raymond Chen describes the implementation
([Chen, 2016-08-26][chen]):

> all of the threads that have an outstanding WaitOnAddress call are kept on
> a lock-free hash table, keyed by the address. Once the thread adds itself to
> the hash table, the thread calls an internal kernel function to go to sleep.

The kernel's part is one buffered wake per thread: "If the wake call arrives
but the thread is not waiting on an address, then the kernel remembers the
address for that thread. […] This wake buffer is only one entry deep." Wine's
clean-room `ntdll` confirms the shape and names the kernel calls
([`sync.c`][wine-sync-comment]):

> On Windows they are implemented using NtAlertThreadByThreadId and
> NtWaitForAlertByThreadId, which manipulate a single flag (similar to an
> auto-reset event) per thread. This can be tested by attempting to wake a
> thread waiting in RtlWaitOnAddress() via NtAlertThreadByThreadId.

This is architecturally a [parking lot](./concepts.md#parking): a global
address-keyed table of waiter records plus a per-thread park/unpark token —
the same design as WebKit `ParkingLot` and Rust `parking_lot`, shipped by the OS.

## How it works

Wine's version is the readable reference ([`RtlWaitOnAddress`][wine-woa]):

- **Table**: `static struct futex_queue futex_queues[256]`, indexed by
  `(addr >> 4) % 256`; each queue is a list plus a spinlock
  (`InterlockedCompareExchange` + `YieldProcessor`).
- **Wait**: put `{ addr, tid }` on the stack, lock the queue, compare the
  1/2/4/8-byte value ("Do the comparison inside of the spinlock, to reduce
  spurious wakeups"), return success if it differs, else append to the list
  (FIFO), unlock, and `NtWaitForAlertByThreadId(NULL, timeout)`. On return,
  remove the entry if a waker has not already done so.
- **Wake single**: lock, take the first entry with a matching address, clear
  its `addr` and unlink it — "so that a simultaneous call to
  RtlWakeAddressSingle() will not also wake it—two simultaneous calls must wake
  at least two waiters if they exist" — unlock, then
  `NtAlertThreadByThreadId(tid)` outside the lock ([`RtlWakeAddressSingle`][wine-wake1]).
- **Wake all**: collect up to 256 TIDs, unlock, `NtAlertMultipleThreadByThreadId`.
- **The alert flag**, in Wine's Unix layer, is a per-TID futex word on Linux, a
  per-thread kqueue with `EVFILT_USER` on macOS/BSD, or an NT event otherwise
  ([`tid_alert_entry`][wine-alert-entry], [`NtWaitForAlertByThreadId`][wine-wait-alert]).
  Alerting sets the flag and wakes; waiting consumes it with
  `InterlockedExchange(futex, 0)` — so an alert that arrives before the wait is
  not lost, which is the buffered wake Chen describes.

**Keyed events** (`NtCreateKeyedEvent`, `NtWaitForKeyedEvent`,
`NtReleaseKeyedEvent`) predate this: a kernel object (one process-wide
instance is enough) that matches waiters and releasers by an arbitrary even
pointer-sized key. Rust's Windows 7 parker documents the critical difference
([`windows7.rs`][rust-win7]): `NtWaitForKeyedEvent` "unconditionally blocks
without checking the parker state first. Instead, NtReleaseKeyedEvent (unlike
WakeByAddressSingle) _blocks_ until it woke up a thread waiting for it". A
release therefore needs a known waiter — keyed events are a rendezvous, not a
compare-and-block.

**Locks on top.** SRWLOCK and CONDITION_VARIABLE are pointer-sized words
(see [`windows-srwlock`](./windows-srwlock.md)). Wine implements both directly
on `RtlWaitOnAddress`: the condvar is a sequence counter
(`InterlockedIncrement(&variable->Ptr); RtlWakeAddressSingle(variable)`), and
waiting releases the SRW lock and waits on the counter's captured value
([`RtlSleepConditionVariableSRW`][wine-cv]). Wine's SRWLOCK header comment still
says "This implementation uses two keyed events" while the code below it calls
`RtlWaitOnAddress` — a stale comment, not a second mechanism.

## Analysis

### Semantics

Compare-and-block against a caller-supplied comparand (`CompareAddress` points
to the "previously observed value"), wake one or all. Documented order: "If
multiple threads are waiting for this address, the system wakes the first
thread to wait" ([`WakeByAddressSingle`][ms-wbas]). Chen calls that claim
descriptive, not normative, and inaccurate: "a spurious wake takes a thread
out of the queue, and then it re-enters the queue at the end. […] a future
version of WaitOnAddress may choose to dispense with FIFO waking in order to
add convoy resistance" ([Chen][chen]). No bitsets, no requeue, no wait-on-many.

### Sizes and alignment

`AddressSize` "can be `1`, `2`, `4`, or `8`" ([MS Learn][ms-woa]); Wine rejects
anything else with `STATUS_INVALID_PARAMETER`. No alignment requirement is
documented; because the table is keyed by address only, waiters on overlapping
addresses of different sizes share a queue. This is what lets Rust `std` give
Windows a **one-byte** futex: `pub type SmallPrimitive = u8;`
([`futex.rs`][rust-win-futex]), while Linux's `SmallPrimitive` is `u32`.

### Timeouts and clocks

`dwMilliseconds`, relative, `INFINITE` for none; failure by timeout reports
`ERROR_TIMEOUT`. `RtlWaitOnAddress` takes an NT `LARGE_INTEGER` (negative =
relative in 100 ns units, positive = absolute system time); `kernelbase`
converts milliseconds to the relative form ([`WaitOnAddress`][wine-kb-woa]). No
clock choice is offered; millisecond granularity is the documented floor.

### Spurious wakeups and wake counts

Spurious returns are part of the contract: "**WaitOnAddress** is guaranteed to
return when the address is signaled, but it is also allowed to return for
other reasons", including low memory, "A previous wake on the same address was
abandoned", and checked builds ([MS Learn][ms-woa]). Chen shows the mechanism:
a wake buffered during an earlier, skipped wait completes the next wait
immediately — "Result: Spurious wake." The wakers return `VOID`: there is no
count of threads woken and no way to know whether anyone was waiting.

### Process scope

Same process only — "Only a thread within the same process can be woken"
([`WakeByAddressSingle`][ms-wbas]). Inter-process waiting needs a named event,
semaphore or mutex handle. This follows from the design: the hash table is
process memory.

### Cost

Not measured here (no Windows host). Structurally the uncontended wake is
cheaper than Linux's: `RtlWakeAddressSingle` hashes, takes a user-mode
spinlock and finds no entry without entering the kernel, so "is anyone
waiting" is answered in user space; only an actual wake costs a syscall
(`NtAlertThreadByThreadId`). The wait costs one syscall plus the table
operations. The table is per process, so unrelated processes cannot collide
— the problem Linux addressed with its 6.16 private hash.

### Event-loop integration

`WaitOnAddress` cannot be handed to an IOCP: there is no handle to wait on, and
the alert it parks on is per thread. The bridges therefore go through a
**kernel object**, usually an event:

- **`NtAssociateWaitCompletionPacket`** — "When the object is signaled, a
  packet is queued to the supplied completion port […] When the packet is
  picked up, the association must be reestablished by calling this function
  again" ([MS Learn][ms-nawcp]). One packet object per armed wait; no thread
  blocks. The page documents only `ntdll` export, no header or import library.
  Go's runtime uses it for high-resolution timers on its IOCP poller: it arms
  a waitable timer, associates it, and on re-arm calls
  `NtCancelWaitCompletionPacket`, handling `STATUS_PENDING` ("the wait
  operation can't be canceled yet") as a race to tolerate
  ([`netpoll_windows.go`][go-netpoll]); it probes for the three functions at
  start-up and falls back when they are missing ([`os_windows.go`][go-os]).
- **`RegisterWaitForSingleObject`** — "Directs a wait thread in the thread
  pool to wait on the object" ([MS Learn][ms-rwfso]); the callback can
  `PostQueuedCompletionStatus`. Costs a wait thread per up to 63 handles
  (Wine: `MAXIMUM_WAITQUEUE_OBJECTS` = `MAXIMUM_WAIT_OBJECTS - 1`,
  [`threadpool.c`][wine-tp]); edge-sensitive events can be missed ("you should
  not pulse an event object passed to **RegisterWaitForSingleObject**").
- **`PostQueuedCompletionStatus`** — the waker posts directly: "The system
  does not use or validate these values" ([MS Learn][ms-pqcs]). The cheapest
  bridge, but the waker must know the loop's port — it breaks the
  "unmodified waker" property a word-based registry wants.
- **`SetIoRingCompletionEvent`** (IoRing, build 22000) is the same event→loop
  bridge in the other direction: "the kernel only sets the event to the
  signaled state when the completion queue transitions from the empty to
  non-empty state" ([MS Learn][ms-sirce]) — so a loop that also waits on IOCP
  or on other objects must drain the ring fully before waiting again.

For a fiber-side `WaitWord` on Windows the realistic design is therefore
user-space: register the fiber in the loop's own address-keyed table and have
the waker, after its `WakeByAddress*`, post a completion to the loop's port
(the "registry" variant), or give each word a lazily created event and use a
wait completion packet (the "handle" variant, one kernel object per word).

### Availability and versions

`WaitOnAddress` family: Windows 8 / Server 2012 and later, desktop and UWP;
Microsoft Store apps link `synchronization.lib`. Keyed events: Windows XP on,
undocumented — Rust used them only below Windows 8, judging the risk acceptable
because "we only use it for older versions of Windows" ([`windows7.rs`][rust-win7]).
`NtWaitForAlertByThreadId`/`NtAlertThreadByThreadId` are undocumented `ntdll`
exports; Zig's `std.Io.Threaded` parks on them directly on Windows, noting
"RtlWaitOnAddress is a userland implementation anyway" and that the address
argument to `NtWaitForAlertByThreadId` appears unused ([`Threaded.zig`][zig-threaded]).
Their first Windows version is not documented by any source read here; Wine's
comment ties them to the `WaitOnAddress` implementation, which implies
Windows 8.

## Strengths

- **Any of 1/2/4/8 bytes** — the only OS primitive here that waits on a byte.
- **User-mode "anyone waiting?" check**: a wake with no waiters costs no
  syscall.
- **Per-process table**: no cross-process bucket contention.
- Documented and supported since Windows 8; SRWLOCK and condvars sit on the
  same machinery.

## Weaknesses

- **No completion-port integration** for addresses; every loop bridge needs a
  kernel object or a waker that knows the port.
- **No wake count**, no requeue, no bitset, no wait-on-many.
- Millisecond relative timeouts only (at the Win32 layer).
- Same-process only.
- FIFO is documented but, per Microsoft's own blog, not a contract.

## Key design decisions and trade-offs

| Decision                                        | Rationale                                                         | Trade-off                                                                     |
| ----------------------------------------------- | ----------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| Hash table of waiters in user mode              | No kernel state per address; empty wakes stay in user space       | Same-process only; no handle, so no IOCP/WaitForMultipleObjects participation |
| Kernel provides a per-thread alert, buffered ×1 | Closes the add-to-table / go-to-sleep race without a kernel queue | Buffered wakes surface as spurious returns                                    |
| Arbitrary value size (1–8 bytes)                | Byte locks and pointer-sized words wait directly                  | Overlapping addresses share queues                                            |
| Wakers return nothing                           | Simplest API                                                      | Callers cannot tell whether a waiter existed; must track waiters in the word  |
| Keyed events (pre-8) block the releaser         | Rendezvous guarantees no lost wake without a value check          | Release must not run unless a waiter is known to be coming                    |

## Sources

- MS Learn: [`WaitOnAddress`][ms-woa], [`WakeByAddressSingle`][ms-wbas], [`NtAssociateWaitCompletionPacket`][ms-nawcp], [`RegisterWaitForSingleObject`][ms-rwfso], [`PostQueuedCompletionStatus`][ms-pqcs], [`SetIoRingCompletionEvent`][ms-sirce]
- Raymond Chen, [_Spurious wakes, race conditions, and bogus FIFO claims: A peek behind the curtain of WaitOnAddress_][chen], The Old New Thing, 2016-08-26
- Wine `a15ee2ccf20e` (2026-10-09): [`dlls/ntdll/sync.c`][wine-sync] (`RtlWaitOnAddress`, condvars, SRW locks), [`dlls/ntdll/unix/sync.c`][wine-unix-sync] (thread alerts, keyed events), [`dlls/kernelbase/sync.c`][wine-kb-woa], [`dlls/ntdll/threadpool.c`][wine-tp]
- Go `runtime` at `015343854b5d`: [`netpoll_windows.go`][go-netpoll], [`os_windows.go`][go-os]
- Rust `std` at `3bf5c6d99bc8`: [`thread_parking/windows7.rs`][rust-win7], [`pal/windows/futex.rs`][rust-win-futex]
- Zig `std` at `1bcd8d9fe60f`: [`Io/Threaded.zig`][zig-threaded]

> [!NOTE]
> **Unverified.** Windows itself was not run or disassembled; the in-kernel
> behaviour is taken from Chen's description and Wine's reimplementation.
> Wine's sparse clone has no `NtAssociateWaitCompletionPacket`
> implementation to compare against.

<!-- References -->

[ms-woa]: https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-waitonaddress
[ms-wbas]: https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-wakebyaddresssingle
[ms-nawcp]: https://learn.microsoft.com/en-us/windows/win32/devnotes/ntassociatewaitcompletionpacket
[ms-rwfso]: https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-registerwaitforsingleobject
[ms-pqcs]: https://learn.microsoft.com/en-us/windows/win32/api/ioapiset/nf-ioapiset-postqueuedcompletionstatus
[ms-sirce]: https://learn.microsoft.com/en-us/windows/win32/api/ioringapi/nf-ioringapi-setioringcompletionevent
[chen]: https://devblogs.microsoft.com/oldnewthing/20160826-00/?p=94185
[wine-sync]: https://gitlab.winehq.org/wine/wine/-/blob/a15ee2ccf20e2fc9f470badd916855801933d31f/dlls/ntdll/sync.c
[wine-sync-comment]: https://gitlab.winehq.org/wine/wine/-/blob/a15ee2ccf20e2fc9f470badd916855801933d31f/dlls/ntdll/sync.c#L814
[wine-woa]: https://gitlab.winehq.org/wine/wine/-/blob/a15ee2ccf20e2fc9f470badd916855801933d31f/dlls/ntdll/sync.c#L878
[wine-wake1]: https://gitlab.winehq.org/wine/wine/-/blob/a15ee2ccf20e2fc9f470badd916855801933d31f/dlls/ntdll/sync.c#L970
[wine-cv]: https://gitlab.winehq.org/wine/wine/-/blob/a15ee2ccf20e2fc9f470badd916855801933d31f/dlls/ntdll/sync.c#L794
[wine-unix-sync]: https://gitlab.winehq.org/wine/wine/-/blob/a15ee2ccf20e2fc9f470badd916855801933d31f/dlls/ntdll/unix/sync.c
[wine-alert-entry]: https://gitlab.winehq.org/wine/wine/-/blob/a15ee2ccf20e2fc9f470badd916855801933d31f/dlls/ntdll/unix/sync.c#L3404
[wine-wait-alert]: https://gitlab.winehq.org/wine/wine/-/blob/a15ee2ccf20e2fc9f470badd916855801933d31f/dlls/ntdll/unix/sync.c#L3587
[wine-kb-woa]: https://gitlab.winehq.org/wine/wine/-/blob/a15ee2ccf20e2fc9f470badd916855801933d31f/dlls/kernelbase/sync.c#L531
[wine-tp]: https://gitlab.winehq.org/wine/wine/-/blob/a15ee2ccf20e2fc9f470badd916855801933d31f/dlls/ntdll/threadpool.c#L99
[go-netpoll]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/netpoll_windows.go#L245
[go-os]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/runtime/os_windows.go#L283
[rust-win7]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/sync/thread_parking/windows7.rs#L1
[rust-win-futex]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/pal/windows/futex.rs#L20
[zig-threaded]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io/Threaded.zig#L17376
