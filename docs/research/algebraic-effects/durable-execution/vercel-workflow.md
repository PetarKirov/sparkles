# Vercel Workflow DevKit (TypeScript)

A compiler-directive durable-execution SDK: `"use workflow"` functions are replayed inside a seeded Node.js `vm` sandbox against an append-only, slot-numbered event log, `"use step"` functions run once in the host and are matched to their recorded results by a replay-stable ULID drawn from the sandbox's seeded `Math.random`.

| Field             | Value                                                                                                                                                                                                          |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | TypeScript (Node.js `^22 \|\| ^24`); the directive transform is a Rust SWC plugin                                                                                                                              |
| License           | Apache-2.0 ([`LICENSE.md`][license])                                                                                                                                                                           |
| Repository        | [vercel/workflow][repo]                                                                                                                                                                                        |
| Documentation     | [workflow-sdk.dev][docs] (source under [`docs/content/`][docs-src]; `useworkflow.dev` now redirects there)                                                                                                     |
| Category          | durable-execution SDK                                                                                                                                                                                          |
| Persistence model | replay (re-run the sandboxed orchestrator; each step consumer resolves from the log)                                                                                                                           |
| Journal store     | A per-run event log behind the `World` interface (`runs`, `steps`, `events`, `hooks`, plus a queue and streams); JSON files under `.workflow-data/` in the Local World, Postgres or Vercel's API in the others |
| Latest release    | `workflow` `4.8.8` is the npm `latest` tag; the reviewed tree is `5.0.0-beta.50` (`beta` tag) ([registry][npm])                                                                                                |
| Local clone       | `$REPOS/vercel-workflow` at `17bd649839b9131db29f17e1d3f1c06c6d1ca799`                                                                                                                                         |

**Last reviewed:** September 12, 2026.

---

## Overview

### What it solves

The Workflow DevKit is Vercel's answer to the same problem as [Temporal][temporal] and [DBOS][dbos]: an `async` function that must survive the process running it. Its distinguishing bet is that the orchestrator/step split should be a **compiler** concern, not a library one. Two string directives, modelled on React's `"use server"`, split one source file into two bundles: the step bundle keeps step bodies intact and registers them in a global map, and the workflow bundle replaces every step body with a proxy that consults the event log. From [`packages/swc-plugin-workflow/spec.md`][swc-spec]:

> _"The `"use step"` and `"use workflow"` directives work similarly to `"use server"` in React. A function marked with `"use step"` represents a durable step that executes on the server. A function marked with `"use workflow"` represents a durable workflow that orchestrates steps."_

The second bet is that determinism should be **enforced by a sandbox rather than requested by a style guide**. The workflow bundle is executed inside a `node:vm` context whose `Math.random`, `Date`, `crypto.getRandomValues` and `crypto.randomUUID` are seeded from the run id, whose timers and `fetch` throw, and whose `Atomics.waitAsync`, `WeakRef` and async `WebAssembly` entry points are deleted ([`packages/core/src/vm/index.ts`][vm]). The docs state the resulting contract plainly ([`foundations/workflows-and-steps.mdx`][ws]):

> _"The sandboxed environment that workflows run in already ensures determinism. For instance, `Math.random` and `Date` constructors are fixed in workflow runs, so you are safe to use them, and the framework ensures that the values don't change across replays."_

### Design philosophy

Everything durable is an **event**, and every entity (run, step, hook, wait) is a fold over its events. The docs page on event sourcing ([`how-it-works/event-sourcing.mdx`][es-src], live at [workflow-sdk.dev][es]) opens with: _"The Workflow SDK uses event sourcing to track all state changes in workflow executions. Every mutation creates an event that is persisted to the event log, and entity state is derived by replaying these events."_ The storage backend is abstracted as a **World**: one interface (`World extends Queue, Streamer, Storage`) with three shipped implementations, `world-local` (JSON files), `world-postgres`, and `world-vercel`, plus `world-sim`, a deterministic in-memory World whose only job is to play out races and check the log contract.

Three consequences shape the API:

1. **Workflows are plain `async` functions and nothing else.** There is no `ctx.step(...)` object, no activity stubs, no `Promise.all` replacement. Concurrency is JavaScript's own `Promise.all`/`Promise.race` over step promises ([`sequential-and-parallel.mdx`][seqpar]).
2. **Step identity is minted, not named.** A step invocation's `correlationId` is `step_` plus a ULID drawn from the sandbox's seeded PRNG at a fixed timestamp ([`packages/core/src/step.ts`][step]), so the _n_-th draw of the _n_-th replay yields the same id. Source location and step name are checked, not used as the key.
3. **Runs are pinned to the deployment that created them.** New code never touches an in-flight run; upgrading is `start(self, [state], { deploymentId: "latest" })` from a clean point ([`foundations/versioning.mdx`][versioning-src], live at [workflow-sdk.dev][versioning]).

