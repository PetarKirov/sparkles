# @effect/workflow (TypeScript)

The durable-workflow layer of the Effect ecosystem: a `Workflow` is an ordinary `Effect` program whose named `Activity` steps have their results persisted as cluster messages, so a crashed or suspended execution is re-run from the top and every finished step is answered from storage instead of being executed again.

| Field             | Value                                                                                                                                                                                                                                                                                                              |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Language          | TypeScript                                                                                                                                                                                                                                                                                                         |
| License           | MIT                                                                                                                                                                                                                                                                                                                |
| Repository        | [`Effect-TS/effect`][repo] (v4 `main`: `packages/effect/src/unstable/workflow` + `unstable/cluster`; v3 line: `packages/workflow` + `packages/cluster`)                                                                                                                                                            |
| Documentation     | [`@effect/workflow` on npm][npm-workflow] · v3 [`packages/workflow/README.md`][v3-readme] · in-source doc comments (the `effect.website` docs site has no workflow page as of September 11, 2026)                                                                                                                  |
| Category          | durable-execution SDK (the `workflow` modules) over a durable-execution engine (`ClusterWorkflowEngine` in the `cluster` modules)                                                                                                                                                                                  |
| Persistence model | replay                                                                                                                                                                                                                                                                                                             |
| Journal store     | the cluster `MessageStorage` mailbox: a `messages` table (one row per persisted request, deduplicated on `message_id`) plus a `replies` table (the request's terminal `WithExit` reply, carrying the encoded `Workflow.Result`); SQL drivers for Postgres, MySQL, MSSQL, SQLite, and an in-memory driver for tests |
| Latest release    | v3 line: `@effect/workflow@0.19.1` and `@effect/cluster@0.60.2` (the `v3` branch at `1af4232fea7bc613e1dc68db9bec7b1f596d9e68`); v4 line: `effect@4.0.0-rc.114` (the clone's `packages/effect/package.json`), where both packages are folded into `effect/unstable/*`                                              |
| Local clone       | `$REPOS/effect` at `657254b8218628b0116497d09aaf783cb88279f3` (v4 `main`); `$REPOS/effect-smol` at `3a1128c7684e04d34d9f541f77adaac38a513056` is the archived v4 staging repository whose history was merged into `main`                                                                                           |

**Last reviewed:** September 12, 2026.

This page covers the durable layer only. The Effect runtime it sits on (fibers, `Effect.gen`, `Layer`, `Scope`, interruption) is described in the sibling page [Effect (TypeScript)][typescript-effect]; everything below assumes that vocabulary.

---

## Overview

### What it solves

A long-running Effect program that talks to the outside world (send an email, wait ten days, wait for a webhook) cannot survive a process restart: the fiber is gone, and re-running the program repeats the side effects. `@effect/workflow` gives such a program a stable identity and a place to put the results of its steps, so the program can be killed, moved to another node, or parked for a week and then re-run to the point where it stopped. The v3 README states the contract in two lines:

> _"An `Activity` represents an unit of work in the workflow. They will only ever be executed once, unless you use `Activity.retry`."_
> ([`packages/workflow/README.md`][v3-readme] on the `v3` branch)

and, on sleeping:

> _"You can sleep for as long as you want - when the workflow pauses it consumes no resources."_
> ([`packages/workflow/README.md`][v3-readme])

The module header of [`Workflow.ts`][workflow-ts] lists the whole surface:

> _"A `Workflow` has a stable tag, schemas for payload, success, and failure, and an idempotency key used to derive execution ids. Workflow definitions can be executed, discarded, polled, interrupted, resumed, and registered with a handler layer. This module also includes workflow result types, compensation and cleanup helpers, suspension support, and settings for defect capture or failure suspension."_

### Design philosophy

Three choices shape everything else:

1. **The engine is a service, the workflow is a plain effect.** A workflow body is an `Effect.gen` function that requires `WorkflowEngine` and `WorkflowInstance` from the context. There is no separate workflow language, no code transform, and no continuation capture; durability is obtained by making each `Activity` ask the engine _"has this name already completed for this execution?"_ before running its body.
2. **The journal is the cluster mailbox, not a bespoke event log.** [`ClusterWorkflowEngine.ts`][cwe-ts] adapts the engine _"so workflow executions, activities, deferred completions, resumes, interrupts, and durable clock wakeups are represented as persisted cluster entity messages."_ Persistence, deduplication, sharding, at-least-once delivery, and transactions are all inherited from `@effect/cluster`; the workflow layer adds only naming and result decoding.
3. **Suspension is interruption.** A workflow that has nothing to do (waiting on a `DurableDeferred`, a durable clock, or a child workflow) interrupts its own fiber and persists a `Suspended` result. Resumption re-runs the body from the beginning; the wait point then finds its answer in storage. No stack is saved anywhere.

The consequence is a system with a very small conceptual core (name-keyed memoization over a durable request/reply mailbox) and a correspondingly large set of documented gotchas about what the memoization does _not_ cover.

---

## How it works

### User-facing API

A workflow is declared with `Workflow.make`, which takes a tag, payload/success/error schemas, and an `idempotencyKey` function ([`Workflow.ts`][workflow-ts], `make`):

```ts
// packages/effect/test/cluster/ClusterWorkflowEngine.test.ts (abridged)
const EmailWorkflow = Workflow.make('EmailWorkflow', {
  payload: { to: Schema.String, id: Schema.String },
  error: SendEmailError,
  idempotencyKey(payload) {
    return payload.id;
  },
});

const EmailWorkflowLayer = EmailWorkflow.toLayer(
  Effect.fn(function* (payload) {
    yield* Activity.make({
      name: 'SendEmail',
      error: SendEmailError,
      execute: Effect.gen(function* () {
        const attempt = yield* Activity.CurrentAttempt;
        if (attempt !== 5) {
          return yield* new SendEmailError({ message: `attempt ${attempt}` });
        }
      }),
    }).pipe(
      EmailWorkflow.withCompensation(
        Effect.fnUntraced(function* () {
          /* undo */
        }),
      ),
      Activity.retry({ times: 5 }),
    );

    yield* DurableClock.sleep({ name: 'Some sleep', duration: '10 seconds' });
    yield* DurableDeferred.await(EmailTrigger);
  }),
);
```

The pieces, each an ordinary Effect value:

| Primitive                 | Module                              | Role                                                                                                                                                      |
| ------------------------- | ----------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Workflow.make`           | [`Workflow.ts`][workflow-ts]        | Definition: `_tag`, schemas, `idempotencyKey`, optional `suspendedRetrySchedule`, annotations (`CaptureDefects`, `SuspendOnFailure`, cluster shard group) |
| `workflow.toLayer(body)`  | [`Workflow.ts`][workflow-ts]        | Registers the body with the `WorkflowEngine`; the body receives `(payload, executionId)`                                                                  |
| `workflow.execute`        | [`Workflow.ts`][workflow-ts]        | Computes the execution id, then `engine.execute`; `{ discard: true }` returns the id without waiting                                                      |
| `Activity.make`           | [`Activity.ts`][activity-ts]        | A named, schema-typed step; itself an `Effect`, so `yield*`-able                                                                                          |
| `Activity.retry`          | [`Activity.ts`][activity-ts]        | `Effect.retry` that bumps the `CurrentAttempt` reference on each try                                                                                      |
| `DurableClock.sleep`      | [`DurableClock.ts`][clock-ts]       | Zero duration: no-op; at or under `inMemoryThreshold` (default 60 s): an in-memory activity; above: a persisted clock message plus a deferred wait        |
| `DurableDeferred`         | [`DurableDeferred.ts`][deferred-ts] | A named wait point completed from outside via a base64url `Token` of `[workflowName, executionId, deferredName]`                                          |
| `DurableDeferred.raceAll` | [`DurableDeferred.ts`][deferred-ts] | Durable race: the first branch's exit is recorded in a deferred named `raceAll/<name>`; replay returns it without re-racing                               |
| `DurableQueue`            | [`DurableQueue.ts`][queue-ts]       | Hand a payload to a persisted worker queue and park on a deferred until the worker records the result                                                     |
| `WorkflowProxy`           | [`WorkflowProxy.ts`][proxy-ts]      | Derives RPC and HTTP endpoints (`execute`, `discard`, `resume`) from a set of workflows                                                                   |

### The engine contract

[`WorkflowEngine.ts`][engine-ts] declares the service every primitive talks to. The interesting operations are the ones the journal is built from:

```ts
// packages/effect/src/unstable/workflow/WorkflowEngine.ts (abridged interface)
readonly execute:         (workflow, { executionId, payload, discard?, suspendedRetrySchedule? }) => Effect<Success | string, Error>
readonly poll:            (workflow, executionId) => Effect<Option<Workflow.Result<Success, Error>>>
readonly interrupt:       (workflow, executionId) => Effect<void>
readonly resume:          (workflow, executionId) => Effect<void>
readonly activityExecute: (activity, attempt) => Effect<Workflow.Result<Success, Error>, never, WorkflowInstance>
readonly deferredResult:  (deferred) => Effect<Option<Exit<Success, Error>>, never, WorkflowInstance>
readonly deferredDone:    (deferred, { workflowName, executionId, deferredName, exit }) => Effect<void>
readonly scheduleClock:   (workflow, { executionId, clock }) => Effect<void>
```

`WorkflowInstance` is the per-run state: `executionId`, the `workflow`, a long-lived `scope` _"only closed when the workflow is completed"_, the `suspended` / `interrupted` / `abandoned` flags, the stored `cause` for `SuspendOnFailure`, the set of `awaitedDeferreds`, and an `activityState` counter with a latch ([`WorkflowEngine.ts`][engine-ts], `WorkflowInstance`).

`Workflow.Result` is the persisted outcome of any step or run: `Complete { exit }` or `Suspended { cause? }`. Its JSON shape is the `Exit` encoding used by the RPC layer ([`RpcMessage.ts`][rpcmessage-ts], `ExitEncoded`):

```json
{
  "_tag": "Complete",
  "exit": {
    "_tag": "Failure",
    "cause": [
      {
        "_tag": "Fail",
        "error": { "_tag": "SendEmailError", "message": "..." }
      }
    ]
  }
}
```

Two engines implement the contract. `WorkflowEngine.layerMemory` keeps `Map`s of executions, activities, and deferred results and is documented as _"useful for tests and local development"_ ([`WorkflowEngine.ts`][engine-ts]). `ClusterWorkflowEngine.layer` is the production engine.

### The cluster engine: every step is a persisted RPC

[`ClusterWorkflowEngine.ts`][cwe-ts] turns each workflow into a cluster `Entity` named `Workflow/<tag>` whose entity id is the execution id, with four RPCs. Each RPC declares a `primaryKey`, and each is annotated `ClusterSchema.Persisted`, which is what makes it a journal entry:

```ts
// packages/effect/src/unstable/cluster/ClusterWorkflowEngine.ts (abridged)
Rpc.make("run", { payload: { ...workflow.payloadSchema.fields, [payloadParentKey]: ... },
                  primaryKey: () => "",
                  success: Workflow.Result({ success: workflow.successSchema, error: workflow.errorSchema }) })
  .annotate(ClusterSchema.Persisted, true).annotate(ClusterSchema.Uninterruptible, true)

const ActivityRpc = Rpc.make("activity", { payload: { name: Schema.String, attempt: Schema.Int, withTransaction: Schema.Boolean },
                                            primaryKey: ({ attempt, name }) => activityPrimaryKey(name, attempt), ... })
const DeferredRpc = Rpc.make("deferred", { payload: { name: Schema.String, exit: ExitUnknown },
                                            primaryKey: ({ name }) => name, ... })
const ResumeRpc   = Rpc.make("resume",   { payload: { childExecutionId: Schema.optional(Schema.String) },
                                            primaryKey: ({ childExecutionId }) => childExecutionId ?? "" })

const activityPrimaryKey = (activity: string, attempt: number) => `${activity}/${attempt}`
```

A fifth entity, `Workflow/-/DurableClock`, receives clock messages whose payload carries a `DeliverAt` timestamp; the cluster delivers the message at that time and the handler completes the clock's deferred (`ClockEntityLayer` in [`ClusterWorkflowEngine.ts`][cwe-ts]).

The storage key of a persisted request is composed in [`Envelope.ts`][envelope-ts] as `${entityType}/${entityId}/${tag}/${id}`; so an activity result lives under, for example, `Workflow/EmailWorkflow/<executionId>/activity/SendEmail/3`. [`SqlMessageStorage.ts`][sql-ts] stores that string in the `message_id` column (hashed with SHA-256 when it exceeds 255 characters) with a `UNIQUE (message_id)` constraint, and inserts with `ON CONFLICT (message_id) DO NOTHING` on Postgres. The two tables, from the Postgres branch:

```sql
-- packages/effect/src/unstable/cluster/SqlMessageStorage.ts (pg dialect, abridged)
CREATE TABLE IF NOT EXISTS cluster_messages (
  id BIGINT PRIMARY KEY,            -- snowflake request id
  rowid BIGSERIAL,
  message_id VARCHAR(255),          -- the deduplication key
  shard_id VARCHAR(50) NOT NULL,
  entity_type VARCHAR(150) NOT NULL,
  entity_id VARCHAR(255) NOT NULL,  -- the execution id
  kind INT NOT NULL,                -- request / ack / interrupt
  tag VARCHAR(50),                  -- run | activity | deferred | resume
  payload TEXT,
  headers TEXT,
  trace_id VARCHAR(32), span_id VARCHAR(16), sampled BOOLEAN,
  processed BOOLEAN NOT NULL DEFAULT FALSE,
  request_id BIGINT NOT NULL,
  reply_id BIGINT, last_reply_id BIGINT, last_read TIMESTAMP,
  deliver_at BIGINT,                -- durable-clock wake-up time
  UNIQUE (message_id)
);
CREATE TABLE IF NOT EXISTS cluster_replies (
  id BIGINT PRIMARY KEY,
  rowid BIGSERIAL,
  kind INT,                         -- 0 = WithExit (terminal), else chunk
  request_id BIGINT NOT NULL,
  payload TEXT NOT NULL,            -- the encoded Workflow.Result
  sequence INT,
  acked BOOLEAN NOT NULL DEFAULT FALSE,
  UNIQUE (request_id, kind),
  UNIQUE (request_id, sequence)
);
```

The memoization itself is not in the workflow layer at all. It is the cluster's duplicate-request path in [`Runners.ts`][runners-ts]: after `saveRequest`, a `Duplicate` result that already has a `WithExit` reply is answered from that reply, and the remote entity is never notified:

```ts
// packages/effect/src/unstable/cluster/Runners.ts (abridged)
Duplicate: ({ lastReceivedReply, originalId }) => {
  // If the last received reply is an exit, we can just return it
  // as the response.
  if (Option.isSome(lastReceivedReply) && lastReceivedReply.value._tag === "WithExit") {
    return message.respond(lastReceivedReply.value.withRequestId(message.envelope.requestId))
  }
  ...
```

So "was this activity already done?" is literally "does a `WithExit` reply exist for the request whose `message_id` is `<entity>/<executionId>/activity/<name>/<attempt>`?".

### The run loop: suspend by interrupting, resume by re-running

`Workflow.intoResult` ([`Workflow.ts`][workflow-ts]) wraps a body so that its exit becomes a `Workflow.Result`: success or typed failure becomes `Complete`; an interrupt with `instance.suspended` set becomes `Suspended`; a defect becomes `Complete` with a `Die` cause when `CaptureDefects` is on (the default) and is re-raised otherwise. `Workflow.suspend` is nothing more than a self-interrupt:

```ts
// packages/effect/src/unstable/workflow/Workflow.ts
export const suspend = (
  instance: WorkflowInstance['Service'],
): Effect.Effect<never> =>
  Effect.interruptible(
    Effect.callback<never>(() => {
      instance.suspended = true;
      const fiber = Fiber.getCurrent()!;
      fiber.interruptUnsafe(fiber.id);
    }),
  );
```

An `Activity` whose engine call returns `Suspended`, or a `DurableDeferred.await` whose engine lookup returns `None`, calls `suspend`. The `run` RPC then completes with a persisted `Suspended` reply. Resumption (`resume`, a `deferred` completion, a child's `resume` message, or the top-level `execute` polling loop with its `suspendedRetrySchedule`, default exponential from 200 ms capped at 30 s) calls `sharding.reset(requestId)`, which in [`SqlMessageStorage.ts`][sql-ts] deletes the terminal reply and marks the `run` row unprocessed:

```ts
// packages/effect/src/unstable/cluster/SqlMessageStorage.ts (clearReplies)
DELETE FROM replies  WHERE request_id = ? AND kind = 0
DELETE FROM messages WHERE request_id = ? AND kind = <interrupt>
UPDATE messages SET processed = FALSE, last_reply_id = NULL, last_read = NULL WHERE request_id = ?
```

The entity then re-executes the `run` handler from the top with the same payload. Every `Activity.make` in the body issues its `activity` request again; the ones with a stored `WithExit` come back instantly from the duplicate path, and execution proceeds past the previous suspension point. Idle entities are released after `entityMaxIdleTime` of 10 seconds because _"Workflow state is durable, so an idle entity (completed or suspended) can be released quickly and is rebuilt from storage when the next message arrives"_ ([`ClusterWorkflowEngine.ts`][cwe-ts]).

---

## Analysis

### 1. Step identity and replay matching

A workflow execution is identified by a deterministic id: the first 16 bytes of `SHA-256("<tag>-<idempotencyKey(payload)>")`, hex-encoded ([`Workflow.ts`][workflow-ts] `makeExecutionIdFromPayload`; [`internal/crypto.ts`][crypto-ts]). Executing the same workflow with a payload that maps to the same key is a duplicate of the `run` request; the cluster test asserts that a second `execute` adds no rows and returns the stored result ([`ClusterWorkflowEngine.test.ts`][cluster-test], "executes, resumes, deduplicates, and polls a suspended workflow").

Within an execution a step is identified by **name plus attempt**, nothing else:

- an activity by `${executionId}/${activity.name}/${attempt}` in the memory engine and by `activity/${name}/${attempt}` under the run entity in the cluster engine;
- a deferred by its `name` under the same entity;
- a durable clock by `DurableClock/${name}`;
- a durable race by `raceAll/${name}`;
- a child workflow by the child's own execution id, and its wake-up of the parent by a `resume` message keyed on the child id.

The arguments to an activity are **not** part of the key. `Activity.make` takes an `execute` effect, not a function of arguments, so the engine never sees inputs. `Activity.idempotencyKey(name, { includeAttempt })` ([`Activity.ts`][activity-ts]) exists for the body to derive a key (`SHA-256(executionId[-attempt]-name)`) for its _own_ downstream idempotent calls, such as a payment-provider request; it does not feed the journal.

`Activity.retry` is the only thing that changes the attempt counter, and it does so by providing a fresh `CurrentAttempt` before each `Effect.retry` iteration ([`Activity.ts`][activity-ts]). Each attempt is a new journal row; the test counts _"5 attempts to send email"_ as five persisted requests for one activity. A `DurableDeferred` can opt into the attempt with `withActivityAttempt`, which renames it `${name}/${attempt}`.

Matching on replay is therefore purely structural: the body re-runs, each `Activity.make` re-issues its request, the storage's `UNIQUE (message_id)` turns the re-issue into a lookup. An activity name that the new run does not visit leaves an orphan row; an activity name the old run never visited runs fresh. Nothing checks that the sequence of names is the same as last time.

### 2. Journal versus world

The journal wins, unconditionally. There is no re-observation step and no reconciliation table: a completed activity's stored exit is decoded and returned (`activityExecute` in [`WorkflowEngine.ts`][engine-ts] runs `Schema.decodeEffect(activity.exitSchemaPartial)` on the stored JSON and `orDie`s on a decode failure). If the world moved on (the email was sent, but the recipient was since deleted), the workflow does not notice until a later activity fails.

Disagreement is detected in exactly one place: schema decoding. A stored result that no longer decodes against the activity's current `success`/`error` schemas is a defect that kills the run. That is a versioning problem more than a world-drift problem, and it is treated under §5.

The only concession to a changed world is on the _input_ side of a step. `Activity.make`'s doc comment is explicit that partial work is not covered:

> _"Only completed activity results are memoized. If the activity suspends while awaiting child workflows or a durable clock, its body runs again when the parent workflow replays. Side effects before the suspension can repeat; make those side effects idempotent."_
> ([`Activity.ts`][activity-ts], `make`)

`DurableQueue` states the same rule for its workers: _"Delivery is at-least-once: a crash between handler success and the acknowledgement redelivers the item, so handlers must be idempotent."_ ([`DurableQueue.ts`][queue-ts]).

### 3. Determinism enforcement

By discipline. The workflow body is an arbitrary `Effect`; nothing forbids `Effect.sleep`, `DateTime.now`, `Random`, or a plain `HttpClient` call between activities, and the runtime does not record or check them. There is no non-determinism error, no history-mismatch detection, and no sandboxing of the workflow fiber. The test suite's own `EmailWorkflow` calls `DateTime.now` _inside_ an activity precisely so that the value is journaled ([`ClusterWorkflowEngine.test.ts`][cluster-test], the `Sleep` activity with `success: Schema.DateTimeUtc`), which is the intended pattern: put anything the world decides inside an `Activity`.

What the runtime _does_ enforce is scoping. The `WorkflowInstance` and `WorkflowEngine` requirements appear in the `R` channel of every durable primitive, so an `Activity` cannot be `yield*`-ed outside a workflow body without a type error, and `toLayer` strips `WorkflowInstance | Execution<Tag> | Scope` from the body's requirements ([`Workflow.ts`][workflow-ts], `toLayer`). The type system tracks _where_ durable steps may appear; it says nothing about what happens between them.

Two runtime details reduce, without eliminating, the cost of replayed non-determinism:

- `DurableClock.sleep` with a duration at or under 60 seconds is an in-memory `Effect.sleep` wrapped in an activity, so short sleeps are journaled as completed once and not re-slept on replay ([`DurableClock.ts`][clock-ts]).
- `Activity.raceAll` records the first branch's exit durably, so a replayed race does not re-race ([`Activity.ts`][activity-ts] delegating to `DurableDeferred.raceAll`).

### 4. Compensation and failure handling

`Workflow.withCompensation(effect, (value, cause) => …)` runs `effect` uninterruptibly and, on success, registers a finalizer on the **workflow instance scope** through `Workflow.addFinalizer`; the finalizer runs the compensation only when the scope closes with a failure exit ([`Workflow.ts`][workflow-ts]):

```ts
// packages/effect/src/unstable/workflow/Workflow.ts
export const withCompensation = dual(2, (effect, compensation) =>
  Effect.uninterruptibleMask(restore =>
    Effect.tap(restore(effect), value =>
      addFinalizer(exit =>
        Exit.isSuccess(exit) ? Effect.void : compensation(value, exit.cause),
      ),
    ),
  ),
);
```

The properties follow from Effect's `Scope`:

- **Registration** is explicit and per step: only effects wrapped in `withCompensation` get a compensation. The doc comment warns: _"Compensation finalizers are only registered for top-level effects in the workflow and do not work for nested activities."_
- **Ordering** is last-in-first-out, because a `Scope` runs its finalizers in reverse registration order ([`Scope.ts`][scope-ts], `addFinalizer` example: `["work", "cleanup 3", "cleanup 2", "cleanup 1"]`).
- **Triggering** happens when `intoResult` closes the instance scope with the run's final exit. `Suspended` does not close the scope (the cluster test checks _"normal finalizer should run even after suspension / but not compensation"_); `Complete` with a failure does; an explicit `interrupt` deposits a durable `InterruptSignal` deferred, and the next run closes the scope with an interrupt exit, which also runs compensations ([`ClusterWorkflowEngine.test.ts`][cluster-test], "interrupts a suspended workflow and runs compensation").
- **Durability by replay, not by journal.** Compensations are in-memory finalizers. They survive a crash only because the next run re-registers them: the replayed body passes through `withCompensation` again, the wrapped activity returns instantly from storage, and the finalizer is added again. A compensation that has _run_ is not journaled either, so a crash mid-compensation re-runs all compensations on the next attempt.
- **Abandonment skips them.** When the cluster moves an execution to another runner mid-run, the old owner's exit carries the `ClusterSchema.Abandon` annotation, `instance.abandoned` is set, and `addFinalizer` callbacks are skipped so that _"the run can replay elsewhere"_ ([`Workflow.ts`][workflow-ts], `intoResult` and `addFinalizer`; [`internal/clusterAbandon.ts`][abandon-ts]).

Failure handling around the compensation mechanism:

- **`CaptureDefects`** (default `true`): defects are stored inside the `Complete` result and therefore replayed as the workflow's answer; off, they propagate out of the run without being journaled ([`Workflow.ts`][workflow-ts]). The test _"can serialize workflow defects"_ round-trips an `Error` instance through storage.
- **`SuspendOnFailure`** (default `false`): any failure is converted into `Suspended` with the cause stored in `instance.cause`, and the execution waits for a manual `workflow.resume(executionId)`; this is the "pause on error, fix, and continue" mode.
- **Activity retry** is opt-in via `Activity.retry`. Separately, an activity whose body is interrupted for a reason other than suspension is retried automatically by `retryOnInterrupt` with `Schedule.exponential(400, 1.5)` capped at 10 seconds for up to 10 attempts, after which it dies with _"interrupted and retry attempts exhausted"_ ([`Activity.ts`][activity-ts]); `interruptRetryPolicy` overrides this.
- **`ClusterSchema.WithTransaction`** on an activity wraps the server-side write of its result in the storage transaction, so a result row and the activity's own SQL writes commit together when the `MessageStorage` supports it ([`ClusterSchema.ts`][clusterschema-ts]).

### 5. Versioning against old histories

There is no versioning API. No `patched`/`getVersion` gate, no workflow version pinned in the journal, no task-queue-per-version routing. The identity of a workflow is its `_tag`, the identity of a step is its `name`, and the schema of a stored result is whatever the current code's `success`/`error` schema decodes.

What follows for the four kinds of change:

| Change to workflow code             | Effect on an in-flight execution                                                                                                  |
| ----------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| Add an activity                     | Runs fresh on replay (no row exists); safe if the world is idempotent to it running "late"                                        |
| Remove an activity                  | Its row is orphaned and ignored; safe                                                                                             |
| Rename an activity                  | Treated as remove + add: the step re-executes                                                                                     |
| Reorder activities                  | Invisible: each name still finds its own row; the body's control flow, not the journal's order, decides what runs                 |
| Change a result schema incompatibly | `Schema.decodeEffect(...)` on the stored JSON fails and is `orDie`d: the run dies with a defect                                   |
| Change the payload schema           | The persisted `run` payload is decoded by the current schema when the entity restarts; incompatible change is a defect at restart |

The engine itself carries one explicit compatibility shim, which shows the maintainers' approach when _their_ message formats change: `ResumeRpc` accepts an empty payload because _"Older persisted resume envelopes have an empty payload and use the empty key"_ ([`ClusterWorkflowEngine.ts`][cwe-ts]), and a test drives _"a fresh entity from a legacy envelope"_ through both a queued and an unqueued replay ([`ClusterWorkflowEngine.test.ts`][cluster-test]). Application-level evolution is left to `Schema`'s own tools (optional fields, defaults, transformations); the test suite contains no case of a body changing between suspension and resumption.

### 6. Concurrency under replay

Concurrency inside a body is plain Effect concurrency, and replay of it rests on name-keyed memoization:

- **Parallel activities** must have distinct names; two concurrent `Activity.make({ name: "x" })` calls would share one journal key. The cluster engine additionally keeps an in-process `activities` map keyed by `${executionId}/${name}` and a latch so that the entity's `activity` handler can find the effect body that the client registered for that name ([`ClusterWorkflowEngine.ts`][cwe-ts], `activityExecute`).
- **Parallel child workflows** are ordinary `Child.execute` calls under `Effect.forEach(..., { concurrency })`. Before the child's execution id is even computed, `withPendingActivity` registers it with the parent _"so a sibling that suspends first waits for this child to be dispatched"_ ([`Workflow.ts`][workflow-ts]). `wrapActivityResult` then makes a suspending branch wait until `activityState.count` returns to zero, so the parent's `Suspended` reply is not published while a sibling activity is still running. The tests _"parallel child workflows inside an activity suspend the parent durably"_, _"bounded child concurrency progresses across suspended activity replays"_, and _"parallel child workflows in the workflow body all dispatch before suspending"_ pin this down ([`ClusterWorkflowEngine.test.ts`][cluster-test]).
- **Races** are made durable by `DurableDeferred.raceAll`: the losers are interrupted, the winner's exit is written to `raceAll/<name>`, and a replay returns the stored winner (_"Activity.raceAll replays the first durable activity"_). A branch that wakes on a deferred while another branch is active preempts the run: `deferredDone` in `makeDeferredState` marks the instance suspended and interrupts the fiber, and the comment explains _"Suspended retains the pending result; the engine re-runs the interrupted run and the replay observes the completion."_ ([`WorkflowEngine.ts`][engine-ts]).
- **Ordering across replays** is not recorded. Two parallel activities that completed in order A, B in the first run may be answered in order B, A from storage on replay; because each is looked up by name, and the body's own joins decide the continuation, that is harmless as long as the body does not observe completion order through non-journaled state.

### 7. Replay or snapshot

Pure replay; there is no snapshot of fiber state anywhere. What is persisted is the set of `(name, attempt) → exit` results plus the run's own last result. The consequences, in both directions:

- **Cost per wake-up** is a full re-execution of the body up to the wait point, with one storage read per activity (batched by the cluster's mailbox reads, but each is a request/reply round trip through sharding). A body with hundreds of activities pays hundreds of lookups every time a deferred fires.
- **Cost per activity** is at least one row in `messages` and one in `replies`; `Activity.retry({ times: n })` multiplies that by attempts.
- **What replay rules out**: a body that is not idempotent between activities (addressed by discipline, §3); observing wall-clock progress between activities; long CPU-bound work before the first activity, which is repeated on every wake.
- **What replay enables**: process death at any instruction is recoverable with no special crash handling; migration between cluster runners is the abandon-and-replay path; the entity can be evicted after 10 seconds idle and rebuilt from storage; polling `poll(executionId)` reads the same rows the engine does.
- **Short sleeps are the escape hatch**: `DurableClock.sleep` under the 60-second `inMemoryThreshold` is an in-memory activity, trading durability of the wait for one row instead of a clock message, a deferred completion, and a re-run.

### 8. Testing

The repository tests the layer at two levels, and both are available to applications:

- **`WorkflowEngine.layerMemory`** runs workflows with no cluster at all; the memory engine's `activities` map is the journal. [`WorkflowEngine.test.ts`][engine-test] covers fan-out replay at several concurrency levels, engine shutdown running compensations, and finalizer visibility of a deposited interrupt.
- **The cluster engine over `MessageStorage.layerMemory`**, assembled in [`ClusterWorkflowEngine.test.ts`][cluster-test] from `Sharding.layer`, `Runners.layerNoop`, `RunnerStorage.layerMemory`, `RunnerHealth.layerNoop`, and a `ShardingConfig.layer` with a 5-second `entityMessagePollInterval`. This is a real sharded engine with an in-memory mailbox, driven deterministically by Effect's `TestClock` (`TestClock.adjust("10 seconds")` fires the durable clock) and by calling `sharding.pollStorage` by hand.

The test oracle is the journal itself. `MessageStorage.MemoryDriver` exposes `requests` and `journal`, and tests assert exact row counts with a comment per row:

```ts
// packages/effect/test/cluster/ClusterWorkflowEngine.test.ts
// - 1 initial request
// - 5 attempts to send email
// - 1 sleep activity
// - 1 durable clock run
// - 1 durable clock deferred set
expect(driver.requests.size).toEqual(9);
```

Crash injection is done by `sharding.reset(requestId)` (clear the reply, mark unprocessed, force a replay) rather than by killing a process, and side-effect counting by a `Flags` map service. There is no crash-at-every-index sweep and no mutate-the-world-between-runs test; the replay tests target specific hazards the maintainers hit (child completing during parent cleanup, coalesced wake-ups, legacy envelopes).

### 9. Journal integrity and the single writer

The journal is a relational mailbox, so integrity is delegated to the database and to the cluster's ownership protocol rather than to any workflow-level scheme.

**Duplicate appends are idempotent on the composed primary key.** A persisted request's `message_id` is `${entityType}/${entityId}/${tag}/${id}` ([`Envelope.ts`][envelope-ts]), the column carries `UNIQUE (message_id)`, and the Postgres insert is `ON CONFLICT (message_id) DO NOTHING` followed by a select of the existing row ([`SqlMessageStorage.ts`][sql-ts], `insertEnvelope`). Keys over 255 characters are SHA-256 hashed at the storage boundary. `saveRequest` therefore returns `SaveResult.Success` or `SaveResult.Duplicate`, and the `Duplicate` _"carries the original request ID and the last reply already received for the duplicated request"_ ([`MessageStorage.ts`][storage-ts]). No append is conditional on a journal version or length; the guard is the uniqueness of the step's name, not the journal's shape.

**Intent is durable before the effect runs.** For a `Persisted` request the runner saves the envelope first and only then notifies the entity ([`Runners.ts`][runners-ts], `notifyWith`: _"after persisting the request, we need to check if the request is a duplicate"_). An activity therefore has a `messages` row before its body executes, and the `replies` row arrives afterwards; the pair is the write-ahead intent and its result. The two are written in separate transactions: `saveReply` updates `processed`/`last_reply_id` on the message and inserts the reply inside one `sql.withTransaction`, and `clearReplies` (reset) is likewise one transaction ([`SqlMessageStorage.ts`][sql-ts]). Wider atomicity is opt-in: `ClusterSchema.WithTransaction` on an activity wraps _"server writes with the configured storage transaction"_, so an activity's own SQL and its result row commit together when the driver supports it ([`ClusterSchema.ts`][clusterschema-ts]).

**The single writer is the shard owner, enforced by a lease.** An execution id maps to one entity address and one shard; a shard is owned by the runner holding its lock in `RunnerStorage`, which _"records which runners are registered, whether they are healthy, which machine id a runner receives, and which shard locks are held by each runner"_ ([`RunnerStorage.ts`][runnerstorage-ts]). The SQL implementation takes a `cluster_locks` row per shard with `acquired_at`, refreshes it every `shardLockRefreshInterval` (default 10 seconds), and lets another runner take it over once `acquired_at` is older than `shardLockExpiration` (default 35 seconds); on Postgres and MySQL it additionally holds an advisory lock on a reserved connection ([`SqlRunnerStorage.ts`][sqlrunnerstorage-ts]; [`ShardingConfig.ts`][shardingconfig-ts]). On acquiring a shard the runner calls `storage.resetShards`, clearing every `last_read` so unprocessed messages are re-delivered to the new owner ([`Sharding.ts`][sharding-ts]).

**Message delivery has its own read lease.** `unprocessedMessages` selects rows with `processed = FALSE AND (last_read IS NULL OR last_read < <ten minutes ago>)`, under `FOR UPDATE` on Postgres, and stamps `last_read` on the rows it takes ([`SqlMessageStorage.ts`][sql-ts]). A runner that dies mid-activity leaves the request unprocessed with a stale `last_read`; ten minutes later, or immediately after a shard hand-over resets the column, the next owner re-runs it. Within one runner, the workflow entity is registered with `concurrency: 2`, one slot for the run and one so that _"deferred completions [can] wake the active run"_, and a `resumeGate` semaphore serialises wakes ([`ClusterWorkflowEngine.ts`][cwe-ts]).

**Torn writes and writer identity.** Because every record is a SQL row, there is no length prefix, checksum, or commit marker of its own; the database's transaction guarantees are the answer. Request and reply ids are snowflakes, _"built from a millisecond timestamp, a machine id, and a sequence number for that machine"_ ([`Snowflake.ts`][snowflake-ts]), so the writing runner is recoverable from any id, but nothing checks a writer id on read. The one generation-like mechanism is the abandon path: when a runner shuts down or loses a shard while a persisted request is in flight, the message is re-persisted and the local caller is interrupted with the `ClusterSchema.Abandon` annotation because _"the request will be served under the next owner"_ ([`Sharding.ts`][sharding-ts]); the workflow layer honours it by skipping finalizers (§4).

### 10. Operator recovery and intervention

The operator surface is the engine API plus whatever the operator can do to the SQL tables; there is no UI, no history query, and no step editor.

**Lifecycle commands exist and are journaled.** `workflow.interrupt(executionId)` completes a durable deferred named `Workflow/InterruptSignal` for that execution; the next run of the body observes it and exits with an interrupt, which runs compensations and closes the instance scope ([`ClusterWorkflowEngine.ts`][cwe-ts], `interrupt`). The interrupt is itself a `deferred` request row, so it survives a crash and leaves a trace. `interruptUnsafe` additionally sends a cluster `Envelope.Interrupt` to the in-flight run, _"potentially ignoring compensation finalizers and orphaning child workflows"_ ([`WorkflowEngine.ts`][engine-ts]). `workflow.resume(executionId)` is only meaningful for a suspended run: it finds the `run` request's `Suspended` reply, calls `sharding.reset(requestId)` to delete that reply and mark the request unprocessed, then `pollStorage` re-delivers it. `WorkflowProxy.toRpcGroup` / `toHttpApiGroup` expose `execute`, `discard`, and `resume` over RPC and HTTP so an operator tool need not import the handler ([`WorkflowProxy.ts`][proxy-ts]).

**Cancellation is distinct from failure, and pausing is a mode.** An interrupted execution's persisted result is `Complete` with an interrupt-only cause, which `poll` returns as such (the test _"interrupts a suspended workflow and runs compensation"_ asserts `value._tag === "Complete" && value.exit._tag === "Failure"` on the stored reply, [`ClusterWorkflowEngine.test.ts`][cluster-test]). `SuspendOnFailure` turns every failure into a `Suspended` result with the cause kept on the instance, so an operator can fix the world and call `resume` ([`Workflow.ts`][workflow-ts]).

**Inspection is `poll` and the tables.** `poll(executionId)` returns `None`, `Suspended`, or `Complete` by reading the `run` request's last reply ([`ClusterWorkflowEngine.ts`][cwe-ts]). There is no API to list executions, page through an execution's activities, or stream its history; an operator who wants the sequence of steps queries `cluster_messages` and `cluster_replies` by `entity_id` directly. Cluster-level gauges (`effect_cluster_entities`, runners, healthy runners, acquired shards) exist for dashboards ([`ClusterMetrics.ts`][clustermetrics-ts]), but nothing workflow-specific.

**Hand-supplying a result is possible only for deferreds.** `DurableDeferred.done` / `succeed` / `fail` take a token and write the deferred's exit from any process that has the engine ([`DurableDeferred.ts`][deferred-ts]); that is the designed human-input channel (§11) and doubles as the operator's lever for a stuck wait. An activity's stored result cannot be edited or skipped through the API; the only tools are `sharding.reset(requestId)` on the activity's request (re-run that attempt, used internally by `resetActivityAttempt`) and `MessageStorage.clearAddress` (drop every row for an execution, used to clear a durable clock on interrupt). Both delete rather than annotate, so an intervention on an activity is invisible afterwards, unlike an interrupt.

**Resuming from a chosen point is not supported.** Replay always restarts the body from the top and consults every stored result; there is no fork-from-step, rewind-to-index, or checkpoint selection. Deleting rows by hand approximates "re-run from step N", at the cost of the audit trail.

**Dead-lettering exists only in `DurableQueue`.** _"When an item exhausts its persisted queue attempts it is dead-lettered: the `DurableDeferred` never resolves and the workflow stays parked until the item is requeued out of band, while the id-based de-duplication prevents replays from resurrecting the failed item."_ ([`DurableQueue.ts`][queue-ts]). A workflow whose activity keeps dying has no quarantine state: with `CaptureDefects` on it completes with the defect; with it off, the run keeps failing at the entity until reset.

### 11. Suspension and external input

Waiting is the mechanism the whole layer is built around: everything that is not an activity's own body is a suspension on a named deferred.

**The primitives** are `DurableDeferred.await` (a named, externally completable wait point), `DurableClock.sleep` (a deferred completed by a `DeliverAt`-scheduled clock message), child `Workflow.execute` (the parent parks until the child's `resume` message), `DurableDeferred.raceAll` / `Activity.raceAll` (first of several, recorded), and `DurableQueue.process` (hand work to a worker and park on the worker's token) ([`DurableDeferred.ts`][deferred-ts]; [`DurableClock.ts`][clock-ts]; [`DurableQueue.ts`][queue-ts]).

**Waiting ends the run.** `await` registers the deferred's name in `instance.awaitedDeferreds`, asks the engine for a stored result, and on `None` calls `Workflow.suspend`, which self-interrupts the fiber ([`DurableDeferred.ts`][deferred-ts]). The run's persisted reply becomes `Suspended`, the entity is evicted after 10 seconds idle, and nothing is held in memory. The exception is the in-memory threshold: a `DurableClock.sleep` at or under 60 seconds is a live `Effect.sleep` inside an activity, so the fiber blocks and a crash during it re-sleeps from zero ([`DurableClock.ts`][clock-ts]). A caller that called `execute` without `discard` does hold a fiber: it loops on `run` with the `suspendedRetrySchedule` (default exponential from 200 ms capped at 30 seconds, unbounded) until the result is `Complete` ([`WorkflowEngine.ts`][engine-ts], `makeUnsafe`).

**Suspended is a first-class persisted state.** `Workflow.Result` is the union `Complete | Suspended`, the `Suspended` schema carries an optional `cause`, and `poll` returns it to any caller ([`Workflow.ts`][workflow-ts]). The tests drive on it directly: `while (Option.isNone(result) || result.value._tag !== "Suspended") { … pollStorage … }` ([`ClusterWorkflowEngine.test.ts`][cluster-test]).

**Addressing external input** is by name within an execution. A `Token` is the base64url encoding of `[workflowName, executionId, deferredName]`, produced inside the workflow by `DurableDeferred.token`, or outside from a payload by `tokenFromPayload` (which recomputes the execution id from the idempotency key) ([`DurableDeferred.ts`][deferred-ts]). Completing it is a persisted `deferred` request with `primaryKey: name`, so:

- an input that arrives **twice** is a duplicate row and is ignored (the memory engine spells it out: `if (deferredResults.has(id)) return Effect.void`, [`WorkflowEngine.ts`][engine-ts]);
- an input that arrives **early**, before the body reaches `await`, is simply found in storage when it does;
- an input that **never** arrives leaves the execution `Suspended` indefinitely; there is no timeout parameter on `await`, and the only bound is a race against a `DurableClock` via `raceAll`, whose winner is then journaled.

**Human approval is the documented pattern, not a special construct.** The v3 README's example forks a `DurableDeferred.succeed` with the token to stand in for an external system, then `await`s ([`packages/workflow/README.md`][v3-readme]); a real approval is the same token delivered through any channel to a process that has the `WorkflowEngine`. Rejection is `DurableDeferred.fail` with the deferred's typed error schema. `SuspendOnFailure` plus `resume` is the complementary operator-in-the-loop pattern for errors rather than decisions (§10).

---

## Strengths

- **Tiny conceptual core.** Name-keyed memoization over a durable request/reply mailbox; everything else (`DurableClock`, `DurableDeferred`, races, child workflows, queues) is built from `activity` and `deferred` messages.
- **The journal is reused infrastructure.** Deduplication, sharding, delivery-at-time, transactions, and reply routing all come from `@effect/cluster`; the workflow layer adds around 3,500 lines including the proxy and queue.
- **Typed all the way down.** Payload, success, error, and deferred values are `Schema`s, so the journal's JSON is decoded, not trusted, and a workflow's dependencies are checked by the `R` channel.
- **Compensation is first-class and scoped**, with LIFO order and the run's cause passed in.
- **Suspension costs nothing** while parked; the entity is evicted and rebuilt from storage.
- **Deterministic tests without a database**: `TestClock` plus the memory driver make a real sharded replay run in milliseconds.

## Weaknesses

- **Determinism is entirely the author's problem** and there is no detector; a non-idempotent statement between two activities is a silent bug that shows up as a repeated side effect.
- **No versioning story.** Renaming an activity re-executes it; changing a result schema kills in-flight runs with a defect.
- **Compensations are not journaled**; they are re-registered by replay and re-run wholesale if a crash interrupts them.
- **Replay re-executes the body on every wake-up**, with one storage round trip per activity; long bodies get quadratic in the number of wait points.
- **Arguments are not part of a step's identity**, so a replayed body that would now call an activity with different inputs gets the old result without complaint.
- **Documentation is source-only**: the `effect.website` documentation site has no workflow or cluster page; the v3 README and the doc comments are the documentation.
- **Still `unstable`** in v4 (`effect/unstable/workflow`), and the April 24, 2026 "This Week in Effect" post still describes `@effect/workflow` as _"currently in alpha"_ ([twie-2026-04-24][twie-2026-04-24]).

## Key design decisions and trade-offs

| Decision                                                                   | Rationale                                                                           | Trade-off                                                                                                 |
| -------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| Workflow body is a plain `Effect`; no DSL or transform                     | Nothing new to learn; every Effect combinator works inside a workflow               | The runtime cannot see, record, or forbid non-durable effects between activities                          |
| Step identity = `name/attempt`, no argument hash                           | Simple, stable across reorders and cosmetic refactors; attempts are explicit        | Two calls with the same name collide; a changed input goes unnoticed                                      |
| Journal = cluster mailbox (`messages` + `replies`)                         | Persistence, dedup, at-least-once delivery, sharding and transactions already exist | The journal is an RPC log, not a readable event history; there is no history-inspection API beyond `poll` |
| Memoization via the storage `UNIQUE (message_id)` and duplicate-reply path | One mechanism serves activities, deferreds, clocks and child workflows              | Every replayed step is a storage round trip                                                               |
| Suspend by interrupting the fiber, resume by re-running                    | No continuation capture; process death and voluntary suspension are the same path   | Full body re-execution on every wake; side effects before a suspension inside an activity repeat          |
| Compensation as `Scope` finalizers                                         | Reuses Effect's resource model; LIFO and cause-aware for free                       | Not durable in their own right; skipped on cluster abandonment; top-level only                            |
| `CaptureDefects` default on                                                | A crash inside a workflow is a journaled answer, not an infinite retry              | A programming error is persisted as the execution's final result until someone resets it                  |
| 60-second in-memory sleep threshold                                        | Short waits do not deserve a clock message and a replay                             | A crash during a 59-second sleep re-sleeps from zero                                                      |

---

## Implications for a durable-execution library

- **Name plus attempt is enough to find a recorded result, and not enough to
  notice that its inputs changed.** Effect proves the first half in production;
  §1 and §2 show the second half is simply unaddressed. A library keying this way
  inherits the blind spot and has to decide separately whether it cares.
- **Compensation belongs on a scope and runs LIFO**, but Effect exposes two traps
  in that design: the finalizers are re-registered by replay rather than
  journaled, and a compensation that has run leaves no record behind. A library
  offering the primitive should record both the registration and the run, or
  accept that a crash mid-rollback cannot be resumed accurately.
- **`Suspended` as a first-class persisted outcome, distinct from failure, is the
  piece most systems omit.** It collapses voluntary waiting, crash recovery and
  operator-driven pausing into one mechanism, and it is what lets a caller poll
  for a definite answer instead of inferring one from absence.
- **`SuspendOnFailure` and `CaptureDefects` are two orthogonal policy switches
  worth copying.** The first turns a failure into a resumable pause; the second
  decides whether a defect is a journaled answer or a lost run. Both are choices
  a library should expose rather than hard-code.
- **Its integrity story is entirely delegated** — a unique message id, an insert
  that does nothing on conflict, a shard lease with a refresh interval, and a
  ten-minute read lease on undelivered messages (§9). That is a clean design when
  a relational store is a given; a library without one must supply the equivalent
  of all four itself.
- **There is no versioning stance at all.** Effect's answer to changed code is
  that names either still match or they do not. For a library whose programs are
  expected to be edited between a crash and its resume, this is the gap to close
  rather than the precedent to follow.
- **Its test oracle transfers directly:** assert the exact set of journal rows
  after each scenario. It is cheap, and unlike a final-state assertion it catches
  both a missing write and a duplicated one.
- **A journal that cannot be read back is a real limitation.** `poll` returns only
  the last result, and there is no history API (§10), so operators fall back to
  querying tables by hand. A log that can be folded is strictly more useful, and
  nothing about the replay model requires giving that up.

---

## Sources

- [`Effect-TS/effect` repository][repo]
- [`@effect/workflow` on npm][npm-workflow]
- [`packages/workflow/README.md` on the `v3` branch (read through the GitHub API at `1af4232fea7bc613e1dc68db9bec7b1f596d9e68`)][v3-readme]
- [`packages/effect/src/unstable/workflow/Workflow.ts`][workflow-ts]
- [`packages/effect/src/unstable/workflow/Activity.ts`][activity-ts]
- [`packages/effect/src/unstable/workflow/WorkflowEngine.ts`][engine-ts]
- [`packages/effect/src/unstable/workflow/DurableClock.ts`][clock-ts]
- [`packages/effect/src/unstable/workflow/DurableDeferred.ts`][deferred-ts]
- [`packages/effect/src/unstable/workflow/DurableQueue.ts`][queue-ts]
- [`packages/effect/src/unstable/workflow/WorkflowProxy.ts`][proxy-ts]
- [`packages/effect/src/unstable/workflow/internal/crypto.ts`][crypto-ts]
- [`packages/effect/src/unstable/cluster/ClusterWorkflowEngine.ts`][cwe-ts]
- [`packages/effect/src/unstable/cluster/SqlMessageStorage.ts`][sql-ts]
- [`packages/effect/src/unstable/cluster/MessageStorage.ts`][storage-ts]
- [`packages/effect/src/unstable/cluster/Envelope.ts`][envelope-ts]
- [`packages/effect/src/unstable/cluster/Runners.ts`][runners-ts]
- [`packages/effect/src/unstable/cluster/ClusterSchema.ts`][clusterschema-ts]
- [`packages/effect/src/unstable/cluster/internal/clusterAbandon.ts`][abandon-ts]
- [`packages/effect/src/unstable/rpc/RpcMessage.ts`][rpcmessage-ts]
- [`packages/effect/src/Scope.ts`][scope-ts]
- [`packages/effect/test/cluster/ClusterWorkflowEngine.test.ts`][cluster-test]
- [`packages/effect/test/unstable/workflow/WorkflowEngine.test.ts`][engine-test]
- [`MIGRATION.md` (v3 to v4: `@effect/cluster` and `@effect/workflow` moved under `effect/unstable/*`)][migration]
- [This Week in Effect, June 27, 2025 (announces durable workflows)][twie-2025-06-27]
- [This Week in Effect, April 24, 2026 (workflow suspension fixes)][twie-2026-04-24]
- Related: [Effect (TypeScript) runtime page][typescript-effect] · [catalog index][index] · [Temporal][temporal]

<!-- References -->

[repo]: https://github.com/Effect-TS/effect
[npm-workflow]: https://www.npmjs.com/package/@effect/workflow
[v3-readme]: https://github.com/Effect-TS/effect/blob/1af4232fea7bc613e1dc68db9bec7b1f596d9e68/packages/workflow/README.md
[workflow-ts]: https://github.com/Effect-TS/effect/blob/657254b8218628b0116497d09aaf783cb88279f3/packages/effect/src/unstable/workflow/Workflow.ts
[activity-ts]: https://github.com/Effect-TS/effect/blob/657254b8218628b0116497d09aaf783cb88279f3/packages/effect/src/unstable/workflow/Activity.ts
[engine-ts]: https://github.com/Effect-TS/effect/blob/657254b8218628b0116497d09aaf783cb88279f3/packages/effect/src/unstable/workflow/WorkflowEngine.ts
[clock-ts]: https://github.com/Effect-TS/effect/blob/657254b8218628b0116497d09aaf783cb88279f3/packages/effect/src/unstable/workflow/DurableClock.ts
[deferred-ts]: https://github.com/Effect-TS/effect/blob/657254b8218628b0116497d09aaf783cb88279f3/packages/effect/src/unstable/workflow/DurableDeferred.ts
[queue-ts]: https://github.com/Effect-TS/effect/blob/657254b8218628b0116497d09aaf783cb88279f3/packages/effect/src/unstable/workflow/DurableQueue.ts
[proxy-ts]: https://github.com/Effect-TS/effect/blob/657254b8218628b0116497d09aaf783cb88279f3/packages/effect/src/unstable/workflow/WorkflowProxy.ts
[crypto-ts]: https://github.com/Effect-TS/effect/blob/657254b8218628b0116497d09aaf783cb88279f3/packages/effect/src/unstable/workflow/internal/crypto.ts
[cwe-ts]: https://github.com/Effect-TS/effect/blob/657254b8218628b0116497d09aaf783cb88279f3/packages/effect/src/unstable/cluster/ClusterWorkflowEngine.ts
[sql-ts]: https://github.com/Effect-TS/effect/blob/657254b8218628b0116497d09aaf783cb88279f3/packages/effect/src/unstable/cluster/SqlMessageStorage.ts
[storage-ts]: https://github.com/Effect-TS/effect/blob/657254b8218628b0116497d09aaf783cb88279f3/packages/effect/src/unstable/cluster/MessageStorage.ts
[envelope-ts]: https://github.com/Effect-TS/effect/blob/657254b8218628b0116497d09aaf783cb88279f3/packages/effect/src/unstable/cluster/Envelope.ts
[runners-ts]: https://github.com/Effect-TS/effect/blob/657254b8218628b0116497d09aaf783cb88279f3/packages/effect/src/unstable/cluster/Runners.ts
[clusterschema-ts]: https://github.com/Effect-TS/effect/blob/657254b8218628b0116497d09aaf783cb88279f3/packages/effect/src/unstable/cluster/ClusterSchema.ts
[abandon-ts]: https://github.com/Effect-TS/effect/blob/657254b8218628b0116497d09aaf783cb88279f3/packages/effect/src/unstable/cluster/internal/clusterAbandon.ts
[rpcmessage-ts]: https://github.com/Effect-TS/effect/blob/657254b8218628b0116497d09aaf783cb88279f3/packages/effect/src/unstable/rpc/RpcMessage.ts
[scope-ts]: https://github.com/Effect-TS/effect/blob/657254b8218628b0116497d09aaf783cb88279f3/packages/effect/src/Scope.ts
[cluster-test]: https://github.com/Effect-TS/effect/blob/657254b8218628b0116497d09aaf783cb88279f3/packages/effect/test/cluster/ClusterWorkflowEngine.test.ts
[engine-test]: https://github.com/Effect-TS/effect/blob/657254b8218628b0116497d09aaf783cb88279f3/packages/effect/test/unstable/workflow/WorkflowEngine.test.ts
[migration]: https://github.com/Effect-TS/effect/blob/657254b8218628b0116497d09aaf783cb88279f3/MIGRATION.md
[twie-2025-06-27]: https://effect.website/blog/this-week-in-effect/2025/06/27/
[twie-2026-04-24]: https://effect.website/blog/this-week-in-effect/2026/04/24/
[typescript-effect]: ../typescript-effect.md
[index]: ./index.md
[temporal]: ./temporal.md
[clustermetrics-ts]: https://github.com/Effect-TS/effect/blob/657254b8218628b0116497d09aaf783cb88279f3/packages/effect/src/unstable/cluster/ClusterMetrics.ts
[runnerstorage-ts]: https://github.com/Effect-TS/effect/blob/657254b8218628b0116497d09aaf783cb88279f3/packages/effect/src/unstable/cluster/RunnerStorage.ts
[sharding-ts]: https://github.com/Effect-TS/effect/blob/657254b8218628b0116497d09aaf783cb88279f3/packages/effect/src/unstable/cluster/Sharding.ts
[shardingconfig-ts]: https://github.com/Effect-TS/effect/blob/657254b8218628b0116497d09aaf783cb88279f3/packages/effect/src/unstable/cluster/ShardingConfig.ts
[snowflake-ts]: https://github.com/Effect-TS/effect/blob/657254b8218628b0116497d09aaf783cb88279f3/packages/effect/src/unstable/cluster/Snowflake.ts
[sqlrunnerstorage-ts]: https://github.com/Effect-TS/effect/blob/657254b8218628b0116497d09aaf783cb88279f3/packages/effect/src/unstable/cluster/SqlRunnerStorage.ts
