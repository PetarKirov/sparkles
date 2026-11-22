# TC39 Signals (JavaScript)

The Stage 1 proposal to put a signal graph into JavaScript itself. It specifies only state cells, lazily cached computations and a synchronous "something may have changed" hook (`Signal.State`, `Signal.Computed`, `Signal.subtle.Watcher`). Effects, scheduling, batching and async are left to the frameworks that are meant to build on it.

| Field             | Value                                                                                                                                                                                                                                               |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | JavaScript / TypeScript (the API sketch is a `.d.ts`)                                                                                                                                                                                               |
| License           | Proposal: MIT ([`LICENSE`][p-license]). Polyfill: Apache-2.0 ([`LICENSE`][pf-license]), with files carrying Google's MIT header (`graph.ts`, `computed.ts`, `signal.ts`) and Bloomberg's Apache header (`wrapper.ts`)                               |
| Repository        | [tc39/proposal-signals][p-repo] (proposal) · [proposal-signals/signal-polyfill][pf-repo] (polyfill)                                                                                                                                                 |
| Documentation     | The proposal [`README.md`][p-readme] is the whole document: motivation, API sketch, a prose "proto-specification" (§ _Signal algorithms_) and an FAQ. [`spec.emu`][p-spec] is a 9-line ecmarkup stub (`stage: 0`) with no spec text yet.            |
| Category          | push-pull signal graph (state, memo, change notification); no effects                                                                                                                                                                               |
| Stage             | **Stage 1**. The README heading says so, and the TC39 [Stage 1 table][tc39-stage1] (at `c688b97`, 2026-10-14) lists "Signals" with meeting notes from 2024-04 and 2024-06. It appears in none of the Stage 2, 2.7 or 3 tables (checked 2026-11-22). |
| Versions surveyed | proposal at `9124ed9` (2025-08-11); `signal-polyfill@0.2.3` at `958ad56` (tag `v0.2.3`, released 2026-11-16)                                                                                                                                        |
| Core abstraction  | a cell with `get()`. A `Computed` auto-tracks the signals it reads, and a `Watcher` gets a synchronous `notify` when a watched signal may be stale                                                                                                  |

> [!WARNING]
> The README contradicts itself. The title block says _"Stage 1"_, but the _Status and development plan_ section still reads _"This proposal is on the April 2024 TC39 agenda for Stage 1. It can currently be thought of as "Stage 0""_, and `spec.emu` says `stage: 0`. The TC39 proposals list confirms Stage 1. Treat the status prose as stale from before April 2024.

---

## Overview

### What it solves

Nearly every JavaScript UI framework has its own signal library, and each auto-tracks dependencies in its own way. A reactive model written for one framework cannot be used from another. The proposal wants to standardize the **graph semantics** underneath those libraries rather than any one framework's surface. From the [`README.md`][p-readme] introduction:

> _"Differently from Promises/A+, we're not trying to solve for a common developer-facing surface API, but rather the precise core semantics of the underlying signal graph. This proposal does include a fully concrete API, but the API is not targeted to most application developers. Instead, the signal API here is a better fit for frameworks to build on top of, providing interoperability through common signal graph and auto-tracking mechanism."_

The collaborators are named: _"The current draft is based on design input from the authors/maintainers of Angular, Bubble, Ember, FAST, MobX, Preact, Qwik, RxJS, Solid, Starbeam, Svelte, Vue, Wiz, and more…"_. The champions are Daniel Ehrenberg, Yehuda Katz, Jatin Ramanathan, Shay Lewis, Kristen Hewell Garrett, Dominic Gannaway, Preston Sego, Milo M and Rob Eisenberg; the original authors are Rob Eisenberg and Daniel Ehrenberg.

For this survey the proposal matters as the **cleanest written statement of the algorithm** that [Solid][solid] (and Preact, Vue, Angular and others) implement in tuned, framework-specific forms. It is also the one place where the field has agreed on what belongs in the core and what does not.

### Design philosophy

The § _Design goals for Signals_ list is short and opinionated ([`README.md`][p-readme]):

> _"Enable JS frameworks to do their own scheduling. No Promise-style built-in forced-on scheduling. — Synchronous reactions are needed to enable scheduling later work based on framework logic. — Writes are synchronous and immediately take effect (a framework which batches writes can do that on top). — It is possible to separate checking whether an effect may be "dirty" from actually running the effect (enabling a two-stage effect scheduler)."_

Four principles follow from it and shape the API:

1. **The core is synchronous and owns no clock.** A write takes effect before `set` returns. A read always returns a value. The only push is `notify`, and `notify` may not touch the graph.
2. **No effect API.** The FAQ answer: _"Effects inherently tie into scheduling and disposal, which are managed by frameworks and outside the scope of this proposal. Instead, this proposal includes the basis for implementing effects through the more low-level `Signal.subtle.Watcher` API."_
3. **Unsoundness is marked, not forbidden.** `untrack` lives under `subtle` because _"it allows the creation of computed Signals whose value depends on other Signals, but which aren't updated when those Signals change"_. Writes from inside computeds are allowed _"to preserve flexibility and compatibility in integration with frameworks"_.
4. **Lossy by design.** _"Signals represent a cell of data--just the immediate current value (which may change), not a stream of data over time. … other constructs (e.g., async iterables, observables) are more appropriate for streams."_

---

## How it works

### The API surface

The whole API, condensed from the README's `.d.ts` sketch:

```ts
namespace Signal {
  class State<T> {
    constructor(t: T, options?: SignalOptions<T>);
    get(): T;
    set(t: T): void;
  }
  class Computed<T> {
    constructor(cb: (this: Computed<T>) => T, options?: SignalOptions<T>);
    get(): T;
  }
  namespace subtle {
    function untrack<T>(cb: () => T): T;
    function currentComputed(): Computed | null;
    function introspectSources(s: Computed | Watcher): (State | Computed)[];
    function introspectSinks(s: State | Computed): (Computed | Watcher)[];
    function hasSinks(s: State | Computed): boolean; // "live": (recursively) watched
    function hasSources(s: Computed | Watcher): boolean;
    class Watcher {
      constructor(notify: (this: Watcher) => void); // no signal reads or writes inside
      watch(...s: Signal[]): void; // no arguments: re-arm notify
      unwatch(...s: Signal[]): void;
      getPending(): Signal[]; // watched computeds that are still dirty
    }
    var watched: Symbol;
    var unwatched: Symbol; // liveness hooks, passed in options
  }
  interface SignalOptions<T> {
    equals?: (this: Signal<T>, t: T, t2: T) => boolean; /* default Object.is */
  }
}
```

Two features keep allocations down: the classes are designed to be subclassed, and callbacks receive the signal as `this`. The README explains that _"a new closure isn't needed per Signal. Instead, context can be saved in extra properties of the signal itself."_

### The proto-spec: three colours plus `computing`

§ _Signal algorithms_ defines a computed's `state` as `~clean~`, `~checked~`, `~computing~` or `~dirty~`. A Watcher is `~waiting~`, `~watching~` or `~pending~`. A `State.set(v)`:

1. throws if `frozen` is set (that is, if we are inside a `notify` or a `watched`/`unwatched` callback);
2. runs "set Signal value", which calls `equals(old, new)`. If they are equal, it returns `~clean~` and nothing happens;
3. marks the direct sinks `~dirty~` and the transitive ones `~checked~`, and moves `~watching~` Watchers to `~pending~`;
4. for each Watcher reached, depth-first: _"Set `frozen` to true. Calling their `notify` callback … Restore `frozen` to false"_, then sets it `~waiting~`. Exceptions are collected and rethrown from `set` once every `notify` has run, as an `AggregateError` if there are several.

`Computed.get()` then pulls: _"Recurse up via `sources` to find the deepest, left-most (i.e. earliest observed) recursive source which is a Computed Signal marked `~dirty~` … Perform the "recalculate dirty computed Signal" algorithm on that Signal"_, and repeats until the computed is clean. A recalculation that ends `equals`-unchanged turns `~checked~` sinks back to `~clean~` without running them. This is the equality cut-off that makes the graph glitch-free and avoids wasted work. The README credits the colouring idea to _"Milo's blog post"_ but gives no link. That source is **unverified** here.

### The polyfill: Angular's version/epoch graph

The polyfill does **not** implement the colour algorithm literally. [`graph.ts`][pf-graph] carries Google's copyright and is Angular's signal graph. It works with versions instead of colours:

- Every node has a `version`, which goes up when its value changes. A global `epoch` goes up on every source write (`producerIncrementEpoch`).
- A consumer records each producer it reads in `producerNode[]`, together with the version it saw (`producerLastReadVersion[]`). Dependencies are positional. `producerAccessed` compares slot `nextProducerIndex` with the producer being read and replaces a stale one, and `consumerAfterComputation` truncates the arrays. This is how dynamic dependencies are kept accurate.
- **Push edges exist only for live nodes.** `liveConsumerNode[]` is filled only when a consumer is live (watched, directly or through other computeds). `producerAddLiveConsumer` adds edges transitively on the 0→1 transition and fires `watched`. `producerRemoveLiveConsumerAtIndex` removes them on 1→0 and fires `unwatched`. An unwatched computed therefore holds references to its sources, but nothing holds a reference to it, so it can be garbage-collected. This is the memory goal from § _Memory management_.
- The push phase is `producerNotifyConsumers`, which sets `dirty` on live consumers under `inNotificationPhase = true`. The pull phase is `producerUpdateValueVersion` → `consumerPollProducersForChange`, which walks recorded producers, brings each one up to date and compares versions. The epoch gives a shortcut: _"Even non-live consumers can skip polling if they previously found themselves to be clean at the current epoch, since their dependencies could not possibly have changed"_.

