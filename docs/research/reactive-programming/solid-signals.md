# Solid 2.0 signals (TypeScript)

The reactive core of SolidJS 2.0, `@solidjs/signals`: a fine-grained, push-pull signal graph whose computations may return a `Promise` or `AsyncIterable`, with the "not ready" state propagated through the graph instead of through a separate resource type.

| Field             | Value                                                                                                                                                                      |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | TypeScript (ES modules; JSX through the Solid compiler, which this survey does not cover)                                                                                  |
| License           | MIT ([`packages/signals/LICENSE`][license])                                                                                                                                |
| Repository        | [solidjs/solid][repo], package [`packages/signals`][pkg]                                                                                                                   |
| Documentation     | [docs.solidjs.com][docs] · [package `README.md`][readme] · the frozen 2.0 RFCs under [`documentation/solid-2.0/`][rfc01] · the async rules [`RULES-FUNDAMENTALS.md`][fund] |
| Category          | fine-grained signals (push-pull)                                                                                                                                           |
| Versions surveyed | `solid-js@2.0.3` / `@solidjs/signals@2.0.3` (commit `68406c2`, 2026-11-19); `solid-js@1.9.15` for the 1.x comparison                                                       |
| Core abstraction  | a node in an ownership tree that is also a node in a dependency graph: `Signal` (writable), `Computed` (memo, effect, boundary) — values are read by calling an accessor   |

> **Release:** Solid 2.0.0 shipped 2026-11-16; this survey reads the `solid-js@2.0.3` tag (`68406c2077eff22c67f71db4a16bf7026ddceee1`, "Version packages (#5059)"). The RFCs under `documentation/solid-2.0/` carry the banner _"Frozen design record (2.0.0, 2026-11-17)"_; current async semantics live in `packages/signals/docs/RULES-*.md`.

---

## Overview

### What it solves

A UI wants three things from state: a derived value that is always consistent with its inputs, side effects that run once per consistent state, and a way to show something sensible while some derived value is waiting on I/O. Solid 1.x delivered the first two with synchronous fine-grained signals and bolted the third on as `createResource`, a separate primitive with its own `.loading`/`refetch` surface ([`signal.ts` at 1.9.15][v1-signal]). 2.0 folds async into the graph itself. From [`05-async-data.md`][rfc05]:

> _"Solid 2.0 makes async a first-class capability of computations: `createMemo`, derived stores, and other computations can return **Promises** or **AsyncIterables**, and consumers interact with them through normal accessors. Pending async values signal "not ready" through the reactive graph, and `Loading` is the boundary that turns that state into UI. This removes the need for a separate `createResource` primitive."_

That is the part most relevant to the sparkles pipeline: a query feeds an async derivation, and the library — not the caller — decides which answer is current, what the screen shows while it waits, and when to drop a superseded answer.

### Design philosophy

The package README positions the core in one sentence ([`README.md`][readme]):

> _"`@solidjs/signals` is a push-pull hybrid reactive system. Signals hold values, computeds derive from them, and effects run side effects — all connected through an automatic dependency graph. Updates are **batched** and flushed asynchronously via microtask, giving you consistent state without glitches."_

Three commitments shape the rest:

1. **The screen is whole.** The first of the eleven immutable async fundamentals ([`RULES-FUNDAMENTALS.md`][fund], F-1): _"Every frame the screen shows is consistent: a value and everything on screen derived from it changed in the same frame."_ Glitch-freedom is extended from synchronous derivations to async ones — a change whose on-screen consequences need unanswered async is _held_ (F-2) rather than shown half-computed.
2. **Writes are events, not derivations.** Writing a signal inside a memo, effect compute, or component body throws in dev (`REACTIVE_WRITE_IN_OWNED_SCOPE`, [`01-reactivity-batching-effects.md`][rfc01]); writes belong in event handlers, effect callbacks, timers, or `action`s.
3. **Tracking is separated from side effects.** `createEffect(compute, effect)` runs every compute half before any effect half, _"which is required for async, Loading, and Errored boundaries"_ ([`01-reactivity-batching-effects.md`][rfc01]).

Within this survey Solid is the pull-and-push-of-values data point, against [RxJS][rxjs] (push of events over time) and [Effect-TS][effect-ts] (a lazy description of one computation); see [Concepts][concepts] and the [comparison][comparison].

---

## Core abstractions and types

