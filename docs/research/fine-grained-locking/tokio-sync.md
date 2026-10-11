# Tokio `tokio::sync` (Rust)

The async synchronization module of the dominant Rust runtime: one strictly
FIFO counting semaphore with an intrusive waiter list (the `Mutex` is that
semaphore with one permit, the `RwLock` the same semaphore with
`MAX_READS` permits), a `Notify` that stores at most one permit, and
version-counted `watch` channels — all runtime-agnostic, because a waiter is
nothing but a `Waker`, and a blocked _thread_ is just a `Waker` that unparks it.

|                        |                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**               | library (async runtime, `tokio::sync` module)                                                                                                                                                                                                                                                                                                                                                                                                         |
| **Language**           | Rust                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| **License**            | MIT                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| **Repository**         | [`tokio-rs/tokio`][tokio-repo] at `32312ae0d6f0` (2026-05-26), crate version `1.52.3`                                                                                                                                                                                                                                                                                                                                                                 |
| **Primitives covered** | `batch_semaphore::Semaphore` (behind `Semaphore`, `Mutex`, `RwLock`), `Notify`, `watch`, `oneshot`, `broadcast`; the thread parkers that `blocking_*` methods and the scheduler use                                                                                                                                                                                                                                                                   |
| **Parking substrate**  | an intrusive doubly-linked list of `Waiter` nodes that live **inside the pending future**, guarded by a `std::sync::Mutex` (or `parking_lot::Mutex` with the `parking_lot` feature); the wake is `Waker::wake`                                                                                                                                                                                                                                        |
| **Fairness**           | strict FIFO with direct permit handoff: permits sit in the counter only when the queue is empty, so a newcomer cannot barge                                                                                                                                                                                                                                                                                                                           |
| **Source read**        | [`sync/batch_semaphore.rs`][bs], [`sync/mutex.rs`][mutex], [`sync/notify.rs`][notify], [`sync/rwlock.rs`][rwlock], [`sync/watch.rs`][watch], [`sync/oneshot.rs`][oneshot], [`sync/broadcast.rs`][broadcast], [`sync/mod.rs`][sync-mod], [`util/linked_list.rs`][ll], [`util/wake_list.rs`][wakelist], [`runtime/park.rs`][park], [`runtime/scheduler/multi_thread/park.rs`][mt-park], [`future/block_on.rs`][block-on], [`loom/std/mod.rs`][loom-std] |

## Overview

### What it solves

Tokio tasks are futures polled by a work-stealing scheduler; a task that must
wait returns `Poll::Pending` and leaves a `Waker` behind. `tokio::sync` gives
those tasks locks, semaphores and channels that wait by returning `Pending`
instead of blocking the worker thread. The module declares itself
executor-independent ([`sync/mod.rs` L438–L450][sync-compat]):

> All synchronization primitives provided in this module are runtime agnostic.
> You can freely move them between different instances of the Tokio runtime
> or even use them from non-Tokio runtimes.
>
> When used in a Tokio runtime, the synchronization primitives participate in
> cooperative scheduling to avoid starvation. This feature does not apply when
> used from non-Tokio runtimes.

The `Mutex` documentation then argues, at length, that the async mutex is
usually the wrong tool — the clearest statement in this catalog of when a
loop-resident task should take a _thread_ lock ([`mutex.rs` L24–L50][mutex-which]):