Within this catalog the DevKit is the _compiler-directive plus seeded-sandbox_ data point. Compare [Effect Workflow][effect-workflow] (same language, library-only, explicit step names), [DBOS][dbos] (same language, Postgres rows, position-keyed), and [Temporal][temporal] (the server-side history protocol it most resembles at the event level).

---

## How it works

### The three transform modes

The SWC plugin runs over every candidate file in one of three modes ([`code-transform.mdx`][ct]):

| Mode       | Step body                                    | Workflow body                              | Output                                                              |
| ---------- | -------------------------------------------- | ------------------------------------------ | ------------------------------------------------------------------- |
| `step`     | kept verbatim; registered via an inline IIFE | replaced with a `throw`; gets `workflowId` | the step registration bundle, and the transform applied to app code |
| `workflow` | replaced with a `WORKFLOW_USE_STEP` proxy    | kept verbatim; gets `workflowId`           | the `flow.js` bundle executed inside the VM                         |
| `detect`   | untouched                                    | untouched                                  | a JSON manifest comment for the build's discovery phase             |

Step mode's output, from [`spec.md`][swc-spec]:

```ts
export async function add(a, b) {
  return a + b;
}
(function (__wf_fn, __wf_id) {
  var __wf_sym = Symbol.for('@workflow/core//registeredSteps'),
    __wf_reg = globalThis[__wf_sym] || (globalThis[__wf_sym] = new Map());
  __wf_reg.set(__wf_id, __wf_fn);
  __wf_fn.stepId = __wf_id;
})(add, 'step//./input//add');
```

Workflow mode's output for the same step, and for a workflow function:

```ts
export var add =
  globalThis[Symbol.for('WORKFLOW_USE_STEP')]('step//./input//add');

export async function myWorkflow(data) {
  const result = await fetchData(data);
  return result;
}
myWorkflow.workflowId = 'workflow//./input//myWorkflow';
globalThis.__private_workflows.set('workflow//./input//myWorkflow', myWorkflow);
```

IDs follow `{type}//{modulePath}//{identifier}`; nested steps get `/`-joined paths (`step//./src/jobs/order//processOrder/innerStep`), methods `#` or `.`, and a `moduleSpecifier` plugin option substitutes a versioned package specifier for the path so a library's step ids survive bundling. A nested step that closes over workflow locals gets a second argument, a thunk returning the captured variables, which the runtime serializes as `closureVars` alongside the step's arguments. The transform itself is [`transform/src/lib.rs`][swc-lib].

### The event log

The `World`'s `Storage` interface is four namespaces, `runs`, `steps`, `events`, `hooks` ([`packages/world/src/interfaces.ts`][interfaces]). `events.create(runId, data)` is the single write primitive: _"Create an event for an existing workflow run and atomically update the entity. Returns both the event and the affected entity (run/step/hook)."_ An optional `events.createBatch` appends a list in one durable write. The event vocabulary is a closed `zod` enum ([`packages/world/src/events.ts`][events]):

```ts
export const EventTypeSchema = z.enum([
  'run_created',
  'run_started',
  'run_completed',
  'run_failed',
  'run_cancelled',
  'attr_set',
  'step_created',
  'step_completed',
  'step_failed',
  'step_retrying',
  'step_started',
  'hook_created',
  'hook_received',
  'hook_disposed',
  'hook_conflict',
  'wait_created',
  'wait_completed',
  'noop',
]);
```

Every event carries `eventType`, an optional `correlationId` (the step/hook/wait id) and a `specVersion`. `step_created` carries `{ stepName, workflowName?, input }`; `step_started` carries `{ stepName?, attempt?, input?, ownerMessageId? }` where a present `input` means this start also created the step (the "lazy start" path that folds `step_created` into `step_started`); `wait_created` carries `resumeAt`. Event ids are **slot numbers**: `evnt_` plus the 1-based log position zero-padded to ULID width, dense within a run, assigned by the World before the write commits ([`event-sourcing.mdx`][es-src]). A missing slot below the highest visible one fails the run with `CORRUPTED_EVENT_LOG` rather than replay across the hole; since spec version 7 the backend seals abandoned slots with a `noop` that replay steps over without advancing the clock ([`spec-version.ts`][specver]).

