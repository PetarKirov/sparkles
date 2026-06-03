# Effect (TypeScript)

Effect is a production-focused TypeScript effect framework — a typed `Effect<A, E, R>` value, an `Effect.gen` generator front-end, and a single-threaded **fiber runtime** that interprets effect instructions and drives async work via a microtask/`setImmediate` scheduler layered over the JS event loop. It is heavily inspired by [ZIO] and [Cats Effect], not by the Plotkin/Pretnar algebraic-handler tradition.

**Last reviewed:** June 2, 2026.

| Field       | Value                                                                                        |
| ----------- | -------------------------------------------------------------------------------------------- |
| Language    | TypeScript                                                                                   |
| Repository  | [`Effect-TS/effect`][repo] (v3, stable) · [`Effect-TS/effect-smol`][smol-repo] (v4, beta)    |
| Stable line | `effect@3.21.2` (3.x; feature-frozen)                                                        |
| Next line   | `effect@4.0.0-beta.75` (v4 rewrite, beta)                                                    |
| Docs        | [effect.website][docs]                                                                       |
| License     | MIT                                                                                          |
| Paradigm    | Effects-as-values; fiber runtime; typed errors + DI; **not** user-defined algebraic handlers |

See also: sibling deep-dives [ZIO][scala-zio] and [Cats Effect][scala-cats-effect] (the two JVM systems Effect tracks most closely), the [comparison matrix][comparison], and the async-I/O cross-cut [Effect Systems & Event Loops][ae-event-loops] (which classifies Effect among the "fiber-runtime libraries" whose suspension is a runtime callback, not a language primitive).

---

## Overview

### What it solves

Effect gives a single, composable value type for the three concerns that ad-hoc TypeScript scatters across `Promise`, `try/catch`, and manual wiring:

- **Typed success and failure.** `Promise<A>` erases the error type; `Effect<A, E, R>` tracks the failure channel `E` in the type system, so the compiler knows which errors are still un-handled.
- **Typed dependencies.** The `R` (requirements / _services_) channel records which services a computation needs; the program does not type-check as runnable until every requirement is provided by a `Layer`.
- **Structured concurrency, interruption, and resource safety.** Every effect runs on a fiber; fibers form a supervision tree, interruption propagates to children, and `Scope`/finalizers guarantee cleanup.

It is best understood as an industrial **effect framework**, not an algebraic-effects language. There is no user-facing `perform op` / `handle … with` construct: the only "operations" the runtime interprets are the fixed instruction set (success, failure, sync, async, flatMap-style continuations, iterator, runtime-flag updates…) baked into the runtime. Compare [Koka][koka] / [OCaml 5 effects][ocaml-effects], where handlers and resumable operations are first-class language features.

### Design philosophy

- **Effects are immutable descriptions.** An `Effect` value does nothing until executed by a runtime (`Effect.runPromise`, `Effect.runFork`, …). This deferral is what makes retries, timeouts, concurrency, and interruption expressible as ordinary combinators.
- **Generators as the ergonomic front end.** `Effect.gen(function* () { … })` plays the role of `async/await`: `yield*` an effect to bind its result, while the compiler accumulates the union of every yielded effect's `E` and `R`.
- **One runtime, many interpreters of the _same_ instruction set.** The fiber runtime is fixed; the _scheduler_ (how queued fiber-steps reach the event loop) is swappable — `MixedScheduler` (default), `SyncScheduler`, `ControlledScheduler` (tests).
- **Tree-shakeable, increasingly modular core.** v4 doubles down on this: a rewritten runtime and a unified, more tree-shakeable package layout (see the v4 section).

---

## Core abstractions & types

### `Effect<A, E, R>`

The central type is declared identically in both lines (`packages/effect/src/Effect.ts`):

```ts
// v3: packages/effect/src/Effect.ts
export interface Effect<out A, out E = never, out R = never>
  extends Effect.Variance<A, E, R>,
    Pipeable {
  [Symbol.iterator](): EffectGenerator<Effect<A, E, R>>;
}
```