| Concept             | API                                                                     | Role                                                                                                          |
| ------------------- | ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| Writable cell       | `createSignal(v, { equals, ownedWrite, unobserved })`                   | `[get, set]` pair; `set` stages the write until the next flush                                                |
| Writable derived    | `createSignal(prev => f(src(), prev), init)`                            | A memo that can also be written (replaces 1.x "derived signal + effect" patterns)                             |
| Memo                | `createMemo(fn, { equals, lazy, loadingValue, unobserved })`            | Cached derivation; eager unless `lazy`; may return `Promise`/`AsyncIterable`                                  |
| Lagging memo        | `createDeferred(fn)`                                                    | An async memo whose re-asks never hold readers (it may lag, never lead)                                       |
| Effect              | `createEffect(compute, effect \| { effect, error })`                    | Two-phase: tracked compute, untracked effect returning a cleanup                                              |
| Render effect       | `createRenderEffect(compute, apply)`                                    | Same split, run in the render queue before user effects; the only "reader" the hold rules count               |
| Single-phase effect | `createTrackedEffect(fn)`, `onSettled(fn)`                              | Escape hatches; cannot create nested primitives                                                               |
| Async verdicts      | `isPending(fn)`, `latest(fn)`, `refresh(x)`, `resolve(fn)`, `until(fn)` | Probe or drive in-flight state without joining a hold                                                         |
| Not-ready signal    | `NotReadyError`                                                         | The control-flow throw a read of a pending node produces ([`error.ts`][error])                                |
| Mutations           | `action(function* () { … })`, `createOptimistic`, `affects`             | Transactional async writes; tentative values that revert when the hold commits                                |
| Ownership           | `createRoot`, `getOwner`, `runWithOwner`, `onCleanup`                   | Lifetime tree; disposal cascades to children and runs cleanups                                                |
| Boundaries          | `createLoadingBoundary`, `createErrorBoundary`                          | `<Loading>`/`<Errored>` in JSX; catch pending/error status from the content below                             |
| Push-source adapter | `from(source)`                                                          | Callback, Observable or `AsyncIterable` → an iterable a memo returns; closed on supersede ([`from.ts`][from]) |
| Stores              | `createStore`, `createProjection`, `reconcile`, `deep`                  | Proxy-based per-property signals; not needed for this survey's pipeline                                       |

The public export list is [`src/index.ts`][index]; the user-facing constructors are in [`src/signals.ts`][signals].

---

## How it works

### The graph: heights, a dirty heap, and two marks

Every `Computed` carries a `_height` (one more than its highest computed dependency) and a bit set `_flags` whose low bits are the classic three-colour state ([`constants.ts`][constants]):

```ts
// packages/signals/src/core/constants.ts
export const REACTIVE_NONE = 0;
export const REACTIVE_CHECK = 1 << 0;
export const REACTIVE_DIRTY = 1 << 1;
```

A write to a signal enqueues its direct subscribers into a height-bucketed heap (`dirtyQueue`, [`heap.ts`][heap]). When anything needs a consistent view, `markHeap` walks the heap and `markNode` colours each queued node `DIRTY` and, transitively, everything downstream `CHECK`:

```ts
// packages/signals/src/core/heap.ts — markNode
export function markNode(el: Computed<unknown>, newState = REACTIVE_DIRTY) {
  const flags = el._flags;
  if ((flags & (REACTIVE_CHECK | REACTIVE_DIRTY)) >= newState) return;
  el._flags = (flags & ~(REACTIVE_CHECK | REACTIVE_DIRTY)) | newState;
  for (let link = el._subs; link !== null; link = link._nextSub) {
    markNode(link._sub, REACTIVE_CHECK);
  }
}
```

The flush then drains the heap in ascending height (`runHeap`), so a node recomputes only after every node it can depend on has settled — the topological order that makes propagation glitch-free. A node that turns out to sit higher than its bucket is moved (`adjustHeight`) rather than run early.

### Pull on read: `updateIfNecessary`

A read between flushes (a `latest()` probe, a lazy memo, a mid-tick pull) does not wait for the heap. `updateIfNecessary` ([`core.ts`][core]) walks the reader's dependencies, bringing each `CHECK` dependency up to date, and recomputes only if one of them actually changed and flipped the reader to `DIRTY`:

```ts
// packages/signals/src/core/core.ts — updateIfNecessary (abridged)
if (el._flags & REACTIVE_CHECK) {
  for (let d = el._deps; d; d = d._nextDep) {
    const dep = d._dep;
    if ((dep as Computed<unknown>)._fn) updateIfNecessary(dep as Computed<unknown>);
    if (el._flags & REACTIVE_DIRTY) break;
  }
}
if (el._flags & REACTIVE_DIRTY || …) recompute(el);
```

That is the "push-pull" of the README: dirtiness is _pushed_ (marks), values are _pulled_ (recompute on demand, cut off by `equals`, `===` by default).

