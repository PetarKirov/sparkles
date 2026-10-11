# smol `event-listener` and `async-lock` (Rust)

The smol ecosystem's answer to "one primitive for tasks and threads": an
`Event` that is a Vyukov-style eventcount — a FIFO intrusive list of
listeners, each of which may be woken by a task `Waker` **or** a thread
`Unparker` — and `async-lock`, which builds `Mutex`, `RwLock`, `Semaphore`,
`Barrier` and `OnceCell` as a plain atomic state word plus one or more
`Event`s, so every lock has both `.await` and `_blocking` entry points over the
same queue.

|                        |                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**               | libraries (`event-listener` 5.4.2, `async-lock` 3.4.2, plus their helpers `event-listener-strategy` and `parking`)                                                                                                                                                                                                                                                                                                                                    |
| **Language**           | Rust (`no_std` + `alloc` capable)                                                                                                                                                                                                                                                                                                                                                                                                                     |
| **License**            | Apache-2.0 OR MIT                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| **Repository**         | [`smol-rs/event-listener`][el-repo] at `77004ac77dce` (2026-07-27); [`smol-rs/async-lock`][al-repo] at `23e181d5cfb9` (2026-06-27); [`smol-rs/event-listener-strategy`][els-repo] at `be0f536e7a18`; [`smol-rs/parking`][pk-repo] at `cedb1884e050`                                                                                                                                                                                                   |
| **Primitives covered** | `Event`, `EventListener`, `listener!`, `Notification` (`notify`, `additional`, `relaxed`, tags); `async_lock::{Mutex, RwLock, Semaphore, Barrier, OnceCell}`; `Strategy` (`Blocking`, `NonBlocking`); `parking::Parker`                                                                                                                                                                                                                               |
| **Parking substrate**  | a per-`Event` intrusive doubly-linked list of listener links under a `std::sync::Mutex` (or a `critical-section` cell, or a spinlock without either); each link holds a `Task` = `Waker` \| `Unparker`; threads park on `parking::Parker` (`Mutex<()>` + `Condvar` + 3-state word)                                                                                                                                                                    |
| **Fairness**           | `Event`: FIFO notification; `Mutex`: barging with eventual fairness after 500 µs of starvation; `Semaphore`: barging; `RwLock`: write-preferring                                                                                                                                                                                                                                                                                                      |
| **Source read**        | `event-listener`: [`src/lib.rs`][el-lib], [`src/intrusive.rs`][el-intr], [`src/notify.rs`][el-notify], [`examples/mutex.rs`][el-ex-mutex]; `async-lock`: [`src/lib.rs`][al-lib], [`src/mutex.rs`][al-mutex], [`src/semaphore.rs`][al-sem], [`src/rwlock/raw.rs`][al-rw-raw], [`src/rwlock.rs`][al-rw], [`src/once_cell.rs`][al-once], [`src/barrier.rs`][al-barrier]; [`event-listener-strategy/src/lib.rs`][els-lib]; [`parking/src/lib.rs`][pk-lib] |

## Overview

### What it solves

`event-listener` exists to turn any non-blocking data structure into a
blocking _and_ an async one with the same code. The crate opens
([`lib.rs` L1–L10][el-doc]):

> Notify async tasks or threads.
>
> This is a synchronization primitive similar to eventcounts invented by
> Dmitry Vyukov.
>
> You can use this crate to turn non-blocking data structures into async or
> blocking data structures. See a simple mutex implementation that exposes an
> async and a blocking interface for acquiring locks.

The pattern is the eventcount loop: check the condition, `listen()`, check
again, then wait — `.await` in a task or `.wait()` on a thread
([`lib.rs` L44–L61][el-doc-loop]). `Event` itself states its contract
([L155–L173][el-event-doc]):

> If there are no active listeners at the time a notification is sent, it
> simply gets lost. […]
>
> If a notified listener is dropped without receiving a notification, dropping
> will notify another active listener. Whether one _additional_ listener will
> be notified depends on what kind of notification was delivered.
>
> Listeners are registered and notified in the first-in first-out fashion,
> ensuring fairness.

