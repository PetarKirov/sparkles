# Inngest (TypeScript SDK / Go server)

An event-driven durable-execution platform in which the workflow function is a stateless HTTP endpoint: the Go server re-invokes it once per step, ships the memoized results of every finished step in the request body, and the SDK's `step.run` returns those results instead of running the step body again.

| Field             | Value                                                                                                                                                                                                       |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | Go (server, dev server, executor); TypeScript (`inngest` SDK); Python and Go SDKs share the same wire protocol                                                                                              |
| License           | Server: Server Side Public License 1.0 with an Apache-2.0 future license ([`LICENSE.md`][srv-license]); TypeScript SDK: Apache-2.0 ([`packages/inngest/package.json`][js-pkg])                              |
| Repository        | [inngest/inngest][srv-repo] (server) · [inngest/inngest-js][js-repo] (SDK) · [inngest/website][web-repo] (docs source)                                                                                      |
| Documentation     | [How Inngest functions are executed][doc-exec] · [Versioning and Function Evolution][doc-versioning] · [Open Source SDK Spec][spec]                                                                         |
| Category          | durable-execution engine (server) + durable-execution SDK                                                                                                                                                   |
| Persistence model | replay — the function is re-run from the top on every call request; steps are memoized by hashed id, not by history position                                                                                |
| Journal store     | Per-run Redis hashes: `actions` (hashed step id → JSON output), `stack` (completion order), `inputs`, `pending`, `metadata`; written atomically by the `saveResponse` Lua script                            |
| Latest release    | Server `v1.44.0` (August 26, 2026); TypeScript SDK `inngest@4.20.0` (September 4, 2026)                                                                                                                     |
| Local clone       | `$REPOS/inngest` at `884e2ed1263524740ed04b3bcb56044e06af38cc` · `$REPOS/inngest-js` at `872770705074538c8ae6059a05b94a546b6c868c` · `$REPOS/inngest-website` at `16618171efb85870ffaa110366a054e703d42c3e` |

**Last reviewed:** September 12, 2026.

---

## Overview

### What it solves

Inngest targets the same problem as [Temporal][temporal] — a long-running function that must survive crashes, retries and redeploys — but refuses the worker-and-poller architecture. A function is an ordinary HTTP handler (or a `connect` websocket worker) that the Inngest server calls; the server owns the queue, the run state and the scheduling of sleeps, event waits and child invocations. The docs put the positioning explicitly against Temporal: _"Temporal uses a deterministic replay model where your entire workflow function is re-executed from the beginning on each step, relying on an internal event history to skip completed work. This requires developers to learn and follow strict determinism rules. Inngest uses a step-based memoization model where each step runs once, its result is persisted, and subsequent executions skip completed steps by injecting their stored results."_ ([`how-functions-are-executed.mdx`][web-exec]).

The distinction is narrower than the marketing suggests. The Inngest function _is_ re-executed from the beginning on every call request (the docs say so two paragraphs earlier: _"Each step in your function is executed as a separate HTTP request"_). What differs from Temporal is the matching rule: a memoized result is found by the SHA-1 of the developer-supplied step id, not by its ordinal position in an event history. That single choice drives every answer in the analysis below.

### Design philosophy

The SDK spec states the contract the SDK must uphold ([`docs/SDK_SPEC.md`][spec] §5):

> _"The Inngest Server acts as a high-level event-loop, calling an SDK to both discover and execute blocks of code. … Critically, to support this an SDK MUST maintain determinism in Call Requests when the underlying code has not changed, ensuring that two identical Call Requests will always produce the same output to the Inngest Server."_

Three commitments follow:

1. **Stateless SDK, stateful server.** The SDK holds nothing between requests. Everything it needs to skip work arrives in the `steps` object of the next request, keyed by hashed id.
2. **Id-keyed memoization, not position-keyed history.** The developer names every step; the SDK hashes the name (plus a `:n` loop counter) and looks the hash up. Order is a soft hint (`ctx.stack.stack`), not the key.
3. **Graceful by default.** Code changes mid-run produce warnings and re-execution of unknown steps, never a hard "nondeterminism" failure ([`versioning.mdx`][web-versioning]).

---

## How it works

### User-facing API

```ts
// pages/docs/learn/how-functions-are-executed.mdx (docs example)
const fn = inngest.createFunction(
  { id: 'import-contacts', triggers: { event: 'contacts/csv.uploaded' } },
  async ({ event, step }) => {
    const rows = await step.run('parse-csv', async () =>
      parseCsv(event.data.fileURI),
    );
    const normalizedRows = await step.run('normalize-raw-csv', async () =>
      normalizeRows(rows, getNormalizedColumnNames()),
    );
    const results = await step.run('input-contacts', async () =>
      importContacts(normalizedRows),
    );
    return { results };
  },
);
```

