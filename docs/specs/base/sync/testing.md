---
status: draft
owner: sparkles:base
reviewed: 2026-10-12
---

# Synchronization primitives — Testing and evidence

The oracles, the check for every requirement of [SPEC.md](./SPEC.md) and
[primitives.md](./primitives.md), the benchmark gates, and the evidence
ledger. Delivery order is in [PLAN.md](./PLAN.md).

The trace every requirement needs is
`requirement -> falsifying scenario -> oracle -> scoped evidence`. Lock
algorithms fail in interleavings and memory orders that native runs reach
rarely, so the primary oracle explores both exhaustively within a bound;
native runs then check what the model cannot see.

## Oracles at a glance

| Oracle                    | Runs on                                     | Independent of                                                       | Cannot observe                                                       |
| ------------------------- | ------------------------------------------- | -------------------------------------------------------------------- | -------------------------------------------------------------------- |
| 1. Interleaving model     | the model platform, every build             | real scheduling and hardware: it enumerates schedules and reads      | schedules and store histories beyond the bound; the kernel; liveness |
| 2. Specification automata | inside oracle 1                             | the primitives' code: outcomes are checked against an abstract model | the same as oracle 1                                                 |
| 3. Native stress          | Linux, Windows, macOS, FreeBSD CI; Wine     | the model platform; histories are checked for linearizability        | rare interleavings                                                   |
| 4. ThreadSanitizer        | Linux, LDC                                  | the model                                                            | the internal atomics' correctness; schedules the stress run missed   |
| 5. Seam fault injection   | every platform                              | the operating system's spurious-wakeup rate                          | kernel behaviour outside the injected faults                         |
| 6. Compile-time checks    | the compiler                                | runtime behaviour                                                    | anything dynamic                                                     |
| 7. Allocation audit       | every platform                              | `@nogc` inference                                                    | allocations in code the audit did not run                            |
| 8. Benchmarks             | the reference machine; each CI leg logs     | the correctness oracles                                              | workloads other than the measured ones                               |
| 9. Litmus tests           | the arm64 macOS leg; x86-64 legs as control | the model's memory model                                             | reorderings the hardware never performs during the run               |
| 10. Protocol model        | TLC, from a TLA+ specification              | the D code: written from SPEC.md and primitives.md                   | whether the code matches the model                                   |
| 11. Disassembly check     | the `checked` build on x86-64 and arm64     | the benchmarks                                                       | the cost of anything but the uncontended path                        |

## Oracle 1: the interleaving model

The parking lot and every primitive are written over a **platform policy**:
atomic loads, stores and read-modify-writes with their memory orders,
`relax`, `bucketWait`, the current parker and the seam. The production policy
is `core.atomic` and the operating system. The model policy turns each of
those operations into a scheduling point of a deterministic scheduler that
runs two or three simulated threads, and fibers on them, and explores
schedules depth-first with a preemption bound, as CHESS and loom do.

The model follows the D and C++ memory models rather than sequential
consistency. Each atomic location keeps a bounded history of stores with
vector clocks; a relaxed or acquire load **may** read any store the model
permits, and the explorer branches on that choice, as loom does. Plain
memory that a primitive protects is tracked by vector clock, so a read that
no release–acquire edge orders after the last write is reported as a race
and as a stale read.

The explorer prunes schedules that differ only in the order of independent
operations, by dynamic partial-order reduction, so that the bound can grow.
Scenarios too large for exhaustive search run instead under a randomized
priority scheduler (PCT), which finds any bug of a small, fixed depth with a
known probability per run; their seeds are recorded. Time is virtual: the
model platform's clock advances only when the explorer chooses, so deadlines
expire at chosen points rather than by wall time.

A simulated thread that parks is not runnable until a simulated unpark makes
it so; the seam's `wait` may return spuriously, a bucket holder may stall
indefinitely, a fiber may be cancelled, and a delivery may be delayed past
its waiter's return and the reuse of its record — each at a point the
explorer chooses.

