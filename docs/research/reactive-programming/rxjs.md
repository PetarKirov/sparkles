# RxJS (TypeScript)

The reference push-based reactive-streams library for JavaScript: a lazy `Observable` of zero-to-infinite values, ~115 pipeable operators, pluggable `Scheduler`s with a virtual clock, and a disposable `Subscription` tree, now being rebuilt in 9.0 on top of the web-platform `Observable` with `AbortSignal` cancellation.

| Field             | Value                                                                                                                                                                         |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | TypeScript (ships JavaScript; 7.x as CJS + ESM, 9.x ESM-only)                                                                                                                 |
| License           | Apache-2.0 ([`LICENSE.txt`][v7-license], [`package.json`][v7-package])                                                                                                        |
| Repository        | [ReactiveX/rxjs][repo]                                                                                                                                                        |
| Documentation     | rxjs.dev, rendered from [`docs_app/content/guide/`][g-observable] at 7.8.2; 9.x docs live beside each package ([`README.md`][v9-readme])                                      |
| Category          | push-based reactive streams                                                                                                                                                   |
| Versions surveyed | **7.8.2** (stable `latest`, commit `e5351d02e225`, 2025-02-21) and **9.0.0-beta.0** (`master`, commit `60d632c3878d`, 2026-11-18; [`packages/rxjs/package.json`][v9-package]) |
| Core abstraction  | `Observable<T>`: a lazy function from an `Observer` to a teardown; 7.x returns a `Subscription`, 9.x returns `undefined` and is cancelled through an `AbortSignal`            |

> [!NOTE]
> Everything below describes **7.8.2** unless marked **v9**. The 9.0 line is a different
> implementation, not an evolution of the 7.x source tree: the v9 README states the
> beta _"has not been published to npm yet"_ at the surveyed commit. v9 claims are
> verified against `master` source; where a claim rests only on v9 design prose it is
> marked _(design doc)_, and where it could not be verified it is marked _(unverified)_.

---

## Overview

### What it solves

RxJS gives JavaScript a value for "a sequence of events over time" that composes like an array. The guide places it in the missing cell of a two-by-two table ([`observable.md`][g-observable]):

> _"Observables are lazy Push collections of multiple values."_

and, decisively for a library design, insists that the type is _not_ inherently asynchronous:

> _"An **Observable** is a lazily evaluated computation that can synchronously or asynchronously return zero to (potentially) infinite values from the time it's invoked onwards."_

Its sweet spot is exactly the sparkles first-consumer shape: UI events (keystrokes, toggles) fed through time operators (`debounceTime`) into cancellable async work (`switchMap`) and rendered downstream.

### Design philosophy

1. **An Observable is a function, a Subscription is its return value.** `subscribe` runs the producer function once per subscriber ([`observable.md`][g-observable]: _"Each call to `observable.subscribe` triggers its own independent setup for that given subscriber."_). Sharing is opt-in via a `Subject`.
2. **Operators are pure functions of Observables.** [`core-semantics.md`][g-core] makes this normative for v8+: an operator _"MUST be a function that returns an operator function. That is `(source: Observable<In>) => Observable<Out>`"_ and the returned function _"MUST be referentially transparent"_.
3. **Concurrency is a parameter, not an ambient property.** Every time-based operator takes an optional `SchedulerLike` and picks a default by _"the principle of least concurrency"_ ([`scheduler.md`][g-scheduler]).
4. **v9: extend the platform, do not compete with it.** [`DECISIONS.md`][v9-decisions] D-001: _"RxJS should extend the platform primitive rather than ship a competing Observable identity."_ Operators become `unique symbol` keys installed on `Observable.prototype` (`source[map](f)`), schedulers disappear, and cancellation is `AbortSignal`.

Within this survey RxJS is the canonical _push, operator-algebra_ data point. Contrast it with [Effect-TS][effect-ts] (pull-based `Stream` over a fiber runtime with typed errors) and [Solid signals][solid-signals] (glitch-free synchronous dependency graph); vocabulary is in [Concepts][concepts], the cross-cut in [Comparison][comparison].

---

## How it works

### The four objects

| Concept       | Type (7.8.2)                               | Role                                                                                                                   |
| ------------- | ------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------- |
| Producer      | `Observable<T>` ([source][observable-ts])  | Holds a `_subscribe` function (or a `source` + `operator` pair after `lift`)                                           |
| Consumer      | `Observer<T>`                              | Plain `{ next, error, complete }` record                                                                               |
| Glue          | `Subscriber<T>` ([source][subscriber-ts])  | Wraps an `Observer`; is itself a `Subscription`; enforces the "no notifications after a terminal" rule via `isStopped` |
| Disposable    | `Subscription` ([source][subscription-ts]) | A tree node: `closed`, `_parentage`, `_finalizers`; `unsubscribe()` is idempotent                                      |
| Multicast hub | `Subject<T>` ([source][subject-ts])        | Both `Observable` and `Observer`; keeps an `observers` array                                                           |
| Clock + queue | `SchedulerLike` ([source][scheduler-ts])   | `now()` and `schedule(work, delay, state)` returning a `Subscription`                                                  |

### Subscribing builds a chain of Subscribers

`Observable.subscribe` ([`Observable.ts`][observable-ts]) wraps the observer in a `SafeSubscriber`, then calls `operator.call(subscriber, source)` for a lifted Observable or `_trySubscribe` for a raw one, and `add`s whatever teardown comes back to the subscriber. Every operator is written with `operate` ([`util/lift.ts`][lift-ts]), which hands the operator the downstream `subscriber` and lets it subscribe upstream with an `OperatorSubscriber`.

The single structural trick is in the `Subscriber` constructor ([`Subscriber.ts`][subscriber-ts]):