The Local World stores all of this as JSON files under `WORKFLOW_LOCAL_DATA_DIR` (default `.workflow-data/`) with temp-file atomic writes ([`worlds/v5/local.mdx`][local-src], [`packages/world-local/src/fs.ts`][local-fs]).

### Replay: the consumer queue

Each invocation of the flow handler builds a fresh VM context, installs the `WORKFLOW_USE_STEP` hook, loads the run's events into an `EventsConsumer`, and calls the workflow function. From [`packages/core/src/workflow.ts`][workflow]:

```ts
const {
  context,
  globalThis: vmGlobalThis,
  updateTimestamp,
} = createContext({
  seed: `${workflowRun.runId}:${workflowRun.workflowName}:${workflowRun.deploymentId}`,
  fixedTimestamp,
});
// ...
const ulid = monotonicFactory(() => vmGlobalThis.Math.random());
// Correlation IDs must be replay-stable. `startedAt` differs between a turbo
// delivery and a later server-backed replay, so use fixedTimestamp.
let mintCount = 0;
const generateUlid = () => {
  mintCount += 1;
  return ulid(fixedTimestamp);
};
```

When the workflow body calls a step proxy, `useStep` mints the id, records a `StepInvocationQueueItem` (`stepName`, `args`, `thisVal`, `closureVars`) in `ctx.invocationsQueue`, and **subscribes a consumer** to the event walk ([`step.ts`][step]):

```ts
const correlationId = `step_${ctx.generateUlid()}`;
// ...
ctx.eventsConsumer.subscribe(event => {
  if (!event) {
    // We've reached the end of the events, so this step has either not been run or is currently running.
    scheduleWorkflowSuspension(ctx);
    return EventConsumerResult.NotConsumed;
  }
  if (event.correlationId !== correlationId) {
    return EventConsumerResult.NotConsumed;
  }
  if (typeof eventStepName === 'string' && eventStepName !== stepName) {
    // ... ReplayDivergenceError: event belongs to a different step name
  }
  if (event.eventType === 'step_created') {
    queueItem.hasCreatedEvent = true;
    return EventConsumerResult.Consumed;
  }
  // step_started keeps the item queued; step_completed / step_failed resolve or reject the promise
});
```

A `step_completed` resolves the promise with the hydrated result; a `step_failed` rejects it; running out of log leaves the promise pending and schedules a **suspension**. The suspension handler then reads `invocationsQueue` and, for each item without a created event, writes `step_created` (or a lazy `step_started` carrying the input) and either runs the step inline in the same invocation or enqueues a step message. `sleep()` is the same shape with `wait_` ids and `wait_created`/`wait_completed` ([`workflow/sleep.ts`][sleep]); `createHook()` mints a `hook_` id plus a nanoid token from the same PRNG, unless the caller supplies a domain token ([`workflow/hook.ts`][hook]).

The VM clock is the last consumed event's `createdAt`, monotone, so `Date.now()` inside the workflow advances only as the log is walked ([`workflow.ts`][workflow]). v5 also keeps the VM alive across inline steps within one invocation so the next iteration appends only the delta instead of rebuilding the sandbox.

### Steps, retries and errors

The step executor runs the registered function under an `AsyncLocalStorage` context that exposes `getStepMetadata()` (`stepName`, `stepId`, `stepStartedAt`, `attempt`) ([`runtime/step-executor.ts`][executor]). On a throw it classifies: a `FatalError` writes `step_failed` and bubbles to the workflow; anything else counts against `stepFn.maxRetries` (default 3) and writes `step_retrying` with an optional `retryAfter` from `RetryableError`. The attempt number that bounds retries is authoritative even for crashes that never wrote `step_failed`: _"Inline (combined handler): the number of `step_started` events already in the event log for this step, plus one for the attempt about to run."_ ([`count-step-started-events.ts`][count-started]). Serialization failures are treated as fatal because they are deterministic ([`errors-and-retries.mdx`][errors]).

Two names the brief asked about are not workflow primitives here: `waitUntil` in [`runtime/wait-until.ts`][wait-until] is a wrapper over `@vercel/functions`'s `waitUntil`, the platform's background-promise keepalive that the runtime uses to flush stream writes after a response, and `defineHook` is a typed factory over `createHook`/`resumeHook` ([`workflow/define-hook.ts`][define-hook]).

---

## Analysis

### 1. Step identity and replay matching

