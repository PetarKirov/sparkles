# Angular Signals (TypeScript)

The one mainstream UI framework that ships both a push-pull signal graph and RxJS, plus a supported converter between them: synchronous `signal`/`computed` cells, change-detection-scheduled `effect`s, `AbortSignal`-cancelled async derivations (`resource`, `httpResource`, `rxResource`) and the `@angular/core/rxjs-interop` bridge (`toSignal`, `toObservable`).

| Field             | Value                                                                                                                                                                                                                                            |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Language          | TypeScript                                                                                                                                                                                                                                       |
| License           | MIT ([`LICENSE`][a-license]; `@angular/core` [`package.json`][a-core-package])                                                                                                                                                                   |
| Repository        | [angular/angular][repo] (signal graph in [`packages/core/primitives/signals`][p-readme])                                                                                                                                                         |
| Documentation     | [angular.dev/guide/signals][d-overview], rendered from [`adev/src/content/guide/signals/`][g-overview]; interop at [angular.dev/ecosystem/rxjs-interop][d-interop]                                                                               |
| Category          | push-pull signal graph + async-resource layer + Observable bridge                                                                                                                                                                                |
| Versions surveyed | `main` at commit `8b15295e8c71` (2026-11-20), root [`package.json`][a-package] `"version": "22.4.0-next.0"`; `resource`/`httpResource`/`rxResource` are `@publicApi 22.0`, `debounced` and `resourceFromSnapshots` are `@experimental 22.0`      |
| Core abstraction  | `Signal<T>`: a zero-argument getter `() => T` backed by a `ReactiveNode` with a monotonic `version`; `Resource<T>`: a bundle of signals (`value`, `status`, `error`, `isLoading`, `snapshot`) driven by an effect that owns an `AbortController` |