> # Which kind of mutex should you use?
>
> Contrary to popular belief, it is ok and often preferred to use the ordinary
> `Mutex` from the standard library in asynchronous code.
>
> The feature that the async mutex offers over the blocking mutex is the
> ability to keep it locked across an `.await` point. This makes the async
> mutex more expensive than the blocking mutex, so the blocking mutex should
> be preferred in the cases where it can be used. The primary use case for the
> async mutex is to provide shared mutable access to IO resources such as a
> database connection. If the value behind the mutex is just data, it's
> usually appropriate to use a blocking mutex such as the one in the standard
> library or `parking_lot`.
>
> Note that, although the compiler will not prevent the std `Mutex` from holding
> its guard across `.await` points in situations where the task is not movable
> between threads, this virtually never leads to correct concurrent code in
> practice as it can easily lead to deadlocks.
>
> A common pattern is to wrap the `Arc<Mutex<...>>` in a struct that provides
> non-async methods for performing operations on the data within, and only
> lock the mutex inside these methods. […]
>
> Additionally, when you _do_ want shared access to an IO resource, it is
> often better to spawn a task to manage the IO resource, and to use message
> passing to communicate with that task.

### Design philosophy

**One semaphore underlies the locks.** `Mutex` is `semaphore::Semaphore::new(1)`
plus an `UnsafeCell<T>` ([`mutex.rs` L133–L138][mutex-struct]); `RwLock` is a
semaphore of `MAX_READS` permits where a reader takes one and a writer takes
all of them ([`rwlock.rs` L783][rwlock-write]). Fairness is therefore decided
in one place, and the module header says why it is FIFO
([`batch_semaphore.rs` L1–L17][bs-doc]):

> Because waiters are enqueued at the back of the linked list and dequeued
> from the front, the semaphore is fair. Tasks trying to acquire large numbers
> of permits at a time will always be woken eventually, even if many other
> tasks are acquiring smaller numbers of permits. This means that in a
> use-case like tokio's read-write lock, writers will not be starved by
> readers.