```ts
// signal-polyfill src/computed.ts — producerRecomputeValue (abridged)
const prevConsumer = consumerBeforeComputation(node);
try {
  newValue = node.computation.call(node.wrapper);
  const oldOk = oldValue !== UNSET && oldValue !== ERRORED;
  wasEqual = oldOk && node.equal.call(node.wrapper, oldValue, newValue);
} catch (err) {
  newValue = ERRORED;
  node.error = err;
} finally {
  consumerAfterComputation(node, prevConsumer);
}
if (wasEqual) {
  node.value = oldValue;
  return;
} // version unchanged: dependents stay clean
node.value = newValue;
node.version++;
```

A `Watcher` is a bare `ReactiveNode` with `consumerIsAlwaysLive = true`, `consumerAllowSignalWrites = false`, and its `notify` installed as `consumerMarkedDirty` ([`wrapper.ts`][pf-wrapper]). `consumerMarkDirty` skips nodes that are already dirty, so a Watcher fires **once** until `watch()` is called again. `watch()` with no arguments only does `node.dirty = false`. `getPending()` is `producerNode.filter((n) => n.dirty)`.

> [!NOTE]
> Divergences observed between the polyfill and the README's proto-spec, read from source and not filed upstream:
> (a) `producerNotifyConsumers` loops inside a `try/finally`, so the first `notify` that throws stops the remaining notifications. The proto-spec says to aggregate every exception.
> (b) `watched`/`unwatched` run inside `producerAddLiveConsumer`/`producerRemoveLiveConsumerAtIndex` without setting the notification-phase flag, while the proto-spec runs them `frozen`.
> (c) The polyfill freezes the graph only during notification. Reads are rejected in `producerAccessed` and writes in `State.set`, which matches the prohibited-contexts test.

---

## Evaluation model

- **Push-pull, explicitly.** The FAQ: _"Evaluation of computed Signals is pull-based: computed Signals are only evaluated when `.get()` is called, even if the underlying state changed much earlier. At the same time, changing a State signal may immediately trigger a Watcher's callback, "pushing" the notification."_ Only invalidation is pushed, and only along live edges. Values are always pulled.
- **Lazy and cached.** A `Computed` does not run on construction or on invalidation, only on `get()`. It is _"cached, meaning that if, after the last time a dependency changes, no dependencies have changed, then the computed Signal is not recalculated when accessed."_ There is no eager or hot mode, and no cold/hot distinction at all: one cached value is shared by every reader.
- **Glitch-free by pulling in dependency order.** The design goal reads: _"no unnecessary calculations are ever performed. This implies that, when an application reads a computed Signal, there is a topological sorting of the potentially dirty parts of the graph to run"_. Because `notify` cannot read anything, no code can observe a half-propagated graph.
- **Synchronous, unbatched writes; batched reads in practice.** _"Setting a Signal to a new value is synchronous … There is no built-in batching of this mutation."_ Several writes before the scheduler's pull cost only re-markings. The README notes that _"the laziness inherent in this mechanism … means that, in practice, the calculations may happen in a batched way"_.
- **Dynamic dependencies.** Each run re-records its sources, so _"a change to that temporarily unused value will not cause the computed Signal to be recalculated, even when pulled."_
- **Deterministic ordering.** _"The order of reads of Signals within a computed is significant, and is observable in the order that certain callbacks … are executed. This means that the sources of a computed Signal must be stored ordered."_

## Composition

Composition happens by **reading**. A derived value is a `Computed` whose callback calls `.get()` on other signals, and a combination of two sources reads both. There are no operators. The full surface is `State`, `Computed`, `Watcher` and six `subtle` functions. The proposal pushes everything else out to libraries: it lists _"recursively reactive store proxy, reactive Map and Set and Array"_ as framework-independent structures that the core should make possible, and the FAQ points at Proxy-backed stores (Vue `reactive()`, Solid stores) and at the `signal-utils` package. A further list of [convenience methods][p-readme] (README: _"Some possible convenience methods are also omitted"_) has been deferred.

What is absent is part of the result. The core has no `map`/`filter`, no time operators, no flattening of async values, and no stream operators. A `Computed` is the only combinator, and `equals` is the only knob on propagation.