Every explored schedule is checked for:

- **Mutual exclusion.** Two simulated threads never hold a mutex, an
  exclusive `RwLock` or `LockBits` at once.
- **No lost wakeup.** No schedule ends with every thread parked while the
  primitive's state would let one proceed.
- **No deadlock.** The explorer reports a schedule in which every thread is
  blocked.
- **Exactly one outcome.** Every park returns once, with one SPEC SYP4
  outcome, and a dequeued record is never dequeued again.
- **Ordering.** Every pair of primitives.md §13 orders the protected data it
  is used to publish.
- **No access to dead storage.** No delivery touches a record whose park has
  returned (SYK8).

A scenario lists its threads' operations, the bound, and the expected set of
outcomes. The explorer's own correctness is checked against seeded faults:
each scenario family has a deliberately broken variant — an unlock that
skips the wake, a validation outside the bucket lock, a timeout that ignores
a committed token, a release store weakened to relaxed, a delivery through
the record — which oracle 1 **must** report.

## Oracle 2: specification automata

Inside oracle 1, each primitive's outcomes are compared with a small
sequential automaton written from primitives.md alone, not from the
implementation: a condition variable's automaton tracks which waiters a
notification may select and requires `notifyOne`/`notifyAll`'s return values
to match; a semaphore's tracks the quantities of SYS4 and requires their
balance; a barrier's tracks generations and withdrawals. An outcome the
automaton does not allow is a failure.

## Oracle 3: native stress

Each primitive runs a fixed-duration workload with a plain counter updated
under the lock, compared with the number of acquisitions afterwards;
condition, semaphore, event, barrier and latch workloads count every
notification and permit. The workloads run with as many threads as the
machine has and with twice as many, with and without deadlines and
cancellation, on every CI leg. Their seeds and durations are recorded with
each result. Each workload also records a timestamped history. For the
operations with a single linearization point — lock and unlock, `tryLock`,
permit acquisition and release, `Once`'s completion, `set` and `reset`, and
`countDown` — the history records each call and return and is checked for
linearizability against oracle 2's automaton: some sequential order of the
operations, consistent with their real-time order, must be one the
automaton allows. A condition wait and a barrier arrival span several
transitions on different objects, so for them the history records each
phase — registration, release of the lock, selection, re-acquisition and
return, or arrival, withdrawal and release — and is checked against a
concurrent automaton of those phases.

## Oracle 4: ThreadSanitizer

The native stress suite is built with LDC's ThreadSanitizer on Linux. A data
race report on data a primitive protects is a failure: it shows a missing
ordering edge in a schedule the run reached. TSan sees the ordering that
instrumented atomic operations establish. A futex sleep and its wake carry
no memory-model edge of their own (SPEC SYF1 permits spurious returns), so
every edge SYH1 and SYH2 require **must** come from an atomic operation: the
waker's release store or read–modify–write of the word or park state, and
the waiter's acquire load after its sleep. The primitives **must not**
annotate happens-before edges for ThreadSanitizer at all, since an
annotation would supply the very edge under test. Seeded faults **must** each
produce a TSan report, or the configuration's silence proves nothing: a mutex
release weakened to relaxed, a thread parker's wake store weakened to
relaxed, and a fiber parker's park-state swap weakened to relaxed. TSan says nothing about
whether the primitives' internal atomics are correct; oracle 1 owns that.

## Oracle 5: seam fault injection

A test switch makes the seam's `wait` return spuriously, or fail with
`EINTR`, at chosen calls, and makes macOS select `__ulock` over `os_sync_*`. With it, SPEC SYP4's "no
spurious return" is checked natively, and the macOS fallback runs on the
macOS leg. The Linux leg runs oracles 3, 5 and 7 a second time built with
`version (SparklesSyncPortableParker)`, so the portable fallback (SPEC SYF2) runs
natively (DS24).

## Oracle 6: compile-time checks