> [!NOTE]
> Every claim below is checked against source at the surveyed commit. The angular.dev URLs
> are the rendered routes of the cited `adev/` Markdown sources; the pages themselves were
> not fetched, so where the live site lags `main` (for example `debounced`, added in 22.0
> as experimental) the GitHub source is authoritative. Code in
> [The worked pipeline](#the-worked-pipeline) and [Testing](#testing) was written for this
> survey and **not executed**.

---

## Overview

### What it solves

Angular's original reactivity was zone.js dirty-checking plus RxJS for anything time-shaped. Signals replace the first with fine-grained, framework-visible dependency tracking ([`overview.md`][g-overview]):

> _"Angular Signals is a system that granularly tracks how and where your state is used throughout an application, allowing the framework to optimize rendering updates."_

They deliberately do **not** replace RxJS for events-over-time. The resource guide draws the line ([`resource.md`][g-resource]):

> _"All signal APIs are synchronous— `signal`, `computed`, `input`, etc. However, applications often need to deal with data that is available asynchronously. A `Resource` gives you a way to incorporate async data into your application's signal-based code and still allow you to access its data synchronously."_

What remains — debounce, merge, retry, streams — stays in RxJS, reached through [`rxjs-interop`][g-interop]. That makes Angular the only surveyed system where both models ([RxJS][rxjs] and a [TC39-style signal graph][tc39]) coexist in one runtime with first-party adapters, and so the best evidence of what each converter loses.

### Design philosophy

1. **State is a value cell; reading is subscribing.** The graph README ([`primitives/signals/README.md`][p-readme]): _"Angular Signals are zero-argument functions (`() => T`). When executed, they return the current value of the signal. Executing signals does not trigger side effects, though it may lazily recompute intermediate values (lazy memoization)."_ Dependencies are implicit and dynamic: _"Users do not need to declare arrays of dependencies, nor does the set of dependencies of a particular context need to remain static across executions."_
2. **Glitch-freedom over immediacy.** _"Effects do not execute synchronously with the set … but are scheduled and resolved by the framework. The exact timing of effects is unspecified."_ ([`README.md`][p-readme]).
3. **Effects are a last resort.** [`effect.md`][g-effect]: _"Effects should be the last API you reach for. Always prefer `computed()` for derived values and `linkedSignal()` for values that can be both derived and manually set."_ — and, bluntly, _"TIP: There are no situations where effect is good, only situations where it is appropriate."_
4. **Lifetime comes from dependency injection.** Every effectful primitive (`effect`, `toSignal`, `toObservable`, `resource`, `debounced`) must be created in an _injection context_ and registers teardown on the ambient `DestroyRef` — the structured-scope role a D library would give a nursery.

---

## How it works

### The producer/consumer graph

[`graph.ts`][p-graph] defines one node type, `ReactiveNode`, usable as producer, consumer or both. Edges are intrusive doubly-linked `ReactiveLink` records (`producer`, `consumer`, `lastReadVersion`, `knownValidAtEpoch`, `prevConsumer`/`nextConsumer`/`nextProducer`), not arrays. A module-level `activeConsumer` is the tracking context: `producerAccessed(node)` links the currently running consumer to `node`, reusing the link at the same position from the previous run when it matches (the README's "pointer into that array" algorithm, now over a list).

Two counters carry correctness:

| Counter        | Where                             | Meaning                                                                                                      |
| -------------- | --------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `node.version` | per producer                      | Incremented only when a _semantically new_ value is produced (after the `equal` check)                       |
| `epoch`        | global (`let epoch: Version = 1`) | _"Incremented whenever a source signal is set"_; lets a clean node skip polling (`lastCleanEpoch === epoch`) |

`signalSetFn` ([`signal.ts`][p-signal]) is the whole write path: assert writes are allowed, run `node.equal(node.value, newValue)`, and only on inequality store the value and call `signalValueChanged` (bump `version`, bump `epoch`, `producerNotifyConsumers`). Notification walks only **live** consumer links and calls `consumerMarkDirty`, with reads forbidden for the duration (`inNotificationPhase`).

### Liveness

Producers hold back-edges only to _live_ consumers ([`README.md`][p-readme]): a consumer is live if `consumerIsAlwaysLive` (effects, templates) or if a live consumer depends on it. An unobserved `computed` therefore has no back-edge and can be garbage-collected; on read it _polls_ its producers (`consumerPollProducersForChange`: compare `lastReadVersion` with `producer.version`, recursively refreshing stale producers first). This is the memory model that lets signals live in plain object fields without explicit unsubscription.

### Effects are `Watch`es with a pluggable scheduler

The primitive [`effect.ts`][p-effect] node has `consumerIsAlwaysLive: true`, `consumerAllowSignalWrites: true`, `dirty: true`. `runEffect` clears `dirty`, re-checks `consumerPollProducersForChange` (an effect invalidated by a `computed` that recomputes to an equal value does not run), then runs `cleanup()` followed by `fn()` with the node as active consumer. _When_ it runs is decided by the framework layer in [`render3/reactivity/effect.ts`][r-effect]:

- **View (component) effect** — created where a `ViewContext` is injectable. `consumerMarkedDirty` calls `markAncestorsForTraversal(this.view)` and notifies `NotificationSource.ViewEffect`. The node sits in `view[EFFECTS]` and is run by `runEffectsInView` ([`view_effect_runner.ts`][r-view-runner]) inside `refreshView`, after that view's template update pass and pre-order hooks and before its embedded views ([`change_detection.ts`][r-cd]).
- **Root effect** — created outside the component tree. `consumerMarkedDirty` calls `scheduler.schedule(this)` on the root `EffectScheduler` and notifies `NotificationSource.RootEffect`. `ZoneAwareEffectScheduler.flush` runs dirty effects FIFO per zone, looping until none are dirty ([`root_effect_scheduler.ts`][r-root-sched]).

The `effect()` doc comment says _"Root effects run as microtasks"_, but the code is more specific: the notification sets `ApplicationRefDirtyFlags.RootEffects`, and `ApplicationRef.synchronizeOnce` does _"First, process any dirty root effects"_ — `rootEffectScheduler.flush()` — before checking any view, re-looping while views or root effects are still dirty ([`application_ref.ts`][a-appref]). The guide states the user-visible contract ([`effect.md`][g-effect]): _"Effects always execute **asynchronously**, during the change detection process."_

### The tick is frame-coalesced

In zoneless mode (_"the default in Angular v21+"_, [`zoneless.md`][g-zoneless]) every notification ends in `ChangeDetectionSchedulerImpl.notify`, which schedules one `tick` via `scheduleCallbackWithRafRace` — the first of `setTimeout(0)` and `requestAnimationFrame` wins and cancels the other ([`callback_scheduler.ts`][a-raf]):

> _"Both `setTimeout` and `rAF` are able to "coalesce" several events from a single user interaction into a single change detection. Importantly, this reduces view tree traversals when compared to an alternative timing mechanism like `queueMicrotask`, where change detection would then be interleaves between each event."_

A notification arriving within one microtask of a tick switches temporarily to `scheduleCallbackWithMicrotask` (`switchToMicrotaskScheduler` in [`zoneless_scheduling_impl.ts`][a-zoneless-impl]) so a `Promise.resolve`-driven follow-up lands in the same paint. This is structurally the sparkles `wakeIn` + rebuild-per-frame loop.

### Relationship to the TC39 polyfill

The TC39 proposal README lists Angular among the frameworks whose maintainers gave design input ([`proposal-signals` `README.md`][tc39-readme]). The reference polyfill is a fork of this package: `signal-polyfill`'s [`src/graph.ts`][poly-graph] still carries _"Copyright Google LLC All Rights Reserved … found in the LICENSE file at https://angular.io/license"_. The two have since diverged: the polyfill keeps the earlier array representation (`producerNode: ReactiveNode[] | undefined` with parallel index arrays), while Angular moved to the linked `ReactiveLink` list with epoch-validated reuse. Angular does not consume the polyfill or `Signal.State`; see [TC39 Signals][tc39].

---

## Evaluation model

- **Push-pull.** _"'dirtiness' is eagerly pushed through the graph when a source signal is changed, but recalculation is performed lazily, only when values are pulled by reading their signals"_ ([`README.md`][p-readme]). The push phase invalidates only; no user code runs in it.
- **Glitch-free** by construction: the README's `counter`/`evenOrOdd` diamond can never log `"1 is even"`, because the effect runs only after the synchronous push completes and its read of `evenOrOdd` pulls a fresh value. Contrast RxJS's `combineLatest`, which emits the intermediate tuple ([RxJS § Weaknesses][rxjs-weak]).
- **Lazy, memoized derivations.** [`overview.md`][g-overview]: _"`doubleCount`'s derivation function does not run to calculate its value until the first time you read `doubleCount`. The calculated value is then cached."_
- **Always hot.** A signal always has a current value; there is no subscription-triggered producer. Cold work exists only inside a `resource` loader, started by the resource's own effect.
- **Batched, not synchronous, at the edges.** Writes are synchronous and reads are immediately consistent (`count.set(3); count()` is `3`), but every _reaction_ — effects, templates, `toObservable` emissions, resource loads — is deferred to the next tick. N writes in one task produce at most one reaction per consumer, seeing the last value.
- **Equality cuts propagation.** `Object.is` by default, overridable per node; a `computed` that recomputes equal keeps its `version`, so downstream effects skip.

## Composition

The signal surface is tiny and has **no time or collection operators**:

| API                                                           | Role                                                                                                                                                             |
| ------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `signal(v, {equal})`                                          | Writable cell: `.set`, `.update`, `.asReadonly()`                                                                                                                |
| `computed(fn, {equal})`                                       | Memoized derivation                                                                                                                                              |
| `linkedSignal(fn)` / `linkedSignal({source, computation})`    | Writable cell that **resets** whenever its source changes; `computation(source, previous?)` sees the previous `{source, value}` ([`linked_signal.ts`][r-linked]) |
| `effect(fn(onCleanup))`                                       | Side-effect sink, scheduled by change detection                                                                                                                  |
| `afterRenderEffect({earlyRead, write, mixedReadWrite, read})` | Effect phased after DOM commit ([`after_render_effect.ts`][r-after-render])                                                                                      |
| `untracked(fn)`                                               | Read without tracking                                                                                                                                            |
| `resource` / `rxResource` / `httpResource`                    | Async derivation: reactive `params` → `loader`/`stream` ([`resource.ts`][r-resource], [`rx_resource.ts`][x-rxresource], [`http/resource.ts`][h-resource])        |
| `debounced(source, wait)`                                     | **Experimental** time operator returning a `Resource<T>` ([`debounce.ts`][r-debounce])                                                                           |
| `resourceFromSnapshots(snapshot)`                             | **Experimental**: build a `Resource` from a `Signal<ResourceSnapshot<T>>` ([`from_snapshots.ts`][r-from-snapshots])                                              |

Composition is ordinary function composition over getters: a `computed` reads whatever it reads. `linkedSignal` is the one stateful combinator — effectively `scan` keyed on a source — and is how Angular itself builds `debounced` and the resource state machine. Resources compose through `params({chain})`: `chain(other)` returns `other`'s value only when `resolved`/`local` and otherwise throws a `ResourceParamsStatus` (`IDLE`/`LOADING`) or `ResourceDependencyError` to propagate status ([`api.ts`][r-api], [`resource.md`][g-resource]). Everything else (merge, zip, scan over events, retry, buffer) means crossing into RxJS.

## Time and scheduling

Signals have **no clock abstraction**. Time enters through two places: the frame-coalesced tick (above) and host timers (`setTimeout`) called directly by library code.

### Debounce

The brief's premise — that debounce is not built in — no longer holds on `main`. `debounced` ([`debounce.ts`][r-debounce], `@experimental 22.0`, exported from `@angular/core` per the [public-API golden][a-golden]) is a `linkedSignal` holding a `ResourceSnapshot<T>` plus a root/view `effect`:

```ts
// packages/core/src/resource/debounce.ts — the effect body (abridged)
const currentState = untracked(state);
if (currentState.status === 'reloading' || currentState.status === 'loading') {
  if (equal(value, pendingValue!)) return; // same value still pending: keep the window
} else if (currentState.status === 'resolved') {
  if (equal(value, currentState.value!)) return;
}
cancelTimer(); // clearTimeout(activeTimer) — numeric wait only
const waitFn =
  typeof wait === 'number'
    ? () =>
        new Promise<void>(resolve => {
          activeTimer = setTimeout(() => {
            activeTimer = undefined;
            resolve();
          }, wait);
        })
    : wait;
const result = waitFn(value, currentState);
if (result === undefined) {
  state.set({ status: 'resolved', value }); /* sync: no delay */
} else {
  if (currentState.status !== 'loading' && currentState.status !== 'error')
    state.set({ status: 'loading', value: currentState.value }); // keep the last settled value
  active = result;
  pendingValue = value;
  result.then(() => {
    if (active === result) state.set({ status: 'resolved', value });
  });
}
```

Properties a D design should note:

- **Trailing-edge, value-deduplicated.** A burst re-arms the window; a value equal to the pending one does not. The result's `value()` keeps the last settled value while `status()` is `'loading'` ([`debounced.md`][g-debounced]).
- **The window starts at the next tick, not at the keystroke.** The timer is armed inside an effect, so it starts when change detection flushes (one rAF/`setTimeout` later).
- **Duration fixed or per-value.** A numeric `wait` is captured at creation. The function form `(value, lastSnapshot) => Promise<void> | void` is called per new value, so it can read a runtime-adjustable N — but a changed N applies from the **next** value, and nothing restarts the pending window. The function is called _inside_ the effect body, so reading an N signal there is _tracked_; wrap it in `untracked` to avoid spurious re-runs.
- **Custom waits are discarded, not cancelled.** `cancelTimer` clears only the numeric path's `setTimeout`; a custom promise is superseded by the `active === result` identity check and its timer keeps running to completion. There is no `AbortSignal` for the wait.
- **Not stability-tracked.** Unlike `resource`, `debounced` registers no `PendingTasks` task, so `ApplicationRef.whenStable()` does not wait for a pending window (inferred from source: no `PendingTasks` reference in [`debounce.ts`][r-debounce]).

The pre-22 idiom, still the general one, routes through RxJS ([`signals-interop.md`][g-interop]):

```ts
readonly query = signal('');
readonly debouncedQuery = toSignal(
  toObservable(this.query).pipe(debounceTime(300), distinctUntilChanged()),
  {initialValue: ''},
);
```

Here the clock is RxJS's `asyncScheduler` ([RxJS § Time and scheduling][rxjs-time]); `toObservable` adds one tick of latency before the window opens and `toSignal` adds one tick before the template sees the result.

## Concurrency and cancellation

JavaScript is single-threaded; signals have no concurrency of their own. Concurrency enters through promises, Observables and Workers, and the only first-party cancellation primitive is the platform `AbortSignal` passed to resource loaders.

**Latest-wins is the default and only policy of `resource`.** `loadEffect` ([`resource.ts`][r-resource]) runs whenever `extRequest` (params + reload counter) changes and does, in order:

1. `this.abortInProgressLoad()` — _"A changed request invalidates the previous load even when the new params are unavailable or errored"_ — which calls `pendingController.abort(getAbortReason())` (a shared `DOMException('AbortError')`) and releases the old load's `PendingTasks` task.
2. If params are `undefined` (idle) or the state is not `loading`, return.
3. `new AbortController()`; call the loader **under `untracked`** with `{params, abortSignal, previous: {status}}`.
4. On settle: `shouldDiscard = () => abortSignal.aborted || untracked(this.extRequest) !== extRequest`; a stale result or stale error is dropped.

There is no `switchMap`/`concatMap`/`exhaustMap` choice: a resource is always "switch", and queueing or ignoring-while-busy must be hand-built. `reload()` re-runs the loader with the same params (`status` becomes `'reloading'` and the previous value is kept), and is refused while `idle` or `loading`.

**Cancellation reaches running work only if the loader listens.** `abort()` dispatches the `abort` event synchronously; `fetch(url, {signal})` honours it, `httpResource` maps it to `HttpClient` unsubscription (`abortSignal.addEventListener('abort', onAbort, {once: true})` → `sub?.unsubscribe()` in [`http/resource.ts`][h-resource]), and `rxResource` does the same for any Observable ([`rx_resource.ts`][x-rxresource]). A plain `async` loader that ignores `abortSignal` keeps running; only its result is discarded.

**A cancel never waits.** The new load starts in the same effect run, immediately after `abort()`. The old promise settles whenever it settles and is ignored. There is no join, no "cancelled work has finished" signal and no way to learn that a worker actually stopped — the D design's structured `cancel-then-join` has no equivalent.

**CPU-bound work** must leave the main thread (a `Worker`); the loader wraps the worker protocol in a promise and translates `abort` into a cancel message. Nothing in Angular helps with that wrapper.

## Errors and completion

- **`computed` caches errors.** A throwing derivation stores the `ERRORED` sentinel and rethrows the cached error on every read until a dependency changes ([`computed.ts`][p-computed]). Errors are values in the graph, not terminal events: the next change recovers.
- **Signals never complete.** `toSignal` says so in a comment: _"Completion of the Observable is meaningless to the signal. Signals don't have a concept of "complete"."_ On Observable `error`, the signal enters an error state and _"will throw an error if the `Observable` errors"_ on every read; on `complete` it keeps the last value ([`to_signal.ts`][x-tosignal]).
- **`toObservable` maps a throwing read to `subject.error(err)`** — terminal for the Observable even though the signal may recover ([`to_observable.ts`][x-toobservable]). Destroying the injector calls `subject.complete()`.
- **Resources expose errors as status.** A rejected loader yields `status() === 'error'`, `error()` set, and `value()` throwing `ResourceValueError`; `hasValue()` is the guard. A new params value recovers. `rxResource` turns an Observable that completes without emitting into `NG0991` (`RESOURCE_COMPLETED_BEFORE_PRODUCING_VALUE`).
- **`outputFromObservable` does not handle errors** — _"Errors notifications are not handled by Angular. You need to handle these manually."_ ([`output_from_observable.ts`][x-output]).
- **Effects:** the root scheduler carries the comment _"TODO: what happens if this throws an error?"_ ([`root_effect_scheduler.ts`][r-root-sched]) — error isolation between effects is not specified.

## State and sharing

- **Every signal is a multicast value cell** — the `BehaviorSubject` role, without subscription bookkeeping. Readers share one memoized value; there is no per-reader work to `share()`.
- **Conflation is the semantics.** Equality-gated writes plus tick batching mean intermediate values are invisible to reactions. `toObservable` makes it explicit: a `ReplaySubject(1)` fed by an effect, so _"If the signal is updated multiple times before the `effect` runs, the observable will only emit the last signal value"_ ([`to_observable.ts`][x-toobservable]). It is therefore unusable for event streams (every keystroke) — only for state.
- **`linkedSignal` is the "derived but user-overridable" cell** (selection that resets when the option list changes). `resource.value` is writable too: `set`/`update` puts it in `'local'` status and aborts any in-flight load.
- **Resource state is a state machine in one `linkedSignal`** (`ResourceState` = `extRequest`, internal status, `previousStatus`, `stream: Signal<ResourceStreamItem<T>>`), with the public `status` projected by a `computed`. On a _new_ request the stream is reset to `undefined`, so `value()` falls back to `defaultValue` during `'loading'` — the previous result is not kept; only `'reloading'` and `debounced` keep it. `resourceFromSnapshots` + `linkedSignal` is the documented way to build a "keep stale while loading" resource.

## Lifetime and ownership

Ownership is the **injector tree**. `DestroyRef` ([`destroy_ref.ts`][a-destroyref]) is the scope; every primitive registers on it:

| Primitive              | Registers                                                                                                                  |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `effect`               | `destroyRef.onDestroy(() => node.destroy())` unless `manualCleanup`; a view effect in its own view needs no registration   |
| `toSignal`             | `cleanupRef.onDestroy(sub.unsubscribe.bind(sub))`; deregistered on Observable `error`/`complete`; `manualCleanup` skips it |
| `toObservable`         | effect with `manualCleanup: true`, destroyed + `subject.complete()` from `DestroyRef`                                      |
| `resource`             | `injector.get(DestroyRef).onDestroy(() => this.destroy())` — aborts the in-flight load, returns to `idle`                  |
| `debounced`            | `onDestroy(() => { cancelTimer(); active = undefined; })`                                                                  |
| `takeUntilDestroyed`   | `takeUntil(destroyed$)` where `destroyed$` emits from `destroyRef.onDestroy` ([`take_until_destroyed.ts`][x-takeuntil])    |
| `outputFromObservable` | pipes the source through `takeUntilDestroyed(this.destroyRef)` and throws on subscribe after destroy                       |

Constraints enforced in dev mode: `assertInInjectionContext` (call from a constructor/field initializer or pass `{injector}`), and `assertNotInReactiveContext` for `effect` and `toSignal` — _"Invoking `toSignal` causes new subscriptions every time."_ The graph itself cannot leak an unobserved `computed` (liveness), and a live effect is always reachable from its owner. Leaks come from `manualCleanup: true` without a matching `destroy()`, and from loaders that ignore `abortSignal` and keep host resources (workers, sockets) alive.

## Testing

- **`TestBed.tick()`** (`@publicApi 20.0`) runs `ApplicationRef.tick()` with test fixtures included, which flushes root effects and refreshes views; `TestBed.flushEffects()` is now `@deprecated use TestBed.tick() instead` and simply calls `tick()` ([`test_bed.ts`][a-testbed]). The `httpResource` guide shows the shape — `TestBed.tick(); // Triggers the effect`, then flush the mock request, then `await TestBed.inject(ApplicationRef).whenStable()` ([`http-resource.md`][g-http-resource]); `whenStable` waits for the resource's `PendingTasks` task.
- **No virtual scheduler.** Signals and `debounced` call the global `setTimeout`; time control means patching globals. The testing guide now recommends `vi.useFakeTimers()` / `await vi.runAllTimersAsync()` and says of zone.js's clock: _"The use of `fakeAsync` is no longer recommended."_ (`fakeAsync` requires `zone.js`) ([`components-scenarios.md`][g-testing]).
- A debounce test therefore interleaves two drivers — `TestBed.tick()` to run the effect that arms the timer, the fake clock to fire it:

```ts
// not executed — illustrates the two clocks a debounce test must drive
it('debounces by 300 ms', async () => {
  vi.useFakeTimers();
  const injector = TestBed.inject(Injector);
  const query = signal('');
  const dq = debounced(query, 300, { injector });

  query.set('a');
  TestBed.tick(); // root effect runs: arms setTimeout(300), status 'loading'
  expect(dq.status()).toBe('loading');
  expect(dq.value()).toBe(''); // last settled value is kept

  await vi.advanceTimersByTimeAsync(299);
  expect(dq.status()).toBe('loading');
  await vi.advanceTimersByTimeAsync(1); // timer + .then microtask
  expect(dq.value()).toBe('a');
  vi.useRealTimers();
});
```

RxJS-side pipelines (the `toObservable(...).pipe(debounceTime)` idiom) can still use `TestScheduler` only if the scheduler is injected into `debounceTime`; the `toObservable` hop itself is driven by `TestBed.tick()`, not by any RxJS scheduler.

## The worked pipeline

Query field → debounce N ms (N adjustable) → hash a file set on a Worker with latest-wins cancellation → show result; a toggle enables/disables everything. Idiomatic 22.x uses `debounced` feeding a `resource`:

```ts
import {
  Component,
  debounced,
  resource,
  signal,
  untracked,
} from '@angular/core';

const sleep = (ms: number) => new Promise<void>(r => setTimeout(r, ms));

function hashOnWorker(
  worker: Worker,
  query: string,
  abortSignal: AbortSignal,
): Promise<string> {
  return new Promise((resolve, reject) => {
    const id = crypto.randomUUID();
    const onMessage = (e: MessageEvent) => {
      if (e.data.id !== id) return; // a stale job's reply
      worker.removeEventListener('message', onMessage);
      e.data.ok ? resolve(e.data.digest) : reject(e.data.error);
    };
    abortSignal.addEventListener(
      'abort',
      () => {
        worker.removeEventListener('message', onMessage);
        worker.postMessage({ type: 'cancel', id }); // the worker stops at its next yield
        reject(abortSignal.reason);
      },
      { once: true },
    );
    worker.addEventListener('message', onMessage);
    worker.postMessage({ type: 'hash', id, query });
  });
}

@Component({
  selector: 'hash-search',
  template: `
    <input [value]="query()" (input)="query.set($any($event.target).value)" />
    <input
      type="number"
      [value]="delayMs()"
      (input)="delayMs.set(+$any($event.target).value)"
    />
    <input
      type="checkbox"
      [checked]="enabled()"
      (change)="enabled.set(!enabled())"
    />
    @if (digest.isLoading()) {
      <p>hashing…</p>
    }
    @if (digest.hasValue()) {
      <p>{{ digest.value() }}</p>
    }
    @if (digest.status() === 'error') {
      <p>failed</p>
    }
  `,
})
export class HashSearch {
  private readonly worker = new Worker(
    new URL('./hash.worker', import.meta.url),
  );
  readonly query = signal('');
  readonly delayMs = signal(250);
  readonly enabled = signal(true);

  // Toggle folded into the source: switching off settles synchronously to `undefined`,
  // which supersedes any pending window.
  readonly settledQuery = debounced(
    () => (this.enabled() ? this.query() : undefined),
    q => (q === undefined ? undefined : sleep(untracked(this.delayMs))),
  );

  readonly digest = resource({
    params: () =>
      this.enabled() ? this.settledQuery.value() || undefined : undefined,
    loader: ({ params: q, abortSignal }) =>
      hashOnWorker(this.worker, q, abortSignal),
  });
}
```

Trace (ms; N = 250; "tick" = the rAF/`setTimeout` race that runs change detection):

| t     | Event                    | What runs                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| ----- | ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0     | construct + first tick   | `debounced`'s `linkedSignal` computes `{resolved, ''}`; its effect sees `''` equal to the resolved value and returns. The resource's `loadEffect`: params `undefined` (empty query) → `idle`.                                                                                                                                                                                                                                                                                               |
| 100   | type `a`                 | `query.set('a')`: push phase marks the `debounced` effect dirty and the template; one tick is scheduled. Tick (~t104): effect sees `'a'` ≠ `''` → `sleep(250)` (timer T1, due ~354) → state `{loading, value: ''}`. `params` still reads `''` → unchanged; the resource stays `idle`.                                                                                                                                                                                                       |
| 180   | type `ab` (in debounce)  | Tick: `'ab'` ≠ pending `'a'` → `cancelTimer()` is a no-op for a custom wait → `sleep(250)` T2 (due ~434); `active = T2`. T1 still fires at ~354; its `.then` fails `active === result` and is ignored.                                                                                                                                                                                                                                                                                      |
| 434   | T2 fires                 | `state.set({resolved, 'ab'})` → notification → tick: `params` = `'ab'` → resource state `loading` (`value()` → `undefined`) → `loadEffect`: `abortInProgressLoad()` (none), new controller C1, loader posts `hash#1`.                                                                                                                                                                                                                                                                       |
| 500   | type `abc` (during hash) | `debounced` → `loading`, `value()` still `'ab'`, so `params` is unchanged and `hash#1` **keeps running** through the window. At ~754 the window settles: `params` = `'abc'` → `loadEffect` calls `C1.abort()` → listener posts `cancel#1` synchronously → new C2, posts `hash#2` in the same effect run. No wait for the worker to acknowledge.                                                                                                                                             |
| 800   | N := 500                 | `delayMs.set(500)`: read under `untracked`, so nothing re-runs; the next keystroke waits 500. The window in progress is not restarted.                                                                                                                                                                                                                                                                                                                                                      |
| 900   | toggle off               | One push phase dirties the `debounced` effect, `params` and the template. Tick: both effects are view effects of the component's host view (it was created in a field initializer), run by `runEffectsInView` in creation order — `debounced` first gets `undefined` → wait fn returns `undefined` → `{resolved, undefined}` synchronously (any pending custom timer is orphaned). `params` → `undefined` → resource `idle` → `loadEffect` aborts C2 → `cancel#2`. `value()` → `undefined`. |
| later | late worker reply        | The `message` listener was removed on abort; even if it had not been, `shouldDiscard()` drops a stale settle.                                                                                                                                                                                                                                                                                                                                                                               |

**Variant: the loader sleeps on the `AbortSignal`** — one `resource` does both debounce and hash, with genuinely cancelled timers:

```ts
const abortableSleep = (ms: number, s: AbortSignal) => new Promise<void>((res, rej) => {
  const t = setTimeout(res, ms);
  s.addEventListener('abort', () => { clearTimeout(t); rej(s.reason); }, {once: true});
});

readonly digest = resource({
  params: () => (this.enabled() && this.query() ? {q: this.query(), ms: this.delayMs()} : undefined),
  loader: async ({params, abortSignal}) => {
    await abortableSleep(params.ms, abortSignal);           // every keystroke aborts this
    return hashOnWorker(this.worker, params.q, abortSignal);
  },
});
```

Each keystroke changes `params`, aborting both the pending sleep and any running hash — stricter latest-wins than the first version (typing cancels an in-flight hash immediately). A new N restarts the window (it is part of `params`), but also re-hashes an unchanged query, and `value()` is `undefined` throughout every window because `loading` drops the previous value.

**Fit with a per-frame UI.** The model maps well: templates are effects that pull signals during a frame-coalesced tick, exactly what an immediate-mode rebuild does with `wakeIn`. The misfits are time and cancellation: debounce lives on host timers with no injectable clock; the first hop after any timer costs a tick; cancel is fire-and-forget with no join; and `debounced`'s custom wait cannot be cancelled at all.

---

## Strengths

- **Glitch-free push-pull with versioned equality** — diamonds never expose inconsistent state, and equal recomputations stop propagation before any effect runs.
- **GC-friendly graph.** Liveness means unobserved derivations need no disposal; only effects (always owned) hold back-edges.
- **Frame-coalesced, two-tier effect scheduling** — root effects before any view, view effects inside the owning view's refresh, the whole tick raced between rAF and `setTimeout`.
- **Async as signal state.** `resource` turns latest-wins async work into five readable signals with a closed status set, real `AbortSignal` cancellation, and stability tracking via `PendingTasks`.
- **Scoped lifetime by default.** Every primitive binds to the ambient `DestroyRef`; `takeUntilDestroyed` brings the same scoping to plain RxJS.
- **Both models, one runtime.** `toSignal`/`toObservable`/`rxResource` make the boundary explicit and small (each adapter is one file of 77–266 lines), and document exactly what crossing it costs.

## Weaknesses

- **No time model.** No scheduler, clock or virtual time; `debounced` uses the global `setTimeout`, and tests must patch globals and alternate `TestBed.tick()` with a fake clock.
- **Latency hops at every boundary.** An effect-driven step (`debounced`, `toObservable`, `resource`) starts only at the next tick; a chain of them adds a tick per hop.
- **One concurrency policy.** `resource` is always switch-latest; no queue, exhaust or bounded parallelism.
- **Cancel without join.** `abort()` is advisory; a loader that ignores it runs on, and nothing reports when cancelled work actually stops.
- **`debounced` is partial.** Experimental; custom waits are superseded but not cancelled; a changed duration does not restart the window; not stability-tracked.
- **`loading` discards the previous value** for new params, so naive search UIs flicker unless built on `resourceFromSnapshots` or `debounced`'s keep-last behaviour.
- **`toObservable` is lossy and asynchronous** — state-only; unusable for discrete events, and its first value arrives a tick late.
- **Effect error handling unspecified** (the scheduler's own `TODO`).

## Key design decisions and trade-offs

| Decision                                                      | Rationale                                                                      | Trade-off                                                                           |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------- |
| Push invalidation, pull recomputation                         | Glitch-freedom without topological sorting; no user code during notification   | Reactions are always deferred; nothing observes a write synchronously               |
| Per-node `version` + global `epoch`                           | Equal recomputations cut propagation; clean nodes skip polling in O(1)         | Two counters and a poll walk on every read of a non-live `computed`                 |
| Back-edges only to live consumers                             | Unobserved derivations are collectable with no `dispose`                       | Non-live reads poll; liveness transitions add bookkeeping                           |
| Effects scheduled by change detection (root first, then view) | Effects see consistent inputs and can create views safely                      | Timing is "unspecified"; effects are not a general-purpose reactive sink            |
| Tick = first of rAF and `setTimeout`                          | Coalesce a user interaction into one pass; keep background tabs and tests fast | Every effect-driven hop costs up to a frame                                         |
| Async derivation as `resource` with `AbortSignal`             | Platform cancellation token; works with `fetch` and `HttpClient` unchanged     | Single switch policy; cancellation is cooperative and unjoined                      |
| Debounce as a `Resource` over host timers                     | Fits the status model (`loading` while pending, keep last value)               | No injectable clock; custom waits are not cancellable                               |
| Lifetime from the DI `DestroyRef`                             | Structured teardown without explicit subscriptions                             | Every primitive needs an injection context or an explicit `injector`                |
| Keep RxJS, bridge with `toSignal`/`toObservable`              | Signals stay minimal; event algebra stays where it is mature                   | Two mental models; `toObservable` conflates and delays, `toSignal` loses completion |

## Sources

- Angular repository at `8b15295e8c7f1543d41dadb5955279702be52c16` (2026-11-20): signal primitives ([`README.md`][p-readme], [`graph.ts`][p-graph], [`signal.ts`][p-signal], [`computed.ts`][p-computed], [`effect.ts`][p-effect], [`linked_signal.ts`][p-linked]); framework reactivity ([`effect.ts`][r-effect], [`root_effect_scheduler.ts`][r-root-sched], [`view_effect_runner.ts`][r-view-runner], [`linked_signal.ts`][r-linked], [`after_render_effect.ts`][r-after-render], [`change_detection.ts`][r-cd]); scheduling ([`application_ref.ts`][a-appref], [`zoneless_scheduling_impl.ts`][a-zoneless-impl], [`callback_scheduler.ts`][a-raf]); resources ([`api.ts`][r-api], [`resource.ts`][r-resource], [`debounce.ts`][r-debounce], [`from_snapshots.ts`][r-from-snapshots], [`http/resource.ts`][h-resource], [`pending_tasks.ts`][a-pending]); interop ([`to_signal.ts`][x-tosignal], [`to_observable.ts`][x-toobservable], [`take_until_destroyed.ts`][x-takeuntil], [`output_from_observable.ts`][x-output], [`rx_resource.ts`][x-rxresource]); [`test_bed.ts`][a-testbed]; [`destroy_ref.ts`][a-destroyref]; [public-API golden][a-golden].
- Guides (source → rendered): [`overview.md`][g-overview] → [angular.dev/guide/signals][d-overview]; [`effect.md`][g-effect] → [/guide/signals/effect][d-effect]; [`resource.md`][g-resource] → [/guide/signals/resource][d-resource]; [`linked-signal.md`][g-linked] → [/guide/signals/linked-signal][d-linked]; [`debounced.md`][g-debounced] → [/guide/signals/debounced][d-debounced]; [`signals-interop.md`][g-interop] → [/ecosystem/rxjs-interop][d-interop]; [`take-until-destroyed.md`][g-takeuntil] → [/ecosystem/rxjs-interop/take-until-destroyed][d-takeuntil]; [`http-resource.md`][g-http-resource] → [/guide/http/http-resource][d-http-resource]; [`zoneless.md`][g-zoneless] → [/guide/zoneless][d-zoneless]; [`components-scenarios.md`][g-testing].
- TC39: [`proposal-signals` `README.md`][tc39-readme] (`9124ed91b24b`); [`signal-polyfill` `src/graph.ts`][poly-graph] (`958ad56b92e3`).
- Siblings: [RxJS][rxjs], [TC39 Signals][tc39], [Solid signals](./solid-signals.md).

<!-- References -->

[repo]: https://github.com/angular/angular
[a-package]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/package.json
[a-license]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/LICENSE
[a-core-package]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/packages/core/package.json
[a-golden]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/goldens/public-api/core/index.api.md
[p-readme]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/packages/core/primitives/signals/README.md
[p-graph]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/packages/core/primitives/signals/src/graph.ts
[p-signal]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/packages/core/primitives/signals/src/signal.ts
[p-computed]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/packages/core/primitives/signals/src/computed.ts
[p-effect]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/packages/core/primitives/signals/src/effect.ts
[p-linked]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/packages/core/primitives/signals/src/linked_signal.ts
[r-effect]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/packages/core/src/render3/reactivity/effect.ts
[r-root-sched]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/packages/core/src/render3/reactivity/root_effect_scheduler.ts
[r-view-runner]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/packages/core/src/render3/reactivity/view_effect_runner.ts
[r-linked]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/packages/core/src/render3/reactivity/linked_signal.ts
[r-after-render]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/packages/core/src/render3/reactivity/after_render_effect.ts
[r-cd]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/packages/core/src/render3/instructions/change_detection.ts
[a-appref]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/packages/core/src/application/application_ref.ts
[a-zoneless-impl]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/packages/core/src/change_detection/scheduling/zoneless_scheduling_impl.ts
[a-raf]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/packages/core/src/util/callback_scheduler.ts
[a-pending]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/packages/core/src/pending_tasks.ts
[a-destroyref]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/packages/core/src/linker/destroy_ref.ts
[a-testbed]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/packages/core/testing/src/test_bed.ts
[r-api]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/packages/core/src/resource/api.ts
[r-resource]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/packages/core/src/resource/resource.ts
[r-debounce]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/packages/core/src/resource/debounce.ts
[r-from-snapshots]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/packages/core/src/resource/from_snapshots.ts
[h-resource]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/packages/common/http/src/resource.ts
[x-tosignal]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/packages/core/rxjs-interop/src/to_signal.ts
[x-toobservable]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/packages/core/rxjs-interop/src/to_observable.ts
[x-takeuntil]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/packages/core/rxjs-interop/src/take_until_destroyed.ts
[x-output]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/packages/core/rxjs-interop/src/output_from_observable.ts
[x-rxresource]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/packages/core/rxjs-interop/src/rx_resource.ts
[g-overview]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/adev/src/content/guide/signals/overview.md
[g-effect]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/adev/src/content/guide/signals/effect.md
[g-resource]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/adev/src/content/guide/signals/resource.md
[g-linked]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/adev/src/content/guide/signals/linked-signal.md
[g-debounced]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/adev/src/content/guide/signals/debounced.md
[g-interop]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/adev/src/content/ecosystem/rxjs-interop/signals-interop.md
[g-takeuntil]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/adev/src/content/ecosystem/rxjs-interop/take-until-destroyed.md
[g-http-resource]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/adev/src/content/guide/http/http-resource.md
[g-zoneless]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/adev/src/content/guide/zoneless.md
[g-testing]: https://github.com/angular/angular/blob/8b15295e8c7f1543d41dadb5955279702be52c16/adev/src/content/guide/testing/components-scenarios.md
[d-overview]: https://angular.dev/guide/signals
[d-effect]: https://angular.dev/guide/signals/effect
[d-resource]: https://angular.dev/guide/signals/resource
[d-linked]: https://angular.dev/guide/signals/linked-signal
[d-debounced]: https://angular.dev/guide/signals/debounced
[d-interop]: https://angular.dev/ecosystem/rxjs-interop
[d-takeuntil]: https://angular.dev/ecosystem/rxjs-interop/take-until-destroyed
[d-http-resource]: https://angular.dev/guide/http/http-resource
[d-zoneless]: https://angular.dev/guide/zoneless
[tc39-readme]: https://github.com/tc39/proposal-signals/blob/9124ed91b24bb02ff7408b2fcf5abb6e18b095d7/README.md
[poly-graph]: https://github.com/proposal-signals/signal-polyfill/blob/958ad56b92e321b84673a42c3d16109f72209017/src/graph.ts
[rxjs]: ./rxjs.md
[rxjs-weak]: ./rxjs.md#weaknesses
[rxjs-time]: ./rxjs.md#time-and-scheduling
[tc39]: ./tc39-signals.md
