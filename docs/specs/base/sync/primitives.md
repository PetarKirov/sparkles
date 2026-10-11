---
status: draft
owner: sparkles:base
reviewed: 2026-10-12
---

# Synchronization primitives — The primitives

Each primitive here is a few bits of atomic state over the parking lot of
[SPEC.md](./SPEC.md). That page's rules hold for all of them: no allocation
(SYA1), the attribute and sharing rules (SYA2, SYA3), no copies and a stable
address (SYA4, SYA5), a usable `.init` (SYA6), the ordering edges of §13
(SYH1), and one protocol per key (SYP14). Every blocking operation parks
through the caller's parker (SPEC §4), so a fiber that blocks suspends.

A **deadline form** of an operation takes an absolute monotonic deadline
(SYF4) and reports whether it succeeded or timed out; an **interruptible
form** also reports cancellation (SPEC §4a). Each section states which forms
an operation has and what a timeout or a cancellation leaves behind; an
operation has no form a section does not list.

## 1. Two kinds of lock

A **non-interruptible lock** — `LockBits`, `Mutex`, `Guarded!T` and
`RwLock` — guards a short critical section that never suspends. Holding one
pins the current parker (SYK9), and acquiring one never observes
cancellation (SYI1). An **interruptible lock**, `InterruptibleMutex`, guards
a critical section that may suspend, for example across I/O; a cancelled
fiber stops waiting for it without ever being left holding it.

_Rationale:_ A cancellable acquisition needs queue bookkeeping that the
uncontended path of a short lock should not pay for; Go declined a
cancellable `sync.Mutex` for that reason, and Rust separates
`std::sync::Mutex` from `tokio::sync::Mutex` (DS13).

## 2. Embedded lock bits

The mutex is a lock projected onto three bits of a byte. The same algorithm
can be projected onto any atomic integer the caller owns, so that a lock
costs no storage of its own.

**SYL1: Lock bits.** `LockBits` **must** implement the mutex of §3 on three
caller-chosen bits — locked, parked and designated — of a caller-owned
atomic integer of 1, 2, 4 or 8 bytes, keyed by the integer's address.

**SYL2: Other bits are preserved.** Every operation **must** change only the
three lock bits; bits outside them **must** keep whatever value concurrent
writers give them, so the caller can keep a counter or flags in the same
word.