Identity is **a deterministic draw sequence**, not a name and not a log position. The `correlationId` is `step_${ctx.generateUlid()}`, and `generateUlid` is a `ulid` `monotonicFactory` fed by the sandbox's `seedrandom(seed)` where the seed is `runId:workflowName:deploymentId`, at a fixed timestamp ([`workflow.ts`][workflow], [`vm/index.ts`][vm]). Two replays of the same run mint the same ids in the same order provided the workflow makes the same draws in the same order; every `Math.random()` the user's workflow body calls also advances the sequence, which is why the docs may say `Math.random` is "safe" and still replay-stable. Matching is then by `correlationId` equality on each event, with two cross-checks: the recorded `stepName` must equal the consumer's, and a `step_created` must correspond to a queued invocation ([`step.ts`][step]). The compiler-generated `step//path//name` id is a _registry key_ for finding the function to run and a label in the log, not the replay key. Consequence: inserting a `Math.random()` call, a `crypto.randomUUID()`, or a new `createHook()` before an existing step shifts every later id and produces a divergence, exactly as a position-keyed scheme would.

### 2. Journal versus world

**The journal wins, always, and disagreement is detected by the consumer walk.** A replay that reaches an event no registered consumer accepts, or finishes with events left unconsumed, raises `ReplayDivergenceError` ([`workflow.ts`][workflow]); a `wait_completed` whose `resumeAt` differs from the sleep's computed one is a divergence too ([`sleep.ts`][sleep]). Divergence is not terminal at first: _"The runtime automatically queues another replay when an invocation reports `REPLAY_DIVERGENCE`. No terminal `run_failed` event is written during these recovery attempts."_ ([`errors/replay-divergence.mdx`][divergence]). After the recovery budget the run fails with `CORRUPTED_EVENT_LOG`. Duplicate events from racing invocations are made inert by **event classes**: a second `step_created`, `step_started` or `wait_created` for an entity whose class is already consumed is skipped; a `step_failed` behind a `step_completed` is skipped too, with a distinct debug line because "both writers cannot be correct" ([`events-consumer.ts`][consumer], [`event-sourcing.mdx`][es-src]). There is no notion of re-observing the world: a step's external effect is assumed idempotent under `stepId` ([`idempotency.mdx`][idempotency]) and its recorded result is the truth.

### 3. Determinism enforcement

**By the compiler and the runtime, not by discipline.** The workflow bundle runs in a `node:vm` context where `Math.random` is `seedrandom(seed)`, `Date` with no arguments returns `fixedTimestamp`, `Date.now()` is the replay clock, `crypto.getRandomValues`/`randomUUID` derive from the same PRNG, `crypto.subtle.digest` is computed synchronously so it settles on a deterministic microtask, and every other `subtle` method, `setTimeout`, `setInterval`, `setImmediate` and global `fetch` throw a `WorkflowRuntimeError` pointing at the step-side alternative ([`vm/index.ts`][vm], [`workflow.ts`][workflow]). `Atomics.waitAsync`, `WeakRef`, `FinalizationRegistry` and the async `WebAssembly` compile paths are deleted so no promise a workflow creates can settle on host timing. Build-time validation rejects Node built-ins (`fs`, `http`, `child_process`) in workflow files ([`code-transform.mdx`][ct]). What the sandbox cannot catch is delivery-order sensitivity in user code (a `Promise.race` whose winner depends on which event lands first); the runtime addresses that with delivery barriers that order resolutions by log position, and with the divergence-recovery retry.

### 4. Compensation and failure handling

**No built-in compensation.** The saga recipe is user code: a `compensations: Array<() => Promise<void>>` in the workflow body, a `push` after each forward step, and `for (const compensate of compensations.reverse()) await compensate()` in the `catch` ([`cookbook/common-patterns/saga.mdx`][saga]). The recipe is explicit that "compensation steps undo it and must be idempotent: safe to call multiple times if the workflow restarts mid-rollback", and that only `FatalError` should trigger the unwind because ordinary errors are still being retried. Because compensations are themselves `"use step"` calls made from the workflow body during the catch, they are journaled like any step and replay correctly. Failure classification is three-way: `FatalError` (no retry, `step_failed`), `RetryableError` with `retryAfter` (scheduled retry), anything else (immediate retry up to `maxRetries`) ([`errors-and-retries.mdx`][errors]). Cancellation is a `run_cancelled` event plus hook-backed `AbortSignal`s inside the VM.

### 5. Versioning against old histories

