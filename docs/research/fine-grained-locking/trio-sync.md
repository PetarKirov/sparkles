# Trio synchronization (Python)

Structured-concurrency async I/O for Python whose synchronization primitives
all sit on one **per-object `ParkingLot`** — named after, and explicitly
modelled on, WebKit's and Rust's parking lots — with strict FIFO handoff,
cancellation as a first-class abort callback, a condition variable that
_requeues_ waiters onto the lock instead of waking them, and a single
documented door, `TrioToken.run_sync_soon`, through which threads and signal
handlers re-enter the loop.

|                        |                                                                                                                                                                                                                                                                                                                                        |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**               | library (single-threaded async runtime)                                                                                                                                                                                                                                                                                                |
| **Language**           | Python                                                                                                                                                                                                                                                                                                                                 |
| **License**            | MIT OR Apache-2.0                                                                                                                                                                                                                                                                                                                      |
| **Repository**         | [`python-trio/trio`][trio-repo] at `96914fbd8c09` (2026-06-02), `0.33.0+dev`                                                                                                                                                                                                                                                           |
| **Primitives covered** | `trio.lowlevel.ParkingLot`, `Lock`, `StrictFIFOLock`, `Condition`, `Semaphore`, `CapacityLimiter`, `Event`; `wait_task_rescheduled`/`reschedule`; `TrioToken.run_sync_soon`, `trio.from_thread`, `trio.to_thread`                                                                                                                      |
| **Parking substrate**  | per-object `OrderedDict[Task, None]` (a FIFO with O(1) removal); a parked task is a suspended coroutine, rescheduled by appending it to the run queue                                                                                                                                                                                  |
| **Fairness**           | strict FIFO with ownership handoff for every primitive; documented as a guarantee                                                                                                                                                                                                                                                      |
| **Source read**        | [`src/trio/_core/_parking_lot.py`][pl], [`src/trio/_sync.py`][sync], [`src/trio/_core/_traps.py`][traps], [`src/trio/_core/_run.py`][run] (`reschedule`), [`src/trio/_core/_entry_queue.py`][entry], [`src/trio/_core/_wakeup_socketpair.py`][wakeup], [`src/trio/_threads.py`][threads], [`docs/source/reference-core.rst`][ref-core] |

## Overview

### What it solves

Trio runs every task of a `trio.run` call on one thread, switching only at
`await` checkpoints, so its locks never protect memory from parallel access —
they serialize _tasks_ that hold a resource across checkpoints. The library
says so outright ([`reference-core.rst` L199–L207][ref-thread-safety]):

> The vast majority of Trio's API is _not_ thread safe: it can only be used
> from inside a call to `trio.run`. This manual doesn't bother documenting
> this on individual calls; unless specifically noted otherwise, you should
> assume that it isn't safe to call any Trio functions from anywhere except
> the Trio thread.

What Trio adds over a naive wait list is **cancellation**: any blocked
operation can be interrupted by a cancel scope at any time, and every
primitive must leave consistent state behind when that happens.

### Design philosophy

The `ParkingLot` module comment names its ancestors and what changes when the
scheduler is cooperative ([`_parking_lot.py` L1–L22][pl-comment]):

