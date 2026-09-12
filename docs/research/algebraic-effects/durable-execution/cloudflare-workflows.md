# Cloudflare Workflows (TypeScript)

A hosted durable-execution engine on Cloudflare Workers: a workflow is a class whose `run` method calls `step.do(name, fn)`, and every step's return value is memoized by name (plus an occurrence counter) in a per-instance SQLite-backed Durable Object, so that re-running `run` after a crash, a sleep or a hibernation short-circuits every step that already completed.

| Field             | Value                                                                                                                                                                                                                                                                                                                                    |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | TypeScript / JavaScript on `workerd` (a Python binding is in open beta)                                                                                                                                                                                                                                                                  |
| License           | Hosted service (proprietary engine). The local emulation, CLI and test tooling in `workers-sdk` are MIT OR Apache-2.0 ([`LICENSE-MIT`][license-mit], [`LICENSE-APACHE`][license-apache]; [`packages/workflows-shared/package.json`][ws-pkg])                                                                                             |
| Repository        | [cloudflare/workers-sdk][repo] — the local engine is `packages/workflows-shared` ("used at Cloudflare to power some internal features of Cloudflare Workflows", [`package.json`][ws-pkg]); docs source: [cloudflare/cloudflare-docs][docs-repo]                                                                                          |
| Documentation     | [developers.cloudflare.com/workflows][docs]                                                                                                                                                                                                                                                                                              |
| Category          | durable-execution engine                                                                                                                                                                                                                                                                                                                 |
| Persistence model | replay (re-execute `run`; a `step.do` whose key is cached returns the stored value or re-throws the stored error without running its callback)                                                                                                                                                                                           |
| Journal store     | One SQLite-backed Durable Object per instance. In the public local engine: DO key-value entries `<sha1(name)>-<count>-value` / `-error` / `-config` / `-metadata`, plus SQL tables `states` (the event log), `priority_queue` (sleep/retry/timeout wakeups) and `streaming_step_chunks` ([`engine.ts`][engine], [`context.ts`][context]) |
| Latest release    | Generally available since April 7, 2025 ([changelog][ga]); at the clone's HEAD the local engine ships as `@cloudflare/workflows-shared` `0.13.0` (private) inside `wrangler` `4.131.1` ([`wrangler/package.json`][wrangler-pkg]) and the test API in `@cloudflare/vitest-plugin` `1.1.8`                                                 |
| Local clone       | `$REPOS/workers-sdk` at `00ae21fa83754462721a52bcd1ff9b4fbc12f898`; `$REPOS/cloudflare-docs` at `96d90994571f3db1d4e6fd91820e700d52476e2b`                                                                                                                                                                                               |

**Last reviewed:** September 12, 2026.

---

## Overview

### What it solves

Cloudflare Workflows exists so that a Worker, which is a short-lived request handler with a CPU budget, can run "for minutes, hours, or even weeks" ([`index.mdx`][index-doc]). The docs name the model outright in the getting-started guide ([`guide.mdx`][guide]):

> The term "Durable Execution" is widely used to describe this programming model.
>
> "Durable" describes the ability of the program to implicitly persist state without you having to manually write to an external store or serialize program state.

The unit of durability is the _step_, not the function: `run` is ordinary async TypeScript with `if`, loops, `try...catch` and `Promise.all`, and only the values returned from `step.do` survive. The engine is not exposed as a library; it is a managed service reached through a `Workflow` binding (`env.MY_WORKFLOW.create(...)`), with a faithful-enough local emulation in `wrangler dev` that the docs describe as "an emulated version of Workflows compared to the one that Cloudflare runs globally" ([`local-development.mdx`][local-dev]). This page reads the docs for the production contract and the emulation's source for the mechanics; the production engine itself is not public.

### Design philosophy

The launch post states the replay contract in one sentence ([blog][blog]):

> Durability means that if and when a workflow fails, the Engine can re-run it, resume from the last recorded step, and deterministically re-calculate the state from all the successful steps' cached responses.

and where the state lives:

> every workflow instance is an Engine behind the scenes, and every Engine is an SQLite-backed Durable Object.

The "Rules of Workflows" page turns the contract into user obligations. The central one is that the step _name_ is the identity ([`rules-of-workflows.mdx`][rules]):

> Steps should be named deterministically (that is, not using the current date/time, randomness, etc). This ensures that their state is cached, and prevents the step from being rerun unnecessarily. Step names act as the "cache key" in your Workflow.

and the second is that nothing outside a step is trusted to persist:

> Workflows may hibernate and lose all in-memory state. This will happen when engine detects that there is no pending work and can hibernate until it needs to wake-up (because of a sleep, retry, or event).

Three consequences shape the API: (1) there is no continuation capture and no sandbox; `run` is re-invoked from the top on every engine lifetime, (2) idempotency of the step body is the user's problem ("Because a step might be retried multiple times, your steps should (ideally) be idempotent"), and (3) control flow is free as long as it depends only on `event.payload` and earlier step results ([`rules-of-workflows.mdx`][rules]). Compare [DBOS][dbos], which makes the same replay bet against Postgres rows but keys steps by position, and [Azure Durable Functions][adf], which replays against an event history.

---

## How it works

### User-facing API

From the `create-cloudflare` starter template ([`hello-world-workflows/ts/src/index.ts`][template]) and the Workers API reference ([`workers-api.mdx`][api]):

```ts
import {
  WorkflowEntrypoint,
  WorkflowEvent,
  WorkflowStep,
} from 'cloudflare:workers';
import { NonRetryableError } from 'cloudflare:workflows';

export class MyWorkflow extends WorkflowEntrypoint<Env, Params> {
  async run(event: WorkflowEvent<Params>, step: WorkflowStep) {
    const files = await step.do('my first step', async () => {
      return { files: ['a.pdf', 'b.pdf'] }; // memoized under this name
    });

    const approval = await step.waitForEvent('request-approval', {
      type: 'approval',
      timeout: '1 minute',
    });

    await step.sleep('wait on something', '1 minute'); // durable timer, not a step

    await step.do(
      'make a call to write that could maybe, just might, fail',
      {
        retries: { limit: 5, delay: '5 second', backoff: 'exponential' },
        timeout: '15 minutes',
      },
      async ctx => {
        // ctx.step.{name,count}, ctx.attempt, ctx.config
        if (ctx.attempt > 3) throw new NonRetryableError('give up');
      },
      {
        rollback: async ({ output, error }) => {
          /* compensate */
        },
      },
    );
  }
}
```