**Pin, then re-run; never migrate.** _"Workflow runs are pinned to the deployment that starts them."_ The runtime enforces this on every queue delivery: `deployment-guard.ts` re-routes a misrouted message to the run's own `deploymentId` with backoff and fails the run after a budget ([`runtime/deployment-guard.ts`][guard]). The documented upgrade paths are (a) cancel affected runs and `start()` again with `deploymentId: "latest"`, or (b) self-upgrading loops that `start(self, [state], { deploymentId: "latest" })` at a clean point where "all in-progress side effects have completed" and state is serializable ([`versioning.mdx`][versioning-src], [`upgrading-workflows.mdx`][upgrading]). There is no patch/version API in the workflow body. The log _format_ is versioned separately by `specVersion` stamped on `run_created`: `SPEC_VERSION_SUPPORTS_SLOT_IDENTITY = 6` and the sealed log at 7 gate reader behaviour, and a runtime refuses a World outside `[SPEC_VERSION_CURRENT, SPEC_VERSION_MAX_SUPPORTED]` ([`spec-version.ts`][specver], [`interfaces.ts`][interfaces]). Compiler-generated ids change when files move, which the docs note "won't break old workflows from running, but will prevent runs from being upgraded" ([`code-transform.mdx`][ct]).

### 6. Concurrency under replay

**Native promises, ordered by log position.** `Promise.all([a(), b(), c()])` mints three ids in call order, subscribes three consumers, and the suspension handler creates and starts all three (inline and in parallel in v5) ([`seqpar.mdx`][seqpar]). On replay, each `step_completed` resolves its own consumer's promise; to keep the JavaScript microtask order independent of which event was written first, completion is deferred through `registerDeliveryBarrier`/`awaitEarlierDeliveries` keyed by `eventIndex` ([`sleep.ts`][sleep], [`step.ts`][step]). `Promise.race` composes the same way, with the documented caveat that the loser keeps running. Racing _invocations_ of the same run (a stale replay and a fresh one) are tolerated at the log level by the duplicate-class rule and by `ownerMessageId` on `step_started`, which lets a wake replay distinguish "in flight in a live invocation" from "died with its process" ([`events.ts`][events]).

### 7. Replay or snapshot

**Replay, with a warm-VM fast path.** Every resumption re-runs the workflow function from the top against the log; there is no continuation capture or heap snapshot. The v5 mitigation is to retain the live VM across inline steps within one invocation so only the event delta is appended, and to batch several steps per suspension instead of returning to the queue after each ([`whats-new.mdx`][whats-new]). The costs replay imposes are visible in the design: a per-run event ceiling (`MAX_EVENTS_EXCEEDED`, 25,000 on Local and Vercel Worlds), a `REPLAY_TIMEOUT` error code, and the recommendation to split unbounded loops into child runs ([`errors-and-retries.mdx`][errors]). What replay rules out is any workflow-body state that is not reconstructible from arguments plus the log, which is why closure variables captured by nested steps are serialized into the step input rather than trusted to survive.

### 8. Testing