```ts
// src/internal/Subscriber.ts (7.8.2)
constructor(destination?: Subscriber<any> | Observer<any>) {
  super();
  if (destination) {
    this.destination = destination;
    // Automatically chain subscriptions together here.
    // if destination is a Subscription, then it is a Subscriber.
    if (isSubscription(destination)) {
      destination.add(this);
    }
  }
  // ...
}
```

So each upstream `OperatorSubscriber` is a child finalizer of its downstream `Subscriber`: the Subscription tree mirrors the operator chain, and unsubscribing the last subscriber walks it **downstream → upstream**. `Subscription.unsubscribe` ([`Subscription.ts`][subscription-ts]) marks `closed`, detaches from parents, runs `initialTeardown`, then each `_finalizers` entry **in insertion order**, collecting thrown errors.

### Operators are closures over mutable state

`OperatorSubscriber` ([`OperatorSubscriber.ts`][operator-subscriber-ts]) wraps the operator's `onNext`/`onComplete`/`onError` so that a throw becomes `destination.error(err)`, and runs an `onFinalize` hook once on unsubscribe. An operator's state (a pending value, an inner Subscriber, a counter) lives in `let` bindings inside the `operate` callback — one instance per subscription, which is what makes the operator function itself referentially transparent.

### v9: the platform Observable

In v9 the producer type is the active realm's `Observable` (native, or the conforming fallback in [`packages/observable-polyfill/src/index.ts`][v9-polyfill]). `subscribe()` returns `undefined`; the caller passes `{ signal }` and calls `controller.abort()`; a producer registers cleanup with `subscriber.addTeardown()` ([`MIGRATION.md`][v9-migration]). Operators are Symbols:

```ts
// packages/rxjs/src/switch-map.ts (v9, abridged)
export const switchMap: unique symbol = Symbol('switchMap');
Observable.prototype[switchMap] = switchMapOperator;
// call site: source[switchMap]((q) => hash(q))
```

The platform surface itself already provides `takeUntil`, `map`, `filter`, `take`, `drop`, `flatMap`, `switchMap`, `inspect`, `catch`, `finally` and Promise-returning `forEach`/`first`/`reduce`/… ([`ARCHITECTURE.md`][v9-architecture], "Platform-shaped fallback surface").

---

## Evaluation model

| Axis                | 7.8.2                                                                              | v9                                                                                                                                  |
| ------------------- | ---------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| Push / pull         | Push. The producer calls `next`; there is no demand signal and no backpressure     | Push; same                                                                                                                          |
| Lazy / eager        | Lazy: nothing runs until `subscribe`                                               | Lazy: first observer activates the producer                                                                                         |
| Cold / hot          | Plain `Observable` is cold (producer per subscription); `Subject` is hot           | Platform `Observable` is **ref-counted shared**: concurrent observers join one producer; `ColdObservable` restores per-subscription |
| Unicast / multicast | Unicast by default; multicast only through a `Subject` ([`subject.md`][g-subject]) | Multicast by default for concurrent observers                                                                                       |
| Emission timing     | Synchronous unless a scheduler or host callback intervenes                         | Same                                                                                                                                |
| Glitches            | Yes — no topological ordering across branches                                      | Same                                                                                                                                |

**Cold by default (7.x).** [`subject.md`][g-subject]: _"plain Observables are unicast (each subscribed Observer owns an independent execution of the Observable), Subjects are multicast."_ Two `subscribe` calls on an HTTP Observable issue two requests.

**Shared by default (v9).** [`ARCHITECTURE.md`][v9-architecture] defines the platform lifecycle: _"A first observer starts producer work. Additional observers join that active subscriber. Aborting an observer removes it; when the last observer leaves, the subscriber closes and producer teardown runs. A later observer can start a new producer subscription."_ — i.e. every v9 Observable behaves like a 7.x `share()`. The document refuses the hot/cold label for it and redefines the terms by producer-creation timing only (D-035).

**Synchronous emission.** [`observable.md`][g-observable]: _"Some people claim that Observables are asynchronous. That is not true."_ `of(1, 2, 3).subscribe(f)` calls `f` three times before `subscribe` returns, which is why `Subscriber` must check `isStopped` on every call and why `share` wires its refcount finalizer _"before the subscription to the source occurs ... so that the assignment to the source connection's `closed` property will be seen by synchronous firehose sources"_ ([`share.ts`][share-ts]).

**Glitches.** `combineLatest` ([`observable/combineLatest.ts`][combinelatest-ts]) emits `values.slice()` on _every_ input `next` once each input has produced a first value. In a diamond `a$ → (b$, c$) → combineLatest([b$, c$])`, one `a$` emission produces two outputs, the first pairing the new `b` with the stale `c`. Nothing in the library orders propagation by dependency depth; this is the defining difference from [Solid signals][solid-signals].

---

## Composition

**`pipe` and the operator catalogue.** 7.x composes with `source.pipe(op1, op2, …)`; [`src/operators/index.ts`][operators-index] exports about 115 names (including deprecated aliases such as `flatMap`, `mapTo`, `pluck`) backed by 117 files under `src/internal/operators/`, plus ~30 creation functions under `src/internal/observable/`. v9 drops `.pipe` and the `OperatorFunction` type family ([`UNSUPPORTED_RXJS_7_SURFACES.md`][v9-unsupported]: _"RxJS Next does not publish the RxJS 7 pipeable-function or string-named .pipe surface."_), keeping a `rxjs/pipe` Symbol for deliberate composition.

**The higher-order mapping family** is where the design sense lives — the four operators differ only in what happens to an inner Observable when a new outer value arrives ([`higher-order-observables.md`][g-hoo]):

| Operator     | Policy for a new outer value while an inner is live            | 7.8.2 implementation                                                                                           |
| ------------ | -------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `switchMap`  | Unsubscribe the old inner, subscribe the new one (latest wins) | Own loop: `innerSubscriber?.unsubscribe()` then `project(value)` ([source][switchmap-ts])                      |
| `mergeMap`   | Run concurrently, up to `concurrent` (default `Infinity`)      | `mergeInternals`: `active < concurrent ? doInnerSub(value) : buffer.push(value)` ([source][mergeinternals-ts]) |
| `concatMap`  | Queue; run one at a time                                       | Literally `mergeMap(project, 1)` ([source][concatmap-ts])                                                      |
| `exhaustMap` | Ignore the new value until the current inner completes         | `if (!innerSub) { … }` ([source][exhaustmap-ts])                                                               |

