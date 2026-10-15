---
status: draft
owner: sparkles:base
reviewed: 2026-10-12
---

# Synchronization primitives — Specification

## Abstract

`sparkles.base.sync` provides the locks, condition variables and waiting
primitives that Sparkles code shares between threads: a mutex, a condition
variable, a reader–writer lock, a one-time initializer, a semaphore, events,
barriers and latches, and a wait on a memory word. They are built on one
parking lot, a fixed table of waiter queues keyed by address, so each
primitive's state is a byte or a word and no operation allocates. The same
queues hold sleeping threads and suspended fibers, so every primitive also
works from a fiber on an event loop without blocking the loop's thread. The
library runs on Linux, Windows, macOS and FreeBSD over each kernel's
wait-on-address primitive.

## Introduction

Sparkles programs share state between threads and, through
`sparkles:event-horizon`, between fibers: stackful coroutines that each event
loop runs on its own thread. Both need to wait: for a lock to be released,
for a condition to become true, for a count to reach zero. A waiting thread
should sleep rather than burn a core, and a waiting fiber should suspend so
that its loop can run other fibers. D's runtime offers class-based wrappers
over each operating system's mutex and condition variable: every lock is a
heap object, and none can suspend a fiber.

The design space is well surveyed
([fine-grained locking](../../../research/fine-grained-locking/index.md)).
Rust's standard library, glibc and Zig keep a three-state word per lock
(unlocked, locked, contended) and let the kernel queue its waiters. That is
simple, but the library cannot see or reorder the kernel's queue: it cannot
hand a lock to a chosen waiter, and no fiber can join the queue. Only Linux
can move waiters from a condition variable's queue onto a mutex's, and glibc
stopped doing so because each release of the mutex then pays a system call.
WebKit's `ParkingLot` and Rust's `parking_lot` keep the queues in user space
instead, which allows all of this, but as shipped they wake a waiter on every
contended unlock and collapse into a convoy — threads acquiring the lock at
the pace of wake-ups — once the cores are saturated
([comparison § (a)](../../../research/fine-grained-locking/comparison.md#a-the-mutex-word)).

This library keeps the queues in user space and removes the convoy. Every
primitive is a few bits of atomic state plus calls into one
[parking lot](../../../glossary.md#parking-lot): a statically allocated table of
buckets, each holding a queue of waiters keyed by the address they wait on.
Decisions that need to see the queue, such as whether anyone is still
waiting, whether to wake or to requeue, and whether to hand a lock over
directly, run while the bucket is locked; each bucket's own lock sleeps
directly on the kernel's primitive. Each waiter is a record, kept in
thread-local storage or in the waiting fiber's own frame and supplied by its
[parker](../../../glossary.md#parker): a sleeping thread by default,
or a suspended fiber when a scheduler installs its own. A lock lets at
most one woken waiter be on its way to it at a time, the
[designated waker](../../../glossary.md#designated-waker): until that waiter
acquires the lock or parks again, a contended unlock wakes no one, and a
waiter that keeps losing the race is eventually handed the lock directly.
The kernel is used only to put one thread to sleep and to wake it. Locks come
in two kinds: a non-interruptible lock for short critical sections that never
suspend, and an interruptible one that a cancelled fiber can stop waiting for
without ever being left holding it.

The library covers process-private synchronization on Linux, Windows, macOS
and FreeBSD; on macOS it uses the public wait-on-address interface from 14.4
and the private one before. It does not share primitives between processes
or inherit priority from a waiter to the lock's owner (decision DS8), and it
does not detect deadlocks (DS9, [decisions](./decisions.md)). It does not
schedule fibers: the fiber parker belongs to `sparkles:event-horizon`,
which implements the contract that §4 states. Other platforms build with a
portable thread parker; the specification promises them correctness but none
of its performance gates.

This page specifies the core: the wait seam (§2), the one call per platform
that puts a thread to sleep on a word; the parking lot (§3); parkers
(§4); cancellation (§4a); the rules on attributes, allocation, addresses and
memory ordering that every primitive
follows (§5); and fork, thread exit and signals (§6).
[Primitives](./primitives.md) specifies each primitive on top of it.
[PLAN.md](./PLAN.md) orders delivery, [testing.md](./testing.md) owns the
test oracles, the performance gates and the record of evidence, and
[decisions.md](./decisions.md) records the consequential choices.

## The contract at a glance

1. No operation allocates, and the table never grows (SYP11, SYA1).
2. A park whose validation succeeds cannot miss an unpark that runs after it
   (SYP2).
3. A park returns for exactly one reason: unparked, invalid, timed out or
   cancelled. Operating-system spurious wakeups never surface (SYP4, SYP5).
4. Waiters on one key are served in the order they were enqueued, whichever
   parker each uses (SYP6, SYK6).
5. No bucket lock is held across a system call, a loop post, a fiber
   suspension or caller code other than the bounded validate, callback and
   filter functions (SYP10, SYP12).
6. A wake can be delivered after its waiter has returned and its storage is
   gone; delivery never touches that storage (SYK8).
7. Every release of a primitive happens before the acquisition it enables
   (SYH1).
8. A primitive's state is a few bits; its address is its identity, so it is
   never copied and never moved while held or waited on (SYA4, SYA5).
9. A fiber that waits suspends, and a fiber that contends for a bucket
   yields; neither blocks its loop's thread, except while the fiber holds a
   lock that pins it (SYK5, SYP13, SYK9).
10. Only interruptible operations observe cancellation, only while what they
    wait for is unavailable, return `cancelled` exactly when their parker
    reports it, and never observe it inside a protected region (SYI1–SYI5).

## 1. Terms

The [parking lot](../../../glossary.md#parking-lot) maps a **key**, an
address, to a FIFO queue of **waiters**. A waiter is a record owned by one
waiting thread or fiber. To **park** is to enqueue the caller's record under a
key and sleep until the record is **unparked**; an unpark can deliver an
**unpark token**, a machine word the parking primitive interprets (for
example, "the lock was handed to you"). A **bucket** is one slot of the table;
keys that hash to the same bucket share its lock and its queue. The
[parker](../../../glossary.md#parker) decides how a record sleeps and
how it is woken. The [designated waker](../../../glossary.md#designated-waker)
is the one waiter a lock has woken and that has not yet acquired the lock or
parked again. A **protocol** is the set of operations of one primitive type
that may park and unpark under a key.

## 2. The wait seam

The seam is the per-platform primitive that puts one thread to sleep on one
word. The thread parker (§4) and the bucket lock (§3) are its only
users; no primitive calls it directly.

**SYF1: Seam operations.** The seam **must** provide `wait(word, expected,
deadline)`, which sleeps while the 32-bit process-private `word` equals
`expected`, and `wake(word, count)` with `count` one or all. `wait` returns
when woken, when the value differs, when the deadline passes, or spuriously.
`wake` **must** identify waiters by the word's address alone, and **must not**
read or write the word.

_Rationale:_ Every supported kernel offers this contract on a 32-bit word,
and nothing above the seam relies on more
([Linux futexes § sizes](../../../research/fine-grained-locking/linux-futex.md#sizes-and-alignment)).
A wake keyed by address alone is what makes a late wake harmless (SYK8).

**SYF2: Mechanism per platform.** The seam **must** use:

| Platform | Mechanism                                                                                                                                                                                  |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Linux    | `futex(FUTEX_WAIT_BITSET \| FUTEX_PRIVATE_FLAG)` with an absolute `CLOCK_MONOTONIC` deadline; `FUTEX_WAKE_PRIVATE`                                                                         |
| Windows  | `WaitOnAddress` with the remaining time recomputed per call; `WakeByAddressSingle`, `WakeByAddressAll`                                                                                     |
| macOS    | `os_sync_wait_on_address_with_timeout` and `os_sync_wake_by_address_any`/`_all` where present at run time, else `__ulock_wait2` and `__ulock_wake` (`UL_COMPARE_AND_WAIT`, `ULF_NO_ERRNO`) |
| FreeBSD  | `_umtx_op(UMTX_OP_WAIT_UINT_PRIVATE)` with an absolute `CLOCK_MONOTONIC` `_umtx_time`; `UMTX_OP_WAKE_PRIVATE`                                                                              |

Other platforms **must** use a per-thread mutex, condition variable and flag
for the thread parker, and **may** spin and yield in the bucket lock. The
waiter **must** read its flag only while holding its own mutex, and delivery
**must** set the flag and signal while holding that mutex, so that the waiter
cannot return, and its storage cannot go, before delivery has released the
mutex; destroying a mutex once it can be locked is safe, as POSIX permits.
This fallback's wake handle is the record itself, the one exception to SYK8.
A build **must** be able to select the fallback on any platform with
`version (SparklesSyncPortableParker)`, so that a leg with a native mechanism
also runs it (DS24).

_Rationale:_ These are the platforms' documented or de facto wait-on-address
primitives ([OS wait primitives](../../../research/fine-grained-locking/index.md#master-catalog)).
macOS's public API exists only from 14.4; the private one remains for older
systems (DS6).

**SYF3: macOS selection is resolved once.** The choice between
`os_sync_*` and `__ulock_*` **must** be made by looking the public symbols
up at run time once per process, and **must not** change afterwards.

**SYF4: Deadlines.** A deadline **must** be an absolute point on the
monotonic clock. A deadline already in the past **must** make `wait` return
without sleeping.

## 3. The parking lot

**SYP1: Keys.** Any address **may** be a key. Waiters under different keys
**must** be independent except that keys sharing a bucket share its lock;
no outcome may depend on which keys collide.

**SYP2: Validated enqueue.** `park(key, validate, beforeSleep, token,
deadline)` **must** lock the key's bucket, run `validate`, and on `true`
enqueue the caller's record before releasing the bucket. An unpark on the
key that locks the bucket after that release **must** find the record.

_Rationale:_ This is the property that makes "check the state, then sleep"
free of lost wakeups: the primitive's state is read under the same lock its
waker takes ([parking_lot § how it works](../../../research/fine-grained-locking/parking-lot.md#how-it-works)).

**SYP3: Before sleeping.** `beforeSleep` **must** run after the record is
enqueued and the bucket released, before the caller sleeps. It **may** call
any unpark operation and **must not** park.

**SYP4: Park outcomes.** `park` **must** return exactly one of: `unparked`
with the unparker's token, `invalid` when validation returned `false`,
`timedOut` when the deadline passed while the record was still enqueued, or
`cancelled` (§4a). It **must not** return because of a spurious wakeup of the
underlying mechanism.

**SYP5: Timeout and cancellation races.** When a deadline passes or a
cancellation arrives after an unparker has already dequeued the record, park
**must** return `unparked` with that unparker's token, and the record
**must** leave the queue exactly once.

_Rationale:_ A token can carry ownership ("the lock is yours"); a waiter that
reported a timeout after receiving one would leak a held lock or a permit
([CQS](../../../research/fine-grained-locking/koval-2023-cqs.md)).

**SYP6: FIFO per key.** `unparkOne(key)` **must** dequeue the earliest
enqueued record of that key, except as SYM8 reorders a waiter it promotes.

**SYP7: Decisions under the bucket lock.** Every unpark operation **must**
run its callback while the bucket is locked, passing the number of records
dequeued, the number requeued, and whether records of the key remain. The
token the callback returns **must** be delivered to every record the
operation dequeued.

**SYP8: Requeue.** `unparkRequeue(from, to, validate, callback)` **must** lock
both keys' buckets in a fixed global order and **may**, as `validate` decides,
wake one record of `from` and move the rest, move one or all, or abort. A
moved record **must** keep its relative order, join the tail of `to`'s queue,
and not wake. A moved record's later timeout **must** be resolved under its
current key's bucket.

**SYP9: Filtered unpark.** `unparkFilter(key, filter, callback)` **must** offer
each record of `key` in queue order to `filter`, which sees the record's park
token and answers wake, skip or stop.

**SYP10: Two-phase wake.** An unpark **must** commit each wake while holding
the bucket lock and deliver it — a system call, a loop post — only after
releasing it. A delivery that reaches a record after its park returned
**must** have no effect on that record's later parks.

_Rationale:_ Holding a bucket across a system call would serialize unrelated
locks behind the slowest wake
([parking_lot § async](../../../research/fine-grained-locking/parking-lot.md#async-and-fiber-integration)).

**SYP11: Fixed, static table.** The table **must** have a compile-time,
power-of-two number of buckets, `parkingBuckets`, allocated statically. No
operation **may** allocate, grow or rehash it.

_Rationale:_ A growable table must allocate, and an allocator may itself need
a lock; Go, Zig, Wine and Folly all keep fixed tables (DS2).

**SYP12: Bounded code under the bucket lock.** `validate`, callbacks and
filters run with a bucket locked. They **must** be bounded and non-blocking,
and **must not** park, allocate, suspend or call another parking-lot
operation; violating this is a programming error, not a contract outcome.

**SYP13: The bucket lock.** A bucket lock **must** be a 32-bit word held only
for queue edits and SYP12 code, and never across a system call or a fiber
suspension. A contended acquirer **must** spin briefly and then wait through
its effective parker's `bucketWait` (SYK1, SYK2): the thread parker sleeps on the
bucket word through the seam (§2); a fiber parker yields to its scheduler
between attempts, so that its loop keeps running.

_Rationale:_ The holder of a bucket can be preempted for an unbounded time;
a fiber that slept through the seam would stop every fiber on its loop for
that long (DS14).

**SYP14: One protocol per key.** At any time, every record queued under a key
**must** belong to one protocol. Each record **must** carry its protocol's
tag, and every park and unpark **must** check the tags of the records it
meets; meeting a record of another protocol is a programming error, which
builds with assertions **must** detect. A requeue (SYP8) **must** rewrite
each moved record's tag to the destination's protocol, under both buckets'
locks, and with it the record's interruptibility and deadline (SYC3, SYC7).
A sleep that returns timed out or cancelled while its record is still
enqueued **must** be resolved against the record's current registration: if
that is non-interruptible, or carries no deadline, the return is spurious and
the parking lot **must** sleep again with the current interruptibility and
deadline.

_Rationale:_ A word used both as `LockBits` and as an address wait would let
a mutex unlock select an address waiter (DS17).

**SYP15: Recoverable queue-derived state.** The parking lot **must** register,
in its key's bucket, every record that has been woken and whose operation
has not yet finished. The registration **must** be retired under the bucket
lock before that operation returns or parks again, whatever the outcome:
acquisition, timeout, cancellation or any other return. A primitive's
queue-derived state — its parked and designated bits — **must** be reconciled
under the bucket lock whenever an operation finds it inconsistent with the
queue and the registrations: a bit with no queued record or registration
behind it **must** be cleared.

_Rationale:_ After `fork` (SYX1) the queues are empty but the primitives keep
their bits; reconciliation lets every primitive recover instead of leaving a
designated bit that suppresses every later wake (DS15).

## 4. Parkers

A [parker](../../../glossary.md#parker) supplies the record a park enqueues
and the things the parking lot cannot do itself: sleep, wake, wait for a
bucket, and relax while spinning. The name follows `parking_lot`'s
`ThreadParker` and Java's `LockSupport.park`, which suspends a virtual thread
where it blocks a platform thread.

**SYK1: The current parker.** Each thread **must** have a current parker, the
thread parker by default. A scheduler **may** install its own parker for the
code it runs and **must** restore the previous one when it stops. Every park,
`bucketWait` and `relax` **must** use the **effective parker**: the current
parker, or the thread parker while the caller is pinned (SYK9).

**SYK2: Parker operations.** A parker **must** provide: `prepare`, run before
enqueue; `sleep(deadline, interruptible)`, returning woken, timed out, or —
only when `interruptible` is true — cancelled;
`commitWake`, run under the bucket lock, returning a wake handle;
`deliverWake(handle)`, run after; `bucketWait(word)`, one bounded wait for a
contended bucket (SYP13); `relax(step)`, one step of a spin; `settle`, run once a park's final
outcome is cancelled (SYI3); and the cancellation queries of §4a. Before
`sleep` returns, the parker **must** have withdrawn every deadline and
cancellation subscription that sleep armed.

**SYK3: The thread parker.** The thread parker's record **must** live in
thread-local storage and need no allocation. Its `sleep` **must** wait through
the seam on a word of its own, so that the kernel never sees two waiters on
one word. It **must not** return cancelled.

**SYK4: Record ownership.** A record **must** be in at most one queue. While
enqueued it **must** be owned by the parking lot; its queue links and its
lifetime are guarded by the bucket that holds it. Once its park has returned
and its registration (SYP15) has been retired, the record's storage **may**
be reclaimed.

**SYK5: A fiber parker.** A fiber parker **must** suspend only the calling
fiber, and its `deliverWake` **must** make the fiber runnable from any thread.
If it supports cancellation, a cancelled sleep **must** dequeue the record
before returning cancelled, subject to SYP5. A fiber parker belongs to the
scheduler that installs it; `sparkles:event-horizon` specifies its own.

**SYK6: Mixed queues.** One key's queue **may** hold records of different
parkers, and SYP6 order **must** hold across them.

**SYK7: Bounded spinning.** Primitives spin only through `relax`, for a
bounded number of steps. The thread parker's steps **must** be processor pause
hints and then thread yields; a fiber parker's steps **should** pause and then
yield to its scheduler, so that a lock held by a fiber on the same thread can
be released.

_Rationale:_ On a cooperative scheduler a pure spin can deadlock against a
holder that yielded inside its critical section
([Skazhenik et al. 2025](../../../research/fine-grained-locking/skazhenik-2025-lightweight-locks.md)).

**SYK8: Wake handles outlive their records.** The handle `commitWake` returns
**must not** refer to the record's storage. `deliverWake` **may** run after
the woken waiter has returned, its thread has exited or its fiber has been
destroyed; it **must** then touch only storage that outlives every delivery,
and its only possible effect on a later waiter **must** be a spurious return
from the seam, which SYP4 absorbs. The thread parker's handle is its word's
address, which SYF1's address-only wake satisfies. A fiber parker's handle
**must** refer only to scheduler storage that the scheduler keeps until every
delivery that names it has completed.

_Rationale:_ A waiter observes its committed wake before the waker delivers
it, so it can return and free its record while the delivery is still in
flight (DS21).

**SYK9: Pinning.** Holding a [non-interruptible lock](./primitives.md#_1-two-kinds-of-lock)
**must** pin the caller for as long as it is held; pins nest. While pinned,
the effective parker is the thread parker (SYK1), so a park, a bucket wait
or a spin blocks the thread for its duration, and a fiber parker's scheduler
**must not** suspend the fiber; a suspension while pinned is a programming
error, which builds with assertions **must** detect. A condition wait
**must** choose the parker for its sleep as if the pin of the lock it
releases were dropped, but **must** keep that pin, and with it the thread
parker for every bucket wait and spin, until its record is enqueued and the
lock released (SYC2); it then drops the pin, and restores it with the lock on
every return path. Waiting on a condition while another lock still pins the
caller is a programming error, which builds with assertions **must** detect.

_Rationale:_ Non-interruptible locks guard short critical sections that never
suspend. A fiber that suspended while holding one would hold it across
unbounded work and stall every contender (DS16).

## 4a. Cancellation

Cancellation is a request, made by a scheduler to one of its fibers, to stop
waiting. The parking lot carries it from the fiber parker to the primitive;
what the primitive does with it is fixed here.

**SYI1: Interruptible operations.** Only operations that primitives.md names
interruptible **may** observe cancellation, and they alone **must** sleep with
`interruptible` true (SYK2). Every other blocking operation **must** sleep with
it false, so that the parker neither reports a pending cancellation to it
nor cancels its sleep, and the cancellation stays pending.

**SYI2: Interruptible only while unavailable.** An interruptible operation
**must** observe cancellation only while the resource it waits for is
unavailable. Once its wake carries ownership (SYP5) it **must** succeed and
leave the cancellation pending.

_Rationale:_ This is the interruptible-operation rule of Marlow et al.'s
asynchronous exceptions: there is no window between gaining ownership and
the caller seeing it (DS13).

**SYI3: One arbitration, in the parking lot.** A parker's `sleep` result is
tentative; the park's outcome is decided under the bucket lock (SYP4, SYP5),
so a sleep that returned cancelled after an unparker had dequeued the record
ends `unparked`. An interruptible operation **must** return `cancelled`
exactly when its park ended `cancelled`, and **must not** keep cancellation
state of its own. The parking lot **must** call the parker's `settle` for
every park whose final outcome is `cancelled`, and for no other; a scheduler that
consumes a request on its report **must** consume it there and nowhere else,
so that a request whose sleep lost to a grant stays pending (SYI2). Whether a
request outlives its report is the scheduler's rule; a scheduler whose
requests stay pending **must** let cleanup wait through a protected region
(SYI4).

_Rationale:_ Schedulers differ: Zig's `std.Io` consumes a request on its report,
while event-horizon latches it until the fiber's scope ends, so that a body
cannot silently drop a cancel. The library serves both by deciding the
outcome once and storing no cancellation state (DS13, DS23, DS25).

**SYI4: Protected regions.** A parker **must** report whether the current
fiber is in a cancellation-protected region, which its scheduler lets code
enter and leave explicitly. Inside one, an interruptible operation **must**
sleep with `interruptible` false and leave any request pending.

**SYI5: Results, not exceptions.** An interruptible operation **must** report
cancellation in its return value and **must not** throw; any guard it returns
**must** exist only for a successful acquisition.

## 5. Attributes, allocation, identity and ordering

**SYA1: No allocation.** No operation of the parking lot or any primitive
**may** allocate memory from the GC or the C heap, on any path.

**SYA2: Attributes.** Non-template operations **must** be `@safe nothrow @nogc`.
Templates that take caller code **must** infer their attributes.

**SYA3: Shared access.** Every operation **must** be callable through a
`shared` reference without a cast.

**SYA4: No copies.** Copying a primitive **must** be a compile-time error.

**SYA5: Address identity.** A primitive's address is its key. A primitive
**must not** be moved while it is held or waited on; doing so is a programming
error the library does not detect.

**SYA6: Zero initialization.** A primitive's `.init` value **must** be its
unlocked, empty or unset state, usable in static and `__gshared` storage
without a constructor.

**SYH1: Happens-before.** Each pair of operations that
[primitives.md § ordering](./primitives.md#_13-ordering) lists **must**
synchronize: every write the first operation's caller made before it
**must** be visible to the second operation's caller after it, in the sense
of the D and C++ memory models. A direct handoff (SYM8) and a permit handoff
(SYS3) **must** carry the same edge as the release they replace.

**SYH2: Park and unpark.** Everything an unparker did before an unpark
operation **must** happen before the return, with that operation's token, of
every park it dequeued.

## 6. Process lifecycle

**SYX1: Fork.** On POSIX, after `fork` the child **must** find every bucket
unlocked, every queue empty and no woken-waiter record left: a
`pthread_atfork` child handler reinitializes the table and the forking
thread's record. A primitive held in the parent at the time of the fork
**must** remain held in the child; every other primitive **must** recover
through SYP15 on its next contended operation.

_Rationale:_ Bucket locks are internal and short; leaving one locked by a
thread that does not exist in the child would deadlock the child's first
contended operation on any lock in that bucket (DS7).

**SYX2: Thread exit.** A thread exits only while it is not parked, so its
record is in no queue; the record needs no destruction. A wake still in
flight to it is harmless (SYK8).

**SYX3: Signals.** No operation is async-signal-safe. Calling one from a
signal handler is outside the contract.

## 7. Limits and constants

| Constant          | Meaning                                              | Value                |
| ----------------- | ---------------------------------------------------- | -------------------- |
| `parkingBuckets`  | buckets in the table (SYP11)                         | 1024                 |
| `spinSteps`       | `relax` steps a locker takes before parking (SYK7)   | 10: 3 pause, 7 yield |
| `starvationBound` | lost races before a waiter is handed the lock (SYM8) | 8                    |

The values are starting points; each is settled by the measurement its
[testing.md](./testing.md#benchmarks) row names, and a change is a
decision record, not an edit to this table alone.
