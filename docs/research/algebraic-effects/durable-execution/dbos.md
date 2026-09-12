# DBOS Transact (TypeScript)

A durable-execution library, not a service: workflows are ordinary async TypeScript functions whose step outcomes are checkpointed row-by-row into a Postgres "system database", and recovery is re-running the function against those rows.

| Field             | Value                                                                                                                                                                                                           |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | TypeScript (Node.js ≥ 20); sibling SDKs for Python, Go and Java share the schema                                                                                                                                |
| License           | MIT ([`LICENSE`][license])                                                                                                                                                                                      |
| Repository        | [dbos-inc/dbos-transact-ts][repo]                                                                                                                                                                               |
| Documentation     | [docs.dbos.dev][docs] (source: [dbos-inc/dbos-docs][docs-repo])                                                                                                                                                 |
| Category          | durable-execution SDK                                                                                                                                                                                           |
| Persistence model | replay (re-execute the function; each recorded step short-circuits)                                                                                                                                             |
| Journal store     | Postgres tables in a `dbos` schema: `workflow_status`, `operation_outputs`, `notifications`, `workflow_events` (+ `workflow_events_history`, `streams`, `application_versions`, `queues`, `workflow_schedules`) |
| Latest release    | `@dbos-inc/dbos-sdk` `4.27.6` on npm ([registry][npm]); `main` is at `4.28-preview` ([`version.json`][version-json])                                                                                            |
| Local clone       | `$REPOS/dbos-transact-ts` at `8495c0060e55d303a38b030900bb1f0c9429f611`; `$REPOS/dbos-docs` at `28245d243740b0bfd684794476c31f9a62dbd6a2`                                                                       |

**Last reviewed:** September 12, 2026.

---

## Overview

### What it solves

DBOS Transact answers the same question as [Temporal][temporal] and [Restate][restate] — how does a long-running program survive the process that runs it dying — but with no server, no event-history protocol and no sandboxed replay: the only infrastructure is a Postgres database, and the only mechanism is a table with one row per completed step. The [architecture page][arch-site] states the overhead as "one database write per step (to checkpoint the step's outcome) plus two additional database writes per workflow (one at the beginning to checkpoint workflow inputs, one at the end to checkpoint the workflow outcome)" ([`docs/architecture.md`][arch]).

The project is the productised remainder of the DBOS research programme at MIT and Stanford: the PVLDB 2022 paper _DBOS: A DBMS-oriented Operating System_ (Skiadopoulos, Li, Kraft, Kaffes, … Stonebraker, Suresh, Zaharia) argues that "a distributed transactional DBMS should be the basis for a scalable cluster OS" ([paper][vldb-paper]); the library keeps the "put every piece of state in the database" thesis and drops the operating system.

### Design philosophy

The [workflow tutorial][wf-tutorial-site] states the reliability contract as three guarantees ([`workflow-tutorial.md`][wf-tutorial]):

> 1. Workflows always run to completion. If a DBOS process is interrupted while executing a workflow and restarts, it resumes the workflow from the last completed step.
> 2. Steps are tried _at least once_ but are never re-executed after they complete. If a failure occurs inside a step, the step may be retried, but once a step has completed (returned a value or thrown an exception to the calling workflow), it will never be re-executed.
> 3. Transactions commit _exactly once_. Once a workflow commits a transaction, it will never retry that transaction.

And the recovery procedure is described in the same plain terms on the [architecture page][arch-site] ([`docs/architecture.md`][arch]):

> Next, DBOS restarts each interrupted workflow by calling it with its checkpointed inputs. As the workflow re-executes, it checks before each step if that step's output is checkpointed in Postgres. If there is a checkpoint, the step returns the checkpointed output instead of executing.
>
> Eventually, the recovered workflow reaches a step with **no checkpoint**. This marks the point where the original execution failed. The recovered workflow executes that step normally and proceeds from there, thus **resuming from the last completed step.**

Everything else — determinism, versioning, messaging, queues — is a consequence of "the checkpoint is a table row keyed by position".

## How it works

### User-facing API

A workflow is registered either by decorator or by wrapping a plain function; steps are registered the same way or invoked inline with `DBOS.runStep` ([`workflow-tutorial.md`][wf-tutorial]):

```ts
async function workflowFunction() {
  await DBOS.runStep(() => stepOne(), { name: 'stepOne' });
  await DBOS.runStep(() => stepTwo(), { name: 'stepTwo' });
}
const workflow = DBOS.registerWorkflow(workflowFunction);

export class Example {
  @DBOS.step()
  static async stepOne() {
    /* … */
  }

  @DBOS.workflow()
  static async exampleWorkflow() {
    await Example.stepOne();
  }
}
```

`DBOS.workflow()` and `DBOS.registerWorkflow` both end in `wrapDBOSFunctionAndRegister…` plus `#getWorkflowInvoker`, so the decorator and the function form are one registration path ([`src/dbos.ts`][dbos-ts]). `DBOS.step()` records a `StepConfig` on the registration and wraps the method so that a call from inside a workflow goes through `callStepFunction`, and a call from inside another step just runs the function ([`src/dbos.ts`][dbos-ts], [`src/step.ts`][step-ts]). Transactions are a datasource-specific kind of step whose user SQL and checkpoint row commit in one Postgres transaction: `runTransactionalStep` opens `BEGIN ISOLATION LEVEL READ COMMITTED`, checks for an existing row, runs the callback on the same client, inserts the `operation_outputs` row, and commits ([`src/system_database.ts`][sysdb], [`transaction-tutorial.md`][tx-tutorial]).

Starting a workflow in the background returns a handle; passing `workflowID` makes the ID the idempotency key ([`workflow-tutorial.md`][wf-tutorial]):

```ts
const handle = await DBOS.startWorkflow(Example, {
  workflowID: myID,
}).exampleWorkflow('one', 'two');
const result = await handle.getResult();
```

The other durable primitives are `DBOS.sleep(ms)`, `DBOS.send(destinationID, message, topic?)` / `DBOS.recv(topic?, timeoutSeconds?)`, and `DBOS.setEvent(key, value)` / `DBOS.getEvent(workflowID, key, timeoutSeconds?)` ([`workflow-communication.md`][wf-comm]). Each is internally a step with a reserved name — `DBOS.sleep`, `DBOS.send`, `DBOS.recv`, `DBOS.setEvent`, `DBOS.getEvent` — recorded in the same table as user steps ([`src/system_database.ts`][sysdb]).