`static assert`s pin: each primitive's size (SYM1, SYR1, SYO1, SYS1, SYE1,
SYC1); that copying fails to compile (SYA4); the attributes of non-template
operations (SYA2); calls through `shared` references (SYA3); that
`InterruptibleMutex` has no raw `lock` or `unlock` (SYJ1); and, as
compile-fail tests, that a `Guarded!T`'s reference cannot escape its guard
and that `Guarded!(int[])`, `Guarded!(int*)` and a guarded class reference
are rejected (SYG2, SYG3).

## Oracle 7: allocation audit

Every operation runs on every platform under a GC-allocation counter and a
C-heap allocation counter, in the native stress workloads; any allocation is
a failure (SYA1).

## Oracle 9: litmus tests

For every pair of primitives.md §13, a message-passing test writes plain
data, performs the releasing operation, and checks the data after the
acquiring operation, millions of times, on the arm64 macOS leg, where loads
and stores may be reordered. The same tests run on the x86-64 legs as a
control. A deliberately weakened variant of each primitive, built only for
this oracle, **must** fail on arm64, or the test proves nothing.

## Oracle 10: the protocol model

A TLA+ specification models the parking lot and the mutex, condition,
semaphore and reader–writer protocols at the level of SPEC.md and
primitives.md: buckets,
queues, woken-waiter records, the lock bits, tokens, timeouts, cancellation
and `fork`. TLC checks its safety invariants — those of oracle 1 — and the
liveness properties oracle 1 cannot. They assume that every holder
eventually releases, that every committed wake is delivered, and that every
loop keeps running, and they hold under weak fairness: every waiter of a mutex
that neither times out nor is cancelled acquires it (SYM8), no designation
lasts forever (SYM6, SYP15), and every selected condition waiter returns
(SYC7). The model **must** accept a trace in which a waiter withdraws by
timeout or cancellation, and **must** reject a seeded starvation fault. The model is written from the
specification, not the code, so it also checks the specification; whether
the code implements it is a manual review obligation, recorded with each
result.

## Oracle 11: disassembly check

In the `checked` build, the uncontended `lock` and `unlock` of `Mutex` and
`LockBits` **must** each compile to one atomic read-modify-write and a
branch, with no call, on x86-64 and arm64; a test inspects the generated
code. It checks SYM2 and that the platform policy compiles away (DS12).

## Benchmarks

The benchmarks extend the survey's
[`mutex-throughput.d`](../../../research/fine-grained-locking/examples/mutex-throughput.d)
into the test runner's `@benchmark` suite. On the reference machine — the
32-hardware-thread Linux host the survey measured on — the gates are:

| Gate | Workload                                                                                                                                                                               | Acceptance                                                                                                                                                                |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| B1   | uncontended `lock`/`unlock`, one thread                                                                                                                                                | within 10% of the three-state futex word                                                                                                                                  |
| B2   | 8 iterations under the lock, 16 outside, 2, 4, 32 and 64 threads, 100 ms per cell, 5 runs                                                                                              | median throughput at least the three-state futex word's at every thread count                                                                                             |
| B3   | as B2                                                                                                                                                                                  | at most 0.01 sleeps per acquisition at 32 and 64 threads                                                                                                                  |
| B4   | as B2, minimum over maximum acquisitions per thread                                                                                                                                    | at least the three-state futex word's at 32 threads                                                                                                                       |
| B5   | `k` mutexes, each contended by 2 threads that park, `k` from 2 to `parkingBuckets / 2`; the keys either all in one bucket or in `k` distinct buckets, each mutex on its own cache line | the one-bucket run's throughput, as a fraction of the distinct-bucket run's, sets the collision cost DS2 accepts; recorded; the owner sets its pass threshold at S2 (DS2) |
| B6   | `notifyAll` to 31 waiters with the lock held, repeated                                                                                                                                 | at most one wake per release of the lock (SYC6)                                                                                                                           |
| B7   | `InterruptibleMutex` against `Mutex`, as B1 and B2                                                                                                                                     | recorded; B1 for `Mutex` must not regress when `InterruptibleMutex` is present (DS13)                                                                                     |

