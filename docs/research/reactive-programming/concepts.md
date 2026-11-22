# Concepts

The vocabulary the [reactive-programming deep-dives][index] share. Each term is
defined once here, with the subjects that show it best; the
[comparison][comparison] uses these terms without redefining them.

**Last reviewed:** November 22, 2026

---

## Evaluation models

### Push

The producer calls the consumer with each value. Nothing paces the producer, so a
slow consumer either buffers or drops. [RxJS][rxjs]'s `Observable` is the reference
push design: a function from an `Observer` to a teardown. [Sodium][sodium]'s
`Stream` and [Elm][elm]'s pre-0.17 `Signal` are push too.

### Pull

The consumer asks for the next value, and the producer runs only when asked.
Pulling gives **backpressure** for free (see [below](#backpressure)).
[Effect][effect-ts] and [fs2][fs2] pull in chunks; [Swift][swift-async-algorithms]'s
`AsyncSequence` pulls one element per `await next()`; [Rust][rust-streams]'s `Stream`
is polled, a `Waker` saying when to poll again.

### Push-pull

Invalidation is pushed and values are pulled: a write marks its dependents stale,
and a stale node recomputes only when it is read. This is the signal algorithm
shared by [Solid][solid-signals], [TC39 Signals][tc39-signals] and
[Angular][angular-signals]. It is what makes an unread derivation free.

### Cold and hot

A **cold** source starts its producer once per subscriber, so two subscribers see
two independent runs (RxJS 7's default `Observable`, every Effect `Stream`). A
**hot** source exists before anyone subscribes and shares one producer among its
subscribers (a `Subject`, a `PubSub`, a `SharedFlow`). RxJS 9 makes the shared form
the default. No surveyed library puts the distinction in the type; every one lists
the confusion among its pitfalls.

### Unicast and multicast

A **unicast** source delivers each value to one consumer (a `Channel`, a queue). A
**multicast** source delivers each value to every subscriber (a `Subject`, a
`Topic`, a `SharedFlow`). `event-horizon`'s [`Channel`][eh-channel] is unicast.

---

## Values over time

### Event stream

A sequence of discrete occurrences, each meaningful on its own: keystrokes, clicks,
completed downloads. Dropping one loses information. Sodium calls it `Stream`, Elm
calls it a message.

### Value cell

A value that exists at every instant and changes: the query text, a toggle, an
interval. Only its current value matters, so intermediate values may be skipped.
Names vary: `BehaviorSubject` (RxJS), `SubscriptionRef` (Effect), `StateFlow`
(Kotlin), `watch` / `Mutable` (Rust), `SignallingRef` (fs2), `Cell` (Sodium),
`MutableState` (Compose), a signal (Solid, TC39, Angular). Classical FRP calls it a
**behaviour**.

### Conflation

Collapsing a burst of updates into the latest one. A value cell may conflate; an
event stream must not. [Compose][jetpack-compose] states it as a principle
("events must not be modelled as state"), and `StateFlow` conflates by definition.

### Derived value

A value computed from other values and kept up to date: `computed`, `createMemo`,
`derivedStateOf`, `lift`, `combine`. A derived value is **lazy** when it recomputes
only on read (push-pull) and **eager** when every change recomputes it (push).

### Glitch and glitch-freedom

A **glitch** is an observable inconsistent state: a derived value computed from a
mix of new and old inputs. The classic case is a diamond, where one source feeds
two branches that are combined again. Push-pull signals avoid glitches by pulling in
dependency order ([Solid][solid-signals]'s height heap, [Angular][angular-signals]'s
versions), Sodium by a rank-ordered queue inside a [transaction](#transaction),
Compose by snapshot isolation. `combineLatest` in RxJS and `combine` in Kotlin can
glitch.

### Transaction

A unit of change inside which every read sees one consistent snapshot. In
[Sodium][sodium], every `hold` commits together at the end of a transaction, so one
transaction is one instant of logical time. A UI frame can be one transaction.

---

## Rate control

### Debounce

Emit a value only after the source has been quiet for _N_; each new value restarts
the wait. This is the _trailing_ debounce a search field wants. Several libraries
ship an operator called `debounce` that is something else: [fs2][fs2]'s fires _N_
after the **first** value of a burst, which is [audit](#throttle-audit-sample).

### Throttle, audit, sample

**Throttle** passes a value and then ignores the source for _N_. **Audit** waits
_N_ after the first value of a burst and emits the latest. **Sample** emits the
latest value at each tick of another source. All three bound the rate; none waits
for quiet.

### Backpressure

A consumer limiting how fast a producer may send. A pull model has it inherently.
Push models replace it with lossy rate control or unbounded buffers. The
[Reactive Streams][reactive-streams] `request(n)` protocol adds it to push.

---

## Concurrency and cancellation

### Latest wins

When a new value arrives, abandon the work started for the previous one and start
the work for the new one. The operator is `switchMap`, `flatMapLatest`,
`transformLatest` or `map_future`; the UI form is a keyed effect that restarts
(`LaunchedEffect(key)`, `.task(id:)`); the control-flow form is a race (`par/or`).
Abandoning can mean two different things:

- **Cancel**: the abandoned work is told to stop.
- **Discard**: the abandoned work runs to the end and its result is ignored,
  usually by comparing a **generation** counter or request id.

### Cancel-and-join and cancel-and-forget

A **cancel-and-join** waits until the cancelled work has finished, finalizers
included, before starting the replacement ([Kotlin][kotlin-flow]'s
`transformLatest`, [fs2][fs2]'s `switchMap`, [Effect][effect-ts]'s `switchMap`). A
**cancel-and-forget** starts the replacement at once, and the two overlap until the
cancelled work notices ([RxJS][rxjs], [Swift][swift-async-algorithms],
[Compose][jetpack-compose], [Angular][angular-signals], [Rust][rust-streams]).
Joining serialises resource use; forgetting minimises latency. In
[C++ senders][cpp-senders-receivers] the composite algorithms (`when_all`,
`exec::when_any`) join by construction.

### Completion channels

The ways one asynchronous operation can end. [C++ senders][cpp-senders-receivers]
define three, and every operation completes on exactly one of them once:
`set_value` (success), `set_error` (failure) and `set_stopped` (cancellation, which
"is not an error"). [Effect][effect-ts]'s `Exit` carries the same three cases,
interruption sitting in its `Cause`. A latest-wins design needs the third channel,
so that a superseded run is neither a result nor an error.

### Structured concurrency and scopes

Concurrent work is owned by a lexical scope that does not exit until its children
have finished, and cancelling a scope cancels its children. Kotlin's
`CoroutineScope`, cats-effect's fibers, Effect's `Scope`, C++26's `counting_scope`
([C++ senders][cpp-senders-receivers]) and `event-horizon`'s
[`Scope`][eh-scope] are scopes; RxJS subscriptions and unstructured Swift `Task`s are
not. [Céu][synchronous-languages]'s `par/or` is the lexical form: the losing trail
is aborted when the block ends.

### Cooperative cancellation and cancellation points

No surveyed runtime preempts running code. Cancellation sets a flag that the work
observes at a **cancellation point**: a suspension (sleep, I/O, channel), an
explicit check (`ensureActive`, `Task.checkCancellation`,
[`interruptRequested`][eh-cause]), or a chunk boundary in a chunked loop
([fs2][fs2]'s `Files.readAll` reads 64 KiB per step). CPU-bound work with no such
point runs to the end.

### Cancellation safety

A future or operation is **cancel-safe** when abandoning it at a cancellation point
loses nothing. The term is [Rust][rust-streams]'s, where dropping a future is how it
is cancelled. On a completion-based loop the hard case is an operation the kernel
still owns: its buffers must stay alive until the completion arrives.

### Finalizer

Code that runs when a scope or subscription ends, however it ends: teardown in
RxJS, `onFinalize`/`bracket` in fs2, `Scope` finalizers in Effect, `onCleanup` in
Solid, `finalize` in Céu, `DisposableEffect`'s `onDispose` in Compose.

---

## Lifetime

### Owner and liveness

What keeps a reactive node alive. Signals keep **live** edges only to watched
consumers, so an unwatched derivation is garbage ([TC39][tc39-signals],
[Angular][angular-signals]); Solid owns nodes in an **owner tree** disposed from the
root; Sodium relies on weak references and finalizers. Without a garbage collector,
liveness has to be ownership by a scope.

### Structural lifetime

Declaring which work should be running as a pure function of state, and letting the
runtime start and stop it when the declaration changes: Elm's
`subscriptions model`, Compose's `if (enabled) LaunchedEffect(…)`, SwiftUI's
`.task(id:)`. The runtime diffs the declaration each frame.

---

## Time and testing

### Virtual time

A clock that advances only when the test says so, so a debounce of 500 ms is tested
by advancing 500 ms rather than sleeping. RxJS 7's `TestScheduler`, Effect's
`TestClock`, Kotlin's `runTest`, fs2's `TestControl`, tokio's `pause` and Compose's
`MainTestClock` all provide it, and `event-horizon` has a [`TestClock`][eh-clock]. The
recurring trap is work that escapes it: a CPU dispatcher or timer not routed through
the virtual clock.

### Frame

One pass of a UI loop: input, update, build, paint. Several models give the frame a
reactive meaning: one [transaction](#transaction) (Sodium), one reaction
(Esterel/Céu), one change-detection tick (Angular), one recomposition (Compose).

<!-- References -->

[index]: ./index.md
[comparison]: ./comparison.md
[rxjs]: ./rxjs.md
[effect-ts]: ./effect-ts.md
[kotlin-flow]: ./kotlin-flow.md
[swift-async-algorithms]: ./swift-async-algorithms.md
[rust-streams]: ./rust-streams.md
[fs2]: ./fs2.md
[solid-signals]: ./solid-signals.md
[tc39-signals]: ./tc39-signals.md
[angular-signals]: ./angular-signals.md
[jetpack-compose]: ./jetpack-compose.md
[sodium]: ./sodium.md
[elm]: ./elm.md
[synchronous-languages]: ./synchronous-languages.md
[cpp-senders-receivers]: ./cpp-senders-receivers.md
[reactive-streams]: https://www.reactive-streams.org/
[eh-channel]: ../../../libs/event-horizon/src/sparkles/event_horizon/channel.d
[eh-scope]: ../../../libs/event-horizon/src/sparkles/event_horizon/scope_.d
[eh-cause]: ../../../libs/event-horizon/src/sparkles/event_horizon/cause.d
[eh-clock]: ../../../libs/event-horizon/src/sparkles/event_horizon/clock.d