### The system-database schema

The schema is created by an in-code migration list, not SQL files. The first table migration is ([`src/sysdb_migrations/internal/migrations.ts`][migrations]):

```ts
`create table "${schemaName}"."operation_outputs" ("workflow_uuid" text not null, "function_id" int4 not null, "output" text, "error" text, constraint "operation_outputs_pkey" primary key ("workflow_uuid", "function_id"))`,
`create table "${schemaName}"."workflow_status" ("workflow_uuid" text, "status" text, "name" text, "authenticated_user" text, "assumed_role" text, "authenticated_roles" text, "request" text, "output" text, "error" text, "executor_id" text, constraint "workflow_status_pkey" primary key ("workflow_uuid"))`,
`create table "${schemaName}"."notifications" ("destination_uuid" text not null, "topic" text, "message" text not null, "created_at_epoch_ms" bigint not null default (EXTRACT(EPOCH FROM now())*1000)::bigint)`,
`create table "${schemaName}"."workflow_events" ("workflow_uuid" text not null, "key" text not null, "value" text not null, constraint "workflow_events_pkey" primary key ("workflow_uuid", "key"))`,
```

Later migrations add the columns that matter for this survey: `workflow_status.application_version` and `application_id` (`20240516004341_application_version`), `recovery_attempts` (`20240621000000_workflow_tries`), `inputs` (`20252523000000_consolidate_inputs`), `workflow_timeout_ms`/`workflow_deadline_epoch_ms`, `forked_from`, `parent_workflow_id`, `serialization`, `owner_xid`, `completed_at`; and on `operation_outputs`: `function_name` (`20250312171547_function_name_op_outputs`), `child_workflow_id` (`20250319190617_add_childid_opoutputs`), `started_at_epoch_ms`/`completed_at_epoch_ms`, `serialization`, `application_name`, `retention_timestamp` ([`migrations.ts`][migrations]). `notifications` gains `message_uuid` (primary key) and `consumed`; `workflow_events_history` records every `setEvent` with its `function_id` so a fork can replay the value as it was ([`migrations.ts`][migrations]).

The [system-tables reference][systables-site] documents the resulting columns ([`system-tables.md`][systables]). The two that carry the whole design:

| Table               | Column                | Documented meaning                                                                                                           |
| ------------------- | --------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `workflow_status`   | `status`              | One of `PENDING`, `SUCCESS`, `ERROR`, `MAX_RECOVERY_ATTEMPTS_EXCEEDED`, `ENQUEUED`, `DELAYED`, or `CANCELLED`                |
| `workflow_status`   | `executor_id`         | The ID of the executor that ran this workflow                                                                                |
| `workflow_status`   | `application_version` | The application version of this workflow code                                                                                |
| `operation_outputs` | `function_id`         | "The monotonically increasing ID of the step (starts from 0) within the workflow, based on the order in which steps execute" |
| `operation_outputs` | `function_name`       | The name of the step                                                                                                         |
| `operation_outputs` | `output` / `error`    | The serialized step output, or the serialized error thrown by the step                                                       |

There is no event log. A workflow's history _is_ the set of `operation_outputs` rows with its `workflow_uuid`, ordered by `function_id`, plus one `workflow_status` row.

### The replay check

Every durable primitive reserves its position first, synchronously, then consults the table. The counter lives in the per-workflow context ([`src/context.ts`][context]):

```ts
export function functionIDGetIncrementForCtx(pctx: DBOSLocalCtx): number {
  if (!isInWorkflowCtx(pctx))
    throw new DBOSInvalidWorkflowTransitionError(
      `Attempt to get a call ID number in a workflow that is already in a call`,
    );
  if (pctx.curWFFunctionId === undefined) pctx.curWFFunctionId = 0;
  return pctx.curWFFunctionId++;
}
```

`callStepFunction` then does the lookup that makes replay work ([`src/dbos-executor.ts`][executor]):

```ts
// Intentionally advance the function ID before any awaits, then work with a copy of the context.
const funcID = functionIDGetIncrement();
// …
// Check if this execution previously happened, returning its original result if it did.
const checkr = await this.systemDatabase
  .getOperationResultAndThrowIfCancelled(wfid, funcID)
  .catch(endSpanAndRethrow);
if (checkr) {
  if (checkr.functionName !== stepFnName) {
    endSpanAndRethrow(
      new DBOSUnexpectedStepError(
        wfid,
        funcID,
        stepFnName,
        checkr.functionName ?? '?',
      ),
    );
  }
  const check = await DBOSExecutor.reviveResultOrError<R>(
    checkr,
    this.serializer,
  ).catch(endSpanAndRethrow);
  span.setAttribute('cached', true);
  // …
  return check;
}
```

The lookup is a single `SELECT output, error, child_workflow_id, function_name, serialization FROM operation_outputs WHERE workflow_uuid=$1 AND function_id=$2` ([`src/system_database.ts`][sysdb]). A recorded error is re-thrown, a recorded output is returned; either way the step body does not run. The record is an `INSERT … ON CONFLICT (workflow_uuid, function_id) DO UPDATE SET completed_at_epoch_ms = operation_outputs.completed_at_epoch_ms RETURNING completed_at_epoch_ms` — the no-op update makes `RETURNING` yield the _existing_ row's timestamp, so a writer that did not win sees a value different from the one it just tried to write and throws `DBOSWorkflowConflictError` ([`src/system_database.ts`][sysdb]). Winning the insert also re-stamps `workflow_status.executor_id` to the current executor, because "Winning the checkpoint proves this executor is advancing the workflow" ([`src/system_database.ts`][sysdb]).

Sleep records its wake-up _deadline_ as the step output: `#durableSleep` computes `endTimeMs`, stores it under the `DBOS.sleep` name, and on replay returns the stored value so the wait is measured against the original deadline ([`src/system_database.ts`][sysdb]). `recv` and `getEvent` use the same helper to store their timeout deadline in a second reserved position (`timeoutFunctionID`), then poll; when a message or event arrives, the value is recorded under the primary position, so a replay returns the exact value first observed "even if the event is later updated" ([`workflow-communication.md`][wf-comm], [`src/system_database.ts`][sysdb]). `send` and `setEvent` run their insert and their checkpoint in one Postgres transaction via `#runAndRecordResult`, and `send` from outside a workflow accepts an `idempotencyKey` that becomes the `message_uuid` ([`src/system_database.ts`][sysdb]).

### Recovery on startup

