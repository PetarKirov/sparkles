# Trigger.dev (TypeScript)

A background-jobs platform whose durability primitive is the operating system, not a journal: a run is an ordinary async function in a container, a wait longer than a threshold has the container's process checkpointed with CRIU and restored later at the same instruction, and a failed attempt starts the function again from the top with nothing memoized.

| Field             | Value                                                                                                                                                                                                                                                                 |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | TypeScript throughout: the SDK (`@trigger.dev/sdk`), the CLI and run controller (`trigger.dev`), the Remix webapp, the supervisor, and the run engine                                                                                                                 |
| License           | Apache-2.0 ([`LICENSE`][license])                                                                                                                                                                                                                                     |
| Repository        | [triggerdotdev/trigger.dev][repo]                                                                                                                                                                                                                                     |
| Documentation     | [trigger.dev/docs][docs] (source in [`docs/`][docs-dir] of the same repository)                                                                                                                                                                                       |
| Category          | contrast case (durable-execution engine that does **not** replay)                                                                                                                                                                                                     |
| Persistence model | snapshot — CRIU process checkpoint of the running container at a waitpoint; no step journal, no re-execution on resume                                                                                                                                                |
| Journal store     | Postgres via Prisma: `TaskRun` (run, payload, idempotency key, version lock), `TaskRunAttempt` (one row per attempt), `TaskRunExecutionSnapshot` (the engine's status log), `TaskRunCheckpoint` (where the CRIU image lives), `Waitpoint` ([`schema.prisma`][schema]) |
| Latest release    | `4.5.16` is the SDK and CLI package version at the reviewed commit ([`packages/trigger-sdk/package.json`][sdk-pkg]); the docs cite `v4.5.12` (external deployment ids) as a named GitHub release ([`version-skew-protection.mdx`][doc-skew-src])                      |
| Local clone       | `$REPOS/trigger.dev` at `66ff818eb41fab762bd4f615a42d30b559db59f0` (shallow; no tags)                                                                                                                                                                                 |

**Last reviewed:** September 12, 2026.

The v3-era `apps/coordinator` and `apps/kubernetes-provider` no longer exist at this commit; checkpointing now lives in `apps/supervisor` (the CRIU path) and the `@internal/compute` microVM path, driven by the v4 run engine in `internal-packages/run-engine`.

---

## Overview

### What it solves

Trigger.dev sells "serverless without timeouts": a TypeScript function that may run for hours or days, trigger child tasks, sleep for a month, or block on a human approval, billed only while it is actually executing. The user writes plain async code with no step API; the platform owns queueing, concurrency, retries, versioning and the dashboard. The core promise is stated in [`how-it-works.mdx`][doc-hiw-src]:

> _"State Checkpointing: While waiting for a subtask or during a long programmed pause (e.g., `wait.for({ minutes: 5 })`), the system uses CRIU (Checkpoint/Restore In Userspace) to create a checkpoint of the task's entire state, including memory, CPU registers, and open file descriptors."_

That sentence is the whole contrast with every other subject in this catalog. Temporal, Durable Functions, Inngest and DBOS survive a pause by _replaying_ code against a journal; Trigger.dev survives it by freezing the process image. The consequence is the second half of the contract, from the same page's "How retries work":

> _"The main task throws an error and is scheduled for retry. When retried, it starts from the beginning, but leverages cached results for completed subtasks."_

"Cached results" here means child-run idempotency keys, not memoized steps. There is no `step.run`; a retried attempt re-executes every line of the `run` function, and only calls that the developer deduplicated with an `idempotencyKey` return the earlier outcome.

### Design philosophy

Three commitments, each visible in the code:

1. **The process is the state.** The SDK's wait functions resolve a promise; nothing in user code is serialized. `SharedRuntimeManager.suspendable` merely flips a flag telling the controller the process may be frozen ([`sharedRuntimeManager.ts`][rt-shared]). The [`ai-chat/how-it-works.mdx`][doc-aichat-src] page spells out what survives: _"Anything in process memory survives: `chat.local`, the message accumulator, in-flight Promises, in-memory caches, open DB connections. The runId is unchanged."_
2. **Durability across a crash is the developer's job, via idempotency.** The docs' "Durable execution" section is a recipe, not a mechanism: break the workflow into child tasks, give each a key, let retries hit the cache ([`how-it-works.mdx`][doc-hiw-src]). The engine's own retry path knows nothing about steps.
3. **One transactional status log per run.** Every transition writes a `TaskRunExecutionSnapshot` row under a per-run lock; its comment reads _"It has the required information to transactionally progress a run through states, and prevent side effects like heartbeats failing a run that has progressed"_ ([`schema.prisma`][schema]). This is a state machine over the run, not a journal of the function's effects.

---

## How it works

### User-facing API

```ts
// docs/how-it-works.mdx (docs example)
import { task, wait } from '@trigger.dev/sdk';

export const parentTask = task({
  id: 'parent-task',
  retry: {
    maxAttempts: 5,
    minTimeoutInMs: 1000,
    maxTimeoutInMs: 10000,
    factor: 2,
  },
  run: async () => {
    // This will cause the parent task to be checkpointed and suspended
    const result = await childTask.triggerAndWait({ data: 'some data' });
    // This will also cause the task to be checkpointed and suspended
    await wait.for({ minutes: 5 });
    return 'Parent task completed';
  },
});
```

The four blocking primitives are `wait.for` / `wait.until` (a `DATETIME` waitpoint), `wait.forToken` (a `MANUAL` waitpoint completed by an HTTP call or the SDK), `triggerAndWait` (a `RUN` waitpoint completed when the child finishes) and `batchTriggerAndWait` (a `BATCH` waitpoint) ([`wait.mdx`][doc-wait-src], [`wait-for-token.mdx`][doc-token-src], [`schema.prisma`][schema] `enum WaitpointType`). `retry` is per task: `maxAttempts` defaults to 3 and counts the first attempt ([`tasks/overview.mdx`][doc-tasks-src]); `catchError` can override the decision per error ([`errors-retrying.mdx`][doc-retry-src]).

### The attempt is the unit of execution

`TaskExecutor.#callRun` in [`taskExecutor.ts`][core-executor] is the only place user code runs, and it is called once per attempt:

```ts
// packages/core/src/v3/workers/taskExecutor.ts
async #callRun(payload: unknown, ctx: TaskRunContext, init: unknown, signal: AbortSignal) {
  const runFn = this.task.fns.run;
  ...
  return await runFn(payload, { ctx, init, signal });
```

When an attempt fails and the retry policy allows another, `RunAttemptSystem.attemptFailed` computes `nextAttemptNumber = latestSnapshot.attemptNumber + 1`, emits `runRetryScheduled`, and either nacks the run back to the queue (long delay) or writes an `EXECUTING` snapshot with the description _"Attempt failed with a short delay, starting a new attempt"_ so the same warm worker calls `run` again ([`runAttemptSystem.ts`][engine-attempt]). Nothing from the failed attempt is carried forward except the `TaskRunAttempt` row and the run's `metadata`. `retrying.ts` returns one of `cancel_run`, `fail_run` or `retry` with `method: "queue" | "immediate"` ([`retrying.ts`][engine-retrying]).

### The wait: sleep, then suspend, then checkpoint

`wait.for` has two regimes ([`wait.ts`][sdk-wait]). Below `DURATION_WAIT_CHARGE_THRESHOLD_MS = 5000` it is a local `setTimeout`. Above it, the SDK creates a `DATETIME` waitpoint through the API and calls `runtime.waitUntil`, which the `SharedRuntimeManager` wraps in `suspendable`:

```ts
// packages/core/src/v3/runtime/sharedRuntimeManager.ts
private async suspendable<T>(promise: Promise<T>): Promise<T> {
  this.setSuspendable(true);
  const [error, result] = await tryCatch(promise);
  this.setSuspendable(false);
  ...
```

The flag crosses the IPC boundary to the run controller in [`execution.ts`][cli-execution], whose `handleSuspendable` cleans up the child, re-checks the snapshot id twice, and calls `httpClient.suspendRun(runFriendlyId, snapshotId)`. The engine side, `CheckpointSystem.createCheckpoint`, validates that the request names the latest snapshot (or the previous one if the run is `QUEUED_EXECUTING`), that the status `isCheckpointable`, records a `TaskRunCheckpoint` with `type` ∈ {`DOCKER`, `KUBERNETES`, `COMPUTE`} and a `location`, writes a `SUSPENDED` snapshot (_"Run was suspended after creating a checkpoint."_) and releases the run's concurrency ([`checkpointSystem.ts`][engine-checkpoint], [`statuses.ts`][engine-statuses]).

The docs fix the timing: _"the concurrency slot is only released once we've snapshotted the machine and shut it down. For `wait.for` and `wait.until` that happens 60 seconds into the wait, so anything shorter stays `EXECUTING` and holds its slot for the whole wait"_ ([`paused-execution-free.mdx`][doc-paused-src]). Between the 5 s billing threshold and the 60 s checkpoint threshold the process is simply kept alive.

### The resume: restore, not re-run

`WaitpointSystem.continueRunIfUnblocked` runs when the last blocking waitpoint completes ([`waitpointSystem.ts`][engine-waitpoint]). Two branches matter:

- `EXECUTING_WITH_WAITPOINTS`: the process is still alive, so the engine writes an `EXECUTING` snapshot (_"Run was continued, whilst still executing."_) carrying the `completedWaitpoints`; the controller forwards them to the process and the pending promise resolves in place.
- `SUSPENDED`: the run is re-enqueued as `QUEUED` with its original timestamp (_"Run was QUEUED, because all waitpoints are completed"_) and its `checkpointId`. If the snapshot has no checkpoint the engine throws `run is suspended, but has no checkpoint` rather than restarting the function; there is no fallback to re-execution.

On dequeue the supervisor sees `message.checkpoint`, logs `path_taken: "restore"`, and either asks the compute manager to `restore({ snapshotId: checkpoint.location, ... })` or calls `checkpointClient.restoreRun` ([`apps/supervisor/src/index.ts`][sup-index], [`checkpointClient.ts`][core-ckclient]). The restored controller then calls `continueRunExecution` and increments `restoreCount` ([`execution.ts`][cli-execution]). The `checkpointsEnabled` option is documented as _"Whether CRIU checkpoint/restore is enabled for this deployment"_ ([`workloadManager/types.ts`][sup-types]); the Kubernetes pod spec applies a seccomp profile because _"node >= 24 always creates io_uring fds, which can't be checkpointed"_ ([`kubernetesPodSpec.ts`][sup-podspec]). Self-hosters do not get this path: _"No checkpoint support. This was only ever experimental when self-hosting"_ ([`self-hosting/docker.mdx`][doc-selfhost-src]).

### The run engine's status log

```prisma
// internal-packages/database/prisma/schema.prisma
enum TaskRunExecutionStatus {
  RUN_CREATED
  DELAYED
  QUEUED
  /// Run is in the RunQueue, and is also executing. This happens when a run is continued cannot reacquire concurrency
  QUEUED_EXECUTING
  PENDING_EXECUTING
  EXECUTING
  /// Run is executing on a worker but is waiting for waitpoints to complete
  EXECUTING_WITH_WAITPOINTS
  /// Run has been suspended and may be waiting for waitpoints to complete before resuming
  SUSPENDED
  PENDING_CANCEL
  FINISHED
}
```

Each `TaskRunExecutionSnapshot` row carries `executionStatus`, `runStatus`, `attemptNumber`, `previousSnapshotId`, `checkpointId`, `completedWaitpoints` with `completedWaitpointOrder`, `workerId`/`runnerId` and `lastHeartbeatAt`. The user-visible `TaskRunStatus` is coarser (`EXECUTING`, `WAITING_TO_RESUME`, `RETRYING_AFTER_FAILURE`, `COMPLETED_SUCCESSFULLY`, `CRASHED`, `TIMED_OUT`, …). A `Waitpoint` has an `idempotencyKey` unique per environment, an `output`, and `completedByTaskRunId` / `completedByBatchId` / `completedAfter` depending on type; the `TaskRunWaitpoint` join table holds `batchIndex` so a batch's results come back in order ([`schema.prisma`][schema]).

What is **absent** from the schema is as telling as what is present: there is no table of step results, no per-call sequence number, no args hash. The only memo is the run-level `idempotencyKey` on `TaskRun` (unique with `runtimeEnvironmentId` and `taskIdentifier`) and the `Waitpoint.idempotencyKey`.

### Idempotency keys

`idempotencyKeys.create(key, { scope })` hashes the key with context: `"run"` (default) adds the parent run id, `"attempt"` adds the attempt number, `"global"` adds nothing ([`idempotency.mdx`][doc-idem-src]). Triggering a child with a key that already exists returns the existing run's handle, so a `triggerAndWait` inside a retried parent completes against the first attempt's child. Wait functions accept the same options (`idempotencyKey`, `idempotencyKeyTTL`) to skip a sleep a previous attempt already served ([`wait-for.mdx`][doc-waitfor-src]).

### Versioning

_"When a task run starts it is locked to the latest version of the code (for that environment). Once locked it won't change versions, even if you deploy new versions."_ and _"Retries are locked to the original version of the run."_ ([`versioning.mdx`][doc-versioning-src]). The lock is the `lockedToVersionId` foreign key from `TaskRun` to `BackgroundWorker`; each `WorkerDeployment` has a `version` unique per environment and a `contentHash` ([`schema.prisma`][schema]). `triggerAndWait` and `batchTriggerAndWait` pin the child to the parent's version; `trigger` does not. A "replay" in Trigger.dev vocabulary is a **new run** with the same payload on the latest version ([`replaying.mdx`][doc-replay-src]), the opposite of what the word means in this catalog.

---

## Analysis

### 1. Step identity and replay matching

Not applicable inside an attempt: there are no steps and nothing is matched, because nothing is re-executed. The process image resumes at the instruction after the `await` ([`doc-aichat-src`][doc-aichat-src]). Across attempts the only identity is the developer-supplied idempotency key, hashed with run id (default), attempt number or nothing ([`idempotency.mdx`][doc-idem-src]); it identifies a **child run** or a **waitpoint**, never a local computation. A plain `await fetch(...)` in a retried attempt runs again.

### 2. Journal versus world

Within an attempt there is no journal to disagree with; the world is whatever the restored process holds in memory plus whatever it re-reads. The docs make the hazard explicit: open DB connections and in-flight promises are frozen and thawed ([`ai-chat/how-it-works.mdx`][doc-aichat-src]), so a connection that timed out during a month-long sleep is the developer's problem. Across attempts, the engine's status log wins over the worker: `createCheckpoint` discards a checkpoint request that does not name the latest snapshot (`incomingCheckpointDiscarded`, _"Not the latest snapshot"_) and the controller aborts if the snapshot id changed between its two checks ([`checkpointSystem.ts`][engine-checkpoint], [`execution.ts`][cli-execution]). Disagreement is detected by snapshot-id comparison, never by comparing recorded observations against re-observed ones.

### 3. Determinism enforcement

None, because none is needed for resume: a snapshot does not care whether `Date.now()` or `Math.random()` was called. The one rule the runtime enforces is structural: `preventMultipleWaits` throws `TASK_DID_CONCURRENT_WAIT` with `skipRetrying: true` if a second wait starts while one is pending, with the message _"Parallel waits are not supported, e.g. using Promise.all() around our wait functions."_ ([`preventMultipleWaits.ts`][rt-prevent]). The comment explains why: the callback is deferred one tick _"to ensure the first wait doesn't checkpoint before the second is called"_. Retry-level determinism is discipline: the docs tell you to give side effects idempotency keys ([`how-it-works.mdx`][doc-hiw-src]).

### 4. Compensation and failure handling

No compensation primitive exists. The failure vocabulary is retry (per task `retry`, per error `catchError` returning `skipRetrying` or `retryAt`), in-function `retry.onThrow` / `retry.fetch`, and the final statuses `COMPLETED_WITH_ERRORS`, `CRASHED`, `SYSTEM_FAILURE`, `TIMED_OUT` ([`errors-retrying.mdx`][doc-retry-src], [`schema.prisma`][schema]). A retry runs the function again from line one; the only protection for work already done is that idempotent child triggers return the existing run. The lifecycle hooks (`onFailure` and friends in [`hooks.ts`][sdk-hooks]) fire per attempt or per run and can clean up, but nothing is registered, ordered or unwound by the platform. The absence is a finding: without a step journal there is nothing to walk backwards.

### 5. Versioning against old histories

Solved by not having histories. A run is locked to a `BackgroundWorker` version at start, retries stay on it, and `triggerAndWait` children inherit it ([`versioning.mdx`][doc-versioning-src]). A CRIU image is a snapshot of a specific container image, so an old run's restore always lands in the code it was checkpointed from; the `TaskRunCheckpoint.imageRef` column records which. Version skew between the app that triggers and the deployment that executes is closed by an opaque external deployment id sent on both sides ([`version-skew-protection.mdx`][doc-skew-src]). The cost is that a bug in an in-flight run cannot be patched into that run; the fix is a new run ("replay") on the new version.

### 6. Concurrency under replay

No replay, so the question becomes "how do concurrent waits suspend". Answer: they may not. One wait at a time is enforced ([`preventMultipleWaits.ts`][rt-prevent]); fan-out is expressed as `batchTriggerAndWait`, a single `BATCH` waitpoint whose results come back ordered by `batchIndex` ([`triggering.mdx`][doc-trigger-src], [`schema.prisma`][schema]). Concurrency between runs is a queue-level concern: a checkpointed run releases its slot (`releaseAllConcurrency` in [`checkpointSystem.ts`][engine-checkpoint]) and may re-acquire one on resume, or run as `QUEUED_EXECUTING` if it cannot ([`queue-concurrency.mdx`][doc-qc-src]).

### 7. Replay or snapshot

Snapshot, unreservedly. What it buys: no determinism rules, no step API, arbitrary in-memory state, and zero re-execution cost on resume. What it costs: the checkpoint is only taken after 60 s of waiting, so short waits hold a container and a concurrency slot ([`paused-execution-free.mdx`][doc-paused-src]); the mechanism needs CRIU-capable hosts, a seccomp profile to keep Node 24 off `io_uring` ([`kubernetesPodSpec.ts`][sup-podspec]), and is unavailable when self-hosting ([`self-hosting/docker.mdx`][doc-selfhost-src]); a crash between checkpoints loses the whole attempt; and the image is opaque, so the dashboard shows status transitions and OpenTelemetry spans, not a replayable list of effects. The microVM path (Firecracker snapshots, private beta) changes the substrate, not the model ([`ai-chat/how-it-works.mdx`][doc-aichat-src]).

### 8. Testing

Developer-facing testing is a dashboard form: pick a task, enter a JSON payload, press "Run test" ([`run-tests.mdx`][doc-tests-src]). There is no in-process test harness for a task function in the SDK. The engine itself is tested heavily against real Postgres and Redis via testcontainers: `checkpoints.test.ts`, `attemptFailures.test.ts`, `batchTriggerAndWait.test.ts` and dozens more under [`engine/tests/`][engine-tests], with a `RaceSimulationSystem` that lets a test park a code path at a named racepoint (`waitForRacepoint({ runId })` is called at the top of `blockRunWithWaitpoint`) to interleave transitions deterministically ([`raceSimulationSystem.ts`][engine-race], [`waitpointSystem.ts`][engine-waitpoint]). The crash-at-every-index style of test has no analogue because there is no index.

---

## Strengths

- **No programming model to learn.** Plain async TypeScript; the only rules are "one wait at a time" and "use idempotency keys for side effects".
- **Resume is free.** A restored process continues at the next instruction with all locals intact; no replay time, no history size limit, no `continueAsNew`.
- **Waiting is free and slot-free** once checkpointed, which lets a workflow sleep for a year without holding compute or concurrency.
- **The status log is transactional and auditable.** Every transition is a `TaskRunExecutionSnapshot` with a human-readable `description`, linked by `previousSnapshotId`, checked under a per-run lock.
- **Version locking is total.** A run, its retries and its awaited children all execute the deployment they started on.

## Weaknesses

- **A retry is a full re-run.** No memoization of prior work; correctness under retry depends entirely on the developer's idempotency discipline.
- **The unit of durability is coarse.** Between checkpoints (and for every wait under 60 s) a crash loses the attempt; the docs' "durable execution" is a pattern built from child tasks, not a property of a task.
- **Infrastructure-bound.** CRIU needs a cooperating kernel, seccomp tuning and cloud-only operation; the process image cannot be inspected, diffed or migrated to a fixed version.
- **No concurrency inside a run.** `Promise.all` over waits is a hard error; only batch fan-out is supported.
- **No compensation, no history query.** Nothing in the platform can undo work or tell you which effects an attempt performed beyond OpenTelemetry spans.

---

## Key design decisions and trade-offs

| Decision                                                    | Rationale                                                                     | Trade-off                                                              |
| ----------------------------------------------------------- | ----------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| Checkpoint the process (CRIU) instead of journaling effects | Users write ordinary code; anything in memory survives a pause                | Needs CRIU hosts and seccomp; not self-hostable; image is opaque       |
| Checkpoint only after 60 s of waiting                       | Checkpointing is slow; short waits are cheaper to sit out                     | Short waits hold a container and a concurrency slot                    |
| A failed attempt re-runs `run` from the top                 | Keeps the engine ignorant of user code structure                              | Every non-idempotent side effect repeats on retry                      |
| Idempotency keys scoped by run / attempt / global           | Gives the developer one knob to make child triggers and waits survive retries | Only covers child runs and waitpoints; local effects have no key       |
| One wait at a time (`preventMultipleWaits`)                 | A checkpoint must be taken at a single well-defined suspension point          | No `Promise.all` over waits; fan-out only via batch                    |
| Version-lock runs, retries and awaited children             | A restored image must run the code it was frozen in                           | Bugs cannot be patched into an in-flight run; "replay" is a new run    |
| `TaskRunExecutionSnapshot` as a transactional status log    | Heartbeats, checkpoints and completions must not act on stale state           | The log records transitions, not effects; it cannot drive re-execution |

---

## Relevance to sparkles

- **Argues against the replay design's central bet, from the outside.** Trigger.dev shows that "durable" can mean "the OS keeps my stack" and that users will accept "retry re-runs everything" if child work is idempotent. `release` cannot take this road: it is a CLI on a developer's machine, not a CRIU-capable cluster, and its hour-long run is mostly waiting on git, GitHub and an LLM, none of which a process image can freeze. The snapshot option is closed for us; the catalog should record why, not just that.
- **Confirms that the journal must key effects, not status.** Trigger.dev's status log is exactly what the design's `journal.jsonl` must **not** be: a list of transitions with human descriptions. It cannot answer "did the tag get pushed"; only an effect-keyed journal (name + attempt + args hash) can. The `TaskRunExecutionSnapshot.previousSnapshotId` chain is, however, a good model for the append-only link and the stale-writer check.
- **Confirms the attempt counter in the key.** Trigger.dev's `"attempt"` idempotency scope is the same idea as the design's attempt counter: a retried step may legitimately want a fresh child while a resumed step wants the old one. The design should let a step choose which, per call, the way `scope` does.
- **Warns about the "one wait at a time" cliff.** `preventMultipleWaits` exists because a snapshot needs one suspension point. A replay journal does not have that constraint, but the design's concurrent `--split` release chains still need a rule for how parallel ops are keyed; Trigger.dev's `batchIndex` ordering (results returned in submission order regardless of completion order) is the simplest correct answer.
- **Its version story is a warning, not a model.** Locking a run to the code it started on is trivial when the state is a process image and impossible for `release`, whose journal must be read by newer code after a fix. The design's reconcile-by-rule-table is the right answer; Trigger.dev confirms that the only alternative is "start a new run".
- **Missing in the design, present here: the snapshot-id guard.** Every write in the run engine names the snapshot it believes is current and is rejected otherwise. The journaling combinator should do the same: a resumed `release` should refuse to append if the journal's last event id is not the one it read at resume, which is the cheap defence against two resumes of the same run.
- **Confirms "compensation is explicit-only", by having none.** Trigger.dev ships no saga primitive and its users cope with idempotency keys. The design's LIFO scope compensations are strictly more than this; the finding is that the absence is survivable only because every retry restarts from a clean slate, which `release` cannot afford (a half-published GitHub release is not idempotent).

---

## Sources

- [triggerdotdev/trigger.dev — repository][repo]
- [`LICENSE` — Apache-2.0][license]
- [`packages/trigger-sdk/package.json` — SDK version][sdk-pkg]
- [`internal-packages/database/prisma/schema.prisma` — `TaskRun`, `TaskRunAttempt`, `TaskRunExecutionSnapshot`, `TaskRunExecutionStatus`, `TaskRunCheckpoint`, `Waitpoint`, `TaskRunWaitpoint`, `WorkerDeployment`][schema]
- [`internal-packages/run-engine/src/engine/statuses.ts` — `isCheckpointable`, `isExecuting`, final statuses][engine-statuses]
- [`internal-packages/run-engine/src/engine/systems/checkpointSystem.ts` — `createCheckpoint`, `continueRunExecution`][engine-checkpoint]
- [`internal-packages/run-engine/src/engine/systems/waitpointSystem.ts` — `blockRunWithWaitpoint`, `continueRunIfUnblocked`][engine-waitpoint]
- [`internal-packages/run-engine/src/engine/systems/runAttemptSystem.ts` — `attemptFailed`, next attempt number, queue vs immediate retry][engine-attempt]
- [`internal-packages/run-engine/src/engine/retrying.ts` — `RetryOutcome`][engine-retrying]
- [`internal-packages/run-engine/src/engine/systems/raceSimulationSystem.ts` — racepoints for tests][engine-race]
- [`internal-packages/run-engine/src/engine/tests/` — engine test suite][engine-tests] ([`checkpoints.test.ts`][engine-test-ckpt], [`attemptFailures.test.ts`][engine-test-fail], [`batchTriggerAndWait.test.ts`][engine-test-batch])
- [`packages/core/src/v3/workers/taskExecutor.ts` — `#callRun`][core-executor]
- [`packages/core/src/v3/runtime/sharedRuntimeManager.ts` — `waitForTask`, `waitForWaitpoint`, `suspendable`][rt-shared]
- [`packages/core/src/v3/runtime/preventMultipleWaits.ts` — `TASK_DID_CONCURRENT_WAIT`][rt-prevent]
- [`packages/core/src/v3/serverOnly/checkpointClient.ts` — `CheckpointClient.suspendRun` / `restoreRun`][core-ckclient]
- [`packages/trigger-sdk/src/v3/wait.ts` — `wait.for`, `wait.until`, `wait.forToken`, `DURATION_WAIT_CHARGE_THRESHOLD_MS`][sdk-wait]
- [`packages/trigger-sdk/src/v3/shared.ts` — `triggerAndWait_internal`, `batchTriggerAndWait`][sdk-shared]
- [`packages/trigger-sdk/src/v3/hooks.ts` — `onFailure` lifecycle hook][sdk-hooks]
- [`packages/cli-v3/src/entryPoints/managed/execution.ts` — snapshot handling, `handleSuspendable`, `restore`][cli-execution]
- [`packages/cli-v3/src/entryPoints/managed/taskRunProcessProvider.ts` — persistent (warm) process reuse][cli-provider]
- [`apps/supervisor/src/index.ts` — restore path on dequeue][sup-index]
- [`apps/supervisor/src/workloadManager/types.ts` — `checkpointsEnabled` (CRIU)][sup-types]
- [`apps/supervisor/src/workloadManager/kubernetesPodSpec.ts` — seccomp profile for checkpointable Node][sup-podspec]
- [`apps/supervisor/src/env.ts` — `TRIGGER_CHECKPOINT_URL`][sup-env]
- [Docs: How Trigger.dev works][doc-hiw] ([source][doc-hiw-src])
- [Docs: Wait overview][doc-wait] ([source][doc-wait-src]) · [Wait for][doc-waitfor] ([source][doc-waitfor-src]) · [Wait for token][doc-token] ([source][doc-token-src]) · [paused-execution snippet][doc-paused-src]
- [Docs: Errors & retrying][doc-retry] ([source][doc-retry-src]) · [Tasks overview][doc-tasks-src]
- [Docs: Idempotency][doc-idem] ([source][doc-idem-src])
- [Docs: Versioning][doc-versioning] ([source][doc-versioning-src]) · [Version skew protection][doc-skew-src] · [Replaying][doc-replay-src]
- [Docs: Queue concurrency][doc-qc] ([source][doc-qc-src]) · [Triggering][doc-trigger-src]
- [Docs: Run tests][doc-tests-src] · [Self-hosting with Docker][doc-selfhost-src] · [AI chat: how it works][doc-aichat-src]
- Related: [Temporal][temporal] · [Inngest][inngest] · [catalog index][index] · [algebraic-effects topic][topic]

<!-- References -->

[repo]: https://github.com/triggerdotdev/trigger.dev
[docs]: https://trigger.dev/docs
[docs-dir]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/docs/README.md
[license]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/LICENSE
[sdk-pkg]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/packages/trigger-sdk/package.json
[schema]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/internal-packages/database/prisma/schema.prisma
[engine-statuses]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/internal-packages/run-engine/src/engine/statuses.ts
[engine-checkpoint]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/internal-packages/run-engine/src/engine/systems/checkpointSystem.ts
[engine-waitpoint]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/internal-packages/run-engine/src/engine/systems/waitpointSystem.ts
[engine-attempt]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/internal-packages/run-engine/src/engine/systems/runAttemptSystem.ts
[engine-retrying]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/internal-packages/run-engine/src/engine/retrying.ts
[engine-race]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/internal-packages/run-engine/src/engine/systems/raceSimulationSystem.ts
[engine-tests]: https://github.com/triggerdotdev/trigger.dev/tree/66ff818eb41fab762bd4f615a42d30b559db59f0/internal-packages/run-engine/src/engine/tests
[engine-test-ckpt]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/internal-packages/run-engine/src/engine/tests/checkpoints.test.ts
[engine-test-fail]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/internal-packages/run-engine/src/engine/tests/attemptFailures.test.ts
[engine-test-batch]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/internal-packages/run-engine/src/engine/tests/batchTriggerAndWait.test.ts
[core-executor]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/packages/core/src/v3/workers/taskExecutor.ts
[rt-shared]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/packages/core/src/v3/runtime/sharedRuntimeManager.ts
[rt-prevent]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/packages/core/src/v3/runtime/preventMultipleWaits.ts
[core-ckclient]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/packages/core/src/v3/serverOnly/checkpointClient.ts
[sdk-wait]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/packages/trigger-sdk/src/v3/wait.ts
[sdk-shared]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/packages/trigger-sdk/src/v3/shared.ts
[sdk-hooks]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/packages/trigger-sdk/src/v3/hooks.ts
[cli-execution]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/packages/cli-v3/src/entryPoints/managed/execution.ts
[cli-provider]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/packages/cli-v3/src/entryPoints/managed/taskRunProcessProvider.ts
[sup-index]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/apps/supervisor/src/index.ts
[sup-types]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/apps/supervisor/src/workloadManager/types.ts
[sup-podspec]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/apps/supervisor/src/workloadManager/kubernetesPodSpec.ts
[sup-env]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/apps/supervisor/src/env.ts
[doc-hiw]: https://trigger.dev/docs/how-it-works
[doc-hiw-src]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/docs/how-it-works.mdx
[doc-wait]: https://trigger.dev/docs/wait
[doc-wait-src]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/docs/wait.mdx
[doc-waitfor]: https://trigger.dev/docs/wait-for
[doc-waitfor-src]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/docs/wait-for.mdx
[doc-token]: https://trigger.dev/docs/wait-for-token
[doc-token-src]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/docs/wait-for-token.mdx
[doc-paused-src]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/docs/snippets/paused-execution-free.mdx
[doc-retry]: https://trigger.dev/docs/errors-retrying
[doc-retry-src]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/docs/errors-retrying.mdx
[doc-tasks-src]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/docs/tasks/overview.mdx
[doc-idem]: https://trigger.dev/docs/idempotency
[doc-idem-src]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/docs/idempotency.mdx
[doc-versioning]: https://trigger.dev/docs/versioning
[doc-versioning-src]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/docs/versioning.mdx
[doc-skew-src]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/docs/deployment/version-skew-protection.mdx
[doc-replay-src]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/docs/replaying.mdx
[doc-qc]: https://trigger.dev/docs/queue-concurrency
[doc-qc-src]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/docs/queue-concurrency.mdx
[doc-trigger-src]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/docs/triggering.mdx
[doc-tests-src]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/docs/run-tests.mdx
[doc-selfhost-src]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/docs/self-hosting/docker.mdx
[doc-aichat-src]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/docs/ai-chat/how-it-works.mdx
[temporal]: ./temporal.md
[inngest]: ./inngest.md
[index]: ./index.md
[topic]: ../index.md