_Rationale:_ WebKit keeps a lock in a JavaScript object's header byte and an
optimistic-read counter beside it in one word
([WebKit](../../../research/fine-grained-locking/webkit-wtf-lock.md#how-it-works)).

**SYL3: One lock per word.** A word **must** carry at most one embedded lock,
and **must not** also be used with the address wait (§12), because the word's
address is the key of both (SYP14).

## 3. Mutex

`Mutex` is `LockBits` over one byte.

**SYM1: Size.** `Mutex.sizeof` **must** be 1.

**SYM2: Uncontended path.** An acquire of a free mutex with no waiters
**must** be one compare-and-swap; a release with no waiters **must** be one
compare-and-swap. Neither **may** touch the parking lot or enter the kernel.

**SYM3: Lock.** `lock` **must** return holding the mutex. Its deadline form,
`lockUntil`, **must** return `true` holding it or `false` not holding it; a
timeout **must** leave no trace in the mutex's state beyond what SYP15
reconciles. It has no interruptible form.

**SYM4: Try.** `tryLock` **must** return `true` holding the mutex or `false`
without parking, spinning or touching the parking lot.

**SYM5: Unlock.** `unlock` **must** release a mutex the caller holds. The
mutex records no owner and is not recursive; unlocking a mutex that is not
held is a programming error, which builds with assertions **must** detect.

**SYM6: Designated waker.** At most one waiter woken by an unlock **may** be
on its way to the mutex at any time. An unlock that finds a designated waker
pending **must** release without waking anyone; the designation ends when
that waiter acquires the mutex or parks again. A designated waker that returns
without the mutex, after a timeout, **must** end its designation and, if
waiters remain parked, wake one of them, so that the designation passes on.

_Rationale:_ Waking a waiter on every contended unlock, as `parking_lot`
does, collapses throughput once the cores are saturated; one designated
waker removes the convoy (DS3,
[comparison § (a)](../../../research/fine-grained-locking/comparison.md#a-the-mutex-word)).

**SYM7: Barging.** An unlock without a handoff (SYM8) **must** make the
mutex free, so that a running locker **may** acquire it before the
designated waker.

**SYM8: Starvation bound.** A waiter that is woken and then loses the race to
a barging locker `starvationBound` times in a row **must** park at the head
of the queue, and the next unlock **must** hand it the mutex directly: the
mutex stays held and the waiter returns from park owning it.

_Rationale:_ A count needs no clock on the slow path; the Linux kernel mutex
and nsync bound starvation the same way (DS5).

**SYM9: Spinning.** A locker that finds the mutex held **may** spin for at
most `spinSteps` `relax` steps (SPEC SYK7) before parking, and **must not**
spin while a designated waker is pending.

## 4. Interruptible mutex

**SYJ1: Guards only.** `InterruptibleMutex` **must** expose acquisition only
through operations that return a guard, and release only through the guard's
destruction; it **must not** offer a raw `lock` or `unlock`.

_Rationale:_ When cancellation races a grant, the operation must hand the
lock on itself. A caller that also unlocked by hand would release a lock it
does not hold; Kotlin's move to prompt cancellation produced exactly that bug
in callers that paired `lock` with `unlock` by hand
([kotlinx.coroutines#2683](https://github.com/Kotlin/kotlinx.coroutines/issues/2683))
(DS13).

**SYJ2: Acquisition.** `lock` **must** be interruptible (SYI2): it returns a
guard, or reports timeout or cancellation with nothing held. Its deadline
form behaves likewise.

**SYJ3: Baton passing.** If cancellation arrives after the mutex was handed
to a waiter, the waiter **must** keep it and succeed (SYI2); if it arrives
before, the waiter **must** leave the queue, and no handoff **may** be
addressed to it.

**SYJ4: No pinning.** Holding an `InterruptibleMutex` **must not** pin the
parker; its holder **may** suspend.

**SYJ5: Fairness.** Waiters **must** be granted the mutex in queue order by
direct handoff whenever any are parked.

_Rationale:_ A holder that suspends makes critical sections long, where a
fair handoff costs little and barging would starve
([CQS § evaluation](../../../research/fine-grained-locking/koval-2023-cqs.md#evaluation)).

## 5. Guarded data

**SYG1: Guarded.** `Guarded!T` **must** hold a `T` and a `Mutex`, and **must**
expose the `T` only through a guard that `lock`, `lockUntil` or `tryLock`
returns. `InterruptibleGuarded!T` **must** do the same over an
`InterruptibleMutex`.

**SYG2: Scoped access.** The guard **must** release the mutex when destroyed,
and the reference it gives **must** be `scope`, so that under
`-preview=dip1000` no reference into the `T` outlives the guard.

**SYG3: Contained payloads.** `Guarded!T` **must** reject at compile time a
`T` that holds a mutable indirection, unless `T` declares itself contained:
every indirection it holds is reachable only through member functions whose
results are `return scope`. A slice, a pointer or a class reference to
mutable data is not contained.

_Rationale:_ `scope` restricts the reference to the `T`, not what the `T`
points to: a guarded `int[]` copied out of its guard keeps mutable access to
its elements after the lock is released (DS19).

**SYG4: Condition waits.** A guard **must** be usable with `Condition` (§6),
which releases and reacquires the mutex through it.

## 6. Condition

**SYC1: State.** `Condition` **must** be pointer-sized: null, or the address
of the lock its waiters use.

**SYC2: Wait.** `wait(guard)` **must** enqueue the caller, release the lock,
and return only after a notification selected it, with the lock held again.
A wait **must not** return spuriously.

**SYC3: Deadline and interruptible forms.** `waitUntil(guard, deadline)`
**must** also return `false` when the deadline passes first. The
interruptible form `waitInterruptible` **must** also report cancellation
while the waiter is waiting for a notification. Every form **must** return
with the lock held: reacquiring the lock after a timeout or a cancellation
**must not** itself be interruptible.

_Rationale:_ The caller's guard releases the lock as it unwinds; returning
without the lock would make that release unlock a lock the caller does not
hold. Eio's test suite states the same rule: "`await` must always re-acquire
the lock, and that lock operation must be non-cancellable"
([`tests/condition.md`](https://github.com/ocaml-multicore/eio/blob/e457773f909e5f68d0b211776693600fbf3d74af/tests/condition.md#L208)).

**SYC4: One lock at a time.** A condition **must** be used with one lock at a
time; waiting with a different lock while waiters remain is a programming
error, which builds with assertions **must** detect.

**SYC5: Notify one.** `notifyOne` **must** return whether it selected a
waiter. If the lock is held, it **must** move the selected waiter onto the
lock's queue without waking it; otherwise it **must** wake it.

**SYC6: Notify all.** `notifyAll` **must** return the number of waiters it
selected. If the lock is held, it **must** move all of them onto the lock's
queue; otherwise it **must** wake one and move the rest.

_Rationale:_ Moving waiters onto the lock — wait morphing — turns a
broadcast into one wake per release instead of a herd, which a user-space
queue makes cheap (DS4,
[comparison § (b)](../../../research/fine-grained-locking/comparison.md#b-the-condition-variable)).

**SYC7: Selected waiters are notified.** A waiter that a notification
selected **must** report a notification, not a timeout or a cancellation,
even if the deadline passes or a cancellation arrives before it reacquires
the lock.

**SYC8: Cheap notify.** A notification with no waiters **must** be one atomic
load: no bucket lock and no system call.

**SYC9: Locks it accepts.** A condition **must** work with `Mutex`,
`LockBits`, `InterruptibleMutex` and both guarded forms.

## 7. Reader–writer lock

**SYR1: Size.** `RwLock.sizeof` **must** be `size_t.sizeof`: a reader count
and the lock's flag bits in one word.

**SYR2: Modes.** The lock **must** offer shared, exclusive and upgradable
modes: one upgradable holder **may** coexist with shared holders, and **may**
upgrade to exclusive or downgrade to shared. Exclusive **may** downgrade to
shared or upgradable. Acquisition has deadline forms and no interruptible
forms.

**SYR3: Writers do not starve.** Once a writer or upgrader is parked, new
shared acquirers **must** park behind it.

**SYR4: Upgrade priority.** An upgrade **must** wait only for the shared
holders present when it began, on a key of its own, and **must** take
priority over every queued writer, which cannot acquire while the upgradable
holder exists. An upgrade that times out **must** leave the caller holding
upgradable mode.

_Rationale:_ A writer queued ahead of the upgrader would wait for the
upgradable holder to leave while the upgrader waits for the writer: a
deadlock (DS20).

**SYR5: One pass per release.** A release that wakes waiters **must** wake,
in one `unparkFilter` pass (SPEC SYP9), either one exclusive waiter or every
shared waiter plus at most one upgradable waiter at the head of the queue.

**SYR6: No recursion.** Acquiring shared mode while already holding the lock
is a programming error: SYR3 makes it deadlock when a writer is parked.

## 8. Once

**SYO1: Size and state.** `Once.sizeof` **must** be 1; the states are
incomplete, running, complete and poisoned.

**SYO2: Exactly once.** `call(init)` **must** run `init` at most once per
successful completion; every caller **must** return only after some caller's
`init` has completed, parking while another caller runs it.

**SYO3: Completed fast path.** `call` on a complete `Once` **must** be one
atomic load with acquire ordering.

**SYO4: Exceptions.** If `init` ends by throwing an `Exception`, the `Once`
**must** return to incomplete, the exception **must** propagate to that
caller, and one waiting caller, or the next caller, **must** run `init`
again.

**SYO5: Errors.** If `init` ends by throwing an `Error`, the `Once` **must**
become poisoned, waiting callers **must** be woken, and every later `call`
**must** fail an assertion.

_Rationale:_ An `Exception` is a recoverable failure, which C++'s
`call_once` also retries; an `Error` means the process's state is suspect
(DS18).

**SYO6: Waiting forms.** The deadline and interruptible forms of `call`
**must** apply only while the caller waits for another caller's `init`: a
timeout or a cancellation **must** return to that caller and leave the
running `init` undisturbed. A caller that runs `init` itself **must** run it
to completion.

## 9. Semaphore

**SYS1: Size.** `Semaphore.sizeof` **must** be `size_t.sizeof`: a permit
count and a parked flag.

**SYS2: Operations.** `acquire`, its deadline and interruptible forms, and
`tryAcquire` **must** take one permit; `release(n)` **must** add `n`.

**SYS3: FIFO handoff.** While waiters are parked, `release` **must** hand
permits directly to them in queue order, waking each recipient with a token
that says it owns a permit, rather than raising the count.

_Rationale:_ Strict handoff does not pay for a single-permit mutex, but it
does for semaphores and pools, where a counter that hands over instead of
retrying wins by large factors
([CQS § evaluation](../../../research/fine-grained-locking/koval-2023-cqs.md#evaluation)).

**SYS4: No lost permit.** A waiter whose deadline passes or that is cancelled
after receiving a permit **must** keep it and report success (SPEC SYP5).
Under every interleaving, the available count plus the permits handed off
and not yet returned to a caller **must** equal the initial count plus every
permit released minus every acquisition that completed.

**SYS5: Overflow.** A release that would overflow the count is a programming
error, which builds with assertions **must** detect.

## 10. Events

**SYE1: Kinds and size.** `ManualResetEvent` and `AutoResetEvent` **must**
each be one byte.

**SYE2: Manual reset.** `set` **must** wake every waiter and leave the event
set until `reset`; `wait` on a set event **must** return at once.

**SYE3: Auto reset.** `set` **must** wake exactly one waiter, or, with none
parked, leave the event set so that the next `wait` consumes it and returns
at once. Setting a set event **must** have no further effect.

**SYE4: Waiting forms.** `wait` **must** have deadline and interruptible
forms. An auto-reset waiter that was selected by `set` **must** report
success and consume the signal even if its deadline passes or a cancellation
arrives first; one that timed out or was cancelled before being selected
**must** consume nothing.

## 11. Barrier and latch

**SYB1: Barrier.** `Barrier(n)` **must** release all `n` parties once the
`n`-th arrives, return `true` to exactly one of them, and then be reusable
for the next generation; a party of a later generation **must not** be
released by an earlier one.

**SYB2: Barrier withdrawal.** The barrier's deadline and interruptible forms
**must** withdraw the caller's arrival when they time out or are cancelled
before the generation completes, so that it no longer counts toward `n`. If
the generation completed first, the caller **must** report success.

**SYB3: Latch.** `Latch(n)` **must** release every waiter once `countDown`
has been called `n` times in total, and every later `wait` **must** return
at once. `wait` **must** have deadline and interruptible forms, which leave
the count unchanged. Counting below zero is a programming error, which
builds with assertions **must** detect.

## 12. Address wait

The address wait lets any code wait for a memory word to change, the way a
futex does, but through the parking lot, so that a waiting fiber suspends.

**SYW1: Wait.** `waitWhile(word, expected)` **must** park the caller while
the word, an atomic integer of 1, 2, 4 or 8 bytes, equals `expected`,
checking the value as SPEC SYP2's validation. If the word already differs it
**must** return at once without parking. It **must** have deadline and
interruptible forms, which report a timeout or a cancellation only if the
caller parked and was not woken.

**SYW2: Wake.** `wakeOne(word)` and `wakeAll(word)` **must** wake waiters of
that word and return how many they woke.

**SYW3: Only its own wakes.** A waiter **must** be woken only by `wakeOne` or
`wakeAll` on the same word. A store to the word alone, or a kernel wake on
its address, **must not** wake it.

_Rationale:_ The waiters are in the parking lot, not in the kernel's queue;
a fiber parker may add a kernel wait as a fast path, but the contract cannot
promise more than the portable case (DS10).

## 13. Ordering

The pairs SYH1 requires to synchronize: the first operation happens before
the second.

| Primitive                    | Releasing operation                                                                 | Acquiring operation that it enables                    |
| ---------------------------- | ----------------------------------------------------------------------------------- | ------------------------------------------------------ |
| `LockBits`, `Mutex`, guarded | `unlock`, including a handoff (SYM8)                                                | the next successful acquisition                        |
| `InterruptibleMutex`         | guard destruction, including a handoff                                              | the next successful acquisition                        |
| `RwLock`                     | release of exclusive or upgradable mode                                             | the next acquisition in any mode                       |
| `RwLock`                     | release of shared mode                                                              | the next exclusive acquisition or upgrade              |
| `Condition`                  | the notifier's actions before `notify*`                                             | the return of a wait that notification selected        |
| `Once`                       | completion of `init`                                                                | every return of `call` that observes completion        |
| `Once`                       | the end of each attempt of `init`, an exceptional one included                      | the start of the next attempt                          |
| `Semaphore`                  | `release`, including a handoff (SYS3)                                               | the acquisition that takes that permit                 |
| Events                       | `set`                                                                               | every wait that returns because of it                  |
| `Barrier`                    | every arrival counted in a completed generation; a withdrawn arrival orders nothing | every successful return from that generation           |
| `Latch`                      | every `countDown`                                                                   | every wait that returns because the count reached zero |
| Address wait                 | the waker's actions before `wakeOne`/`wakeAll`                                      | the return of every wait that wake ended               |