```ts
// v4: typescript/effect-smol/packages/effect/src/Effect.ts
export interface Effect<out A, out E = never, out R = never>
  extends Pipeable,
    Inspectable {
  readonly [TypeId]: Variance<A, E, R>;
  [Symbol.iterator](): EffectIterator<Effect<A, E, R>>;
}
```

| Parameter | Meaning                           | When `never`                 |
| --------- | --------------------------------- | ---------------------------- |
| **A**     | Success value type                | `void` = no meaningful value |
| **E**     | Error (failure) channel type      | `never` = cannot fail        |
| **R**     | Requirements / services (context) | `never` = no requirements    |

Both lines expose extractors `Effect.Success<T>` / `Effect.Error<T>`; v3 calls the requirement extractor `Effect.Context<T>`, while v4 renames it `Effect.Services<T>` (`Effect.ts`, with `@see Services` cross-references throughout) — a vocabulary shift that runs through the whole v4 API (`Context.Service`, `Effect.context`, `Effect.runForkWith(services)`).

The `[Symbol.iterator]` member is what makes a bare `Effect` `yield*`-able inside `Effect.gen` — it returns a single-shot generator (`SingleShotGen` in `Utils.ts`) wrapping the effect.

### Runtime instruction representation

An `Effect` is a small tagged object. In **v3** every primitive is an `EffectPrimitive` carrying an opcode string `_op` (`packages/effect/src/internal/core.ts`):

```ts
// v3: internal/core.ts — primitives are tagged by ._op (OpCodes.OP_*)
class EffectPrimitive {
  /* _op, effect_instruction_i0/i1/i2, [EffectTypeId] = effectVariance */
}
```

The opcodes (`internal/opCodes/effect.ts`) include `OP_SUCCESS`, `OP_FAILURE`, `OP_SYNC`, `OP_ASYNC`, `OP_ON_SUCCESS`, `OP_ON_FAILURE`, `OP_ON_SUCCESS_AND_FAILURE`, `OP_WHILE`, `OP_ITERATOR`, `OP_UPDATE_RUNTIME_FLAGS`, `OP_COMMIT`, `OP_YIELD`, `OP_TAG`, etc.

In **v4** the representation is reworked around symbol-keyed _prototype methods_ rather than a string switch (`effect-smol/packages/effect/src/internal/core.ts`). Each primitive carries an `[evaluate]` method plus optional `[contA]` (success continuation), `[contE]` (failure continuation), and `[contAll]` (ensure/finalizer) methods:

```ts
// v4: internal/core.ts
export interface Primitive {
  readonly [identifier]: string;
  readonly [contA]: ((value, fiber, exit?) => Primitive | Yield) | undefined;
  readonly [contE]: ((cause, fiber, exit?) => Primitive | Yield) | undefined;
  readonly [contAll]:
    | ((fiber) => ((value, fiber) => Primitive | Yield) | undefined)
    | undefined;
  [evaluate](fiber: FiberImpl): Primitive | Yield;
}
// built via makePrimitive / makePrimitiveProto — each op IS a tiny prototype object
```

This is the heart of the v4 runtime rewrite: instead of one giant `[OpCodes.OP_*]` method table on the fiber (v3), each effect node _is_ its own interpreter step, dispatched virtually through its prototype. It cuts allocation and indirection per step.

---

## How effects are declared

### Generators (`Effect.gen` + `yield*`)

`Effect.gen` is the primary composition mechanism. Both lines compile a generator function into an iterator-driven effect (v3 `internal/core.ts`):

```ts
// v3: internal/core.ts
export const gen = function () {
  const f =
    arguments.length === 1 ? arguments[0] : arguments[1].bind(arguments[0]);
  return fromIterator(() => f(pipe)); // builds an OP_ITERATOR primitive
};
```

A worked example (idiomatic v3; the `R` channel accumulates automatically):