`DBOSExecutor.init` ends with `await this.recoverPendingWorkflows([this.executorID])` ([`src/dbos-executor.ts`][executor]). That runs one `UPDATE` ([`src/system_database.ts`][sysdb]):

```ts
`UPDATE "${this.schemaName}".workflow_status
 SET started_at_epoch_ms = NULL,
     status = $1,
     updated_at = (EXTRACT(EPOCH FROM now()) * 1000)::bigint,
     queue_name = COALESCE(queue_name, $2)
 WHERE status = $3
   AND executor_id = $4
   AND application_version = $5
   AND ${scope}
 RETURNING workflow_uuid`;
```

i.e. every `PENDING` row owned by this executor, this application and this application version is flipped back to `ENQUEUED` on an internal recovery queue, and the queue runner re-invokes the workflow function with its stored `inputs`. The [recovery page][recovery-site] says it in one sentence: "each time you restart your application's process, DBOS recovers all workflows that were executing before the restart (all `PENDING` workflows)" ([`workflow-recovery.md`][recovery]). In a fleet, each process gets an executor ID and only recovers its own rows; DBOS Conductor (the hosted control plane) reassigns a dead executor's rows to a live one ([`workflow-recovery.md`][recovery]).

Workflows that keep failing during recovery are dead-lettered: `recovery_attempts` is counted on every claim and a row whose attempts exceed `maxRecoveryAttempts` moves to `MAX_RECOVERY_ATTEMPTS_EXCEEDED` ([`src/dbos-executor.ts`][executor]).

## Analysis

### 1. Step identity and replay matching

Identity is **position**: the `function_id` counter, reserved synchronously before the first `await` of every durable call, is the primary key together with `workflow_uuid` ([`src/context.ts`][context], [`src/dbos-executor.ts`][executor]). Matching is by position with a **name check**: if the row at that position carries a different `function_name`, `DBOSUnexpectedStepError` is thrown with the message "During execution of workflow … step …, function … was recorded when … was expected. Check that your workflow is deterministic." ([`src/error.ts`][error]). Arguments are not part of the key and not compared; a step called with different inputs at the same position replays the old output silently. Child workflow starts and `getWorkflowStatus` calls occupy positions too (the child row stores `child_workflow_id`), so `startWorkflow` from inside a workflow is itself idempotent ([`src/dbos-executor.ts`][executor]).

### 2. Journal versus world

The journal wins, always, and there is no disagreement detector at the step level. A recorded row is returned without re-executing anything; an observation of the world (a query, a file read, `Date.now()`) is supposed to live in a step precisely so that its _recorded_ value is what replay sees ([`docs/architecture.md`][arch]). The only "world" DBOS checks is the journal's own consistency under concurrent executors: the [concurrent-executions page][concurrent-site] explains that when a zombie executor and a recovering one both run the same workflow, "steps get at-least-once guarantees and workflow outcomes are persisted exactly-once", and a run that loses a checkpoint race is **parked** — "it waits for the workflow's recorded outcome to become visible in the database, then delivers that recorded outcome through its own handle" ([`concurrent-executions.md`][concurrent]). The same parking applies to the terminal write: if `recordWorkflowOutput` finds the row no longer `PENDING`, the run adopts whatever outcome is recorded ([`src/dbos-executor.ts`][executor]).

What DBOS offers instead of reconciliation is manual intervention: `DBOS.forkWorkflow` copies a workflow's `operation_outputs` rows up to a chosen step into a fresh `workflow_uuid` (recorded in `forked_from`) and runs the new copy from there, so an operator can "recover from outages in downstream services (by forking from the step that failed after the outage is resolved)" ([`workflow-management.md`][wf-mgmt], [`src/system_database.ts`][sysdb]).

### 3. Determinism enforcement

By discipline, with a runtime tripwire. The [tutorial][wf-tutorial-site] states the rule verbatim ([`workflow-tutorial.md`][wf-tutorial]):

> However, a workflow function must be **deterministic**: if called multiple times with the same inputs, it should invoke the same steps with the same inputs in the same order (given the same return values from those steps). If you need to perform a non-deterministic operation like accessing the database, calling a third-party API, generating a random number, or getting the local time, you shouldn't do it directly in a workflow function. Instead, you should do all non-deterministic operations in steps.

Nothing in the language or runtime prevents `Math.random()` in a workflow body; the only enforcement is the `function_name` comparison at each position, which catches a _different step_ at a position, not a different argument, a skipped branch that happens to align, or a non-step side effect ([`src/error.ts`][error]). The runtime does forbid some structural mistakes eagerly: starting a workflow from a step, calling `runStep` or `DBOS.sleep` inside a transaction, and requesting a function ID outside a workflow all throw `DBOSInvalidWorkflowTransitionError` ([`src/dbos.ts`][dbos-ts], [`src/context.ts`][context]).

### 4. Compensation and failure handling

**There is no compensation mechanism.** Neither the source tree nor the documentation mentions sagas, compensating steps or rollback of completed steps; the words do not occur outside two comments about swallowing a SQL `ROLLBACK` failure ([`src/system_database.ts`][sysdb]). Failure handling is layered as:

- **Step retries**: `StepConfig` has `retriesAllowed` (default `false`), `intervalSeconds` (1), `maxAttempts` (3), `backoffRate` (2), `shouldRetry` and `timeoutMS`; the retry loop sleeps `intervalSeconds`, multiplies by `backoffRate`, caps at one hour, and on exhaustion records a `DBOSMaxStepRetriesError` _as the step's outcome_ ([`src/step.ts`][step-ts], [`src/dbos-executor.ts`][executor], [`step-tutorial.md`][step-tutorial]).
- **Recorded errors replay**: a step that threw has its error serialised into `operation_outputs.error`; replay re-throws it rather than retrying ([`src/dbos-executor.ts`][executor]).
- **Workflow errors terminate**: "If an exception is thrown from a workflow, the workflow **terminates** — DBOS records the exception, sets the workflow status to `ERROR`, and **does not recover the workflow**. This is because uncaught exceptions are assumed to be nonrecoverable." ([`workflow-tutorial.md`][wf-tutorial]).
- **Cancellation** is cooperative: `checkIfCanceled` runs before every step and before every retry attempt, and a `CANCELLED` status throws `DBOSWorkflowCancelledError` at the next step boundary ([`src/system_database.ts`][sysdb], [`src/dbos-executor.ts`][executor]).