The four step primitives ([`workers-api.mdx`][api]):

| Call                                           | Identity                             | Persists                                                                             |
| ---------------------------------------------- | ------------------------------------ | ------------------------------------------------------------------------------------ |
| `step.do(name, config?, fn, rollbackOptions?)` | `name` + per-name call count         | the return value (≤ 1 MiB structured-cloneable, or a byte stream) or the final error |
| `step.sleep(name, duration)`                   | `name` + duration + call count       | that the sleep happened, and its absolute wake time                                  |
| `step.sleepUntil(name, timestamp)`             | delegates to `sleep` with `ts - now` | as above                                                                             |
| `step.waitForEvent(name, { type, timeout? })`  | `name` + call count                  | the received event, or the timeout error                                             |

`step.sleep` and `step.sleepUntil` "do not count towards the maximum Workflow steps limit" ([`workers-api.mdx`][api]). `WorkflowStepConfig` is `{ retries?: { limit, delay, backoff? }, timeout? }`, where `delay` may be a duration or a `WorkflowDelayFunction` receiving `{ ctx, error }` ([`sleeping-and-retrying.mdx`][retrying]). The documented defaults are `limit: 5`, `delay: 10000`, `backoff: "exponential"`, `timeout: "10 minutes"`; the local engine's `defaultConfig` uses `delay: 1000` ([`context.ts`][context], [`delay.ts`][delay]).

The instance handle (`env.MY_WORKFLOW.get(id)`) exposes `status()`, `pause()`, `resume()`, `terminate({ rollback? })`, `restart({ from? })` and `sendEvent({ type, payload })` ([`workers-api.mdx`][api]).

### The local engine: one Durable Object per instance

Miniflare instantiates one Durable Object namespace per workflow binding, with `enableSql: true` and `preventEviction: true`, and hands the user's class to it as the `USER_WORKFLOW` service ([`miniflare/src/plugins/workflows/index.ts`][mf-plugin]). `WorkflowBinding.create` maps the instance id to the DO id with `idFromName(id)` and fires `stub.init(...)` under `waitUntil` ([`binding.ts`][binding]). The `Engine` DO creates its tables in the constructor ([`engine.ts`][engine]):

```sql
CREATE TABLE IF NOT EXISTS priority_queue (
    id INTEGER PRIMARY KEY NOT NULL,
    created_on TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    target_timestamp INTEGER NOT NULL,
    action INTEGER NOT NULL, -- should only be 0 or 1 (1 for added, 0 for deleted),
    entryType INTEGER NOT NULL,
    hash TEXT NOT NULL,
    CHECK (action IN (0, 1)),
    UNIQUE (action, entryType, hash)
);
CREATE TABLE IF NOT EXISTS states (
    id INTEGER PRIMARY KEY NOT NULL,
    timestamp TIMESTAMP DEFAULT (DATETIME('now','subsec')),
    groupKey TEXT,
    target TEXT,
    metadata TEXT,
    event INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS streaming_step_chunks (
    cache_key TEXT NOT NULL, attempt INTEGER NOT NULL, chunk_index INTEGER NOT NULL,
    chunk BLOB NOT NULL, PRIMARY KEY (cache_key, attempt, chunk_index)
) WITHOUT ROWID
```

`states` is the observable event log; its `event` column is the `InstanceEvent` enum ([`instance.ts`][instance]):

```ts
export const enum InstanceEvent {
  WORKFLOW_QUEUED = 0,
  WORKFLOW_START = 1,
  WORKFLOW_SUCCESS = 2,
  WORKFLOW_FAILURE = 3,
  WORKFLOW_TERMINATED = 4,
  STEP_START = 5,
  STEP_SUCCESS = 6,
  STEP_FAILURE = 7,
  SLEEP_START = 8,
  SLEEP_COMPLETE = 9,
  ATTEMPT_START = 10,
  ATTEMPT_SUCCESS = 11,
  ATTEMPT_FAILURE = 12,
  __INTERNAL_PROD = 13,
  WAIT_START = 14,
  WAIT_COMPLETE = 15,
  WAIT_TIMED_OUT = 16,
  ROLLBACK_START = 17,
  ROLLBACK_STEP_START = 18,
  ROLLBACK_ATTEMPT_START = 19,
  ROLLBACK_ATTEMPT_SUCCESS = 20,
  ROLLBACK_ATTEMPT_FAILURE = 21,
  ROLLBACK_STEP_SUCCESS = 22,
  ROLLBACK_STEP_FAILURE = 23,
  ROLLBACK_COMPLETE = 24,
  ROLLBACK_FAILED = 25,
}
```

The log is _not_ what replay reads. Replay reads the DO's key-value storage, where each step's outcome sits under keys derived from its cache key. `Engine.init` writes `WORKFLOW_QUEUED`/`WORKFLOW_START` on first run, restores the buffered-event map, constructs a fresh `Context` (the `WorkflowStep` implementation) and calls `this.env.USER_WORKFLOW.run(event, stubStep)` — the same call on every lifetime ([`engine.ts`][engine]).

### The memoization in `Context.do`

The whole replay mechanism is a dozen lines of [`context.ts`][context]. The key is a SHA-1 of the name ([`cache.ts`][cache]) joined to a 1-indexed per-name counter that lives only in memory for this lifetime:

```ts
#getCount(name: string): number {
	let val = this.#counters.get(name) ?? 0;
	// 1-indexed, as we're increasing the value before write
	val++;
	this.#counters.set(name, val);
	return val;
}
// ...in do():
const hash = await computeHash(name);
count = this.#getCount("run-" + name);
cacheKey = `${hash}-${count}`;
stepNameWithCounter = `${name}-${count}`;

const valueKey = `${cacheKey}-value`;
const configKey = `${cacheKey}-config`;
const errorKey = `${cacheKey}-error`;
const stepStateKey = `${cacheKey}-metadata`;
```

Then the lookup, in order: a completed stream output, a plain value, a stored error ([`context.ts`][context]):