```ts
// v3 idiom
import { Effect, Context } from 'effect';

class Database extends Context.Tag('@app/Database')<
  Database,
  {
    readonly query: (sql: string) => Effect.Effect<unknown[], DatabaseError>;
  }
>() {}

const getUser = (id: string) =>
  Effect.gen(function* () {
    const db = yield* Database; // adds Database to R
    const rows = yield* db.query('SELECT …'); // adds DatabaseError to E
    return rows[0] as User;
  });
// inferred: Effect<User, DatabaseError, Database>
```

In **v4** the recommended idiom shifts to `Context.Service` (the v4 successor to `Context.Tag`) and to `Effect.fn("name")` / `Effect.fnUntraced` for functions that return effects — the repo's own [`.patterns/effect.md`](#sources) instructs agents to _"prefer `Effect.fnUntraced` over functions that only return `Effect.gen`"_ and to _"prefer the class syntax when working with `Context.Service`"_, and [`ai-docs/`](#sources) carries the canonical service example:

```ts
// v4: typescript/effect-smol/ai-docs/src/01_effect/02_services/01_service.ts
export class Database extends Context.Service<
  Database,
  {
    query(sql: string): Effect.Effect<Array<unknown>, DatabaseError>;
  }
>()('myapp/db/Database') {
  static readonly layer = Layer.effect(
    Database,
    Effect.gen(function* () {
      const query = Effect.fn('Database.query')(function* (sql: string) {
        /* … */
      });
      return Database.of({ query });
    }),
  );
}
```

### Yieldable (v4): what may be `yield*`-ed

A defining v4 change (`effect-smol/migration/yieldable.md`): in v3, many types (`Ref`, `Deferred`, `Fiber`, `FiberRef`, `Config`, `Option`, `Either`, `Context.Tag`) were _structural subtypes of `Effect`_ and could be passed anywhere an `Effect` was expected. v4 replaces this with a narrower **`Yieldable`** trait:

```ts
// v4: migration/yieldable.md
interface Yieldable<Self, A, E = never, R = never> {
  asEffect(): Effect<A, E, R>;
  [Symbol.iterator](): EffectIterator<Self>;
}
```

`Option`, `Result`, `Config`, and `Context.Service` are `Yieldable` (so `yield*` still works and the runtime calls `.asEffect()` internally). But `Ref`, `Deferred`, and `Fiber` are **no longer Effects** — you must use `Ref.get`, `Deferred.await`, `Fiber.join`. This removes a class of bugs where a `Ref` silently flowed into `Effect.map`. Concretely, v4's `Fiber` no longer extends `Effect`:

```ts
// v3: packages/effect/src/Fiber.ts — Fiber IS an Effect
export interface Fiber<out A, out E = never> extends Effect.Effect<A, E>, Fiber.Variance<A, E> { … }

// v4: effect-smol/packages/effect/src/Fiber.ts — Fiber is NOT an Effect
export interface Fiber<out A, out E = never> extends Pipeable {
  readonly currentOpCount: number
  readonly maxOpsBeforeYield: number
  readonly interruptUnsafe: (…) => void
}
```

---

## How handlers/interpreters work

Effect has no user-defined handlers; the single, fixed interpreter is the **fiber runtime**. The mechanics differ markedly between lines.

### v3 — `FiberRuntime` with an `_op` dispatch loop

`FiberRuntime` (`packages/effect/src/internal/fiberRuntime.ts`) extends `Effectable.Class` and holds the mutable fiber state: a message inbox `_queue`, a continuation `_stack`, `currentRuntimeFlags`, `currentScheduler`, `currentContext`, `_asyncInterruptor`, `currentOpCount`, etc. The core is `runLoop`, a trampoline that repeatedly dispatches the current primitive through `this[cur._op](cur)`:

```ts
// v3: internal/fiberRuntime.ts — runLoop (abridged)
runLoop(effect0): Exit | YieldedOp {
  let cur = effect0
  this.currentOpCount = 0
  while (true) {
    if (this._queue.length > 0) cur = this.drainQueueWhileRunning(this.currentRuntimeFlags, cur)
    if (!this._isYielding) {
      this.currentOpCount += 1
      const shouldYield = this.currentScheduler.shouldYield(this)   // op-budget check
      if (shouldYield !== false) {
        this._isYielding = true
        this.currentOpCount = 0
        const oldCur = cur
        cur = core.flatMap(core.yieldNow({ priority: shouldYield }), () => oldCur)
      }
    }
    cur = this[cur._op](cur)            // <-- dispatch on the opcode string
    if (cur === YieldedOp) { /* OP_YIELD or OP_ASYNC → suspend; else materialize Exit */ }
  }
}
```

`yield*` is interpreted by the `OP_ITERATOR` continuation (`contOpSuccess[OP_ITERATOR]`): it drives the generator with `iterator.next(value)`; for each yielded effect it pushes the iterator frame back on the stack and returns the yielded primitive to the loop; when `state.done` it returns `exitSucceed(state.value)`.

### v4 — `FiberImpl` with prototype `[evaluate]` dispatch

`FiberImpl` (`effect-smol/packages/effect/src/internal/effect.ts`) is the rewritten runtime. The loop dispatches by calling the primitive's own `[evaluate]` method instead of indexing a method table:

```ts
// v4: internal/effect.ts — runLoop (abridged)
runLoop(effect: Primitive): Exit | Yield {
  let yielding = false
  let current = effect
  this.currentOpCount = 0
  const currentLoop = ++this.currentLoopCount
  while (true) {
    this.currentOpCount++
    if (!yielding && !this.currentPreventYield && this.currentScheduler.shouldYield(this)) {
      yielding = true
      current = flatMap(yieldNow, () => prev)   // re-enter after a scheduler tick
    }
    current = this.currentTracerContext
      ? this.currentTracerContext(current, this)
      : current[evaluate](this)                 // <-- virtual dispatch on the primitive
    if (currentLoop !== this.currentLoopCount) return Yield   // another effect took the loop
    else if (current === Yield) { /* if _yielded is an Exit → return it; else suspend */ }
  }
}
```

Continuations are popped from `_stack` via `getCont(contA | contE)`, which also runs `[contAll]` ensure-hooks (finalizers, interruptibility restores) as it unwinds. The generator front end is `fromIteratorUnsafe` (op `"Iterator"`): its `[contA]` advances `iter.next(value)`, pushes itself back for non-`Exit` results, and short-circuits on `Failure`. `Effect.gen` first tries to resolve the iterator _synchronously_ and only falls back to a suspended `flatMap` chain when it hits a genuinely async effect — a fast path for sync-heavy generators.

---

## Performance approach

Effect is single-threaded JavaScript; "performance" means _throughput per fiber step_ and _bytes shipped to the client_.

### The Scheduler — bridging fibers to the JS event loop

A fiber that must wait (an `OP_ASYNC` / `callback` effect) **does not block**. It registers a resume callback, returns control to the runtime, and the runtime re-enters the fiber when the callback fires. Between steps, fibers are re-scheduled onto the host event loop by the `Scheduler` (`Scheduler.ts`). The op-budget (`MaxOpsBeforeYield`, default **2048**) forces even a CPU-bound fiber to yield periodically so other fibers (and the event loop / Node libuv) make progress — cooperative fairness without preemption.

**v3 `MixedScheduler`** (`packages/effect/src/Scheduler.ts`) batches tasks into `PriorityBuckets` and drains them via the **microtask queue**, escalating to a macrotask after a depth threshold:

```ts
// v3: Scheduler.ts — MixedScheduler drain strategy
private readonly getRunner = SchedulerRunner.cached((depth, drain) => {
  if (depth >= this.maxNextTickBeforeTimer) setTimeout(() => drain(0), 0)  // macrotask escape hatch
  else Promise.resolve(void 0).then(() => drain(depth + 1))                // microtask
})
// defaultScheduler = new MixedScheduler(2048)
```

