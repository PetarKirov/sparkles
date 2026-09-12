# Temporal (Go / TypeScript)

A durable-execution platform in which ordinary workflow code is made crash-resumable by recording every command it issues as an append-only _event history_ on a server and re-executing the code against that history after a failure; the server owns the journal, the SDKs own replay.

| Field             | Value                                                                                                                                                                                                                                                                                                     |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | Server: Go. SDKs surveyed: Go (`go.temporal.io/sdk`) and TypeScript (`@temporalio/*`, whose worker embeds the Rust `sdk-core` as a git submodule)                                                                                                                                                         |
| License           | MIT (server, Go SDK, TypeScript SDK)                                                                                                                                                                                                                                                                      |
| Repository        | [temporalio/temporal][repo-server] · [temporalio/sdk-go][repo-go] · [temporalio/sdk-typescript][repo-ts] · [temporalio/documentation][repo-docs]                                                                                                                                                          |
| Documentation     | [docs.temporal.io][docs-home]                                                                                                                                                                                                                                                                             |
| Category          | durable-execution engine (server) + durable-execution SDK (Go, TypeScript)                                                                                                                                                                                                                                |
| Persistence model | replay                                                                                                                                                                                                                                                                                                    |
| Journal store     | Per-execution event history persisted by the server in a `history_node` table (Cassandra, MySQL, PostgreSQL, SQLite), keyed by shard, tree, branch, node and transaction id; the SDK never writes it directly                                                                                             |
| Latest release    | The checkouts declare server `ServerVersion = "1.33.0"` (`common/headers/version_checker.go`), Go SDK `SDKVersion = "1.48.0"` (`internal/version.go`) and TypeScript worker package `1.23.0` (`packages/worker/package.json`)                                                                             |
| Local clone       | `$REPOS/temporal` at `2f7ba7ce3b4afb0db9ccf7aebbf7189e2d38bbef` · `$REPOS/temporal-sdk-go` at `fee1a45426e6dd90389ac5af4a45d98a357566b4` · `$REPOS/temporal-sdk-typescript` at `72615f23ef735ab27ef0cc18cbf3de68f823fdc1` · `$REPOS/temporal-documentation` at `01c99ad49289ccd45519f113dcd05b5f6503a331` |

**Last reviewed:** September 12, 2026.

---

## Overview

### What it solves

A long multi-step program that talks to the outside world (a release pipeline, an order saga, a provisioning run) dies partway through and must resume without redoing what it already did. Temporal's answer is to split the program into a **workflow** (orchestration logic that must be deterministic) and **activities** (arbitrary side-effecting calls). The workflow never performs an action itself; it emits _commands_ to the server, and the server turns each command into _events_ in a durable per-execution history. When a worker crashes, any worker can fetch the history and re-run the workflow function from the top; every command the code re-issues is matched against the recorded events, every already-completed activity result is fed back from history instead of being executed again, and execution continues from the first unrecorded command. The documentation's summary ([`docs/encyclopedia/event-history/event-history.mdx`][doc-event-history]):

> _"Each time your Workflow Definition makes an API call to execute an Activity or start a Timer for instance, it doesn't perform the action directly. Instead, it sends a Command to the Temporal Service. … These Commands are then mapped to Events which are persisted in case of failure. For example, if the Worker crashes, the Worker uses the Event History to replay the code and recreate the state of the Workflow Execution to what it was immediately before the crash."_

### Design philosophy

Three commitments shape everything below.

1. **Replay, not snapshot.** Workflow state is never serialized. The program is its own checkpoint: history plus deterministic code reconstructs any intermediate state. The price is a hard determinism contract on workflow code, stated bluntly in the Go SDK's internal `workflow` interface doc ([`internal/internal_workflow.go`][go-internal-workflow]): _"Code of a workflow must be deterministic. It must use workflow.Channel, workflow.Selector, and workflow.Go instead of native channels, select and go. It also must not use range operation over map as it is randomized by go runtime. All time manipulation should use current time returned by GetTime(ctx) method."_
2. **The server is the only writer of the journal.** A command becomes an event only when the server's `workflowTaskCompletedHandler` accepts it ([`workflow_task_completed_handler.go`][srv-wtc-handler]); the SDK cannot append, edit or compact history. The SDK's escape hatch for recording arbitrary data is one event type, `MarkerRecorded`, which the server _"will only store … and will not try to understand"_ ([`docs/references/events.mdx`][doc-events]).
3. **Activities are at-least-once; idempotency is the user's job.** The documentation recommends but cannot enforce idempotency ([`docs/encyclopedia/activities/activity-definition.mdx`][doc-activity-def]): _"By design, completed Activities will not re-execute as part of a Workflow Replay. However, Activities won't record to the Event History until they return or produce an error. If an Activity fails to report to the server at all, it will be retried."_