```ts
const maybeResult = maybeMap.get(valueKey);
if (maybeResult) {
	const result = (maybeResult as { value: T }).value;
	this.#registerRollback({ cacheKey, rollbackFn, stepContext: { step: { name, count }, ... }, output: result, rollbackConfig });
	return result;                       // callback never runs
}
const maybeError = maybeMap.get(errorKey) as Error | undefined;
if (maybeError) {
	maybeError.isUserError = true;
	throw maybeError;                    // a step that exhausted its retries fails the same way again
}
// Persist initial config because user can pass in dynamic config
if (cachedConfig === undefined) {
	await this.#state.storage.put(configKey, config);
} else {
	config = cachedConfig;               // the stored config wins over the code's
}
```

A successful attempt stores `{ value }` (wrapped so `undefined` is storable), writes `ATTEMPT_SUCCESS` then `STEP_SUCCESS` with the result in the log's `metadata`, and returns. A failed attempt writes `ATTEMPT_FAILURE`, bumps `attemptedCount` in `-metadata`, computes the delay (`base * 2^(attempt-1)` for exponential, `base * attempt` for linear, [`retries.ts`][retries]), parks a `retry` entry in `priority_queue` so a crash mid-wait still reschedules, waits, and recurses. When `attemptedCount > retries.limit` it writes `STEP_FAILURE`, stores the error under `-error`, and throws ([`context.ts`][context]). A `NonRetryableError` (matched by `error.name === "NonRetryableError"` because the class crosses an RPC boundary) skips the retry loop entirely and, uncaught in `run`, ends the instance as `Errored` ([`context.ts`][context], [`engine.ts`][engine]).

### Sleeps and timers survive the process

`sleep` stores a `true` under its own cache key immediately, adds a `sleep` entry with an absolute `targetTimestamp` to `priority_queue`, then `scheduler.wait`s ([`context.ts`][context]). The `TimePriorityQueue` is a heap mirrored into that SQL table; on every `init`, `popPastEntries()` drains what is already due and `handleNextAlarm()` arms a DO alarm for the earliest future entry ([`timePriorityQueue.ts`][pq], [`engine.ts`][engine]). So a sleep is a journaled _deadline_: if the engine restarts, replay reaches the `sleep` call, finds the cached marker, finds the still-pending queue entry, and waits only for the remainder. Attempt timeouts are journaled the same way as `timeout` entries.

`waitForEvent` stores a `-pending` marker and a `WAIT_START` log, then races an in-memory resolver against the timeout and the pause signal; events that arrive when no waiter is registered are buffered in `eventMap` and persisted under `EVENT_MAP\n<type>\n<i>` keys so that "You can send an event to a Workflow instance _before_ it reaches the corresponding `waitForEvent` call" ([`events-and-parameters.mdx`][events], [`engine.ts`][engine]).

---

## Analysis

### 1. Step identity and replay matching

Identity is **name plus occurrence count**, never position in the history. The docs expose the count as `ctx.step.count`, "How many times `step.do` has been called with this name so far in the current Workflow run. Starts at `1` for the first call with a given name" ([`step-context.mdx`][step-ctx]), and the emulation's key is exactly `sha1(name)-count` ([`context.ts`][context]). A duplicate name is therefore **not an error**; the counter disambiguates, and a test pins it: two consecutive `step.do("repeated step", …)` calls receive `count: 1` and `count: 2` while a third, differently named step gets `count: 1` ([`tests/context.test.ts`][context-test]). Names are validated only for length (256) and control characters ([`validators.ts`][validators]).

Matching is a pure key lookup: there is no comparison of the step's kind, config or arguments against what was recorded. The three primitives use disjoint counter namespaces (`run-`, `sleep-`, `waitForEvent-` prefixes), and `sleep`'s key additionally hashes the duration, so changing a sleep's length after it was journaled produces a fresh key and a fresh sleep ([`context.ts`][context]). `restart({ from: { name, count, type } })` addresses the same identity from the outside; the restart code finds the n-th `STEP_START`/`SLEEP_START`/`WAIT_START` whose `target` matches `name` and wipes that group key and every later one, then re-runs `run` so the earlier keys hit and the later ones miss ([`restart.ts`][restart], [`workers-api.mdx`][api]).

### 2. Journal versus world

The journal wins, unconditionally and silently. A cached value is returned without executing the callback, so the world is never re-observed; the docs' worked example makes this the _point_: a `Promise.race` whose losing branch completes later "will return `first`, even though the `Promise.race` first returned `second`" on a later passage, because the cache, not the world, is truth ([`rules-of-workflows.mdx`][rules]). Disagreement is not detected by the engine. It is delegated to the step body, which is told to check before acting: "Non-idempotent API/Binding calls are always done **after** checking if the operation is still needed" ([`rules-of-workflows.mdx`][rules]). The only world-facing detection the engine performs is on _itself_: on replay it looks for a dangling `ATTEMPT_START` with no matching success/failure and records an `ATTEMPT_FAILURE` "due to internal workflows error" before retrying ([`context.ts`][context]). (In the public engine `readLogsFromStep` returns `[]`, so that branch is inert locally.) The operator's tool for "the world moved" is `restart({ from })`, i.e. truncate the journal and re-run.

### 3. Determinism enforcement

By discipline, backed by a documented rulebook and a handful of hard runtime checks. The docs list what must not happen: non-deterministic names, side effects outside `step.do` ("logic outside of the steps may be duplicated"), conditions on `Math.random()` or `Date.now()` outside a step, mutating `event.payload`, un-awaited steps ([`rules-of-workflows.mdx`][rules]). None of these are detected; the runtime does not sandbox `Date`, `Math.random` or `fetch`, and the recommended fix is the same one every replay system gives: "wrap non-deterministic function in a step". What the runtime _does_ enforce, fatally: the return value must be structured-cloneable (`DataCloneError` ends the instance as `Errored` "as the step … returned a value which is not serialisable"), non-stream outputs must fit in 1 MiB (`SQLITE_TOOBIG` surfaces as a `WorkflowInternalError`), the step count must stay under the configured limit (10,000 by default, 25,000 maximum on paid plans, 1,024 on free), and the step name and config must validate ([`context.ts`][context], [`limits.mdx`][limits]). One subtle enforcement is the persisted `-config` key: on replay the _stored_ retry config overrides whatever the code now passes, so a config change cannot alter an in-flight step's retry budget ([`context.ts`][context]).

### 4. Compensation and failure handling