The step tools ([`InngestStepTools.ts`][js-tools]) each produce one opcode: `step.run` and `step.sendEvent` report `StepPlanned` (sendEvent is a planned step whose body calls the client's `_send`), `step.sleep`/`sleepUntil` report `Sleep`, `step.waitForEvent` reports `WaitForEvent`, `step.invoke` reports `InvokeFunction`. The opcode vocabulary lives in `StepOpCode` ([`types.ts`][js-types]):

```ts
// packages/inngest/src/types.ts
export enum StepOpCode {
  WaitForSignal = 'WaitForSignal',
  WaitForEvent = 'WaitForEvent',
  Step = 'Step', // legacy v0, mixed data wrapping
  StepRun = 'StepRun',
  StepError = 'StepError',
  StepFailed = 'StepFailed',
  StepPlanned = 'StepPlanned',
  Sleep = 'Sleep',
  StepNotFound = 'StepNotFound', // "likely indicative that a step was renamed or removed"
  InvokeFunction = 'InvokeFunction',
  AiGateway = 'AIGateway',
  Gateway = 'Gateway',
  RunComplete = 'RunComplete',
  DiscoveryRequest = 'DiscoveryRequest',
  DeferAdd = 'DeferAdd',
  DeferAbort = 'DeferAbort',
}
```

The server-side mirror is `enums.Opcode` ([`pkg/enums/opcode.go`][srv-opcode-enum]); note that the server has no `StepNotFound` member — the SDK's `StepNotFound` is handled as a driver error, not an opcode the state store records.

### The call request

Every invocation is a `POST` whose body the SDK parses in `parseFnData` ([`helpers/functions.ts`][js-functions]):

```ts
// packages/inngest/src/helpers/functions.ts — parseFnData (abridged)
z.object({
  event: z.record(z.any()),
  events: z.array(z.record(z.any())).default([]),
  steps: stepSchema, // hashed id → { data } | { error } | { input }
  defers: z.record(z.object({ abortable: z.boolean().optional() })).optional(),
  ctx: z.object({
    run_id: z.string(),
    fn_id: z.string().optional(),
    attempt: z.number().default(0),
    max_attempts: z.number().optional(),
    disable_immediate_execution: z.boolean().default(false),
    use_api: z.boolean().default(false),
    stack: z
      .object({ stack: z.array(z.string()), current: z.number() })
      .optional(),
  }),
});
```

`stepSchema` ([`api/schema.ts`][js-schema]) admits exactly three memoized shapes: `{ data }` (a finished step), `{ error }` (a step that exhausted retries, in the `{ name, message, stack? }` error format), or `{ input }` (a planned step whose arguments were captured but which has not run). When the payload would exceed the host's request-size limit the server sets `ctx.use_api` and the SDK fetches `/v0/runs/:run_id/batch` and `/v0/runs/:run_id/actions` itself (`fetchAllFnData`, same file; spec §4.4.2).

The SDK answers with `200` (function returned), `206 Partial Content` (an array of reported ops, spec §5.1.1), or `400`/`500` with `X-Inngest-No-Retry` (spec §4.4.3). Each reported op is a `GeneratorOpcode` on the server ([`pkg/execution/state/opcode.go`][srv-opcode]):

```go
// pkg/execution/state/opcode.go
type GeneratorOpcode struct {
	Op          enums.Opcode      `json:"op"`
	ID          string            `json:"id"`      // hashed unique ID; the state-store key
	Name        string            `json:"name"`    // step name, or the sleep duration
	Opts        any               `json:"opts"`
	Data        json.RawMessage   `json:"data"`
	Error       *UserError        `json:"error"`
	DisplayName *string           `json:"displayName"`
	Timing      interval.Interval `json:"timing"`
	Userland    *struct {
		ID    string `json:"id"`              // User-defined ID
		Index int    `json:"index,omitempty"` // Autogenerated index for repeated IDs
	} `json:"userland,omitempty"`
}
```

### Step identity: `hashId`

The hash is plain SHA-1 over the (possibly suffixed) user id ([`engine.ts`][js-engine], bottom of the file):

```ts
// packages/inngest/src/components/execution/engine.ts
const hashId = (id: string): string => {
  return sha1().update(id).digest('hex');
};

const hashOp = (op: OutgoingOp): OutgoingOp => {
  return { ...op, id: hashId(op.id) };
};
```

Collisions within one execution are resolved by `resolveStepIdCollision` in the same file: the first occurrence keeps the bare id, later ones get `baseId + STEP_INDEXING_SUFFIX + i` (`my-step-id`, `my-step-id:1`, `my-step-id:2`, per spec §5.1.2) before hashing. The counter is per execution, recomputed on every replay, so a loop that calls `step.run("row", …)` N times is stable as long as N is. The server stores the id as `OpID [20]byte` ([`v2/state.go`][srv-v2-state]): _"This is currently a SHA1 hash of the step name and step's index, though may be lowered to an 8 or 10 byte hash in the future."_

### Memoization lookup

When the function calls a step tool during a replay, the engine (in the `stepHandler` closure around `engine.ts` line 2900) computes `hashedId`, looks up `this.state.stepState[hashedId]`, and if present marks it `seen`, removes it from `remainingStepsToBeSeen`, and treats the step as fulfilled unless the memo is only an `{ input }`. A fulfilled step's promise resolves with the memoized `data` (or rejects with a `StepError` built from the memoized `error`) without invoking the user's callback. Once `remainingStepsToBeSeen` is empty, `allStateUsed()` is true and the `onMemoizationEnd` middleware hook fires — this is the SDK's notion of "replay is over, new work begins".

### The report loop and the stack

Steps are not memoized the instant they are discovered. `reportNextTick` collects every step found in the current microtask "tick", then walks `remainingStepCompletionOrder` — a copy of `ctx.stack.stack` — and handles the earliest stack entry that has been found, one per tick, until nothing on the stack matches. Only then are the leftover found steps rolled up into a `steps-found` checkpoint and reported to the server ([`engine.ts`][js-engine] around line 2367). This is the spec's §5.4 recommendation implemented: memoize in completion order so that code which raced steps in a previous execution observes the same winner.

If the server asked for one specific step (`requestedRunStep`, the `stepId` query parameter) and the replay never reaches a step with that hash, a timer fires and the execution reports `StepNotFound` with a sorted sample of the steps it _did_ find (`initializeTimer` / `getStepNotFoundDetails`, [`engine.ts`][js-engine]; test coverage in [`step-not-found.test.ts`][js-snf-test]).

### Server state

The `state.State` interface ([`pkg/execution/state/state.go`][srv-state]) exposes `Stack() []string` (_"the order in which data is saved to the state store … strongly orders function steps"_), `Actions() map[string]any`, `Errors() map[string]error` and `ActionID(id)`. The v2 `RunService` ([`v2/interfaces.go`][srv-v2-iface]) narrows this to `SaveStep(ctx, id, stepID, data)`, `SavePending`, `LoadSteps`, `LoadStepInputs`, `LoadStack`, `LoadPending`. The Redis implementation lays a run out as a handful of keys ([`key_generator.go`][srv-keys]):

| Key                                   | Type   | Holds                                      |
| ------------------------------------- | ------ | ------------------------------------------ |
| `{prefix}:actions:{fnID}:{runID}`     | hash   | hashed step id → JSON output               |
| `{prefix}:stack:{runID}`              | list   | hashed step ids in completion order        |
| `{prefix}:inputs:{fnID}:{runID}`      | hash   | hashed step id → captured input            |
| `{prefix}:pending:{fnID}:{runID}`     | set    | planned-but-unfinished step ids            |
| `{prefix}:metadata:{runID}`           | hash   | status, `state_size`, `step_count`, config |
| `{prefix}:bulk-events:{fnID}:{runID}` | string | the triggering event batch                 |
| `{prefix}:key:{idempotencyKey}`       | string | run-level idempotency guard                |

Writes go through one Lua script so a step is committed exactly once ([`saveResponse.lua`][srv-lua]):

```lua
-- pkg/execution/state/redis_state/lua/saveResponse.lua (abridged)
if redis.call("HEXISTS", keyStep, stepID) == 1 then
	if redis.call("HGET", keyStep, stepID) == outputData then
		return { -2, hasStepsPending }   -- idempotent re-save of identical data
	end
	return { -1 }                        -- duplicate response with DIFFERENT data
end
redis.call("HSET", keyStep, stepID, outputData)
redis.call("RPUSH", keyStack, stepID)
redis.call("SREM", keyStepsPending, stepID)
```

`SaveResponse` in [`redis_state.go`][srv-redis] maps `-1` to `ErrDuplicateResponse` and `-2` to `ErrIdempotentResponse`; a second executor delivering the same step output is harmless, a second delivery with different output is rejected.

### Parallel steps

`Promise.all` of un-awaited `step.run` calls makes the SDK discover several unfulfilled steps in one tick, so `steps-found` reports them all as `StepPlanned`. On the server, `handleGeneratorStepPlanned` ([`executor.go`][srv-executor]) enqueues one queue item per planned op, with a job id of `idempotencyKey + "-" + gen.ID + "-plan"`, each of which becomes a separate call request carrying `stepId=<hash>`. When a response carries more than one non-lazy op the executor also flips `ForceStepPlan` in the run's metadata, which becomes `ctx.disable_immediate_execution: true` on every later request ([`executor.go`][srv-executor] around line 3724; spec §5.5). From then on the SDK may no longer run a lone `step.run` inline; it must plan first and execute on the follow-up request.

---

## Analysis

### 1. Step identity and replay matching

Identity is the developer's string id, suffixed `:n` on the n-th repeat within one execution, then SHA-1 hashed (`hashId`, [`engine.ts`][js-engine]; spec §5.1.2). Matching is a hash-map lookup in the request's `steps` object, independent of position in code. The spec's stated reason for hashing is portability: _"IDs are hashed to ensure a consistent length and format across multiple SDKs, allowing cross-language, cross-cloud migrations of Functions mid-Run."_ Arguments are not part of the key: two steps with the same id and different inputs are the same step, and the second is served the first's memo. The `{ input }` memo shape ([`api/schema.ts`][js-schema]) records arguments only so a planned step can be executed later with the arguments it was planned with.

### 2. Journal versus world

The journal wins unconditionally. A memoized `{ data }` is injected without re-running the step body, so a `step.run` that observed the world (a git tag, an API response) returns its old observation forever. There is no re-observation hook and no reconciliation rule; the docs' only instruction is to put non-determinism inside steps so that it is journaled (_"Any non-deterministic logic (such as DB calls or API calls) must be placed within a `step.run()` call"_, [`how-functions-are-executed.mdx`][web-exec]). Disagreement is detected in exactly one direction: when a step the server asked to run is absent from the replay, the SDK returns `StepNotFound`. A step whose memo is stale is never detected.

### 3. Determinism enforcement

By discipline, backed by a soft runtime check. Nothing in the language or SDK forbids `Date.now()`, `Math.random()` or a raw `fetch` between steps; the spec merely requires that identical requests yield identical outputs (§5). The runtime check is the stack walk: the SDK memoizes in `ctx.stack.stack` order and, per spec §5.4, _"If the SDK is following this ordering and the next Step cannot be found, it MUST first warn the user that the Function has appeared to change"_, then fall back to earliest-match memoization. Two findings from the code: the TypeScript engine's `reportNextTick` does the ordered walk and the fallback, but the only order-related warning it emits today is `AUTOMATIC_PARALLEL_INDEXING` (a duplicate id across parallel chains); the `NONDETERMINISTIC_STEPS` code in [`helpers/errors.ts`][js-errors] is declared and not raised anywhere in the package, and `NON_DETERMINISTIC_FUNCTION` is marked `@deprecated` for the retired v0 execution. The docs page's claim that _"If step execution order changes, the SDK logs a warning rather than failing the function"_ ([`versioning.mdx`][web-versioning]) is therefore aspirational for v4 as far as the engine source shows.

### 4. Compensation and failure handling

There is no compensation primitive. Failure handling is three-tiered ([`error-handling.mdx`][web-errors]): a step retries independently (default four retries, per-step counter); an exhausted step throws a `StepError` into the function body where ordinary `try`/`catch` can run a fallback or "rollback" step ([`rollbacks.mdx`][web-rollbacks] — the rollback is just another `step.run` the developer writes); an exhausted function fires `onFailure` or the `inngest/function.failed` system event ([`failure-handlers.mdx`][web-failure]). Nothing registers undo actions on a scope, nothing runs them LIFO, and cancellation does not trigger anything in user code. Idempotency is likewise delegated: _"Retried code should be idempotent, which means running it more than once does not create duplicate or inconsistent side effects"_, with event-level `id` keys (24-hour window) and function-level `idempotency` expressions as the offered tools ([`handling-idempotency.mdx`][web-idem]).

### 5. Versioning against old histories

No version markers exist; the id-keyed model is the versioning story ([`versioning.mdx`][web-versioning]). Adding a step: it runs when discovered, even in a run whose later steps are already memoized, so the docs warn _"New steps must not depend on data from steps that haven't executed yet."_ Changing a step's body under the same id: old runs keep the old memo. Renaming: the new id has no memo, so it re-executes (the documented way to force re-execution). Removing: the orphan memo stays in the `actions` hash and is ignored. Reordering: memos are position-independent, so it works, with the warning caveat from §3. Incompatible rewrites are handled outside the engine, by deploying a second function with a timestamp or `event.v` filter on the trigger. The server records `RequestVersion` per run ([`driver_response.go`][srv-driver]) so a run started under an old hashing scheme keeps it.

### 6. Concurrency under replay

Parallel steps replay in stack order, not discovery order: `ctx.stack.stack` records the order outputs were saved, and the SDK fulfils promises in that order one tick at a time ([`engine.ts`][js-engine] `reportNextTick`; spec §5.4: _"the order in which Steps are discovered dynamically by an SDK can differ from the order in which they should be memoized"_). The server enforces planning after the first parallel response via `ForceStepPlan` → `disable_immediate_execution` ([`executor.go`][srv-executor]), so every subsequent step costs two requests (plan, then run). The docs list the sharp edges: with the v4 default "optimized parallelism", `Promise.race` waits for all branches; sequential steps inside different parallel branches may not run in source order; racing steps are not cancelled ([`step-parallelism.mdx`][web-parallel]). Duplicate ids across branches are auto-indexed with a warning.

### 7. Replay or snapshot

Pure replay. Each request re-runs the function from the top; cost is one function invocation per step plus the payload of every memo (which is why `use_api` exists to pull large state out of band). What replay rules out here is any in-memory state surviving across steps — a variable assigned outside `step.run` is recomputed on every request, and the docs' rollback example works only because `via` is reassigned during replay. The server-side "checkpointing" mode (`checkpoint()` and `checkpointingStepBuffer` in [`engine.ts`][js-engine]; `OpcodeIsSync` in [`pkg/enums/opcode.go`][srv-opcode-enum]) lets one long-lived request execute several `StepRun`s and flush their outputs in batches, which reduces round trips but does not change the model: on the next request the function is still replayed from the top.

### 8. Testing

`@inngest/test` ([`packages/test/README.md`][js-test]) wraps a function in an in-process `InngestTestEngine`: `t.execute()` drives the whole plan-run-memoize loop to completion without a server; `t.executeStep("id")` runs until one step has executed, which is how a `waitForEvent` or `sleep` is asserted to have been registered with the right options; the `steps` option mocks any step by id with a replacement `handler`. Returned `state` exposes each step's output. There is no crash-at-every-step harness and no world-mutation harness; the docs' advice for versioning is manual: start a run with a `step.sleep`, edit the code while it sleeps, and watch the dev server ([`versioning.mdx`][web-versioning]).

---

## Strengths

- **Name-keyed memoization makes ordinary edits safe.** Add, reorder, remove or rename a step and in-flight runs keep going; the position-keyed histories of Temporal-style replay turn each of those into a nondeterminism fault.
- **Stateless workers.** The SDK needs nothing between requests, so functions run on serverless hosts and survive host restarts without a worker cluster.
- **A written wire spec.** [`SDK_SPEC.md`][spec] pins the request body, the response codes, the hashing rule and the stack-order recovery rule, so a third SDK (or a D one) can be built against it.
- **Atomic, idempotent step commit.** `saveResponse.lua` makes double delivery of a step output a no-op and double delivery with different output an error.
- **Parallelism without a scheduler in user code.** `Promise.all` is enough; the executor fans out one queue item per planned step.

## Weaknesses

- **Journal can never be wrong.** A memoized observation of the world is served forever; there is no re-observe or reconcile path, so a step that reads mutable external state must be split from the decisions made on it by the developer, by hand.
- **Determinism is a warning at best.** The spec mandates a warning when the stack order is violated; the v4 TypeScript engine declares the error code and does not raise it. The docs promise more than the code delivers.
- **Arguments are not part of identity.** Same id, different inputs, same memo.
- **No compensation model.** "Rollback" is a `try`/`catch` around a step; nothing is registered, ordered or run on cancellation.
- **Two HTTP requests per step after the first parallel group,** and a full replay of the function body on each; the body itself must be cheap and side-effect-free outside steps.
- **Testing stops at the function boundary.** No harness for crash-then-resume or for the world changing between attempts.

---

## Key design decisions and trade-offs

| Decision                                                         | Rationale                                                                         | Trade-off                                                                                         |
| ---------------------------------------------------------------- | --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Memo keyed by SHA-1 of a developer-chosen id (+ `:n` counter)    | Position-independent, cross-SDK portable, survives reorder/insert/rename          | Developer must keep ids unique and stable; inputs are invisible to the key                        |
| Function re-executed from the top per step                       | Stateless SDK; any host, including serverless                                     | O(steps) invocations and O(state) payload per step; nothing outside a step persists               |
| Completion order shipped as `ctx.stack.stack`, memoized in order | Reproduces race outcomes among parallel steps; gives a hook to detect code change | Only a recommendation; the v4 engine's detection is silent                                        |
| `StepPlanned` then run, forced after the first parallel group    | Server schedules each branch as its own retriable job                             | Doubles requests per step for the rest of the run                                                 |
| Graceful evolution: warn and run unknown steps                   | Deploys do not fail in-flight runs                                                | A silently mismatched replay can serve a wrong memo; incompatible rewrites need a second function |
| Retries per step, `onFailure` per function, no saga primitive    | Keeps the model to one concept (the step)                                         | Compensation is user code in `catch` blocks, with no ordering or cancellation guarantees          |
| Redis hash + list + set per run, one Lua commit script           | Atomic, idempotent, cheap to load in full                                         | The store is a snapshot of outputs, not an event log; no per-attempt history of what was tried    |

---

## Relevance to sparkles

- **Confirms name-plus-counter keying.** The design's `stable name + attempt counter + args hash` is a superset of Inngest's `id + ":n"`. Inngest shows the counter alone is enough for loops and that position-independent keys are what make reorder/insert/rename safe. Keep the name as the primary key; treat position as a hint, exactly like `ctx.stack.stack`.
- **Argues for the args hash Inngest lacks.** Same id with different inputs silently reuses a memo in Inngest. `release`'s steps (tag a version, publish a release) take arguments that change between resumes, so the args hash is the guard Inngest does not have. Decide what a mismatch means: Inngest's `saveResponse.lua` treats "same key, different data" as an error (`-1`), which is a reasonable default for the journal side.
- **Argues against journal-always-wins for observations.** Inngest has no re-observe path, and it is the design's stated weakness that motivates the observe/decide split with a reconciliation table. Inngest's advice (put every world read inside a step) is the discipline version of the same split; the design makes it a type distinction in the capability row, which is stronger.
- **Confirms that compensations are absent from step-memoization engines.** Neither Inngest, nor its docs, nor its spec has a compensation primitive; "rollback" is a `try`/`catch`. The design's explicit LIFO scope is not something to borrow from here, and Inngest is evidence that a durable engine can ship without one — so the scope must earn its place by `release`'s concrete undo cases (delete a pushed tag, delete a created GitHub release).
- **Borrow the completion-order list.** `ctx.stack.stack` is a cheap, separate record of the order steps _completed_, distinct from the order they were _started_. The journal's `started`/`completed` pairs already encode this; make sure replay of concurrent steps fulfils them in completed order, not journal-append order, or racing steps reproduce differently.
- **Borrow the `StepNotFound` timeout.** When resume asks for a step the replayed code never reaches, Inngest waits a bounded time and then reports the mismatch along with the steps it _did_ find. The design's crash-at-every-index test should have an equivalent assertion: a resume that never re-issues a journaled name is a detected failure with a diagnostic listing, not a hang.
- **Warn versus fail is a real choice.** Inngest chose "warn and continue" for order changes and its engine ended up not even warning. For a CLI that cuts releases, a mismatch between journal and code should fail closed with the diagnostic; the design should say so.
- **The in-process test engine is the shape of the sparkles harness.** `InngestTestEngine.execute()` runs the plan/run/memoize loop without a server, and `steps` mocks by id. The design's journaling combinator over a `Ctx` row with `TestClock`/`SimNet`/`SimProc` is the same idea with better doubles; what Inngest lacks and the design should keep is crash-at-every-event-index and mutate-the-world-between-attempts.

---

## Sources

- [inngest/inngest — server repository][srv-repo]
- [inngest/inngest-js — TypeScript SDK repository][js-repo]
- [inngest/website — docs source][web-repo]
- [`docs/SDK_SPEC.md` — Open Source SDK Spec (call requests §4.4, steps §5, hashing §5.1.2, memoization §5.2, recovery and the stack §5.4, parallelism §5.5)][spec]
- [`pkg/enums/opcode.go` — server `Opcode` enum, sync/async/lazy classification][srv-opcode-enum]
- [`pkg/execution/state/opcode.go` — `GeneratorOpcode`][srv-opcode]
- [`pkg/execution/state/state.go` — `State`, `Manager`, `Mutater.SaveResponse`][srv-state]
- [`pkg/execution/state/driver_response.go` — `DriverResponse`, `UserError`, `RequestVersion`][srv-driver]
- [`pkg/execution/state/v2/state.go` — `State`, `OpID [20]byte`][srv-v2-state]
- [`pkg/execution/state/v2/interfaces.go` — `RunService`, `StateLoader`][srv-v2-iface]
- [`pkg/execution/state/redis_state/key_generator.go` — Redis key layout][srv-keys]
- [`pkg/execution/state/redis_state/redis_state.go` — `SaveResponse`][srv-redis]
- [`pkg/execution/state/redis_state/lua/saveResponse.lua` — atomic step commit][srv-lua]
- [`pkg/execution/executor/executor.go` — `handleGeneratorStepPlanned`, `ForceStepPlan`, `handleGeneratorDiscoveryRequest`][srv-executor]
- [`LICENSE.md` — SSPL 1.0 / Apache 2.0 future license][srv-license]
- [`packages/inngest/src/components/execution/engine.ts` — `hashId`, `hashOp`, `resolveStepIdCollision`, `reportNextTick`, `StepNotFound`][js-engine]
- [`packages/inngest/src/components/execution/ARCHITECTURE.md` — lazy ops and checkpointing][js-arch]
- [`packages/inngest/src/components/execution/step-not-found.test.ts`][js-snf-test]
- [`packages/inngest/src/components/InngestStepTools.ts` — step tools → opcodes][js-tools]
- [`packages/inngest/src/types.ts` — `StepOpCode`][js-types]
- [`packages/inngest/src/helpers/functions.ts` — `parseFnData`, `fetchAllFnData`][js-functions]
- [`packages/inngest/src/helpers/errors.ts` — `ErrCode`][js-errors]
- [`packages/inngest/src/api/schema.ts` — `stepSchema`][js-schema]
- [`packages/inngest/package.json` — version and license][js-pkg]
- [`packages/test/README.md` — `@inngest/test`][js-test]
- [Docs: How Inngest functions are executed][doc-exec] ([source][web-exec])
- [Docs: Versioning and Function Evolution][doc-versioning] ([source][web-versioning])
- [Docs: Inngest Steps][doc-steps] ([source][web-steps])
- [Docs: Step parallelism][doc-parallel] ([source][web-parallel])
- [Docs: Error handling][doc-errors] ([source][web-errors]) · [Rollbacks][web-rollbacks] · [Failure handlers][web-failure]
- [Docs: Handling idempotency][doc-idem] ([source][web-idem])
- [Docs: Testing (TypeScript SDK v4)][doc-testing] ([source][web-testing])
- Related: [Temporal][temporal] · [catalog index][index] · [algebraic-effects topic][topic]

<!-- References -->

[srv-repo]: https://github.com/inngest/inngest
[js-repo]: https://github.com/inngest/inngest-js
[web-repo]: https://github.com/inngest/website
[spec]: https://github.com/inngest/inngest/blob/884e2ed1263524740ed04b3bcb56044e06af38cc/docs/SDK_SPEC.md
[srv-opcode-enum]: https://github.com/inngest/inngest/blob/884e2ed1263524740ed04b3bcb56044e06af38cc/pkg/enums/opcode.go
[srv-opcode]: https://github.com/inngest/inngest/blob/884e2ed1263524740ed04b3bcb56044e06af38cc/pkg/execution/state/opcode.go
[srv-state]: https://github.com/inngest/inngest/blob/884e2ed1263524740ed04b3bcb56044e06af38cc/pkg/execution/state/state.go
[srv-driver]: https://github.com/inngest/inngest/blob/884e2ed1263524740ed04b3bcb56044e06af38cc/pkg/execution/state/driver_response.go
[srv-v2-state]: https://github.com/inngest/inngest/blob/884e2ed1263524740ed04b3bcb56044e06af38cc/pkg/execution/state/v2/state.go
[srv-v2-iface]: https://github.com/inngest/inngest/blob/884e2ed1263524740ed04b3bcb56044e06af38cc/pkg/execution/state/v2/interfaces.go
[srv-keys]: https://github.com/inngest/inngest/blob/884e2ed1263524740ed04b3bcb56044e06af38cc/pkg/execution/state/redis_state/key_generator.go
[srv-redis]: https://github.com/inngest/inngest/blob/884e2ed1263524740ed04b3bcb56044e06af38cc/pkg/execution/state/redis_state/redis_state.go
[srv-lua]: https://github.com/inngest/inngest/blob/884e2ed1263524740ed04b3bcb56044e06af38cc/pkg/execution/state/redis_state/lua/saveResponse.lua
[srv-executor]: https://github.com/inngest/inngest/blob/884e2ed1263524740ed04b3bcb56044e06af38cc/pkg/execution/executor/executor.go
[srv-license]: https://github.com/inngest/inngest/blob/884e2ed1263524740ed04b3bcb56044e06af38cc/LICENSE.md
[js-engine]: https://github.com/inngest/inngest-js/blob/872770705074538c8ae6059a05b94a546b6c868c/packages/inngest/src/components/execution/engine.ts
[js-arch]: https://github.com/inngest/inngest-js/blob/872770705074538c8ae6059a05b94a546b6c868c/packages/inngest/src/components/execution/ARCHITECTURE.md
[js-snf-test]: https://github.com/inngest/inngest-js/blob/872770705074538c8ae6059a05b94a546b6c868c/packages/inngest/src/components/execution/step-not-found.test.ts
[js-tools]: https://github.com/inngest/inngest-js/blob/872770705074538c8ae6059a05b94a546b6c868c/packages/inngest/src/components/InngestStepTools.ts
[js-types]: https://github.com/inngest/inngest-js/blob/872770705074538c8ae6059a05b94a546b6c868c/packages/inngest/src/types.ts
[js-functions]: https://github.com/inngest/inngest-js/blob/872770705074538c8ae6059a05b94a546b6c868c/packages/inngest/src/helpers/functions.ts
[js-errors]: https://github.com/inngest/inngest-js/blob/872770705074538c8ae6059a05b94a546b6c868c/packages/inngest/src/helpers/errors.ts
[js-schema]: https://github.com/inngest/inngest-js/blob/872770705074538c8ae6059a05b94a546b6c868c/packages/inngest/src/api/schema.ts
[js-pkg]: https://github.com/inngest/inngest-js/blob/872770705074538c8ae6059a05b94a546b6c868c/packages/inngest/package.json
[js-test]: https://github.com/inngest/inngest-js/blob/872770705074538c8ae6059a05b94a546b6c868c/packages/test/README.md
[web-exec]: https://github.com/inngest/website/blob/16618171efb85870ffaa110366a054e703d42c3e/pages/docs/learn/how-functions-are-executed.mdx
[web-versioning]: https://github.com/inngest/website/blob/16618171efb85870ffaa110366a054e703d42c3e/pages/docs/learn/versioning.mdx
[web-steps]: https://github.com/inngest/website/blob/16618171efb85870ffaa110366a054e703d42c3e/pages/docs/learn/inngest-steps.mdx
[web-parallel]: https://github.com/inngest/website/blob/16618171efb85870ffaa110366a054e703d42c3e/pages/docs/guides/step-parallelism.mdx
[web-errors]: https://github.com/inngest/website/blob/16618171efb85870ffaa110366a054e703d42c3e/pages/docs/guides/error-handling.mdx
[web-rollbacks]: https://github.com/inngest/website/blob/16618171efb85870ffaa110366a054e703d42c3e/pages/docs/features/inngest-functions/error-retries/rollbacks.mdx
[web-failure]: https://github.com/inngest/website/blob/16618171efb85870ffaa110366a054e703d42c3e/pages/docs/features/inngest-functions/error-retries/failure-handlers.mdx
[web-idem]: https://github.com/inngest/website/blob/16618171efb85870ffaa110366a054e703d42c3e/pages/docs/guides/handling-idempotency.mdx
[web-testing]: https://github.com/inngest/website/blob/16618171efb85870ffaa110366a054e703d42c3e/pages/docs/reference/typescript/v4/testing/index.mdx
[doc-exec]: https://www.inngest.com/docs/learn/how-functions-are-executed
[doc-versioning]: https://www.inngest.com/docs/learn/versioning
[doc-steps]: https://www.inngest.com/docs/learn/inngest-steps
[doc-parallel]: https://www.inngest.com/docs/guides/step-parallelism
[doc-errors]: https://www.inngest.com/docs/guides/error-handling
[doc-idem]: https://www.inngest.com/docs/guides/handling-idempotency
[doc-testing]: https://www.inngest.com/docs/reference/typescript/v4/testing
[temporal]: ./temporal.md
[index]: ./index.md
[topic]: ../index.md
