# C++ senders and receivers (C++, `std::execution`)

The C++26 standard model of asynchronous work: a lazy, typed description of **one** operation
(a _sender_) that completes exactly once on one of three channels — value, error or stopped —
plus counting scopes for dynamic work and a coroutine `task`. It is a single-value model, not a
stream library, and the closest analogue in this [survey][index] to `event-horizon`'s [`Effect`][eh-effect]
and structured [`Scope`][eh-scope].

| Field             | Value                                                                                                                                                                                                                                                       |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | C++26 (the standard); stdexec builds as C++20                                                                                                                                                                                                               |
| License           | ISO standard (wording); stdexec Apache-2.0 with LLVM exception ([`LICENSE.txt`][sx-license]); libunifex Apache-2.0 with LLVM exception                                                                                                                      |
| Repository        | [NVIDIA/stdexec][sx-readme] (reference implementation, `stdexec::` = `std::execution`, `exec::` = extensions); [facebookexperimental/libunifex][ux-concepts] (the predecessor)                                                                              |
| Documentation     | Working draft [[exec]][draft-exec] · [P2300R10][p2300] · [P3149R11][p3149] · [P2079R10][p2079] · [P3552R3][p3552] · [stdexec docs][sx-docs]                                                                                                                 |
| Category          | Single-value lazy asynchronous operations with structured concurrency; streams only as experimental _sequence senders_                                                                                                                                      |
| Versions surveyed | Working draft as served by eel.is on 2026-11-22 (source commit `c7015b48`); P2300R10 (2024-06-28), P3149R11 (2025-06-19), P2079R10 (2025-06-25), P3552R3 (2025-06-20); stdexec `main` @ `f27cd131` (2026-11-21); libunifex `main` @ `894a2c52` (2026-10-16) |
| Core abstraction  | `sender` — `connect(sndr, rcvr)` yields an operation state; `start(op)` runs it; it finishes by calling exactly one of `set_value(rcvr, vs...)`, `set_error(rcvr, e)`, `set_stopped(rcvr)`                                                                  |

> [!NOTE]
> stdexec line references are to commit `f27cd131bc99f5ef04bef6574bd2db919563d997`
> (2026-11-21). The adoption meetings (P2300R10 at St. Louis, June 2024; P3149R11, P2079R10 and
> P3552R3 at Sofia, June 2025) are taken from the papers' dates and the draft's contents, not
> re-verified against plenary minutes. Every algorithm named below as "standard" was checked
> against the [[exec]][draft-exec] table of contents on 2026-11-22.

---

## Overview

### What it solves

C++ had threads, `std::future` and callbacks, and no common vocabulary for "an asynchronous
operation" that a GPU runtime, an `io_uring` loop and a thread pool could all accept. P2300 gives
one: a sender is a value describing work, generic algorithms (`then`, `let_value`, `when_all`)
compose senders into senders, and a scheduler is anything that can produce a sender completing
"on" its execution resource. The motivating requirements are explicit about cancellation; among
P2300R10's priorities ([§1.2][p2300]):

> _"Support cancellation, which is not an error."_

That sentence is the third outcome of [concepts][concepts]' consensus, written into the
foundation: [Effect][effect-ts]'s `Exit`/`Cause` separates interruption from failure inside a
cause tree, while senders give it its own completion function.

C++26 then added what P2300 deliberately left out. [P3149][p3149] supplies scopes for work whose
count is not known statically; [P2079][p2079] a portable parallel thread pool; [P3552][p3552] a
coroutine type.

### Design philosophy

The draft fixes the shape of every operation in [[exec.async.ops]][draft-async-ops] ¶2.3:

> _"once started, eventually completes exactly once with a (possibly empty) set of result datums
> … in exactly one of three dispositions: success, failure, or cancellation."_