Two consequences for a D design: `concatMap`'s queue is an **unbounded** `T[]` (`buffer.push`) — the push model has nowhere else to put excess values; and v9 collapses the family further by giving `switchMap` a `concurrent` option ([`switch-map.ts`][v9-switchmap]: `const { concurrent = 1 } = options ?? {};`, evicting the oldest `AbortController` when full) and `mergeMap` the same option ([`merge-map.ts`][v9-mergemap]). There is no `concat-map.ts` in v9; the platform `flatMap` is the sequential flattener _(the exact migration target for `concatMap` is unverified)_.

**Derived values.** RxJS has no "computed" primitive. A derived value is an operator chain (`combineLatest`, `withLatestFrom`, `scan`, `map`) and the "current value" of a derivation exists only if a `BehaviorSubject` or `shareReplay(1)` is placed at the end. Operator sprawl is the price of this: overlapping members (`debounce`/`debounceTime`, `audit`/`auditTime`, `throttle`/`throttleTime`, `buffer*`/`window*` pairs) exist because each scheduling variant is a separate operator. v9 starts to merge them — numeric and selector `debounce` share one Symbol, count and delay windows share `buffer` (D-015).

---

## Time and scheduling

A scheduler is, per [`scheduler.md`][g-scheduler], three things at once: _"A Scheduler is a data structure ... A Scheduler is an execution context ... A Scheduler has a (virtual) clock. It provides a notion of "time" by a getter method `now()` on the scheduler."_

| Scheduler                 | Mechanism (7.8.2 source)                                                                                                                                  |
| ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| none (`null`)             | Synchronous, recursive delivery                                                                                                                           |
| `queueScheduler`          | Trampoline: delay `0` runs via `scheduler.flush(this)` in the current frame; `delay > 0` falls back to `AsyncAction` ([`QueueAction.ts`][queueaction-ts]) |
| `asapScheduler`           | Microtask: `immediateProvider.setImmediate`, implemented on `Promise.resolve().then` ([`AsapAction.ts`][asapaction-ts], [`Immediate.ts`][immediate-ts])   |
| `asyncScheduler`          | Macrotask: `intervalProvider.setInterval` — _"we use `setInterval` to schedule single and repeat actions"_ ([`AsyncAction.ts`][asyncaction-ts])           |
| `animationFrameScheduler` | `requestAnimationFrame` via `animationFrameProvider` ([`AnimationFrameScheduler.ts`][animationframe-ts])                                                  |

**`now()`** is `Scheduler.now = dateTimestampProvider.now`, i.e. `(dateTimestampProvider.delegate || Date).now()` ([`Scheduler.ts`][scheduler-ts], [`dateTimestampProvider.ts`][datetimestamp-ts]). The `delegate` slot is the seam `TestScheduler.run` overwrites to install virtual time.

**`AsyncAction` recycles its interval.** `schedule()` keeps the existing timer handle if the action is rescheduled from inside its own callback with the _same_ delay; otherwise `recycleAsyncId` clears it ([`AsyncAction.ts`][asyncaction-ts]):

```ts
// src/internal/scheduler/AsyncAction.ts (7.8.2)
protected recycleAsyncId(_scheduler: AsyncScheduler, id?: TimerHandle, delay: number | null = 0) {
  // If this action is rescheduled with the same delay time, don't clear the interval id.
  if (delay != null && this.delay === delay && this.pending === false) {
    return id;
  }
  // ...
  if (id != null) {
    intervalProvider.clearInterval(id);
  }
  return undefined;
}
```

**`debounceTime` does not re-arm a timer per value.** The 7.8.2 implementation ([`debounceTime.ts`][debouncetime-ts]) stores `lastValue` and `lastTime = scheduler.now()` on every `next`, but schedules only _"if it's not already up"_:

```ts
// src/internal/operators/debounceTime.ts (7.8.2)
(value: T) => {
  lastValue = value;
  lastTime = scheduler.now();
  // Only set up a task if it's not already up
  if (!activeTask) {
    activeTask = scheduler.schedule(emitWhenIdle, dueTime);
    subscriber.add(activeTask);
  }
},
```

When the task fires, `emitWhenIdle` computes `targetTime = lastTime + dueTime`; if `now < targetTime` it reschedules itself for the remainder (`this.schedule(undefined, targetTime - now)`), otherwise it emits. A burst of _k_ keystrokes inside one window therefore costs _k_ clock reads and at most one reschedule per elapsed window, not _k_ `clearTimeout`/`setTimeout` pairs. (Because the remainder differs from `dueTime`, that one reschedule does clear and re-request the interval.) Source completion flushes the pending value synchronously before `complete`.

**v9 reverses this.** v9 has no `debounceTime`; the numeric form of `debounce` ([`v9 debounce.ts`][v9-debounce]) aborts the previous `AbortController` and calls `globalThis.setTimeout(emitPendingValue, delay)` **on every value** — the re-arm-per-value design. D-019 ([`DECISIONS.md`][v9-decisions]) makes it normative: _"each source value replaces the preceding host timer."_ v9 also has no scheduler argument anywhere; D-034 requires late `globalThis.*` resolution so `@rxjs/test` can patch the host.

**`debounce(durationSelector)`** ([`debounce.ts`][debounce-ts]) generalises the window to any Observable: on each value it unsubscribes the previous duration subscriber and subscribes `innerFrom(durationSelector(value))`; the first `next` of the duration emits the pending value. This is the hook for a runtime-adjustable delay: `debounce(() => timer(delay$.getValue()))` reads the current delay per value.