Three layers. **Unit**: without the compiler both directives are no-ops, so steps and step-only workflows are plain functions ([`testing/index.mdx`][testing]). **Integration**: the `@workflow/vitest` plugin compiles the directives, builds both bundles and runs a fresh Local World in-process per worker; tests drive `start()`, `run.returnValue`, `resumeHook()` and force-complete waits. **Simulation**: `@workflow/world-sim` is a deterministic in-memory World in which "the World API is the schedule": every method has `before`/`after` interception points, time is virtual, and a scenario can hold the orchestrator inside the `events.create` that committed `step_started` while an external writer delivers a hook ([`packages/world-sim/README.md`][sim-readme]). It ships two checkers this catalog cares about: `checkInvariants`, which re-derives every entity from the log alone and compares it to the stored rows ([`invariants.ts`][sim-invariants]), and `verifyReplay`, which drops the terminal `run_*` event, loads the rest into an empty world, delivers one queue message and requires the real runtime to re-derive the removed event with the same output ([`replay.ts`][sim-replay]). The repo also carries an e2e harness that captures "the divergence signature" of an event-log race (the HEAD commit's subject).

---

## Strengths

- **Determinism is a sandbox property, not a lint rule.** `Math.random`, `Date`, `crypto` are seeded and replay-safe; timers, `fetch` and Node built-ins throw at runtime or fail the build.
- **Zero-API orchestration.** Workflows are plain `async` functions using `await`, `Promise.all`, `Promise.race`, `try/catch` and `using`; the compiler adds the durability.
- **A small, closed event vocabulary** (18 types) with a documented lifecycle per entity and a dense slot-numbered log that can detect its own holes.
- **Concurrency-tolerant log**: duplicate-class skipping, sealed `noop` slots and `ownerMessageId` make racing invocations of one run safe rather than forbidden.
- **`world-sim`** turns "what if the webhook lands between these two writes" from a flaky poll into a byte-reproducible scenario, and `verifyReplay` is a cold-start replay oracle.
- **Pluggable World** with a file-backed local implementation that needs no services.

## Weaknesses

- **Identity by PRNG draw order is fragile.** Any new draw (a `Math.random()`, `crypto.randomUUID()`, `createHook()` without a token, a serialized stream id) before an existing step shifts all later ids; the failure mode is a divergence, not a named-step mismatch, and the fix is a new run.
- **No in-body versioning.** There is no `patched()`/`getVersion()`; the only evolution story is cancel-and-rerun or self-restart with carried state, both of which lose the old run's continuity.
- **No compensation primitive.** Sagas are a cookbook pattern the user gets right or wrong; nothing registers, orders or triggers undo.
- **Deployment pinning depends on the platform.** `deploymentId: "latest"` is documented as Vercel-specific; other Worlds must invent their own affinity.
- **Replay cost is bounded by ceilings rather than snapshots.** 25,000 events per run, a replay timeout, and child-run splitting are the answers to long histories.
- **Beta churn.** The reviewed tree is `5.0.0-beta.50` with a very active log-format history (`specVersion` 1 through 7); the stable `4.8.8` has a different bundle layout.

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                                                 | Trade-off                                                                                                  |
| ----------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Directives compiled by an SWC plugin into two bundles             | Plain functions stay plain; the split is invisible in source and checked at build time                    | Requires a build integration per framework; no-compiler unit tests see a different program than production |
| Orchestrator runs in a seeded `node:vm` context                   | Determinism enforced, not requested; `Math.random`/`Date` usable in workflow code                         | Every host API must be shimmed or forbidden; a VM per invocation (mitigated by the retained-VM fast path)  |
| Step id = ULID from the seeded PRNG, matched by `correlationId`   | No user-supplied names; ids are globally unique and usable as external idempotency keys                   | Any change to the draw sequence before a step invalidates the log; divergence rather than a name mismatch  |
| Closed event enum with per-entity lifecycle and class-based dedup | Racing invocations produce inert duplicates instead of corrupt state                                      | Every new capability (attributes, hooks) needs new event types and reader rules gated by `specVersion`     |
| Dense slot-numbered event ids, sealed `noop` holes                | A reader can prove a log complete by length; abandoned positions cannot masquerade as unread events       | Backend must own a per-run sequencer; ULID-era runs and slot-era runs coexist via `specVersion`            |
| Runs pinned to their deployment; upgrade = new run                | In-flight runs never resume into changed code; type safety across deploys                                 | No incremental migration; long-lived runs need explicit restart points                                     |
| `FatalError` / `RetryableError` / default-retry classification    | Retry policy lives with the throw site; deterministic failures (serialization) skip retries automatically | Compensation is left to the user; a fatal in the middle of a saga is the user's `catch`                    |
| `world-sim` as a first-class package                              | Races become scripted scenarios; the log contract is checked by re-deriving entities and by cold replay   | Only exercises the World seam; nothing outside it (real network, real clock) is simulated                  |

---

## Relevance to sparkles

- **Argues against "name + attempt + args hash" as the sole key, from the other direction.** The DevKit keys on a deterministic draw _sequence_ and checks the name second. Its own weakness shows why the sparkles design's stable name is the better primary key: a new op inserted before an existing one should shift nothing. But its `stepName` cross-check on every event is worth copying: a journal entry whose recorded name disagrees with the consumer's is a divergence, and the check is cheap.
- **Confirms "journal wins" and the divergence-then-retry posture.** Replay divergence is first treated as a transient (a stale invocation followed the wrong branch of a race) and retried from the log before the run is declared corrupt. `release` should distinguish "this resume disagrees with the journal" from "the journal is unreadable" the same way, and the second should be a hard stop.
- **Confirms enforcing determinism at the seam rather than by discipline, and shows the D analogue is cheaper.** The DevKit needs a whole VM to make `Date.now` and `Math.random` replay-safe. In `event-horizon` the clock and randomness already flow through the capability row (`isClock`), so the journaling combinator can record and replay them as ordinary ops with no sandbox.
- **Its retained-VM fast path is the snapshot the design does not have.** Replaying `release` from the top for every op is fine for tens of ops; the DevKit's 25,000-event ceiling and replay timeout are the shape of the problem at scale. Not needed now, but the design should state its expected journal length.
- **Compensation: the DevKit has none, and its saga recipe reproduces the sparkles design almost line for line** (LIFO stack, push after each forward step, unwind only on fatal, compensations must be idempotent because a crash mid-rollback replays them). The design's registered-on-a-scope, explicit-only compensations are a strict improvement because the registration itself is journaled; the DevKit's recipe re-derives the stack from replay, which works only because the pushes are deterministic.
- **Versioning: the DevKit's answer is "never" and the design should decide whether it accepts that.** A `release` run that dies partway and is resumed by a _newer_ binary has no analogue here; the DevKit would refuse to run it on the new deployment. If sparkles wants resume-under-new-code, it must add what neither the DevKit nor the draw-order scheme has: a per-op version or a rule table for journal entries the new code no longer emits.
- **`world-sim` is the testing bar.** Its two oracles map directly onto the design's stated tests: `checkInvariants` (entity rows are a pure fold of the log) is the "journal is self-consistent" half, and `verifyReplay` (drop the terminal event, cold-start, require the runtime to re-derive it) is a stronger form of crash-at-every-index. The interception model, "the World API is the schedule", is what `SimNet`/`SimProc`/`TestClock` already are; the missing piece in sparkles is a scenario DSL that holds a capability call _after_ its journal write commits and _before_ the caller resumes.
- **Duplicate-class skipping is a concrete rule table for "when two writers disagree".** A second `started` for an entity is inert; a `failed` behind a `completed` is inert but logged as a real conflict. The design's reconciliation rule table for observations should adopt the same "first outcome in log order wins, later opposite outcome is flagged" rule for its own `started`/`completed` pairs.

---

## Sources

- [vercel/workflow — GitHub repository][repo]
- [Workflow DevKit documentation (workflow-sdk.dev)][docs]
- [`workflow` on npm (dist-tags `latest` 4.8.8, `beta` 5.0.0-beta.50)][npm]
- [`LICENSE.md` — Apache 2.0][license]
- [`packages/workflow/package.json` — the umbrella package at `5.0.0-beta.50`][workflow-pkg]
- [`packages/swc-plugin-workflow/spec.md` — directive specification, three modes, id format][swc-spec]
- [`packages/swc-plugin-workflow/transform/src/lib.rs` — the SWC transform][swc-lib]
- [`packages/core/src/vm/index.ts` — seeded `Math.random`, fixed `Date`, deterministic `crypto`, deleted host-timing intrinsics][vm]
- [`packages/core/src/workflow.ts` — VM bootstrap, `generateUlid`, `EventsConsumer` wiring, forbidden timers/`fetch`][workflow]
- [`packages/core/src/step.ts` — `useStep`: `correlationId` minting and the step consumer][step]
- [`packages/core/src/workflow/sleep.ts` — `wait_` ids, `resumeAt` divergence check, delivery barriers][sleep]
- [`packages/core/src/workflow/hook.ts` — `hook_` ids and token minting][hook]
- [`packages/core/src/workflow/define-hook.ts` — `defineHook`][define-hook]
- [`packages/core/src/events-consumer.ts` — the ordered walk, parkable types, duplicate classes][consumer]
- [`packages/core/src/runtime/step-executor.ts` — step execution, `FatalError`/`RetryableError` classification][executor]
- [`packages/core/src/runtime/count-step-started-events.ts` — authoritative attempt count][count-started]
- [`packages/core/src/runtime/deployment-guard.ts` — deployment affinity on delivery][guard]
- [`packages/core/src/runtime/start.ts` — client-generated `wrun_` ids][start]
- [`packages/core/src/runtime/wait-until.ts` — `@vercel/functions` `waitUntil` wrapper][wait-until]
- [`packages/world/src/events.ts` — the event schemas][events]
- [`packages/world/src/interfaces.ts` — `Storage`, `World`, `specVersion`][interfaces]
- [`packages/world/src/spec-version.ts` — log-format versions 1 through 7][specver]
- [`packages/world-local/src/fs.ts` — JSON-file storage with atomic writes][local-fs]
- [`packages/world-sim/README.md` — the deterministic simulation World][sim-readme]
- [`packages/world-sim/src/invariants.ts` — `checkInvariants`][sim-invariants]
- [`packages/world-sim/src/replay.ts` — `verifyReplay`][sim-replay]
- [`docs/content/docs/v5/how-it-works/code-transform.mdx`][ct] · [live page][ct-live]
- [`docs/content/docs/v5/how-it-works/event-sourcing.mdx`][es-src] · [live page][es]
- [`docs/content/docs/v5/foundations/workflows-and-steps.mdx`][ws]
- [`docs/content/docs/v5/foundations/errors-and-retries.mdx`][errors]
- [`docs/content/docs/v5/foundations/versioning.mdx`][versioning-src] · [live page][versioning]
- [`docs/content/docs/v5/foundations/idempotency.mdx`][idempotency]
- [`docs/content/docs/v5/foundations/hooks.mdx`][hooks]
- [`docs/content/docs/v5/cookbook/common-patterns/saga.mdx`][saga]
- [`docs/content/docs/v5/cookbook/common-patterns/sequential-and-parallel.mdx`][seqpar]
- [`docs/content/docs/v5/cookbook/advanced/upgrading-workflows.mdx`][upgrading]
- [`docs/content/docs/v5/testing/index.mdx`][testing]
- [`docs/content/docs/v5/errors/replay-divergence.mdx`][divergence]
- [`docs/content/docs/v5/errors/step-executed-multiple-times.mdx`][multi-start]
- [`docs/content/docs/v5/whats-new.mdx`][whats-new]
- [`docs/content/worlds/v5/local.mdx`][local-src]
- Related: [Temporal][temporal] · [DBOS][dbos] · [Effect Workflow][effect-workflow] · [Azure Durable Functions][adf] · [Deterministic simulation testing][dst] · [Sagas][sagas] · [Catalog index][index] · [Effect (TypeScript)][effect-ts] · [`event-horizon` spec][eh-spec]

<!-- References -->

[repo]: https://github.com/vercel/workflow
[docs]: https://workflow-sdk.dev/
[npm]: https://registry.npmjs.org/workflow
[license]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/LICENSE.md
[workflow-pkg]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/packages/workflow/package.json
[docs-src]: https://github.com/vercel/workflow/tree/17bd649839b9131db29f17e1d3f1c06c6d1ca799/docs/content
[swc-spec]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/packages/swc-plugin-workflow/spec.md
[swc-lib]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/packages/swc-plugin-workflow/transform/src/lib.rs
[vm]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/packages/core/src/vm/index.ts
[workflow]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/packages/core/src/workflow.ts
[step]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/packages/core/src/step.ts
[sleep]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/packages/core/src/workflow/sleep.ts
[hook]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/packages/core/src/workflow/hook.ts
[define-hook]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/packages/core/src/workflow/define-hook.ts
[consumer]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/packages/core/src/events-consumer.ts
[executor]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/packages/core/src/runtime/step-executor.ts
[count-started]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/packages/core/src/runtime/count-step-started-events.ts
[guard]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/packages/core/src/runtime/deployment-guard.ts
[start]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/packages/core/src/runtime/start.ts
[wait-until]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/packages/core/src/runtime/wait-until.ts
[events]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/packages/world/src/events.ts
[interfaces]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/packages/world/src/interfaces.ts
[specver]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/packages/world/src/spec-version.ts
[local-fs]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/packages/world-local/src/fs.ts
[sim-readme]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/packages/world-sim/README.md
[sim-invariants]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/packages/world-sim/src/invariants.ts
[sim-replay]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/packages/world-sim/src/replay.ts
[ct]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/docs/content/docs/v5/how-it-works/code-transform.mdx
[ct-live]: https://workflow-sdk.dev/docs/how-it-works/code-transform
[es-src]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/docs/content/docs/v5/how-it-works/event-sourcing.mdx
[es]: https://workflow-sdk.dev/docs/how-it-works/event-sourcing
[ws]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/docs/content/docs/v5/foundations/workflows-and-steps.mdx
[errors]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/docs/content/docs/v5/foundations/errors-and-retries.mdx
[versioning-src]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/docs/content/docs/v5/foundations/versioning.mdx
[versioning]: https://workflow-sdk.dev/docs/foundations/versioning
[idempotency]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/docs/content/docs/v5/foundations/idempotency.mdx
[hooks]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/docs/content/docs/v5/foundations/hooks.mdx
[saga]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/docs/content/docs/v5/cookbook/common-patterns/saga.mdx
[seqpar]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/docs/content/docs/v5/cookbook/common-patterns/sequential-and-parallel.mdx
[upgrading]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/docs/content/docs/v5/cookbook/advanced/upgrading-workflows.mdx
[testing]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/docs/content/docs/v5/testing/index.mdx
[divergence]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/docs/content/docs/v5/errors/replay-divergence.mdx
[multi-start]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/docs/content/docs/v5/errors/step-executed-multiple-times.mdx
[whats-new]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/docs/content/docs/v5/whats-new.mdx
[local-src]: https://github.com/vercel/workflow/blob/17bd649839b9131db29f17e1d3f1c06c6d1ca799/docs/content/worlds/v5/local.mdx
[temporal]: ./temporal.md
[dbos]: ./dbos.md
[effect-workflow]: ./effect-workflow.md
[adf]: ./azure-durable-functions.md
[dst]: ./deterministic-simulation-testing.md
[sagas]: ./sagas.md
[index]: ./index.md
[effect-ts]: ../typescript-effect.md
[eh-spec]: ../../../specs/event-horizon/SPEC.md