So a chain of resumed fibers runs on successive **microtasks** (`Promise.resolve().then`), and only after `maxNextTickBeforeTimer` (2048) consecutive microtask drains does it hand back to the macrotask queue (`setTimeout(…, 0)`) — preventing microtask starvation of timers and I/O callbacks.

**v4 `MixedScheduler`** (`effect-smol/packages/effect/src/Scheduler.ts`) instead dispatches via **`setImmediate`** (with a `setTimeout(f, 0)` fallback where `setImmediate` is unavailable), and supports an explicit `"sync" | "async"` execution mode plus a `makeDispatcher()` per fiber:

```ts
// v4: Scheduler.ts
const setImmediate =
  'setImmediate' in globalThis
    ? f => {
        const t = globalThis.setImmediate(f);
        return () => globalThis.clearImmediate(t);
      }
    : f => {
        const t = setTimeout(f, 0);
        return () => clearTimeout(t);
      };

export class MixedScheduler implements Scheduler {
  constructor(
    readonly executionMode = 'async',
    readonly setImmediate = setImmediate,
  ) {}
  shouldYield(fiber) {
    return fiber.currentOpCount >= fiber.maxOpsBeforeYield;
  }
  makeDispatcher() {
    return new MixedSchedulerDispatcher(this.setImmediate);
  }
}
```

In both lines the chain is: **fiber step → scheduler task queue (priority buckets) → host tick (microtask/`setImmediate`/timer) → drain → resume fiber**. The scheduler is the _only_ place Effect touches the underlying event loop; everything above it is platform-agnostic. (For where this sits among readiness vs. completion I/O models, see [Effect Systems & Event Loops][ae-event-loops].)

### Async registration & resumption

The async primitive builds a one-shot resume callback and feeds it to the user's register function (v3 `initiateAsync`, `internal/fiberRuntime.ts`):

```ts
// v3: internal/fiberRuntime.ts
initiateAsync(runtimeFlags, asyncRegister) {
  let alreadyCalled = false
  const callback = (effect) => {
    if (alreadyCalled) return
    alreadyCalled = true
    this.tell(FiberMessage.resume(effect))   // re-enqueue the fiber's inbox
  }
  if (runtimeFlags_.interruptible(runtimeFlags)) this._asyncInterruptor = callback
  asyncRegister(callback)
}
```

`tell` pushes a message and, if the fiber is idle, calls `drainQueueLaterOnExecutor()`, which does `this.currentScheduler.scheduleTask(this.run, priority, this)`. v4's `Async` primitive (`internal/effect.ts`) is the structurally equivalent rewrite: a `resumed`/`yielded` latch, optional `AbortController` wired to the `signal`, and `fiber.evaluate(effect)` to resume.

### Bundle size (v4's headline number)

v4's rewrite is explicitly motivated by bundle size and runtime cost. Per the official beta post and `effect-smol/MIGRATION.md`: a minimal Effect program drops from **~70 KB in v3 to ~20 KB in v4** (full program with Stream + Schema), with a minimal core around **~6.3 KB** min+gzip and **~15 KB** with Schema. The flatter `internal/` layout (v3 has a deep `internal/` tree with dozens of files; v4 collapses much of the core into a single large `internal/effect.ts` plus a small `internal/core.ts`) and the prototype-dispatch primitive design are what enable aggressive tree-shaking.

---

## Composability model

### Layers — typed dependency injection

`Layer<ROut, E, RIn>` (signature identical across lines) is a blueprint for constructing services `ROut` from dependencies `RIn`, possibly failing with `E`:

```ts
// v3 packages/effect/src/Layer.ts & v4 effect-smol/.../Layer.ts
export interface Layer<in ROut, out E = never, out RIn = never>
  extends Variance<ROut, E, RIn>,
    Pipeable {}
```

A program type-checks as runnable only when its `R` is fully discharged by provided layers (`Effect.provide`). Layers are memoized so a service is constructed once, and they integrate with `Scope` so acquisition/finalization is lifecycle-correct.