### Design philosophy

**Separate the state from the wait queue.** `async-lock` keeps each lock's
state in its own `AtomicUsize` and uses `Event` only as a wait queue that
carries no data. The uncontended paths never touch the `Event`'s list; the
contended paths are the eventcount loop. That makes `event-listener` the
"base" of `async-lock` (and of `async-channel`, `async-io`, … in the smol
stack): one audited wait-queue implementation, many lock-free state machines
on top.

**Threads and tasks are peers.** A listener records whichever waker its
current waiter has. `async-lock`'s own crate docs then tell users not to reach
for it unless they must ([`async-lock` `lib.rs` L11–L30][al-doc]):

> In general, you should consider using `std::sync` types over types from this
> crate.
>
> There are two primary use cases for types from this crate:
>
> - You need to use a synchronization primitive in a `no_std` environment.
> - You need to hold a lock across an `.await` point. […]
>
> In contrast, `async-lock`'s notification system uses `std::sync::Mutex`
> under the hood if the `std` feature is enabled, and will fall back to a
> significantly slower strategy if it is not. So, there are few cases where
> `async-lock` is a win for performance over `std::sync`.

## How it works

**`Event`** is a single `AtomicPtr<Inner<T>>`, null until first use, then a
leaked `Arc<Inner>` installed by CAS ([`lib.rs` L174–L181][el-event-struct],
[`inner()` L469–L500][el-inner-init]). `Inner` holds an `AtomicUsize
notified` and the list ([L131–L144][el-inner]). The list
([`intrusive.rs` L21–L48][el-list]) is `{ head, tail, next, len, notified }`,
where `next` points at the **first unnotified** listener — the boundary that
makes `notify(n)` and `notify_additional(n)` cheap to distinguish.

- `listen()` heap-allocates an `InnerListener` (`Box::pin`) holding an `Arc`
  to the `Inner` and a `Link { state: Cell<State>, prev, next }`, and links it
  at the tail under the list lock ([`lib.rs` L305–L318][el-listen],
  [`intrusive.rs` L180–L212][el-insert]). The `listener!` macro does the same
  with a pinned `StackSlot`, avoiding the allocation ([`lib.rs`
  L1043–L1051][el-listener-macro]).
- A link's `State` is `Created`, `Task(Task)`, `Notified { additional, tag }`
  or `NotifiedTaken` ([L1207–L1222][el-state]); `Task` is `Waker(Waker)` or
  `Unparker(parking::Unparker)` ([L1287–L1313][el-task]).
- `notify(n)` runs the notification's fence, then locks the list and walks from
  `next`: for a plain notification it first subtracts the already-notified
  count — "notifies _at least_ the specified number of listeners" — while
  `additional` always notifies `n` more ([`intrusive.rs`
  L347–L387][el-notify-impl]). Each chosen link becomes `Notified` and, if it
  held a `Task`, that task is woken **while the list lock is held**.
- Polling a listener calls `register` under the lock: if `Notified`, it
  removes itself and returns the tag; otherwise it stores the current waker
  (`will_wake` short-circuits a re-store) ([L233–L274][el-register]).