`parkingBuckets`, `spinSteps` and `starvationBound` (SPEC §7) are set by B2,
B4 and B5; a change to any of them reruns all seven.

## Requirement checks

### The seam and the parking lot

| Requirement      | Check                                                                                                                                                                                                                                                                                            | Oracle  |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------- |
| `SYF1`, `SYF4`   | a waiter sleeps while the value holds, returns on a wake and on a past deadline; a wake on an address whose storage was freed has no effect beyond a spurious return                                                                                                                             | 3       |
| `SYF2`           | each leg's build selects the table's mechanism; the macOS leg runs both mechanisms; the FreeBSD leg runs `_umtx_op`; the Linux leg also runs the portable fallback                                                                                                                               | 3, 5, 6 |
| `SYF3`           | the macOS selection is read once and cached                                                                                                                                                                                                                                                      | 5       |
| `SYP1`           | the B5 workload with colliding keys gives the same outcomes as with distinct buckets                                                                                                                                                                                                             | 1, 3    |
| `SYP2`           | a park racing an unpark across the validation point is never stranded                                                                                                                                                                                                                            | 1       |
| `SYP3`           | an unpark issued from `beforeSleep` wakes a waiter enqueued before it                                                                                                                                                                                                                            | 1       |
| `SYP4`           | injected spurious seam returns never end a park                                                                                                                                                                                                                                                  | 1, 5    |
| `SYP5`           | a deadline or cancellation racing a committed unpark returns `unparked` with its token                                                                                                                                                                                                           | 1       |
| `SYI3`, `SYI2`   | a semaphore release commits a permit, its delivery is delayed, and a cancellation wins the test parker's sleep: the acquire succeeds, `settle` is not called, and a consuming parker's request stays pending                                                                                     | 1       |
| `SYP14`, `SYC7`  | notify, requeue onto a held mutex, then a cancellation and the old deadline fire before the unlock: the waiter sleeps again, stays queued, and reports a notification with the lock held                                                                                                         | 1       |
| `SYP6`           | three waiters on one key are unparked in enqueue order                                                                                                                                                                                                                                           | 1       |
| `SYP7`           | callback arguments match the queue the automaton predicts                                                                                                                                                                                                                                        | 2       |
| `SYP8`           | requeued records keep their order, do not wake, and time out under their new key                                                                                                                                                                                                                 | 1, 2    |
| `SYP9`           | a filter's wake, skip and stop answers select exactly the records it accepted                                                                                                                                                                                                                    | 1, 2    |
| `SYP10`, `SYP12` | no system call, loop post or suspension happens with a bucket locked, checked by a model-platform assertion                                                                                                                                                                                      | 1       |
| `SYP11`          | the table is a static array of `parkingBuckets` buckets; the allocation audit sees no allocation                                                                                                                                                                                                 | 6, 7    |
| `SYP13`          | the bucket lock passes the mutual-exclusion and lost-wakeup checks; with a bucket holder stalled indefinitely, a fiber contending for the bucket yields and the other fibers on its loop keep running                                                                                            | 1, 3    |
| `SYP14`          | a word used both as `LockBits` and as an address wait fails an assertion in a checked build                                                                                                                                                                                                      | 1, 3    |
| `SYP15`          | a designated or parked bit left with no waiter behind it is cleared by the next contended operation, and a new waiter is then woken                                                                                                                                                              | 1, 10   |
| `SYP14`, `SYP8`  | `notifyOne` moving a condition waiter onto a mutex that already has waiters rewrites its tag and its interruptibility, with no assertion                                                                                                                                                         | 1       |
| `SYP15`, `SYM6`  | a woken waiter loses to a barging locker, reaches its deadline and returns; its record is reused; its registration is gone and its designation passes to a parked waiter Q; with Q still on its way, the next unlock wakes nobody; with Q parked again, the next contended unlock wakes a waiter | 1       |