A key v4 semantic change (`effect-smol/migration/layer-memoization.md`): in v3 each `Effect.provide` call had its _own_ memoization scope, so two `Effect.provide` calls with overlapping layers would build them **twice**. In v4 the `MemoMap` is shared across `Effect.provide` calls by default (opt out with `{ local: true }`), so overlapping layers are deduplicated globally — `"Building MyService"` logs once, not twice.

### Structured concurrency & interruption

Fibers form a supervision tree: a parent fiber owns its forked children, and finishing/interrupting the parent interrupts the children. Interruption is cooperative and Cause-aware:

- v3: `FiberRuntime.interruptAsFork` / the `_asyncInterruptor`, `RuntimeFlags` (`OpSupervision`, interruptibility), and `Cause` carry the interrupt reason; `Fiber.join` / `Fiber.await` observe the `Exit`.
- v4: `FiberImpl.interruptUnsafe(fiberId?, annotations?)` combines an interrupt `Cause` (the v4 `Cause` is a _flattened_ array of `Fail | Die | Interrupt` reasons — see `migration/cause.md`), respects the `interruptible` flag, and the `asyncFinalizer` continuation flips interruptibility off while a finalizer runs.

`Effect.runFork` returns a `RuntimeFiber`; `Effect.runPromise` adds an observer that resolves a `Promise` from the fiber's `Exit`. v4 removes the `Runtime<R>` value entirely (`migration/runtime.md`): run functions live directly on `Effect` (`Effect.runForkWith(services)`), the `Runtime` module shrinks to process-lifecycle helpers (`Teardown`, `makeRunMain`), and `ManagedRuntime` remains the bridge for embedding Effect in non-Effect code (web handlers, framework hooks).

---

## Strengths

- **One coherent model** for typed errors (`E`), dependency injection (`R` + `Layer`), structured concurrency, interruption, and resource safety — replacing four ad-hoc TypeScript idioms.
- **Strong inference** through `Effect.gen`: `E` and `R` accumulate automatically, and a program literally does not type-check until all requirements are provided.
- **Swappable scheduler** cleanly isolates the only event-loop touchpoint (`MixedScheduler`/`SyncScheduler`/`ControlledScheduler`), enabling deterministic tests (`TestClock`, controlled stepping).
- **Active, well-funded ecosystem** with fast release cadence (HttpApi, CLI, AI, cluster, Schema, Stream), and a v4 rewrite that materially improves bundle size and runtime cost.
- **Cooperative fairness** via the op-budget yield (default 2048), so CPU-bound fibers don't starve I/O.

## Weaknesses

- **Conceptual overhead.** Three type parameters, layers, fibers, Causes, and a large API surface impose a steep learning curve versus plain `Promise`.
- **Runtime indirection.** Every step is an interpreted instruction on a fiber; for trivial straight-line code this is overhead a bare `async/await` avoids (v4 narrows but does not erase the gap).
- **Not algebraic handlers.** The "operations" are a fixed runtime instruction set; there is no user-defined `perform`/`handle`, so it cannot express arbitrary resumable effects like [Koka][koka], [Eff][eff-lang], or [OCaml 5][ocaml-effects].
- **Framework gravity / migration cost.** Deep integration creates lock-in; the v3→v4 transition is a _major_ version with renamed APIs (`Context.Tag`→`Context.Service`, removed Effect-subtyping via `Yieldable`, flattened `Cause`, removed `Runtime<R>`).
- **v4 is beta.** As of June 2026, `effect@4.0.0-beta.75` is beta and may have breaking changes; the maintainers recommend **v3 for production** (see status below).

---

## Key design decisions and trade-offs