### The flush: microtask, heap, then two effect queues

A setter calls `schedule()`, which queues one microtask per batch ([`scheduler.ts`][scheduler]):

```ts
// packages/signals/src/core/scheduler.ts
export function schedule() {
  if (halted) {
    notifyHalted();
    return;
  }
  if (scheduled) return;
  scheduled = true;
  if (!syncDepth && !globalQueue._running) {
    queueMicrotask(flush);
  }
}
```

`GlobalQueue.flush` sweeps dormant (unobserved, autodisposing) nodes, runs the heap, settles holds, advances the global `clock`, then runs the render-effect queue and the user-effect queue — in that order:

```ts
// packages/signals/src/core/scheduler.ts — GlobalQueue.flush (abridged)
sweepDormant();
runHeap(dirtyQueue, GlobalQueue._update);
this.settle();
clock++;
this.run(EFFECT_RENDER);
this.run(EFFECT_USER);
```

Until the flush, reads return the last committed value: _"Signal writes are batched — reads after a write won't reflect the new value until `flush()` runs"_ ([`README.md`][readme]). F-10 states the same thing as a rule: _"Between `set(x)` and the flush that carries it, nothing shows the write"_ ([`RULES-FUNDAMENTALS.md`][fund]). `flush()` drains synchronously; `flush(fn)` runs `fn`'s writes in a synchronous flush scope.

### Async computations: flights, `NotReadyError`, holds

When a compute returns a thenable or async iterable, `handleAsync` ([`async.ts`][async]) records it as the node's flight (`_x._inFlight = result`) and the node's status becomes pending. A tracked read of a pending node with no committed value throws `NotReadyError`; the throw is _"addressed to the graph, not to the code around the read"_ (F-12) — it marks the reader pending and the nearest armed `<Loading>` boundary catches it. A pending node that _does_ have a committed value serves it, and F-2 decides the rest: if showing the change would put a render effect on screen that needs the unanswered async, the whole change is held — the screen keeps its previous content and the change reveals as one frame when every such flight has landed.

A landing is accepted only from the current flight:

```ts
// packages/signals/src/core/async.ts — handleAsync, the landing path
const asyncWrite = (value: T, then?: () => void) => {
  if (el._x?._inFlight !== result) return;
  …
  // A newer write re-runs the node. A first answer is still a produced value:
  // it lands before the re-ask (D-22, F-9). Only the verdict engine can tell.
  if (el._flags & REACTIVE_DIRTY && !(holdWorkHook && el._statusFlags & STATUS_UNINITIALIZED))
    return;
```

The rejection path (`handleError`) has the same identity guard. A compute that answers synchronously clears `_inFlight` to `null`, so a pending promise from the previous run can never land afterwards.

---

## Evaluation model

- **Push-pull.** Writes push `DIRTY`/`CHECK` marks; values are pulled by the height-ordered heap at flush or by `updateIfNecessary` on read. `equals` cuts propagation: a memo that recomputes to an equal value leaves its dependents' `CHECK` unconfirmed and they do not re-run.
- **Eager memos by default, lazy on request.** _"Without `lazy`, memos compute eagerly on creation. With `lazy: true`, the memo is inert until something reads it"_; `lazy` also _"opts a memo into **autodisposal**"_ when its last subscriber leaves ([`01-reactivity-batching-effects.md`][rfc01]). Unowned memos autodispose too.
- **Glitch-free, and extended to async.** Synchronous derivations are glitch-free by topological order. Async derivations are made "glitch-free" by holding: F-1 forbids _"a new value beside a stale derivation of it"_ even when the derivation is waiting on a promise. Only `createDeferred` (declared lag), `latest`/`isPending` (declared display-ahead reads), and optimistic values are permitted exceptions.
- **Batched, not synchronous.** 1.x propagated synchronously at the end of each write or `batch(fn)` ([`signal.ts` at 1.9.15][v1-signal], `runUpdates`). 2.0 removes `batch`; every write in a synchronous tick joins one microtask flush. A render effect still runs synchronously _on creation_; its later runs come from the flush.
- **Dynamic dependencies.** Dependencies are re-recorded on every run. In an `async` compute only reads _before the first `await`_ are tracked; dev builds turn a later read of a pending source into an error: _"Reads inside async computations only register as dependencies before the first `await`"_ ([`async.ts`][async]).

## Composition

Composition is function composition over accessors — there are no operators. A derivation is a memo that reads other accessors; combining two sources means reading both. Sync and async compose without combinators: a sync memo over an async memo is itself pending while its input is (the read throws `NotReadyError` through it), so `createMemo(() => results().length)` needs no `map`/`switchMap`. Three building blocks cover what an operator library would:

- `from(source)` adapts any push source — a subscribe function, an RxJS/TC39 Observable (`Symbol.observable` interop), or an `AsyncIterable` — into a value a memo can return; a subscription _"keeps the latest value: values that arrive between pulls coalesce"_ ([`from.ts`][from]).
- `mapArray`/`repeat` give keyed list mapping; `flatten` and `merge` are structural helpers.
- Custom primitives are plain functions that create signals and effects under the caller's owner (the dev tooling even folds `createDebounced.value` into a `createDebounced` label, [`08-dev-diagnostics.md`][rfc08] — the name is the user's; the library ships no such primitive).

Missing by design: time operators (`debounceTime`, `throttle`, `delay`), multicasting operators (every accessor is already shared), and stream completion (a signal never "completes").

## Time and scheduling

There is no scheduler abstraction and no virtual time. The only scheduling decisions are internal: _when_ a flush runs (a microtask, or a manual `flush()`), and _in which order_ work runs within one (heap by height, then `EFFECT_RENDER`, then `EFFECT_USER`). `onFlush(fn)` runs a callback right after the pending flush; `onSettled(fn)` runs once the current activity has settled.

Timers are ordinary host timers. A debounce is expressed either as an effect whose effect half arms a `setTimeout` and returns `() => clearTimeout(id)` as its cleanup (the effect's next run, or its disposal, cancels the pending timer), with the timer callback writing a signal (a timer callback has no owner, so the write is legal); or as an async memo that `await`s a delay (the debounce window then _is_ a flight — readers hold and `isPending` is `true` during it); or at the event source, in the input handler. No `debounce`/`throttle` primitive ships in `@solidjs/signals`; the dev diagnostics point at the gap when they flag abandoned flights — _"Put a debounced or equality-gated derivation between the input and the fetch"_ ([`08-dev-diagnostics.md`][rfc08]). Community primitives (`@solid-primitives/scheduled` in 1.x) exist outside this repository and were not surveyed for 2.0 compatibility (**unverified**).

The test suite's answer to missing virtual time is a hand-rolled manual clock: [`async-chain-supersession.test.ts`][t-chain] replaces timers with `delay(ms)` promises resolved by `advanceTo(t)`, with a `settle()` that drains microtasks and calls `flush()` between resolutions — _"the same interleaving a browser produces with real timers, minus the waiting."_

## Concurrency and cancellation

JavaScript gives Solid one thread, so "concurrency" here means overlapping flights, not parallel computation. Off-thread work (a Web Worker) is just a promise the compute returns.

- **Latest-wins is built in, by result discarding.** Each re-run of an async compute replaces `_inFlight`; a landing or rejection whose promise is not the current `_inFlight` returns without effect (the identity guard above). 1.x `createResource` had the same rule in user-visible form (`if (pr === p)` in `loadEnd`, [`signal.ts` at 1.9.15][v1-signal]). The RFC is explicit that this is the whole of the built-in mechanism: _"Solid drops a superseded run's result on its own; stopping the work itself is up to the run"_ ([`05-async-data.md`][rfc05]).
- **There is no `AbortSignal` parameter.** Cancellation is expressed with `onCleanup` inside the compute, which the engine runs promptly for a superseded run that never committed: _"`onCleanup(() => ac.abort())` registered before the first `await` aborts an unfinished request promptly"_ ([`05-async-data.md`][rfc05]). The _committed_ run's cleanups are different: _"The run on screen stays fully live until its replacement lands (a value or an error)."_ [`async-cleanup-timing.test.ts`][t-cleanup] pins the order: superseding `b` with `c` logs `cleanup b` immediately; `cleanup a` (the committed run) runs only when `C` lands, just before `show C`.
- **Iterables are closed on supersede.** _"An iterable the compute returns is closed (`return()`) as soon as the run re-runs"_; an iterable consumed with `for await` inside the compute must be wrapped in `from()` to get the same prompt close, because _"the language can't interrupt a generator paused on an `await`"_ ([`05-async-data.md`][rfc05], [`from.ts`][from] `onSupersede`).
- **Stale-while-revalidate is the default after a first answer.** A re-run of a memo with a committed value keeps serving it; the change is held (F-2) unless a boundary catches it. `isPending(fn)` reports _"a new question"_ in flight; `refresh(x)` is a _quiet_ re-ask that does not read as pending (F-9); `affects(x); refresh(x)` makes it loud.
- **Transitions are implicit and plural.** _"Multiple transitions can be in flight; "entangling" determines what should block what"_ ([`05-async-data.md`][rfc05]). `action(function* …)` makes the hold explicit for writes that follow async work; `createOptimistic` shows a guess for the hold's duration ([`06-actions-optimistic.md`][rfc06]).
- **Coordination is opt-out per node.** Because one slow flight holds the whole change, `createDeferred` exists: _"Once it has a committed value, its own non-finality is invisible to the downstream graph"_ ([`create-deferred.md`][deferred-doc]); it is _"verdict-loud"_ (`isPending` still sees the flight) and _"never leads"_.

## Errors and completion

- **Errors are a node status, not a thrown value the reader owns.** A rejected flight or a throwing compute marks the node errored; readers are errored with it, and _"`try/catch` around a reactive read is not a channel"_ (F-12, amended 2026-10-30). Recovery goes through `createErrorBoundary(fn, (error, reset) => …)` (`<Errored>`), whose fallback receives the error accessor and a `reset` ([`boundaries.ts`][boundaries]).
- **Pending is never an error.** _"`<Errored>` does not catch it and never shows its fallback for a wait"_ (F-12).
- **Effects split their error arms by phase.** A compute-phase error goes to the `EffectBundle`'s `error` handler or is _"logged and the effect simply skips that run"_; an effect-phase throw _"is treated as an unhandled application error"_ ([`signals.ts`][signals] `createEffect` doc).
- **Escape halts the system.** _"An error that escapes every boundary halts the reactive system (`REACTIVITY_HALTED`); later writes are ignored"_ (F-12); `schedule()` checks `halted` first ([`scheduler.ts`][scheduler]).
- **No completion.** A signal or memo has no terminal state; it lives until its owner is disposed. An async iterable that finishes simply leaves the node at its last value.

## State and sharing

All state is shared by construction: an accessor is a function any number of readers can call, and every reader sees the same committed value at the same flush (the hot-and-replayed behaviour an RxJS user gets from `shareReplay(1)`, for free). The `equals` option decides propagation; `unobserved` fires when the last subscriber leaves, the hook for releasing external resources a source holds only while watched. Stores extend this to nested objects with per-property signals behind a `Proxy`, `reconcile` for diffing server data in, and `createProjection` for derived stores ([`README.md`][readme]). Writes are restricted, not state: `ownedWrite: true` is the opt-in for a signal that must be written from inside a computation, and the RFC warns it _"is not a general-purpose escape hatch"_ ([`01-reactivity-batching-effects.md`][rfc01]).

## Lifetime and ownership

Every primitive is created under the current owner and linked into its children; disposing an owner disposes its subtree and runs its `onCleanup` callbacks ([`owner.ts`][owner]). `createRoot(dispose => …)` makes a new tree and hands back its `dispose`; created inside another owner, it is attached to it, and the source comment says to _"detach explicitly if the root must outlive its creator"_ with `runWithOwner(null, …)` ([`owner.ts`][owner] `createRoot`). Context (`createContext`/`getContext`/`setContext`) rides the same tree.

A computation's children and cleanups belong to its _run_: when the compute re-runs, the previous run's children are disposed — for async runs on the schedule described under [Concurrency](#concurrency-and-cancellation) (superseded uncommitted runs at once, the committed run when its replacement lands). `onCleanup` is _"not expected to be used inside side effects"_; an effect's effect half returns its cleanup instead ([`01-reactivity-batching-effects.md`][rfc01]). Creating a memo, effect or root inside an effect callback throws (`PRIMITIVE_IN_EFFECT_CALLBACK`, [`08-dev-diagnostics.md`][rfc08]), so the owner tree is shaped only by computations and roots.

## Testing

`@solidjs/signals` is tested with Vitest (`"test": "vitest run"`, [`package.json`][package]) over ~475 test files, many named after the rule or issue they pin (`create-deferred.test.ts`, `async-cleanup-timing.test.ts`). The idiom is deterministic by construction: write, call `flush()`, assert; for async, hold promises open with explicit gates and resolve them by hand ([`create-deferred.test.ts`][t-deferred]: a `gated()` helper whose `gates[i]()` resolves the i-th flight, and a `tick()` that drains microtasks then flushes). Time is simulated with the manual clock described under [Time and scheduling](#time-and-scheduling); there is no `TestClock` in the library. The async rules are cross-referenced to scenario tables (`SCENARIOS.md`), and the dev build ships a diagnostics channel with stable codes (`REACTIVE_WRITE_IN_OWNED_SCOPE`, `PENDING_ASYNC_UNTRACKED_READ`, …) that tests assert on ([`08-dev-diagnostics.md`][rfc08]).

## The worked pipeline

The use case: a query field, debounced by an adjustable N ms, hashes a file set on a worker with latest-wins cancellation, shows results, and an enable toggle turns the pipeline off. In Solid 2.0:

```tsx
import {
  createSignal,
  createMemo,
  createEffect,
  onCleanup,
  untrack,
  isPending,
  Loading,
  Show,
  For,
} from 'solid-js';

type FileHash = { path: string; blake3: string };
declare function hashOnWorker(
  query: string,
  signal: AbortSignal,
): Promise<FileHash[]>;
declare function Row(props: { hash: FileHash }): JSX.Element;

// A hand-rolled debounce: the effect half arms a timer; its cleanup (run
// before the next effect run and on disposal) cancels the pending one.
function createDebounced<T>(source: () => T, ms: () => number) {
  const [out, setOut] = createSignal<T>(untrack(source));
  createEffect(
    () => [source(), ms()] as const, // compute: track both inputs
    ([value, delay]) => {
      // effect: untracked, imperative
      const id = setTimeout(() => setOut(() => value), delay); // timer: no owner, write is legal
      return () => clearTimeout(id);
    },
  );
  return out;
}

const [query, setQuery] = createSignal('');
const [enabled, setEnabled] = createSignal(true);
const [debounceMs, setDebounceMs] = createSignal(250);

const debounced = createDebounced(query, debounceMs);

const results = createMemo(async () => {
  if (!enabled()) return [] as FileHash[]; // read every input before the first await
  const q = debounced();
  const ac = new AbortController();
  onCleanup(() => ac.abort()); // runs at once if this run is superseded uncommitted
  return hashOnWorker(q, ac.signal); // postMessage; abort posts a cancel to the worker
});

function SearchPanel() {
  return (
    <>
      <input onInput={e => setQuery(e.currentTarget.value)} />
      <input
        type="checkbox"
        checked={enabled()}
        onChange={e => setEnabled(e.currentTarget.checked)}
      />
      <Loading fallback={<p>Hashing…</p>}>
        <Show when={isPending(() => results())}>
          <span>updating…</span>
        </Show>
        <For each={results()}>{h => <Row hash={h} />}</For>
      </Loading>
    </>
  );
}
```

What happens, per event:

1. **Mount.** `results` computes eagerly: `enabled()` is `true`, `debounced()` is `""`, a worker job starts, `_inFlight` is that promise. The render effects under `<Loading>` read `results()`, which has no committed value, so the read throws `NotReadyError`; the boundary is armed (fresh), catches it and shows `Hashing…` (F-4). The debounce effect's first effect half arms a 250 ms timer that will write `""` again — an equal write, cut off by `equals`.
2. **Keystroke `a`.** The handler's `setQuery("a")` stages the write and queues the microtask flush. In the flush, the debounce effect's compute re-runs (`["a", 250]`); in the user-effect queue its previous cleanup clears the old timer and a new one is armed. `debounced` is unchanged, so nothing downstream is marked.
3. **Keystroke `ab` 100 ms later.** Same as 2: the timer restarts. No hashing has started for `a`.
4. **250 ms of quiet.** The timer callback calls `setOut(() => "ab")`; a flush runs. `markNode` marks `results` `DIRTY` and the render effects `CHECK`; the heap recomputes `results` first. Its new run replaces `_inFlight`. If the mount-time job has not landed yet, that run never committed, so its `onCleanup` aborts it now and any late answer fails the `_inFlight !== result` guard. The render effects re-run: `results` still has no committed value (first load), so the boundary keeps its fallback. Once a first answer _has_ landed, the same step instead holds: the list keeps showing the previous results (the disarmed boundary forwards, F-5) while `isPending(() => results())` reads `true` and shows `updating…` (a display-ahead read, F-6).
5. **The worker answers `ab`.** The promise resolves; the guard passes; the value lands and the hold commits in one frame: the list and the `updating…` indicator change together. The previously committed run's `onCleanup` (its `AbortController`) runs now — harmless, its job is done.
6. **`setDebounceMs(800)`.** The debounce effect re-runs with the new delay and _restarts_ the window with the current query; nothing is hashed. (Applying the new delay only to the next keystroke would need the delay read untracked.)
7. **Toggle off mid-flight.** `setEnabled(false)` dirties `results`; its run returns `[]` synchronously, `_inFlight` becomes `null`, the uncommitted flight's cleanup aborts the worker job, and the empty list reveals at once. Typing while disabled still runs the debounce timers (the effect does not read `enabled`) but `results` no longer reads `debounced`, so it is not woken.

**Where the model fits a per-frame immediate-mode UI, and where it does not.**

- _Fits:_ the dependency graph, latest-wins by flight identity, cleanup-driven cancellation, and `isPending`/`latest` as non-throwing probes map directly onto a D library over `event-horizon`: the microtask becomes "end of the current loop turn", `flush()` becomes "before building this frame", and `onCleanup` maps onto a structured scope's cancellation.
- _Does not fit:_ the hold machinery is defined in terms of _render effects_ — _"Only a render effect is a reader"_ ([`RULES-FUNDAMENTALS.md`][fund]). An immediate-mode frame that rebuilds its widget tree reads state imperatively, outside any tracking scope, and untracked reads _"read the screen as it stands"_; reading a still-loading async value that way throws (`PENDING_ASYNC_UNTRACKED_READ`, [`08-dev-diagnostics.md`][rfc08]). A per-frame UI would therefore read `latest(results)`/`isPending(results)` every frame and render the stale-while-pending state itself; `<Loading>`, transitions, and whole-frame holds have no reader to apply to. The transferable core is the graph plus flight identity, not the hold rules.

## Strengths

- **One model for sync and async.** A memo that returns a promise is still a memo: it composes with sync memos without operators, and `createResource` is gone.
- **Latest-wins without user code.** Flight identity (`_inFlight`) silently drops superseded answers; the user only adds cancellation of the _work_ via `onCleanup`.
- **Consistency guarantees stated as rules.** Eleven numbered, immutable fundamentals plus derived rules and scenario tests make "what is on screen" a specified contract, not emergent behaviour.
- **Topological, glitch-free propagation** with `equals` cut-off and lazy, autodisposing memos for demand-driven work.
- **Effects that cannot see half-computed state.** The compute/effect split runs all tracking before any side effect in a flush.
- **Deterministic testing** with nothing but `flush()` and hand-resolved promises.

## Weaknesses

- **No time vocabulary.** No debounce, throttle, or interval primitive, and no virtual clock; every time-based behaviour is hand-rolled from `setTimeout` plus cleanup, and tested with an ad-hoc fake clock.
- **Cancellation is by convention.** There is no `AbortSignal` argument; forgetting `onCleanup` before the first `await` leaves superseded work running to completion, only its answer discarded.
- **Tracking stops at the first `await`.** Inputs read after it are not dependencies — a dev-only error, a silent staleness bug otherwise.
- **The async semantics are deep.** Holds, lanes, display-ahead reads, arming/disarming boundaries, `createDeferred` and optimistic guesses need an eleven-fundamental rulebook and dozens of derived rules; `core.ts` and `scheduler.ts` alone are ~185 KB of source.
- **Readers are render effects.** The guarantees assume a retained, fine-grained renderer; an immediate-mode frame is an untracked reader and gets none of them.
- **Writes are restricted.** Writing from a computation throws in dev, which rules out "derive into a signal" patterns that 1.x allowed.

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                                | Trade-off                                                                                    |
| ----------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Microtask batching, `batch()` removed                             | Every write in a tick is one consistent update; aligns with Vue/Svelte ([RFC 01][rfc01]) | Reads after a write see the old value until `flush()`; imperative code must flush explicitly |
| Height-ordered dirty heap with `CHECK`/`DIRTY` marks              | Topological, glitch-free recomputation; pull on read via `updateIfNecessary`             | Height maintenance (`adjustHeight`, `liftOwned`) on dynamic dependency changes               |
| Async as a memo's return value, `NotReadyError` through the graph | One primitive family; derived values combine sync and async without combinators          | Reads throw for control flow; untracked reads of pending values are errors                   |
| Latest-wins by flight identity, cancellation via `onCleanup`      | The engine always knows the current question; stopping work is the run's business        | No built-in `AbortSignal`; superseded work keeps running unless the user wires cleanup       |
| Hold changes until on-screen async lands (F-2)                    | The screen is never torn between a value and a stale derivation of it                    | One slow flight holds unrelated content; needs `createDeferred`/`Loading on` to opt out      |
| Split compute/effect phases                                       | Full dependency picture before side effects; needed for boundaries and holds             | Two callbacks per effect; effects never compare values (put a memo in front)                 |
| No writes in owned scope                                          | No feedback loops; the graph stays a pure function of its inputs                         | Writable-derived state needs `createSignal(fn)` or an event-side write                       |
| No time primitives in the core                                    | The core stays about consistency, not about clocks                                       | Debounce/throttle are user code; no virtual time for tests                                   |

---

## Sources

- [solidjs/solid at `solid-js@2.0.3`][repo] · [`packages/signals`][pkg] · [`README.md`][readme] · [`package.json`][package] · [`CHANGELOG.md`][changelog] · [`LICENSE`][license]
- [`src/index.ts` — public exports][index] · [`src/signals.ts` — `createSignal`/`createMemo`/`createEffect`/`onCleanup`/`refresh`][signals]
- [`src/core/heap.ts` — dirty heap, `markNode`, `runHeap`][heap] · [`src/core/core.ts` — `recompute`, `updateIfNecessary`, owned-scope write check][core] · [`src/core/constants.ts` — `REACTIVE_*`/`STATUS_*`/`EFFECT_*` flags][constants]
- [`src/core/scheduler.ts` — `schedule()`, `GlobalQueue.flush`][scheduler] · [`src/core/async.ts` — `handleAsync`, flight identity, `onSupersede`][async] · [`src/core/error.ts` — `NotReadyError`][error]
- [`src/core/owner.ts` — owner tree, `createRoot`, disposal][owner] · [`src/core/verdict.ts` — `isPending`, `latest`][verdict] · [`src/core/action.ts` — `action`][action]
- [`src/deferred.ts` — `createDeferred`][deferred] · [`src/from.ts` — `from`][from] · [`src/boundaries.ts` — `createLoadingBoundary`/`createErrorBoundary`][boundaries]
- [`docs/RULES-FUNDAMENTALS.md` — the eleven async fundamentals][fund] · [`docs/RULES-DERIVED.md`][derived] · [`docs/create-deferred.md`][deferred-doc]
- RFCs: [01 reactivity, batching, effects][rfc01] · [05 async data][rfc05] · [06 actions and optimistic][rfc06] · [08 dev diagnostics][rfc08] · [`MIGRATION.md`][migration]
- Tests: [`async-cleanup-timing.test.ts`][t-cleanup] · [`async-chain-supersession.test.ts`][t-chain] · [`create-deferred.test.ts`][t-deferred]
- 1.x comparison: [`packages/solid/src/reactive/signal.ts` at `solid-js@1.9.15`][v1-signal]
- [Solid documentation site][docs]
- Related: [Reactive programming survey][index-umbrella] · [Concepts][concepts] · [RxJS][rxjs] · [Effect-TS][effect-ts] · [Comparison][comparison] · [`event-horizon` library docs][eh-docs] · [`event-horizon` spec][eh-spec]

<!-- References -->

[repo]: https://github.com/solidjs/solid/tree/68406c2077eff22c67f71db4a16bf7026ddceee1
[pkg]: https://github.com/solidjs/solid/tree/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals
[readme]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/README.md
[package]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/package.json
[changelog]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/CHANGELOG.md
[license]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/LICENSE
[index]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/src/index.ts
[signals]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/src/signals.ts
[heap]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/src/core/heap.ts
[core]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/src/core/core.ts
[constants]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/src/core/constants.ts
[scheduler]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/src/core/scheduler.ts
[async]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/src/core/async.ts
[error]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/src/core/error.ts
[owner]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/src/core/owner.ts
[verdict]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/src/core/verdict.ts
[action]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/src/core/action.ts
[deferred]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/src/deferred.ts
[from]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/src/from.ts
[boundaries]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/src/boundaries.ts
[fund]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/docs/RULES-FUNDAMENTALS.md
[derived]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/docs/RULES-DERIVED.md
[deferred-doc]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/docs/create-deferred.md
[rfc01]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/documentation/solid-2.0/01-reactivity-batching-effects.md
[rfc05]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/documentation/solid-2.0/05-async-data.md
[rfc06]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/documentation/solid-2.0/06-actions-optimistic.md
[rfc08]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/documentation/solid-2.0/08-dev-diagnostics.md
[migration]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/documentation/solid-2.0/MIGRATION.md
[t-cleanup]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/tests/async-cleanup-timing.test.ts
[t-chain]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/tests/async-chain-supersession.test.ts
[t-deferred]: https://github.com/solidjs/solid/blob/68406c2077eff22c67f71db4a16bf7026ddceee1/packages/signals/tests/create-deferred.test.ts
[v1-signal]: https://github.com/solidjs/solid/blob/a252c783b709e84e1e650a774d6cb52af7624ce7/packages/solid/src/reactive/signal.ts
[docs]: https://docs.solidjs.com/
[index-umbrella]: ./index.md
[concepts]: ./concepts.md
[rxjs]: ./rxjs.md
[effect-ts]: ./effect-ts.md
[comparison]: ./comparison.md
[eh-docs]: ../../libs/event-horizon/index.md
[eh-spec]: ../../specs/event-horizon/SPEC.md