Explicit, saga-style, and recent. A fourth argument to `step.do` registers `{ rollback, rollbackConfig? }`; on an uncaught error in `run` the engine runs "registered rollback handlers in reverse `step-start` order" with `{ ctx, error, output }`, where `output` is `undefined` if the forward step itself failed ([`sleeping-and-retrying.mdx`][retrying], [`workers-api.mdx`][api]). The emulation's `executeRollbacks` is "LIFO; halts on first failure. Goes through Context.do so each rollback inherits retries/timeouts/attempt-logging" ([`rollback.ts`][rollback]); eligibility is computed from the `states` log (every `STEP_START` whose metadata carries `hasRollback: true` and that has no `ROLLBACK_STEP_SUCCESS`/`FAILURE` yet), walked in descending `id` ([`engine.ts`][engine]). A test pins the ordering for parallel steps as reverse _start_ order, not reverse completion order ([`tests/engine.test.ts`][engine-test]).

The interesting mechanism is what happens when the rollback closures are gone. They are RPC stubs, "dead across DO restarts", so `terminate({ rollback: true })` on a hibernated instance first **re-runs `run` in a "replay" phase** with a stub `Context` whose `do` returns cached values (or `undefined` past the cache), whose `sleep` returns immediately and whose only job is to re-collect the handlers, then switches to the "rollback" phase and executes them; a replay that throws is tolerated because "replay may stop on normal workflow control flow" ([`engine.ts`][engine]). Rollback progress is itself journaled (`ROLLBACK_*` events, `rollback:` cache-key prefix) and reported in `status().rollback` as `{ outcome: "complete" | "failed" }` ([`workers-api.mdx`][api]). Ordinary failures are handled with `try...catch` around a step; retries are per step, with `NonRetryableError` as the escape hatch, and fatal serialization errors abort the DO before rollbacks can run ([`context.ts`][context], [`retrying.mdx`][retrying]).

### 5. Versioning against old histories

**Undocumented.** Neither the Workflows docs tree nor the launch post says what happens to a running instance when a new version of the Worker is deployed; the only vocabulary is the `versionId` recorded in `WORKFLOW_QUEUED` and the `DatabaseVersion` row in instance metadata, which the local binding fills with `{}` ([`engine.ts`][engine], [`binding.ts`][binding]). The emulation carries a `TODO (WOR-85): Remove this once upgrade story is done` next to the check that refuses to resume an `Errored` instance ([`engine.ts`][engine]). What the identity scheme implies, absent a statement: because keys are names rather than positions, inserting, deleting or reordering steps does not shift the cache of the others, and the replay of an old history against new code silently reuses every name that still exists. The failure mode is a renamed step (re-executed) or a reused name with different semantics (replayed with the wrong value), and nothing detects either. The documented remedy for an instance that ended up wrong is `restart({ from })` ([`workers-api.mdx`][api]).

### 6. Concurrency under replay

Supported and deliberately simple. `Promise.all` over several `step.do` calls is the recommended way to build parallel state ([`rules-of-workflows.mdx`][rules]); the dashboard's visualizer models it as a `ParallelNode` ([`visualizer.mdx`][visualizer]). Because identity is name-based, parallel steps with distinct names have no ordering problem at all. Same-named steps inside a `Promise.all` are numbered by the order in which `step.do` is _called_ (the counter is bumped synchronously before the first `await` in `do`), which is deterministic for deterministic code. The documented hazard is `Promise.race`/`Promise.any`: a losing branch keeps running and gets cached, so on the next lifetime the "winner" may differ; the fix is to nest the race inside an outer `step.do` so only its result is cached ([`rules-of-workflows.mdx`][rules]). Pause interacts with concurrency by waiting for every in-flight step to finish (`waitUntilNothingIsRunning`) before flipping to `Paused`; tests cover "multiple concurrent in-flight step.dos" ([`engine.ts`][engine], [`tests/engine.test.ts`][engine-test]).

### 7. Replay or snapshot

Replay, with two consequences the docs are candid about. First, the price of re-execution is paid in CPU: "Do not do too much CPU-intensive work inside a single step - sometimes the engine may have to restart, and it will start over from the beginning of that step", and compute is metered per step (10 ms on free, 30 s default on paid) ([`rules-of-workflows.mdx`][rules], [`limits.mdx`][limits]). Second, replay makes hibernation free: an instance in `waiting` (sleeping, retrying, or waiting for an event) holds no concurrency slot, so "you can have millions of Workflow instances sleeping or waiting for events simultaneously" ([`limits.mdx`][limits]). There is no snapshot of the JavaScript heap; the persisted state is the step outputs (1 MiB each, 1 GB per instance on paid) and the `states` log. The storage design is what makes replay cheap: a step's replay cost is one DO storage `get` of five keys, and the step count cap (25,000) bounds the replay walk.

### 8. Testing

Two layers, both in the public repo. The user-facing layer is the `cloudflare:test` introspection API in `@cloudflare/vitest-plugin`: `introspectWorkflowInstance(binding, id)` / `introspectWorkflow(binding)` return handles whose `modify` callback receives a `WorkflowInstanceModifier` with `disableSleeps`, `disableRetryDelays`, `mockStepResult`, `mockStepError(step, error, times?)`, `forceStepTimeout`, `mockEvent`, `forceEventTimeout`, and whose `waitForStepResult({ name, index? })`, `waitForStatus`, `getOutput`, `getError` observe the run ([`test-apis.mdx`][test-apis], [`vitest-plugin/src/worker/workflows.ts`][vitest-wf], [`types.ts`][types]). The modifiers are implemented as storage keys the engine consults at each decision point (`MODIFIER_KEYS.*`), which is why they must be installed before `create` ([`context.ts`][context]). The engine's own suite drives `Engine` through Miniflare and asserts on the `states` log: retry counts and delays, `NonRetryableError`, dynamic delay functions, event buffering across lifetimes, step limits, pause during a step/sleep/wait, restart-from-step preserving earlier results, LIFO rollback, and stream replay from cache ([`tests/engine.test.ts`][engine-test], [`tests/context.test.ts`][context-test]).

What is absent: a crash-injection primitive. There is no "kill the engine after event N and resume" operation; the closest things are `restart({ from })` (which _erases_ rather than resumes) and the `unsafeAbort` used to tear down between tests. Durability across lifetimes is exercised indirectly (a `waitForEvent` test sends the event while the engine is not active; a stream test restarts and checks the chunk table) rather than swept.

### 9. Journal integrity and the single writer