### Parkers, cancellation, attributes, ordering and lifecycle

| Requirement            | Check                                                                                                                                                                                                                                                                                                                                                                                                                         | Oracle |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| `SYK1`                 | a parker installed and restored around a call is used by parks inside it and not after                                                                                                                                                                                                                                                                                                                                        | 1, 3   |
| `SYK2`, `SYK4`         | a test parker records the order of `prepare`, `commitWake` and `deliverWake`, and the queue holds each record once                                                                                                                                                                                                                                                                                                            | 1      |
| `SYK3`                 | the thread parker allocates nothing and never reports cancelled                                                                                                                                                                                                                                                                                                                                                               | 3, 7   |
| `SYK5`                 | event-horizon's fiber parker passes its own suite (its specification); here, a test parker that cancels is never stranded                                                                                                                                                                                                                                                                                                     | 1      |
| `SYK6`                 | a queue of thread-parker and test-parker records is served in enqueue order                                                                                                                                                                                                                                                                                                                                                   | 1      |
| `SYK7`                 | `relax` is called at most `spinSteps` times per park                                                                                                                                                                                                                                                                                                                                                                          | 1      |
| `SYK8`                 | a delivery delayed past the waiter's return, the reuse of its record, its thread's exit and its fiber's destruction touches no record storage                                                                                                                                                                                                                                                                                 | 1, 3   |
| `SYK9`                 | a condition wait meets a contended bucket after choosing a fiber parker and before releasing the lock: its thread sleeps and the fiber does not yield; the pin is restored on every return path; a park while pinned uses the thread parker; a test scheduler that suspends a pinned fiber fails an assertion                                                                                                                 | 1, 3   |
| `SYI1`–`SYI5`          | per interruptible operation: cancellation before selection reports cancelled with nothing held; cancellation after a grant succeeds and leaves the cancellation pending; inside a protected region the operation does not observe it; non-interruptible operations never observe it                                                                                                                                           | 1, 2   |
| `SYA1`                 | the allocation audit                                                                                                                                                                                                                                                                                                                                                                                                          | 7      |
| `SYA2`–`SYA6`          | the compile-time checks; `.init` values pass the stress suite from static storage                                                                                                                                                                                                                                                                                                                                             | 3, 6   |
| `SYH1`, `SYH2`         | the ordering check of oracle 1 for every pair of primitives.md §13, and the litmus tests                                                                                                                                                                                                                                                                                                                                      | 1, 9   |
| `SYX1`                 | a child forked while another thread holds a bucket lock, and while a mutex has a designated waker and parked waiters in the parent, locks that mutex and a mutex in that bucket, and its own waiters are woken                                                                                                                                                                                                                | 3      |
| `SYX2`                 | thread exit with a record never enqueued, and with a delivery to it still in flight, leaves the table unchanged                                                                                                                                                                                                                                                                                                               | 1, 3   |
| `SYK1`, `SYK9`         | a pinned fiber meeting a contended bucket sleeps its thread; a fiber holding a `Mutex` calls `Condition.wait`, its pin is dropped, it suspends, and a fiber on the same loop notifies it; a condition wait while another lock pins the caller fails an assertion                                                                                                                                                              | 1, 3   |
| `SYI1`, `SYI3`, `SYI4` | a fiber in a non-interruptible `Semaphore.acquire` receives a cancellation that persists; it does not loop, it acquires once a fiber on the same loop releases, and the request is still pending; with a consuming test parker, cleanup after a `cancelled` result waits normally; with a latching one, every later interruptible operation returns `cancelled` and the same cleanup waits normally inside a protected region | 1      |
| `SYF2` fallback        | the portable thread parker's waiter returns only after delivery has released its mutex, with delivery delayed at every point                                                                                                                                                                                                                                                                                                  | 1      |

### Primitives