> ParkingLot provides an abstraction for a fair waitqueue with cancellation
> and requeuing support. Inspiration:
>
> [`webkit.org/blog/6161/locking-in-webkit/`][webkit-blog]
> [`amanieu.github.io/parking_lot/`][pl-rust-docs]
>
> which were in turn heavily influenced by
>
> [`gee.cs.oswego.edu/dl/papers/aqs.pdf`][aqs-paper]
>
> Compared to these, our use of cooperative scheduling allows some
> simplifications (no need for internal locking). On the other hand, the need
> to support Trio's strong cancellation semantics adds some complications
> (tasks need to know where they're queued so they can cancel). Also, in the
> above work, the ParkingLot is a global structure that holds a collection of
> waitqueues keyed by lock address, and which are opportunistically allocated
> and destroyed as contention arises; this allows the worst-case memory usage
> for all waitqueues to be O(#tasks). Here we allocate a separate wait queue
> for each synchronization object, so we're O(#objects + #tasks).

Fairness is a documented promise, not an implementation detail
([`reference-core.rst` L1156–L1164][ref-fairness]): "These classes are all
guaranteed to be "fair", meaning that when it comes time to choose who will be
next to acquire a lock, get an item from a queue, etc., then it always goes to
the task which has been waiting longest. It's not entirely clear whether this
is the best choice, but for now that's how it works."

## How it works

**The blocking trap.** Every blocking operation ends in
`wait_task_rescheduled(abort_fn)` ([`_traps.py` L115–L160][traps-wtr]): the
caller first arranges for "someone" to call `reschedule(task)` later, then
suspends. If the task's cancel scope fires first, Trio calls `abort_fn`, which
must either undo the arrangement and return `Abort.SUCCEEDED` (the task then
raises `Cancelled`) or return `Abort.FAILED` and guarantee a later
`reschedule`. `reschedule` sets the value to send, clears `task._abort_func`
and appends the task to `runq` ([`_run.py` L1898–L1931][run-reschedule]) — so
**once a task is rescheduled it can no longer be aborted**.

**`ParkingLot`** ([`_parking_lot.py` L136–L317][pl-class]) is an
`OrderedDict[Task, None]` plus a `broken_by` list:

- `park()` inserts the current task, records the lot in
  `task.custom_sleep_data`, and waits with an `abort_fn` that deletes the task
  from `task.custom_sleep_data._parked` — the lot it is _currently_ in, which
  `repark` may have changed ([L168–L190][pl-park]).
- `unpark(count)` pops the `count` oldest tasks, `reschedule`s each and
  **returns the list of tasks it woke** ([L205–L219][pl-unpark]).
- `repark(new_lot, count)` moves the oldest tasks to another lot, preserving
  order, without waking them ([L226–L268][pl-repark]).
- `break_lot(task)` reschedules every parked task with `BrokenResourceError`
  and makes future `park()` calls fail ([L279–L306][pl-break]); `Lock`
  registers its owner as a breaker so a task that exits while holding a lock
  breaks it instead of deadlocking waiters.

**`Lock`** (`_LockImpl`, [`_sync.py` L580–L661][lock]) is `_owner` + `_lot`.
`acquire_nowait` succeeds only if `_owner is None and not self._lot`;
`acquire` awaits `checkpoint_if_cancelled()`, tries `acquire_nowait`, and
otherwise parks. `release` does the handoff ([L645–L661][lock-release]):

```python
remove_parking_lot_breaker(self._owner, self._lot)
if self._lot:
    (self._owner,) = self._lot.unpark(count=1)
    add_parking_lot_breaker(self._owner, self._lot)
else:
    self._owner = None
```

**`Semaphore`** keeps the invariant "`bool(self._lot)` implies
`self._value == 0`": `release` with waiters unparks one **without**
incrementing the value ([L479–L484][sem-invariant], [L531–L547][sem-release]).
**`CapacityLimiter`** does the same with a `_borrowers` set and a
`_pending_borrowers` map, assigning a token to each task `unpark` returns
([L291–L294][cl-wake]). **`Event`** is a flag plus a `set` of waiting tasks;
`set()` reschedules all ([L60–L120][event]).

## Analysis

### State word and fast path

There is none in the atomic sense: state is ordinary Python attributes,
mutated only by the Trio thread between checkpoints. `Lock.acquire` on a free
lock is `checkpoint_if_cancelled()` + attribute writes + a
`cancel_shielded_checkpoint()`, so even an uncontended acquire yields to the
scheduler once — a deliberate rule that every Trio blocking call is a
checkpoint. Release is not a checkpoint: "in Trio releasing a lock is not a
checkpoint" ([`reference-core.rst` L1166–L1176][ref-fairness]).

### Waiting: spin, yield, park

No spinning — it would never terminate, since the holder cannot run while the
waiter spins. A waiter parks immediately; parking is suspending the coroutine.
The Trio thread itself sleeps only in the I/O manager (`epoll`, `kqueue`, or
IOCP) when `runq` is empty.

### The parking substrate

Waiter records are entries in a per-object `OrderedDict`, keyed by `Task`, so
removal on cancellation is O(1) without an intrusive link. The module comment
still describes "a SortedDict ordered by a global monotonic counter" and
muses that "an intrusive doubly-linked list would also be a natural approach"
([L37–L44][pl-comment]); the code has since moved to `OrderedDict`. It also
records the open question "should we switch to the shared global ParkingLot
approach?" — Trio considered and declined WebKit's
[global hashed table](./webkit-wtf-lock.md) because "our synchronization
objects are heavier than theirs and our tasks are lighter". Since a task can
be parked in at most one lot, `task.custom_sleep_data` doubles as the
back-pointer that makes `abort_fn` and `repark` cheap.

### Fairness, handoff and starvation

**Strict FIFO handoff everywhere.** `Lock.release` assigns `_owner` to the
oldest waiter before that task runs; `acquire_nowait` refuses a newcomer while
`_lot` is non-empty; so [barging](./concepts.md#barging-and-handoff) is
impossible and starvation is bounded by queue length. The documented demo is
two tasks re-acquiring in a loop: "With an unfair lock, this would result in
the same task holding the lock forever and the other task being starved out.
But if you run this, you'll see that the two tasks politely take turns"
([`reference-core.rst` L1166–L1176][ref-fairness]). The price — the
[convoy](./concepts.md#convoys) WebKit's lock was designed to avoid — is
lower here, because the handed-to task runs on the same thread at the next
scheduling step rather than after an OS context switch.

`StrictFIFOLock` is today "identical to `Lock`" and exists as "an executable
reminder that you're relying on this property", reserved for a future in which
Trio adds non-FIFO scheduling ([L697–L758][strict-fifo]); the `ParkingLot`
comment notes that weighted fair queuing would force `unpark` to stop
returning the tasks it woke ([L63–L71][pl-comment]).

**Cancellation never loses a handoff.** Two facts combine:

1. While a task is parked, its `abort_fn` removes it from the lot, so a
   cancelled waiter simply leaves the queue; nothing was promised to it.
2. Once `unpark` has chosen a task, `reschedule` has cleared its
   `_abort_func`, so a cancellation arriving afterwards cannot abort the wait.
   The task wakes up owning the lock (or holding the semaphore unit, or the
   capacity token) and sees `Cancelled` at its next checkpoint, inside the
   `async with` that will release it.

The decision point and the ownership transfer are one synchronous step, so
there is no window in which a permit belongs to a cancelled waiter.
`CapacityLimiter.acquire_on_behalf_of` additionally pops its
`_pending_borrowers` entry on `Cancelled` ([L358–L384][cl-acquire]).

### Condition variables and predicates

`Condition` is **wait morphing by construction**
([`concepts`](./concepts.md#wait-morphing)). `wait()` releases the lock and
parks on the condition's own lot; `notify(n)` does not wake anyone — it
`repark`s `n` waiters onto **the lock's** lot ([L832–L892][condition]):

> NOTE: we go to sleep on `self._lot`, but we'll wake up on
> `self._lock._lot`. That's all that's required to acquire a Lock.

This works because `Lock.acquire`'s contended path is "just
`_lot.park()`" (a comment in `acquire` warns to keep it that way), so a
reparked condition waiter is indistinguishable from a lock waiter and is
handed the lock by a later `release`. `notify` and `notify_all` require the
caller to hold the lock. A cancelled `wait()` re-acquires the lock under a
shielded cancel scope before raising, so `async with condition: await
condition.wait()` never releases a lock it does not hold. There are no
predicate waits.

### Footprint and layout

Python objects: every `Lock`, `Semaphore`, `Condition` and `CapacityLimiter`
allocates its own `ParkingLot` (an attrs object holding an `OrderedDict` and
a list) at construction — the O(#objects) cost the module comment accepts.
Cache-line layout is not a consideration.

### Portability

Pure Python over the standard library; the platform-specific parts are the I/O
manager (`epoll`, `kqueue`, Windows IOCP) and the wakeup socketpair, whose
buffer tuning is per-OS ("Linux 4.8: 6 / macOS (darwin 15.5): 1 / Windows 10:
525347" sends before `BlockingIOError`, [`_wakeup_socketpair.py`
L21–L30][wakeup-sock]).

### Async and fiber integration

**Inside the loop**, everything is a task primitive; no Trio primitive can be
waited on by an OS thread. The duality is mediated, not shared:

- **Thread → loop: `TrioToken.run_sync_soon(fn, *args)`**, "the fundamental
  primitive used to re-enter the Trio run loop from outside of it", safe "from
  the main thread, from other threads, and from signal handlers"
  ([`_entry_queue.py` L174–L223][token]). It appends to a `deque` (or, with
  `idempotent=True`, an ordered `dict` that coalesces duplicates) under an
  `RLock` and calls `wakeup_thread_and_signal_safe()`, which `send`s one byte
  to a non-blocking socketpair, ignoring `BlockingIOError` when the 1-byte
  buffer is already full ([L130–L148][entry-submit],
  [`_wakeup_socketpair.py` L37–L50][wakeup-sock]). A system task drains the
  queue in bounded passes and otherwise sleeps in `wait_readable` on the
  socketpair ([L87–L103][entry-task]). Because the socket buffer is one byte,
  a burst of wakeups collapses into one readable event — the same
  deduplication folly's `remoteReadyInsert` gets from its empty-list check.
- **`trio.from_thread.run` / `run_sync`** wrap `run_sync_soon`: the thread
  posts a closure that runs `fn` in a Trio task and puts the outcome on a
  `queue.SimpleQueue`, then **blocks the thread on `queue.get()`**
  ([`_threads.py` L498–L528][send-to-trio]). A thread that wants a
  `trio.Lock` therefore calls `trio.from_thread.run(lock.acquire)`; it waits
  on an OS queue while a proxy task waits in the lock's `ParkingLot`.
- **Loop → thread: `trio.to_thread.run_sync`** borrows a token from a
  `CapacityLimiter` _on behalf of_ a placeholder, starts the function on a
  cached thread, and waits in `wait_task_rescheduled`; the thread reports back
  with `run_sync_soon(report_back_in_trio_thread_fn, result)`
  ([L415–L445][to-thread]). Cancellation is explicit about the thread: with
  `abandon_on_cancel=False` "the function ignores the cancellation and keeps
  going"; with `True`, "**the thread keeps running in background** – we just
  abandon it", and "The `limiter` is only released after the thread has
  _actually_ finished" ([L303–L325][to-thread-cancel]).

For a `WaitWord` design Trio contributes three precedents: an abort callback
that runs synchronously in the loop and is disarmed at the instant of
handoff; a single thread-safe entry queue plus a coalescing wakeup fd as the
only cross-thread path; and `repark` as wait morphing between two queues the
loop owns.

## Strengths

- **One `ParkingLot` abstraction** implements every primitive, including
  requeue (`repark`) and lot breaking.
- **Fairness is a documented guarantee**, with handoff and no barging.
- **Cancellation is structurally safe**: `abort_fn` runs only while parked,
  `reschedule` disarms it, so handoffs are never lost.
- **`Condition` is genuine wait morphing**, and `Lock` breaks rather than
  deadlocks if its owner exits.
- **One cross-thread entry point**, signal-safe, with a coalescing 1-byte
  wakeup socket.

## Weaknesses

- **Not thread-safe**: a thread can only reach a primitive by posting to the
  loop and blocking on an OS queue — two hops and two context switches.
- **Every acquire is a checkpoint**, so even uncontended locking yields.
- **FIFO handoff only**; no barging mode for throughput (mitigated by the
  single-threaded scheduler).
- **Per-object queue allocation**, O(#objects) memory.
- Stale module comment (`SortedDict`) describes a removed data structure.

## Key design decisions and trade-offs

| Decision                                           | Rationale                                                                                    | Trade-off                                                                   |
| -------------------------------------------------- | -------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Per-object `ParkingLot`, not a global hashed table | "our synchronization objects are heavier than theirs and our tasks are lighter"              | O(#objects + #tasks) memory                                                 |
| No internal locking                                | "our use of cooperative scheduling allows some simplifications"                              | nothing is usable from another thread                                       |
| Strict FIFO with ownership handoff                 | documented fairness: "it always goes to the task which has been waiting longest"             | convoy-style handoff; `StrictFIFOLock` reserved for a non-FIFO future       |
| `abort_fn` per wait; `reschedule` clears it        | cancellation must undo the wait or guarantee a later reschedule                              | every blocking primitive writes its own abort logic                         |
| `Condition.notify` = `repark` onto the lock's lot  | waking a waiter that will only block on the lock is wasted work                              | requires `Lock.acquire`'s slow path to be exactly `_lot.park()`             |
| Owner registered as lot breaker                    | a task that dies holding a lock breaks it (`BrokenResourceError`) instead of hanging waiters | extra global bookkeeping (`GLOBAL_PARKING_LOT_BREAKER`)                     |
| Threads enter via `run_sync_soon` + socketpair     | one thread- and signal-safe primitive; buffer of 1 byte coalesces wakeups                    | thread-side waits block on a `SimpleQueue`; extra hop through a system task |

## Sources

- `python-trio/trio` at [`96914fbd8c09`][trio-repo]: the files in the
  metadata table.
- [`docs/source/reference-core.rst`][ref-core] — "Thread safety"
  (L199–L207) and "Fairness" (L1156–L1196).
- The references cited by the `ParkingLot` comment: [Locking in
  WebKit][webkit-blog], [`parking_lot`][pl-rust-docs], and Lea's [AQS
  paper][aqs-paper] (linked, not re-read here; see the
  [`webkit-wtf-lock`](./webkit-wtf-lock.md), [`parking-lot`](./parking-lot.md)
  and [`java-aqs`](./java-aqs.md) pages).

> [!NOTE]
> The Trio clone is a single-commit checkout; no history is cited. The I/O
> manager files were not read beyond their names, and `to_thread`'s thread
> cache (`start_thread_soon`) was not read.

<!-- References -->

[trio-repo]: https://github.com/python-trio/trio/tree/96914fbd8c09013259c836a55d9617c7108b1a56
[pl]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/src/trio/_core/_parking_lot.py
[pl-comment]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/src/trio/_core/_parking_lot.py#L1-L71
[pl-class]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/src/trio/_core/_parking_lot.py#L136-L317
[pl-park]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/src/trio/_core/_parking_lot.py#L168-L190
[pl-unpark]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/src/trio/_core/_parking_lot.py#L205-L219
[pl-repark]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/src/trio/_core/_parking_lot.py#L226-L268
[pl-break]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/src/trio/_core/_parking_lot.py#L279-L306
[sync]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/src/trio/_sync.py
[event]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/src/trio/_sync.py#L60-L120
[cl-wake]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/src/trio/_sync.py#L291-L294
[cl-acquire]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/src/trio/_sync.py#L358-L384
[sem-invariant]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/src/trio/_sync.py#L479-L484
[sem-release]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/src/trio/_sync.py#L531-L547
[lock]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/src/trio/_sync.py#L580-L661
[lock-release]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/src/trio/_sync.py#L645-L661
[strict-fifo]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/src/trio/_sync.py#L697-L758
[condition]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/src/trio/_sync.py#L832-L892
[traps]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/src/trio/_core/_traps.py
[traps-wtr]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/src/trio/_core/_traps.py#L115-L160
[run]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/src/trio/_core/_run.py
[run-reschedule]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/src/trio/_core/_run.py#L1898-L1931
[entry]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/src/trio/_core/_entry_queue.py
[entry-task]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/src/trio/_core/_entry_queue.py#L87-L103
[entry-submit]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/src/trio/_core/_entry_queue.py#L130-L148
[token]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/src/trio/_core/_entry_queue.py#L174-L223
[wakeup]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/src/trio/_core/_wakeup_socketpair.py
[wakeup-sock]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/src/trio/_core/_wakeup_socketpair.py#L21-L50
[threads]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/src/trio/_threads.py
[to-thread-cancel]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/src/trio/_threads.py#L303-L325
[to-thread]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/src/trio/_threads.py#L415-L445
[send-to-trio]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/src/trio/_threads.py#L498-L528
[ref-core]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/docs/source/reference-core.rst
[ref-thread-safety]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/docs/source/reference-core.rst#L199-L207
[ref-fairness]: https://github.com/python-trio/trio/blob/96914fbd8c09013259c836a55d9617c7108b1a56/docs/source/reference-core.rst#L1156-L1196
[webkit-blog]: https://webkit.org/blog/6161/locking-in-webkit/
[pl-rust-docs]: https://amanieu.github.io/parking_lot/
[aqs-paper]: https://gee.cs.oswego.edu/dl/papers/aqs.pdf