---

## Concurrency and cancellation

**Cancellation is synchronous unsubscription.** `subscription.unsubscribe()` runs finalizers inline, on the caller's stack ([`subscription.md`][g-subscription]: _"A Subscription is an object that represents a disposable resource, usually the execution of an Observable."_). There is no cancellation _request_ and no acknowledgement: once `unsubscribe` returns, the consumer is detached; whatever the producer had in flight (a `fetch`, a worker job) must be stopped by the teardown function the producer returned, and any late result is dropped because `Subscriber.isStopped` is set.

**`switchMap` unsubscribes the old inner before creating the new one.** From [`switchMap.ts`][switchmap-ts]:

```ts
// src/internal/operators/switchMap.ts (7.8.2)
(value) => {
  // Cancel the previous inner subscription if there was one
  innerSubscriber?.unsubscribe();
  let innerIndex = 0;
  const outerIndex = index++;
  // Start the next inner subscription
  innerFrom(project(value, outerIndex)).subscribe(
    (innerSubscriber = createOperatorSubscriber(subscriber, /* next */ …, /* complete */ () => {
      innerSubscriber = null!;
      checkComplete();
    }))
  );
},
```

The order is: old inner's teardown runs to completion → `project(value)` is called → new inner subscribes. A producer that posts "cancel job _n_" in its teardown therefore posts it **before** the mapper posts "start job _n+1_". The result completes only when the outer is complete _and_ no inner is live (`checkComplete`). v9 keeps the order — `active.shift()!.abort()` precedes `mapper(value, index++)` ([`v9 switch-map.ts`][v9-switchmap]) — but the cancellation travels as an `abort` event on the inner's `AbortSignal`.

**No preemption.** Every `next` runs to completion on the JavaScript thread. A synchronous `map(hashEverything)` blocks the UI and cannot be interrupted by `switchMap`: the next keystroke is not even dequeued until it returns. RxJS has no thread pool and no `Worker` integration; offloading means wrapping a `Worker` in `new Observable(...)` by hand, and cooperative cancellation is the worker's job — it sees the cancel message only when it returns to its own event loop (or polls a `SharedArrayBuffer` flag).

**Schedulers are not concurrency.** `observeOn`/`subscribeOn` move delivery to another queue on the same thread; they buy fairness between macrotasks, not parallelism.

**v9: `AbortSignal` all the way down.** `subscribe()` returns `undefined` ([`MIGRATION.md`][v9-migration]: _"Own cancellation with an `AbortController`, and pass its signal in the subscription options."_); teardowns _"run in reverse insertion order"_ — the opposite of 7.x's insertion-order finalizers. The polyfill must patch `AbortController.prototype.abort` because _"JavaScript exposes abort events but not the DOM-standard abort-algorithm hook that must run before those events"_ ([`ARCHITECTURE.md`][v9-architecture]).

---

## Errors and completion

**The grammar is `next* (error | complete)?`.** An `error` is terminal and untyped (`err: any`); after it the `Subscriber` sets `isStopped` and unsubscribes ([`Subscriber.ts`][subscriber-ts]). A throw from a producer function is routed to `sink.error(err)` by `_trySubscribe` ([`Observable.ts`][observable-ts]); a throw from an operator callback becomes `destination.error(err)` via `OperatorSubscriber`.

**Recovery replaces the stream.** `catchError(selector)` ([`catchError.ts`][catcherror-ts]) unsubscribes the failed source and subscribes the Observable the selector returns — the failed source is gone, so a `catchError` placed after `switchMap` kills the whole pipeline on the first failed hash. `retry({ count, delay, resetOnSuccess })` ([`retry.ts`][retry-ts]) re-subscribes the source up to `count` (default `Infinity`) times.

**Isolate errors inside the inner.** The idiom for "one failed job must not end the stream" is to catch _inside_ the higher-order mapper — `switchMap(q => hash(q).pipe(catchError(e => of(failed(q, e)))))` — turning the error into a value. This is the `Expected`-as-value discipline event-horizon already uses, applied by convention rather than by type.

**Consumer errors never reach the producer.** A `SafeSubscriber`'s `ConsumerObserver` wraps each user callback; a throw goes to `handleUnhandledError` → `reportUnhandledError`, which rethrows on a fresh `setTimeout` ([`reportUnhandledError.ts`][report-unhandled-ts]). One throwing observer of a `Subject` therefore does not stop delivery to the others.

**`UnsubscriptionError`.** `Subscription.unsubscribe` runs _every_ finalizer even if some throw, then throws one aggregate ([`UnsubscriptionError.ts`][unsubscription-error-ts]): _"`${errors.length} errors occurred during unsubscription:`"_. v9 removes it with the rest of the `Subscription` type ([`UNSUPPORTED_RXJS_7_SURFACES.md`][v9-unsupported]: _"These errors belong to removed RxJS 7 Subscription and closed-Subject internals."_).

---

## State and sharing

| Type              | Behaviour (7.8.2)                                                                                                                                                             |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Subject`         | Snapshot-iterates `observers` on `next` (`currentObservers = Array.from(this.observers)`); late subscribers to a stopped Subject get the terminal only ([source][subject-ts]) |
| `BehaviorSubject` | Holds `_value`; replays it synchronously on subscribe; `getValue()` throws the stored error if errored ([source][behaviorsubject-ts])                                         |
| `ReplaySubject`   | Ring of `bufferSize` values, trimmed by `windowTime` against a `TimestampProvider` ([source][replaysubject-ts])                                                               |
| `share(config)`   | Refcounted `Subject` connector; `resetOnError`/`resetOnComplete`/`resetOnRefCountZero` all default `true` ([source][share-ts])                                                |
| `shareReplay(n)`  | `share` with a `ReplaySubject`, `resetOnComplete: false`, and `resetOnRefCountZero: refCount` — **default `false`** ([source][sharereplay-ts])                                |

`BehaviorSubject` is the only built-in synchronous read of "current state":

```ts
// src/internal/BehaviorSubject.ts (7.8.2)
getValue(): T {
  const { hasError, thrownError, _value } = this;
  if (hasError) {
    throw thrownError;
  }
  this._throwIfClosed();
  return _value;
}
```

**v9 has no `getValue`.** The v9 `BehaviorSubject` ([`behavior-subject.ts`][v9-behaviorsubject], 29 lines) keeps a private `#currentValue`, replays it on subscribe, and exposes only the lowercase factory `behaviorSubject(value)`; there is no synchronous accessor in the source. The dynamic-debounce variant that re-reads the delay per value must hold the number in a plain variable instead.