**A waiter is a `Waker`, not a thread.** Nothing in `tokio::sync` names an OS
primitive. A pending operation registers `cx.waker().clone()`; whoever releases
calls `wake()`. A synchronous caller supplies a `Waker` that unparks its own
thread (see [Async and fiber integration](#async-and-fiber-integration)), so the
same queue serves tasks and threads.

## How it works

`Semaphore` holds an `AtomicUsize` of permits shifted left by one, whose low
bit is `CLOSED`, and a `Mutex<Waitlist>` — an intrusive `LinkedList<Waiter>`
plus a `closed` flag ([L35–L46][bs-struct], [L123–L135][bs-const]). A
`Waiter` holds `state: AtomicUsize` (permits still needed),
`waker: UnsafeCell<Option<Waker>>`, the list `pointers` and a
`PhantomPinned`, and is embedded in the `Acquire` future itself ([L71–L112][bs-waiter]).

`poll_acquire` ([L397–L522][bs-poll]):

1. Load `permits`; if enough, CAS them away and return `Ready` — no lock.
2. If not enough, **take the list lock before the CAS** that drains the
   counter, so a concurrent release cannot slip permits in unseen
   ([L434–L443][bs-lock-first]):

   > No permits were immediately available, so this permit will (probably)
   > need to wait. We'll need to acquire a lock on the wait queue before
   > continuing. We need to do this _before_ the CAS that sets the new value
   > of the semaphore's `permits` counter. Otherwise, if we subtract the
   > permits and then acquire the lock, we might miss additional permits
   > being added while waiting for the lock.

3. Take whatever permits exist (possibly fewer than requested), credit them to
   the node with `assign_permits`, store the waker (skipping the clone when
   `will_wake` says it is unchanged), and `push_front` the node.

`release(n)` always locks the list and runs `add_permits_locked`
([L306–L370][bs-add]): starting at the **back** (oldest) node it assigns
permits; a node whose `state` reaches zero is popped and its waker moved into a
`WakeList`, a fixed array of 32 wakers ([`wake_list.rs` L5][wakelist]). Only
when the queue empties are leftover permits `fetch_add`ed to the counter. The
lock is dropped before `wakers.wake_all()`, and re-taken if more than 32
waiters must be served.

`Notify` ([`notify.rs` L202–L215][notify-struct]) packs a 2-bit state
(`EMPTY`, `WAITING`, `NOTIFIED`) with a count of `notify_waiters` calls in the
upper bits, beside a `Mutex<WaitList>`. "A `Notify` can be thought of as a
`Semaphore` starting with 0 permits" whose `notify_one` "sets a permit **if
there currently are no available permits**" ([L26–L49][notify-doc]).
`notify_one` CASes `EMPTY`/`NOTIFIED` → `NOTIFIED` without the lock and locks
only when the state is `WAITING` ([L677–L709][notify-one]); it then pops the
oldest waiter, `store_release`s a per-waiter `notification` (`One(Fifo)`,
`One(Lifo)` for `notify_last`, or `All`) and wakes it after unlocking
([L844–L897][notify-locked]). `notify_waiters` bumps the call counter, moves
the whole list behind a pinned guard node into a `GuardedLinkedList`, and wakes
it in batches of 32, re-locking between batches so each waiter can still
unlink itself ([L747–L818][notify-waiters]).

`watch` keeps a version (`state`, step 2, low bit `CLOSED`) and a `BigNotify`
of eight `Notify`s chosen at random per receiver "to avoid contention on the
lock inside the `Notify`" ([`watch.rs` L372–L433][watch-big]); `changed()`
"first request[s] a notification, **then** check[s] the current value's
version" ([L983–L1000][watch-changed]). `oneshot` has no list at all: two
`Waker` slots (`tx_task`, `rx_task`) gated by `RX_TASK_SET`/`TX_TASK_SET`
bits in one `AtomicUsize` ([`oneshot.rs` L386–L410][oneshot-inner],
[L1486–L1503][oneshot-bits]). `broadcast` keeps a ring of slots and a
`Mutex<Tail>` whose `waiters` field is another intrusive list
([`broadcast.rs` L362–L409][broadcast-tail]).

## Analysis

### State word and fast path

- **Semaphore / `Mutex`:** one `usize` = `permits << 1 | CLOSED`. Uncontended
  `lock` is `load(Acquire)` + `compare_exchange(curr, curr - 2, AcqRel,
Acquire)` ([`try_acquire` L266–L295][bs-try]); `try_lock` is the same CAS.
  Unlock is **not** a single atomic: `MutexGuard::drop` calls
  `release(1)` ([`mutex.rs` L964–L967][mutex-drop]), and `release` always
  takes the list mutex, even with no waiters ([L231–L238][bs-release]). An
  uncontended lock/unlock pair therefore costs one CAS plus an OS-mutex
  lock/unlock — the price of keeping "counter non-zero ⇒ queue empty" true
  under one lock.
- **`Notify`:** `notify_one` with no waiter is one CAS; `notified().await`
  with a stored permit is one CAS (`NOTIFIED` → `EMPTY`).
- **`MAX_PERMITS = usize::MAX >> 3`**: three flag bits are reserved, one used
  ([L123–L135][bs-const]).

### Waiting: spin, yield, park

No primitive spins. A task that cannot proceed returns `Pending`; there is no
"try a few times" loop because the next thing the worker does is run another
task. Two scheduler-level policies stand in for spinning:

- **Cooperative budget.** Each `Acquire::poll` first calls
  `coop::poll_proceed(cx)` ([L590–L598][bs-coop]); a task gets
  `Budget(Some(128))` operations per scheduling quantum
  ([`task/coop/mod.rs` L116][coop]) and is forced to yield when it runs out, even
  if the lock was free. This is the "participate in cooperative scheduling"
  clause above, and it is lost on non-Tokio executors.
- **Worker parking.** An idle worker parks in one of two ways
  ([`multi_thread/park.rs` L44–L48][mt-states]): `PARKED_DRIVER` (it owns the
  I/O driver and blocks in the OS poller) or `PARKED_CONDVAR` (another worker
  has the driver; it blocks on a `Condvar`). The thread is never parked _on
  the lock_ — only on "no runnable task".

### The parking substrate

Task waiters live in **intrusive list nodes embedded in the pinned future**
(`Acquire`, `Notified`), so a wait allocates nothing; the node is `!Unpin` so
its address is stable while linked ([`util/linked_list.rs`][ll]). The record a
waker holds is the task's `Waker` (a vtable pointer plus data pointer). There
is no global hashed table: every primitive owns its list. The list is
protected by a real thread mutex — `std::sync::Mutex`, wrapped to ignore
poisoning ([`loom/std/mutex.rs`][loom-mutex]), or `parking_lot::Mutex` when the
`parking_lot` feature is on and not under Miri ([`loom/std/mod.rs`
L54–L69][loom-std]). Contention on that _list_ lock blocks OS threads in the
kernel, which is why every release wakes outside it and why `watch` shards its
`Notify` eight ways.

Wakeups are batched: `add_permits_locked` and `notify_waiters` collect up to
32 wakers, unlock, wake, and loop ([`wake_list.rs`][wakelist]). A panic in one
waker leaves the rest unlinked by `NotifyWaitersList::drop`, which marks them
notified without waking ([`notify.rs` L363–L376][notify-guard-drop]).

### Fairness, handoff and starvation

**Strict FIFO with permit handoff.** `add_permits_locked` credits permits to
the oldest waiter before the counter sees them, so a free permit in the
counter implies an empty queue, and a newcomer's fast-path CAS cannot
overtake a sleeper ([barging](./concepts.md#barging-and-handoff) is
structurally impossible). The `Mutex` doc states the consequence: "the order
in which tasks call the `lock` method is the exact order in which they will
acquire the lock" ([`mutex.rs` L20–L22][mutex-which]). Large requests cannot
starve: a waiter needing 5 permits accumulates partial assignments in
`state` while blocking everyone behind it. The cost is the classic
[convoy](./concepts.md#convoys): the lock is owned by a task that has not been
polled yet, so the releasing task, if it wants the lock again, queues behind a
task that may sit in a run queue for a whole scheduling round. Tokio's answer
is the doc quoted above — don't hold async locks for data. Contrast
[`async-lock`](./smol-event-listener.md#fairness-handoff-and-starvation), which
barges until a waiter has starved for 0.5 ms, and
[`parking_lot`](./parking-lot.md#fairness-handoff-and-starvation).

`RwLock` inherits the queue: "a read lock will not be given out until all
write lock requests that were queued before it have been acquired and
released" ([`rwlock.rs` L41–L48][rwlock-fair]). `Notify` offers both orders:
`notify_one` wakes the oldest (`pop_back`), `notify_last` the newest
(`pop_front`).

**Cancellation is safe for permits, not for position.** Dropping a pending
future is cancellation in Rust, and every primitive's `Drop` repairs the queue
under the list lock:

- `Acquire::drop` unlinks its node and returns any permits already credited to
  it through `add_permits_locked` — i.e. straight to the next waiter
  ([L686–L709][bs-drop]). No permit is lost; the canceller loses its place,
  which every acquire method documents under "Cancel safety": "Cancelling a
  call to `lock` makes you lose your place in the queue" ([`mutex.rs`
  L415–L419][mutex-cancel]).
- `Notified::drop` unlinks the waiter and, **if it had already been chosen by
  `notify_one`/`notify_last` but not yet polled**, re-runs `notify_locked` with
  the same strategy so the notification passes to the next waiter or becomes
  the stored permit ([`notify.rs` L1332–L1375][notify-drop]). A
  `notify_waiters` notification is not forwarded — it was meant for everyone.

### Condition variables and predicates

`tokio::sync` has **no condition variable**. `Notify` is the substitute, and
its documentation spells out the lost-wakeup race that a condvar's
mutex-coupled wait prevents: with two `recv`ers and two `send`ers, "The
`notify_one` method is called twice, adding only a single permit to the
`Notify`. […] One of them consumes the permit, and the other sleeps forever"
([L119–L135][notify-doc-mpmc]). The fix is `Notified::enable()`, which
inserts the waiter without a `Waker` _before_ re-checking the predicate
([L1006][notify-enable]) — the futex rule "register, then re-check, then
sleep" moved into a future. `notify_waiters` gets the same effect differently:
`notified()` snapshots the call counter at creation, so a broadcast that
happens between creation and first poll still completes the future
([L565–L575][notify-notified], [L1118–L1131][notify-poll-init]). `watch` is a
sequence counter plus that same "notification first, version check second"
order. There are no predicate waits; callers loop.

### Footprint and layout

- `Semaphore`: the list mutex (on Linux std: a 4-byte futex word and a
  poison byte), list `head`/`tail` (16 bytes), `closed`, and the `permits`
  word — about 40 bytes on a 64-bit target by field arithmetic (not measured);
  `Mutex<T>` adds only `T`.
- `Waiter` (per pending acquire, inside the future): `state` (8), `Option<Waker>`
  (16), two link pointers (16). No heap allocation per wait; cloning the
  `Waker` may touch a refcount.
- `Notify`: one `AtomicUsize` plus a `Mutex<LinkedList>`; `watch` multiplies
  that by eight to spread list-lock contention.
- Nothing is cache-line padded.

### Portability

Pure Rust over `std` atomics and `std::sync::Mutex`; the OS-specific part is
only what `std` (or `parking_lot`) uses for the list lock and what the
runtime's driver uses to sleep. Everything is also built under `loom` for
model checking (`crate::loom::*` indirection). `blocking_*` methods are
unavailable on targets without threads (`#[cfg(not(target_family = "wasm"))]`
in the doc examples).

### Async and fiber integration

This is the whole subject: a waiter is a `Waker`, and crossing from a thread
to the event loop is just calling `wake()` from that thread.

**Thread → loop.** `release()` from any thread pops a waiter and calls its
`Waker`. For a Tokio task that pushes the task onto a run queue and, if a
worker is parked, calls `Unparker::unpark`, which swaps the parker state to
`NOTIFIED` and dispatches on what it found ([`multi_thread/park.rs`
L277–L290][mt-unpark]):

```rust
match self.state.swap(NOTIFIED, SeqCst) {
    EMPTY => {}    // no one was waiting
    NOTIFIED => {} // already unparked
    PARKED_CONDVAR => self.unpark_condvar(),
    PARKED_DRIVER => driver.unpark(),
    actual => panic!("inconsistent state in unpark; actual = {actual}"),
}
```

`driver.unpark()` ends in the I/O driver's `self.waker.wake()`
([`runtime/io/driver.rs` L258–L261][io-unpark]), a `mio::Waker` (an `eventfd`
or pipe registered with the poller; `mio` was not read). The swap-to-`NOTIFIED`
on every unpark is deliberate: "we must write `NOTIFIED` even if `state` is
already `NOTIFIED`. That is why this must be a swap rather than a
compare-and-swap" — the release write is what the parked side acquires.

**Loop → thread, and threads waiting on async primitives.** `blocking_lock`
is literally `crate::future::block_on(self.lock())` ([`mutex.rs`
L468–L522][mutex-blocking]); `block_on` polls the future with a `Waker` built
from the calling thread's `ParkThread` and parks between polls
([`runtime/park.rs`][park]). That parker is a three-state word
(`EMPTY`/`PARKED`/`NOTIFIED`) over a `std::sync::Mutex<()>` and `Condvar`
([L21–L29][park-states], [L77–L215][park-impl]) — not a futex wait on the
word itself. So the duality costs nothing in the primitive: the same FIFO
queue holds task wakers and thread wakers, and a thread waiter is served in
order like any task. The one rule is enforced at runtime: calling a
`blocking_*` method on a runtime thread panics ("Cannot block the current
thread from within a runtime", [`future/block_on.rs` L1–L21][block-on]); the
doc points callers at `spawn_blocking` or `block_in_place`.

**Bearing on a `WaitWord`.** Tokio's design shows a registry where (1) waiter
records are owned by the waiting future and linked intrusively, (2) the
registry lock is held only to link, unlink and pop, (3) wakers run outside it
in bounded batches, and (4) the waker abstraction makes "fiber on a loop" and
"thread" interchangeable. What it does _not_ give is a wait on an arbitrary
address: every primitive owns its list, and the list lock is a full OS mutex
even when uncontended. The closest one-word prior art for thread-or-fiber
waiting remains folly's [`fibers::Baton`](./folly-sync.md#async-and-fiber-integration).

## Strengths

- **One fairness policy, stated and enforced structurally**: permits never
  reach the counter while someone waits, so FIFO needs no flag or timer.
- **Cancellation never leaks a permit or a `notify_one`**; the repair code is
  in `Drop`, under the same lock as the queue.
- **Zero allocation per wait**; waiter nodes ride in the future.
- **Wakes outside the lock in batches of 32**; a panicking waker cannot
  corrupt the list.
- **Executor-agnostic** and **thread-usable**: any `Waker` works, including a
  thread parker.
- The documentation is unusually honest about when _not_ to use it.

## Weaknesses

- **Every release takes an OS mutex**, even uncontended; the async `Mutex` is
  a semaphore plus a `std::sync::Mutex`, strictly more expensive than the
  thread lock it is compared against.
- **FIFO handoff convoys**: the lock passes to a task that may not run for a
  scheduling round; no barging option exists.
- **No condition variable**, no predicate waits; `Notify` stores one permit
  and requires the `enable()` idiom for multi-consumer use.
- **Lost position on cancellation** is inherent to the drop-based design.
- Thread waiters sleep on a `Mutex` + `Condvar` parker, not on the word.

## Key design decisions and trade-offs

| Decision                                                       | Rationale                                                                                                 | Trade-off                                                                      |
| -------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `Mutex` and `RwLock` are a counting semaphore                  | one place for fairness; writers take all `MAX_READS` permits, so "writers will not be starved by readers" | release always locks the waiter list                                           |
| Strict FIFO, permits handed to the oldest waiter               | "the order in which tasks call the `lock` method is the exact order in which they will acquire the lock"  | convoys; the lock is held by a not-yet-polled task                             |
| Lock the list _before_ the CAS that empties the counter        | otherwise a concurrent release is missed                                                                  | contended acquires serialize on the list mutex                                 |
| Waiter node embedded in the pinned future                      | no allocation per wait; `Drop` is the cancellation hook                                                   | `!Unpin` futures; `unsafe` intrusive list                                      |
| `Drop` returns credited permits / forwards a `notify_one`      | cancellation must not lose a wakeup                                                                       | the canceller loses its place                                                  |
| Waiter = `Waker`; `blocking_lock` = `block_on(lock())`         | one queue for tasks and threads; runtime-agnostic                                                         | thread waiters park on `Mutex`+`Condvar`; panics if called on a runtime thread |
| `Notify` stores at most one permit; `enable()` registers early | `thread::park`/`unpark` semantics, no counter overflow                                                    | callers must know the `enable()` idiom for MPMC                                |
| Wake outside the lock, 32 at a time                            | waker code may be arbitrary; bounded critical section                                                     | `notify_waiters` needs a guarded list so waiters can unlink mid-broadcast      |

## Sources

- `tokio-rs/tokio` at [`32312ae0d6f0`][tokio-repo]: the files in the metadata
  table; `tokio/src/runtime/io/driver.rs` and `runtime/context/blocking.rs` for
  the wake and `block_on` paths.
- The `tokio::sync` module and `Mutex` documentation are the rustdoc comments
  of [`sync/mod.rs`][sync-mod] and [`sync/mutex.rs`][mutex]; quotes above are
  taken from the source, not the rendered site.

> [!NOTE]
> The tokio clone is a single-commit checkout, so no history is cited. Byte
> sizes are field arithmetic for 64-bit Linux with the default (`std`) list
> mutex; no `size_of` was measured. `mio`'s `Waker` implementation was not
> read.

<!-- References -->

[tokio-repo]: https://github.com/tokio-rs/tokio/tree/32312ae0d6f0b1c6457f1323e3e7f568f448d0db
[bs]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/batch_semaphore.rs
[bs-doc]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/batch_semaphore.rs#L1-L17
[bs-struct]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/batch_semaphore.rs#L35-L46
[bs-waiter]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/batch_semaphore.rs#L71-L112
[bs-const]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/batch_semaphore.rs#L123-L135
[bs-release]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/batch_semaphore.rs#L231-L238
[bs-try]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/batch_semaphore.rs#L266-L295
[bs-add]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/batch_semaphore.rs#L306-L370
[bs-poll]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/batch_semaphore.rs#L397-L522
[bs-lock-first]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/batch_semaphore.rs#L434-L443
[bs-coop]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/batch_semaphore.rs#L590-L598
[bs-drop]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/batch_semaphore.rs#L686-L709
[mutex]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/mutex.rs
[mutex-which]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/mutex.rs#L14-L54
[mutex-struct]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/mutex.rs#L133-L138
[mutex-cancel]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/mutex.rs#L415-L419
[mutex-blocking]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/mutex.rs#L468-L522
[mutex-drop]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/mutex.rs#L964-L967
[notify]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/notify.rs
[notify-doc]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/notify.rs#L26-L49
[notify-doc-mpmc]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/notify.rs#L119-L135
[notify-struct]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/notify.rs#L202-L215
[notify-guard-drop]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/notify.rs#L363-L376
[notify-notified]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/notify.rs#L565-L575
[notify-one]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/notify.rs#L677-L709
[notify-waiters]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/notify.rs#L747-L818
[notify-locked]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/notify.rs#L844-L897
[notify-enable]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/notify.rs#L1006
[notify-poll-init]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/notify.rs#L1118-L1131
[notify-drop]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/notify.rs#L1332-L1375
[rwlock]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/rwlock.rs
[rwlock-fair]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/rwlock.rs#L41-L48
[rwlock-write]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/rwlock.rs#L783
[watch]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/watch.rs
[watch-big]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/watch.rs#L372-L433
[watch-changed]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/watch.rs#L983-L1000
[oneshot]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/oneshot.rs
[oneshot-inner]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/oneshot.rs#L386-L410
[oneshot-bits]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/oneshot.rs#L1486-L1503
[broadcast]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/broadcast.rs
[broadcast-tail]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/broadcast.rs#L362-L409
[sync-mod]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/mod.rs
[sync-compat]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/sync/mod.rs#L438-L450
[ll]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/util/linked_list.rs
[wakelist]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/util/wake_list.rs#L5
[coop]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/task/coop/mod.rs#L116
[park]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/runtime/park.rs
[park-states]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/runtime/park.rs#L21-L29
[park-impl]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/runtime/park.rs#L77-L215
[mt-park]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/runtime/scheduler/multi_thread/park.rs
[mt-states]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/runtime/scheduler/multi_thread/park.rs#L44-L48
[mt-unpark]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/runtime/scheduler/multi_thread/park.rs#L277-L290
[io-unpark]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/runtime/io/driver.rs#L258-L261
[block-on]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/future/block_on.rs#L1-L21
[loom-std]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/loom/std/mod.rs#L54-L69
[loom-mutex]: https://github.com/tokio-rs/tokio/blob/32312ae0d6f0b1c6457f1323e3e7f568f448d0db/tokio/src/loom/std/mutex.rs