Undoing work is therefore ordinary `try`/`catch` in the workflow body calling ordinary steps — the checkout example's `undoSubtractInventory()` is a plain step in the else-branch ([`testing.md`][testing]).

### 5. Versioning against old histories

Two mechanisms, both documented on the [upgrading page][upgrading-site] ([`upgrading-workflows.md`][upgrading]).

**Versioning.** Every `workflow_status` row is stamped with `application_version` at start; recovery filters on it (`AND application_version = $5` above). The version defaults to an MD5 over the _source text_ of every registered workflow function, sorted, plus the DBOS version and app name — "if the app's workflows are updated (which would break recovery), its version changes" ([`src/dbos-executor.ts`][executor]) — or is pinned with `applicationVersion` in config. Old-version rows are simply not recovered by new code; the recommended deployment is blue-green, with `DBOS.getLatestApplicationVersion` / `setLatestApplicationVersion` steering enqueued work and `application_versions` recording what exists ([`upgrading-workflows.md`][upgrading], [`migrations.ts`][migrations]).

**Patching.** `DBOS.patch('name')` reserves a position and inserts a marker row named `DBOS.patch-name`; "`DBOS.patch()` returns `true` for new calls (those executing after the breaking change) and `false` for old calls (those that executed before the breaking change)" — an old history has a real step at that position, so the marker insert finds a non-matching row and the patch reports `false` ([`upgrading-workflows.md`][upgrading], [`src/system_database.ts`][sysdb]). `deprecatePatch` stops inserting markers but tolerates existing ones, so the branch can be removed once old workflows drain. A patch mistake surfaces as the same `DBOSUnexpectedStepError`, with a second sentence about patches ([`src/error.ts`][error]). Patching must be enabled with `enablePatching: true` ([`upgrading-workflows.md`][upgrading]).

### 6. Concurrency under replay

Because identity is a counter, concurrency is legal only when the counter is reserved in a deterministic order. The counter is bumped **synchronously before the first `await`** of each step, so `Promise.allSettled([step1(), step2(), step3()])` assigns IDs in source order regardless of completion order; the tutorial permits exactly that and forbids racing sub-sequences ([`workflow-tutorial.md`][wf-tutorial], [`src/dbos-executor.ts`][executor]):

> Here, `step2` and `step4` may be started in either order since their execution depends on the relative time taken by `step1` and `step3`.

The docs also warn off `Promise.all` because a rejected sibling can leave an unhandled rejection that crashes Node, and suggest child workflows (`startWorkflow`, awaited via handles) for concurrent _sequences_; each child has its own counter and its own rows, and the parent's row for the start records `child_workflow_id` ([`workflow-tutorial.md`][wf-tutorial], [`src/dbos-executor.ts`][executor]). Queues add flow control (worker/global concurrency, rate limits, partitions, deduplication IDs, priorities) over the same `workflow_status` table ([`workflow-tutorial.md`][wf-tutorial]).

### 7. Replay or snapshot

Pure replay with per-step memoisation, and no snapshotting of program state at all. What is stored is inputs, per-step outputs and the terminal output; the stack is reconstructed by re-running the function ([`docs/architecture.md`][arch]). Costs: one Postgres round trip per step boundary on the happy path (`SELECT` then `INSERT`, or one transaction for transactional steps), and on recovery one `SELECT` per already-completed step. Rules out: nondeterministic control flow, and steps whose outputs are large — the docs ask that "steps return pointers" to blobs because "the sizes of its writes are determined by the sizes of your inputs and outputs" ([`docs/architecture.md`][arch]). Rules in: an operator can fork from any step because the rows _are_ the state, and no in-memory checkpoint format has to be versioned.

### 8. Testing

Two levels, documented on the [testing page][testing-site] ([`testing.md`][testing]):

- **Unit**: mock the whole `DBOS` module — "It's important to mock `DBOS.registerWorkflow` to directly return the workflow function instead of wrapping it with durable workflow code" — and assert on step-mock call counts; no Postgres.
- **Integration**: drop and recreate the system database in `beforeEach`, `DBOS.setConfig`, `DBOS.launch()`, run real workflows, `DBOS.shutdown()` in `afterEach`.

The library's own suite tests durability more directly. `oaoo.test.ts` runs a workflow twice under the same `workflowID` and asserts a step counter stayed at one ([`tests/oaoo.test.ts`][oaoo-test]). `recovery.test.ts` completes a workflow, resets its row to `PENDING` with `setWfAndChildrenToPending`, calls `recoverPendingWorkflows()` and checks that only un-checkpointed steps re-run and that `executor_id` is re-stamped ([`tests/recovery.test.ts`][recovery-test], [`tests/helpers.ts`][helpers]). `appversion.test.ts` restarts DBOS with a _different_ workflow class and asserts the pending row is not recovered ([`tests/appversion.test.ts`][appversion-test]). `patching.test.ts` covers patch-at-first and patch-at-last step; `concurrency.test.ts` runs the same step, transaction and `recv` concurrently under one ID ([`tests/patching.test.ts`][patching-test], [`tests/concurrency.test.ts`][concurrency-test]). Crash points are injected through `debugTriggerPoint(name)`, a named hook the system database calls at `DEBUG_TRIGGER_STEP_COMMIT` and which a test can make sleep, block or call back ([`src/debugpoint.ts`][debugpoint], [`src/system_database.ts`][sysdb]). A separate `chaos-tests` suite runs workflows, `recv`, events, schedules and queues while a `PostgresChaosMonkey` disrupts the database ([`chaos-tests/workflows.test.ts`][chaos]). There is no deterministic-simulation harness and no "crash at every step index" sweep; coverage of crash positions is by chosen debug points.

### 9. Journal integrity and the single writer

The journal is a set of Postgres rows, so torn writes, checksums and partial records are Postgres's problem, not the library's: a checkpoint is either a committed row or nothing. What DBOS engineers on top of that is _ownership_, at three grains.

**Per step, the primary key is the guard.** The checkpoint insert is `INSERT … ON CONFLICT (workflow_uuid, function_id) DO UPDATE SET completed_at_epoch_ms = operation_outputs.completed_at_epoch_ms RETURNING completed_at_epoch_ms`; because the update is a no-op, `RETURNING` yields the timestamp already on disk, and a writer that sees a value other than the one it just supplied knows another execution got there first and throws `DBOSWorkflowConflictError` ([`src/system_database.ts`][sysdb]). The guard is the constraint itself, distinct from any lease. There is no expected-length or expected-version check on the history as a whole; each position is guarded independently, which is enough because positions are assigned deterministically. Duplicate appends are idempotent on `(workflow_uuid, function_id)`, and the docs are explicit that this is detection, not prevention: "steps get at-least-once guarantees and workflow outcomes are persisted exactly-once" ([`concurrent-executions.md`][concurrent]).

