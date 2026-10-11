# `AbstractQueuedSynchronizer` (Java)

Doug Lea's framework under every `java.util.concurrent` lock: one `int` of
user-defined state, a CLH-derived FIFO queue of per-acquire nodes, and
per-thread `park`/`unpark` permits — the reference design for a blocking lock
whose queue lives in the lock object rather than in a global table, and, since
Java 21, the mechanism that lets a virtual thread wait on a lock without
holding its carrier thread.

|                       |                                                                                                                                                                                                                                                                                                                                                                                                          |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**              | runtime library (synchronizer framework + locks built on it)                                                                                                                                                                                                                                                                                                                                             |
| **Language**          | Java                                                                                                                                                                                                                                                                                                                                                                                                     |
| **License**           | GPL-2.0 with Classpath Exception (OpenJDK); the JSR 166 sources are public domain                                                                                                                                                                                                                                                                                                                        |
| **Repository**        | [`openjdk/jdk`][jdk-repo], `src/java.base/share/classes/java/util/concurrent/locks/`                                                                                                                                                                                                                                                                                                                     |
| **Lineage**           | JSR 166, Java 5 (2004); queue later rewritten with explicit `prev`/`next` links and status bits (the design comment's "Historical note"; the release is not recorded in the shallow clone); paper: Lea, [_The java.util.concurrent Synchronizer Framework_][lea-paper], CSJP 2004, journal version _Science of Computer Programming_ 58(3):293–309, 2005, DOI [10.1016/j.scico.2005.03.007][lea-doi]     |
| **Lock word**         | `volatile int state` (meaning chosen by the subclass) + `exclusiveOwnerThread` + `head`/`tail` queue pointers in the lock object                                                                                                                                                                                                                                                                         |
| **Parking substrate** | per-thread permit: `LockSupport.park`/`unpark` → `Unsafe.park` (platform thread) or `VirtualThread.park` (continuation yield)                                                                                                                                                                                                                                                                            |
| **Source read**       | [`AbstractQueuedSynchronizer.java`][aqs], [`ReentrantLock.java`][rl], [`LockSupport.java`][ls], [`StampedLock.java`][sl], [`AbstractOwnableSynchronizer.java`][aos], [`java/lang/VirtualThread.java`][vt] (fetched at the same SHA; the local clone is sparse to `java.util.concurrent`); Lea's paper (full text, [`$REPOS/papers/fine-grained-locking/lea-2005-aqs.pdf`][lea-paper]); [JEP 491][jep491] |

## Overview

### What it solves

The paper states the problem as a refusal to pick one primitive as the basis
of the others ([Lea 2004][lea-paper], §1):

> If none of these constructs are intrinsically more primitive than the
> others, developers should not be compelled to arbitrarily choose one of them
> as a basis for building others. Instead, JSR166 establishes a small
> framework centered on class AbstractQueuedSynchronizer, that provides common
> mechanics that are used by most of the provided synchronizers in the
> package.

`ReentrantLock`, `ReentrantReadWriteLock`, `Semaphore`, `CountDownLatch` and
`ThreadPoolExecutor.Worker` are all a few lines of `tryAcquire`/`tryRelease`
over the same queue. The performance goal is explicitly _contended_ behaviour,
not the uncontended fast path ([Lea 2004][lea-paper], §2.2): "the usual JVM
strategy of optimizing locks primarily for the zero-contention case, leaving
other cases to less predictable 'slow paths' is not the right tactic for
typical multithreaded server applications".

### Design philosophy

**State is the subclass's; queuing is the framework's.** The class doc gives
the whole contract as two loops ([`AbstractQueuedSynchronizer.java`][aqs-doc]):

```java
Acquire:
    while (!tryAcquire(arg)) {
       enqueue thread if it is not already queued;
       possibly block current thread;
    }

Release:
    if (tryRelease(arg))
       unblock the first queued thread;
```

**A spin-lock queue repurposed for blocking.** The long design comment that
opens the implementation ([`AbstractQueuedSynchronizer.java`][aqs-overview])
is the primary source for the current queue:

> The wait queue is a variant of a "CLH" (Craig, Landin, and Hagersten) lock
> queue. CLH locks are normally used for spinlocks. We instead use them for
> blocking synchronizers by including explicit ("prev" and "next") links plus
> a "status" field that allow nodes to signal successors when releasing locks,
> and handle cancellation due to interrupts and timeouts. The status field
> includes bits that track whether a thread needs a signal (using
> LockSupport.unpark). Despite these additions, we maintain most CLH locality
> properties.

The paper explains why CLH and not MCS: CLH "appeared more amenable than MCS
for use in the synchronizer framework because they are more easily adapted to
handle cancellation and timeouts" ([Lea 2004][lea-paper], §3.3). See
[queue locks](./queue-locks.md) for the spin-lock originals.

**Barging by default, fairness by subclass.** The class doc names the default
policy and its alternatives ([`AbstractQueuedSynchronizer.java`][aqs-barging]):
"Throughput and scalability are generally highest for the default barging
(also known as _greedy_, _renouncement_, and _convoy-avoidance_) strategy."

## How it works

The queue is a doubly linked list of `Node` objects whose `status` packs three
bits ([`AbstractQueuedSynchronizer.java`][aqs-node]):

```java
static final int WAITING   = 1;          // must be 1
static final int CANCELLED = 0x80000000; // must be negative
static final int COND      = 2;          // in a condition wait

abstract static class Node {
    volatile Node prev;       // initially attached via casTail
    volatile Node next;       // visibly nonnull when signallable
    Thread waiter;            // visibly nonnull when enqueued
    volatile int status;      // written by owner, atomic bit ops by others
}
```

One method, `acquire(Node, int, boolean shared, boolean interruptible,
boolean timed, long time)`, implements every blocking acquire as a state
machine whose steps its own comment lists ([`acquire`][aqs-acquire]):

1. If the node is first (its `prev` is `head`), or not yet queued, call
   `tryAcquire`. Success while first makes the node the new `head` (dummy).
2. No queue yet: CAS a dummy `head` in — lazily, "because it would be wasted
   effort if there is never contention" ([design comment][aqs-overview]).
3. No node yet: allocate an `ExclusiveNode` or `SharedNode` and **retry the
   acquire before enqueuing**.
4. Not yet linked: `casTail(t, node)`, then the plain store `t.next = node`.
   One CAS on `tail` is "a simple point of demarcation from unqueued to
   queued".
5. First and recently woken: spin `Thread.onSpinWait()` for `spins` rounds.
6. `status == 0`: set `WAITING` and loop once more (the Dekker-style
   "indicate WAITING, retry, recheck" handshake).
7. Otherwise `LockSupport.park(this)` (or `parkNanos`), then `clearStatus()`
   and loop.

Release is `tryRelease` followed by `signalNext(head)`, which unparks the
successor only if its status is non-zero, clearing `WAITING` atomically
([`signalNext`][aqs-signalnext]):

```java
private static void signalNext(Node h) {
    Node s;
    if (h != null && (s = h.next) != null && s.status != 0) {
        s.getAndUnsetStatus(WAITING);
        LockSupport.unpark(s.waiter);
    }
}
```

Cancellation (timeout, interrupt) sets `CANCELLED` and calls `cleanQueue`,
which walks back from `tail` unsplicing cancelled nodes with CAS on
`prev`/`next`, "reminiscent of Michael-Scott queues in that after a successful
CAS to prev field, other threads help fix next fields"
([`cleanQueue`][aqs-cleanqueue]).

`ReentrantLock` is the canonical subclass: `state` is the hold count,
`exclusiveOwnerThread` the owner, and the fair/nonfair split is two `Sync`
subclasses that differ only in whether they consult the queue
([`ReentrantLock.java`][rl-sync]):

```java
// NonfairSync
final boolean initialTryLock() {
    Thread current = Thread.currentThread();
    if (compareAndSetState(0, 1)) { // first attempt is unguarded
        setExclusiveOwnerThread(current);
        return true;
    } ...
// FairSync
protected final boolean tryAcquire(int acquires) {
    if (getState() == 0 && !hasQueuedPredecessors() &&
        compareAndSetState(0, acquires)) { ...
```

## Analysis

### State word and fast path

The lock state is a full `int` (`private volatile int state`,
[`AbstractQueuedSynchronizer.java`][aqs-state]); a 64-bit sibling,
`AbstractQueuedLongSynchronizer`, exists for state that needs more bits. The
paper justifies 32 bits as pragmatic: 64-bit atomics were "emulated using
internal locks on enough platforms that the resulting synchronizers would not
perform well" ([Lea 2004][lea-paper], §3.1). The uncontended `ReentrantLock`
acquire is one `compareAndSetState(0, 1)` (a volatile CAS, i.e. sequentially
consistent) plus a plain store of `exclusiveOwnerThread`; release is a volatile
store of `state` followed by a read of `head` — no RMW at all when nobody is
queued. Waiter presence is **not** in `state`: it is `head != null` plus the
successor's `status`, so the lock word never encodes "contended". That is the
opposite of a 3-state [futex](./concepts.md#futex) word, and possible only
because the queue pointers sit next to `state` in the same object.

### Waiting: spin, yield, park

The design comment is explicit that AQS does not spin in the usual sense:

> To counteract possible repeated unlucky rewaits, we exponentially increase
> retries (up to 256) to acquire each time a thread is unparked. Except in this
> case, AQS locks do not spin; they instead interleave attempts to acquire with
> bookkeeping steps. (Users who want spinlocks can use tryAcquire.)

In code, `spins = postSpins = (byte)((postSpins << 1) | 1)` after every park,
so a first waiter that loses to a barger retries 1, 3, 7, … times with
`Thread.onSpinWait()` (x86 `pause`) before parking again
([`acquire`][aqs-acquire]). A waiter that is not first never spins: it parks
as soon as it has published `WAITING`. The class doc calls this "most of the
benefits of spins when exclusive synchronization is only briefly held, without
most of the liabilities when it isn't" ([`AbstractQueuedSynchronizer.java`][aqs-barging]).
On allocation failure (`OutOfMemoryError` creating a node) the acquire falls
back to `acquireOnOOME`, a spin with exponential `park(nanos)` backoff capped
near one second.

### The parking substrate

Waiters park on a **per-thread permit**, never on the lock's address
([`LockSupport.java`][ls-doc]):

> This class associates, with each thread that uses it, a permit (in the sense
> of the Semaphore class). A call to `park` will return immediately if the
> permit is available, consuming it in the process; otherwise it _may_ block.
> […] (Unlike with Semaphores though, permits do not accumulate. There is at
> most one.)

The permit makes the unpark-before-park race benign (the unpark is banked)
and is why AQS needs no compare-and-block primitive: the queue is the
"address", the node's `status` bit is the futex-like check, and `park` only
needs a binary per-thread event. `park` may also return spuriously, and a
stray permit left by an earlier synchronizer can make one `park` return early
— the paper accepts this because "It is more efficient to invoke park multiple
times when it happens to be necessary" ([Lea 2004][lea-paper], §3.2). Waiter
records (`Node`s) are heap objects allocated per contended acquire and
reclaimed by the GC; "fields of nodes coming off the list are nulled out as
soon as possible" for collectability ([design comment][aqs-overview]). This is
the Java analogue of the per-thread `ThreadParker` in
[`parking_lot`](./parking-lot.md#the-parking-substrate), without the global
table: each lock owns its queue.

### Fairness, handoff and starvation

The default is [barging](./concepts.md#barging-and-handoff): `tryAcquire`
runs before enqueuing, so arriving threads can take the lock while the woken
first waiter is still being scheduled. The paper quantifies the risk ([Lea
2004][lea-paper], §4.1): "if incoming threads arrive faster than it takes an
unparked thread to unblock, the first thread in the queue will only rarely win
the race, so will almost always reblock". The only counter-measure is the
growing `postSpins` budget above; there is **no timer-based eventual fairness**
and no direct handoff in the nonfair lock. Fairness is a subclass policy:
`FairSync.tryAcquire` fails when `hasQueuedPredecessors()`, and its
`initialTryLock` refuses even the first CAS when `hasQueuedThreads()`. Even
then the doc warns that "the untimed `tryLock()` method does not honor the
fairness setting" ([`ReentrantLock.java`][rl]). The paper's measurement: with
briefly held locks fair mode's per-thread completion-time standard deviation
was 0.7 % of the mean versus 6.0 % for nonfair; with long critical sections
run times were "nearly identical (9.79s for Fair, 9.72s for Reentrant)" while
nonfair variability rose to 29.5 % ([Lea 2004][lea-paper], §5.1). Fair mode on
short critical sections is a [convoy](./concepts.md#convoys): "context
switching time completely determines performance for Fair locks".

### Condition variables and predicates

`ConditionObject` keeps a separate singly linked FIFO of `ConditionNode`s,
touched only while the lock is held, so it needs no atomics for its own links
([design comment][aqs-overview]): "Upon await, a node is inserted into a
condition queue. Upon signal, the node is enqueued on the main queue. A
special status field value is used to track and atomically trigger this."
`await` saves the full `state` (the hold count, so reentrant locks release
completely), releases, and blocks until `canReacquire` sees the node linked
into the lock queue ([`await`][aqs-await]). `signal` clears `COND` and calls
`enqueue(first)` ([`doSignal`][aqs-dosignal]) — it does **not** unpark the
waiter unless its new predecessor is cancelled. The waiter is woken later by
the lock's own `signalNext` when it reaches the front. This is
[wait morphing](./concepts.md#wait-morphing) done in user space, with
`signalAll` transferring the whole list and so avoiding a
[thundering herd](./concepts.md#thundering-herd) on the lock. Predicates
remain the caller's loop; there is no `Await(predicate)` à la
[Abseil](./abseil-mutex.md).

### Footprint and layout

An AQS-based lock is at least two heap objects (`ReentrantLock` and its
`Sync`) whose `Sync` carries `head`, `tail`, `state` and
`exclusiveOwnerThread`; contention adds one `Node` per waiting acquire. The
paper rejects compactness as a goal ([Lea 2004][lea-paper], §2.2): built-in
monitors minimise space "because any Java object can serve as a lock", but
"Programmers construct synchronizers only when needed, so there is no need to
compact space". `StampedLock` keeps "lock state and queue pointers together
(normally on the same cache line)" and declines to pad
([`StampedLock.java`][sl-notes]). The lesson for a word-sized D lock is the
inverse: AQS's queue-in-object design is what a 4-byte lock cannot afford.

### Portability

All of the framework is Java; portability is delegated to `Unsafe.park`,
which HotSpot maps per OS. The paper lists the analogues it was designed to fit
— "the Solaris-9 thread library, in WIN32 'consumable events', and in the
Linux NPTL thread library" — and notes that HotSpot then actually used "a
pthread condvar in order to fit into the existing runtime design" ([Lea
2004][lea-paper], §3.2). The binary per-thread event is therefore the only OS
contract AQS needs.

### Async and fiber integration

This is AQS's most instructive dimension. `LockSupport.park` dispatches on the
current thread's kind ([`LockSupport.java`][ls-park]):

```java
if (t.isVirtual()) {
    JLA.parkVirtualThread();
} else {
    U.park(false, 0L);
}
```

`VirtualThread.park` consumes the permit if present, otherwise sets
`PARKING` and yields the continuation, freeing the carrier; only if the yield
fails (a native frame or monitor pins it, or OOME) does it fall back to
`parkOnCarrierThread`, recording `PINNED` and a `jdk.VirtualThreadPinned` JFR
event ([`VirtualThread.java`][vt-park]). `unpark` from any thread CASes
`PARKED → UNPARKED` and submits the continuation to the scheduler
([`unpark`][vt-unpark]). Because every `java.util.concurrent` lock, condition
and semaphore blocks only through `park`, they all became virtual-thread
friendly in Java 21 without changes to AQS: **the lock never knows what kind
of waiter it holds**. The waking side is a plain method call that enqueues a
task, so a platform thread can wake a virtual thread (the cross-thread wake an
event-loop `WaitWord` needs).

`synchronized` was the exception. [JEP 491][jep491] (delivered in JDK 24)
explains that the JVM "tracks which platform thread holds the monitor, not
which virtual thread", so a virtual thread holding or blocking on a monitor
could not unmount; the JEP changes the JVM "so that virtual threads can
acquire, hold, and release monitors, independently of their carriers". Until
then, the JEP notes, users had moved to `java.util.concurrent` locks, which do
not pin. A second integration point is `ConditionNode implements
ForkJoinPool.ManagedBlocker`, so an untimed `await` inside a `ForkJoinPool`
lets the pool add a compensating worker "without risking fixed pool
exhaustion" ([`AbstractQueuedSynchronizer.java`][aqs-node]).

## Strengths

- One queue algorithm serves locks, semaphores, latches and read-write locks;
  subclasses write only `tryAcquire`/`tryRelease` over an `int`.
- Release does no RMW when uncontended, and wakes at most one thread (or a
  cascade of shared-mode nodes).
- Per-thread permits make the queue the only shared structure; no global
  table, no hash collisions between unrelated locks.
- `signal` transfers the node to the lock queue (wait morphing) rather than
  waking it.
- Waiter kind is abstracted behind `park`, which is why virtual threads came
  for free.

## Weaknesses

- Heap-allocated nodes per contended acquire and two objects per lock: the
  design depends on a GC and is far from word-sized.
- Barging has only probabilistic starvation bounds; no eventual-fairness timer.
- Fair mode convoys on short critical sections.
- Single-permit `park` admits "lost unpark" bugs when a waiter parks for an
  unrelated reason between publishing and blocking (the `LockSupport` doc
  warns of class loading).
- Cancellation needs an O(n) `cleanQueue` walk.

## Key design decisions and trade-offs

| Decision                                   | Rationale                                                    | Trade-off                                                             |
| ------------------------------------------ | ------------------------------------------------------------ | --------------------------------------------------------------------- |
| CLH queue with explicit `prev`/`next`      | One CAS to enqueue; `prev` links make cancellation tractable | Nodes on the heap; `next` is a hint that needs backward-walk fallback |
| `int state` owned by subclass              | One framework for every synchronizer                         | 32 bits only; waiters are tracked outside the word                    |
| Per-thread binary permit (`park`/`unpark`) | Wake-before-wait race is benign; maps onto any OS event      | Spurious returns; stray permits leak across synchronizers             |
| Barging default, fairness via `tryAcquire` | Highest throughput; avoids convoys                           | Starvation is possible; fair mode is slow on short sections           |
| `signal` re-enqueues instead of unparking  | No thundering herd; waiter wakes holding the turn            | Condition waiters depend on the lock's release to run                 |
| Blocking only through `LockSupport.park`   | Lets the runtime swap the waiter's blocking strategy         | Any path that blocks some other way (monitors before JDK 24) pins     |

## Sources

- [`AbstractQueuedSynchronizer.java`][aqs] — design comment, `acquire`,
  `cleanQueue`, `ConditionObject`.
- [`ReentrantLock.java`][rl], [`LockSupport.java`][ls],
  [`StampedLock.java`][sl], [`AbstractOwnableSynchronizer.java`][aos].
- [`VirtualThread.java`][vt] — virtual-thread park/unpark state machine.
- Doug Lea, "The java.util.concurrent Synchronizer Framework", CSJP 2004
  ([PDF][lea-paper]); _Sci. Comput. Program._ 58(3), 2005, [DOI][lea-doi].
- [JEP 491: Synchronize Virtual Threads without Pinning][jep491].

<!-- References -->

[jdk-repo]: https://github.com/openjdk/jdk/tree/5f92fecdd23672b8b1d2ee7bb0d25b726fb4c0e0
[aqs]: https://github.com/openjdk/jdk/blob/5f92fecdd23672b8b1d2ee7bb0d25b726fb4c0e0/src/java.base/share/classes/java/util/concurrent/locks/AbstractQueuedSynchronizer.java
[aqs-doc]: https://github.com/openjdk/jdk/blob/5f92fecdd23672b8b1d2ee7bb0d25b726fb4c0e0/src/java.base/share/classes/java/util/concurrent/locks/AbstractQueuedSynchronizer.java#L140-L153
[aqs-barging]: https://github.com/openjdk/jdk/blob/5f92fecdd23672b8b1d2ee7bb0d25b726fb4c0e0/src/java.base/share/classes/java/util/concurrent/locks/AbstractQueuedSynchronizer.java#L155-L181
[aqs-overview]: https://github.com/openjdk/jdk/blob/5f92fecdd23672b8b1d2ee7bb0d25b726fb4c0e0/src/java.base/share/classes/java/util/concurrent/locks/AbstractQueuedSynchronizer.java#L317-L460
[aqs-node]: https://github.com/openjdk/jdk/blob/5f92fecdd23672b8b1d2ee7bb0d25b726fb4c0e0/src/java.base/share/classes/java/util/concurrent/locks/AbstractQueuedSynchronizer.java#L462-L522
[aqs-state]: https://github.com/openjdk/jdk/blob/5f92fecdd23672b8b1d2ee7bb0d25b726fb4c0e0/src/java.base/share/classes/java/util/concurrent/locks/AbstractQueuedSynchronizer.java#L535-L538
[aqs-signalnext]: https://github.com/openjdk/jdk/blob/5f92fecdd23672b8b1d2ee7bb0d25b726fb4c0e0/src/java.base/share/classes/java/util/concurrent/locks/AbstractQueuedSynchronizer.java#L636-L648
[aqs-acquire]: https://github.com/openjdk/jdk/blob/5f92fecdd23672b8b1d2ee7bb0d25b726fb4c0e0/src/java.base/share/classes/java/util/concurrent/locks/AbstractQueuedSynchronizer.java#L694-L807
[aqs-cleanqueue]: https://github.com/openjdk/jdk/blob/5f92fecdd23672b8b1d2ee7bb0d25b726fb4c0e0/src/java.base/share/classes/java/util/concurrent/locks/AbstractQueuedSynchronizer.java#L820-L857
[aqs-dosignal]: https://github.com/openjdk/jdk/blob/5f92fecdd23672b8b1d2ee7bb0d25b726fb4c0e0/src/java.base/share/classes/java/util/concurrent/locks/AbstractQueuedSynchronizer.java#L1544-L1565
[aqs-await]: https://github.com/openjdk/jdk/blob/5f92fecdd23672b8b1d2ee7bb0d25b726fb4c0e0/src/java.base/share/classes/java/util/concurrent/locks/AbstractQueuedSynchronizer.java#L1735-L1774
[rl]: https://github.com/openjdk/jdk/blob/5f92fecdd23672b8b1d2ee7bb0d25b726fb4c0e0/src/java.base/share/classes/java/util/concurrent/locks/ReentrantLock.java
[rl-sync]: https://github.com/openjdk/jdk/blob/5f92fecdd23672b8b1d2ee7bb0d25b726fb4c0e0/src/java.base/share/classes/java/util/concurrent/locks/ReentrantLock.java#L119-L288
[ls]: https://github.com/openjdk/jdk/blob/5f92fecdd23672b8b1d2ee7bb0d25b726fb4c0e0/src/java.base/share/classes/java/util/concurrent/locks/LockSupport.java
[ls-doc]: https://github.com/openjdk/jdk/blob/5f92fecdd23672b8b1d2ee7bb0d25b726fb4c0e0/src/java.base/share/classes/java/util/concurrent/locks/LockSupport.java#L44-L72
[ls-park]: https://github.com/openjdk/jdk/blob/5f92fecdd23672b8b1d2ee7bb0d25b726fb4c0e0/src/java.base/share/classes/java/util/concurrent/locks/LockSupport.java#L178-L228
[sl]: https://github.com/openjdk/jdk/blob/5f92fecdd23672b8b1d2ee7bb0d25b726fb4c0e0/src/java.base/share/classes/java/util/concurrent/locks/StampedLock.java
[sl-notes]: https://github.com/openjdk/jdk/blob/5f92fecdd23672b8b1d2ee7bb0d25b726fb4c0e0/src/java.base/share/classes/java/util/concurrent/locks/StampedLock.java#L243-L310
[aos]: https://github.com/openjdk/jdk/blob/5f92fecdd23672b8b1d2ee7bb0d25b726fb4c0e0/src/java.base/share/classes/java/util/concurrent/locks/AbstractOwnableSynchronizer.java
[vt]: https://github.com/openjdk/jdk/blob/5f92fecdd23672b8b1d2ee7bb0d25b726fb4c0e0/src/java.base/share/classes/java/lang/VirtualThread.java
[vt-park]: https://github.com/openjdk/jdk/blob/5f92fecdd23672b8b1d2ee7bb0d25b726fb4c0e0/src/java.base/share/classes/java/lang/VirtualThread.java#L748-L860
[vt-unpark]: https://github.com/openjdk/jdk/blob/5f92fecdd23672b8b1d2ee7bb0d25b726fb4c0e0/src/java.base/share/classes/java/lang/VirtualThread.java#L862-L903
[lea-paper]: https://gee.cs.oswego.edu/dl/papers/aqs.pdf
[lea-doi]: https://doi.org/10.1016/j.scico.2005.03.007
[jep491]: https://openjdk.org/jeps/491