**`async_lock::Mutex`** ([`mutex.rs` L20–L54][al-mutex-struct]) is a
`state: AtomicUsize` — bit 0 = locked, the remaining bits count starving
waiters (in units of 2) — and `lock_ops: Event`. `try_lock` is
`compare_exchange(0, 1, Acquire, Acquire)` ([L164][al-try-lock]); unlock is
`fetch_sub(1, Release)` followed by `lock_ops.notify(1)`
([L203–L207][al-unlock]). The slow path `AcquireSlow` is described under
[fairness](#fairness-handoff-and-starvation). `Semaphore` is `count:
AtomicUsize` + `event`; acquire loops `try_acquire` / `listen` / wait, release
is `fetch_add(1)` + `notify(1)` ([`semaphore.rs` L289–L310][al-sem-poll],
[L381–L385][al-sem-drop]). `RwLock` is a `Mutex<()>` that writers hold, a
state word (`WRITER_BIT` = 1, readers in units of 2) and two `Event`s,
`no_readers` and `no_writer` ([`rwlock/raw.rs` L22–L48][al-rw-struct]).
`OnceCell` is a 3-state word plus `active_initializers` and `passive_waiters`
events ([`once_cell.rs` L89–L105][al-once-struct]); `Barrier` is a
`Mutex<State { count, generation_id }>` plus an `Event`.

Every future is written once as an `EventListenerFuture` with
`poll_with_strategy`; `Strategy::NonBlocking` polls the listener with the
task's `Context`, `Strategy::Blocking` calls `listener.wait()`
([`event-listener-strategy` L453–L525][els-strategies]). `lock_blocking()` is
`self.lock().wait()` ([`mutex.rs` L143][al-lock-blocking]);
`acquire_blocking()`, `read_blocking()`, `wait_blocking()` likewise.

## Analysis

### State word and fast path

- **`Mutex`:** one `usize`. Lock: `CAS(0 → 1, Acquire)`. Unlock:
  `fetch_sub(1, Release)` then `Event::notify(1)`. `notify` is not guarded by
  a waiter check: at this SHA it runs `full_fence()` (on x86 a `lock not` on a
  stack word, cheaper than `mfence`, [`notify.rs` L579–L610][el-fence]),
  allocates the `Event`'s `Inner` on first use, and takes the list mutex
  ([`lib.rs` L448–L456][el-notify-fn], [`intrusive.rs`
  L223–L227][el-notify-cold]). The `notified` atomic the list maintains
  (`update_notified`, [L390–L399][el-update-notified]) is read only by
  `is_notified()`. So an uncontended unlock costs a fence plus an OS-mutex
  lock/unlock, the same order of cost as tokio's `release` and the reason the
  crate defers to `std::sync`.
- **`Semaphore`:** `count` CAS loop down, `fetch_add` + `notify(1)` up.
- **`RwLock`:** readers CAS `state + 2` while `WRITER_BIT` is clear; the last
  reader's `fetch_sub` notifies `no_readers`; `write_unlock` clears the bit,
  notifies `no_writer`, and unlocks the writer mutex
  ([L240–L276][al-rw-unlock]).

### Waiting: spin, yield, park

No primitive spins on the state word. A task returns `Pending` after
registering its `Waker`. A thread in `wait()` borrows a thread-local
`(Parker, Unparker)` pair, registers the `Unparker`, and parks
([`lib.rs` L1096–L1171][el-wait]). `parking::Parker` is the familiar
`EMPTY`/`PARKED`/`NOTIFIED` word over a `Mutex<()>` and `Condvar`; `unpark`
swaps in `NOTIFIED` unconditionally ("we must write `NOTIFIED` even if
`state` is already `NOTIFIED`") and briefly takes the lock before
`notify_one` so a thread between `PARKED` and `cvar.wait` cannot miss it
([`parking/src/lib.rs` L326–L438][pk-inner]). With neither `std` nor
`critical-section`, the list lock itself is a test-and-test-and-set spinlock
with `spin_loop()` that the crate calls "dangerous to rely on"
([`intrusive.rs` L424–L493][el-spinlock]).

### The parking substrate

Each `Event` owns its queue; there is no global table. Waiter records are the
`Link`s embedded in the listener, which lives either in a `Box` (`listen()`,
one allocation per wait) or on the waiter's stack (`listener!`). Because
`Inner` is reference-counted and each listener holds an `Arc`, a listener may
outlive the borrow of the `Event`. The list is guarded by
`std::sync::Mutex` (poisoning ignored), by `critical_section::Mutex<RefCell<…>>`
when that feature is on (embedded targets), or by the spinlock — three
backends behind one `with_inner` ([`intrusive.rs` L109–L177][el-with-inner]).

> [!NOTE]
> `Inner`'s field comment still says "On `no_std` platforms, this is a more
> traditional `Vec` of listeners, with an atomic queue used as a backup for
> high contention" ([`lib.rs` L138–L143][el-inner]). At this SHA the
> `intrusive.rs` module is the only backend, mounted as `mod sys` by a
> `#[path]` attribute; the comment describes the removed `no_std`
> implementation.

### Fairness, handoff and starvation

**`Event` is FIFO; the locks on top are not.** A notification marks the
oldest unnotified listener, but it hands over no ownership: the woken waiter
must win a CAS on the lock's own state, and a newcomer can take it first.

**`Mutex`: barging with a 500 µs eventual-fairness bound.** The doc: "The
locking mechanism uses eventual fairness to ensure locking will be fair on
average without sacrificing performance. This is done by forcing a fair lock
whenever a lock operation is starved for longer than 0.5 milliseconds"
([`mutex.rs` L20–L24][al-mutex-struct]). `AcquireSlow::poll_with_strategy`
([L520–L628][al-acquire-slow]) runs two loops:

1. **Unfair loop.** Listen, then `CAS(0 → 1)`. A result of `1` means locked
   and nobody starving — keep waiting. A result `> 1` means someone is
   starving: re-`notify(1)` ("we probably received a notification that was
   meant for a starved task") and switch loops. After each wakeup,
   `start.elapsed() > Duration::from_micros(500)` also switches.
2. **Fair loop.** `state.fetch_add(2)` registers the starver. Newcomers'
   `CAS(0 → 1)` now always fails (state ≥ 2), so only starvers compete:
   `CAS(2 → 3)` on first entry, `fetch_or(1)` after a wakeup; a starver that
   sees the lock free but loses the race notifies the next listener "to be
   fair". `take_mutex` (called on success and from `Drop`) subtracts the 2
   ([L501–L512][al-take-mutex]).

The timer needs `std::time::Instant`; on `no_std` or Wasm the 500 µs exit is
compiled out and only the "somebody is starved" path remains. This is
[`parking_lot`](./parking-lot.md#fairness-handoff-and-starvation)'s _eventual
fairness_ idea transplanted to async — which `parking_lot` itself has since
removed at HEAD. Compare tokio's strict FIFO
([`tokio-sync`](./tokio-sync.md#fairness-handoff-and-starvation)).

**`Semaphore`** barges with no bound: a woken waiter whose `try_acquire` loses
re-`listen()`s at the tail ([`semaphore.rs` L289–L310][al-sem-poll]; the
strategy sets the listener to `None` once it fires, [`event-listener-strategy`
L474–L490][els-nonblocking]). **`RwLock`** is "write-preferring, which means
writers are never starved": a writer takes the writer mutex, then
`fetch_or(WRITER_BIT)` stops new readers, and waits on `no_readers`
([`rwlock.rs` L1–L6][al-rw-doc], [`raw.rs` L455–L475][al-rw-write]).

**Cancellation.** Dropping a listener calls `remove(listener, propagate =
true)` ([`lib.rs` L1071–L1079][el-drop]); if the link had been `Notified`, the
list re-notifies one listener with the same `additional` flag and tag
([`intrusive.rs` L326–L340][el-propagate]) — the notification is not lost.
`discard()` is the explicit opt-out ([`lib.rs` L1174–L1181][el-discard]).
`AcquireSlow`'s `PinnedDrop` decrements the starvation count, so a cancelled
starver does not leave newcomers locked out ([`mutex.rs`
L469–L474][al-acquire-drop]). A waiter that _wins_ the CAS and is then dropped
holds a guard whose `Drop` unlocks — permits live in the state word, never in
the queue, so nothing can be stranded there.

### Condition variables and predicates

No condition variable. `Event` _is_ the condition-variable half — a wait queue
without a mutex — and the eventcount loop is how callers express a predicate:
check, `listen()`, re-check, wait. The re-check after `listen()` closes the
lost-wakeup window because registration and `notify` serialize on the list
lock; `Event::listen`'s doc additionally promises "a `SeqCst` fence after
registering a listener" (at this SHA the code relies on the list lock for
it; the only explicit fence is in `notify`), and `notify` issues `full_fence`
before notifying unless the notification is `relaxed()`. Tags (`Event::<T>::with_tag`) let a
notifier pass a value to exactly the listeners it wakes.

### Footprint and layout

- `Event`: one pointer (8 bytes), lazily pointing at an `Arc<Inner>` — two
  refcounts, `notified`, the list mutex, `head`/`tail`/`next`, `len`,
  `notified`.
- `async_lock::Mutex<T>`: `AtomicUsize` + `Event` = 16 bytes + `T`;
  `Semaphore` the same; `RwLock<T>` = `Mutex<()>` + two `Event`s + a state
  word = 40 bytes + `T` (field arithmetic, not measured).
- Per contended wait: one `Box` from `listen()` in every `async-lock` slow path
  (they call `listen()`, not `listener!`), carrying an `Arc` clone and a `Link`
  (state `Cell` with a 16-byte `Waker`, two pointers).

### Portability

`std` (`std::sync::Mutex` list lock, `parking` for threads), `no_std` +
`critical-section`, or `no_std` + spinlock; `portable-atomic` for targets
without native atomics; `loom` for model checking. Blocking waits
(`wait`, `*_blocking`) are compiled out on `target_family = "wasm"`, where no
thread can park. `parking` uses `std` `Mutex`/`Condvar`, so the thread side
inherits the platform's `std` lock (futex on Linux).

### Async and fiber integration

This crate pair is the clearest thread/task duality in the catalog: **one
queue, two kinds of waker, chosen per wait, not per primitive.**

- A link stores `Task::Waker` when polled from a future and `Task::Unparker`
  when `wait()`ed from a thread; `notify` calls `waker.wake()` or
  `unparker.unpark()` accordingly ([`lib.rs` L1287–L1313][el-task]).
  `parking::Unparker` also converts into a `std::task::Waker`
  (`impl Wake for Inner`), so a thread can be woken through the async path
  too.
- `async-lock` writes every acquire as one state machine over a `Strategy`; the
  blocking variant is that machine driven by `listener.wait()`. The examples
  ship a hand-written mutex exposing `lock()` and `lock_async()` in a dozen
  lines over `TryLock` + `Event` ([`examples/mutex.rs`][el-ex-mutex]).
- Crossing from a thread into an event loop is just `notify`: the waker it
  calls belongs to whatever executor polled the listener (smol's `async-io`
  reactor or any other); `event-listener` knows nothing of loops.
- Weak spots for a fiber registry: `notify` wakes under the list lock, so a
  waker that re-enters the same `Event` (or is slow) extends the critical
  section; and `TaskRef::will_wake` returns `false` for two `Unparker`s
  ("TODO: Use unreleased `will_unpark` API"), so a thread re-registers its
  unparker on every spurious return. Folly's
  [`fibers::Baton`](./folly-sync.md#async-and-fiber-integration) solves the
  same duality inside a single word instead of a per-object list.

## Strengths

- **One wait queue serves tasks and threads**, selected per waiter — the model
  a `WaitWord` registry needs.
- **State and queue separated**: lock semantics are a few atomics; all
  parking subtlety lives in one crate.
- **Notifications are never lost to cancellation**: dropped notified
  listeners propagate, with `discard()` as the explicit escape.
- **`notify` vs `notify_additional`** gives both idempotent "make sure n are
  awake" and counting semantics on one list.
- **Bounded starvation in `Mutex`** without giving up barging throughput.
- Runs `no_std`, with `critical-section` for embedded.

## Weaknesses

- **Every `notify` takes the list lock and a full fence** even with no
  listeners; every unlock of an `async_lock::Mutex` therefore costs an OS-mutex
  round trip.
- **Wakers run under the list lock.**
- **A `Box` per contended wait** in `async-lock`.
- **`Semaphore` can starve a waiter**; only `Mutex` has the fairness switch,
  and its timer disappears without `std`.
- Thread waiters park on `Mutex` + `Condvar`, not on the state word; stale
  `no_std` documentation in `Inner`.

## Key design decisions and trade-offs

| Decision                                                   | Rationale                                                                  | Trade-off                                                                  |
| ---------------------------------------------------------- | -------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| Eventcount (`Event`) separate from lock state              | "turn non-blocking data structures into async or blocking data structures" | every primitive is a check–listen–check loop; wakeups carry no ownership   |
| Link stores `Waker` or `Unparker`                          | one queue for tasks and threads; `_blocking` APIs for free                 | thread waits park on a `Mutex`+`Condvar` parker                            |
| Lazily allocated `Arc<Inner>` behind an `AtomicPtr`        | `const fn new`; `Event` is one word                                        | first `notify`/`listen` allocates; an extra indirection on every operation |
| `next` pointer = first unnotified listener                 | `notify(n)` is idempotent, `notify_additional(n)` counts                   | callers must pick the right one (the classic lost-vs-extra wakeup choice)  |
| Notified-but-dropped listener re-notifies                  | cancellation-safe by default                                               | `discard()` needed when the notification should die                        |
| `Mutex` barges, then goes fair after 500 µs                | throughput of barging, bounded starvation                                  | needs `Instant`; `no_std` loses the bound; `Semaphore` has no equivalent   |
| Three list-lock backends (`std`, `critical-section`, spin) | `no_std` support                                                           | the spinlock fallback is documented as dangerous                           |

## Sources

- `smol-rs/event-listener` at [`77004ac77dce`][el-repo], `smol-rs/async-lock`
  at [`23e181d5cfb9`][al-repo], `smol-rs/event-listener-strategy` at
  [`be0f536e7a18`][els-repo] and `smol-rs/parking` at [`cedb1884e050`][pk-repo]:
  the files in the metadata table.
- Dmitry Vyukov, [eventcounts][vyukov-eventcount] — the design `event-listener`
  cites as its origin (cited from the crate docs, not re-read).

> [!NOTE]
> All four clones are single-commit checkouts, so no history is cited. The
> statement that `parking_lot` removed eventual fairness at HEAD comes from
> the catalog's [`parking-lot`](./parking-lot.md) page, not from these
> crates. Byte sizes are field arithmetic for a 64-bit target.

<!-- References -->

[el-repo]: https://github.com/smol-rs/event-listener/tree/77004ac77dcef7884bf71a99c276a50f83a7fa4e
[el-lib]: https://github.com/smol-rs/event-listener/blob/77004ac77dcef7884bf71a99c276a50f83a7fa4e/src/lib.rs
[el-doc]: https://github.com/smol-rs/event-listener/blob/77004ac77dcef7884bf71a99c276a50f83a7fa4e/src/lib.rs#L1-L10
[el-doc-loop]: https://github.com/smol-rs/event-listener/blob/77004ac77dcef7884bf71a99c276a50f83a7fa4e/src/lib.rs#L44-L61
[el-inner]: https://github.com/smol-rs/event-listener/blob/77004ac77dcef7884bf71a99c276a50f83a7fa4e/src/lib.rs#L131-L144
[el-event-doc]: https://github.com/smol-rs/event-listener/blob/77004ac77dcef7884bf71a99c276a50f83a7fa4e/src/lib.rs#L155-L173
[el-event-struct]: https://github.com/smol-rs/event-listener/blob/77004ac77dcef7884bf71a99c276a50f83a7fa4e/src/lib.rs#L174-L181
[el-listen]: https://github.com/smol-rs/event-listener/blob/77004ac77dcef7884bf71a99c276a50f83a7fa4e/src/lib.rs#L305-L318
[el-notify-fn]: https://github.com/smol-rs/event-listener/blob/77004ac77dcef7884bf71a99c276a50f83a7fa4e/src/lib.rs#L448-L456
[el-inner-init]: https://github.com/smol-rs/event-listener/blob/77004ac77dcef7884bf71a99c276a50f83a7fa4e/src/lib.rs#L469-L500
[el-listener-macro]: https://github.com/smol-rs/event-listener/blob/77004ac77dcef7884bf71a99c276a50f83a7fa4e/src/lib.rs#L1043-L1051
[el-drop]: https://github.com/smol-rs/event-listener/blob/77004ac77dcef7884bf71a99c276a50f83a7fa4e/src/lib.rs#L1071-L1079
[el-wait]: https://github.com/smol-rs/event-listener/blob/77004ac77dcef7884bf71a99c276a50f83a7fa4e/src/lib.rs#L1096-L1171
[el-discard]: https://github.com/smol-rs/event-listener/blob/77004ac77dcef7884bf71a99c276a50f83a7fa4e/src/lib.rs#L1174-L1181
[el-state]: https://github.com/smol-rs/event-listener/blob/77004ac77dcef7884bf71a99c276a50f83a7fa4e/src/lib.rs#L1207-L1222
[el-task]: https://github.com/smol-rs/event-listener/blob/77004ac77dcef7884bf71a99c276a50f83a7fa4e/src/lib.rs#L1287-L1355
[el-intr]: https://github.com/smol-rs/event-listener/blob/77004ac77dcef7884bf71a99c276a50f83a7fa4e/src/intrusive.rs
[el-list]: https://github.com/smol-rs/event-listener/blob/77004ac77dcef7884bf71a99c276a50f83a7fa4e/src/intrusive.rs#L21-L48
[el-with-inner]: https://github.com/smol-rs/event-listener/blob/77004ac77dcef7884bf71a99c276a50f83a7fa4e/src/intrusive.rs#L109-L177
[el-insert]: https://github.com/smol-rs/event-listener/blob/77004ac77dcef7884bf71a99c276a50f83a7fa4e/src/intrusive.rs#L180-L212
[el-notify-cold]: https://github.com/smol-rs/event-listener/blob/77004ac77dcef7884bf71a99c276a50f83a7fa4e/src/intrusive.rs#L223-L227
[el-register]: https://github.com/smol-rs/event-listener/blob/77004ac77dcef7884bf71a99c276a50f83a7fa4e/src/intrusive.rs#L233-L274
[el-propagate]: https://github.com/smol-rs/event-listener/blob/77004ac77dcef7884bf71a99c276a50f83a7fa4e/src/intrusive.rs#L326-L340
[el-notify-impl]: https://github.com/smol-rs/event-listener/blob/77004ac77dcef7884bf71a99c276a50f83a7fa4e/src/intrusive.rs#L347-L387
[el-update-notified]: https://github.com/smol-rs/event-listener/blob/77004ac77dcef7884bf71a99c276a50f83a7fa4e/src/intrusive.rs#L390-L399
[el-spinlock]: https://github.com/smol-rs/event-listener/blob/77004ac77dcef7884bf71a99c276a50f83a7fa4e/src/intrusive.rs#L424-L493
[el-notify]: https://github.com/smol-rs/event-listener/blob/77004ac77dcef7884bf71a99c276a50f83a7fa4e/src/notify.rs
[el-fence]: https://github.com/smol-rs/event-listener/blob/77004ac77dcef7884bf71a99c276a50f83a7fa4e/src/notify.rs#L579-L610
[el-ex-mutex]: https://github.com/smol-rs/event-listener/blob/77004ac77dcef7884bf71a99c276a50f83a7fa4e/examples/mutex.rs
[al-repo]: https://github.com/smol-rs/async-lock/tree/23e181d5cfb91a59382e5719c682caa58ff43ace
[al-lib]: https://github.com/smol-rs/async-lock/blob/23e181d5cfb91a59382e5719c682caa58ff43ace/src/lib.rs
[al-doc]: https://github.com/smol-rs/async-lock/blob/23e181d5cfb91a59382e5719c682caa58ff43ace/src/lib.rs#L11-L30
[al-mutex]: https://github.com/smol-rs/async-lock/blob/23e181d5cfb91a59382e5719c682caa58ff43ace/src/mutex.rs
[al-mutex-struct]: https://github.com/smol-rs/async-lock/blob/23e181d5cfb91a59382e5719c682caa58ff43ace/src/mutex.rs#L20-L54
[al-lock-blocking]: https://github.com/smol-rs/async-lock/blob/23e181d5cfb91a59382e5719c682caa58ff43ace/src/mutex.rs#L143
[al-try-lock]: https://github.com/smol-rs/async-lock/blob/23e181d5cfb91a59382e5719c682caa58ff43ace/src/mutex.rs#L164
[al-unlock]: https://github.com/smol-rs/async-lock/blob/23e181d5cfb91a59382e5719c682caa58ff43ace/src/mutex.rs#L203-L207
[al-acquire-drop]: https://github.com/smol-rs/async-lock/blob/23e181d5cfb91a59382e5719c682caa58ff43ace/src/mutex.rs#L469-L474
[al-take-mutex]: https://github.com/smol-rs/async-lock/blob/23e181d5cfb91a59382e5719c682caa58ff43ace/src/mutex.rs#L501-L512
[al-acquire-slow]: https://github.com/smol-rs/async-lock/blob/23e181d5cfb91a59382e5719c682caa58ff43ace/src/mutex.rs#L520-L628
[al-sem]: https://github.com/smol-rs/async-lock/blob/23e181d5cfb91a59382e5719c682caa58ff43ace/src/semaphore.rs
[al-sem-poll]: https://github.com/smol-rs/async-lock/blob/23e181d5cfb91a59382e5719c682caa58ff43ace/src/semaphore.rs#L289-L310
[al-sem-drop]: https://github.com/smol-rs/async-lock/blob/23e181d5cfb91a59382e5719c682caa58ff43ace/src/semaphore.rs#L381-L385
[al-rw]: https://github.com/smol-rs/async-lock/blob/23e181d5cfb91a59382e5719c682caa58ff43ace/src/rwlock.rs
[al-rw-doc]: https://github.com/smol-rs/async-lock/blob/23e181d5cfb91a59382e5719c682caa58ff43ace/src/rwlock.rs#L1-L6
[al-rw-raw]: https://github.com/smol-rs/async-lock/blob/23e181d5cfb91a59382e5719c682caa58ff43ace/src/rwlock/raw.rs
[al-rw-struct]: https://github.com/smol-rs/async-lock/blob/23e181d5cfb91a59382e5719c682caa58ff43ace/src/rwlock/raw.rs#L22-L48
[al-rw-unlock]: https://github.com/smol-rs/async-lock/blob/23e181d5cfb91a59382e5719c682caa58ff43ace/src/rwlock/raw.rs#L240-L276
[al-rw-write]: https://github.com/smol-rs/async-lock/blob/23e181d5cfb91a59382e5719c682caa58ff43ace/src/rwlock/raw.rs#L455-L475
[al-once]: https://github.com/smol-rs/async-lock/blob/23e181d5cfb91a59382e5719c682caa58ff43ace/src/once_cell.rs
[al-once-struct]: https://github.com/smol-rs/async-lock/blob/23e181d5cfb91a59382e5719c682caa58ff43ace/src/once_cell.rs#L89-L105
[al-barrier]: https://github.com/smol-rs/async-lock/blob/23e181d5cfb91a59382e5719c682caa58ff43ace/src/barrier.rs
[els-repo]: https://github.com/smol-rs/event-listener-strategy/tree/be0f536e7a18776978b03a6079eb823ee3aa9b34
[els-lib]: https://github.com/smol-rs/event-listener-strategy/blob/be0f536e7a18776978b03a6079eb823ee3aa9b34/src/lib.rs
[els-strategies]: https://github.com/smol-rs/event-listener-strategy/blob/be0f536e7a18776978b03a6079eb823ee3aa9b34/src/lib.rs#L453-L525
[els-nonblocking]: https://github.com/smol-rs/event-listener-strategy/blob/be0f536e7a18776978b03a6079eb823ee3aa9b34/src/lib.rs#L474-L490
[pk-repo]: https://github.com/smol-rs/parking/tree/cedb1884e0502ad21d4863a21eec9e3f13c3cf5f
[pk-lib]: https://github.com/smol-rs/parking/blob/cedb1884e0502ad21d4863a21eec9e3f13c3cf5f/src/lib.rs
[pk-inner]: https://github.com/smol-rs/parking/blob/cedb1884e0502ad21d4863a21eec9e3f13c3cf5f/src/lib.rs#L326-L438
[vyukov-eventcount]: https://web.archive.org/web/20260101070254/http://www.1024cores.net/home/lock-free-algorithms/eventcounts
