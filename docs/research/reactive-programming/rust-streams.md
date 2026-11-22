# Rust streams, watch channels and signals (Rust)

Rust has no single reactive library. It has a set of poll-driven pieces: `futures::Stream` (an async `Iterator`), Tokio's `watch` latest-value channel, `Sleep` timer, `select!` and task handles, and `futures-signals`, a lossy latest-value FRP layer. All of them share one cancellation rule: **dropping a future cancels it at its next `.await`**.

| Field             | Value                                                                                                                                                                                                                                                                                                                                                              |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Language          | Rust (`futures` MSRV 1.71, `tokio` MSRV 1.85, per [`futures/Cargo.toml`][fut-cargo] and [`tokio/Cargo.toml`][tk-cargo]; `futures-signals` is edition 2018, [`Cargo.toml`][sg-cargo])                                                                                                                                                                               |
| License           | `futures`: MIT OR Apache-2.0; `tokio`, `tokio-util`, `tokio-stream`, `futures-signals`: MIT                                                                                                                                                                                                                                                                        |
| Repository        | [rust-lang/futures-rs][fut-repo] · [tokio-rs/tokio][tk-repo] (holds `tokio`, `tokio-util`, `tokio-stream`, `tokio-macros`) · [Pauan/rust-signals][sg-repo]                                                                                                                                                                                                         |
| Documentation     | [docs.rs/futures][docs-futures] · [docs.rs/tokio][docs-tokio] · [docs.rs/tokio-util][docs-token] · [docs.rs/tokio-stream][docs-tokio-stream] · [docs.rs/futures-signals][docs-signals] (the crate's tutorial lives in [`src/lib.rs`][sg-lib])                                                                                                                      |
| Category          | Poll-based async streams plus a latest-value signal library. A toolkit, not one reactive library                                                                                                                                                                                                                                                                   |
| Versions surveyed | `futures` **0.3.34** (released 2026-08-11 per [`CHANGELOG.md`][fut-changelog]); its `master` says `0.4.0-alpha.0` at `92c78c2b985e` (2026-11-18). `tokio` **1.54.1** (2026-10-21, [`CHANGELOG.md`][tk-changelog]), `tokio-util` **0.7.20**, `tokio-stream` **0.1.19**, at `675ba8164071` (2026-11-22). `futures-signals` **0.3.34** at `006adaf5b138` (2026-04-06) |
| Core abstraction  | `Stream::poll_next`: a pinned state machine the consumer polls; a `Waker` tells it when to poll again. `Signal::poll_change`: the same shape, but it reports only "changed since last poll". `watch::Receiver`: a versioned latest-value cell                                                                                                                      |

> [!NOTE]
> Source citations are to the pinned `master`/default-branch commits above. `futures`
> `master` is a 0.4 alpha. The `StreamExt`, `Abortable` and `select!` surfaces cited
> here are the ones the 0.3 line also ships, but no claim was checked against the
> 0.3.34 tag itself. Rust sketches in this page were **not compiled**. Where the text
> infers behaviour from code rather than from documentation, it says so.

---

## Overview

### What it solves

Rust's `async`/`.await` gives each computation a compiler-generated state machine (a `Future`) that does nothing until an executor polls it. `Stream` adds "many values": the trait doc in [`futures-core/src/stream.rs`][fut-stream] puts it as _"If `Future<Output = T>` is an asynchronous version of `T`, then `Stream<Item = T>` is an asynchronous version of `Iterator<Item = T>`."_ On top of that, Tokio provides the runtime services a reactive pipeline needs: timers, channels, tasks, a blocking pool and a virtual clock. `futures-signals` provides a _"value that changes over time"_ ([`README.md`][sg-readme]) for GUI and state synchronisation. It is the backend of the `dominator` web framework.

Nothing in this stack is an Rx-style operator library with `debounce` and `switchMap`. The idioms that stand in for them are this survey's main finding.

### Design philosophy

The design is zero-cost and poll-driven. Composition builds nested structs whose `poll` calls each other's `poll`, so a chain needs no allocation and no scheduler hop. The `futures-signals` tutorial states the trade it makes ([`src/lib.rs`][sg-lib]):

> _"It is important to understand that `for_each`, `to_stream`, and \*all\* other `SignalExt` methods are \*lossy\*: they might skip changes. … This is an intentional design choice: it is necessary for correctness and performance."_

Tokio defines cancellation by what happens when a future is dropped ([`tokio/src/macros/select.rs`][tk-select]):

> _"Cancellation safety can be defined in the following way: If you have a future that has not yet completed, then it must be a no-op to drop that future and recreate it."_

That definition is the centre of the model. Rust has no cancellation _signal_ inside a future. Ownership is the only lever: whoever holds the future decides when it stops existing.

---

## How it works

### The poll contract

`Stream` has one required method:

```rust
// futures-core/src/stream.rs
pub trait Stream {
    type Item;
    fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>>;
}
```

`Poll::Pending` promises that _"the current task will be notified when the next value may be ready"_. `Ready(Some(v))` yields a value, and `Ready(None)` ends the stream ([`stream.rs`][fut-stream]). A consumer that gets `Ready(Some)` may poll again right away. `FusedStream` (`is_terminated`) and `TryStream` (an `Item` of `Result<T, E>`) refine the trait in the same file.

`futures-signals`' `Signal` uses the same signature with a different contract. The trait carries no doc comment, only a `TODO documentation for Signal contract` comment ([`src/signal/signal.rs`][sg-signal]):

> _"a Signal must always return Poll::Ready(Some(...)) the first time it is polled … it can return Poll::Pending, which means the Signal hasn't changed from its previous value … unlike Streams, the consumer does not poll again if it receives Poll::Ready(Some(...)), it will only repoll if wake_by_ref() is called"_

So a `Signal` always has a current value, and a consumer only learns "something changed, pull the latest".

### Cells and wakers

`tokio::sync::watch` is the runtime's latest-value cell. The module doc calls it _"A multi-producer, multi-consumer channel that only retains the \*last\* sent value"_, and says _"Each [`Receiver`] independently tracks the last value \*seen\* by its caller"_ ([`watch.rs`][tk-watch]). Internally the shared state is an `AtomicState` whose low bit is a `CLOSED` flag and whose other bits are a `Version` counter. A receiver stores the last `version` it saw. `changed()` waits until the shared version differs, and `borrow_and_update()` reads the value and records the version.

`futures_signals::signal::Mutable` is the signals equivalent: an `Arc` around an `RwLock`, plus one `ChangedWaker` per derived signal. A `ChangedWaker` is an `AtomicBool` "changed" flag and a stored `Waker`. `set` marks every child changed and wakes it, and `poll_change` reads the value under the read lock only if the flag is set ([`src/signal/mutable.rs`][sg-mutable]). A new signal starts with `changed: true`, which is how the "first poll is always `Ready`" rule is met.

### Tasks and the select loop

`tokio::spawn` makes a future a task, and its `JoinHandle` is the result. `tokio::select!` polls several futures inside one task and runs the handler of the first that finishes. Every losing future is _dropped_. The macro doc says it _"Waits on multiple concurrent branches, returning when the \*\*first\*\* branch completes, cancelling the remaining branches"_ ([`select.rs`][tk-select]). The expansion polls inside its own scope and runs handlers outside it (_"Create a scope to separate polling from handling the output. This adds borrow checker flexibility"_), so a handler may mutate state that a branch future had borrowed. The worked pipeline relies on this.

---

## Evaluation model

- **Push-pull, lazy.** A `Waker` push says "poll me", and the consumer then _pulls_ the value with `poll_next` or `poll_change`. Every combinator is `#[must_use = "streams do nothing unless polled"]` ([`stream.rs`][fut-stream]), and the signals tutorial repeats the point. A chain that nobody polls does nothing at all.
- **Cold vs hot depends on the source.** `stream::iter` or an `async_stream` generator restarts per instance (cold). A stream over an `mpsc` or `watch` receiver observes a producer that runs anyway (hot). The trait does not encode the difference.
- **Backpressure comes free.** A producer behind a bounded channel cannot outrun a consumer that stops polling. Tokio-stream's `throttle` relies on this: it _delays_ the next pull and drops nothing (see [Time and scheduling](#time-and-scheduling)).
- **Conflation instead of queues for state.** `watch` and `Signal` keep only the newest value, so a slow reader skips intermediates. `SignalVec` is the documented exception: _"Unlike `Signal`, it is guaranteed that the `SignalVec` will never skip a change. In addition, the changes will always be in the correct order"_ ([`src/lib.rs`][sg-lib]). It pays for this with a diff queue.
- **Glitch-freedom is not documented.** `glitch` appears nowhere in the `rust-signals` tree. _Inferred from the code:_ a `map_ref!` over several signals recomputes when its task is polled, and it polls every input in that one pass. Several `set`s that land before the poll therefore collapse into one recompute over consistent inputs, and a diamond that hangs off one `Mutable` cannot be observed half-updated on a single-threaded executor. On a multi-threaded runtime a poll can fall between two `set`s on different `Mutable`s, and nothing orders them. There is no topological propagation and no transaction (contrast [Solid signals][solid-signals] and [Sodium][sodium]).
- **Propagation is batched by the executor**, not synchronous. `Mutable::set` only flips flags and wakes. The work happens on the next poll of the consuming task.

## Composition

| Layer                        | Surface (counted at the pinned commits)                                                                                                                                                                                                                          |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `futures::StreamExt`         | 49 methods ([`stream/stream/mod.rs`][fut-streamext]): `map`, `then`, `filter`, `scan`, `flatten`, `flat_map`, `flatten_unordered`, `buffered`, `buffer_unordered`, `zip`, `chain`, `take_until`, `for_each_concurrent`, `fuse`, `select_next_some`, …            |
| `futures::TryStreamExt`      | 26 methods over `Result` items ([`try_stream/mod.rs`][fut-trystream])                                                                                                                                                                                            |
| Free functions / sets        | `stream::select` (round-robin merge, [`select.rs`][fut-select]), `select_all`, `FuturesUnordered` / `FuturesOrdered` ([`futures_unordered/mod.rs`][fut-unordered]), `Abortable` ([`abortable.rs`][fut-abortable])                                                |
| `tokio_stream::StreamExt`    | 24 methods ([`stream_ext.rs`][ts-ext]): the basics plus `merge`, `timeout`, `timeout_repeating`, `throttle`, `chunks_timeout`; and wrappers such as `WatchStream` ([`wrappers/watch.rs`][ts-watch])                                                              |
| `futures_signals::SignalExt` | ~26 methods: `map`, `dedupe`, `map_future`, `filter_map`, `throttle`, `flatten`, `switch`, `switch_signal_vec`, `sample_stream_cloned`, `for_each`, `to_stream`, `broadcast`, … and `map_ref!` for N inputs ([`signal.rs`][sg-signal], [`macros.rs`][sg-macros]) |

The `futures` crate has **no `switch`/`flatMapLatest`/`debounce`** (grep for `debounce`/`switch`/`latest` in `futures-util/src` finds only unrelated comments). `flatten` and `flat_map` run the inner streams _sequentially_, and `flatten_unordered` runs them _concurrently_. Neither drops the previous inner stream when a new one arrives. A `switchMap` is written by hand: hold the current inner future in a variable and overwrite it, which drops the old one.

`futures-signals` _does_ have latest-wins operators, because conflation makes them natural:

- `switch(f)` is literally `self.map(callback).flatten()` ([`signal.rs`][sg-signal]), and `flatten` follows the newest inner `Signal`.
- `map_future(f)` is a `switchMap` to a `Future`: _"If `self` changes before the old `Future` is finished, it will cancel the old `Future`. That means if `self` changes faster than the `Future`, then it will never output any values."_ Its `poll_change` loops over upstream changes and calls `future.set(Some(callback(value)))`, which drops the previous future in place.

## Time and scheduling

- **Clock and timer.** `tokio::time::sleep` returns a `Sleep` that _"operates at millisecond granularity and should not be used for tasks that require high-resolution timers"_. Cancelling one _"is done by dropping the returned future. No additional cleanup work is required"_ ([`sleep.rs`][tk-sleep]).
- **`Sleep::reset`** _"allows changing the instant at which the `Sleep` future completes without having to create new associated state … can be called both before and after the future has completed"_. It takes an absolute `Instant`, so a debounce whose window changes at runtime is just a `reset` to `last_input + new_n`.
- **Schedulers.** There is no Rx-style `Scheduler` argument. Where code runs is decided by which executor polls it: `current_thread`, the multi-thread work-stealing runtime, a `LocalSet`, or the blocking pool. `select!` checks branches in random order by default for fairness, and `biased;` makes the order the order of declaration ([`select.rs`][tk-select]).
- **Debounce does not exist as an operator** anywhere in the three trees: zero hits for `debounce` across the whole `tokio` repository, `futures-util/src` and `rust-signals`. What does exist:
  - `tokio_stream::StreamExt::throttle` _"Slows down a stream by enforcing a delay between items"_. It sleeps _after_ yielding an item and refuses to pull the next one until the `Sleep` fires ([`throttle.rs`][ts-throttle]). It is a lossless rate limiter driven by backpressure, not RxJS `throttleTime` and not a debounce. Its duration is fixed at construction.
  - `futures_signals::SignalExt::throttle(|| fut)` _"delays updates until a `Future` finishes … If multiple updates happen while it's being delayed, it will only output the most recent value"_ ([`signal.rs`][sg-signal]). It is lossy, and because the closure builds a new future each time, the delay may differ per update.
  - **The idiomatic debounce** is either a `select!` loop that calls `reset` on a pinned `Sleep` for every input (Tokio's own `Sleep` doc example has this shape), or, with signals, `map_future(|v| async move { sleep(n).await; v })`. There latest-wins cancellation of the pending `sleep` _is_ the debounce.
- **Frames.** No piece knows about frames. A per-frame UI reads `watch::Receiver::borrow()` or `has_changed()` synchronously when it builds the tree, and nothing in the stack wakes the UI loop unless code wires it to (see [the worked pipeline](#the-worked-pipeline)).

## Concurrency and cancellation

**Drop is cancellation.** A future that is not polled makes no progress, and dropping it runs its destructors at whatever `.await` it is suspended on. Tokio's task docs spell out the remote form ([`task/mod.rs`][tk-task]):

> _"When one of these methods are called, the task is signalled to shut down next time it yields at an `.await` point. … When tasks are shut down, it will stop running at whichever `.await` it has yielded at. All local variables are destroyed by running their destructor."_

The tools, from in-task to cross-task:

| Mechanism                                    | What it cancels                                                                                                                                                                                            | Waits for the victim?                                                                                                                                                                                                                |
| -------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Drop / `select!` loser                       | the dropped future, synchronously, at its suspension point                                                                                                                                                 | yes: the drop is synchronous, but a destructor cannot `.await`                                                                                                                                                                       |
| `futures::future::Abortable` + `AbortHandle` | sets an `AtomicBool` and wakes the task. The wrapper then returns `Err(Aborted)` / `None`                                                                                                                  | no. `is_aborted` is _"true even if … `abort` was called while the task was being polled - the task may still be running"_ ([`abortable.rs`][fut-abortable]). The inner future is dropped only when the `Abortable` is                |
| `JoinHandle::abort` / `AbortHandle`          | a spawned task, at its next `.await`                                                                                                                                                                       | no: _"calls to [`JoinHandle::abort`] just schedule the task for cancellation, and will return before the cancellation has completed. To wait … [await] the [`JoinHandle`]"_ ([`task/mod.rs`][tk-task])                               |
| Dropping a `JoinHandle`                      | **nothing**: it _"\*detaches\* the associated task"_ ([`join.rs`][tk-join])                                                                                                                                | n/a. `JoinSet` (_"When the `JoinSet` is dropped, all tasks in the `JoinSet` are immediately aborted"_, [`join_set.rs`][tk-joinset]) and `tokio_util::task::AbortOnDropHandle` ([`abort_on_drop.rs`][tu-abort]) restore abort-on-drop |
| `tokio_util::sync::CancellationToken`        | nothing by itself. It is a cooperative flag with a tree of `child_token()`s, `cancelled()` (cancel-safe), `run_until_cancelled`, `drop_guard` ([`cancellation_token.rs`][tu-token], [docs.rs][docs-token]) | no. Cancelling a parent cancels its children, but each task must observe the token                                                                                                                                                   |

**CPU-bound work cannot be preempted.** A future that never reaches an `.await` cannot be cancelled. `spawn_blocking` work is outside the async machinery entirely ([`task/blocking.rs`][tk-blocking]):

> _"Be aware that tasks spawned using `spawn_blocking` cannot be aborted because they are not async. If you call [`abort`] on a `spawn_blocking` task, then this \*will not have any effect\*, and the task will continue running normally. The exception is if the task has not started running yet"_

Runtime shutdown _"will wait indefinitely for all started `spawn_blocking` to finish running"_. Latest-wins over a CPU-bound hash therefore needs a cooperative flag (`AtomicBool` or `CancellationToken::is_cancelled()`) that the hashing loop checks. Dropping or aborting the handle only means nobody receives the result.

**Cancellation safety** is documented per method. The `select!` doc keeps the canonical lists. _Cancel-safe:_ `mpsc::Receiver::recv`, `broadcast::Receiver::recv`, `watch::Receiver::changed`, `TcpListener::accept`, `AsyncReadExt::read`/`read_buf`, `AsyncWriteExt::write`/`write_buf`, `StreamExt::next`. _Not cancel-safe (data loss):_ `read_exact`, `read_to_end`, `read_to_string`, `write_all`. _Not cancel-safe (lose queue position):_ `Mutex::lock`, `RwLock::read`/`write`, `Semaphore::acquire`, `Notify::notified`. Each method carries its own `# Cancel safety` section. For example, `watch::Receiver::changed` says: _"If you use it as a branch in [`tokio::select!`] and another branch completes first, then it is guaranteed that no values have been marked seen by this call to `changed`"_ ([`watch.rs`][tk-watch]). For `JoinHandle`: _"Awaiting a `&mut JoinHandle<T>` is cancel safe … it is guaranteed that the output of the task is not lost"_ ([`join.rs`][tk-join]).

### Drop-based cancellation vs completion-based I/O

Drop-cancellation assumes that dropping a future ends every use of its borrowed memory. That holds for readiness I/O (epoll: the syscall happens inside `poll`), but not for completion I/O, where the kernel holds a pointer until it posts a completion. withoutboats laid out the problem in [_Notes on io-uring_][boats-uring] (2020-05-06): futures _"are supposed to be implicitly cancellable, by simply never polling them again"_, yet _"the kernel will write to or read from that buffer even if you cancel the future"_. The answer proposed there: _"Logical ownership is the only way to make this work in Rust’s current type system"_. The operation must _own_ its buffer. The later [_Asynchronous clean-up_][boats-cleanup] (2024-02-24) explains why "just `await` in `Drop`" is not available (_"Async Rust has no good way to handle this pattern today"_).

Tokio's in-tree io_uring driver (behind `tokio_unstable` + `feature = "io-uring"`, Linux only, [`macros/cfg.rs`][tk-cfg], [`lib.rs`][tk-lib]) implements exactly that answer. `Op<T>`'s `Drop` calls `cancel_op`, which moves the operation's owned resources into a `Lifecycle::Cancelled(CancelData)` slot: _"The submitter no longer has interest in the operation result. The state must be passed to the driver and held until the operation completes"_ ([`runtime/driver/op.rs`][tk-op]). The driver keeps the slab entry alive _"to keep uring data alive until the operation completes"_. If the completion already arrived, it frees it, closing a just-opened fd ([`runtime/io/driver/uring.rs`][tk-uring]). No `IORING_OP_ASYNC_CANCEL` is submitted (zero hits in `tokio/src`). The kernel operation runs to completion, and only the waiter disappears. The cost is ownership-passing APIs (`Vec<u8>` in, `Vec<u8>` out) instead of `&mut [u8]`.

For `event-horizon`, which is completion-based like io_uring, the lesson is direct. A scope's cancel can be synchronous for _interest_ (stop waking the fiber), but the operation's buffers must outlive the scope until the completion arrives. Either the loop owns them, as in Tokio's `CancelData`, or the scope's close awaits the completion. That is structured "cancel and join" rather than Rust's "cancel and forget". See [`../async-io/io-uring/`][io-uring] and [`../async-io/tokio.md`][async-tokio].

## Errors and completion

- `Stream` has no error channel. The end is `Ready(None)`, and errors are a convention: `Item = Result<T, E>` (`TryStream`, `TryStreamExt::try_next`, `try_for_each`, `try_buffer_unordered`). An error item does not end a stream unless a combinator decides it should (`try_collect` stops on the first error, `map` does not).
- `Signal` has no error concept. `Ready(None)` means _"the Signal is ended (i.e. there won't be any future changes)"_ ([`signal.rs`][sg-signal]). A `MutableSignal` ends when every `Mutable` sender is dropped (the `senders == 0` check in [`mutable.rs`][sg-mutable]). Errors travel as `Result` values.
- `watch::Receiver::changed()` returns `Err(RecvError)` _"if the channel has been closed \_\_AND\_\_ the current value is \*seen\*"_ ([`watch.rs`][tk-watch]), so a last value is never lost to closure.
- Task failures arrive as `JoinError`: `is_cancelled()` after `abort`, `is_panic()` for a panic, which the runtime catches per task. Panics in a plain future propagate through `poll`. `StreamExt::catch_unwind` converts them.
- **Aborting does not guarantee a cancelled result:** _"aborting a task does not guarantee that it fails with a cancelled error, since it may complete normally first"_ ([`task/mod.rs`][tk-task]). A latest-wins consumer must discard stale results itself.

## State and sharing

- **Value cells:** `watch` (async, `Send + Sync`, versioned; `send_replace`, `send_modify`, `send_if_modified`, `borrow` / `borrow_and_update`, `wait_for(pred)`) and `Mutable` (`set`, `set_neq`, `replace_with`, `lock_mut`; `signal()` / `signal_cloned()` / `signal_ref(f)`).
- **Multicast:** a `watch::Sender::subscribe()` per reader. `Mutable` hands out any number of signals, and _"When the `Mutable` changes, \*all\* of its `Signal`s are notified"_ ([`src/lib.rs`][sg-lib]). An _arbitrary_ derived `Signal` is single-consumer: it is a struct, and only one owner can poll it. `SignalExt::broadcast()` returns a `Broadcaster`, which _"Splits an input `Signal` into multiple output `Signals`"_ ([`broadcaster.rs`][sg-broadcaster]). A `Stream` has no built-in share: you go through a `broadcast` channel or `Shared` futures.
- **Conflation** is built into `watch` and `Signal`: the tutorial example `my_state.set(2); my_state.set(3);` _"will only detect the `3` change"_. `broadcast` and `mpsc` queue values.
- **`borrow_and_update` vs `borrow`.** In a `changed()` loop, `borrow()` can produce a duplicate run: _"If [`Receiver::borrow()`] is used, the loop may run twice with the same value"_ ([`watch.rs`][tk-watch]).

## Lifetime and ownership

There is no subscription object and no disposer. **A computation lives exactly as long as the value that owns it**, and that one rule does the job of RxJS's `Subscription` tree:

- A derived `Signal` or `Stream` chain is a nested struct, and dropping the outermost value tears down every stage synchronously, inner futures included.
- A spawned task is the leak point: it is detached by default and outlives its creator (`JoinHandle` drop detaches). Structured lifetime has to be opted into with `JoinSet`, `AbortOnDropHandle`, `CancellationToken::drop_guard` (_"Returned guard will cancel this token (and all its children) on drop"_, [`cancellation_token.rs`][tu-token]) or `tokio_util::task::TaskTracker`. Tokio has no nursery or scope that guarantees children finish before the parent returns. Compare [Kotlin's `coroutineScope`][kotlin-flow] and [Effect's fibers][effect-ts].
- `JoinHandle` makes one strong promise: _"the destructor of the spawned task has finished before task completion is observed via `JoinHandle` `await`"_ ([`join.rs`][tk-join]). Awaiting after `abort` is therefore a sound join.
- `Mutable` signals keep the shared `Arc` alive, and a stored `Waker` keeps the consuming task reachable until the next `set` takes it. Neither leaks once the signal struct is dropped.

## Testing

- **Virtual time.** `tokio::time::pause()` freezes Tokio's `Instant::now()`. `advance(d)` jumps it forward, and with the clock paused, _"If time is paused and the runtime has no work to do, the clock is auto-advanced to the next pending timer"_ ([`time/clock.rs`][tk-clock]). Pausing needs the `current_thread` runtime and the `test-util` feature. `#[tokio::test(start_paused = true)]` / `Builder::start_paused` start the clock frozen ([`tokio-macros/src/lib.rs`][tk-macros], [`tests/rt_time_start_paused.rs`][tk-start-paused]). Only Tokio's `Instant` is virtual: _"the `Instant` in std continues to work as normal"_.
- **Tokio's own caveat about `advance`:** _"all `sleep` calls with a deadline before the new time will immediately complete 'at the same time', and the runtime is free to poll them in any order. Additionally, this method will not wait for the `sleep` calls it advanced past to complete"_. Its advice: prefer `sleep` under auto-advance for in-order firing. A deterministic debounce test therefore drives inputs, calls `sleep(n - 1ms).await` and asserts nothing was emitted, then `sleep(1ms).await` and asserts the emission.
- **Blocking work and auto-advance.** _"When a blocking task is running, the clock's auto-advance is temporarily inhibited"_ ([`time/clock.rs`][tk-clock]). A test of the hash stage therefore does not race the clock, but a hung blocking task hangs the test.
- **Poll scripts.** `futures-signals` tests use a hand-rolled `util::Source` of scripted `Poll` results. The `throttle` test feeds `Ready(true), Pending, Pending, Ready(false) …` and asserts the exact `Poll` sequence out ([`tests/signal/throttle.rs`][sg-throttle-test], [`tests/util/mod.rs`][sg-test-util]). It is deterministic and needs no clock, because the throttle future is itself a scripted `poll_fn`. `futures::executor::block_on` and `futures-test` give single-threaded deterministic executors for `Stream` tests.

## The worked pipeline

The query field feeds a debounce of N ms, with N adjustable. After the debounce, a worker hashes the file set; the newest query wins and cancels the older hash. The result goes to the UI, and a toggle turns the whole pipeline on and off. Written idiomatically on Tokio, it is one task with a `select!` loop over three `watch` cells, a resettable `Sleep`, and a `spawn_blocking` job that carries a cooperative stop flag:

```rust
use std::sync::{atomic::{AtomicBool, Ordering}, Arc};
use std::time::Duration;
use tokio::sync::watch;
use tokio::task::{JoinError, JoinHandle};
use tokio::time::{sleep, Instant};

type Outcome = Result<[u8; 32], String>;

struct Job {
    query: String,
    stop: Arc<AtomicBool>,                        // spawn_blocking cannot be aborted
    handle: JoinHandle<Option<Outcome>>,          // None = observed `stop`
}
impl Drop for Job {                               // replacing/clearing the job IS the cancel
    fn drop(&mut self) { self.stop.store(true, Ordering::Relaxed); }
}

async fn join(job: &mut Option<Job>) -> Result<Option<Outcome>, JoinError> {
    match job {
        Some(j) => (&mut j.handle).await,         // cancel-safe: output is not lost
        None => std::future::pending().await,
    }
}

pub async fn pipeline(
    mut query: watch::Receiver<String>,
    mut delay_ms: watch::Receiver<u64>,
    mut enabled: watch::Receiver<bool>,
    result: watch::Sender<Option<(String, Outcome)>>,
) {
    let debounce = sleep(Duration::ZERO);
    tokio::pin!(debounce);
    let (mut armed, mut last_input) = (false, Instant::now());
    let mut job: Option<Job> = None;

    loop {
        tokio::select! {
            biased;                                           // the toggle wins ties
            r = enabled.changed() => {
                if r.is_err() { break; }
                if !*enabled.borrow_and_update() {
                    armed = false;                            // drop the pending debounce
                    job = None;                               // flag the hash, detach it
                }
            }
            r = query.changed() => {
                if r.is_err() { break; }
                query.borrow_and_update();
                if *enabled.borrow() {
                    last_input = Instant::now();
                    let n = Duration::from_millis(*delay_ms.borrow());
                    debounce.as_mut().reset(last_input + n);  // restart the window
                    armed = true;
                }
            }
            r = delay_ms.changed() => {
                if r.is_err() { break; }
                let n = Duration::from_millis(*delay_ms.borrow_and_update());
                if armed { debounce.as_mut().reset(last_input + n); } // re-aim, same anchor
            }
            () = &mut debounce, if armed => {
                armed = false;
                let q = query.borrow().clone();
                let stop = Arc::new(AtomicBool::new(false));
                let (q2, s2) = (q.clone(), stop.clone());
                let handle = tokio::task::spawn_blocking(move || hash_fileset(&q2, &s2));
                job = Some(Job { query: q, stop, handle });   // drops (cancels) the old Job
            }
            r = join(&mut job) => {
                let j = job.take().expect("join only completes for Some");
                match r {
                    Ok(Some(out)) => { result.send_replace(Some((j.query.clone(), out))); }
                    Ok(None) => {}                            // stopped: stale, discard
                    Err(e) => { result.send_replace(Some((j.query.clone(), Err(e.to_string())))); }
                }
            }
        }
    }
}

fn hash_fileset(query: &str, stop: &AtomicBool) -> Option<Outcome> {
    let mut h = blake3::Hasher::new();
    for path in expand_fileset(query) {               // the fileset query, evaluated
        if stop.load(Ordering::Relaxed) { return None; } // cancellation granularity: one file
        h.update(&std::fs::read(&path).ok()?);
    }
    Some(Ok(*h.finalize().as_bytes()))
}
```

The UI owns the three `watch::Sender`s and calls `send_replace` on edit. That call is synchronous, so the frame code never `.await`s. It reads `result_rx.borrow()` while building the tree each frame.

The same pipeline in `futures-signals` is shorter, because latest-wins is the default:

```rust
let stage1 = map_ref! {
    let q = query.signal_cloned(), let n = delay_ms.signal(), let on = enabled.signal() =>
    (q.clone(), *n, *on)
}
.map_future(|(q, n, on)| async move {         // any input change drops this future
    if !on { return None; }
    tokio::time::sleep(Duration::from_millis(n)).await; // debounce = cancellable sleep
    Some(q)
})
.map(|o| o.flatten())
.dedupe_cloned();

let output = stage1.map_future(|q| async move {
    let q = q?;                                  // toggle off -> None -> old hash dropped
    let token = CancellationToken::new();
    let _guard = token.clone().drop_guard();     // future dropped => token cancelled
    let h = AbortOnDropHandle::new(tokio::task::spawn_blocking(move || hash(&q, &token)));
    h.await.ok().flatten()
});
```

**Per-event trace (Tokio version, N = 250 ms).**

1. _Keystroke during debounce_ (at t₀+100 ms). `query.changed()` wins and `reset(t₁ + 250 ms)` moves the existing timer entry; no new `Sleep` is allocated. The pending window is gone, and only the new deadline can fire. Because `watch` conflates, ten keystrokes between two polls of the task look like one.
2. _Keystroke during hash._ The query branch re-arms the debounce. The running hash is left alone until the new debounce fires. The `job = Some(new)` assignment then drops the old `Job`: its `Drop` sets `stop`, and its `JoinHandle` drops, which detaches the task. The assignment returns at once and **does not wait**. The old blocking thread keeps hashing until its next `stop` check (at most one file's read and hash), then returns `None` into a dropped handle. For that window, two blocking-pool threads are busy. If the stale task finishes first, its output is unobservable because its handle is gone. A variant that keeps the old job hashing until the debounce _starts_ is a one-line change (`job = None` in the query branch).
3. _Interval change while armed._ `delay_ms.changed()` re-aims to `last_input + n′`. If that instant is already past, the `Sleep` completes on the next poll. The new N applies to the _current_ window, measured from the last keystroke. The signals version differs: `map_ref!` restarts `map_future` with a fresh `sleep(n′)` measured from the change.
4. _Toggle off._ `biased;` checks the toggle first in every poll. `armed = false` disables the timer branch, and the `Sleep` stays allocated but is never polled. `job = None` flags and detaches the hash. The UI keeps the last result unless the handler also clears it (`result.send_replace(None)`). Toggling back on does nothing until the next keystroke. That is a deliberate choice, and arming from the current query is another `reset`.

**Fit with a per-frame UI.** The fit is good at the edges and awkward in the middle. Writes are synchronous `send_replace`, and reads are synchronous `borrow()`, so the immediate-mode frame stays free of `.await`. But nothing _wakes the UI_ when `result` changes. Either the frame polls `has_changed()`, which only works while the loop is spinning anyway, or the pipeline task carries a handle to the UI loop's wake primitive (sparkles' `wakeIn`) and calls it after `send_replace`. The pipeline itself needs an executor separate from the frame loop (a Tokio runtime on another thread). The signals version instead needs a spawned `for_each` to get polled at all. In both, cancellation of CPU work is cooperative and does not join.

---

## Strengths

- **One uniform cancellation rule** (drop) that composes structurally: every combinator, `select!` branch and nested future inherits it with no extra API.
- **Zero-cost composition:** chains are inlined state machines with no per-item allocation and no scheduler hop. `futures-signals` claims that `map_future` _"does not do any heap allocation"_.
- **Backpressure and conflation are explicit choices of type:** `Stream`/`mpsc` queue, while `watch`/`Signal` conflate. The type says which.
- **Cancellation safety is documented per method**, with canonical lists in `select!`. Other ecosystems rarely spell this out.
- **`Sleep::reset`** makes a runtime-adjustable debounce trivial and allocation-free.
- **Deterministic virtual time** (`start_paused`, auto-advance, and auto-advance held off during blocking work) built into the runtime.
- **The `futures-signals` latest-wins operators** (`map_future`, `switch`, `throttle`) are the closest thing in Rust to `switchMap`/`debounce`.
- **Tokio's io_uring `CancelData`** shows how drop-cancellation can coexist with completion I/O.

## Weaknesses

- **No operator library for time**: no `debounce`, no `switchMap` in `futures` or `tokio-stream`. Every project hand-rolls `select!` loops, and those loops are where cancellation-safety bugs live.
- **Cancellation is silent and unjoined.** `abort` and drop return before the victim stops, a detached `JoinHandle` leaks the task, and nothing awaits the cleanup of an aborted task unless you await the handle.
- **No preemption:** CPU-bound and `spawn_blocking` work ignores `abort`, so latest-wins over computation needs hand-threaded flags.
- **Destructors cannot `.await`**, so async cleanup, completion-I/O buffers included, needs ownership workarounds ([withoutboats][boats-cleanup]).
- **Hidden hazards:** `select!` drops the losing futures, so `read_exact`, `Mutex::lock` and friends lose data or their place in the queue, and the type system does not flag it.
- **Glitch behaviour is undocumented** in `futures-signals`, and consistency across `Mutable`s on a multi-threaded runtime is not guaranteed.
- **No structured scopes** in Tokio: lifetimes are opt-in through `JoinSet` and tokens.
- **Fragmentation**: three crates, two `StreamExt` traits whose names collide (`futures` vs `tokio-stream`), and an `Abortable` and a `CancellationToken` that do different things.

## Key design decisions and trade-offs

| Decision                                               | Rationale                                                                                        | Trade-off                                                                                                             |
| ------------------------------------------------------ | ------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------- |
| Poll/pull with `Waker` notification (push-pull)        | Zero allocation and inlining. Backpressure is automatic, and laziness falls out of `#[must_use]` | Values only move when someone polls. Wiring wakes into a non-async frame loop is manual                               |
| Cancellation = dropping the future                     | Needs no runtime support, works for every combinator, and is synchronous                         | Cleanup cannot `.await`. Completion I/O must hand buffers to the driver. Cancel-unsafe operations lose data silently  |
| `select!` drops losing branches                        | Concise latest-wins and timeouts                                                                 | Every branch must be cancel-safe. Tokio documents this per method because the compiler cannot check it                |
| `JoinHandle` drop detaches, `abort` is fire-and-forget | Tasks are independent units, and `spawn` stays cheap                                             | Leaks and unjoined cancellation by default. Structure comes from `JoinSet`, `AbortOnDropHandle`, tokens               |
| `spawn_blocking` work is not abortable                 | Threads cannot be safely killed                                                                  | Latest-wins over CPU work needs cooperative flags, and shutdown can hang on blocking tasks                            |
| `watch`/`Signal` keep only the latest value            | Correctness and performance for state: readers never fall behind                                 | Intermediate values are skipped by design. `SignalVec` pays for a queue to stay lossless                              |
| `map_future`/`switch` are latest-wins by construction  | Conflation makes "newest input wins" the only sensible semantics                                 | _"if `self` changes faster than the `Future`, then it will never output any values"_: a fast input starves the output |
| No built-in debounce; `Sleep::reset` instead           | A small core; `reset` takes an absolute `Instant`, so the window can change at runtime           | Each pipeline writes its own state machine. tokio-stream's `throttle` is a lossless delay, not a debounce             |
| Virtual time is a runtime-wide frozen `Instant`        | Real-code tests with no injected clock; auto-advance skips idle waits                            | `current_thread` only. `advance` fires expired timers "at the same time" in any order. std `Instant` stays real       |
| io_uring ops move `CancelData` into the driver on drop | Keeps drop-cancel sound under completion I/O without async drop                                  | No `ASYNC_CANCEL`: the kernel op still runs to completion, and APIs take owned buffers                                |

---

## Sources

- [`futures-core/src/stream.rs`: `Stream`, `FusedStream`, `TryStream`][fut-stream]
- [`futures-util/src/stream/stream/mod.rs`: `StreamExt`][fut-streamext] · [`try_stream/mod.rs`][fut-trystream] · [`stream/select.rs`][fut-select] · [`futures_unordered/mod.rs`][fut-unordered] · [`async_await/select_mod.rs`: `select!` requires `FusedFuture + Unpin`][fut-select-macro]
- [`futures-util/src/abortable.rs`: `Abortable`, `AbortHandle`][fut-abortable]
- [`futures/Cargo.toml`][fut-cargo] · [`CHANGELOG.md`][fut-changelog]
- [`tokio/src/macros/select.rs`: `select!`, cancellation-safety lists][tk-select]
- [`tokio/src/sync/watch.rs`: `watch` channel][tk-watch]
- [`tokio/src/time/sleep.rs`: `Sleep`, `reset`][tk-sleep] · [`tokio/src/time/clock.rs`: `pause`, `advance`, auto-advance][tk-clock]
- [`tokio/src/task/mod.rs`: task cancellation][tk-task] · [`runtime/task/join.rs`: `JoinHandle`][tk-join] · [`task/blocking.rs`: `spawn_blocking`][tk-blocking] · [`task/join_set.rs`][tk-joinset]
- [`tokio/src/runtime/driver/op.rs`: io_uring `Op`, `Lifecycle::Cancelled`][tk-op] · [`runtime/io/driver/uring.rs`: `cancel_op`][tk-uring] · [`macros/cfg.rs`][tk-cfg] · [`lib.rs`][tk-lib]
- [`tokio-macros/src/lib.rs`: `start_paused`][tk-macros] · [`tokio/tests/rt_time_start_paused.rs`][tk-start-paused] · [`tokio/Cargo.toml`][tk-cargo] · [`tokio/CHANGELOG.md`][tk-changelog]
- [`tokio-stream/src/stream_ext.rs`][ts-ext] · [`stream_ext/throttle.rs`][ts-throttle] · [`wrappers/watch.rs`][ts-watch]
- [`tokio-util/src/sync/cancellation_token.rs`][tu-token] · [`tokio-util/src/task/abort_on_drop.rs`][tu-abort] · [`CancellationToken` on docs.rs (0.7.20)][docs-token]
- [`rust-signals` `README.md`][sg-readme] · [`src/lib.rs`: tutorial][sg-lib] · [`src/signal/signal.rs`: `Signal`, `SignalExt`][sg-signal] · [`src/signal/mutable.rs`][sg-mutable] · [`src/signal/broadcaster.rs`][sg-broadcaster] · [`src/signal/macros.rs`: `map_ref!`][sg-macros] · [`tests/signal/throttle.rs`][sg-throttle-test] · [`tests/util/mod.rs`][sg-test-util] · [`Cargo.toml`][sg-cargo]
- withoutboats, [_Notes on io-uring_][boats-uring] (2020-05-06) · [_Asynchronous clean-up_][boats-cleanup] (2024-02-24)
- Related: [RxJS][rxjs] · [Effect-TS][effect-ts] · [Kotlin Flow][kotlin-flow] · [Swift Async Algorithms][swift-async] · [Solid signals][solid-signals] · [Sodium][sodium] · [Concepts][concepts] · [Comparison][comparison] · [Tokio (async-io)][async-tokio] · [io_uring][io-uring] · [Cats Effect][cats-effect]

<!-- References -->

[fut-repo]: https://github.com/rust-lang/futures-rs/tree/92c78c2b985e9b713c658d4d65c84e2688788b87
[fut-stream]: https://github.com/rust-lang/futures-rs/blob/92c78c2b985e9b713c658d4d65c84e2688788b87/futures-core/src/stream.rs
[fut-streamext]: https://github.com/rust-lang/futures-rs/blob/92c78c2b985e9b713c658d4d65c84e2688788b87/futures-util/src/stream/stream/mod.rs
[fut-trystream]: https://github.com/rust-lang/futures-rs/blob/92c78c2b985e9b713c658d4d65c84e2688788b87/futures-util/src/stream/try_stream/mod.rs
[fut-select]: https://github.com/rust-lang/futures-rs/blob/92c78c2b985e9b713c658d4d65c84e2688788b87/futures-util/src/stream/select.rs
[fut-select-macro]: https://github.com/rust-lang/futures-rs/blob/92c78c2b985e9b713c658d4d65c84e2688788b87/futures-util/src/async_await/select_mod.rs
[fut-unordered]: https://github.com/rust-lang/futures-rs/blob/92c78c2b985e9b713c658d4d65c84e2688788b87/futures-util/src/stream/futures_unordered/mod.rs
[fut-abortable]: https://github.com/rust-lang/futures-rs/blob/92c78c2b985e9b713c658d4d65c84e2688788b87/futures-util/src/abortable.rs
[fut-cargo]: https://github.com/rust-lang/futures-rs/blob/92c78c2b985e9b713c658d4d65c84e2688788b87/futures/Cargo.toml
[fut-changelog]: https://github.com/rust-lang/futures-rs/blob/92c78c2b985e9b713c658d4d65c84e2688788b87/CHANGELOG.md
[tk-repo]: https://github.com/tokio-rs/tokio/tree/675ba8164071a6eee3dd1f3cb4fbdc1d3664396e
[tk-select]: https://github.com/tokio-rs/tokio/blob/675ba8164071a6eee3dd1f3cb4fbdc1d3664396e/tokio/src/macros/select.rs
[tk-watch]: https://github.com/tokio-rs/tokio/blob/675ba8164071a6eee3dd1f3cb4fbdc1d3664396e/tokio/src/sync/watch.rs
[tk-sleep]: https://github.com/tokio-rs/tokio/blob/675ba8164071a6eee3dd1f3cb4fbdc1d3664396e/tokio/src/time/sleep.rs
[tk-clock]: https://github.com/tokio-rs/tokio/blob/675ba8164071a6eee3dd1f3cb4fbdc1d3664396e/tokio/src/time/clock.rs
[tk-task]: https://github.com/tokio-rs/tokio/blob/675ba8164071a6eee3dd1f3cb4fbdc1d3664396e/tokio/src/task/mod.rs
[tk-join]: https://github.com/tokio-rs/tokio/blob/675ba8164071a6eee3dd1f3cb4fbdc1d3664396e/tokio/src/runtime/task/join.rs
[tk-blocking]: https://github.com/tokio-rs/tokio/blob/675ba8164071a6eee3dd1f3cb4fbdc1d3664396e/tokio/src/task/blocking.rs
[tk-joinset]: https://github.com/tokio-rs/tokio/blob/675ba8164071a6eee3dd1f3cb4fbdc1d3664396e/tokio/src/task/join_set.rs
[tk-op]: https://github.com/tokio-rs/tokio/blob/675ba8164071a6eee3dd1f3cb4fbdc1d3664396e/tokio/src/runtime/driver/op.rs
[tk-uring]: https://github.com/tokio-rs/tokio/blob/675ba8164071a6eee3dd1f3cb4fbdc1d3664396e/tokio/src/runtime/io/driver/uring.rs
[tk-cfg]: https://github.com/tokio-rs/tokio/blob/675ba8164071a6eee3dd1f3cb4fbdc1d3664396e/tokio/src/macros/cfg.rs
[tk-lib]: https://github.com/tokio-rs/tokio/blob/675ba8164071a6eee3dd1f3cb4fbdc1d3664396e/tokio/src/lib.rs
[tk-macros]: https://github.com/tokio-rs/tokio/blob/675ba8164071a6eee3dd1f3cb4fbdc1d3664396e/tokio-macros/src/lib.rs
[tk-start-paused]: https://github.com/tokio-rs/tokio/blob/675ba8164071a6eee3dd1f3cb4fbdc1d3664396e/tokio/tests/rt_time_start_paused.rs
[tk-cargo]: https://github.com/tokio-rs/tokio/blob/675ba8164071a6eee3dd1f3cb4fbdc1d3664396e/tokio/Cargo.toml
[tk-changelog]: https://github.com/tokio-rs/tokio/blob/675ba8164071a6eee3dd1f3cb4fbdc1d3664396e/tokio/CHANGELOG.md
[ts-ext]: https://github.com/tokio-rs/tokio/blob/675ba8164071a6eee3dd1f3cb4fbdc1d3664396e/tokio-stream/src/stream_ext.rs
[ts-throttle]: https://github.com/tokio-rs/tokio/blob/675ba8164071a6eee3dd1f3cb4fbdc1d3664396e/tokio-stream/src/stream_ext/throttle.rs
[ts-watch]: https://github.com/tokio-rs/tokio/blob/675ba8164071a6eee3dd1f3cb4fbdc1d3664396e/tokio-stream/src/wrappers/watch.rs
[tu-token]: https://github.com/tokio-rs/tokio/blob/675ba8164071a6eee3dd1f3cb4fbdc1d3664396e/tokio-util/src/sync/cancellation_token.rs
[tu-abort]: https://github.com/tokio-rs/tokio/blob/675ba8164071a6eee3dd1f3cb4fbdc1d3664396e/tokio-util/src/task/abort_on_drop.rs
[sg-repo]: https://github.com/Pauan/rust-signals/tree/006adaf5b13870c6cec71a2f00fda0d12f1e3b5d
[sg-readme]: https://github.com/Pauan/rust-signals/blob/006adaf5b13870c6cec71a2f00fda0d12f1e3b5d/README.md
[sg-lib]: https://github.com/Pauan/rust-signals/blob/006adaf5b13870c6cec71a2f00fda0d12f1e3b5d/src/lib.rs
[sg-signal]: https://github.com/Pauan/rust-signals/blob/006adaf5b13870c6cec71a2f00fda0d12f1e3b5d/src/signal/signal.rs
[sg-mutable]: https://github.com/Pauan/rust-signals/blob/006adaf5b13870c6cec71a2f00fda0d12f1e3b5d/src/signal/mutable.rs
[sg-broadcaster]: https://github.com/Pauan/rust-signals/blob/006adaf5b13870c6cec71a2f00fda0d12f1e3b5d/src/signal/broadcaster.rs
[sg-macros]: https://github.com/Pauan/rust-signals/blob/006adaf5b13870c6cec71a2f00fda0d12f1e3b5d/src/signal/macros.rs
[sg-throttle-test]: https://github.com/Pauan/rust-signals/blob/006adaf5b13870c6cec71a2f00fda0d12f1e3b5d/tests/signal/throttle.rs
[sg-test-util]: https://github.com/Pauan/rust-signals/blob/006adaf5b13870c6cec71a2f00fda0d12f1e3b5d/tests/util/mod.rs
[sg-cargo]: https://github.com/Pauan/rust-signals/blob/006adaf5b13870c6cec71a2f00fda0d12f1e3b5d/Cargo.toml
[docs-futures]: https://docs.rs/futures/latest/futures/
[docs-tokio]: https://docs.rs/tokio/latest/tokio/
[docs-tokio-stream]: https://docs.rs/tokio-stream/latest/tokio_stream/
[docs-token]: https://docs.rs/tokio-util/latest/tokio_util/sync/struct.CancellationToken.html
[docs-signals]: https://docs.rs/futures-signals/latest/futures_signals/
[boats-uring]: https://without.boats/blog/io-uring/
[boats-cleanup]: https://without.boats/blog/asynchronous-clean-up/
[rxjs]: ./rxjs.md
[effect-ts]: ./effect-ts.md
[kotlin-flow]: ./kotlin-flow.md
[swift-async]: ./swift-async-algorithms.md
[solid-signals]: ./solid-signals.md
[sodium]: ./sodium.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[async-tokio]: ../async-io/tokio.md
[io-uring]: ../async-io/io-uring/index.md
[cats-effect]: ../algebraic-effects/scala-cats-effect.md