and names the three: _"A cancellation completion, also known as a stopped completion, has no
result datum."_ Everything is lazy and statically typed: a sender's possible completions are a
type-level list (its **completion signatures**, ¶13: _"A completion signature is a function type
that describes a completion operation"_), computed from the sender and the receiver's
_environment_ before anything runs. Removing unstructured primitives was a design act: P2300R10's
revision history records that _"ensure_started, start_detached, execute, and
execute_may_block_caller are removed from the proposal"_, _"to be replaced with safer and more
structured APIs"_ by P3149. P3149 states the goal ([§3.2][p3149]):

> _"we need an abstraction that ensures that all async work that is spawned has a defined,
> observable, and controllable lifetime."_

---

## How it works

Three objects and two calls. `connect(sndr, rcvr)` returns an **operation state**, an immovable
object holding everything the run needs (so a whole pipeline is one allocation, or none on the
stack). `start(op)` begins it; the operation later calls one completion function on the receiver.
The receiver also answers `get_env(rcvr)`: a queryable **environment** carrying the stop token
(`get_stop_token`), the current scheduler (`get_scheduler`), an allocator (`get_allocator`) and
more. Queries flow _down_ (from consumer to producer, at `connect` time), completions flow _up_.

```cpp
namespace ex = std::execution;

ex::sender auto work =
    ex::schedule(pool)                           // completes set_value() on a pool thread
  | ex::then([] { return read_config(); })       // set_value(Config); a throw → set_error(exception_ptr)
  | ex::let_value([](Config c) {                 // value → a new sender, started in place
        return ex::when_all(fetch(c.a), fetch(c.b)); })
  | ex::upon_stopped([] { return Pair{}; });     // stopped → a value
auto [a, b] = std::this_thread::sync_wait(std::move(work)).value();
```

Nothing executes until `sync_wait` connects and starts the chain. `stdexec` implements every
algorithm as a `__sexpr` (sender expression: a tag, data, children) whose behaviour lives in a
`__sexpr_impl<Tag>` specialisation; domains (`get_domain`, `transform_sender`) let a GPU or
other backend replace an algorithm wholesale. [`when_all`][sx-when-all] shows the cancellation
plumbing all composite algorithms share: when any child can fail or stop, it owns an
`inplace_stop_source`, gives each child a token from it, and chains the receiver's token to it
([lines 74-76][sx-when-all-l74]):

> _"If any one input can fail or be stopped, `when_all` uses an internal `inplace_stop_source`. An
> unhappy completion requests stop on the other inputs before the combined operation completes."_

---

## Evaluation model

- **Lazy, cold, single-shot.** A sender is a description; each `connect` + `start` is a fresh
  run. There is no hot sender in the standard: the one sharing adaptor, `split`, is not in C++26
  (see [State and sharing](#state-and-sharing)).
- **Push of one completion.** The producer calls the receiver once. There is no "next value", so
  backpressure, conflation and glitch-freedom do not arise in the single-value model.
- **Synchronous unless a scheduler intervenes.** `just(1) | then(f)` completes inside `start`, on
  the caller's stack; asynchrony enters only through a scheduler's `schedule` sender or an I/O
  operation. stdexec's [`trampoline_scheduler`][sx-trampoline] exists to bound the stack depth this
  causes in loops.
- **Streams are outside the standard.** C++26 has no multi-value abstraction. stdexec's
  experimental **sequence senders** ([`exec/sequence_senders.hpp`][sx-seq-senders]) add one: a
  sequence receiver gets `set_next(rcvr, item)` per item, where the item is itself a sender, and
  `set_next` returns a _next-sender_ that _"can complete with `set_value_t()` or
  `set_stopped_t()`"_ ([lines 138-146][sx-seq-setnext]) — so each item is a push whose
  acknowledgement is asynchronous, giving per-item backpressure, and stopping the next-sender is
  how a consumer says "no more". Its predecessor in libunifex was pull-based ([`doc/concepts.md`
  § Streams][ux-concepts]): _"values are produced lazily and on-demand only when the consumer asks
  for the next value by calling a `next()` method that returns a Sender"_.

## Composition

The C++26 surface is about thirty algorithms ([[exec.factories]][draft-exec],
[[exec.adapt]][draft-exec], [[exec.consumers]][draft-exec]):

| Family               | Algorithms                                                                                                    |
| -------------------- | ------------------------------------------------------------------------------------------------------------- |
| Factories            | `schedule`, `just`, `just_error`, `just_stopped`, `read_env`                                                  |
| Value / error / stop | `then`, `upon_error`, `upon_stopped`; `let_value`, `let_error`, `let_stopped` (continuation returns a sender) |
| Channel conversion   | `stopped_as_optional`, `stopped_as_error`, `into_variant`                                                     |
| Context              | `starts_on`, `continues_on`, `schedule_from`, `on`, `write_env`, `unstoppable`, `affine` (coroutines)         |
| Concurrency          | `when_all`, `when_all_with_variant`, `bulk`, `bulk_chunked`, `bulk_unchunked`                                 |
| Scopes               | `associate`, `spawn_future`, `spawn` (consumer); `simple_counting_scope`, `counting_scope`                    |
| Consumers            | `std::this_thread::sync_wait`, `sync_wait_with_variant`                                                       |

`let_value` is monadic bind; `then` is `map`; each channel has both forms, so error recovery and
stop recovery use the same two shapes. stdexec's `exec::` namespace adds the rest of a toolkit:
[`when_any`][sx-when-any] (first completion wins), [`finally`][sx-finally], [`repeat_until`][sx-repeat]
(the old `repeat_effect_until` header is now a deprecation shim, [`repeat_effect_until.hpp`][sx-repeat-old]),
`repeat_n`, [`materialize`/`dematerialize`][sx-materialize] (completions as values), `variant_sender`,
`any_sender_of`, `create`, `fork_join`, and [`exec::sequence`][sx-sequence] — note the name: this
is _serial composition of senders_ (`sequence(a, b)` runs `b` after `a`), not a stream.

The sequence-sender algorithms in [`exec/sequence/`][sx-seq-dir] are few: `iterate` (a range as a
sequence), `transform_each`, `merge`, `merge_each`, `ignore_all_values`, `empty_sequence`,
`any_sequence_of`. There is **no** `switch`/latest-wins, no `scan`, no `distinct`, and no
time-based sequence operator (`interval`, `debounce`, `throttle`): a search of `include/` for
`latest`, `debounce` and `throttle` finds nothing.

---

## Time and scheduling

**C++26 has no time.** No timer, no `schedule_after`, no clock query appears in
[[exec]][draft-exec]; P2079R10 lists it as future work ([§5.5][p2079]: the authors _"expect to add
time-based scheduling, async I/O, priority-based scheduling"_). The standard schedulers are
`run_loop` ([[exec.run.loop]][draft-exec]), `inline_scheduler`, `task_scheduler` (type-erased),
and `parallel_scheduler` from `get_parallel_scheduler()`, which _"implements the
`get_forward_progress_guarantee` query to return `parallel`"_ and whose backend is replaceable at
link time only (P2079R10 §5.3: _"the only remaining option is link-time replaceability"_).

stdexec supplies time as an extension, [`exec/timed_scheduler.hpp`][sx-timed]: a
`timed_scheduler` is a scheduler with `now(sched)` returning a totally ordered time point plus
`schedule_at(sched, tp)` and/or `schedule_after(sched, d)`. If a scheduler has only
`schedule_at`, `schedule_after` falls back to
`let_value(just(), [=] { return schedule_at(sched, now(sched) + d); })`
([lines 231-254][sx-timed-fallback]) — the deadline is computed when the sender _starts_, not when
it is built. Implementations: [`timed_thread_context`][sx-timed-thread] (one thread, an intrusive
heap of deadlines), [`io_uring_context`][sx-io-uring] (`IORING_OP_TIMEOUT`), and the Windows
thread pool.

**Debounce does not exist** in either the standard or stdexec, and needs no operator: a debounce
is `schedule_after(timer, n)` as the first step of a cancellable request, and a newer keystroke
stops it. Because `n` is an ordinary argument read when the request is built (or inside a
`let_value` when it starts), **the interval can change at runtime** with the same two strengths
the [comparison][cmp-debounce] describes: a change applies from the next keystroke, or the
application restarts the pending wait itself. Stopping a pending timer is prompt: on
`timed_thread_context`, the stop callback enqueues a stop command, and the timer thread erases the
operation from its heap and calls `set_stopped` at once ([lines 160-180][sx-timed-stop]).

Moving between execution resources is explicit: `starts_on(sch, s)` starts `s` on `sch`;
`continues_on(s, sch)` delivers `s`'s completion on `sch`; `on(sch, s)` runs `s` on `sch` and
returns to the starting scheduler. A per-frame UI has a gap here: the standard `run_loop` has only
`run()` (process items _"until the finishing flag is set"_) and `finish()`
([`__run_loop.hpp` lines 63-92][sx-run-loop]). There is no non-blocking "drain what is ready",
so a frame loop that owns its thread cannot pump it between frames; it needs its own scheduler.

---

## Concurrency and cancellation

**Cancellation is cooperative and travels through environments.** A receiver's environment
carries a stop token (`std::stop_token`, the allocation-free `inplace_stop_token`, or
`never_stop_token`, all modelling `stoppable_token`, [`stop_token.hpp`][sx-stop-token]). An
operation that can be cancelled registers a stop callback (`inplace_stop_callback`) on the token at
`start`, and answers a stop request by completing with `set_stopped`. Nothing preempts: a CPU loop
must read the token itself. `unstoppable(s)` gives `s` a `never_stop_token`, the analogue of
`event-horizon`'s `protect` ([`scope_.d`][eh-scope]).

**The composite algorithms cancel and join.** `when_all` requests stop on its siblings after the
first error or stopped completion and completes only when every child has arrived: in
[[exec.when.all]][draft-when-all] each child completion calls `arrive`, and only `0 == --count`
completes downstream; stdexec documents it as _"At most one completion is delivered to the
downstream receiver … the internal stop source is signalled so the remaining children can wind
down promptly"_ ([lines 134-148][sx-when-all-l134]). stdexec's `exec::when_any` is the race: the
first completion of any kind is stored, `__stop_source_.request_stop()` stops the rest, and the
result is forwarded only when the count of arrived children reaches zero
([lines 112-135][sx-when-any-l112]). Both are **cancel-and-join by construction** — an operation
state cannot be destroyed while a child still runs, so no composite can return early. This is
`event-horizon`'s [`race`][eh-schedule] exactly: _"the first to reach a terminal state wins; the
rest are cancelled (`InterruptKind.raceLost`) and joined."_

**Latest-wins has no primitive.** There is no `switch` in the standard or in stdexec; the
sequence algorithms have `merge_each` but nothing that cancels the previous inner. It is built
from a counting scope and one `inplace_stop_source` per request:

1. `counting_scope` owns the requests' lifetime. `spawn(sndr, scope.get_token())` heap-allocates
   the operation, associates it and starts it; `scope.join()` is a sender that completes when the
   association count reaches zero; `scope.request_stop()` _"Requests stop on the scope's internal
   stop source"_ ([P3149R11 §5.7.5][p3149]), whose token every associated sender sees because a
   `counting_scope` token's `wrap` makes the operation _"receive stop requests from both the
   connected receiver and the stop source in the token's `counting_scope`"_ (§5.7.7).
2. A request is `write_env(work, prop(get_stop_token, src.get_token()))`; a newer request calls
   `src.request_stop()` on the old one and spawns itself. This is **cancel-and-forget**: the new
   request starts at once, and the scope's `join` collects the stragglers later.
3. **Cancel-and-join** is expressible because a finished request is a sender: keep the previous
   request as a `spawn_future` sender and start the next one after it,
   `upon_stopped(std::move(prev), []() noexcept {}) | let_value(next)`. A `spawn_future` sender
   that is dropped unconnected is _"abandoned"_ and _"a stop request is sent to the running"_
   operation ([P3149R11][p3149]), so the future also doubles as a cancel handle.

> [!WARNING]
> `write_env` replaces the stop token rather than fusing it: stdexec queries the child's
> environment as `__join(__env2_, __env)`, written environment first
> ([`__write_env.hpp` lines 48-54][sx-write-env]). Writing a per-request token therefore hides the
> scope's token from the work beneath it, and `scope.request_stop()` no longer reaches that work.
> The fusing adaptor the standard uses internally, _stop-when_ ([[exec.stop.when]][draft-exec]),
> is exposition-only; stdexec exposes it only as `__stop_when` ([`__stop_when.hpp`][sx-stop-when]).
> Shutdown must therefore stop the current request's source as well as the scope.

**CPU-bound work** goes to `get_parallel_scheduler()` (or stdexec's
[`static_thread_pool`][sx-pool]) through `starts_on`, and observes cancellation by reading the
token from its environment (`read_env(get_stop_token)`, or `co_await` of it in a `task`).

**Does a cancel wait?** Inside one sender tree, always: `when_all`, `when_any`, `let_value` and
`task` complete only after their children. Across spawned requests, it is the application's
choice — forget by default, join by sequencing on a `spawn_future` — and the scope's `join` waits
for everything at teardown. A scope's destructor does not wait: per
[[exec.simple.counting.ctor]][draft-scopes], _"If state is not one of joined, unused, or unused-and-closed, invokes
terminate."_

## Errors and completion

The error channel is typed: `set_error(rcvr, e)` carries one datum of any type, and a sender's
completion signatures list every error type it can produce. `std::exception_ptr` appears whenever
something may throw (`then` with a throwing function, a throwing decay-copy in `when_all`); a
pipeline that is `noexcept` throughout has no exception channel at all. There is no
`std::expected` interop in the standard; stdexec has no `std::expected` mention under `include/`
either. The bridges are generic: `let_error` / `upon_error` turn errors into values, and stdexec's
[`materialize`][sx-materialize] lifts every completion into `set_value(tag, args...)`.

`set_stopped` is neither value nor error, and stays so through every algorithm unless converted:
`stopped_as_optional` maps stopped to an empty `optional`, `stopped_as_error(e)` maps it to an
error, `upon_stopped`/`let_stopped` recover from it. `sync_wait` returns an empty `optional` for a
stopped run. `spawn` _requires_ a sender that cannot fail — _"`spawn` cannot deliver an error to a
non-existent caller"_ ([`__spawn.hpp` lines 172-182][sx-spawn]) — and discards values and
stopped. So every spawned request must handle its errors inside, and a superseded request that
ends `set_stopped` is silently and correctly dropped: the right default for latest-wins.

`task` ([P3552R3][p3552]) maps the channels onto coroutines: `co_await` of a sender that
completes with an error throws it; one that completes stopped never resumes the coroutine and the
task itself completes `set_stopped`; `co_yield with_error{e}` reports an error without throwing;
`co_await just_stopped()` cancels the task from inside.

## State and sharing

**No value cell, no multicast, in C++26.** A sender has one consumer. P2300's sharing adaptor,
`split`, and its eager cousin `ensure_started` are absent from the draft
([[exec]][draft-exec] has neither `[exec.split]` nor `[exec.ensure.started]`): `ensure_started`
was removed by P2300R10 itself, and `split` by [P3682R0][p3682] ("Remove `std::execution::split`",
2025-05-05), which cites its shared state's dynamic allocation and the eagerness it acquires once
a first consumer starts it. stdexec moved all three to the extension namespace and left
deprecated aliases: _"Include `exec/split.hpp` and use `exec::split` instead"_
([`__deprecations.hpp` lines 83-102][sx-deprecations]); [`exec/split.hpp`][sx-split],
[`exec/ensure_started.hpp`][sx-ensure-started], [`exec/start_detached.hpp`][sx-start-detached].
`spawn_future` replaces `ensure_started`: an eagerly started operation whose single result is
consumed through a sender.

`split` shares _one_ result among several consumers, which is a promise, not a cell. A value cell
for the query, the interval or the toggle has to come from outside — an atomic, a mutex-guarded
value — and so does the delivery of a result to the UI.

## Lifetime and ownership

Lifetime is structural at two levels. Within a tree, the operation state owns every child's
state, and the child must complete before the parent does, so lifetimes nest by construction —
the [structured concurrency][concepts-scopes] of a single expression. For dynamic work,
`simple_counting_scope` and `counting_scope` ([[exec.counting.scopes]][draft-scopes]) count
associations through the states _unused_, _open_, _closed_, _open-and-joining_,
_closed-and-joining_, _unused-and-closed_ and _joined_. `close()` makes later associations fail —
a closed scope's `spawn` _"destroys the state and returns without starting the operation"_
([`__spawn.hpp`][sx-spawn]) — and `join()` completes on the scheduler from the receiver's
`get_start_scheduler`, so stdexec refuses to join without one
(`_JOINING_A_COUNTING_SCOPE_NEEDS_A_SCHEDULER_IN_THE_ENVIRONMENT_`,
[`__counting_scopes.hpp`][sx-scopes]). `counting_scope` adds `request_stop()`;
`simple_counting_scope` cannot cancel. stdexec's older [`exec::async_scope`][sx-async-scope]
(`spawn`, `spawn_future`, `nest`, `on_empty`, `request_stop`) is the pre-P3149 design, itself
descended from libunifex's [`async_scope`][ux-async-scope].

Leaks are impossible to ignore: an unjoined scope's destructor terminates. The cost is that
teardown must be asynchronous (`sync_wait(scope.join())` on the owning thread), which a UI
application has to schedule at shutdown.

## Testing

**No virtual time.** The standard has no clock, so it has no test clock; stdexec ships none
either (no `TestClock`, manual clock or virtual-time scheduler under `include/` or `test/`).
Determinism comes from three places:

- `sync_wait` over `run_loop`: a pipeline with only inline and `run_loop` scheduling runs on the
  calling thread, in order.
- stdexec's test-only [`impulse_scheduler`][sx-test-sched]: _"Until the scheduler is told to
  start the next operation, the actions in the operation states are not executed"_
  ([lines 62-69][sx-test-sched-l62]); a test steps it with `start_next()`. It controls _order_, not
  time.
- The `timed_scheduler` concept is small enough to fake. A virtual-time scheduler is `now()`
  returning a test-controlled time point plus `schedule_at` inserting into a heap that `advance`
  drains; stdexec's own [fallback test][sx-timed-test] builds a scheduler whose `now()` returns
  `{}`. Nothing in the library helps with the [recurring trap][cmp-time]: the parallel scheduler
  is replaceable only at link time, so the hash cannot be put under a test clock except by
  injecting the scheduler.

Cancellation semantics, by contrast, are tested thoroughly:
[`test_counting_scopes.cpp`][sx-test-scopes] has _"counting_scope::request_stop signals associated
senders"_, and [`test_when_any.cpp`][sx-test-when-any] _"when_any forwards stop signal"_.

---

## The worked pipeline

The frame rebuilds the widget tree and compares the three inputs with the values it last acted
on; the pipeline is driven from those comparisons. `ui_post` (a mutex-guarded mailbox plus the
host's wake call) is the application's own code: no standard scheduler can be pumped per frame.

```cpp
namespace ex = std::execution;

struct Pipeline {
  exec::timed_thread_context timers;                // stdexec extension: no timers in C++26
  ex::counting_scope         scope;                 // owns every request
  struct Request { ex::inplace_stop_source stop; std::uint64_t gen = 0; };
  std::shared_ptr<Request>   current;               // UI thread only
  std::uint64_t              gen = 0;

  // One request: debounce, hash on the pool, publish. Cannot fail (spawn requires it).
  // `req` is captured so the stop source outlives the operation (the token does not own it).
  ex::sender auto request(std::string q, std::chrono::milliseconds n, std::shared_ptr<Request> req) {
    auto g = req->gen;
    return exec::schedule_after(timers.get_scheduler(), n)          // stop → set_stopped at once
         | ex::let_value([q] { return ex::starts_on(ex::get_parallel_scheduler(), hash_task(q)); })
         | ex::then([g](Digest d) noexcept { ui_post(Done{g, d}); })
         | ex::upon_error([g, req](std::exception_ptr e) noexcept { ui_post(Failed{g, e}); });
         // set_stopped passes through; spawn discards it: a superseded request is silent
  }

  void restart(std::string q, std::chrono::milliseconds n) {       // keystroke, interval change
    cancel();
    current = std::make_shared<Request>();
    current->gen = ++gen;
    ex::spawn(ex::write_env(request(std::move(q), n, current),
                            ex::prop(ex::get_stop_token, current->stop.get_token())),
              scope.get_token());
  }
  void cancel() { if (current) current->stop.request_stop(); current.reset(); } // toggle off
  ~Pipeline() { cancel(); scope.close(); std::this_thread::sync_wait(scope.join()); }
};

ex::task<Digest> hash_task(std::string q) {                        // P3552: std::execution::task
  auto tok = co_await ex::read_env(ex::get_stop_token);
  Blake3 h;
  for (auto& file : walk(q)) {
    if (tok.stop_requested()) co_await ex::just_stopped();         // cancellation point per file
    h.update(read(file));
  }
  co_return h.digest();
}
```

The frame applies a `Done`/`Failed` only if its `gen` equals the current generation, because a
hash that finishes in the instant before `request_stop` still posts. The `shared_ptr` captured in
the last lambda is load-bearing: the lambdas live in the operation state until the operation
completes, and `inplace_stop_token` does not own its source, so without it `cancel()`'s `reset`
would free a source that the running `hash_task` still reads. That `co_await
ex::read_env(ex::get_stop_token)` yields the task's token follows P3552R3's environment wording;
it was not compiled for this survey.

> [!WARNING]
> The sketch is illustrative C++, not compiled against stdexec. In particular, a `let_value`
> continuation that returns `starts_on(…, task)` gives the task the parallel scheduler as its
> start scheduler; P3552's scheduler affinity then resumes it there after every `co_await`.

Per-event trace (times in ms; `n = 300`):

1. **Keystroke during debounce.** At t=0 `restart("a")` spawns request 1, whose
   `schedule_after` registers a deadline at 300 on the timer thread and a stop callback on
   request 1's token. At t=200 the frame sees `"ab"` and calls `restart`: `request_stop` runs the
   callback, which enqueues a stop command; the timer thread erases the deadline and calls
   `set_stopped`. `let_value`, `then` and `upon_error` are skipped, the stopped completion reaches
   `spawn`'s receiver, which frees the operation and drops the association. Request 2 was spawned
   immediately, without waiting, and arms its own deadline at 500.
2. **Keystroke during hash.** At t=500 the deadline fires; `let_value` starts `hash_task("ab")`
   on the parallel scheduler. A keystroke at t=700 stops request 2's source: the hash sees
   `stop_requested()` at its next file boundary, `co_await just_stopped()` completes the task
   `set_stopped`, and the result is never posted. Request 3's debounce already started at t=700:
   **cancel-and-forget**, so at most one file's worth of CPU overlaps. The keystroke cancels the
   hash at once, not _n_ later, because the debounce sits inside the request. For
   **cancel-and-join**, `restart` keeps request 2 as `spawn_future(...)` and spawns
   `upon_stopped(std::move(prev), []() noexcept {}) | let_value([=] { return request(q, n, g); })`.
3. **Interval change.** The new `n` is an argument, read when `restart` builds the request.
   Either the frame calls `restart` on an interval change (the pending wait restarts with the new
   length, at the cost of re-hashing an unchanged query if a hash was running), or it does
   nothing and the next keystroke uses the new value.
4. **Toggle off.** `cancel()`: a pending debounce completes `set_stopped` promptly on the timer
   thread; an in-flight hash stops at its next file. Nothing joins at this point — the scope does,
   at shutdown, in `~Pipeline`. Toggling on calls `restart` with the current query.

**Against `event-horizon`.** The two models line up almost term for term; the differences are
where the design choices are.

| Senders (`std::execution` + stdexec)                | `event-horizon`                                                       | Difference                                                                                   |
| --------------------------------------------------- | --------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| sender (lazy, typed, single completion)             | [`Effect`][eh-effect] (lazy node tree, compile-time fold)             | both are values interpreted at run; senders are interpreted by `connect` into one op state   |
| `set_value` / `set_error` / `set_stopped`           | `Outcome!(T, E)`: value, or a `Cause` of `fail` / `die` / interrupt   | stopped is a separate channel, not a cause kind; no `die` (defects are exceptions)           |
| `then`, `let_value`, `when_all`                     | `map`, `andThen`, `zipPar`                                            | same shapes; senders add per-channel `upon_*` / `let_*`                                      |
| `exec::when_any` (cancel-and-join)                  | [`race`][eh-schedule] (cancelled with `raceLost`, joined)             | identical rule                                                                               |
| `counting_scope`, `spawn`, `join`, `request_stop`   | [`Scope`][eh-scope]: `spawn`, `cancel`, `withScope` (join on exit)    | `event-horizon` joins lexically on exit; a counting scope joins when told, terminates if not |
| stop token in the receiver's environment            | interrupt on the fiber, observed at checkpoints (`checkCancellation`) | explicit token vs. ambient fiber state                                                       |
| `unstoppable`                                       | `protect`                                                             | same                                                                                         |
| `exec::schedule_after` on a `timed_scheduler`       | `sleep`, `withDeadline` over the [`clock`][eh-clock] capability       | `event-horizon` has a clock capability and `TestClock`; C++26 has no time                    |
| (none)                                              | [`TestClock`][eh-clock] `advance` / `advanceToNext`                   | `event-horizon` is ahead                                                                     |
| (none) — latest-wins built from scope + stop source | (none) — hand-written                                                 | the shared gap                                                                               |

**Fit for a per-frame UI.** Good where the UI drives: comparing inputs each frame and calling
`restart`/`cancel` is natural, and a request is an allocation-light value. Poor where results
return: there is no frame-pumpable scheduler and no value cell, so the delivery mailbox, the wake
and the generation check are application code, and so is the lifetime discipline for stop
sources.

---

## Strengths

- Interruption as a third outcome is in the type of every operation, from the standard down.
- Composites are cancel-and-join by construction; no algorithm can leak a running child.
- Errors are typed per sender; a `noexcept` pipeline has no exception channel to handle.
- Operation states make a whole pipeline one allocation (or none); `spawn` is the only
  routine heap allocation.
- Environments give cancellation, scheduler and allocator one uniform, statically checked route.
- `counting_scope` makes leaked work a hard error rather than a silent one.

## Weaknesses

- No streams in the standard; sequence senders are experimental and lack switch, time and
  sharing operators.
- No time at all in C++26, hence no debounce, no timeout and no virtual time.
- No latest-wins; building it needs a scope, a stop source per request and a generation check.
- `write_env` shadows rather than fuses stop tokens, and the fusing _stop-when_ is not public.
- Non-owning `inplace_stop_token` makes stop-source lifetime a manual obligation.
- `run_loop` cannot be drained without blocking, so a frame loop needs its own scheduler.
- Template-heavy diagnostics and compile times (stdexec carries dedicated diagnostic types).

## Key design decisions and trade-offs

| Decision                                    | Rationale                                                                | Trade-off                                                                 |
| ------------------------------------------- | ------------------------------------------------------------------------ | ------------------------------------------------------------------------- |
| Three completion channels                   | _"Support cancellation, which is not an error"_ (P2300R10 §1.2)          | every algorithm triples its cases; stopped must be converted at the edges |
| `connect` into an immovable operation state | zero-allocation composition, GPU-friendly                                | operations cannot move; type names grow with the pipeline                 |
| Single value per operation                  | a small, provable core; streams deferred                                 | reactive pipelines need an extension or hand-written loops                |
| Cancellation via environment stop tokens    | explicit, typed, `never_stop_token` costs nothing                        | CPU work polls manually; token lifetime is the caller's problem           |
| Composites join before completing           | structured lifetimes; no dangling children                               | a slow child delays the whole composite                                   |
| Counting scopes, terminate if unjoined      | dynamic work with a defined, observable lifetime (P3149)                 | asynchronous teardown is mandatory                                        |
| `split`/`ensure_started` removed            | shared state allocates and turns eager (P3682R0)                         | no standard multicast; `spawn_future` covers one consumer                 |
| No timers in C++26                          | scheduler vocabulary first; time-based scheduling is future work (P2079) | every application picks an extension; no standard virtual time            |

---

## Sources

- ISO C++ working draft, [[exec]][draft-exec], [[exec.async.ops]][draft-async-ops],
  [[exec.when.all]][draft-when-all], [[exec.counting.scopes]][draft-scopes] (eel.is, read
  2026-11-22).
- [P2300R10 `std::execution`][p2300] (Dominiak, Evtushenko, Baker, Teodorescu, Howes, Shoop,
  Garland, Niebler, Lelbach; 2024-06-28).
- [P3149R11 "async_scope – Creating scopes for non-sequential concurrency"][p3149] (Petersen,
  Wong; 2025-06-19).
- [P2079R10 "Parallel scheduler"][p2079] (Teodorescu, Arutyunyan, Howes, Voss; 2025-06-25).
- [P3552R3 "Add a Coroutine Task Type"][p3552] (Kühl, Nadolski; 2025-06-20).
- [P3682R0 "Remove `std::execution::split`"][p3682] (Leahy; 2025-05-05).
- stdexec at `f27cd131`: [`README.md`][sx-readme], [`__when_all.hpp`][sx-when-all],
  [`when_any.hpp`][sx-when-any], [`__counting_scopes.hpp`][sx-scopes], [`__spawn.hpp`][sx-spawn],
  [`__spawn_future.hpp`][sx-spawn-future], [`__associate.hpp`][sx-associate],
  [`__stop_when.hpp`][sx-stop-when], [`__write_env.hpp`][sx-write-env],
  [`__run_loop.hpp`][sx-run-loop], [`__parallel_scheduler.hpp`][sx-par],
  [`__task.hpp`][sx-task], [`timed_scheduler.hpp`][sx-timed],
  [`timed_thread_scheduler.hpp`][sx-timed-thread], [`sequence_senders.hpp`][sx-seq-senders],
  [`sequence/merge_each.hpp`][sx-merge-each], [`__deprecations.hpp`][sx-deprecations],
  [`test_common/schedulers.hpp`][sx-test-sched].
- libunifex at `894a2c52`: [`doc/concepts.md`][ux-concepts], [`stream_concepts.hpp`][ux-stream],
  [`async_scope.hpp`][ux-async-scope].
- Related: [Kotlin Flow][kotlin-flow] (structured concurrency, cancel-and-join), [fs2][fs2],
  [Effect][effect-ts] (`Exit`/`Cause`), [Eio][alg-eio] (the `Switch` `event-horizon`'s `Scope`
  transcribes), [async I/O][async-io].

<!-- References -->

[index]: ./index.md
[concepts]: ./concepts.md
[concepts-scopes]: ./concepts.md#structured-concurrency-and-scopes
[cmp-debounce]: ./comparison.md#debounce
[cmp-time]: ./comparison.md#virtual-time
[kotlin-flow]: ./kotlin-flow.md
[fs2]: ./fs2.md
[effect-ts]: ./effect-ts.md
[alg-eio]: ../algebraic-effects/ocaml-eio.md
[async-io]: ../async-io/index.md
[eh-effect]: ../../../libs/event-horizon/src/sparkles/event_horizon/effect.d
[eh-scope]: ../../../libs/event-horizon/src/sparkles/event_horizon/scope_.d
[eh-schedule]: ../../../libs/event-horizon/src/sparkles/event_horizon/schedule.d
[eh-clock]: ../../../libs/event-horizon/src/sparkles/event_horizon/clock.d
[draft-exec]: https://eel.is/c++draft/exec
[draft-async-ops]: https://eel.is/c++draft/exec.async.ops
[draft-when-all]: https://eel.is/c++draft/exec.when.all
[draft-scopes]: https://eel.is/c++draft/exec.counting.scopes
[p2300]: https://wg21.link/P2300R10
[p3149]: https://wg21.link/P3149R11
[p2079]: https://wg21.link/P2079R10
[p3552]: https://wg21.link/P3552R3
[p3682]: https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2025/p3682r0.pdf
[sx-docs]: https://nvidia.github.io/stdexec
[sx-readme]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/README.md
[sx-license]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/LICENSE.txt
[sx-when-all]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/stdexec/__detail/__when_all.hpp
[sx-when-all-l74]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/stdexec/__detail/__when_all.hpp#L74-L76
[sx-when-all-l134]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/stdexec/__detail/__when_all.hpp#L134-L148
[sx-when-any]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/exec/when_any.hpp
[sx-when-any-l112]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/exec/when_any.hpp#L112-L135
[sx-scopes]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/stdexec/__detail/__counting_scopes.hpp
[sx-spawn]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/stdexec/__detail/__spawn.hpp#L138-L197
[sx-spawn-future]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/stdexec/__detail/__spawn_future.hpp
[sx-associate]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/stdexec/__detail/__associate.hpp
[sx-stop-when]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/stdexec/__detail/__stop_when.hpp
[sx-write-env]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/stdexec/__detail/__write_env.hpp#L48-L54
[sx-stop-token]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/stdexec/stop_token.hpp
[sx-run-loop]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/stdexec/__detail/__run_loop.hpp#L63-L92
[sx-par]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/stdexec/__detail/__parallel_scheduler.hpp
[sx-task]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/stdexec/__detail/__task.hpp
[sx-deprecations]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/stdexec/__detail/__deprecations.hpp#L83-L102
[sx-timed]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/exec/timed_scheduler.hpp
[sx-timed-fallback]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/exec/timed_scheduler.hpp#L231-L254
[sx-timed-thread]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/exec/timed_thread_scheduler.hpp
[sx-timed-stop]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/exec/timed_thread_scheduler.hpp#L160-L180
[sx-io-uring]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/exec/linux/io_uring_context.hpp
[sx-pool]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/exec/static_thread_pool.hpp
[sx-trampoline]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/exec/trampoline_scheduler.hpp
[sx-finally]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/exec/finally.hpp
[sx-repeat]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/exec/repeat_until.hpp
[sx-repeat-old]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/exec/repeat_effect_until.hpp
[sx-materialize]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/exec/materialize.hpp
[sx-sequence]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/exec/sequence.hpp
[sx-seq-senders]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/exec/sequence_senders.hpp
[sx-seq-setnext]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/exec/sequence_senders.hpp#L138-L146
[sx-seq-dir]: https://github.com/NVIDIA/stdexec/tree/f27cd131bc99f5ef04bef6574bd2db919563d997/include/exec/sequence
[sx-merge-each]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/exec/sequence/merge_each.hpp
[sx-split]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/exec/split.hpp
[sx-ensure-started]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/exec/ensure_started.hpp
[sx-start-detached]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/exec/start_detached.hpp
[sx-async-scope]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/include/exec/async_scope.hpp
[sx-test-sched]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/test/test_common/schedulers.hpp
[sx-test-sched-l62]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/test/test_common/schedulers.hpp#L62-L69
[sx-timed-test]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/test/exec/test_timed_scheduler_fallback.cpp
[sx-test-scopes]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/test/stdexec/types/test_counting_scopes.cpp
[sx-test-when-any]: https://github.com/NVIDIA/stdexec/blob/f27cd131bc99f5ef04bef6574bd2db919563d997/test/exec/test_when_any.cpp
[ux-concepts]: https://github.com/facebookexperimental/libunifex/blob/894a2c52ccc40b0849cc36055c2172d661855187/doc/concepts.md#streams
[ux-stream]: https://github.com/facebookexperimental/libunifex/blob/894a2c52ccc40b0849cc36055c2172d661855187/include/unifex/stream_concepts.hpp
[ux-async-scope]: https://github.com/facebookexperimental/libunifex/blob/894a2c52ccc40b0849cc36055c2172d661855187/include/unifex/async_scope.hpp