The single writer is the actor, not a lock. Every instance is one Durable Object addressed by `idFromName(instanceId)` ([`binding.ts`][binding]), and "Durable Objects are single-threaded and cooperatively multi-tasked, just like code running in a web browser", each with "durable, transactional, and strongly consistent storage … accessible only within that object" ([`what-are-durable-objects.mdx`][do-concepts]). Two executions of the same instance therefore cannot exist: the platform routes every request for that id to the one live object. Inside the object, `init` returns early if `isRunning` is already set, so a `receiveEvent` or alarm arriving while `run` is in flight does not start a second `run` ([`engine.ts`][engine]). There is no lease, e-tag or expected-version guard on appends, because the design makes them unnecessary; the emulation's only durable constraint is `UNIQUE (action, entryType, hash)` on `priority_queue`, which is why a dynamic-delay retry entry cannot be re-added with a corrected timestamp ([`engine.ts`][engine], [`context.ts`][context]).

The write discipline is intent-then-result, at attempt granularity. `ATTEMPT_START` is inserted into `states` and `attemptedCount` is bumped in `-metadata` _before_ the user callback runs; the value is put under `-value` only after it returns; `ATTEMPT_SUCCESS`/`STEP_SUCCESS` follow ([`context.ts`][context]). A crash between intent and result is what the dangling-`ATTEMPT_START` scan on replay is for ([§2](#2-journal-versus-world)). The log insert and the value put are separate operations (SQL `INSERT` versus KV `put`), so an intent and its result are not one atomic append; the two places the engine wraps writes in `storage.transaction` are the status transitions around `WORKFLOW_SUCCESS`/`FAILURE`, "to guarentee ordering with running setstatus call" ([`engine.ts`][engine]). Torn records are the storage engine's problem: SQLite-backed DO storage is transactional, and `abort` calls `storage.sync()` before tearing the object down ([`engine.ts`][engine]). Nothing in the record identifies which lifetime wrote it; there is no incarnation id or generation counter, and none is checked on read, which is consistent with the platform guaranteeing there is only ever one.

Duplicate appends are idempotent on the cache key: a second `put` under `<hash>-<count>-value` overwrites the first, and the replay path never reaches the put once the key exists. At the API edge, `create({ id })` "Throws an error if the provided ID is already used by an existing instance that has not yet passed its retention limit", while `createBatch` "is idempotent and will not fail if an ID is already in use" ([`workers-api.mdx`][api]).

### 10. Operator recovery and intervention

The operator surface is the instance handle, mirrored by the CLI and the REST API: `pause`, `resume`, `terminate`, `restart` and `sendEvent` on `WorkflowInstance` ([`workers-api.mdx`][api]); `wrangler workflows instances {list, describe, pause, resume, restart, terminate, terminate-all, send-event, delete}` ([`wrangler/src/workflows/commands/instances/`][wrangler-instances]), each accepting `--local` against a `wrangler dev` session since April 1, 2026 ([`release-notes/workflows.yaml`][release-notes]); and, locally, the browser-based Local Explorer where one can "Inspect the step history and current status of each instance" and "Pause, resume, terminate, and restart instances" ([`local-development.mdx`][local-dev]).

Resume-from-a-chosen-point is `restart({ from: { name, count?, type? } })`: "the cached results of every earlier step are reused, while the target step and any steps that follow it run again", and it "throws an error if no step matching `from` is found in the instance's execution history" ([`workers-api.mdx`][api]). The emulation implements it by scanning `states` for the n-th matching `STEP_START`/`SLEEP_START`/`WAIT_START`, collecting that group key and every later one, then deleting those groups' KV entries, their `states` rows, their stream chunks, and the whole `priority_queue` ([`restart.ts`][restart]). A plain `restart()` wipes everything and re-logs `WORKFLOW_QUEUED`/`WORKFLOW_START`; the docs' phrasing is "erase any intermediate state, and treat the Workflow as if it was run for the first time" ([`trigger-workflows.mdx`][trigger]). Intervention therefore does _not_ leave a trace in the journal: the erased rows are gone, and the surviving log reads as a first run. A `terminate` does leave `WORKFLOW_TERMINATED` with `trigger: { source: API }` ([`engine.ts`][engine]).

Editing a recorded result by hand is not a production operation. `mockStepResult` and `mockStepError` exist only behind the `cloudflare:test` introspector ([§8](#8-testing)). Cancellation is distinct from failure in the status vocabulary (`terminated` versus `errored`, both terminal, both refused by `terminate` afterwards, [`workers-api.mdx`][api]), and in-flight work is handled differently by the two: `pause` waits for every running step to finish (`waitUntilNothingIsRunning`) and interrupts sleeps and waits through `pauseController`, while `terminate` aborts the object outright after optionally running rollbacks ([`engine.ts`][engine]). There is no dead-letter or quarantine state; an instance that cannot proceed is `errored`, retained for 3 or 30 days, and the only exits are `restart` or `delete` ([`limits.mdx`][limits]).

### 11. Suspension and external input

Three waiting primitives, all journaled: `step.sleep`/`step.sleepUntil` (a durable timer, up to 365 days), `step.waitForEvent(name, { type, timeout? })` (an external event, default timeout 24 hours, 1 second to 365 days), and, indirectly, a child workflow started from a step, which the parent "will not block waiting for" ([`workers-api.mdx`][api], [`events-and-parameters.mdx`][events], [`trigger-workflows.mdx`][trigger]). Human-in-the-loop approval is the documented use of `waitForEvent`, with a worked example that waits on `type: 'approval-for-ai-tagging'` and branches on `payload.approved` ([`wait-for-event.mdx`][wait-example]).

Suspension is a first-class persisted state: `waiting` ("instance is hibernating and waiting for sleep or event to finish") sits beside `running`, `paused`, `queued` and the terminal states in `InstanceStatus`, is returned by `status()`, and is what frees the concurrency slot ([`workers-api.mdx`][api], [`limits.mdx`][limits]). The process does end: the engine "may hibernate and lose all in-memory state" when "there is no pending work" ([`rules-of-workflows.mdx`][rules]), and the wake is a DO alarm armed from the persisted `priority_queue`, after which `run` is replayed to the waiting call ([`timePriorityQueue.ts`][pq], [`engine.ts`][engine]). The docs note a threshold in the other direction: the transition to `waiting` "may not occur if the wait duration is very short" ([`limits.mdx`][limits]).

External input is addressed by `type`, not by the step's name and not by a handed-out token; the engine keeps a FIFO per type (`eventMap`) and a waiter list per type, and the source carries a `TODO: This might need to be the name, not the event type` ([`context.ts`][context], [`engine.ts`][engine]). An event that arrives early is buffered and persisted under `EVENT_MAP\n<type>\n<i>` so it survives hibernation, and "will be buffered and delivered when the Workflow reaches the `waitForEvent` step with the matching `type`" ([`events-and-parameters.mdx`][events]). An event that arrives twice is two queue entries, consumed by two successive waits of that type. An event that never arrives ends in `WAIT_TIMED_OUT`, with the timeout error stored under the wait's `-error` key so replay re-throws it rather than waiting again; the timeout deadline itself is a `timeout` entry in `priority_queue`, and a test pins that an event sent after a wait timed out is not delivered to that stale waiter but to the next one ([`context.ts`][context], [`tests/engine.test.ts`][engine-test]). `sendEvent` "throws an exception if the Workflow is not running or is an errored state" ([`workers-api.mdx`][api]).

---

## Strengths

- **Name-keyed identity makes the common edits safe.** Inserting, removing or reordering steps does not invalidate other steps' cache, and parallel steps need no deterministic completion order ([`context.ts`][context]).
- **Both outcomes are memoized.** A step that exhausted its retries re-throws the stored error on replay instead of retrying again, so the workflow's `try...catch` branch is stable across lifetimes ([`context.ts`][context]).
- **Deadlines, not durations.** Sleeps, retry waits and attempt timeouts are absolute timestamps in a persisted priority queue that arms a DO alarm; a crash mid-sleep resumes for the remainder ([`timePriorityQueue.ts`][pq]).
- **Idempotency key at the instance level.** `create({ id })` refuses a duplicate id within the retention window; `createBatch` is idempotent and skips duplicates ([`workers-api.mdx`][api]).
- **First-class compensation with journaled progress** and reverse-start-order semantics that are pinned by tests ([`rollback.ts`][rollback], [`tests/engine.test.ts`][engine-test]).
- **Cheap hibernation.** Replay plus DO alarms let `waiting` instances cost nothing; this is the reason for the "millions sleeping" claim ([`limits.mdx`][limits]).
- **A real local engine and a modifier-based test API** ship in the open, so the mechanics on this page are checkable ([`workflows-shared`][ws-pkg], [`test-apis.mdx`][test-apis]).

## Weaknesses

- **No disagreement detection.** A cache hit is never compared against the world or against the current code's step kind or config; a renamed step re-executes and a reused name replays a stale value, silently.
- **Versioning is unspecified.** No documented behavior for deploying new code over running instances; the emulation still carries an "upgrade story" TODO ([`engine.ts`][engine]).
- **Rollback closures are not durable.** They are RPC stubs re-collected by re-running `run` in a stub phase; if the code no longer registers the handler, the rollback is logged as `RollbackMissing` and the chain halts ([`rollback.ts`][rollback]).
- **Determinism is a checklist, not a check.** Nothing stops `Date.now()` in a condition; the `Promise.race` hazard is documented rather than prevented ([`rules-of-workflows.mdx`][rules]).
- **The production engine is closed**, and the public emulation admits divergence in places (`readLogsFromStep` returns `[]`; the dynamic-delay retry entry keeps a placeholder timestamp "accepted for local dev") ([`engine.ts`][engine], [`context.ts`][context]).
- **Hard ceilings.** 1 MiB per non-stream step result, 25,000 steps, 30-minute recommended attempt timeout, per-step CPU metering ([`limits.mdx`][limits], [`rules-of-workflows.mdx`][rules]).
- **No crash-position test primitive**; durability is tested by construction, not by sweep.

---

## Key design decisions and trade-offs

| Decision                                                           | Rationale                                                                                                     | Trade-off                                                                                         |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Key steps by `sha1(name)-count`, not by position                   | Code edits and parallelism do not shift identities; `ctx.step.count` and `restart({ from })` share the scheme | Names must be deterministic; a reused name silently replays; no kind/args tripwire                |
| Re-run `run` from the top on every lifetime                        | No continuation capture, no sandbox, plain TypeScript control flow                                            | CPU is re-spent up to the first miss; side effects outside steps repeat; hibernation must be safe |
| Memoize errors as well as values                                   | `try...catch` branches replay identically                                                                     | A transient failure that hit the retry limit is permanent until `restart`                         |
| Persist the step config on first sight and prefer it on replay     | Dynamic configs are allowed; an in-flight step's retry budget is stable                                       | Changing a step's retry policy in code has no effect on steps already started                     |
| Sleeps and timeouts as absolute deadlines in a SQL heap + DO alarm | Survive restart; `waiting` instances are free                                                                 | Dynamic-delay retries park a placeholder deadline (local engine only)                             |
| Rollback handlers as closures, re-collected by replay              | Handlers see the forward step's `output`; no serialization of code                                            | Code drift between forward run and rollback breaks the chain                                      |
| Buffer events before the waiter exists                             | `sendEvent` can precede `waitForEvent`                                                                        | Event buffers live in the same DO; the local engine notes an OOM risk on restore                  |
| Test by modifiers in storage, not by crash injection               | Tests stay black-box against the binding; no engine internals leak                                            | No way to assert "resume after crash at N"                                                        |

---

## Implications for a durable-execution library

- **Name plus occurrence count is the cleanest evidence for named identity.**
  Reorder-safety and parallel-safety fall out of the key itself, with no patch
  markers, no source hash and no rule about where an `await` may appear (§1, §6).
- **Memoize failures, not only successes.** The terminal error is stored and
  re-thrown on replay, so `try`/`catch` control flow is stable across resumes
  (§1). A record that only holds successes changes the program's shape after a
  crash.
- **Persist the operation's resolved configuration on first sight and prefer it on
  replay.** It is a two-line rule that stops a resumed run from behaving
  differently because someone edited a retry budget in between (§5).
- **Record absolute deadlines and re-arm the timer on resume.** The wake-up queue
  stores target timestamps and the alarm is re-armed at initialisation (§11), so a
  long outage does not restart every wait.
- **Closure-based compensation is a trap, and this is the survey's clearest proof.**
  Rollback handlers are stubs that do not survive a restart, so terminating a
  hibernated instance with rollback must first replay the program just to
  rediscover them — and a handler the new code no longer registers becomes a
  missing-rollback error (§4). Registering compensations in the record avoids all
  of this.
- **An undocumented versioning story in a generally available product is itself a
  finding** (§5). The only defence on offer is that name-keying makes most edits
  harmless, which is true and is not a policy.
- **Restart-from-a-named-step is the right shape for an operator action**, and
  instance ids double as the idempotency key at creation (§10). Both are small
  surfaces that a library can expose without committing to a UI.

---

## Sources

- [cloudflare/workers-sdk — GitHub repository][repo] · [`LICENSE-MIT`][license-mit] · [`LICENSE-APACHE`][license-apache] · [`packages/wrangler/package.json`][wrangler-pkg]
- Local engine (`@cloudflare/workflows-shared`): [`package.json`][ws-pkg] · [`src/engine.ts` — the `Engine` Durable Object, tables, `init`, rollback replay, pause/resume/restart/terminate][engine] · [`src/context.ts` — `Context.do`/`sleep`/`sleepUntil`/`waitForEvent`, cache keys, retries][context] · [`src/instance.ts` — `InstanceEvent`, `InstanceStatus`][instance] · [`src/binding.ts` — `WorkflowBinding.create`/`createBatch`/`get`][binding] · [`src/types.ts` — the introspection/modifier API][types]
- Local engine helpers: [`src/lib/cache.ts` — `computeHash` (SHA-1)][cache] · [`src/lib/rollback.ts` — `executeRollbacks`][rollback] · [`src/lib/restart.ts` — `resolveGroupKeysToWipe`][restart] · [`src/lib/retries.ts` — `calcRetryDuration`][retries] · [`src/lib/errors.ts` — `ABORT_REASONS`, `NonRetryableError` handling][errors] · [`src/lib/validators.ts` — step name/config validation][validators] · [`src/lib/delay.ts` — `DEFAULT_RETRY_DELAY_MS`][delay] · [`src/lib/timePriorityQueue.ts`][pq] · [`src/lib/gracePeriodSemaphore.ts`][grace]
- Tests: [`tests/context.test.ts`][context-test] · [`tests/engine.test.ts`][engine-test]
- Tooling: [`packages/miniflare/src/plugins/workflows/index.ts` — the DO namespace per workflow][mf-plugin] · [`packages/vitest-plugin/src/worker/workflows.ts` — `introspectWorkflowInstance`/`introspectWorkflow`][vitest-wf] · [`create-cloudflare` `hello-world-workflows` template][template]
- Docs (source files in [cloudflare/cloudflare-docs][docs-repo]): [Overview][index-doc] · [Get started][guide] · [Workers API][api] · [Rules of Workflows][rules] · [Sleeping and retrying][retrying] · [Step context][step-ctx] · [Events and parameters][events] · [Trigger Workflows][trigger] · [Local development][local-dev] · [Visualize Workflows][visualizer] · [Limits][limits] · [Vitest test APIs][test-apis] · [Release notes data][release-notes] · [Open beta (October 24, 2024)][beta] · [GA (April 7, 2025)][ga]
- Docs (published pages): [Workflows][docs] · [Rules of Workflows][rules-site] · [Workers API][api-site] · [Sleeping and retrying][retrying-site] · [Limits][limits-site] · [Vitest integration test APIs][test-apis-site]
- [Building Workflows: durable execution on Workers — Cloudflare blog, October 24, 2024][blog]
- Related: [DBOS][dbos] · [Azure Durable Functions][adf] · [Temporal][temporal] · [Sagas][sagas] · [catalog index][index] · [Effect (TypeScript)][effect] · [`sparkles:event-horizon` spec][eh-spec]

<!-- References -->

[repo]: https://github.com/cloudflare/workers-sdk
[docs-repo]: https://github.com/cloudflare/cloudflare-docs
[docs]: https://developers.cloudflare.com/workflows/
[license-mit]: https://github.com/cloudflare/workers-sdk/blob/00ae21fa83754462721a52bcd1ff9b4fbc12f898/LICENSE-MIT
[license-apache]: https://github.com/cloudflare/workers-sdk/blob/00ae21fa83754462721a52bcd1ff9b4fbc12f898/LICENSE-APACHE
[wrangler-pkg]: https://github.com/cloudflare/workers-sdk/blob/00ae21fa83754462721a52bcd1ff9b4fbc12f898/packages/wrangler/package.json
[ws-pkg]: https://github.com/cloudflare/workers-sdk/blob/00ae21fa83754462721a52bcd1ff9b4fbc12f898/packages/workflows-shared/package.json
[engine]: https://github.com/cloudflare/workers-sdk/blob/00ae21fa83754462721a52bcd1ff9b4fbc12f898/packages/workflows-shared/src/engine.ts
[context]: https://github.com/cloudflare/workers-sdk/blob/00ae21fa83754462721a52bcd1ff9b4fbc12f898/packages/workflows-shared/src/context.ts
[instance]: https://github.com/cloudflare/workers-sdk/blob/00ae21fa83754462721a52bcd1ff9b4fbc12f898/packages/workflows-shared/src/instance.ts
[binding]: https://github.com/cloudflare/workers-sdk/blob/00ae21fa83754462721a52bcd1ff9b4fbc12f898/packages/workflows-shared/src/binding.ts
[types]: https://github.com/cloudflare/workers-sdk/blob/00ae21fa83754462721a52bcd1ff9b4fbc12f898/packages/workflows-shared/src/types.ts
[cache]: https://github.com/cloudflare/workers-sdk/blob/00ae21fa83754462721a52bcd1ff9b4fbc12f898/packages/workflows-shared/src/lib/cache.ts
[rollback]: https://github.com/cloudflare/workers-sdk/blob/00ae21fa83754462721a52bcd1ff9b4fbc12f898/packages/workflows-shared/src/lib/rollback.ts
[restart]: https://github.com/cloudflare/workers-sdk/blob/00ae21fa83754462721a52bcd1ff9b4fbc12f898/packages/workflows-shared/src/lib/restart.ts
[retries]: https://github.com/cloudflare/workers-sdk/blob/00ae21fa83754462721a52bcd1ff9b4fbc12f898/packages/workflows-shared/src/lib/retries.ts
[errors]: https://github.com/cloudflare/workers-sdk/blob/00ae21fa83754462721a52bcd1ff9b4fbc12f898/packages/workflows-shared/src/lib/errors.ts
[validators]: https://github.com/cloudflare/workers-sdk/blob/00ae21fa83754462721a52bcd1ff9b4fbc12f898/packages/workflows-shared/src/lib/validators.ts
[delay]: https://github.com/cloudflare/workers-sdk/blob/00ae21fa83754462721a52bcd1ff9b4fbc12f898/packages/workflows-shared/src/lib/delay.ts
[pq]: https://github.com/cloudflare/workers-sdk/blob/00ae21fa83754462721a52bcd1ff9b4fbc12f898/packages/workflows-shared/src/lib/timePriorityQueue.ts
[grace]: https://github.com/cloudflare/workers-sdk/blob/00ae21fa83754462721a52bcd1ff9b4fbc12f898/packages/workflows-shared/src/lib/gracePeriodSemaphore.ts
[context-test]: https://github.com/cloudflare/workers-sdk/blob/00ae21fa83754462721a52bcd1ff9b4fbc12f898/packages/workflows-shared/tests/context.test.ts
[engine-test]: https://github.com/cloudflare/workers-sdk/blob/00ae21fa83754462721a52bcd1ff9b4fbc12f898/packages/workflows-shared/tests/engine.test.ts
[mf-plugin]: https://github.com/cloudflare/workers-sdk/blob/00ae21fa83754462721a52bcd1ff9b4fbc12f898/packages/miniflare/src/plugins/workflows/index.ts
[vitest-wf]: https://github.com/cloudflare/workers-sdk/blob/00ae21fa83754462721a52bcd1ff9b4fbc12f898/packages/vitest-plugin/src/worker/workflows.ts
[template]: https://github.com/cloudflare/workers-sdk/blob/00ae21fa83754462721a52bcd1ff9b4fbc12f898/packages/create-cloudflare/templates/hello-world-workflows/ts/src/index.ts
[index-doc]: https://github.com/cloudflare/cloudflare-docs/blob/96d90994571f3db1d4e6fd91820e700d52476e2b/src/content/docs/workflows/index.mdx
[guide]: https://github.com/cloudflare/cloudflare-docs/blob/96d90994571f3db1d4e6fd91820e700d52476e2b/src/content/docs/workflows/get-started/guide.mdx
[api]: https://github.com/cloudflare/cloudflare-docs/blob/96d90994571f3db1d4e6fd91820e700d52476e2b/src/content/docs/workflows/build/workers-api.mdx
[rules]: https://github.com/cloudflare/cloudflare-docs/blob/96d90994571f3db1d4e6fd91820e700d52476e2b/src/content/docs/workflows/build/rules-of-workflows.mdx
[retrying]: https://github.com/cloudflare/cloudflare-docs/blob/96d90994571f3db1d4e6fd91820e700d52476e2b/src/content/docs/workflows/build/sleeping-and-retrying.mdx
[step-ctx]: https://github.com/cloudflare/cloudflare-docs/blob/96d90994571f3db1d4e6fd91820e700d52476e2b/src/content/docs/workflows/build/step-context.mdx
[events]: https://github.com/cloudflare/cloudflare-docs/blob/96d90994571f3db1d4e6fd91820e700d52476e2b/src/content/docs/workflows/build/events-and-parameters.mdx
[trigger]: https://github.com/cloudflare/cloudflare-docs/blob/96d90994571f3db1d4e6fd91820e700d52476e2b/src/content/docs/workflows/build/trigger-workflows.mdx
[local-dev]: https://github.com/cloudflare/cloudflare-docs/blob/96d90994571f3db1d4e6fd91820e700d52476e2b/src/content/docs/workflows/build/local-development.mdx
[visualizer]: https://github.com/cloudflare/cloudflare-docs/blob/96d90994571f3db1d4e6fd91820e700d52476e2b/src/content/docs/workflows/build/visualizer.mdx
[limits]: https://github.com/cloudflare/cloudflare-docs/blob/96d90994571f3db1d4e6fd91820e700d52476e2b/src/content/docs/workflows/reference/limits.mdx
[test-apis]: https://github.com/cloudflare/cloudflare-docs/blob/96d90994571f3db1d4e6fd91820e700d52476e2b/src/content/docs/workers/testing/vitest-integration/test-apis.mdx
[release-notes]: https://github.com/cloudflare/cloudflare-docs/blob/96d90994571f3db1d4e6fd91820e700d52476e2b/src/content/release-notes/workflows.yaml
[beta]: https://github.com/cloudflare/cloudflare-docs/blob/96d90994571f3db1d4e6fd91820e700d52476e2b/src/content/changelog/workflows/2024-10-24-workflows-beta.mdx
[ga]: https://github.com/cloudflare/cloudflare-docs/blob/96d90994571f3db1d4e6fd91820e700d52476e2b/src/content/changelog/workflows/2025-04-07-workflows-ga.mdx
[rules-site]: https://developers.cloudflare.com/workflows/build/rules-of-workflows/
[api-site]: https://developers.cloudflare.com/workflows/build/workers-api/
[retrying-site]: https://developers.cloudflare.com/workflows/build/sleeping-and-retrying/
[limits-site]: https://developers.cloudflare.com/workflows/reference/limits/
[test-apis-site]: https://developers.cloudflare.com/workers/testing/vitest-integration/test-apis/#workflows
[blog]: https://blog.cloudflare.com/building-workflows-durable-execution-on-workers/
[dbos]: ./dbos.md
[adf]: ./azure-durable-functions.md
[temporal]: ./temporal.md
[sagas]: ./sagas.md
[index]: ./index.md
[effect]: ../typescript-effect.md
[eh-spec]: ../../../specs/event-horizon/SPEC.md
[do-concepts]: https://github.com/cloudflare/cloudflare-docs/blob/96d90994571f3db1d4e6fd91820e700d52476e2b/src/content/docs/durable-objects/concepts/what-are-durable-objects.mdx
[wait-example]: https://github.com/cloudflare/cloudflare-docs/blob/96d90994571f3db1d4e6fd91820e700d52476e2b/src/content/docs/workflows/examples/wait-for-event.mdx
[wrangler-instances]: https://github.com/cloudflare/workers-sdk/tree/00ae21fa83754462721a52bcd1ff9b4fbc12f898/packages/wrangler/src/workflows/commands/instances
