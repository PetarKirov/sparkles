# The parking lot: why `base.sync` looks the way it does

Every primitive in `sparkles.base.sync` is a few bits of atomic state, and
none of them owns a queue of waiters. The waiters live in one
[parking lot](../../../glossary.md#parking-lot) shared by the whole process.
This page explains why the library is built that way, what each part of the
design buys, and how its correctness is established. The normative contract
is the [specification](../../../specs/base/sync/SPEC.md); the reasoning
behind each choice, with its alternatives and evidence, is in
[decisions.md](../../../specs/base/sync/decisions.md); and the survey it
draws on is the [fine-grained locking catalog](../../../research/fine-grained-locking/index.md).

| See also                                                                      |                                                 |
| ----------------------------------------------------------------------------- | ----------------------------------------------- |
| [Synchronize threads and fibers](../how-to/synchronize-threads-and-fibers.md) | the recipes: which primitive, and how to use it |
| [The primitives](../../../specs/base/sync/primitives.md)                      | each primitive's requirements                   |
| [Testing and evidence](../../../specs/base/sync/testing.md)                   | the oracles and what each can observe           |

## One parking lot instead of a futex word per lock

The common design keeps a three-state word per lock — unlocked, locked,
contended — and lets the kernel queue the waiters on that word's address.
Rust's standard library, glibc and Zig do this, and it is simple. Its cost is
that the queue belongs to the kernel. The library cannot ask how many
waiters remain, cannot hand the lock to a chosen waiter, cannot move waiters
from one queue to another without paying a system call on every later
release, and cannot put a suspended fiber in the queue at all.

A parking lot moves the queues into user space. It is a fixed table of
buckets; an address hashes to a bucket, and the bucket holds a FIFO queue of
the waiters parked on that address. A primitive parks a waiter only after
re-checking its own state with the bucket locked, so a release that runs
afterwards cannot miss it, and it decides under the same lock whether to
wake, to requeue or to hand over. The kernel is left with one job: putting a
single thread to sleep on a word of its own and waking it.

Because the queue is the library's, the primitive itself needs no storage
for it. A `Mutex` is one byte, a `Condition` one pointer, and a lock can live
in three spare bits of a word the caller already has (`LockBits`). The table
is statically allocated and never grows, so no operation allocates; Go, Zig
and Wine size theirs the same way, and growing it, as WebKit and Rust's
`parking_lot` do, would need an allocator that may itself need a lock
([DS1](../../../specs/base/sync/decisions.md#ds1-a-parking-lot-not-a-futex-word-per-lock),
[DS2](../../../specs/base/sync/decisions.md#ds2-a-fixed-statically-allocated-table)).

The same queues hold threads and fibers because each waiter's record comes
from its [parker](../../../glossary.md#parker). The thread parker sleeps on
the operating system's wait-on-address primitive; a scheduler such as
`sparkles:event-horizon` installs a parker that suspends the fiber instead.
The parking lot neither knows nor cares which kind of waiter a record
belongs to, and serves both in the order they arrived.

## The designated waker and convoys

User-space queues alone do not make a fast lock. WebKit's lock and
`parking_lot`, as shipped, wake a waiter on every contended unlock. Once the
cores are saturated, that waiter usually loses the race to a thread that is
already running, and parks again: almost one sleep per acquisition. The lock
then moves at the pace of wake-ups, a convoy
([concepts § convoys](../../../research/fine-grained-locking/concepts.md#convoys)).

The fix, taken from nsync and Abseil, is to let at most one woken waiter be
on its way to a lock at a time: the
[designated waker](../../../glossary.md#designated-waker). Until it acquires
the lock or parks again, an unlock wakes no one and simply frees the lock,
so a running thread may take it. That barging is what keeps throughput high,
and its risk, a waiter that loses forever, is bounded by count rather than by
clock: a waiter that loses `starvationBound` races in a row parks at the head
of the queue and is handed the lock directly on the next unlock
([DS3](../../../specs/base/sync/decisions.md#ds3-the-designated-waker),
[DS5](../../../specs/base/sync/decisions.md#ds5-a-count-based-starvation-bound)).
While it is on its way, the designated waker alone keeps spinning on
processor pauses for a while before it parks again, whoever else is parked:
it is the waiter the unlock expects, so its spin narrows the window a barger
can take
([DS29](../../../specs/base/sync/decisions.md#ds29-b4-a-designated-waker-that-spins)).
The survey's benchmark measured the parked-bit design at 0.76–0.97 sleeps
per acquisition and the designated waker at 0.002.

## Wait morphing

A condition variable over a kernel-queued mutex has two poor choices for a
broadcast: wake every waiter, so that all of them stampede for a lock only
one can hold, or ask the kernel to requeue them onto the mutex's word, which
glibc abandoned because the mutex then stays in its contended state and
every release pays a wake.

In a parking lot the requeue is a list operation under two bucket locks. A
notification made while the lock is held moves the selected waiters onto the
lock's queue without waking any of them, and marks the lock parked so its
next release wakes one. A broadcast thus costs one wake per release instead
of a herd. A moved waiter continues as an ordinary waiter of the lock: handed
the lock, it returns holding it; designated, it acquires as the designated
waker ([DS4](../../../specs/base/sync/decisions.md#ds4-wait-morphing),
[primitives §6](../../../specs/base/sync/primitives.md#_6-condition)).

The condition knows its lock only by address. Each waiter's park token
describes the lock's word, so one `Condition` type serves `Mutex`,
`LockBits` and `InterruptibleMutex` alike.

## Pinning, and the two kinds of lock

A fiber that suspends while holding a short lock holds it across unbounded
work: every other thread that wants the lock waits for the fiber's loop to
come back to it. So holding a `Mutex` or `LockBits` lock pins the caller to
the thread parker: while pinned, a wait blocks the thread instead of
suspending the fiber, and the critical section stays short by construction
([DS16](../../../specs/base/sync/decisions.md#ds16-holding-a-non-interruptible-lock-pins-the-parker)).

Some critical sections must suspend, for example across I/O, and a fiber
waiting for such a lock may be cancelled. Making every lock cancellable would
put queue bookkeeping on the uncontended path of the short ones; Go declined
a cancellable `sync.Mutex` for that reason, and Rust separates
`std::sync::Mutex` from `tokio::sync::Mutex`. The library has two kinds of
lock instead
([DS13](../../../specs/base/sync/decisions.md#ds13-two-kinds-of-lock-and-interruptible-waits)):

- **Non-interruptible** — `Mutex`, `LockBits`, `Guarded!T`. They barge, use
  the designated waker, pin their holder, and never observe cancellation.
- **Interruptible** — `InterruptibleMutex`, `InterruptibleGuarded!T`. They do
  not pin, grant in queue order by direct handoff, and stop waiting when the
  fiber is cancelled, with nothing held.

The interruptible lock is acquired and released only through guards. When a
cancellation races a grant, either the grant was committed first and the
waiter keeps the lock, or the cancellation won and no grant is ever
addressed to it. A caller that also paired `lock` with a hand-written
`unlock` could release a lock it never got, as Kotlin's callers did when its
mutex switched to prompt cancellation. Results are returned as a
`WaitStatus`, never thrown, so every operation stays `nothrow`.

## Recovering after `fork`

A forked child has one thread. If another thread of the parent held a bucket
lock at the moment of the fork, every contended operation in the child on
any key in that bucket would wait forever for a thread that does not exist.
The library therefore resets the table in a `pthread_atfork` child handler:
every bucket unlocked, every queue empty
([DS7](../../../specs/base/sync/decisions.md#ds7-reset-the-table-in-a-forked-child)).

That leaves the primitives' own bits, which may claim waiters that are gone:
a parked bit, or a designated bit naming a waker that never ran. The parking
lot records each woken, unresolved waiter in its bucket, and any operation
that finds a parked or designated bit with nothing behind it clears the bit
([DS15](../../../specs/base/sync/decisions.md#ds15-queue-derived-state-reconciles-itself)).
The same rule makes the state self-correcting in general, not only after a
fork. A primitive held in the parent at the fork stays held in the child, as
the contract says it must.

## How correctness is established

Lock algorithms fail in interleavings and memory orders that ordinary runs
reach rarely, so no single test establishes them. Each of several oracles
sees something the others cannot; [testing.md](../../../specs/base/sync/testing.md#oracles-at-a-glance)
lists what each one observes and misses, and the
[decision records](../../../specs/base/sync/decisions.md#ds12-an-exhaustive-interleaving-model-as-the-primary-oracle)
explain the choice of each.

- **The interleaving model.** Every primitive is written over a platform
  policy. In tests, a deterministic scheduler replaces it and explores every
  schedule of two or three threads and fibers within a preemption bound, in
  the manner of loom and CHESS. It follows the D and C++ memory models, not
  sequential consistency: a load may read any store the model permits, so a
  missing release–acquire edge shows up as a stale read of protected data.
  Seeded faults — a release weakened to relaxed, a wake despite a
  designation, a missing handoff — must each be caught, or the scenario
  proves nothing.
- **The protocol model.** A TLA+ specification of the parking lot and the
  lock protocols, written from the specification rather than the code,
  checks the same safety invariants and the liveness properties the
  interleaving model cannot: every waiter that neither times out nor is
  cancelled eventually acquires.
- **Litmus tests.** Message-passing tests for each release–acquire pair run
  millions of times on arm64, which reorders loads and stores, with x86-64
  as a control; a deliberately weakened variant must fail there. They are
  built optimized: the arm64 cores tested commit a lock's stores in order,
  so a dropped ordering shows only once the compiler may move the protected
  accesses across the relaxed atomics.
- **Native stress and ThreadSanitizer.** Real threads on every supported
  platform exercise what the model does not simulate: the kernel, `fork` and
  thread exit. Under ThreadSanitizer on Linux, the same runs check that
  protected data is ordered by the primitives in the schedules they reached.
- **The disassembly check.** In the `checked` build, the uncontended `lock`
  and `unlock` of `Mutex` and `LockBits` must compile to one atomic
  read–modify–write and a branch, with no call, which shows that the
  platform policy costs nothing in production.

Benchmarks then decide the constants — the bucket count, the spin length and
the starvation bound — that the correctness oracles leave open
([SPEC §7](../../../specs/base/sync/SPEC.md#_7-limits-and-constants)).