| Decision                                                                                             | Rationale                                                                                         | Trade-off                                                                                                 |
| ---------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `Effect<A, E, R>` as an immutable description, not a running computation                             | Retries, timeouts, concurrency, interruption become ordinary combinators over a value             | Nothing runs until a runtime executes it; adds a mental indirection vs. eager `Promise`                   |
| Generators (`Effect.gen` + `yield*`) as the front end                                                | `async/await`-like ergonomics with full `E`/`R` inference                                         | Generator step overhead; v4 adds `Effect.fn`/`fnUntraced` and tweaks `gen(this, …)` → `gen({ self }, …)`  |
| v3 `_op` switch interpreter vs. v4 prototype `[evaluate]` dispatch                                   | v4: less allocation/indirection per fiber step; simpler internals; better tree-shaking            | A ground-up rewrite (`effect-smol`) and a breaking major version to ship it                               |
| v3 microtask scheduler (`Promise.resolve().then`, `setTimeout` escape at 2048) vs. v4 `setImmediate` | Bridge fibers to the JS event loop without blocking; keep timers/I/O from starving                | Scheduling semantics differ subtly between hosts (`setImmediate` is Node-ish; falls back to `setTimeout`) |
| Op-budget yield (`MaxOpsBeforeYield` = 2048)                                                         | Cooperative fairness so CPU-bound fibers don't monopolize the single thread                       | Tunable but never truly preemptive; `PreventSchedulerYield` can disable it and starve the loop            |
| Fixed instruction set, no user-defined handlers                                                      | Predictable, optimizable runtime; typed errors/DI without language support                        | Cannot express arbitrary algebraic operations/resumptions like [Koka]/[OCaml 5][ocaml-effects]            |
| `Layer<ROut, E, RIn>` for DI + memoization                                                           | Compile-time-verified, deduplicated, scope-aware service graph                                    | v4 changes memoization to a shared `MemoMap` across `provide` calls — a behavioral break                  |
| v4 `Yieldable` replaces v3 Effect-subtyping                                                          | Removes silent bugs (a `Ref` flowing into `Effect.map`)                                           | Breaking: `Ref`/`Deferred`/`Fiber` now need explicit `.get`/`.await`/`.join` and `.asEffect()`            |
| v4 unified, single-version, tree-shakeable packages + `effect/unstable/*`                            | One version across the ecosystem; faster iteration on new modules; ~70 KB → ~20 KB minimal bundle | Migration churn; `unstable/*` modules can break in minor releases                                         |

---

## Project status (verified June 2026)

### Stable line — Effect 3.x

The `Effect-TS/effect` repository publishes the active, production-recommended **3.x** line (`effect@3.21.2` in the cloned source). The maintainers have placed v3 under a **feature freeze**: bug fixes and security patches continue, but new features land only in v4. [effect.website][docs] explicitly recommends **v3 for production** during the v4 beta.

### Next line — Effect v4 (`effect-smol`), beta

Effect v4 — developed in `Effect-TS/effect-smol` (`effect@4.0.0-beta.75` in the cloned source) — entered **public beta on February 18, 2026**. Per the official [v4 beta release post][v4-beta] and `effect-smol/MIGRATION.md`, the rewrite's goals are:

- **Rewritten fiber runtime** "from scratch to have lower memory overhead, faster execution, and simpler internals" (the prototype-`[evaluate]` design documented above).
- **Smaller bundles** via aggressive tree-shaking (~70 KB → ~20 KB for a minimal Stream+Schema program; ~6.3 KB minimal core).
- **Unified package system**: all ecosystem packages share one version (`@effect/sql-pg@4.0.0-beta.x` matches `effect@4.0.0-beta.x`); many former separate packages (`@effect/platform`, `@effect/rpc`, `@effect/cluster`) merge into core `effect`.
- **Unstable modules** under `effect/unstable/*` (ai, cli, cluster, http, schema, sql, …) that may break in minor releases until they graduate to top-level `effect/*`.