| Requirement    | Check                                                                                                                                                                                                                                                | Oracle   |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- |
| `SYL1`–`SYL3`  | `LockBits` on 1-, 2-, 4- and 8-byte words passes the mutex scenarios while another thread toggles the other bits                                                                                                                                     | 1, 3     |
| `SYM1`, `SYM2` | size assertion; the model counts one CAS and no parking-lot call per uncontended acquire and release                                                                                                                                                 | 1, 6, 11 |
| `SYM3`–`SYM5`  | lock, deadline and try scenarios; an unlock of a free mutex fails an assertion in a checked build                                                                                                                                                    | 1, 3     |
| `SYM6`, `SYM7` | no schedule has two designated wakers; an unlock with one pending makes no parking-lot call                                                                                                                                                          | 1, 10    |
| `SYM8`         | an adversarial schedule in which barging lockers always win hands the waiter the lock within `starvationBound` + 1 wakes                                                                                                                             | 1, 10    |
| `SYM9`         | the model counts at most `spinSteps` relax steps per lock, none with a designated waker pending                                                                                                                                                      | 1        |
| `SYJ1`–`SYJ5`  | guard-only acquisition; cancellation racing a grant on either side of the handoff; FIFO grants; a holder that suspends                                                                                                                               | 1, 2, 6  |
| `SYG1`–`SYG4`  | the guard releases on scope exit; the escape and payload compile-fail tests; condition waits through a guard                                                                                                                                         | 1, 6     |
| `SYC1`–`SYC9`  | condition scenarios against the automaton: wait, timeout, cancellation, notify one and all, held and free lock; after a timeout or cancellation the lock is held again, and a cancellation during re-acquisition is not observed                     | 1, 2, 10 |
| `SYR1`–`SYR6`  | reader–writer scenarios against the automaton, including: U holds upgradable, R holds shared, W queues, U upgrades, R releases — U acquires exclusive before W; an upgrade that times out keeps upgradable                                           | 1, 2, 3  |
| `SYO1`–`SYO6`  | three callers race; `init` runs once; an `Exception` lets another caller run `init`, and a fresh caller that wins the retry sees the failed attempt's writes (also a litmus test); an `Error` poisons; a waiter's timeout leaves `init` running      | 1, 3     |
| `SYS1`–`SYS5`  | the SYS4 balance under every explored schedule, with timeouts and cancellation; after `release(1)` then `acquire`, available plus handed off is 0 and initial plus released minus completed is 0                                                     | 1, 2, 3  |
| `SYE1`–`SYE4`  | manual and auto-reset scenarios against the automaton, with timeouts and cancellation racing `set`                                                                                                                                                   | 1, 2     |
| `SYB1`–`SYB3`  | generations never mix; a party that times out before the `n`-th arrival is withdrawn, the generation completes only with `n` present, and no ordering is required from a party's writes after its withdrawal; the latch releases once and stays open | 1, 2, 3  |
| `SYW1`–`SYW3`  | a word that already differs returns at once with no park; a store without a wake leaves waiters parked; wakes return exact counts                                                                                                                    | 1, 2     |

## Evidence ledger

| Requirements                             | State   | Evidence | Gap                                                                                                                                              |
| ---------------------------------------- | ------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| every requirement of this tree           | planned | —        | no implementation exists; see [PLAN.md](./PLAN.md)                                                                                               |
| `SYF2` on FreeBSD; the portable fallback | planned | —        | the FreeBSD leg (a virtual machine on every pull request, within 15 minutes) and the Linux portable-parker configuration do not exist yet (DS24) |
| `SYK5`                                   | planned | —        | specified by event-horizon's [fiber-parker.md](../../event-horizon/fiber-parker.md); delivered and tested in its M20                             |

The specification's independent-review gate is **partly met**: a first
independent review on 2026-10-15 raised twelve findings and three gaps
(DS13–DS22); a second review of that revision raised twelve more (DS23); a
third, of that revision and of event-horizon's fiber parker, raised fourteen
(DS25). The tree that resolves the third review has not yet been reviewed.