**Per workflow, the `owner_xid` column decides who runs.** `insertWorkflowStatus` upserts the status row with the caller's transaction id; `#initWorkflowStatusInternal` then compares the row's `owner_xid` to its own and returns `shouldExecuteOnThisExecutor: ownerXid === resRow.owner_xid`, so of two concurrent `startWorkflow` calls with the same ID only the one whose upsert won executes and the other attaches to the handle ([`src/system_database.ts`][sysdb]). The same routine rejects a re-start with a different `name`, `class_name` or `config_name` with `DBOSConflictingWorkflowError` — the ID is bound to the function that first claimed it ([`src/system_database.ts`][sysdb]). The terminal write is guarded again: `#recordWorkflowOutcome` updates only a `PENDING` row, and the comment states the rule and its limit — "a run owns its workflow's outcome exactly as long as the row says that run is what the workflow is doing. (Note: this does not prevent a write when another concurrent execution is already running and the status is PENDING. However, both executions should be deterministic and idempotent.)" ([`src/system_database.ts`][sysdb]). Within one process, `runningWorkflowMap` refuses a second in-memory execution of the same ID ([`src/system_database.ts`][sysdb]).

**Writer identity is recorded, and partly checked.** `workflow_status.executor_id` names the executor that last advanced the workflow and is re-stamped by whichever executor wins a step checkpoint; `operation_outputs.application_name` names the application ([`src/system_database.ts`][sysdb], [`system-tables.md`][systables]). Recovery filters on `executor_id`, `application_version` and `application_name`, so a stale writer's rows are simply not picked up by a peer ([`src/system_database.ts`][sysdb]). Nothing checks a writer id on the replay read of a step row; the row is trusted because the key matched.

**Write-ahead is selective.** An ordinary step records its result _after_ the effect, with nothing on disk while it runs; the only "intent" is the `PENDING` status row plus the recorded inputs. Two exceptions record before the effect: `#durableSleep` writes the deadline before waiting, and a child-workflow start inserts the child's status row and then the parent's `child_workflow_id` row, both before the child runs ([`src/system_database.ts`][sysdb], [`src/dbos-executor.ts`][executor]). Atomic multi-record appends exist where they matter: `send` and `setEvent` insert their payload row and their checkpoint row in one transaction via `#runAndRecordResult`, `recv` marks the message `consumed` and checkpoints in one transaction, and a transactional step commits user SQL and its checkpoint together ([`src/system_database.ts`][sysdb]).

### 10. Operator recovery and intervention

This is DBOS's richest dimension: the history is a table, so intervention is `UPDATE` and `INSERT`, and every operation is exposed three ways — as `DBOS.*` methods, as `npx dbos workflow {list,get,steps,cancel,resume,fork,queue list}` CLI commands, and as HTTP routes on the admin server (`/workflows`, `/workflows/:id`, `/workflows/:id/steps`, `/cancel`, `/resume`, `/restart`, `/fork`) that the hosted Conductor console drives ([`workflow-management.md`][wf-mgmt], [`cli.md`][cli], [`src/adminserver.ts`][adminserver]).

**Resume from a chosen point.** `DBOS.forkWorkflow(workflowID, startStep, options)` starts "a new execution of a workflow from a specific step": `bulkForkWorkflows` copies the `operation_outputs` rows with `function_id` below `startStep` (and the matching `workflow_events_history` values) under a fresh `workflow_uuid`, records `forked_from` on the child and `was_forked_from` on the parent, and runs the copy ([`methods.md`][methods], [`src/system_database.ts`][sysdb]). Options let the fork run on a different `applicationVersion` — "useful for 'patching' workflows that failed due to a bug in the previous application version" — be enqueued instead of started, and substitute `replacementChildren` so a forked parent re-attaches to forked children ([`methods.md`][methods]). The docs frame the use case as "recovering from outages in downstream services (by forking from the step that failed after the outage is resolved)" ([`workflow-management.md`][wf-mgmt]). The original run is untouched; the fork is a new row with a back-pointer.

**Resume from where it stopped.** `DBOS.resumeWorkflow` sets a non-terminal row back to `ENQUEUED`, zeroes `recovery_attempts`, and so re-admits a `CANCELLED` or `MAX_RECOVERY_ATTEMPTS_EXCEEDED` workflow, or pulls an enqueued one ahead of its queue ([`src/system_database.ts`][sysdb], [`workflow-management.md`][wf-mgmt]).

**Editing a recorded result is not supported.** No API rewrites an `operation_outputs` row; the documented path for "the step recorded the wrong thing" is fork from that step under fixed code ([`methods.md`][methods]). An operator with SQL access can of course edit the table, but nothing in the library models it.

**Cancellation is a status, distinct from failure.** `cancelWorkflows` sets `status = 'CANCELLED'` and clears queue fields on any non-terminal row; the running execution notices at its next step boundary, because `checkIfCanceled` runs before every step and every retry attempt, and throws `DBOSWorkflowCancelledError` ([`src/system_database.ts`][sysdb], [`src/dbos-executor.ts`][executor]). An in-flight step is not interrupted: "cancelling it preempts its execution (interrupting it at the beginning of its next step)" ([`workflow-management.md`][wf-mgmt]). A workflow timeout is the same mechanism with a durable deadline, and cancels children too ([`workflow-tutorial.md`][wf-tutorial]). There is no pause state; the nearest is `DELAYED`, a queue state for a workflow not yet eligible to run, adjustable with a delay-until timestamp ([`src/dbos.ts`][dbos-ts]).

**Inspection.** `listWorkflows` filters by status, name, version, time range, queue and GIN-indexed `attributes`; `listWorkflowSteps` returns the `operation_outputs` rows with outputs and errors deserialised; the console draws them as a trace timeline and can export a workflow, with children, into another application's system database "to examine and (using fork) reproduce a bug that originally occured in production" ([`workflow-management.md`][wf-mgmt], [`production/workflow-management.md`][prod-mgmt]). `workflow_events` and `streams` give a workflow a way to publish its own status for such a UI ([`workflow-communication.md`][wf-comm]).