## Time and scheduling

**The core has no clock and no scheduler.** It has one hook, `notify`. It runs synchronously inside the `set` that caused it, _"but after graph coloring has completed"_, and it may neither read nor write signals. The README says what it is for: _"A typical callback will add a Signal to an Array to be read later, or mark a bit somewhere. It is unnecessary and impractically expensive to make a separate microtask for all of these sorts of actions."_ A framework therefore schedules a pull on a microtask, a frame or an idle callback, and that pull calls `getPending()`, `get()`s each pending computed, and re-arms with `watch()`. Both the README's `effect` and the polyfill's are this pattern over `queueMicrotask`. The README labels its own version _"too basic to be useful. Do not copy/paste."_

The README also concedes that `Watcher` is optional: _"it is perfectly possible to use Signals effectively without `Signal.subtle.Watcher` by scheduling polling of computed Signals, as Glimmer does."_ For a per-frame UI this is the important case: a frame loop that `get()`s its computeds is a complete scheduler.

**Debounce is not in the proposal or the polyfill.** It is user code. The usual shape is an effect that reads the source and the interval, arms a host timer that writes a `State`, and clears the timer in its cleanup. A runtime-adjustable interval works without any special support: the interval is a signal the effect reads, so changing it re-runs the effect, which clears the old timer and arms a new one. The window restarts. Keeping the original deadline means storing it outside the graph. See [the worked pipeline](#the-worked-pipeline).

## Concurrency and cancellation

The proposal does not deal with concurrency or cancellation. A JavaScript agent runs one thread, and the hidden globals (`computing`, `frozen`, `generation`) are defined as _"global for the entire thread, or "agent""_. A worker has its own graph, and signals are not shared across agents.

- **Latest-wins** is not provided. It has to be built from an effect that owns an `AbortController` and aborts it in its cleanup. The effect's re-run, which the framework triggers when the input signal changes, carries out the cancellation. The README even has an unwritten TODO for this: _"Show example of a computed signal which represents the result of a fetch directed at a state, which is cancelled"_ (inside an HTML comment at this commit).
- **Cancellation is a message and does not wait.** `abort()` returns immediately. CPU-bound work on a worker sees it only if it polls (an `Atomics` flag in a `SharedArrayBuffer`, or a chunked loop that yields to receive a `postMessage`), or if it is killed with `worker.terminate()`. The graph's only protection is that a stale result is never written: the completion handler checks `signal.aborted` before it calls `set`.
- **CPU-bound work inside a `Computed` blocks the thread.** A computed is a synchronous function, so any parallelism has to sit outside the graph and report back with `set`.

## Errors and completion

- **Errors are cached values.** _"If a computed Signal's callback throws, then that error is cached just like another value, and rethrown every time the Signal is read"_ until a dependency changes. In the polyfill this is the `ERRORED` sentinel plus `node.error`. A throwing `equals` is also cached as the error ([`errors.test.ts`][pf-t-errors]: _"are cached by computed signals when equals throws"_). An error propagates to downstream computeds by rethrow on read, and a downstream computed may catch it.
- **`notify` errors go to the writer.** In the proto-spec they are rethrown from the `set` that caused them, aggregated if there are several. See the polyfill divergence above.
- **Cycles throw.** _"It is an error to read a computed recursively"_. The polyfill throws `'Detected cycle in computations.'` on the `COMPUTING` sentinel ([`cycles.test.ts`][pf-t-cycles]).
- **No completion.** A signal has no terminal state, and there is no "loading" state either. The README's § _Omitted for now_ suggests exceptions as a stopgap for async loading: _"One simple way to model the loading state is with exceptions, and the exception-caching behavior of computed signals composes somewhat reasonably with this technique. Improved techniques are discussed in Issue #30."_ There is no `AsyncComputed` in the proposal or the polyfill at the surveyed revisions. Where such a type exists, it is in third-party utility packages that this survey did not read (**unverified**). Compare Solid 2.0, which made async a node status ([Solid: async computations][solid-async]).

## State and sharing

- **`State` is the value cell.** It is a single object that can both read and write. The README notes that this works against capability separation, but it saves allocations. `equals` (default `Object.is`) suppresses writes of an equal value at the source, and recomputations that produce an equal value at each computed.
- **Every signal is multicast and conflated by construction.** Any number of readers share one cached value, and writes in between are lost: _"if you write to a state Signal twice in a row, without doing anything else, the first write is "lost" and never seen by any computed Signals or effects."_ The FAQ calls this _"a feature rather than a bug"_.
- **Liveness is observable.** `hasSinks` (the node is live), `introspectSinks` (live sinks only) and `introspectSources` expose the graph for DevTools. The `watched`/`unwatched` hooks let a signal acquire an external resource (a subscription, a socket) only while something is watching it. The README's TODO describes converting an Observable to a computed this way. [`liveness.test.ts`][pf-t-liveness] checks that the hooks fire _"only … on first and last descendant"_.

## Lifetime and ownership

There are **no owners, scopes or disposal in the core**. The FAQ: _"The parts which are more framework-specific tend to be in the area of effects, scheduling, and ownership/disposal, which this proposal does not attempt to solve."_ Lifetime has two rules:

- **Unwatched signals are ordinary garbage.** _"Only watched Signals need to be cleaned up (by unwatching them), while unwatched Signals can be garbage-collected automatically."_ The polyfill delivers this because it builds no back-edges for non-live nodes.
- **Watched signals are kept alive by their sources.** _"Any Signals which are watched by a Watcher will be held alive as long as any of the underlying states are reachable … For this reason, remember to call `Watcher.prototype.unwatch` to clean up effects."_ An effect that is never unwatched leaks for as long as its state is reachable, and the core cannot detect this.

Nested effects, cleanup ordering, and the parent-child disposal that Solid's owner tree provides are all left to the framework. The README's `effect` covers only the minimum: it calls the previous run's destructor at the start of the next run, and once more on dispose.

## Testing

The polyfill is tested with Vitest ([`package.json`][pf-package]: `"test": "vitest"`). The suites cover each API (`tests/Signal/**`), behaviours (`tests/behaviors/` — cycles, dynamic dependencies, errors, liveness, pruning, prohibited contexts), and ports of other libraries' suites ([`ported/preact.test.ts`][pf-t-preact], `ported/vue.test.ts`). The benchmarks plug the polyfill into `js-reactivity-benchmark` through an adapter whose `effect` is again the Watcher-plus-microtask pattern ([`adapter.ts`][pf-bench]). The adapter names the framework `tc39SignalsProposalStage0`.

Because the core is synchronous, its tests need no time handling: write, then `get()`, then assert. A Watcher's `notify` can be checked with a spy as soon as `set` returns ([`watcher.test.ts`][pf-t-watcher]). **Virtual time is the framework's job.** No polyfill test uses fake timers or `setTimeout`. A debounce test would use the test runner's fake clock (`vi.useFakeTimers()`) around the framework's own effect and scheduler. In sparkles terms, the graph would need no clock, and `TestClock` would drive only the timers that effects arm.

## The worked pipeline

The use case: a query field, debounced by an N ms window that can be changed at runtime, hashes a file set on a worker with latest-wins cancellation, and shows the result. An enable toggle turns the whole pipeline off. Everything below the core is **framework code**, and the proposal intends it to be:

```ts
import { Signal } from 'signal-polyfill';

// ---- framework layer: one Watcher and a scheduler hook ----------------------------
type Cleanup = (() => void) | void;
let scheduled = false;
const watcher = new Signal.subtle.Watcher(() => {
  // Runs inside the State.set() that caused it. It must not read or write any signal.
  if (!scheduled) {
    scheduled = true;
    queueMicrotask(flush);
  } // or the next frame
});
function flush() {
  scheduled = false;
  watcher.watch(); // re-arm *before* pulling (see below)
  for (const s of watcher.getPending()) s.get(); // pull: re-runs dirty effects
}
function effect(fn: () => Cleanup): () => void {
  let cleanup: Cleanup;
  const c = new Signal.Computed(() => {
    cleanup?.();
    cleanup = fn();
  });
  watcher.watch(c);
  c.get();
  return () => {
    watcher.unwatch(c);
    cleanup?.();
    cleanup = undefined;
  };
}

// ---- application state ------------------------------------------------------------
const enabled = new Signal.State(true);
const query = new Signal.State('');
const interval = new Signal.State(300); // ms, bound to the numeric field
const settled = new Signal.State<string | null>(null); // the debounced query
const result = new Signal.State<HashResult | null>(null);
const busy = new Signal.State(false);

// Debounce: a host timer that writes a State. The effect's cleanup clears it.
effect(() => {
  if (!enabled.get()) return; // while off, this is the effect's only dependency
  const q = query.get(),
    n = interval.get();
  const id = setTimeout(() => settled.set(q), n);
  return () => clearTimeout(id);
});

// Latest-wins hash: the effect owns an AbortController, and its cleanup aborts it.
effect(() => {
  if (!enabled.get()) return;
  const q = settled.get();
  if (q === null) return;
  const ac = new AbortController();
  busy.set(true); // writes inside a Computed are allowed
  hashOnWorker(q, ac.signal).then(
    r => {
      if (!ac.signal.aborted) {
        result.set(r);
        busy.set(false);
      }
    },
    e => {
      if (!ac.signal.aborted) {
        result.set({ error: e });
        busy.set(false);
      }
    },
  );
  return () => ac.abort(); // returns at once. The worker must poll, or be terminated.
});

// UI handlers. The per-frame view reads result/busy untracked with .get().
const onQuery = (s: string) => query.set(s);
const onInterval = (n: number) => interval.set(n);
const onToggle = (on: boolean) => {
  enabled.set(on);
  if (!on) {
    settled.set(null);
    busy.set(false);
  }
};
```

`hashOnWorker(q, signal)` posts `{ id, q }` to a `Worker`. On `abort` it posts `{ cancel: id }`, and it resolves when the reply with that `id` arrives. Its definition is omitted.

The flush re-arms **before** it pulls, for a reason that comes from the polyfill's `graph.ts`; this is the survey's reading, not upstream guidance. `consumerMarkDirty` skips consumers that are already dirty, and a Watcher stays dirty until `watch()`. If an effect writes a signal during the pull (here `busy.set(true)`), the write must be able to notify again. With the README's order (pull first, re-arm second), an effect dirtied during the pull would have no Watcher listening. It would stay dirty, and later writes would not re-mark it, so it would never run. This is one concrete reason behind the README's _"Do not copy/paste"_.

**Trace.** All calls are polyfill functions. "Flush" means the microtask (or the frame) the Watcher scheduled.

1. **Keystroke during a debounce window.** `query.set("ab")` → `signalSetFn`: not equal, so `version++`, `epoch++`, then `producerNotifyConsumers(query)`. The debounce effect is a live consumer, so `consumerMarkDirty` runs on it and then on the Watcher, whose `notify` schedules a flush. All of this happens before `set` returns, with reads frozen. At the flush: `watch()`, then `getPending()` → `[debounce]`, then `get()` → `consumerPollProducersForChange` sees `query`'s new version and recomputes. The cleanup calls `clearTimeout` on the old timer, and a new `setTimeout(n)` is armed. The effect returns `undefined` again, `equals` holds, and its version does not move. Typing ten characters before the flush costs one re-run.
2. **Keystroke during a hash.** Only the debounce effect depends on `query`, so the running hash is untouched while the user types. Latest-wins applies to _settled_ queries. When the new window expires, `settled.set(q2)` dirties the hash effect. At the flush its cleanup calls `ac1.abort()`. The abort listener posts `cancel` and returns at once, and the worker stops at its next poll. The effect then creates `ac2` and posts job 2. If job 1's promise settles later, it finds `ac1.signal.aborted` and writes nothing.
3. **Interval change.** `interval.set(500)` dirties the debounce effect. At the flush the old timer is cleared and a 500 ms timer is armed from _now_ for the current query, so the window restarts. If no window was pending, the new timer fires `settled.set(q)` with an unchanged string. `Object.is` holds, `signalSetFn` returns early, and no hash runs.
4. **Toggle off.** `enabled.set(false)` dirties both effects and notifies the Watcher. `settled.set(null)` and `busy.set(false)` follow in the same handler. The Watcher is already dirty, so they cause no second `notify`. No glitch is possible, because nothing runs until the pull. At the flush, both effects run their cleanups (`clearTimeout`, `ac.abort()`) and return after reading only `enabled`. `consumerAfterComputation` truncates their source arrays and removes the live edges to `query`, `interval` and `settled`. While the pipeline is off, keystrokes reach no effect. Turning it back on makes the debounce effect read `query` again and arm a fresh window.

**Fit with a per-frame UI.** It fits well, and the README describes the reason: the frame loop _is_ the scheduler. `notify` maps to "set a flag and `wakeIn(0)`", and the frame's build step reads `result.get()` and `busy.get()` outside any computed (untracked, `activeConsumer === null`). A read is a cache hit unless something changed, and in the polyfill the `lastCleanEpoch === epoch` test makes it O(1). The model does not fit where time and cancellation are concerned: timers, abort and the worker are three separate host mechanisms tied together by hand-written cleanups. Nothing enforces that a cleanup exists, that cancellation reaches the worker, or that a completion checks `aborted`. In an `event-horizon` design, a structured scope with a `sleep` and a cancellable fiber would make those guarantees.

## Strengths

- **The cleanest specification of the push-pull algorithm.** It has explicit state machines, ordering rules, and an equality cut-off, written as prose that can be checked against an implementation.
- **The smallest useful core.** Three classes and six `subtle` functions are enough to build effects, stores, decorators and DevTools.
- **Glitch-freedom by construction.** `notify` is frozen and values are only pulled, so no observer can see an intermediate state.
- **Lossy cells suit frame-driven UIs.** Many writes between two frames cost one recomputation.
- **GC-friendly when unwatched.** Push edges exist only for live nodes. The polyfill implements this with a battle-tested graph (Angular's).
- **Broad agreement.** The design input of more than a dozen framework teams is written down, along with the reasons each thing was omitted.

## Weaknesses

- **No effect, scheduler, batching or owner.** Every framework re-implements them, so interoperability stops at the graph. The README admits it: _"the omission limits the potential of interoperability among frameworks."_
- **No async story.** Loading state is suggested to be modelled with exceptions, and the improvements are left to an open issue. Latest-wins and abort are user code.
- **The `Watcher` contract has sharp edges.** It notifies once per arming, and the re-arm order is subtle (see the trace). The README's own example says not to copy it.
- **Unsound escape hatches stay in.** `untrack` and writes inside computeds are allowed, and a computed may end up `clean` while being stale (the prohibited-contexts test: _"c is marked clean in this case, even though re-evaluating it would cause it to change value"_).
- **Progress has stalled.** The proposal reached Stage 1 in April 2024. At the surveyed revisions the spec file is a stub, and the README's status section is out of date.
- **The polyfill diverges from the proto-spec** on aggregating `notify` errors and on freezing the graph during `watched`/`unwatched`.

## Key design decisions and trade-offs

| Decision                                          | Rationale                                                                                              | Trade-off                                                                                          |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------- |
| Standardize graph semantics, not a surface API    | Frameworks differ in ergonomics but agree on the algorithm. Built-ins share better than npm libraries. | Apps still need a framework, and `.get()` matches no popular API                                   |
| No `effect`, no scheduler                         | Effect timing is tied to each framework's render cycle and disposal                                    | Interoperability ends at effects, and every framework re-implements Watcher scheduling             |
| Synchronous `notify` that may not touch the graph | Lets the framework schedule without a microtask per change, and keeps glitches invisible               | `notify` can only set flags. The re-arm protocol is easy to get wrong.                             |
| Lazy, pull-based computeds                        | Glitch-free and no wasted work; the work naturally batches until the next pull                         | Nothing runs unless something pulls, so a reader has to be scheduled                               |
| Lossy cells                                       | A UI needs the current value, not the history                                                          | Streams (keystroke logs, events) need Observables or async iterables next to the graph             |
| Writes allowed inside computeds; `untrack`        | Compatibility with existing frameworks' patterns                                                       | Unsound states (stale but `clean`) are possible; the danger is signalled only by naming (`subtle`) |
| Back-edges only for watched nodes                 | Unwatched computeds can be collected without explicit disposal                                         | Watched nodes leak unless `unwatch`ed. Unwatched reads poll versions.                              |
| Async omitted                                     | No consensus among frameworks yet                                                                      | Loading, latest-wins and cancellation all end up in user code                                      |

## Sources

- Proposal, [tc39/proposal-signals at `9124ed9`][p-repo]: [`README.md`][p-readme] (Background, Design goals, API sketch, Signal algorithms, Omitted for now, FAQ) · [`spec.emu`][p-spec] · [`docs/initial-survey.md`][p-survey] (the framework-author questionnaire on push/pull, lossiness, scheduling) · [`LICENSE`][p-license]
- TC39 process: [Stage 1 proposals table at `c688b97`][tc39-stage1] (the Signals row and its 2024-04/2024-06 notes links) · [TC39 process document][tc39-process]
- Polyfill, [proposal-signals/signal-polyfill at `v0.2.3`][pf-repo]: [`README.md`][pf-readme] (`effect`, decorator) · [`CHANGELOG.md`][pf-changelog] · [`package.json`][pf-package] · [`LICENSE`][pf-license]
- Polyfill source: [`src/graph.ts` — `ReactiveNode`, `producerAccessed`, `producerNotifyConsumers`, `consumerPollProducersForChange`, liveness][pf-graph] · [`src/computed.ts` — `producerRecomputeValue`, `ERRORED`/`COMPUTING`][pf-computed] · [`src/signal.ts` — `signalSetFn`, epoch][pf-signal] · [`src/wrapper.ts` — the public `Signal` namespace and `Watcher`][pf-wrapper] · [`src/equality.ts` — `defaultEquals`][pf-equality]
- Polyfill tests: [`prohibited-contexts.test.ts`][pf-t-prohibited] · [`errors.test.ts`][pf-t-errors] · [`cycles.test.ts`][pf-t-cycles] · [`liveness.test.ts`][pf-t-liveness] · [`watcher.test.ts`][pf-t-watcher] · [`ported/preact.test.ts`][pf-t-preact] · [`benchmarks/adapter.ts`][pf-bench]
- Related: [Reactive programming survey][index-umbrella] · [Concepts][concepts] · [Solid 2.0 signals][solid] · [Angular signals][angular] · [RxJS][rxjs] · [Comparison][comparison] · [`event-horizon` library docs][eh-docs]

<!-- References -->

[p-repo]: https://github.com/tc39/proposal-signals/tree/9124ed91b24bb02ff7408b2fcf5abb6e18b095d7
[p-readme]: https://github.com/tc39/proposal-signals/blob/9124ed91b24bb02ff7408b2fcf5abb6e18b095d7/README.md
[p-spec]: https://github.com/tc39/proposal-signals/blob/9124ed91b24bb02ff7408b2fcf5abb6e18b095d7/spec.emu
[p-survey]: https://github.com/tc39/proposal-signals/blob/9124ed91b24bb02ff7408b2fcf5abb6e18b095d7/docs/initial-survey.md
[p-license]: https://github.com/tc39/proposal-signals/blob/9124ed91b24bb02ff7408b2fcf5abb6e18b095d7/LICENSE
[tc39-stage1]: https://github.com/tc39/proposals/blob/c688b97e056142da3c05a9b7552f14cc77d0ff94/stage-1-proposals.md
[tc39-process]: https://tc39.es/process-document/
[pf-repo]: https://github.com/proposal-signals/signal-polyfill/tree/958ad56b92e321b84673a42c3d16109f72209017
[pf-readme]: https://github.com/proposal-signals/signal-polyfill/blob/958ad56b92e321b84673a42c3d16109f72209017/README.md
[pf-changelog]: https://github.com/proposal-signals/signal-polyfill/blob/958ad56b92e321b84673a42c3d16109f72209017/CHANGELOG.md
[pf-package]: https://github.com/proposal-signals/signal-polyfill/blob/958ad56b92e321b84673a42c3d16109f72209017/package.json
[pf-license]: https://github.com/proposal-signals/signal-polyfill/blob/958ad56b92e321b84673a42c3d16109f72209017/LICENSE
[pf-graph]: https://github.com/proposal-signals/signal-polyfill/blob/958ad56b92e321b84673a42c3d16109f72209017/src/graph.ts
[pf-computed]: https://github.com/proposal-signals/signal-polyfill/blob/958ad56b92e321b84673a42c3d16109f72209017/src/computed.ts
[pf-signal]: https://github.com/proposal-signals/signal-polyfill/blob/958ad56b92e321b84673a42c3d16109f72209017/src/signal.ts
[pf-wrapper]: https://github.com/proposal-signals/signal-polyfill/blob/958ad56b92e321b84673a42c3d16109f72209017/src/wrapper.ts
[pf-equality]: https://github.com/proposal-signals/signal-polyfill/blob/958ad56b92e321b84673a42c3d16109f72209017/src/equality.ts
[pf-t-prohibited]: https://github.com/proposal-signals/signal-polyfill/blob/958ad56b92e321b84673a42c3d16109f72209017/tests/behaviors/prohibited-contexts.test.ts
[pf-t-errors]: https://github.com/proposal-signals/signal-polyfill/blob/958ad56b92e321b84673a42c3d16109f72209017/tests/behaviors/errors.test.ts
[pf-t-cycles]: https://github.com/proposal-signals/signal-polyfill/blob/958ad56b92e321b84673a42c3d16109f72209017/tests/behaviors/cycles.test.ts
[pf-t-liveness]: https://github.com/proposal-signals/signal-polyfill/blob/958ad56b92e321b84673a42c3d16109f72209017/tests/behaviors/liveness.test.ts
[pf-t-watcher]: https://github.com/proposal-signals/signal-polyfill/blob/958ad56b92e321b84673a42c3d16109f72209017/tests/Signal/subtle/watcher.test.ts
[pf-t-preact]: https://github.com/proposal-signals/signal-polyfill/blob/958ad56b92e321b84673a42c3d16109f72209017/tests/Signal/ported/preact.test.ts
[pf-bench]: https://github.com/proposal-signals/signal-polyfill/blob/958ad56b92e321b84673a42c3d16109f72209017/tests/benchmarks/adapter.ts
[index-umbrella]: ./index.md
[concepts]: ./concepts.md
[solid]: ./solid-signals.md
[solid-async]: ./solid-signals.md#async-computations-flights-notreadyerror-holds
[angular]: ./angular-signals.md
[rxjs]: ./rxjs.md
[comparison]: ./comparison.md
[eh-docs]: ../../libs/event-horizon/index.md
