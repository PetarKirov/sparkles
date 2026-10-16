---
status: draft
owner: sparkles:base
reviewed: 2026-10-12
---

# Synchronization primitives — Decisions

The consequential choices behind [SPEC.md](./SPEC.md) and
[primitives.md](./primitives.md). Each records the question, the
alternatives, the evidence, the choice and its cost, and when to revisit it.
The evidence base is the
[fine-grained locking survey](../../../research/fine-grained-locking/index.md).
The owner accepted DS1–DS7 and DS10–DS12 in review on 2026-10-12, and DS8,
DS9 and DS13–DS22 on 2026-10-15, after an independent review whose findings
DS13–DS22 resolve; DS23, resolving a second review, and DS24 were accepted on
2026-10-15; and DS25 and DS26, resolving a third and a fourth review, on
2026-10-16.

## DS1: A parking lot, not a futex word per lock

**Question.** Should a lock keep its waiters in the kernel's queue, behind a
three-state futex word, or in a user-space parking lot?

**Alternatives.** The three-state word of Rust std, glibc and Zig; a parking
lot as in WebKit and `parking_lot`; a queue hanging off each lock as in
Abseil, nsync and Java's AQS.

**Evidence.** The futex word is the simpler design, and three standard
libraries chose it for that reason
([Rust std § overview](../../../research/fine-grained-locking/rust-std-sync.md#overview)).
Only a queue the library owns permits wait morphing, exact notification
counts, direct handoff and fiber waiters
([comparison § (a)](../../../research/fine-grained-locking/comparison.md#a-the-mutex-word)).
As shipped, `parking_lot` is 6–8× slower than Rust's futex mutex at 32 and
64 threads, and a parking lock with a designated waker is about 2.2× faster
than the futex word there
([mutex benchmark](../../../research/fine-grained-locking/examples/mutex-throughput.d)).
A queue per lock costs a pointer per lock.

**Choice.** A parking lot (SPEC §3), with a designated waker (DS3).

**Cost.** Keys that share a bucket share its lock; a parking lot is
process-private (DS8).

**Revisit** if a measured workload loses to the futex word by more than the
benchmark's run-to-run spread.

## DS2: A fixed, statically allocated table

**Question.** Should the table grow with the number of threads?

**Evidence.** `parking_lot` and WebKit grow theirs, locking every bucket and
leaking old tables; Rust rejected `parking_lot` because growth allocates and
an allocator may need a lock. Go (251 buckets), Zig (256), Wine (256) and
Folly (4096) keep fixed tables
([comparison § (a)](../../../research/fine-grained-locking/comparison.md#a-the-mutex-word)).

**Choice.** A fixed table of `parkingBuckets` buckets (SPEC SYP11).

**Cost.** Collisions grow with the number of simultaneously parked keys
rather than shrinking with the thread count.

**Revisit** if the collision benchmark in [testing.md](./testing.md#benchmarks)
shows bucket-lock contention at the reference load. B5 records the collision
cost with no pass mark; S2's acceptance includes the owner setting one from
that record, and a run below it grows `parkingBuckets` by a decision record.

## DS3: The designated waker

**Question.** How does a parking lock avoid the convoy?

**Evidence.** With an exact parked bit, every contended unlock wakes a waiter
that then loses the race and parks again: 0.76–0.97 sleeps per acquisition.
Spinning despite the parked bit does not help. Allowing one woken waiter at a
time, as nsync and Abseil do, brings that to 0.002
([concepts § convoys](../../../research/fine-grained-locking/concepts.md#convoys)).

**Choice.** One designated-waker bit per lock (SYM6).

**Cost.** One more bit, and the unlock path checks it.

## DS4: Wait morphing

**Question.** Should a notification wake waiters or move them onto the lock?

**Evidence.** glibc dropped requeue in 2016 because, over a futex word, it
forces the mutex into its contended state and every release then pays a
wake; it also blocked lock elision. In a parking lot the requeue runs under
the bucket lock and keeps the parked bit exact, and glibc has since removed
elision ([comparison § (b)](../../../research/fine-grained-locking/comparison.md#b-the-condition-variable)).

**Choice.** Requeue when the lock is held (SYC4, SYC5).

## DS5: A count-based starvation bound

**Question.** How is a waiter that keeps losing to barging lockers
protected?

**Alternatives.** None (Rust std, glibc); a timer (Go's 1 ms, WebKit's ~1 ms,
`async-lock`'s 500 µs); a count of failed wakes (nsync, the Linux kernel's
`HANDOFF`).

**Choice.** Hand off after `starvationBound` lost races (SYM8): no clock on
the slow path, and a bound a deterministic test can check.

**Revisit** with the fairness measurement in [testing.md](./testing.md#benchmarks).

## DS6: The macOS seam

**Question.** Which macOS wait primitive?

**Evidence.** `os_sync_wait_on_address` is public from macOS 14.4; before
that the only one is the private `__ulock` interface, which risks App Store
rejection and which Rust's standard library avoids
([Darwin](../../../research/fine-grained-locking/darwin-ulock.md)).

**Choice.** The public interface when present at run time, else `__ulock`
(SYF2, SYF3).

**Revisit** when the oldest supported macOS is 14.4 or later: drop `__ulock`.

## DS7: Reset the table in a forked child

**Choice.** A `pthread_atfork` child handler reinitializes the table (SYX1);
the alternative, forbidding any primitive in a child before `exec`, leaves a
bucket locked by a vanished thread to deadlock the child. Primitives recover
their own state through DS15.

## DS8: No process sharing, no priority inheritance

**Choice.** Both are out of scope. A parking lot is process-private by
construction, and priority inheritance needs the owner in the word, which a
three-bit lock does not hold ([queue locks § spinning](../../../research/fine-grained-locking/queue-locks.md#waiting-spin-yield-park)).

**Revisit** if a consumer needs either; `os_unfair_lock` and Linux PI futexes
are the available bases.

## DS9: No deadlock detection

**Choice.** Out of scope for the first delivery. `parking_lot`'s wait-for
graph is the model if a consumer needs it
([parking_lot](../../../research/fine-grained-locking/parking-lot.md)).

## DS10: The address wait lives in base; the fiber parker in event-horizon

**Question.** Where does a fiber's wait on a word live?

**Choice.** The address wait (SYW1–SYW3) and the parker seam (SPEC §4)
live in `sparkles.base.sync`; `sparkles:event-horizon` implements the fiber
parker and **may** use `IORING_OP_FUTEX_WAIT` inside it. Every primitive is
then fiber-aware on every platform, as Java's locks became with virtual
threads ([comparison § (d)](../../../research/fine-grained-locking/comparison.md#d-fibers-waiting-on-a-word-the-waitword-registry)).

## DS11: `WaitOnAddress`, not `SRWLOCK`, on Windows

**Evidence.** `SRWLOCK` broke its shared-mode contract from 2005 to 2024, and
Rust's `RwLock` moved to `WaitOnAddress`
([Windows SRWLOCK](../../../research/fine-grained-locking/windows-srwlock.md)).

**Choice.** The seam uses `WaitOnAddress` (SYF2); no primitive wraps a
Windows lock.

## DS12: An exhaustive interleaving model as the primary oracle

**Question.** What establishes that the algorithms are correct?

**Choice.** The primitives are written over a platform policy. A test build
replaces it with a deterministic scheduler that explores every interleaving
of two or three threads within a preemption bound, in the manner of loom and
CHESS, and checks the safety properties of [testing.md](./testing.md).
Native stress tests, ThreadSanitizer and benchmarks complement it.

**Cost.** The policy indirection must compile away in production builds,
which the benchmarks check. DS22 adds weak memory to the model.

## DS13: Two kinds of lock, and interruptible waits

**Question.** Which blocking operations observe a fiber's cancellation, and
how?

**Alternatives.** Every blocking operation cancellable, as in Zig's `std.Io`,
Eio and Kotlin; none; or a split between short non-cancellable locks and
cancellable ones, as in Rust (`std::sync::Mutex` against `tokio::sync::Mutex`)
and Go.

**Evidence.** Go declined a cancellable `sync.Mutex`: "I don't see how to
implement this feature without complicating and slowing down `sync.Mutex`,
which seems like a bad tradeoff for most programs"
([golang/go#40026](https://github.com/golang/go/issues/40026)). A cancellable
queue must support removal from its middle and a race between a grant and
the cancellation, which Scott and Scherer's timeout-capable queue locks show
is the whole difficulty. Kotlin's switch from atomic to prompt cancellation
([kotlinx.coroutines#1937](https://github.com/Kotlin/kotlinx.coroutines/pull/1937))
broke callers that paired `lock` and `unlock` by hand
([#2683](https://github.com/Kotlin/kotlinx.coroutines/issues/2683)). Marlow,
Peyton Jones, Moran and Reppy ("Asynchronous Exceptions in Haskell", PLDI 2001) make a blocking operation interruptible only while it cannot proceed,
which leaves no window between gaining a resource and the caller seeing it.

**Choice.** Non-interruptible locks for short sections that never suspend,
and an `InterruptibleMutex` that only returns guards (primitives.md §1, §4);
interruptible forms of the waits on conditions, semaphores, events, barriers,
latches, `Once` and the address wait; Marlow's rule for all of them (SYI2);
cancellation state owned by the parker, not the library (SYI3), and
explicit protected regions (SYI4);
and condition re-acquisition that is never interruptible (SYC3). Results are
returned, not thrown (SYI5), so the operations stay `nothrow`. With results
instead of exceptions there is no unwinding the parker could detect, so
cleanup that must wait during a cancellation enters a protected region.

**Cost.** Two mutex types to choose between, and interruptible forms beside
the plain ones.

## DS14: The bucket lock waits through the current parker

**Choice.** A contended bucket lock spins and then waits through the current
parker (SYP13): the thread parker sleeps on the bucket word, a fiber parker
yields. The alternative, letting a fiber block its thread while another
thread holds a bucket, is unbounded: the holder can be preempted.

## DS15: Queue-derived state reconciles itself

**Choice.** The parking lot records each woken, not-yet-resolved waiter in
its bucket, and any operation that finds a parked or designated bit with no
waiter behind it clears the bit (SYP15). This is what lets every primitive
recover in a forked child (SYX1, DS7); without it, a designated bit left by a
thread that does not exist in the child would suppress every later wake.

**Cost.** A woken waiter registers in its bucket and deregisters when it
acquires or parks again: one more bucket-lock round trip on the contended
path only.

## DS16: Holding a non-interruptible lock pins the parker

**Choice.** A non-interruptible lock pins the current parker (SYK9): while
pinned, waits use the thread parker and a fiber may not suspend. A fiber that
suspended inside a short critical section would hold the lock across
unbounded work, and a lock it took while holding another could otherwise
suspend it with the first still held.

## DS17: One protocol per key

**Choice.** Records carry a protocol tag, and a key holds records of one
protocol at a time (SYP14), checked in builds with assertions. Mixing, for
example a word used both as `LockBits` and as an address wait, is a
programming error rather than a supported combination, because a mutex
unlock would otherwise select an address waiter.

## DS18: `Once` retries after an `Exception`

**Choice.** An `Exception` from `init` returns the `Once` to incomplete and
another caller retries, as C++'s `call_once` does; an `Error` poisons it
(SYO4, SYO5). Rejecting throwing initializers would make the common
"initialize from a file" case impossible to write.

## DS19: `Guarded!T` requires a contained payload

**Evidence.** Under `-preview=dip1000`, a `scope` reference to a guarded
`int[]` still lets the caller copy the slice, and the copy keeps mutable
access after the guard is gone; the reviewer reproduced this with DMD and
LDC.

**Choice.** `Guarded!T` rejects a `T` with mutable indirections unless `T`
declares that every indirection is reachable only through `return scope`
members (SYG3), as an owning buffer's are.

## DS20: An upgrade outranks queued writers

**Choice.** An upgrade waits only for the shared holders present when it
began, on a key of its own, and queued writers cannot acquire while an
upgradable holder exists (SYR4), as in `parking_lot`'s `RwLock`. Queuing the
upgrader behind a writer deadlocks.

## DS21: Wake handles never point into records

**Choice.** A wake handle refers to an address or to scheduler storage that
outlives deliveries, never to the record (SYK8). A woken waiter can observe
its wake, return and free its record before the waker delivers the wake;
the thread parker's address-keyed seam wake turns such a late delivery into
at most a spurious seam return. A fiber parker whose wait is in the kernel,
such as an `IORING_OP_FUTEX_WAIT`, keeps the state the kernel points at until
the operation's final completion has been reaped.

## DS22: A weak-memory explorer and native litmus tests

**Question.** How are the ordering edges of SYH1 verified, when oracle 1's
scheduler is sequentially consistent?

**Choice.** Oracle 1 models the C++ and D memory orders: loads may read any
store the model permits, as loom does, so a missing release–acquire edge
shows up as a stale read of protected data. Message-passing litmus tests for
every pair of primitives.md §13 run on the arm64 macOS leg, a weakly ordered
machine. ThreadSanitizer's role narrows to what it checks: that protected
non-atomic data is ordered by the primitives in the schedules it ran (DS12
amended).

## DS23: Resolutions of the second review

A second independent review, of the tree that resolved the first, found
twelve conflicts among the new rules. Each is resolved in the contract
itself; the choices that are not forced:

- **Woken registrations retire on every exit** (SYP15, SYK4), and a
  designated waker that gives up passes its designation on (SYM6).
- **One effective parker** decides every park, bucket wait and spin: the
  thread parker while pinned (SYK1, SYK9). A condition wait drops its own
  lock's pin before choosing; waiting while another lock pins is an error.
- **Requeue rewrites a record's protocol tag and interruptibility** (SYP14).
- **Masking lives in the parker**: a non-interruptible operation sleeps with
  `interruptible` false (SYI1, SYK2), so a persistent cancellation cannot make
  it re-park in a loop.
- **The parker owns cancellation state** (SYI3; superseded by DS25, which
  makes the parking lot the one arbitration point): an interruptible operation
  returns `cancelled` exactly when its parker's `sleep` says so, whether the
  scheduler consumes a request on its report (Zig's `std.Io`) or latches it
  (event-horizon, whose fiber parker is sticky). Protected regions are
  explicit (SYI4); because cancellation is a returned value, no unwinding
  exists for the parker to detect.
- **The portable fallback's waiter observes its wake only under its own
  mutex** (SYF2), so its storage outlives delivery; it is the one parker whose
  wake handle is its record.
- **Ordering**: a barrier's withdrawn arrivals order nothing, and each `Once`
  attempt, an exceptional one included, happens before the next
  (primitives.md §13).
- **Evidence**: TSan annotations only for edges carried by the kernel, with a
  seeded fault proving TSan still sees a weakened release; linearizability
  only for single-point operations, phase histories for condition waits and
  barriers; oracle 10 gated at S1, S2 and S3 (testing.md, PLAN.md).

## DS24: Native evidence for every mechanism

**Question.** Which legs run the seam mechanisms that no hosted runner has?

**Choice.** A FreeBSD leg, a virtual machine on a hosted runner, runs on every
pull request, provided it finishes within 15 minutes. The portable fallback
is selectable on any platform (`version (SparklesSyncPortableParker)`), and the
Linux leg runs the native oracles a second time with it (SPEC SYF2,
testing.md oracle 5).

**Cost.** Two more CI configurations, one of them a virtual machine.

**Revisit** if the FreeBSD leg exceeds 15 minutes: it moves to a nightly and
on-demand schedule, and a pull request that changes the seam, the thread
parker or their build runs it on demand against its own tree; a nightly run
of an older tree is history, not evidence for the change.

## DS25: Resolutions of the third review

A third independent review, of the tree that resolved the second and of
event-horizon's [fiber parker](../../event-horizon/fiber-parker.md), found
fourteen defects. The choices that are not forced:

- **One arbitration point** (SYI3): a parker's sleep result is tentative and
  the parking lot decides the outcome under the bucket lock; a parker learns
  that a park ended cancelled only through `settle`, which is where a
  consuming scheduler consumes the request.
- **Requeue rewrites the deadline too** (SYP14), and a stale timeout or
  cancellation of a requeued record is a spurious return that sleeps again in
  the record's current mode.
- **A condition wait keeps its lock's pin until it has released the lock**
  (SYK9); only the parker for its sleep is chosen as if the pin were gone.
- **No happens-before annotations** for ThreadSanitizer: futex wakes carry no
  memory-model edge, so every edge comes from an atomic, and seeded faults
  cover the parkers' publications too (testing.md oracle 4).
- **Liveness is qualified** by its client and delivery assumptions, and
  withdrawal is a legal trace (oracle 10).
- **Nightly evidence is for its own tree** (DS24).
- In event-horizon, a shield stops propagation but not cancellation aimed at
  it; shutdown retains a scheduler that still has parked records; direct
  interrupts and node cancellation take separate routes on the ring path;
  parking reserves its resources; and `auto` follows a recorded decision
  ([fiber-parker.md](../../event-horizon/fiber-parker.md)).

## DS26: Resolutions of the fourth review

The fourth round ran two reviewers in parallel: the reviewer of the first
three rounds, and a second with no earlier context. Their findings were
checked against the tree. Several of the second reviewer's rested on text
the specification does not contain, and were set aside; those that held,
with the first reviewer's, are resolved here. The choices that are not
forced:

- **A spurious return re-prepares under the bucket lock** (SYK2, SYP4): a
  park that sleeps again calls `prepare` before releasing the bucket, so the
  next `commitWake` names the new sleep, instead of a separate rearm
  operation.
- **Spurious results are judged by their reason** (SYP14), and a requeued
  record is made non-interruptible with no deadline whatever its
  destination, because a moved record only reacquires.
- **The parking lot alone dequeues** a record whose sleep returned timed out
  or cancelled (SYK5); a parker never does.
- **A woken waiter continues as the lock's waiter** (SYC2): a handoff means
  it holds the lock, a designation means it acquires as the designated
  waker. A free handoff lock is acquired for the waiter `notifyAll` wakes
  (SYC6), and `Condition` reacquires an `InterruptibleMutex` through a
  package-internal acquisition that is not interruptible (SYJ1).
- **Only a designation registers** a woken record, and each queue-derived
  bit is reconciled only under its own key's bucket (SYP15).
- **RwLock releases promise progress** (SYR7), and the protocol model checks
  liveness for `InterruptibleMutex` and `RwLock` (oracle 10).
- **The bucket word has three states** (SYP13), and `bucketWait` takes the
  value it expects.
- In event-horizon: every completion of a ring wait reads the park word, so
  a wake from an earlier generation writes the wait again (EFP7); the
  deferred submission checks a latched interrupt (EFP8); the cancel word is
  woken by one synchronous `futex` call, never a queued ring operation, so
  the kernel never names a stack slot after its scope exits (EFP23); the
  cancellation's ring route requires the ring sleep (EFP6); and a timed park
  reserves both of its submission entries (EFP22).