**Dead-lettering.** A workflow recovered more than `maxRecoveryAttempts` times is moved to `MAX_RECOVERY_ATTEMPTS_EXCEEDED` and stops being recovered; its handle rejects with `DBOSAwaitedWorkflowExceededMaxRecoveryAttempts`, and `resumeWorkflow` is the way out ([`src/dbos-executor.ts`][executor], [`tests/recovery.test.ts`][recovery-test]).

**Traceability of intervention is partial.** Fork leaves `forked_from`/`was_forked_from`; cancel and resume mutate `status`, `updated_at` and `recovery_attempts` in place, so the fact of a resume is visible only as a reset counter and a newer timestamp, not as a history entry ([`src/system_database.ts`][sysdb]).

### 11. Suspension and external input

The waiting primitives are `DBOS.sleep`, `DBOS.recv` (messages by workflow ID and optional topic), `DBOS.getEvent` (key-value events published by another workflow), child completion via `handle.getResult()`, and `readStream` for a producer's incremental output ([`workflow-communication.md`][wf-comm]). Each is a step: sleep records its deadline, `recv`/`getEvent` reserve two positions (value and timeout deadline), and an in-workflow `getResult` is recorded under `DBOS.getResult` so the parent replays the child's outcome without re-awaiting ([`src/system_database.ts`][sysdb], [`src/workflow.ts`][workflow-ts]).

**Waiting holds the process.** A waiting workflow is a live async function in a live Node process: `recv` registers a callback with the `LISTEN/NOTIFY` listener (a trigger on `notifications` fires `pg_notify` from inside the inserting transaction "so recv is never woken before its row commits"), then loops on `Promise.race` between that callback and a poll every `dbPollingIntervalEventMs` (10 s), falling back to polling alone where `LISTEN/NOTIFY` is unavailable ([`src/system_database.ts`][sysdb], [`migrations.ts`][migrations]). There is no threshold past which the runtime unloads the workflow; suspension across a process boundary happens only because a restart re-runs the function and the recorded deadline makes the resumed wait honour the original schedule ([`src/system_database.ts`][sysdb]). The human-in-the-loop page presents this as the design: "Because the workflow's progress is checkpointed and both the deadline and notification are stored in your database, this can safely wait for a long time" ([`hitl.md`][hitl]).

**"Suspended" is not a persisted state.** A waiting workflow is `PENDING`, indistinguishable in `workflow_status` from one mid-step; the documented way to expose "waiting for approval" is for the workflow to `setEvent` its own status and for a UI to list `PENDING` workflows and read that event ([`hitl.md`][hitl]). `DELAYED` and `ENQUEUED` are persisted, but describe a workflow that has not started, not one that is waiting.

**Addressing and duplicates.** Messages are addressed by destination workflow ID plus topic; `send` from outside a workflow accepts an `idempotencyKey` that becomes the `message_uuid`, and the insert is `ON CONFLICT (message_uuid) DO NOTHING`, so a duplicate send is dropped; a send from inside a workflow is itself a step and so exactly-once ([`src/system_database.ts`][sysdb], [`workflow-communication.md`][wf-comm]). An early message simply waits in `notifications` until a `recv` consumes it (`consumed = true`, oldest first); a message to a non-existent workflow fails the foreign key and throws `DBOSNonExistentWorkflowError` ([`src/system_database.ts`][sysdb]). Events are addressed by publisher ID plus key, upserted, and a `getEvent` that ran inside a workflow keeps the value it first saw ([`workflow-communication.md`][wf-comm]).

**Timeouts are journaled.** `recv` and `getEvent` default to 60 s and return `null` on expiry; the deadline is written through `#durableSleep` at the reserved `timeoutFunctionID` before polling, so a restart resumes the same deadline rather than restarting the clock ([`src/system_database.ts`][sysdb], [`workflow-communication.md`][wf-comm]). Whether `null` is an error is left to the workflow.

**Human approval** is a documented pattern rather than a primitive: publish `pending_approval` with `setEvent`, `recv` with a long timeout, and have an HTTP endpoint `send` the decision to the workflow ID ([`hitl.md`][hitl], [`hitl-site`][hitl-site]).

## Strengths

- **One dependency.** A Postgres URL is the whole deployment; the schema, migrations and recovery all live in the SDK ([`migrations.ts`][migrations]).
- **The journal is a queryable table.** `listWorkflows`, `getWorkflowSteps`, fork, resume and cancel are SQL over `workflow_status`/`operation_outputs`, and any tool can read them ([`system-tables.md`][systables]).
- **Transactions are exactly-once by construction**: user writes and the checkpoint row commit together ([`src/system_database.ts`][sysdb]).
- **Concurrent-executor safety is explicit**: the insert-or-detect on the primary key and the parking rule make a zombie executor harmless rather than undefined ([`concurrent-executions.md`][concurrent]).
- **Versioning is stamped on the history**, and the default version is derived from the code that wrote it ([`src/dbos-executor.ts`][executor]).
- **Fork-from-step** turns the journal into an operator tool, not just a crash log ([`workflow-management.md`][wf-mgmt]).

## Weaknesses

- **Identity is positional and name-checked only.** Reordering, inserting or removing a step shifts every later position; changed arguments are invisible ([`src/dbos-executor.ts`][executor]).
- **Determinism is unenforced**: a stray `Date.now()` or `Math.random()` in a workflow body is legal and only sometimes detected ([`workflow-tutorial.md`][wf-tutorial]).
- **No compensation model.** Undo is user code in `catch`, with no ordering, registration or replay guarantees beyond those of ordinary steps.
- **Workflow-level exceptions are terminal.** Nothing distinguishes a bug from a transient failure at the workflow level; only steps retry ([`workflow-tutorial.md`][wf-tutorial]).
- **Concurrency inside a workflow is fragile**: correctness depends on start order being deterministic, which the type system cannot see ([`workflow-tutorial.md`][wf-tutorial]).
- **Every step is a database round trip**, and large step outputs are stored inline ([`docs/architecture.md`][arch]).
- **Patching adds a row per patch per workflow** and a branch in user code for the life of the migration ([`upgrading-workflows.md`][upgrading]).

## Key design decisions and trade-offs