Compared with the effect-handler systems elsewhere in this topic, Temporal is closest to [Effect's][ts-effect] `Effect` values in spirit (a description of a computation, interpreted by a runtime) but with the interpretation split across a network boundary and with the journal, not the handler stack, as the source of truth.

---

## How it works

### The history model

An execution's journal is a list of `HistoryEvent` records, each with a monotonically increasing `event_id`, an `event_time`, an `event_type` and a type-specific attributes message. The Go SDK's replayer dispatches on every type in one switch ([`internal/internal_event_handlers.go`][go-event-handlers], `ProcessEvent`); the server's mutable state exposes one `Add…Event` method per type ([`service/history/workflow/mutable_state_impl.go`][srv-mutable-state]). The families that matter for this survey:

| Family              | Events                                                                                                                                                                                                      | Written by                                                     |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| Workflow task       | `WorkflowTaskScheduled`, `WorkflowTaskStarted`, `WorkflowTaskCompleted`, `WorkflowTaskTimedOut`, `WorkflowTaskFailed`                                                                                       | Server, around each invocation of the workflow function        |
| Activity            | `ActivityTaskScheduled`, `ActivityTaskStarted`, `ActivityTaskCompleted`, `ActivityTaskFailed`, `ActivityTaskTimedOut`, `ActivityTaskCancelRequested`, `ActivityTaskCanceled`                                | `Scheduled` from a command; the rest from activity worker RPCs |
| Timer               | `TimerStarted`, `TimerFired`, `TimerCanceled`                                                                                                                                                               | `Started`/`Canceled` from commands; `Fired` by the server      |
| Marker              | `MarkerRecorded`                                                                                                                                                                                            | From a `RecordMarker` command; opaque to the server            |
| Child workflow      | `StartChildWorkflowExecutionInitiated`, `ChildWorkflowExecutionStarted`, `…Completed`, `…Failed`, `…Canceled`, `…TimedOut`, `…Terminated`                                                                   | Initiated from a command; the rest by the server               |
| Execution lifecycle | `WorkflowExecutionStarted`, `…Completed`, `…Failed`, `…TimedOut`, `…Canceled`, `…Terminated`, `…ContinuedAsNew`, `…Signaled`, `WorkflowExecutionUpdateAccepted/Completed`, `UpsertWorkflowSearchAttributes` | Mixed                                                          |

Two structural facts about this journal are load-bearing. First, `ActivityTaskScheduled` is the _command_ (intent), and `ActivityTaskCompleted` (with `result`, `scheduled_event_id`, `started_event_id`) is the _observation_ (outcome); the `ActivityTaskStarted` event between them _"is not written to History until the terminal Event … occurs"_ ([`docs/references/events.mdx`][doc-events]). Second, each command-derived event carries `workflow_task_completed_event_id`, which pins it to the workflow task that produced it, so history is a sequence of `[WorkflowTaskScheduled, WorkflowTaskStarted, WorkflowTaskCompleted, <command events>…, <server events>…]` groups. Replay walks those groups: the SDK runs the workflow function up to the `WorkflowTaskStarted` boundary, collects the commands it produced, and checks them against the events that follow the matching `WorkflowTaskCompleted`.

On the server, events are stored as opaque encoded blobs in a `history_node` table; the PostgreSQL schema ([`schema/postgresql/v12/temporal/schema.sql`][srv-schema]):

```sql
CREATE TABLE history_node (
  shard_id       INTEGER NOT NULL,
  tree_id        BYTEA NOT NULL,
  branch_id      BYTEA NOT NULL,
  node_id        BIGINT NOT NULL,
  txn_id         BIGINT NOT NULL,
  --
  prev_txn_id    BIGINT NOT NULL DEFAULT 0,
  data           BYTEA NOT NULL,
  data_encoding  VARCHAR(16) NOT NULL,
  PRIMARY KEY (shard_id, tree_id, branch_id, node_id, txn_id)
);
```

A `tree_id`/`branch_id` pair identifies one history branch; `node_id` is the first event id of a batch; `txn_id` orders concurrent writers. Branching exists for cross-cluster replication and reset, which is why history is a tree rather than a flat list.

### The user-facing shape

The Go SDK ([`internal/workflow.go`][go-workflow]) exposes the determinism-safe vocabulary as functions over a `workflow.Context`:

```go
func Now(ctx Context) time.Time                       // "the time when the workflow task is started or replayed"
func Sleep(ctx Context, d time.Duration) error        // a server-side timer, not time.Sleep
func Go(ctx Context, f func(ctx Context))             // a coroutine, not a goroutine
func NewSelector(ctx Context) Selector                 // instead of select
func SideEffect(ctx Context, f func(ctx Context) any) converter.EncodedValue
func MutableSideEffect(ctx Context, id string, f func(ctx Context) any, equals func(a, b any) bool) converter.EncodedValue
func GetVersion(ctx Context, changeID string, minSupported, maxSupported Version) Version
func ExecuteActivity(ctx Context, activity any, args ...any) Future
func ExecuteChildWorkflow(ctx Context, childWorkflow any, args ...any) ChildWorkflowFuture
```

`Now` is literally the replay clock: it returns `wc.currentReplayTime`, which is set from the `event_time` of each `WorkflowTaskStarted` event as it is processed ([`internal/internal_event_handlers.go`][go-event-handlers]). The TypeScript SDK ([`packages/workflow/src/workflow.ts`][ts-workflow]) exposes the same surface as module functions inside a sandbox: `sleep`, `condition`, `proxyActivities`, `executeChild`, `patched`, `deprecatePatch`, `uuid4`, `continueAsNew`.

### From command to event and back

Each SDK keeps a per-execution command buffer. In Go, every command-producing call draws a fresh id from one monotonic counter, `commandsHelper.getNextID()`; `ExecuteActivity` sets `ScheduleID` from it and derives `ActivityID = getStringID(ScheduleID)` unless the caller supplied one ([`internal/internal_event_handlers.go`][go-event-handlers]). Timers, signals, cancellations and version markers all draw from the same counter, so the _n_-th command-producing call in program order always gets the same id on replay. In TypeScript the same role is played by per-kind sequence numbers, `activator.nextSeqs.timer++` and friends, attached to each command pushed with `activator.pushCommand` ([`packages/workflow/src/internals.ts`][ts-internals]).

When a workflow task completes, the SDK sends the buffered commands; the server's `handleCommand` switch converts each into exactly one event via mutable state ([`workflow_task_completed_handler.go`][srv-wtc-handler]):

```go
switch command.GetCommandType() {
case enumspb.COMMAND_TYPE_SCHEDULE_ACTIVITY_TASK:
    historyEvent, response, err = handler.handleCommandScheduleActivity(ctx, command.GetScheduleActivityTaskCommandAttributes())
case enumspb.COMMAND_TYPE_START_TIMER:
    historyEvent, err = handler.handleCommandStartTimer(ctx, command.GetStartTimerCommandAttributes())
case enumspb.COMMAND_TYPE_RECORD_MARKER:
    historyEvent, err = handler.handleCommandRecordMarker(ctx, command.GetRecordMarkerCommandAttributes())
// … CompleteWorkflow, FailWorkflow, CancelTimer, RequestCancelActivity, StartChildWorkflow,
//   SignalExternalWorkflow, ContinueAsNew, UpsertSearchAttributes, ModifyWorkflowProperties, ProtocolMessage
}
```

### The nondeterminism check (Go)

Replay produces a list of commands; the history segment that followed the corresponding `WorkflowTaskCompleted` is a list of events. `matchReplayWithHistory` zips them ([`internal/internal_task_handlers.go`][go-task-handlers]):

```go
func matchReplayWithHistory(replayCommands []*commandpb.Command, historyEvents []*historypb.HistoryEvent, msgs []outboxEntry, sdkFlags *sdkFlags) error {
    di, hi := 0, 0
    for hi < len(historyEvents) || di < len(replayCommands) {
        // … skip events/commands the check ignores (server-originated events, version-marker + search-attribute pairs)
        if d == nil {
            return historyMismatchErrorf("[TMPRL1100] nondeterministic workflow: missing replay command for %s", util.HistoryEventToString(e))
        }
        if e == nil {
            return historyMismatchErrorf("[TMPRL1100] nondeterministic workflow: extra replay command for %s", util.CommandToString(d))
        }
        if !isCommandMatchEvent(d, e, msgs) {
            return historyMismatchErrorf("[TMPRL1100] nondeterministic workflow: history event is %s, replay command is %s", …)
        }
        di++; hi++
    }
    return nil
}
```

`isCommandMatchEvent` is deliberately shallow. A `ScheduleActivityTask` command matches an `ActivityTaskScheduled` event when the `activity_id`s agree and the _last dotted segment_ of the activity type name agrees (`lastPartOfName`); a `StartTimer` matches a `TimerStarted` on `timer_id` alone; `CompleteWorkflowExecution` matches any `WorkflowExecutionCompleted`. Arguments, timeouts and retry policies are not compared, which is exactly the freedom the documentation grants: _"you can change: The input parameters, return values, and execution timeouts of Child Workflows and Activities"_ ([`docs/encyclopedia/workflow/workflow-definition.mdx`][doc-workflow-def]).

There is a second, earlier detector. Events are applied to per-command state machines (`internal/internal_command_state_machine.go`); when history delivers, say, an `ActivityTaskCompleted` for a command the replayed code never issued, `getCommand` panics with _"[TMPRL1100] During replay, a matching %v command was expected in history event position %s. However, the replayed code did not produce that. Possible causes are nondeterministic workflow definition code, or an incompatible change in the workflow definition."_, and an event arriving in an impossible state trips `failStateTransition` ([`internal/internal_command_state_machine.go`][go-csm]). The comment above the check in `ProcessWorkflowTask` names both routes ([`internal/internal_task_handlers.go`][go-task-handlers]): _"Non-deterministic error could happen in 2 different places: 1) the replay commands does not match to history events. … 2) the command state machine is trying to make illegal state transition while replay a history event (like activity task completed), but the corresponding workflow code that start the event has been removed."_

What happens next is a worker policy, not a workflow outcome ([`internal/worker.go`][go-worker]): `BlockWorkflow` (the default) _"causes workflow to get stuck in the workflow task retry loop. It is expected that after the problem is discovered and fixed the workflows are going to continue without any additional manual intervention"_; `FailWorkflow` _"immediately fails workflow execution … WARNING: enabling this in production can cause all open workflows to fail on a single bug or bad deployment."_

### The nondeterminism check (TypeScript)

The TypeScript worker does not implement the matcher. Its `.gitmodules` pins `packages/core-bridge/sdk-core` to the Rust core ([`.gitmodules`][ts-gitmodules]); the core owns history pagination, the command/event state machines and the check. The TypeScript side sees the verdict as an eviction: `evictionReasonToReplayError` maps `EvictionReason.NONDETERMINISM` to a `DeterminismViolationError` whose message reads _"Replay failed with a nondeterminism error. This means that the workflow code as written is not compatible with the history that was fed in"_ ([`packages/worker/src/replay.ts`][ts-replay]).

### The TypeScript determinism sandbox

Each workflow runs in a Node `vm` context (`vm.ts` describes the creator as making _"VMWorkflows in the current isolate"_; `reuseV8Context`, default `true`, shares one context across workflows for a measured _"2/3 reduction in memory usage"_ ([`packages/worker/src/worker-options.ts`][ts-worker-options])). Calls into the context run under `isolateExecutionTimeoutMs` ([`packages/worker/src/workflow/vm.ts`][ts-vm]). Inside, `overrideGlobals` rewrites the ambient nondeterminism ([`packages/workflow/src/global-overrides.ts`][ts-global-overrides]):

```ts
global.WeakRef = function () {
  throw new DeterminismViolationError('WeakRef cannot be used in Workflows because v8 GC is non-deterministic');
};
global.Date = function (...args: unknown[]) {
  if (args.length > 0) return new (OriginalDate as any)(...args);
  return new OriginalDate(getActivator().now);   // the activation's timestamp, not the wall clock
};
global.Date.now = function () { return getActivator().now; };
global.setTimeout = function (cb, ms, ...args) {   // becomes a StartTimer command
  const seq = activator.nextSeqs.timer++;
  activator.pushCommand({ startTimer: { seq, startToFireTimeout: msToTs(ms) } });
  …
};
Math.random = currentRandom;                        // alea PRNG seeded from the activation's randomnessSeed
```

`injectGlobals` then installs a fixed allowlist (`URL`, `TextEncoder`, `assert`, `AbortController`, a `console` that is silent while `isReplayingHistoryEvents`) ([`packages/worker/src/workflow/vm-shared.ts`][ts-vm-shared]). The sandbox blocks the _accidental_ leaks (time, randomness, GC observation, timers) but not deliberate ones: a workflow module can still import `fs` unless the bundler's module overrides refuse it, so the enforcement is partial.

### Side effects, markers and versioning

`SideEffect` runs `f` once when live and records the result in a `MarkerRecorded` event; on replay it looks the value up by its side-effect id and panics if absent ([`internal/internal_event_handlers.go`][go-event-handlers]):

```go
if wc.isReplay {
    result, ok = wc.sideEffectResult[sideEffectID]
    if !ok {
        panicIllegalState(fmt.Sprintf("[TMPRL1100] No cached result found for side effectID=%v. KnownSideEffects=%v", sideEffectID, keys))
    }
} else {
    result, err = f()
}
wc.commandsHelper.recordSideEffectMarker(sideEffectID, result, wc.dataConverter, userMetadata)
```

`MutableSideEffect` is the one place Temporal re-observes the world: when live it runs `f`, compares with the recorded value through the caller's `equals`, and records a new marker only if the value changed; when replaying it returns the recorded value without calling `f`, and a missing marker is a nondeterminism panic ([`internal/internal_event_handlers.go`][go-event-handlers]). `GetVersion` is a marker too: the first live call records `versionMarkerName` with the change id and chosen version and upserts a `TemporalChangeVersion` search attribute; on replay a missing marker yields `DefaultVersion` (_"GetVersion for changeID is called first time in replay mode, use DefaultVersion"_), and the recorded version is validated against the `[minSupported, maxSupported]` window the current code declares.

TypeScript's `patched(id)` is the same mechanism with a boolean: on replay, `notifyHasPatch` jobs from the core populate `knownPresentPatches`; `patchInternal` returns `false` if replaying without the marker, otherwise records a `setPatchMarker` command and returns `true` ([`packages/workflow/src/internals.ts`][ts-internals]). `deprecatePatch(id)` records the marker but never branches; its doc warns that mixing workers with and without the patch is _"undefined"_ ([`packages/workflow/src/workflow.ts`][ts-workflow]).

Beneath user versioning sits a second, SDK-internal layer: `WorkflowTaskCompleted` carries `sdk_metadata.lang_used_flags`, and both SDKs gate their own replay-affecting behaviour changes on flags read back from history ([`internal/internal_flags.go`][go-flags]; [`packages/workflow/src/flags.ts`][ts-flags]). The TypeScript flag table is candid about why: one entry notes that _"SDKs v1.11.0 and v1.11.1 were not properly writing back the flags to history, possibly resulting in NDE on replay"_ and works around it by inferring the flag from the recorded build id.

### Activities: retries, heartbeats, idempotency

Activities are retried by the server under a declarative per-activity `RetryPolicy`; _"Temporal's default behavior is to automatically retry an Activity that fails"_, bounded by the activity's `schedule_to_close_timeout`, whereas _"a Workflow Execution itself is not associated with a Retry Policy by default"_ ([`docs/encyclopedia/retry-policies.mdx`][doc-retry]). Long activities must call `RecordHeartbeat` within `HeartbeatTimeout`, both to prove liveness and because _"Activities must heartbeat to receive cancellations from a Temporal Service"_ ([`docs/encyclopedia/activities/activity-execution.mdx`][doc-activity-exec]). Heartbeat details are the only activity-side progress that survives a retry; everything else is the activity's own idempotency.

### Continue-As-New and history size

History is bounded by dynamic config ([`common/dynamicconfig/constants.go`][srv-dynconfig]): `limit.historySize.error` at 50 MiB, `limit.historyCount.error` at 51,200 events, warnings at a fifth of each, and `limit.historySize.suggestContinueAsNew` at 4 MiB, which surfaces as `suggest_continue_as_new` on `WorkflowTaskStarted` and as `continueAsNewSuggested` in the Go SDK's `WorkflowInfo`. The escape is `NewContinueAsNewError`: _"the current execution is ended and the new execution with same workflow ID is started automatically"_ ([`internal/error.go`][go-error]) with a fresh history and whatever state the workflow passes as arguments. The documentation adds a second motive ([`docs/encyclopedia/workflow/workflow-execution/continue-as-new.mdx`][doc-can]): _"To prevent long-running Workflows from running on stale versions of code, you may also want to Continue-as-New periodically."_

---

## Analysis

### 1. Step identity and replay matching

A step is identified **positionally**, by the order in which command-producing calls execute, and the position is materialized as an id drawn from a per-execution counter (Go: `commandsHelper.getNextID()` → `ScheduleID`/`ActivityID`/`TimerID`; TypeScript: `nextSeqs.<kind>++`). Matching is a two-pointer zip of the replayed command list against the recorded event list per workflow task ([`matchReplayWithHistory`][go-task-handlers]), comparing command type, the counter-derived id, and, for activities, only the last segment of the type name. Arguments are never hashed or compared. The result is that inserting or removing _any_ command-producing call before a step shifts every later id and fails replay, while changing what a step _does_ (its inputs, timeouts, retry policy) is invisible to the check. The documentation lists exactly which calls are command-producing and therefore _"must not be reordered, added, or removed without proper Versioning techniques"_ ([`docs/encyclopedia/workflow/workflow-definition.mdx`][doc-workflow-def]). Explicitly named steps exist only as opt-ins: a caller-supplied `ActivityID`, a `MutableSideEffect` id, a `GetVersion` change id, a `patched` id.

### 2. Journal versus world

**The journal wins, unconditionally, and the world is not consulted.** Replay feeds recorded `ActivityTaskCompleted` results back to the code; a completed activity is never re-run, and nothing re-checks whether its effect still holds. Disagreement is detected in only one direction: the code disagreeing with the journal (nondeterminism). The world disagreeing with the journal is by design invisible to the workflow and is handled at the activity boundary by retries plus idempotency: _"If an Activity fails to report to the server at all, it will be retried"_ ([`docs/encyclopedia/activities/activity-definition.mdx`][doc-activity-def]), so the same external action can execute twice with one recorded completion. `MutableSideEffect` is the single reconciling primitive, and it reconciles only during live execution, never during replay. There is no rule table for observations; Temporal's position is that a workflow should not observe the world except through activities, and that activity results, once recorded, are facts.

### 3. Determinism enforcement

**Discipline, backed by runtime substitution and runtime detection; never by the language.** Go offers no isolation at all: the SDK substitutes `workflow.Now`, `Sleep`, `Go`, `Channel`, `Selector` for their stdlib counterparts and documents that the stdlib forms _"must not be used in workflow code"_ ([`internal/workflow.go`][go-workflow]), but a stray `time.Now()` or `go func()` compiles and runs. TypeScript goes further with a `vm` context whose globals are rewritten (`Date`, `Date.now`, `setTimeout`, `Math.random`) or made to throw (`WeakRef`, `FinalizationRegistry`) ([`packages/workflow/src/global-overrides.ts`][ts-global-overrides]). Both SDKs then rely on detection after the fact: the command/event zip and the state-machine transitions raise `[TMPRL1100]` errors, and the TypeScript replayer surfaces them as `DeterminismViolationError`. Detection is bounded by the check's shallowness (§1): a nondeterministic branch that happens to issue the same command sequence passes.

### 4. Compensation and failure handling

**No built-in compensation in the Go or TypeScript SDKs; it is a documented pattern.** The saga page ([`docs/design-patterns/saga-pattern.mdx`][doc-saga]) shows a `[]func()` slice appended to before each step and drained in reverse (_"register a compensation before or after each step, and run all compensations in reverse order on failure"_), with two rules that matter: register the compensation _before_ the step it undoes (_"`disconnectBankAccounts` is registered before `addBankAccount` runs, so it executes even if `addBankAccount` failed mid-flight — its implementation must be idempotent"_), and _"Use a disconnected context for cancellation compensation. In Go, use `NewDisconnectedContext` to run compensation Activities after Workflow cancellation, since the original context is already cancelled."_ Compensations are themselves activities, so they are journaled and retried like any other step; the LIFO order is reconstructed by replay because the slice is rebuilt deterministically. Only the Java SDK ships a `Saga` class. Failure handling proper is layered: activity retries (server, declarative), workflow task retries (unbounded, exponential, for panics and nondeterminism under `BlockWorkflow`), and workflow-level `RetryPolicy` (opt-in, uncommon).

### 5. Versioning against old histories

**Marker-based branching, plus deployment-level pinning.** `GetVersion`/`patched` record a marker at the first live call and read it back on replay, so old histories take the old branch and new executions take the new one; the recorded version is validated against the window the current code supports, which is how a too-old history fails loudly rather than silently ([`internal/internal_event_handlers.go`][go-event-handlers]). The documentation's `patched()` semantics page spells out the sharp edges ([`docs/encyclopedia/workflow/patching.mdx`][doc-patching]): a marker that appears _later_ in history than the current call is a nondeterminism error, and _"if there is no marker for a given patch ID, the execution will return `false` and will not add a marker to the event history. In addition, all future calls to `patched()` with that ID will return `false` -- even after it is done replaying and is running new code."_ The lifecycle is three deploys: add `patched`, replace with `deprecatePatch`, remove. Orthogonally, Worker Versioning assigns each worker a deployment name plus build id and each workflow type a behaviour: _"A Pinned Workflow is guaranteed to complete on a single Worker Deployment Version"_, while auto-upgrade workflows _"need to be kept replay-safe manually, that is with patching"_ ([`docs/encyclopedia/workers/worker-versioning.mdx`][doc-worker-versioning]; Go `WorkerDeploymentOptions{UseVersioning, Version, DefaultVersioningBehavior}` in [`internal/worker.go`][go-worker]). Continue-As-New is the third tool: a fresh history has no old code to be compatible with.

### 6. Concurrency under replay

**Cooperative, single-threaded, deterministically scheduled.** The Go SDK's dispatcher _"executes coroutines one by one in deterministic order until all of them are completed or blocked on Channel or Selector"_ ([`internal/internal_workflow.go`][go-internal-workflow]); `workflow.Go` creates a coroutine on that dispatcher, and `ExecuteUntilAllBlocked` loops over the coroutine slice in order, inserting eagerly-created children right after their parent. `Selector.Select` iterates its cases in registration order (`for _, pair := range s.cases`) even though the interface comment says an eligible branch is _"picked randomly"_, a discrepancy worth knowing when reading that doc. Because the interleaving is a pure function of the event order, concurrent steps replay by re-running the same schedule. TypeScript gets the same property from JavaScript's single thread and microtask queue, at the cost that the _order in which the SDK dispatches activation jobs_ becomes part of the replay contract: `ProcessWorkflowActivationJobsAsSingleBatch` exists because reordering signal dispatch relative to other jobs changed promise interleavings and hence command order ([`packages/workflow/src/flags.ts`][ts-flags]). Unblocked concurrent activities are matched by id, so their completion events may arrive in any order.

### 7. Replay or snapshot

**Replay, with a cache to avoid paying for it.** A worker keeps the live workflow in a sticky cache and the server routes later tasks to it; only on eviction or crash is the full history fetched and replayed ([`docs/encyclopedia/workflow/workflow-execution/workflow-execution.mdx`][doc-workflow-exec]). Replay cost is linear in history, so history is capped (51,200 events, 50 MiB) and the server nudges the workflow to `Continue-As-New` at 4 MiB. Replay rules out: any state not reconstructible from history (hence the sandbox), any code change that alters command order (hence markers), and any history larger than the cap (hence Continue-As-New, which is a manual snapshot expressed as workflow arguments). What it buys: the journal is small and typed (intents and outcomes, not state), any worker can resume any execution, and the same history is a regression test.

### 8. Testing

Three tiers. **Replay tests**: `worker.NewWorkflowReplayer().ReplayWorkflowHistory(...)` in Go ([`worker/worker.go`][go-worker-pkg]) and `Worker.runReplayHistory(options, history)` in TypeScript, which _"Will resolve as soon as the history has finished being replayed, or if the workflow produces a nondeterminism error"_ ([`packages/worker/src/worker.ts`][ts-worker]); the documentation recommends downloading _"a representative set of recent open and closed Workflows"_ and failing CI on any replay error ([`docs/develop/go/best-practices/testing-suite.mdx`][doc-go-testing]). **Unit tests with a mock clock**: Go's `TestWorkflowEnvironment` runs the workflow against a `clock.Mock` that _"automatically move[s] forward to fire next timer when workflow is blocked"_ ([`internal/workflow_testsuite.go`][go-testsuite]), with `RegisterDelayedCallback` to inject signals at workflow-clock times. **Integration tests with a real server**: TypeScript's `TestWorkflowEnvironment.createTimeSkipping` runs the Java time-skipping test server, where _"Time skipping, which is automatically done when awaiting a workflow result and manually done on sleep, is global to the environment"_, and `createLocal` runs the real dev server without time skipping ([`packages/testing/src/testing-workflow-environment.ts`][ts-testing]). There is no crash-at-every-event test primitive; the replayer is the closest thing, and it tests compatibility of code with a _finished_ history rather than resumption from each prefix.

---

## Strengths

- **The journal is intents and outcomes, not state.** Every event is a small typed record with an id; the schema doubles as an audit log and a debugger input, and the replayer is the same code path as production.
- **Two independent detectors for drift** (the command/event zip and the state-machine transitions), both with the searchable `[TMPRL1100]` tag.
- **Markers make versioning a data problem.** `GetVersion`/`patched` write the decision into the journal at the first live call, so the old branch is provable, not inferred.
- **Deterministic scheduling is owned by the SDK**, so `workflow.Go`/`Selector` replay by construction and concurrent activities are matched by id, not by completion order.
- **Retries, heartbeats and timeouts are declarative and server-enforced**, which keeps the activity-side contract to one word: idempotent.
- **History caps plus `suggest_continue_as_new`** turn an unbounded-replay failure mode into a signal the workflow can act on.

## Weaknesses

- **Positional identity is brittle.** Inserting one `sleep` before a step renumbers everything after it; the fix is a marker at every insertion point, forever, until every old history is gone.
- **The match is shallow.** Arguments are not compared, so a nondeterministic branch that yields the same command shape is undetected; conversely the activity-type match uses only the last dotted name segment.
- **The world is never re-observed.** A recorded activity completion is a fact even if the effect was later undone; there is no reconciliation rule beyond "make the activity idempotent".
- **No compensation primitive in Go/TypeScript.** The LIFO slice is a convention, and its correctness under cancellation depends on remembering `NewDisconnectedContext`.
- **Enforcement is partial.** Go has no sandbox; TypeScript's sandbox patches globals but relies on bundler discipline to keep `fs` and `process` out.
- **`BlockWorkflow` means silent stalls.** The default response to a nondeterminism error is to retry the workflow task forever until a deploy fixes it.
- **The SDK's own behaviour changes are versioned by flags in history**, and the TypeScript flag table records at least one release that failed to write them, which then had to be inferred from build ids.

## Key design decisions and trade-offs

| Decision                                                                | Rationale                                                                               | Trade-off                                                                                                      |
| ----------------------------------------------------------------------- | --------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| Server owns the journal; SDK only proposes commands                     | Any worker can resume any execution; the server can validate, cap and replicate history | Every step is a network round-trip; `MarkerRecorded` is the only SDK-controlled record                         |
| Positional step ids from one counter                                    | Zero annotation burden; ids are stable for unchanged code                               | Any inserted command-producing call invalidates all later ids; versioning markers are the only remedy          |
| Shallow command/event match (type + id + last name segment)             | Lets inputs, timeouts and retry policies change without a version bump                  | Cannot detect a branch that happens to issue the same command shape with different meaning                     |
| Activities at-least-once, results journaled on completion               | Simple activity contract; retries are server-side and declarative                       | Duplicate side effects are the user's problem; no reconciliation of journal against world                      |
| `SideEffect`/`MutableSideEffect` markers for in-workflow nondeterminism | Keeps short observations out of the activity machinery                                  | Value is captured once; `MutableSideEffect` re-observes only when live                                         |
| TypeScript `vm` sandbox with rewritten globals                          | Catches accidental time/random/GC leaks at runtime with a clear error                   | Not a security boundary; `reuseV8Context` shares a context for performance                                     |
| Go: cooperative coroutine dispatcher instead of goroutines              | Deterministic interleaving without OS scheduling                                        | A whole parallel vocabulary (`workflow.Go`, `Channel`, `Selector`) that the compiler does not enforce          |
| Nondeterminism default = `BlockWorkflow`                                | A bad deploy can be rolled back without losing executions                               | Workflows stall silently until someone notices the failing-task metric                                         |
| History caps + `Continue-As-New`                                        | Bounds replay time and storage                                                          | The user must design a checkpoint-as-arguments shape and pick when to cut                                      |
| Worker Versioning with pinned/auto-upgrade behaviours                   | Old code keeps running old executions; no patching needed for pinned types              | Operational surface (deployments, ramps, drain states) and a still-shifting API (`BuildID` already deprecated) |

## Relevance to sparkles

- **Confirms the two-record shape.** Temporal's `ActivityTaskScheduled` (intent, with the id the code chose) and `ActivityTaskCompleted` (outcome, with `scheduled_event_id` back-reference) are exactly the design's `started` + `completed` pair, and the back-reference is what lets concurrent completions land out of order. The journal should carry the intent id in the completion record.
- **Argues for a name, not a counter, as step identity.** Temporal's positional ids are the root of its versioning pain: every inserted call renumbers the tail. The design's stable name plus attempt counter plus args hash is strictly stronger; keep it. But note that Temporal deliberately does _not_ compare arguments so inputs can change without a version bump; the design's args-hash-in-the-key means a changed argument reads as a _new_ step, which is the right call for `release` (a different tag name is a different action) but should be a documented choice, not an accident.
- **Argues against "the journal wins" for observations, and the design already diverges.** Temporal never re-observes; it relies on idempotent activities and accepts duplicate effects. The design's re-observe-and-reconcile rule table for git tags and HEAD is the thing Temporal lacks, and `MutableSideEffect` (run, compare with `equals`, record only on change) is the nearest Temporal analogue: a per-observation equality plus a policy for what to do on inequality. Worth borrowing its shape: observation steps carry an `equals` and a reconciliation verdict, both journaled.
- **The `[TMPRL1100]` detector pair is the test the design needs.** "Missing replay command", "extra replay command" and "mismatched command" are the three failure classes for a replaying journal; the crash-at-every-index test should assert each is raised, not just that resumption succeeds. Add the state-machine variant too: a `completed` record whose `started` the replaying code never produced.
- **Compensation as a journaled, LIFO, explicit-only slice is what Temporal's docs recommend**, including the two rules the design should adopt verbatim: register before the step it undoes, and run compensations on a context that survives cancellation (the effect-row analogue of `NewDisconnectedContext`).
- **Versioning is the gap.** The design says nothing about running new `release` code against a journal written by old code. Temporal's answer is a marker at the first live decision point plus a supported-version window that fails loudly. With named steps the design can do better (a renamed or removed step is detectable by name), but a `version` marker step with `[min, max]` validation is cheap and turns "old journal, new code" from undefined into an error with a message.
- **Determinism enforcement will be by discipline, as in Go.** D has no sandbox; the design's "single pure-cast in the journaling combinator" is the Go SDK's position (substitute the primitives, document the rest). The TypeScript lesson is that the substitutions worth making are clock, randomness and timers; the design's `TestClock` already covers the first and third.
- **Replay tests against saved journals are the cheapest regression suite Temporal has**, and the design's `journal.jsonl` makes them trivial: check journals from real runs into the tree and replay them in CI, failing on any of the three mismatch classes. Continue-As-New has no analogue needed; a `release` run is bounded.

---

## Sources

- [temporalio/temporal — server repository][repo-server]
- [temporalio/sdk-go — Go SDK repository][repo-go]
- [temporalio/sdk-typescript — TypeScript SDK repository][repo-ts]
- [temporalio/documentation — docs source][repo-docs]
- [docs.temporal.io][docs-home]
- [`internal/internal_task_handlers.go` — `matchReplayWithHistory`, `isCommandMatchEvent`, the two nondeterminism routes][go-task-handlers]
- [`internal/internal_event_handlers.go` — `ProcessEvent` switch, `GenerateSequence`, `Now`, `SideEffect`, `MutableSideEffect`, `GetVersion`, `handleMarkerRecorded`][go-event-handlers]
- [`internal/internal_command_state_machine.go` — `getCommand`, `failStateTransition`][go-csm]
- [`internal/internal_workflow.go` — dispatcher contract, `ExecuteUntilAllBlocked`, `selectorImpl.Select`][go-internal-workflow]
- [`internal/workflow.go` — public API docs: `Now`, `Go`, `Selector`, `SideEffect`, `MutableSideEffect`, `GetVersion`][go-workflow]
- [`internal/worker.go` — `WorkflowPanicPolicy`, `WorkerDeploymentOptions`, `PreferredVersionProvider`][go-worker]
- [`internal/error.go` — `NewContinueAsNewError`][go-error]
- [`internal/internal_flags.go` — SDK flags][go-flags]
- [`internal/workflow_testsuite.go` — `TestWorkflowEnvironment`, `RegisterDelayedCallback`][go-testsuite]
- [`worker/worker.go` — `NewWorkflowReplayer`][go-worker-pkg]
- [`packages/workflow/src/global-overrides.ts` — the sandbox overrides][ts-global-overrides]
- [`packages/workflow/src/internals.ts` — `Activator`, `nextSeqs`, `pushCommand`, `patchInternal`][ts-internals]
- [`packages/workflow/src/workflow.ts` — `sleep`, `patched`, `deprecatePatch`, `uuid4`][ts-workflow]
- [`packages/workflow/src/flags.ts` — SDK flags and the 1.11.0 note][ts-flags]
- [`packages/worker/src/replay.ts` — `evictionReasonToReplayError`][ts-replay]
- [`packages/worker/src/worker.ts` — `runReplayHistory`, `runReplayHistories`][ts-worker]
- [`packages/worker/src/worker-options.ts` — `reuseV8Context`, `workerDeploymentOptions`][ts-worker-options]
- [`packages/worker/src/workflow/vm.ts`][ts-vm] · [`packages/worker/src/workflow/vm-shared.ts` — `injectGlobals`][ts-vm-shared]
- [`packages/testing/src/testing-workflow-environment.ts` — `createTimeSkipping`, `createLocal`][ts-testing]
- [`.gitmodules` — the `sdk-core` submodule][ts-gitmodules]
- [`service/history/api/respondworkflowtaskcompleted/workflow_task_completed_handler.go` — `handleCommand`][srv-wtc-handler]
- [`service/history/workflow/mutable_state_impl.go` — `Add…Event` methods][srv-mutable-state]
- [`schema/postgresql/v12/temporal/schema.sql` — `history_node`][srv-schema]
- [`common/dynamicconfig/constants.go` — history size and count limits][srv-dynconfig]
- [Docs: Workflow Definition — deterministic constraints][doc-workflow-def]
- [Docs: Event History][doc-event-history] · [Docs: Events reference][doc-events] · [Docs: Workflow Execution (replay, sticky cache)][doc-workflow-exec]
- [Docs: Activity Definition — idempotency][doc-activity-def] · [Docs: Activity Execution — heartbeats][doc-activity-exec] · [Docs: Retry Policies][doc-retry]
- [Docs: Saga pattern][doc-saga] · [Docs: Patching][doc-patching] · [Docs: Worker Versioning][doc-worker-versioning]
- [Docs: Continue-As-New][doc-can] · [Docs: Go testing suite — replay][doc-go-testing] · [Docs: TypeScript testing suite — replay][doc-ts-testing]
- Related: [Effect (TypeScript)][ts-effect] · [this catalog's index][catalog-index] · [algebraic-effects topic index][topic-index]

<!-- References -->

[repo-server]: https://github.com/temporalio/temporal
[repo-go]: https://github.com/temporalio/sdk-go
[repo-ts]: https://github.com/temporalio/sdk-typescript
[repo-docs]: https://github.com/temporalio/documentation
[docs-home]: https://docs.temporal.io/
[go-task-handlers]: https://github.com/temporalio/sdk-go/blob/fee1a45426e6dd90389ac5af4a45d98a357566b4/internal/internal_task_handlers.go
[go-event-handlers]: https://github.com/temporalio/sdk-go/blob/fee1a45426e6dd90389ac5af4a45d98a357566b4/internal/internal_event_handlers.go
[go-csm]: https://github.com/temporalio/sdk-go/blob/fee1a45426e6dd90389ac5af4a45d98a357566b4/internal/internal_command_state_machine.go
[go-internal-workflow]: https://github.com/temporalio/sdk-go/blob/fee1a45426e6dd90389ac5af4a45d98a357566b4/internal/internal_workflow.go
[go-workflow]: https://github.com/temporalio/sdk-go/blob/fee1a45426e6dd90389ac5af4a45d98a357566b4/internal/workflow.go
[go-worker]: https://github.com/temporalio/sdk-go/blob/fee1a45426e6dd90389ac5af4a45d98a357566b4/internal/worker.go
[go-error]: https://github.com/temporalio/sdk-go/blob/fee1a45426e6dd90389ac5af4a45d98a357566b4/internal/error.go
[go-flags]: https://github.com/temporalio/sdk-go/blob/fee1a45426e6dd90389ac5af4a45d98a357566b4/internal/internal_flags.go
[go-testsuite]: https://github.com/temporalio/sdk-go/blob/fee1a45426e6dd90389ac5af4a45d98a357566b4/internal/workflow_testsuite.go
[go-worker-pkg]: https://github.com/temporalio/sdk-go/blob/fee1a45426e6dd90389ac5af4a45d98a357566b4/worker/worker.go
[ts-global-overrides]: https://github.com/temporalio/sdk-typescript/blob/72615f23ef735ab27ef0cc18cbf3de68f823fdc1/packages/workflow/src/global-overrides.ts
[ts-internals]: https://github.com/temporalio/sdk-typescript/blob/72615f23ef735ab27ef0cc18cbf3de68f823fdc1/packages/workflow/src/internals.ts
[ts-workflow]: https://github.com/temporalio/sdk-typescript/blob/72615f23ef735ab27ef0cc18cbf3de68f823fdc1/packages/workflow/src/workflow.ts
[ts-flags]: https://github.com/temporalio/sdk-typescript/blob/72615f23ef735ab27ef0cc18cbf3de68f823fdc1/packages/workflow/src/flags.ts
[ts-replay]: https://github.com/temporalio/sdk-typescript/blob/72615f23ef735ab27ef0cc18cbf3de68f823fdc1/packages/worker/src/replay.ts
[ts-worker]: https://github.com/temporalio/sdk-typescript/blob/72615f23ef735ab27ef0cc18cbf3de68f823fdc1/packages/worker/src/worker.ts
[ts-worker-options]: https://github.com/temporalio/sdk-typescript/blob/72615f23ef735ab27ef0cc18cbf3de68f823fdc1/packages/worker/src/worker-options.ts
[ts-vm]: https://github.com/temporalio/sdk-typescript/blob/72615f23ef735ab27ef0cc18cbf3de68f823fdc1/packages/worker/src/workflow/vm.ts
[ts-vm-shared]: https://github.com/temporalio/sdk-typescript/blob/72615f23ef735ab27ef0cc18cbf3de68f823fdc1/packages/worker/src/workflow/vm-shared.ts
[ts-testing]: https://github.com/temporalio/sdk-typescript/blob/72615f23ef735ab27ef0cc18cbf3de68f823fdc1/packages/testing/src/testing-workflow-environment.ts
[ts-gitmodules]: https://github.com/temporalio/sdk-typescript/blob/72615f23ef735ab27ef0cc18cbf3de68f823fdc1/.gitmodules
[srv-wtc-handler]: https://github.com/temporalio/temporal/blob/2f7ba7ce3b4afb0db9ccf7aebbf7189e2d38bbef/service/history/api/respondworkflowtaskcompleted/workflow_task_completed_handler.go
[srv-mutable-state]: https://github.com/temporalio/temporal/blob/2f7ba7ce3b4afb0db9ccf7aebbf7189e2d38bbef/service/history/workflow/mutable_state_impl.go
[srv-schema]: https://github.com/temporalio/temporal/blob/2f7ba7ce3b4afb0db9ccf7aebbf7189e2d38bbef/schema/postgresql/v12/temporal/schema.sql
[srv-dynconfig]: https://github.com/temporalio/temporal/blob/2f7ba7ce3b4afb0db9ccf7aebbf7189e2d38bbef/common/dynamicconfig/constants.go
[doc-workflow-def]: https://github.com/temporalio/documentation/blob/01c99ad49289ccd45519f113dcd05b5f6503a331/docs/encyclopedia/workflow/workflow-definition.mdx
[doc-event-history]: https://github.com/temporalio/documentation/blob/01c99ad49289ccd45519f113dcd05b5f6503a331/docs/encyclopedia/event-history/event-history.mdx
[doc-events]: https://github.com/temporalio/documentation/blob/01c99ad49289ccd45519f113dcd05b5f6503a331/docs/references/events.mdx
[doc-workflow-exec]: https://github.com/temporalio/documentation/blob/01c99ad49289ccd45519f113dcd05b5f6503a331/docs/encyclopedia/workflow/workflow-execution/workflow-execution.mdx
[doc-activity-def]: https://github.com/temporalio/documentation/blob/01c99ad49289ccd45519f113dcd05b5f6503a331/docs/encyclopedia/activities/activity-definition.mdx
[doc-activity-exec]: https://github.com/temporalio/documentation/blob/01c99ad49289ccd45519f113dcd05b5f6503a331/docs/encyclopedia/activities/activity-execution.mdx
[doc-retry]: https://github.com/temporalio/documentation/blob/01c99ad49289ccd45519f113dcd05b5f6503a331/docs/encyclopedia/retry-policies.mdx
[doc-saga]: https://github.com/temporalio/documentation/blob/01c99ad49289ccd45519f113dcd05b5f6503a331/docs/design-patterns/saga-pattern.mdx
[doc-patching]: https://github.com/temporalio/documentation/blob/01c99ad49289ccd45519f113dcd05b5f6503a331/docs/encyclopedia/workflow/patching.mdx
[doc-worker-versioning]: https://github.com/temporalio/documentation/blob/01c99ad49289ccd45519f113dcd05b5f6503a331/docs/encyclopedia/workers/worker-versioning.mdx
[doc-can]: https://github.com/temporalio/documentation/blob/01c99ad49289ccd45519f113dcd05b5f6503a331/docs/encyclopedia/workflow/workflow-execution/continue-as-new.mdx
[doc-go-testing]: https://github.com/temporalio/documentation/blob/01c99ad49289ccd45519f113dcd05b5f6503a331/docs/develop/go/best-practices/testing-suite.mdx
[doc-ts-testing]: https://github.com/temporalio/documentation/blob/01c99ad49289ccd45519f113dcd05b5f6503a331/docs/develop/typescript/best-practices/testing-suite.mdx
[ts-effect]: ../typescript-effect.md
[catalog-index]: ./index.md
[topic-index]: ../index.md