**Hot/cold pitfalls.**

- `shareReplay(1)` without `{ refCount: true }` keeps its source subscribed after the last subscriber leaves — a timer or socket stays alive for the life of the program.
- A cold source used twice (`results$` rendered and logged) runs the producer twice: two worker jobs per query. In 7.x the fix is `share()`; in v9 this is the default behaviour and per-subscription work must be requested with `ColdObservable`.
- Resubscribing to a `Subject` loses values emitted in between; resubscribing to a `BehaviorSubject` replays the latest. This difference decides whether the worked pipeline below loses a keystroke when the delay changes.

---

## Lifetime and ownership

**The subscriber owns the subscription.** The top-level `subscribe` call returns the root of the Subscription tree; nothing else holds it. Every leak in RxJS code is a root nobody unsubscribed: an `interval` in a component that was destroyed, a `fromEvent` listener left registered. No scope encloses a subscription automatically.

**`takeUntil(destroy$)`** is the idiom that ties a chain to an owner's lifetime ([`takeUntil.ts`][takeuntil-ts]): it subscribes the notifier _first_ (as [`core-semantics.md`][g-core] requires: _"Notifiers provided directly to the operator MUST be subscribed to before the source is subscribed to."_) and completes the result on the notifier's first `next`. It must be the **last** operator: placed before a `switchMap`, it completes the outer, but `switchMap`'s `checkComplete` waits for the live inner, which keeps running.

**`finalize(callback)`** ([`finalize.ts`][finalize-ts]) adds `callback` as a finalizer of the downstream subscriber, so it runs on error, complete _and_ unsubscribe — the `scope(exit)` of RxJS.

**v9** inverts ownership into the caller's `AbortController`: a component holds one controller and passes its signal to every `subscribe`; `controller.abort()` is the scope exit. This is structurally the event-horizon model (a cancellation token owned by an enclosing scope), though the tree is still built by hand.

---

## Testing

`TestScheduler` virtualises time by swapping every provider delegate inside `run()` ([`TestScheduler.ts`][testscheduler-ts]):

```ts
// src/internal/testing/TestScheduler.ts — run() (7.8.2, abridged)
TestScheduler.frameTimeFactor = 1;
this.maxFrames = Infinity;
this.runMode = true;
animationFrameProvider.delegate = animator.delegate;
dateTimestampProvider.delegate = this;
immediateProvider.delegate = delegates.immediate;
intervalProvider.delegate = delegates.interval;
timeoutProvider.delegate = delegates.timeout;
performanceTimestampProvider.delegate = this;
```

Marble strings describe a timeline ([`marble-testing.md`][g-marble]): `-` is one frame (1 virtual ms inside `run`), `a` a value, `|` complete, `#` error, `^`/`!` subscribe/unsubscribe points, `(ab)` a synchronous group, and `10ms` a time progression. A debounce test reads:

```ts
testScheduler.run(({ cold, expectObservable }) => {
  const q = cold('a 50ms b 300ms c|');
  expectObservable(q.pipe(debounceTime(100))).toBe('151ms b 201ms (c|)');
});
```

Documented known issues ([`marble-testing.md`][g-marble], "Known issues"):

- _"If you have RxJS code that uses asynchronous scheduling - e.g. Promises, etc. - you can't reliably use marble diagrams for that particular code."_ — microtasks are not virtualised.
- _"you also can't currently assert delays of zero, even with `AsyncScheduler`"_.
- Sync groups advance time by their character count: _"`'(abc)'` will emit the values of a, b, and c synchronously in the same frame and then advance virtual time by 5 frames"_ — called _"a known pain point in real-world testing"_.
- Outside `run()`, frames are 10 ms, `maxFrames = 750`, operators do not pick up the test scheduler, and flushing is manual.

**v9** replaces `TestScheduler` with `@rxjs/test`'s `rxTest`, which _"virtualizes the supported host timing APIs"_ and returns a `Promise` (D-012, [`DECISIONS.md`][v9-decisions]; [`packages/test/README.md`][v9-test]). Because v9 has no scheduler seam, virtual time is achieved by patching `globalThis` timers; D-034 admits that _"References captured by application code before `rxTest` patches the realm remain outside the supported virtual-host boundary."_

---

## The worked pipeline

The first consumer — query field → debounce N ms (N adjustable) → hash a file set on a worker with latest-wins cancellation → render; a toggle enables or disables it — in RxJS 7.8.2:

```ts
import { BehaviorSubject, EMPTY, Observable, Subject, of } from 'rxjs';
import {
  catchError,
  debounceTime,
  distinctUntilChanged,
  switchMap,
  takeUntil,
} from 'rxjs/operators';

type Result =
  | { kind: 'ok'; query: string; digest: string }
  | { kind: 'err'; query: string; error: unknown };

const query$ = new BehaviorSubject<string>(''); // text field: next() on input
const delayMs$ = new BehaviorSubject<number>(250); // N, adjustable at runtime
const enabled$ = new BehaviorSubject<boolean>(true); // the toggle
const destroy$ = new Subject<void>(); // the view's lifetime

// One worker job per subscription; teardown posts a cancel if the job is still running.
function hashOnWorker(worker: Worker, query: string): Observable<Result> {
  return new Observable<Result>(subscriber => {
    const id = crypto.randomUUID();
    let done = false;
    const onMessage = (e: MessageEvent) => {
      if (e.data.id !== id) return; // a stale job's reply
      done = true;
      subscriber.next(
        e.data.ok
          ? { kind: 'ok', query, digest: e.data.digest }
          : { kind: 'err', query, error: e.data.error },
      );
      subscriber.complete();
    };
    worker.addEventListener('message', onMessage);
    worker.postMessage({ type: 'hash', id, query });
    return () => {
      // runs on complete, error, or unsubscribe
      worker.removeEventListener('message', onMessage);
      if (!done) worker.postMessage({ type: 'cancel', id });
    };
  });
}

const results$ = enabled$.pipe(
  distinctUntilChanged(),
  switchMap(on =>
    on
      ? delayMs$.pipe(
          distinctUntilChanged(),
          switchMap(ms => query$.pipe(debounceTime(ms))), // a new N restarts the window
          distinctUntilChanged(), // same query after a restart: no re-hash
          switchMap(q =>
            hashOnWorker(worker, q).pipe(
              catchError(error => of<Result>({ kind: 'err', query: q, error })),
            ),
          ),
        )
      : EMPTY,
  ),
  takeUntil(destroy$), // last, so it also ends live inners
);

results$.subscribe(render);
```

What happens, event by event (times in ms; N = 250):

| t    | Event                         | Precisely what runs                                                                                                                                                                                                                                                                                                                                         |
| ---- | ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0    | `subscribe(render)`           | Synchronously: `enabled$` replays `true` → outer `switchMap` subscribes the branch → `delayMs$` replays `250` → `query$` replays `''` → `debounceTime` stores `lastTime = 0` and schedules one `AsyncAction` (a `setInterval(…, 250)`). `subscribe` returns.                                                                                                |
| 100  | user types `a`                | `query$.next('a')` → `debounceTime` stores `lastValue = 'a'`, `lastTime = 100`; a task is already up, so no timer call.                                                                                                                                                                                                                                     |
| 250  | timer fires                   | `emitWhenIdle`: `targetTime = 350 > now`, reschedules for 100 ms (different delay → `clearInterval` + new interval).                                                                                                                                                                                                                                        |
| 350  | timer fires                   | Emits `'a'` → `distinctUntilChanged` passes it (first value; `''` was superseded before emission) → `switchMap` has no inner → `hashOnWorker('a')` posts `hash#1`.                                                                                                                                                                                          |
| 610  | `'ab'` (typed at 360) emitted | `switchMap` calls `innerSubscriber.unsubscribe()` **first**: job 1's teardown removes its listener and posts `cancel#1`; then `project('ab')` posts `hash#2`. The worker receives `cancel#1` before `hash#2` (`postMessage` is FIFO) but processes it only when its own loop yields between files. A late reply for job 1 is ignored: its listener is gone. |
| 900  | worker replies for job 2      | `done = true`, `render({ kind: 'ok', query: 'ab', … })`, inner completes; its teardown sees `done` and posts nothing. The result stays open (outer not complete).                                                                                                                                                                                           |
| 1000 | `delayMs$.next(500)`          | Middle `switchMap` unsubscribes `query$.pipe(debounceTime(250))` (cancels any pending window, discards `lastValue`) and subscribes `debounceTime(500)`; `query$` replays `'ab'` so nothing typed is lost. At 1500 `'ab'` is emitted and suppressed by `distinctUntilChanged`; no re-hash; job 2's result stays rendered.                                    |
| 1600 | toggle off                    | Outer `switchMap` unsubscribes the whole branch, depth-first through the Subscription tree: any in-flight job's teardown posts its cancel. `project(false)` returns `EMPTY`, which completes at once; `render` is not called, so the last result stays on screen — return `of(disabledMarker)` instead to clear it.                                         |
| 1700 | toggle on                     | A fresh branch: all three `BehaviorSubject`s replay, the inner `distinctUntilChanged` is new, so the current query is debounced with N = 500 and re-hashed once.                                                                                                                                                                                            |
| end  | `destroy$.next()`             | `takeUntil` completes the result; `SafeSubscriber` unsubscribes, which tears the chain down exactly as for "toggle off".                                                                                                                                                                                                                                    |

**Variant: re-read N per value.** `debounce(() => timer(delayMs$.getValue()))` replaces the middle `switchMap`. A new N then applies from the _next_ keystroke rather than restarting the current window, and `debounce` re-subscribes a `timer` per value (one `setInterval` + `clearInterval` pair per keystroke) where `debounceTime` reuses one action.

**What the user code had to supply** that a D library should provide: the job identity and stale-reply guard, the `done` flag that stops a cancel being sent for a finished job, the ordering argument that makes `cancel#n` precede `hash#n+1`, the `catchError` placement that keeps one failure from killing the stream, and the `takeUntil`-must-be-last rule. None is checked by the type system.

---

## Strengths

- **One small algebra covers UI events, timers and async work.** `switchMap` + `debounceTime` express latest-wins search in two operators; the four mapping policies make concurrency choices explicit and named.
- **Deterministic, synchronous teardown.** `unsubscribe` runs the whole finalizer tree before it returns; `switchMap` cancels the old inner strictly before starting the new one.
- **Virtual time is a first-class seam (7.x).** Every time operator takes a `SchedulerLike`; `TestScheduler.run` turns a debounce test into a one-line marble assertion.
- **Allocation-aware internals.** `debounceTime` reuses a single scheduled action across a burst; `AsyncAction` keeps its interval when rescheduled with the same delay.
- **Normative operator semantics.** [`core-semantics.md`][g-core] states subscription order, notifier rules and finalization timing as MUST/SHOULD rules.
- **v9 aligns with the platform.** Native `Observable`, `AbortSignal` cancellation, shared-by-default activation and Symbol-keyed extensions remove the library's private identity and its `Subscription` type.

## Weaknesses