| Decision                                                                  | Rationale                                                                             | Trade-off                                                                           |
| ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Journal = one Postgres row per step, keyed `(workflow_uuid, function_id)` | Primary-key uniqueness gives exactly-once checkpointing and zombie detection for free | Positional identity; any structural edit to the workflow needs a patch or a version |
| Position counter reserved synchronously before any `await`                | Makes `Promise.allSettled` over steps deterministic without a scheduler               | Racing sub-sequences are silently wrong                                             |
| Name check, not argument check, on replay                                 | Cheap; catches the common "different step here" bug                                   | Changed inputs at the same position replay stale outputs                            |
| Sleep/timeouts record the deadline, not the duration                      | A restart mid-sleep wakes on the original schedule                                    | Clock skew between executors moves the wake-up                                      |
| `application_version` = MD5 of workflow source text                       | Any code change fences recovery automatically                                         | Harmless refactors also fence; old rows drain only under old code                   |
| Patch markers as rows in the same table                                   | Old and new code coexist without a second history format                              | Runtime cost per patch, and the branch lives in user code                           |
| No compensation primitive                                                 | Keeps the model to "steps + checkpoints"                                              | Every saga is hand-rolled                                                           |
| Workflow exceptions are terminal                                          | Uncaught errors are assumed to be bugs, not transients                                | No workflow-level retry policy                                                      |
| Recovery = re-enqueue `PENDING` rows for this executor + version          | Single-node recovery needs no coordinator                                             | Fleets need executor IDs and Conductor (or manual reassignment)                     |

## Implications for a durable-execution library

- **Positional identity is a real cost, paid three times over.** DBOS needs patch
  markers, a source-hash application version, and a rule forbidding racing
  sub-sequences, all so that a counter keeps lining up (§1, §5, §6). Every one of
  those mechanisms exists to defend the identity scheme rather than to serve the
  program.
- **Its cheap tripwire is worth copying whatever the key is.** On a hit, DBOS also
  compares the recorded operation's name and fails loudly on a mismatch
  (`DBOSUnexpectedStepError`). That is one comparison and it converts a class of
  silent wrongness into a stopped run.
- **Stamping the record with a code version, and filtering recovery on it, is two
  lines that prevent the worst outcome:** new code silently replaying decisions
  made by old code. A source hash is a crude way to derive the version, but the
  mechanism is sound and cheaper than any patch-marker scheme.
- **A caller-supplied run id as the idempotency key** turns "the same program
  started twice" into a lookup rather than a double execution, and pairs with the
  park-and-adopt rule for the loser (§9). A library that omits this pushes the
  problem onto every consumer.
- **Record deadlines, not durations.** DBOS stores absolute wake times, so a
  replay after a long outage does not restart the clock.
- **No compensation primitive is a defensible baseline**, and DBOS demonstrates
  that a library can be widely used without one. What it also demonstrates is the
  consequence: rollback logic lives in user `catch` blocks, and nothing records
  that a rollback happened.
- **Fork-from-step is the operator affordance a library should not skip.** DBOS
  makes it first-class, and it is what a human reaches for when the recorded
  world was wrong rather than the code (§10). A library whose only recovery is
  "discard the journal" has made every such case destructive.
- **A queryable history is part of the product, not an extra.** Because the journal
  is ordinary SQL tables, outside tools inspect a run without the library's
  cooperation. Any storage choice that forecloses this loses something real.

---

## Sources

- [dbos-inc/dbos-transact-ts — GitHub repository][repo]
- [DBOS documentation site][docs] · [dbos-inc/dbos-docs — docs source][docs-repo]
- [`@dbos-inc/dbos-sdk` on the npm registry][npm]
- [`version.json` — `4.28-preview` on `main`][version-json] · [`LICENSE` — MIT][license]
- [`src/sysdb_migrations/internal/migrations.ts` — the system-database schema history][migrations]
- [`src/system_database.ts` — `operation_outputs` read/insert, sleep, send/recv, events, patch, recovery `UPDATE`][sysdb]
- [`src/dbos-executor.ts` — `callStepFunction`, retries, `recoverPendingWorkflows`, `computeAppVersion`, parking][executor]
- [`src/dbos.ts` — `DBOS.workflow`/`registerWorkflow`/`step`/`runStep`/`startWorkflow`/`sleep`][dbos-ts]
- [`src/context.ts` — `functionIDGetIncrement`][context] · [`src/step.ts` — `StepConfig`][step-ts] · [`src/error.ts` — `DBOSUnexpectedStepError`][error] · [`src/debugpoint.ts` — `debugTriggerPoint`][debugpoint]
- [`tests/oaoo.test.ts`][oaoo-test] · [`tests/recovery.test.ts`][recovery-test] · [`tests/helpers.ts`][helpers] · [`tests/appversion.test.ts`][appversion-test] · [`tests/patching.test.ts`][patching-test] · [`tests/concurrency.test.ts`][concurrency-test] · [`chaos-tests/workflows.test.ts`][chaos]
- Docs (source files): [Workflows tutorial][wf-tutorial] · [Steps tutorial][step-tutorial] · [Transactions & Datasources][tx-tutorial] · [Communicating with Workflows][wf-comm] · [Upgrading Workflow Code][upgrading] · [Testing & Mocking][testing] · [Workflow Management][wf-mgmt] · [Architecture][arch] · [Workflow Recovery][recovery] · [System Database][systables] · [Concurrent Executions][concurrent]
- Docs (published pages): [Workflows][wf-tutorial-site] · [Upgrading Workflow Code][upgrading-site] · [Testing & Mocking][testing-site] · [Architecture][arch-site] · [Workflow Recovery][recovery-site] · [System Database][systables-site] · [Concurrent Executions][concurrent-site]
- [Skiadopoulos et al., _DBOS: A DBMS-oriented Operating System_, PVLDB 15 (2022)][vldb-paper]
- Related: [Temporal][temporal] · [Restate][restate] · [catalog index][index] · [Effect (TypeScript)][effect] · [`sparkles:event-horizon` spec][eh-spec]

<!-- References -->