v4 is **beta**: APIs may still change, and the maintainers state that once it stabilizes it will be a long-term-stable (LTS) release. Major migration axes are catalogued in `effect-smol/migration/` (services, cause, error-handling, forking, yieldable, fiberref, runtime, scope, equality, generators, schema). For a third-party summary, see [InfoQ's v4 beta report][infoq-v4].

---

## Comparison note

Effect shares ZIO's three-parameter shape and runtime model, and Cats Effect's fiber/structured-concurrency model:

| [ZIO][scala-zio] concept                    | [Cats Effect][scala-cats-effect] analogue | Effect equivalent                                          |
| ------------------------------------------- | ----------------------------------------- | ---------------------------------------------------------- |
| `ZIO[R, E, A]`                              | `IO[A]` (+ `Resource`, MTL for `R`/`E`)   | `Effect<A, E, R>`                                          |
| `ZLayer[In, E, Out]`                        | `Resource[F, A]`                          | `Layer<ROut, E, RIn>`                                      |
| `for` comprehension                         | `for` comprehension (cats)                | `Effect.gen(function* () { … })`                           |
| Fiber runtime (work-stealing, multi-thread) | Fiber runtime (compute pool)              | Single-threaded `FiberRuntime`/`FiberImpl` + JS event loop |
| Interruption + `Cause`                      | Cancellation + `Outcome`                  | Interruption + `Cause`                                     |

The decisive difference is the host: Effect runs on a **single-threaded** JS runtime, so its scheduler bridges to microtasks/`setImmediate`/libuv rather than OS threads — see [Effect Systems & Event Loops][ae-event-loops] for how this places Effect among the fiber-runtime libraries whose suspension is a runtime-managed callback rather than a language-level continuation ([OCaml 5][ocaml-effects], [Koka][koka]).

---

## Sources

Source files read in `/home/petar/code/repos/typescript/`:

- **v3 (`effect/`)**: `packages/effect/src/Effect.ts`, `Scheduler.ts`, `Fiber.ts`, `Layer.ts`, `internal/fiberRuntime.ts` (`runLoop`, `initiateAsync`, `drainQueueLaterOnExecutor`, `contOpSuccess`), `internal/core.ts` (`gen`, `fromIterator`, `EffectPrimitive`), `internal/runtime.ts` (`unsafeFork`, `unsafeRunCallback`).
- **v4 (`effect-smol/`)**: `packages/effect/src/Effect.ts`, `Scheduler.ts`, `Fiber.ts`, `Layer.ts`, `internal/effect.ts` (`FiberImpl`, `runLoop`, `Async`, `fromIteratorUnsafe`), `internal/core.ts` (`makePrimitive`/`makePrimitiveProto`, `Primitive`); `AGENTS.md`, `LLMS.md`, `MIGRATION.md`, `.patterns/effect.md`, `ai-docs/src/01_effect/02_services/01_service.ts`, `migration/{yieldable,runtime,layer-memoization,generators,cause}.md`; `packages/effect/package.json` (`4.0.0-beta.75`).
- Web: [v4 beta release post][v4-beta], [effect.website][docs], [InfoQ v4 beta report][infoq-v4].

Effect documentation references:

- [Using Generators][gen-docs]
- [Services][services-docs]
- [Layers][layers-docs]
- [Fibers][fibers-docs]
- [Scope][scope-docs]

<!-- References -->

[scala-zio]: scala-zio.md
[scala-cats-effect]: scala-cats-effect.md
[ZIO]: scala-zio.md
[Cats Effect]: scala-cats-effect.md
[koka]: koka.md
[ocaml-effects]: ocaml-effects.md
[eff-lang]: eff-lang.md
[comparison]: comparison.md
[ae-event-loops]: ../async-io/effects-and-event-loops.md
[repo]: https://github.com/Effect-TS/effect
[smol-repo]: https://github.com/Effect-TS/effect-smol
[docs]: https://effect.website/
[v4-beta]: https://effect.website/blog/releases/effect/40-beta/
[infoq-v4]: https://www.infoq.com/news/2026/04/effect-v4-beta/
[gen-docs]: https://effect.website/docs/getting-started/using-generators/
[services-docs]: https://effect.website/docs/requirements-management/services/
[layers-docs]: https://effect.website/docs/requirements-management/layers/
[fibers-docs]: https://effect.website/docs/concurrency/fibers/
[scope-docs]: https://effect.website/docs/resource-management/scope/