- **No backpressure.** Push without demand means excess goes into unbounded buffers (`mergeInternals`' `buffer: T[]`) or is dropped by a lossy operator the user must choose.
- **Glitches.** `combineLatest` emits intermediate inconsistent tuples in diamonds; there is no topological propagation.
- **Untyped, terminal errors.** `err: any` and stream-killing `error` push every robust pipeline toward catching inside inners by convention.
- **Ownership is manual.** No enclosing scope; leaks come from forgotten roots, `shareReplay` without `refCount`, and `takeUntil` in the wrong position.
- **Hot/cold is invisible in types.** The same `Observable<T>` type may start a worker per subscriber or share one; v9 flips the default, so the same code changes meaning across major versions.
- **No parallelism or preemption.** Synchronous work blocks every stream; workers are hand-wrapped with hand-rolled cancellation protocols.
- **Operator sprawl.** ~115 exported names with overlapping time/selector pairs and deprecated aliases.
- **v9 regresses testability and debounce cost.** Without schedulers, virtual time depends on patching `globalThis` (with the captured-reference hole D-034 admits), and numeric `debounce` re-arms a host timer per value.

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                               | Trade-off                                                                                         |
| ----------------------------------------------------------------- | ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Observable = lazy function; cold by default (7.x)                 | Referential transparency: subscribing twice is calling a function twice | Duplicate side effects unless the user adds `share()`; hot/cold not visible in the type           |
| Shared, ref-counted activation by default (v9)                    | Match the web-platform `Observable` lifecycle (D-001, D-035)            | Per-subscription work needs an explicit `ColdObservable`; a semantic break for every 7.x pipeline |
| Pure push, no demand channel                                      | Simplest protocol; fits DOM events, which cannot be paused              | Unbounded buffering or explicit lossy operators; no flow control to a slow consumer               |
| Synchronous emission allowed                                      | No forced async hop; zero-latency `of`/`map` chains                     | Re-entrancy hazards; `share` and `Subscriber` must guard against firehose sources                 |
| Subscription tree mirrors the operator chain                      | `unsubscribe` at the sink cancels everything upstream deterministically | Hand-built tree; leaks when a root is dropped; 7.x insertion-order vs v9 reverse-order teardown   |
| `switchMap` tears down the old inner before calling `project`     | Cancel is observably ordered before the next start                      | Teardown cannot await an acknowledgement; in-flight work must be cancelled cooperatively          |
| `debounceTime` stores `lastTime` and reschedules once (7.x)       | One scheduled action per burst instead of a timer per value             | Depends on `now()` precision and the scheduler; v9 abandoned it for one host timer per value      |
| Injectable `SchedulerLike` on every time operator (7.x)           | Least-concurrency defaults; virtual time for tests                      | API surface on dozens of operators; removed entirely in v9 in favour of host patching             |
| Errors are terminal and untyped                                   | Mirrors `Promise` rejection; a single failure channel                   | Recovery replaces the stream; per-item isolation is a convention (`catchError` inside inners)     |
| Operators as pipeable functions (7.x) → Symbol-keyed methods (v9) | Tree-shaking without patching string names onto a platform type (D-003) | Bracket-call syntax `source[map](f)`; no `.pipe`; a migration tool is required                    |

---

## Sources

- [ReactiveX/rxjs — GitHub repository][repo]
- 7.8.2 (`e5351d02e225e275ac0e497c7b66eaa5f0c88791`): [`package.json`][v7-package] · [`LICENSE.txt`][v7-license]
- 7.8.2 guides (rxjs.dev source): [`observable.md`][g-observable] · [`subject.md`][g-subject] · [`subscription.md`][g-subscription] · [`scheduler.md`][g-scheduler] · [`higher-order-observables.md`][g-hoo] · [`core-semantics.md`][g-core] · [`testing/marble-testing.md`][g-marble]
- 7.8.2 core: [`Observable.ts`][observable-ts] · [`Subscriber.ts`][subscriber-ts] · [`Subscription.ts`][subscription-ts] · [`Subject.ts`][subject-ts] · [`BehaviorSubject.ts`][behaviorsubject-ts] · [`ReplaySubject.ts`][replaysubject-ts] · [`util/lift.ts`][lift-ts] · [`util/reportUnhandledError.ts`][report-unhandled-ts] · [`util/UnsubscriptionError.ts`][unsubscription-error-ts] · [`util/Immediate.ts`][immediate-ts]
- 7.8.2 operators: [`OperatorSubscriber.ts`][operator-subscriber-ts] · [`debounceTime.ts`][debouncetime-ts] · [`debounce.ts`][debounce-ts] · [`switchMap.ts`][switchmap-ts] · [`mergeInternals.ts`][mergeinternals-ts] · [`concatMap.ts`][concatmap-ts] · [`exhaustMap.ts`][exhaustmap-ts] · [`catchError.ts`][catcherror-ts] · [`retry.ts`][retry-ts] · [`share.ts`][share-ts] · [`shareReplay.ts`][sharereplay-ts] · [`finalize.ts`][finalize-ts] · [`takeUntil.ts`][takeuntil-ts] · [`observable/combineLatest.ts`][combinelatest-ts] · [`src/operators/index.ts`][operators-index]
- 7.8.2 schedulers and testing: [`Scheduler.ts`][scheduler-ts] · [`AsyncAction.ts`][asyncaction-ts] · [`QueueAction.ts`][queueaction-ts] · [`AsapAction.ts`][asapaction-ts] · [`AnimationFrameScheduler.ts`][animationframe-ts] · [`dateTimestampProvider.ts`][datetimestamp-ts] · [`TestScheduler.ts`][testscheduler-ts]
- 9.0.0-beta.0 (`60d632c3878d7237f2d405d9517091899d553f6d`): [`README.md`][v9-readme] · [`packages/rxjs/package.json`][v9-package] · [`MIGRATION.md`][v9-migration] · [`UNSUPPORTED_RXJS_7_SURFACES.md`][v9-unsupported] · [`ARCHITECTURE.md`][v9-architecture] · [`DECISIONS.md`][v9-decisions] · [`switch-map.ts`][v9-switchmap] · [`merge-map.ts`][v9-mergemap] · [`debounce.ts`][v9-debounce] · [`behavior-subject.ts`][v9-behaviorsubject] · [`observable-polyfill/src/index.ts`][v9-polyfill] · [`packages/test/README.md`][v9-test]
- Related: [Survey index][index] · [Concepts][concepts] · [Comparison][comparison] · [Effect-TS][effect-ts] · [Solid signals][solid-signals] · [`event-horizon` specification][eh-spec] · [`event-horizon` docs][eh-docs]

<!-- References -->

[repo]: https://github.com/ReactiveX/rxjs
[v7-package]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/package.json
[v7-license]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/LICENSE.txt
[g-observable]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/docs_app/content/guide/observable.md
[g-subject]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/docs_app/content/guide/subject.md
[g-subscription]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/docs_app/content/guide/subscription.md
[g-scheduler]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/docs_app/content/guide/scheduler.md
[g-hoo]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/docs_app/content/guide/higher-order-observables.md
[g-core]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/docs_app/content/guide/core-semantics.md
[g-marble]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/docs_app/content/guide/testing/marble-testing.md
[observable-ts]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/internal/Observable.ts
[subscriber-ts]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/internal/Subscriber.ts
[subscription-ts]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/internal/Subscription.ts
[subject-ts]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/internal/Subject.ts
[behaviorsubject-ts]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/internal/BehaviorSubject.ts
[replaysubject-ts]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/internal/ReplaySubject.ts
[lift-ts]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/internal/util/lift.ts
[report-unhandled-ts]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/internal/util/reportUnhandledError.ts
[unsubscription-error-ts]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/internal/util/UnsubscriptionError.ts
[immediate-ts]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/internal/util/Immediate.ts
[operator-subscriber-ts]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/internal/operators/OperatorSubscriber.ts
[debouncetime-ts]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/internal/operators/debounceTime.ts
[debounce-ts]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/internal/operators/debounce.ts
[switchmap-ts]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/internal/operators/switchMap.ts
[mergeinternals-ts]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/internal/operators/mergeInternals.ts
[concatmap-ts]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/internal/operators/concatMap.ts
[exhaustmap-ts]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/internal/operators/exhaustMap.ts
[catcherror-ts]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/internal/operators/catchError.ts
[retry-ts]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/internal/operators/retry.ts
[share-ts]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/internal/operators/share.ts
[sharereplay-ts]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/internal/operators/shareReplay.ts
[finalize-ts]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/internal/operators/finalize.ts
[takeuntil-ts]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/internal/operators/takeUntil.ts
[combinelatest-ts]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/internal/observable/combineLatest.ts
[operators-index]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/operators/index.ts
[scheduler-ts]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/internal/Scheduler.ts
[asyncaction-ts]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/internal/scheduler/AsyncAction.ts
[queueaction-ts]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/internal/scheduler/QueueAction.ts
[asapaction-ts]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/internal/scheduler/AsapAction.ts
[animationframe-ts]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/internal/scheduler/AnimationFrameScheduler.ts
[datetimestamp-ts]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/internal/scheduler/dateTimestampProvider.ts
[testscheduler-ts]: https://github.com/ReactiveX/rxjs/blob/e5351d02e225e275ac0e497c7b66eaa5f0c88791/src/internal/testing/TestScheduler.ts
[v9-readme]: https://github.com/ReactiveX/rxjs/blob/60d632c3878d7237f2d405d9517091899d553f6d/README.md
[v9-package]: https://github.com/ReactiveX/rxjs/blob/60d632c3878d7237f2d405d9517091899d553f6d/packages/rxjs/package.json
[v9-migration]: https://github.com/ReactiveX/rxjs/blob/60d632c3878d7237f2d405d9517091899d553f6d/packages/rxjs/MIGRATION.md
[v9-unsupported]: https://github.com/ReactiveX/rxjs/blob/60d632c3878d7237f2d405d9517091899d553f6d/packages/rxjs/docs/UNSUPPORTED_RXJS_7_SURFACES.md
[v9-architecture]: https://github.com/ReactiveX/rxjs/blob/60d632c3878d7237f2d405d9517091899d553f6d/docs/rxjs-next/ARCHITECTURE.md
[v9-decisions]: https://github.com/ReactiveX/rxjs/blob/60d632c3878d7237f2d405d9517091899d553f6d/docs/rxjs-next/DECISIONS.md
[v9-switchmap]: https://github.com/ReactiveX/rxjs/blob/60d632c3878d7237f2d405d9517091899d553f6d/packages/rxjs/src/switch-map.ts
[v9-mergemap]: https://github.com/ReactiveX/rxjs/blob/60d632c3878d7237f2d405d9517091899d553f6d/packages/rxjs/src/merge-map.ts
[v9-debounce]: https://github.com/ReactiveX/rxjs/blob/60d632c3878d7237f2d405d9517091899d553f6d/packages/rxjs/src/debounce.ts
[v9-behaviorsubject]: https://github.com/ReactiveX/rxjs/blob/60d632c3878d7237f2d405d9517091899d553f6d/packages/rxjs/src/behavior-subject.ts
[v9-polyfill]: https://github.com/ReactiveX/rxjs/blob/60d632c3878d7237f2d405d9517091899d553f6d/packages/observable-polyfill/src/index.ts
[v9-test]: https://github.com/ReactiveX/rxjs/blob/60d632c3878d7237f2d405d9517091899d553f6d/packages/test/README.md
[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[effect-ts]: ./effect-ts.md
[solid-signals]: ./solid-signals.md
[eh-spec]: ../../specs/event-horizon/SPEC.md
[eh-docs]: ../../libs/event-horizon/index.md