[repo]: https://github.com/dbos-inc/dbos-transact-ts
[docs]: https://docs.dbos.dev/
[docs-repo]: https://github.com/dbos-inc/dbos-docs
[npm]: https://registry.npmjs.org/@dbos-inc/dbos-sdk/latest
[version-json]: https://github.com/dbos-inc/dbos-transact-ts/blob/8495c0060e55d303a38b030900bb1f0c9429f611/version.json
[license]: https://github.com/dbos-inc/dbos-transact-ts/blob/8495c0060e55d303a38b030900bb1f0c9429f611/LICENSE
[migrations]: https://github.com/dbos-inc/dbos-transact-ts/blob/8495c0060e55d303a38b030900bb1f0c9429f611/src/sysdb_migrations/internal/migrations.ts
[sysdb]: https://github.com/dbos-inc/dbos-transact-ts/blob/8495c0060e55d303a38b030900bb1f0c9429f611/src/system_database.ts
[executor]: https://github.com/dbos-inc/dbos-transact-ts/blob/8495c0060e55d303a38b030900bb1f0c9429f611/src/dbos-executor.ts
[dbos-ts]: https://github.com/dbos-inc/dbos-transact-ts/blob/8495c0060e55d303a38b030900bb1f0c9429f611/src/dbos.ts
[context]: https://github.com/dbos-inc/dbos-transact-ts/blob/8495c0060e55d303a38b030900bb1f0c9429f611/src/context.ts
[step-ts]: https://github.com/dbos-inc/dbos-transact-ts/blob/8495c0060e55d303a38b030900bb1f0c9429f611/src/step.ts
[error]: https://github.com/dbos-inc/dbos-transact-ts/blob/8495c0060e55d303a38b030900bb1f0c9429f611/src/error.ts
[debugpoint]: https://github.com/dbos-inc/dbos-transact-ts/blob/8495c0060e55d303a38b030900bb1f0c9429f611/src/debugpoint.ts
[oaoo-test]: https://github.com/dbos-inc/dbos-transact-ts/blob/8495c0060e55d303a38b030900bb1f0c9429f611/tests/oaoo.test.ts
[recovery-test]: https://github.com/dbos-inc/dbos-transact-ts/blob/8495c0060e55d303a38b030900bb1f0c9429f611/tests/recovery.test.ts
[helpers]: https://github.com/dbos-inc/dbos-transact-ts/blob/8495c0060e55d303a38b030900bb1f0c9429f611/tests/helpers.ts
[appversion-test]: https://github.com/dbos-inc/dbos-transact-ts/blob/8495c0060e55d303a38b030900bb1f0c9429f611/tests/appversion.test.ts
[patching-test]: https://github.com/dbos-inc/dbos-transact-ts/blob/8495c0060e55d303a38b030900bb1f0c9429f611/tests/patching.test.ts
[concurrency-test]: https://github.com/dbos-inc/dbos-transact-ts/blob/8495c0060e55d303a38b030900bb1f0c9429f611/tests/concurrency.test.ts
[chaos]: https://github.com/dbos-inc/dbos-transact-ts/blob/8495c0060e55d303a38b030900bb1f0c9429f611/chaos-tests/workflows.test.ts
[wf-tutorial]: https://github.com/dbos-inc/dbos-docs/blob/28245d243740b0bfd684794476c31f9a62dbd6a2/docs/typescript/tutorials/workflow-tutorial.md
[step-tutorial]: https://github.com/dbos-inc/dbos-docs/blob/28245d243740b0bfd684794476c31f9a62dbd6a2/docs/typescript/tutorials/step-tutorial.md
[tx-tutorial]: https://github.com/dbos-inc/dbos-docs/blob/28245d243740b0bfd684794476c31f9a62dbd6a2/docs/typescript/tutorials/transaction-tutorial.md
[wf-comm]: https://github.com/dbos-inc/dbos-docs/blob/28245d243740b0bfd684794476c31f9a62dbd6a2/docs/typescript/tutorials/workflow-communication.md
[upgrading]: https://github.com/dbos-inc/dbos-docs/blob/28245d243740b0bfd684794476c31f9a62dbd6a2/docs/typescript/tutorials/upgrading-workflows.md
[testing]: https://github.com/dbos-inc/dbos-docs/blob/28245d243740b0bfd684794476c31f9a62dbd6a2/docs/typescript/tutorials/testing.md
[wf-mgmt]: https://github.com/dbos-inc/dbos-docs/blob/28245d243740b0bfd684794476c31f9a62dbd6a2/docs/typescript/tutorials/workflow-management.md
[arch]: https://github.com/dbos-inc/dbos-docs/blob/28245d243740b0bfd684794476c31f9a62dbd6a2/docs/architecture.md
[recovery]: https://github.com/dbos-inc/dbos-docs/blob/28245d243740b0bfd684794476c31f9a62dbd6a2/docs/production/workflow-recovery.md
[systables]: https://github.com/dbos-inc/dbos-docs/blob/28245d243740b0bfd684794476c31f9a62dbd6a2/docs/explanations/system-tables.md
[concurrent]: https://github.com/dbos-inc/dbos-docs/blob/28245d243740b0bfd684794476c31f9a62dbd6a2/docs/explanations/concurrent-executions.md
[wf-tutorial-site]: https://docs.dbos.dev/typescript/tutorials/workflow-tutorial
[upgrading-site]: https://docs.dbos.dev/typescript/tutorials/upgrading-workflows
[testing-site]: https://docs.dbos.dev/typescript/tutorials/testing
[arch-site]: https://docs.dbos.dev/architecture
[recovery-site]: https://docs.dbos.dev/production/workflow-recovery
[systables-site]: https://docs.dbos.dev/explanations/system-tables
[concurrent-site]: https://docs.dbos.dev/explanations/concurrent-executions
[vldb-paper]: https://www.vldb.org/pvldb/vol15/p21-skiadopoulos.pdf
[temporal]: ./temporal.md
[restate]: ./restate.md
[index]: ./index.md
[effect]: ../typescript-effect.md
[eh-spec]: ../../../specs/event-horizon/SPEC.md
[adminserver]: https://github.com/dbos-inc/dbos-transact-ts/blob/8495c0060e55d303a38b030900bb1f0c9429f611/src/adminserver.ts
[cli]: https://github.com/dbos-inc/dbos-docs/blob/28245d243740b0bfd684794476c31f9a62dbd6a2/docs/typescript/reference/cli.md
[hitl]: https://github.com/dbos-inc/dbos-docs/blob/28245d243740b0bfd684794476c31f9a62dbd6a2/docs/ai/hitl.md
[hitl-site]: https://docs.dbos.dev/ai/hitl
[methods]: https://github.com/dbos-inc/dbos-docs/blob/28245d243740b0bfd684794476c31f9a62dbd6a2/docs/typescript/reference/methods.md
[prod-mgmt]: https://github.com/dbos-inc/dbos-docs/blob/28245d243740b0bfd684794476c31f9a62dbd6a2/docs/production/workflow-management.md
[workflow-ts]: https://github.com/dbos-inc/dbos-transact-ts/blob/8495c0060e55d303a38b030900bb1f0c9429f611/src/workflow.ts
