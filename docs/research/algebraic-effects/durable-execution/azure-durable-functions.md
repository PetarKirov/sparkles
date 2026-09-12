# Azure Durable Functions (.NET / JavaScript)

Microsoft's serverless durable-execution product: an Azure Functions extension built on the Durable Task Framework (DTFx), in which an _orchestrator function_ is re-executed from the top on every wake-up against an append-only event history, plus _durable entities_, an event-sourced actor half that checkpoints state instead of replaying it.

| Field             | Value                                                                                                                                                                                                                                                             |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | C# (extension, DTFx) · TypeScript (`durable-functions` npm SDK); also Python, PowerShell, Java SDKs                                                                                                                                                               |
| License           | MIT (extension, JS SDK) · Apache-2.0 (DTFx)                                                                                                                                                                                                                       |
| Repository        | [Azure/azure-functions-durable-extension][ext-repo] · [Azure/azure-functions-durable-js][js-repo] · [Azure/durabletask][dtfx-repo]                                                                                                                                |
| Documentation     | [Durable Task / Durable Functions docs][docs-orch]                                                                                                                                                                                                                |
| Category          | durable-execution engine (extension + DTFx) with per-language SDKs; durable entities are `event-sourced actors`                                                                                                                                                   |
| Persistence model | `replay` for orchestrations; `snapshot` for entities (state re-persisted per batch via `ContinueAsNew`)                                                                                                                                                           |
| Journal store     | Pluggable `DurabilityProvider` ([storage providers][docs-providers]): Azure Storage (tables + queues + blobs, default), [MSSQL][mssql-repo], [Netherite][netherite-repo] (Event Hubs + FASTER, see [Netherite][netherite-page]), Durable Task Scheduler (managed) |
| Latest release    | `durable-functions` 3.5.0 (npm, `package.json` in the clone) · `Microsoft.Azure.WebJobs.Extensions.DurableTask` 3.15.0 (`.csproj` in the clone) · `DurableTask.Core` 3.9.0                                                                                        |
| Local clone       | `$REPOS/azure-functions-durable-js` at `fcab779bf2bbe5c12f51969009b174c7c6476fdd` · `$REPOS/azure-functions-durable-extension` at `2317b407104b657ada289122090b356d8f4e3539` · `$REPOS/durabletask` at `b385165ac10ecebbf183fdfdb07db33307756792`                 |

**Last reviewed:** September 12, 2026.

This page covers what the Functions extension and its JavaScript SDK add on top of DTFx. The framework itself (its dispatcher, its `TaskOrchestrationContext`, its backends as a standalone library) is the subject of [Dapr Workflow][dapr-page]; only the DTFx mechanics the extension leans on directly are repeated here.

---

## Overview

### What it solves

An Azure Function is stateless and time-limited. Durable Functions lets one function _coordinate_ many others over hours or months while keeping local variables alive across process recycles, without the author writing a state machine. The official overview states the contract ([docs][docs-orch]):

> "They automatically checkpoint execution progress when the function calls an `await` or `yield` operator, so the process doesn't lose local state when it recycles or the VM reboots."

The price is a programming model with hard constraints: the orchestrator is a pure decision function over its own history, and every side effect lives in an _activity function_ whose result is journaled.

### Design philosophy

The system is explicit that it is event sourcing applied to a function body, and that replay is the whole mechanism ([docs][docs-orch]):

> "Instead of directly storing the current state of an orchestration, the Durable Task Framework uses an append-only store to record the full series of actions the function orchestration takes."

> "When an orchestration function gets more work to do (for example, a response message is received or a durable timer expires), the orchestrator wakes up and re-executes the entire function from the start to rebuild the local state. During the replay, if the code tries to call a function (or do any other asynchronous work), the Durable Task Framework consults the execution history of the current orchestration. If it finds that the activity already executed and yielded a result, it replays that function's result, and the orchestrator code continues to run. Replay continues until the function code is finished or until it schedules new asynchronous work."

Three consequences shape everything below:

1. **The orchestrator never touches the world.** Bindings, I/O, HTTP, threads and clocks are all banned from orchestrator code ([code constraints][docs-constraints]). There is therefore no "journal versus world" reconciliation in the engine at all: the world is only ever seen through activity results, and those are frozen in the history.
2. **Two processes, one sequence.** For non-.NET languages the SDK runs in a separate worker process. It receives the history as JSON, replays it against the user's generator, and returns an `actions` array; the extension then replays that array through DTFx's in-process `TaskOrchestrationContext`, which is where sequence IDs are minted and non-determinism is detected. The SDK must therefore _predict_ the IDs DTFx will assign.
3. **Entities do not replay.** A durable entity's state is a JSON blob re-persisted after every batch of operations; the DTFx machinery is reused, but as a snapshot store.

---

## How it works

### The user-facing shape (JavaScript)

An orchestrator is a synchronous generator; each `yield` hands a `Task` back to the SDK's executor and suspends until the history contains its result ([`samples-js/functions/cancelTimer.js`][js-cancel-timer]):

```js
df.app.orchestration('cancelTimer', function* (context) {
  const expiration = DateTime.fromJSDate(context.df.currentUtcDateTime).plus({
    minutes: 2,
  });
  const timeoutTask = context.df.createTimer(expiration.toJSDate());

  const hello = yield context.df.callActivity(
    'sayHello',
    'from the other side',
  );

  if (!timeoutTask.isCompleted) {
    timeoutTask.cancel();
  }

  return hello;
});
```

`context.df` exposes `callActivity`, `callActivityWithRetry`, `callSubOrchestrator`, `callEntity`, `signalEntity`, `createTimer`, `waitForExternalEvent`, `continueAsNew`, `lock`, `Task.all`, `Task.any`, `currentUtcDateTime`, `newGuid`, `isReplaying`, `version` and `setCustomStatus` ([`DurableOrchestrationContext.ts`][js-context]). The docs mandate the generator form: "Don't declare JavaScript orchestrator functions as `async` because the Node.js runtime doesn't guarantee deterministic behavior for `async` functions" ([code constraints][docs-constraints]).

### The history

The journal is DTFx's `HistoryEvent` list. The JS SDK mirrors the enum by ordinal ([`HistoryEventType.ts`][js-event-type]; DTFx's own [`EventType.cs`][dtfx-event-type] adds `ExecutionRewound = 21` and warns "Changing the order of variables may cause bugs in OOProc SDKs"):

```ts
export enum HistoryEventType {
  ExecutionStarted = 0,
  ExecutionCompleted = 1,
  ExecutionFailed = 2,
  ExecutionTerminated = 3,
  TaskScheduled = 4,
  TaskCompleted = 5,
  TaskFailed = 6,
  SubOrchestrationInstanceCreated = 7,
  SubOrchestrationInstanceCompleted = 8,
  SubOrchestrationInstanceFailed = 9,
  TimerCreated = 10,
  TimerFired = 11,
  OrchestratorStarted = 12,
  OrchestratorCompleted = 13,
  EventSent = 14,
  EventRaised = 15,
  ContinueAsNew = 16,
  GenericEvent = 17,
  HistoryState = 18,
  ExecutionSuspended = 19,
  ExecutionResumed = 20,
}
```

Every event carries `EventType`, `EventId`, `IsPlayed`, `Timestamp` ([`HistoryEvent.ts`][js-event]). A `TaskScheduledEvent` has `Name` and `Input`; its `TaskCompletedEvent` has `TaskScheduledId` and `Result` ([`TaskScheduledEvent.ts`][js-task-scheduled], [`TaskCompletedEvent.ts`][js-task-completed]). DTFx's history README defines the pairing: "The `TaskScheduledId` field will match the `EventId` field of the corresponding `TaskScheduled` event" ([`History/README.md`][dtfx-history-readme]).

Each wake-up (an _episode_) is bracketed by `OrchestratorStarted` / `OrchestratorCompleted`. The docs show the resulting Azure Storage table rows for a three-activity chain ([docs][docs-orch]); abbreviated:

| EventType             | Name        | Result                |
| --------------------- | ----------- | --------------------- |
| ExecutionStarted      | HelloCities |                       |
| OrchestratorStarted   |             |                       |
| TaskScheduled         | SayHello    |                       |
| OrchestratorCompleted |             |                       |
| TaskCompleted         |             | `"Hello Tokyo!"`      |
| OrchestratorStarted   |             |                       |
| TaskScheduled         | SayHello    |                       |
| …                     |             |                       |
| ExecutionCompleted    |             | `["Hello Tokyo!", …]` |

In the Azure Storage provider this is literally a table: "The _partition key_ derives from the orchestration's instance ID … The _row key_ is a sequence number that orders the history events. When you need to run an orchestration instance, the system loads the full history into memory using a range query within a single table partition" ([Azure Storage provider][docs-azstorage]). Queues drive execution: one `-workitems` queue for activities and N `-control-NN` queues (partitions, hashed by instance ID) for orchestrator messages; payloads over 45 KB spill to a `-largemessages` blob container. The docs also concede the consistency model: "Azure Storage doesn't provide any transactional guarantees about data consistency between table storage and queues when it saves data" — the provider uses "eventual consistency patterns, such as Command and Query Responsibility Segregation (CQRS)" ([docs][docs-orch]).

### The replay loop (JavaScript SDK)

`Orchestrator.handle` builds a `DurableOrchestrationContext` from the trigger binding (history, input, instance ID, `isReplaying`, negotiated `upperSchemaVersion`) and hands off to `TaskOrchestrationExecutor.execute` ([`Orchestrator.ts`][js-orchestrator]). The executor walks the history once ([`TaskOrchestrationExecutor.ts`][js-executor]):

```ts
// Determine the index of the last OrchestratorStarted event in the history.
// Events before this index belong to previous replay frames (isReplaying = true).
// Events at or after this index belong to the current frame (isReplaying = false).
// This approach does not rely on the IsPlayed flag, which some backends do not set.
let lastOrchestratorStartedIndex = -1;
for (let i = 0; i < history.length; i++) {
  if (history[i].EventType === HistoryEventType.OrchestratorStarted) {
    lastOrchestratorStartedIndex = i;
  }
}
for (let i = 0; i < history.length; i++) {
  this._isReplaying = i < lastOrchestratorStartedIndex;
  this.processEvent(history[i]);
  if (this.isDoneExecuting()) break;
}
```

`processEvent` dispatches on type: `OrchestratorStarted` advances `currentUtcDateTime` (monotonically), `ContinueAsNew` calls `initialize()` and forgets everything, `ExecutionStarted` starts the generator, and any completion event (`TaskCompleted`, `TaskFailed`, `TimerFired`, `SubOrchestrationInstanceCompleted`/`Failed`, `EventRaised`) resolves an open task and calls `tryResumingUserCode`. The completion-to-task map is explicit:

```ts
this.eventToTaskValuePayload = {
  [HistoryEventType.TaskCompleted]: [true, 'TaskScheduledId'],
  [HistoryEventType.TimerFired]: [true, 'TimerId'],
  [HistoryEventType.SubOrchestrationInstanceCompleted]: [
    true,
    'TaskScheduledId',
  ],
  [HistoryEventType.EventRaised]: [true, 'Name'],
  [HistoryEventType.TaskFailed]: [false, 'TaskScheduledId'],
  [HistoryEventType.SubOrchestrationInstanceFailed]: [false, 'TaskScheduledId'],
};
```

`tryResumingUserCode` feeds the current task's result into the generator (`next(value)` on success, `throw(error)` on failure). When the generator yields a fresh `DFTask` that has no result yet, the executor records its `actionObj` into `this.actions`, then `trackOpenTask` assigns it an ID and registers it as open. The output of an invocation is an `OrchestratorState` — `isDone`, the flat `actions` array, `output`, `error`, `customStatus`, `schemaVersion` — serialized back to the extension ([`OrchestratorState.ts`][js-state]).

### The extension side

The extension's `OutOfProcOrchestrationShim` deserializes that state and, under schema V2–V4, replays the actions **through DTFx's live context** ([`OutOfProcOrchestrationShim.cs`][ext-shim]):

```csharp
private async Task ProcessAsyncActionsV2(AsyncAction[] actions, SchemaVersion schema)
{
    foreach (AsyncAction action in actions)
    {
        Task durableTask = this.InvokeAPIFromAction(action, schema);
        try { await durableTask; }
        catch (Exception) { /* Silently ignore exceptions thrown by user code */ }
    }
}
```

`InvokeAPIFromAction` maps `AsyncActionType.CallActivity` to `context.CallActivityAsync`, `WhenAll` to `Task.WhenAll(...)`, `WhenAny` to `Task.WhenAny(...)`, `ContinueAsNew` to `context.ContinueAsNew(...)`, and so on. If the SDK reported `isDone == false`, the shim then `await Task.Delay(Timeout.Infinite)` so the DTFx dispatcher treats the orchestration as blocked on open tasks. So the JS process's `sequenceNumber` and DTFx's `idCounter` must advance in lock-step: the JS executor even bumps its counter for fire-and-forget actions, with a comment explaining that releasing an N-entity lock "consumes N slots" on the extension side, because "the extension's `ReleaseLocks()` sends one entity message per locked entity" ([`TaskOrchestrationExecutor.ts`][js-executor]).

For in-process .NET, `DurableOrchestrationContext` wraps DTFx's context directly; `IsReplaying` and `CurrentUtcDateTime` are forwarded to `InnerContext` ([`DurableOrchestrationContext.cs`][ext-context]). DTFx's own `ExecuteCore` defines the flag the simple way: `IsReplaying = true` while it processes `pastEvents`, `false` for `newEvents`, and it sets `CurrentUtcDateTime` from each `OrchestratorStarted` it passes ([`TaskOrchestrationExecutor.cs`][dtfx-executor]).

### Durable timers, external events, sub-orchestrations, continue-as-new

- **Timers.** `createTimer(fireAt)` yields a `DFTimerTask` backed by a `CreateTimerAction`; the backend enqueues a message "that becomes visible only at 4:30 PM UTC" ([timers][docs-timers]). Storage providers cap a single timer, so under schema ≥ V3 the SDK builds a `LongTimerTask` — a `WhenAllTask` that schedules a chain of sub-timers of `longRunningTimerIntervalDuration` until `fireAt` is reached ([`LongTimerTask.ts`][js-long-timer]). The decomposition is visible in the history ("observable in the underlying data store but doesn't affect orchestration behavior"). A timer that is never awaited must be cancelled, or the orchestration never completes: "The Durable Task Framework doesn't change an orchestration's status to 'Completed' until all outstanding tasks, including durable timer tasks, are either completed or canceled" ([timers][docs-timers]).
- **External events.** `waitForExternalEvent(name)` yields an `AtomicTask` whose ID is the event _name_, not a sequence number; the executor keeps a per-name FIFO of waiting tasks in `openEvents`, and an `EventRaised` that arrives before anyone waits is parked in `deferredTasks` and drained by the next `trackOpenTask` for that name ([`TaskOrchestrationExecutor.ts`][js-executor]). Delivery is "at-least-once … we recommend that external events contain some kind of ID that allows them to be manually de-duplicated in orchestrators"; an event for an unknown instance "is discarded" ([external events][docs-events]).
- **Sub-orchestrations.** `callSubOrchestrator(name, input, instanceId?)` yields a task matched by `SubOrchestrationInstanceCompleted.TaskScheduledId`. The docs' fan-out sample derives child IDs deterministically (`context.df.instanceId + ":" + i`) "to prevent duplicate sub-orchestrations on replay" ([sub-orchestrations][docs-subs]); in .NET, an omitted ID is filled by the deterministic `NewGuid()`.
- **Continue-as-new.** `continueAsNew(input)` records a `ContinueAsNewAction` and sets `willContinueAsNew`, after which `addToActions` drops further actions ([`DurableOrchestrationContext.ts`][js-context]). The instance keeps its ID but "the orchestrator function's history resets"; "The results of any incomplete tasks are discarded" ([eternal orchestrations][docs-eternal]).

### Durable entities

An entity function receives a `batch` of `RequestMessage`s plus the current serialized `state`, runs the handler once per operation, and returns an `EntityState` — `entityExists`, `entityState`, per-operation `results`, outgoing `signals` ([`Entity.ts`][js-entity], [`EntityState.ts`][js-entity-state]). On the extension side `TaskEntityShim` executes the batch and then commits the new state by calling `innerContext.ContinueAsNew(jstate)` on the DTFx orchestration that hosts the entity, i.e. the entity's history is truncated to a single `ExecutionStarted` carrying the state blob after every batch ([`TaskEntityShim.cs`][ext-entity-shim]). The persisted `SchedulerState` holds `exists`, `state`, a `queue` of pending requests, `lockedBy` and a `MessageSorter` for ordered delivery ([`SchedulerState.cs`][ext-scheduler-state]). The docs position this against Orleans: "Durable entity operations run serially to prevent race conditions"; "Entities deliver messages reliably and in order"; "Orchestrations are the only place you can use request-response with entities" ([entities][docs-entities]).

---

## Analysis

### 1. Step identity and replay matching

A step's identity is its **ordinal position in the sequence of durable operations the orchestrator scheduled**. The JS executor assigns `task.id = this.sequenceNumber++` the first time a task is tracked, and that integer is what `TaskScheduledId` / `TimerId` refer back to ([`TaskOrchestrationExecutor.ts`][js-executor]). DTFx does the same on its side (`int id = this.idCounter++` in `ScheduleTaskInternal`) and records the scheduled action in `orchestratorActionsMap` ([`TaskOrchestrationContext.cs`][dtfx-context]). External events are the one exception: they are keyed by **name**, with a FIFO per name.

Matching on replay is a two-level check. The SDK matches purely by ordinal. DTFx additionally verifies the **name** when it re-encounters a `TaskScheduled` event ([`TaskOrchestrationContext.cs`][dtfx-context]):

```csharp
if (!string.Equals(scheduledEvent.Name, currentReplayAction.Name, StringComparison.OrdinalIgnoreCase))
{
    throw new NonDeterministicOrchestrationException(scheduledEvent.EventId,
        $"A previous execution of this orchestration scheduled an activity task with sequence number {taskId} "
        + $"named '{scheduledEvent.Name}', but the current orchestration replay instead scheduled an activity "
        + $"task named '{currentReplayAction.Name}' with this sequence number.  Was a change made to the "
        + "orchestrator code after this instance had already started running?");
}
```

The kind (`ScheduleTask` vs timer vs sub-orchestration) is also checked. **Inputs are not**: a replayed call with a different argument but the same name at the same ordinal is accepted silently and gets the old result. There is no hash of arguments anywhere in the matching path, and no attempt counter — a retry is a new ordinal, because `RetryableTask` schedules fresh sub-tasks (a timer, then a `NoOpTask` re-attempt) for each try ([`RetryableTask.ts`][js-retryable]).

### 2. Journal versus world

**The journal always wins, and disagreement is undetectable by design.** The orchestrator is forbidden from observing the world directly ([code constraints][docs-constraints]: no bindings, no I/O, no environment variables, "Orchestrator functions can replay multiple times, causing nondeterministic and duplicate I/O with external systems"). Every observation is an activity whose return value is journaled in `TaskCompleted.Result`, and on replay the activity is _not re-run_: "if the code tries to call a function … the Durable Task Framework consults the execution history … it replays that function's result" ([docs][docs-orch]). Nothing ever re-observes and compares.

Where the journal and world can drift, the docs push the problem to the user: activities and external events are at-least-once, so "external events contain some kind of ID that allows them to be manually de-duplicated" ([external events][docs-events]); the Azure Storage provider's Instances table is only "eventually consistent with the contents of the History table" ([Azure Storage provider][docs-azstorage]). The only engine-level reconciliation is the MSSQL provider's transactional consumption of external events (no duplicates there, "unlike the Azure Storage provider").

### 3. Determinism enforcement

Three layers, none of them the language:

- **Discipline, documented.** The constraints page enumerates the banned categories — dates/times, GUIDs, random numbers, bindings, static variables, environment variables, network, thread-blocking APIs, async APIs, threading — and supplies journaled substitutes: "Don't use APIs like `new Date()` or `Date.now()` to get the current date and time. Instead, use `DurableOrchestrationContext.currentUtcDateTime`" and "Instead of the `uuid` module or the `crypto.randomUUID()` function, use the context object's built-in `newGuid()` method to generate a random GUID that's safe for orchestrator replay" ([code constraints][docs-constraints]). `currentUtcDateTime` is the `Timestamp` of the current `OrchestratorStarted` event ([`Orchestrator.ts`][js-orchestrator]); `newGuid` is a UUID v5 of `` `${instanceId}_${this.currentUtcDateTime.valueOf()}_${this.newGuidCounter}` `` under a fixed namespace ([`DurableOrchestrationContext.ts`][js-context]) — SHA-1 based, with the note "We cannot update to SHA2-based algorithms without breaking customers' inflight orchestrations" ([`GuidManager.ts`][js-guid]). The .NET equivalent concatenates instance ID, `CurrentUtcDateTime.ToString("o")` and a counter ([`DurableOrchestrationContext.cs`][ext-context]).
- **Runtime detection, partial.** DTFx throws `NonDeterministicOrchestrationException` on ordinal/name/kind mismatch (above) and attempts to detect foreign threads, but the docs caution "this detection behavior won't catch all violations, and you shouldn't depend on it" ([code constraints][docs-constraints]). The JS executor throws on any non-`Task` yield with a "programming constraint violation" message ([`TaskOrchestrationExecutor.ts`][js-executor]).
- **Static analysis, .NET only.** The extension ships Roslyn analyzers for orchestrator methods — `DateTimeAnalyzer`, `GuidAnalyzer`, `EnvironmentVariableAnalyzer`, `ThreadTaskAnalyzer`, `TimerAnalyzer`, `IOTypesAnalyzer`, `BindingAnalyzer`, `CancellationTokenAnalyzer`, `ConfigureAwaitAnalyzer`, `MethodInvocationAnalyzer` ([`DateTimeAnalyzer.cs`][ext-analyzer-datetime], [`GuidAnalyzer.cs`][ext-analyzer-guid]) — and a `[Deterministic]` attribute "to label a method as Deterministic. This allows the method to be called in an Orchestration function without causing a compiler warning" ([`DeterministicAttribute.cs`][ext-deterministic]). JavaScript has no equivalent.

A subtler determinism trap is documented for .NET: LINQ's deferred execution re-schedules activities on a second enumeration, so "Materialize the sequence once before waiting for the tasks" ([code constraints][docs-constraints]).

### 4. Compensation and failure handling

**No engine-level compensation.** Activity failures surface as thrown errors (`TaskFailedError` in JS, carrying structured `FailureDetails` when the host supplies them — [`TaskOrchestrationExecutor.ts`][js-executor]); the documented pattern is plain `try/catch` with a compensating activity call ([error handling][docs-errors]):

```js
yield context.df.callActivity("debitAccount", { account: transferDetails.sourceAccount, amount });
try {
    yield context.df.callActivity("creditAccount", { account: transferDetails.destinationAccount, amount });
} catch (error) {
    // Refund the source account.
    yield context.df.callActivity("creditAccount", { account: transferDetails.sourceAccount, amount });
}
```

"If the first **CreditAccount** function call fails, the orchestrator function compensates by crediting the funds back to the source account." There is no registration, no ordering, no scope: a compensation is just another journaled activity the author remembers to call, and it is only as durable as the orchestrator's own progress (the `catch` block replays like any other code). Retries are declarative per call (`RetryOptions`: max attempts, first interval, backoff coefficient, max interval, retry timeout) and are themselves durable, since `RetryableTask` is a `WhenAllTask` over a growing list of timer and re-attempt sub-tasks ([`RetryableTask.ts`][js-retryable]). An unhandled orchestrator exception is terminal: "the orchestration instance finishes in a `Failed` state. You can't retry an orchestration instance after it fails" ([docs][docs-orch]), and "A call to `continue-as-new` from a `finally` block does _not_ restart the orchestration after an uncaught exception" ([eternal orchestrations][docs-eternal]). Critical sections (`context.df.lock` over entities) give mutual exclusion, not atomicity ([`samples-js/functions/transferTryFinally.js`][js-transfer]).

### 5. Versioning against old histories

The versioning page is candid that ordinal matching makes most edits breaking ([versioning][docs-versioning]):

> "During replay, if the original call to `Foo` returned `true`, then the orchestrator replay calls into `SendNotification`, which isn't in its execution history. The runtime detects this inconsistency and raises a _non-deterministic orchestration_ error because it encountered a call to `SendNotification` when it expected to see a call to `Bar`."

> "Deploying breaking changes without a mitigation strategy (the 'do nothing' approach) can cause orchestrations to fail with _nondeterministic orchestration_ errors, get stuck indefinitely in a `Running` status, or trigger low-level runtime failures that degrade performance."

Three strategies are offered. **Side-by-side deployments** — "The most fail-proof way to ensure that breaking changes are deployed safely is by deploying them side by side with your older versions", via a different storage account or a different task hub name, optionally with deployment slots. **Stop all in-flight instances** — clear the control and work-item queues; "This approach is ideal for rapid prototype development". **Orchestration versioning (recommended)** — a runtime feature: "Each orchestration instance gets a version permanently associated with it when created", the orchestrator branches on it, "Workers running newer orchestrator function versions can continue executing orchestration instances created by older versions" and "The runtime prevents workers running older orchestrator function versions from executing orchestrations of newer versions" ([orchestration versioning][docs-orch-versioning]). Configuration is `defaultVersion`, `versionMatchStrategy` (`None` / `Strict` / `CurrentOrOlder`, the default) and `versionFailureStrategy` (`Reject`, the default, or `Fail`) in `host.json`, mirrored by `DurableTaskOptions.DefaultVersion`, `VersionMatchStrategy` and `VersionFailureStrategy` ([`DurableTaskOptions.cs`][ext-options]). The JS SDK reads the instance's version from `ExecutionStartedEvent.Version` in the history and exposes it as `context.df.version` ([`DurableOrchestrationContext.ts`][js-context]). The rule that makes this work is the same as everywhere: "Keep old version code paths unchanged after deployment."

There is a second, orthogonal versioning axis: the SDK↔extension **replay protocol** (`ReplaySchema` V1–V4, negotiated per invocation from `upperSchemaVersion`), which changes the shape of the `actions` payload — V1 flattens compound actions into a 2-D array, V2+ sends nested `WhenAll`/`WhenAny` ([`ReplaySchema.ts`][js-schema], [`OrchestratorState.ts`][js-state]).

### 6. Concurrency under replay

Fan-out is `Task.all` / `Task.any` over tasks the orchestrator created without yielding ([`DurableOrchestrationContext.ts`][js-context]). A `CompoundTask` sets itself as `parent` of each child; `trackOpenTask` recurses into children in array order and assigns each its ordinal, so the sequence is fixed by construction order, not completion order ([`CompoundTask.ts`][js-compound], [`TaskOrchestrationExecutor.ts`][js-executor]). Completion propagates upward: `WhenAllTask.trySetValue` resolves when "all sub-tasks have completed" or fails on the `firstError`; `WhenAnyTask.trySetValue` resolves with the first child whose completion event appears in the history, and "always feed[s] in the result as a value" ([`WhenAllTask.ts`][js-when-all], [`WhenAnyTask.ts`][js-when-any]). Because the history is a total order, "which child won" is deterministic on replay regardless of real-world timing. The extension mirrors the tree with `Task.WhenAll` / `Task.WhenAny` over the DTFx tasks ([`OutOfProcOrchestrationShim.cs`][ext-shim]). The docs note that even a fan-in replays repeatedly, once per batch of arriving results, unless extended sessions keep the instance in memory ([Azure Storage provider][docs-azstorage]).

### 7. Replay or snapshot

**Replay for orchestrations, snapshot for entities.** The cost of replay is explicit: the whole history is loaded per episode ("Potentially, this approach creates significant memory pressure"), mitigated by sub-orchestrations, smaller payloads, lower concurrency throttles ([Azure Storage provider][docs-azstorage]), by `continueAsNew` for unbounded loops ([eternal orchestrations][docs-eternal]), and by _extended sessions_, an opt-in cache that keeps instances in memory so "new messages can be processed without a full history replay" — off by default because "The default aggressive replay behavior can be useful for detecting orchestrator function code constraints violations at development time". DTFx has a `HistoryState` event type for embedding a state snapshot but it "is not used in most modern backend types" ([`History/README.md`][dtfx-history-readme]). Entities take the other branch: after each batch the shim calls `ContinueAsNew(jstate)`, so an entity's "history" is always one event holding the latest state ([`TaskEntityShim.cs`][ext-entity-shim]). What replay rules out is any non-journaled observation in the orchestrator; what snapshotting rules out for entities is request-response from anywhere but an orchestration.

### 8. Testing

The documented approach **does not exercise replay at all**: "you test orchestrators, activities, and client (trigger) functions by mocking the framework-provided context objects and calling your functions directly" ([unit testing][docs-testing]) — Moq over `TaskOrchestrationContext` in .NET, `orchestrator_generator_wrapper` over a mocked context in Python. For JavaScript the page defers entirely: "JavaScript unit testing for Durable Functions requires the standalone Durable Task SDK", whose `TestOrchestrationWorker` + `InMemoryOrchestrationBackend` run "the full orchestration engine in-process".

The JS SDK does ship the pieces for history-driven tests — `DummyOrchestrationContext` (exported from `index.ts`) and `DurableOrchestrationInput`, whose constructor takes a `history: HistoryEvent[]` and defaults to a single `OrchestratorStartedEvent` ([`testingUtils.ts`][js-testing]) — and its own integration suite is exactly that: hand-built histories such as `GetSayHelloWithActivityReplayOne`, `GetFanOutFanInDiskUsagePartComplete`, `GetActivityThenWaitForEvent_EventBeforeActivityCompletion`, `GetTwoEarlyEventsSameName` fed to real orchestrators, asserting on the returned `actions` and on `isReplaying` ([`test/testobjects/testhistories.ts`][js-testhistories], [`test/integration/orchestrator-spec.ts`][js-orch-spec]). Nothing in the product generates those histories for a user, and nothing mutates the world between episodes.

### 9. Journal integrity and the single writer

Single-writer-ness is enforced at two levels in the Azure Storage provider, and neither is the append itself. The coarse level is **partition ownership**: every instance hashes to one control queue, and control queues are handed out to workers under blob leases (`-leases` container, `BlobPartitionLeaseManager`; an optional table-based partition manager), so "each orchestration or entity must only be processed by one worker at a time" ([Azure Storage provider][docs-azstorage]). While a worker holds a batch of messages for an instance it keeps them invisible by renewing their visibility timeout (`RenewTaskOrchestrationWorkItemLockAsync`, "Reset the visibility of the message to ensure it doesn't get picked up by anyone else" — [`AzureStorageOrchestrationService.cs`][dtfx-azs-service]).

The fine level is a **conditional append**. `UpdateStateAsync` writes the episode's new events as a table transaction of `UpsertReplace` rows keyed `RowKey = sequenceNumber.ToString("X16")` plus `ExecutionId`, in chunks of at most 99 rows or 3 MB; every chunk also carries a `sentinel` row (`RowKey = "sentinel"`, `ExecutionId`, `IsCheckpointComplete`) submitted as `UpdateMerge` with the ETag the worker read at load time, or `Add` if no history existed ([`AzureTableTrackingStore.cs`][dtfx-azs-tracking]). A `PreconditionFailed` (ETag moved) or `Conflict` (someone else added the sentinel first) is logged as `SplitBrainDetected` and surfaced as `SessionAbortedException`: "Aborting execution due to conflicting completion of the work item by another worker" ([`AzureStorageOrchestrationService.cs`][dtfx-azs-service]). So the guard is per-instance and version-based (the sentinel's ETag stands in for an expected history length), independent of the lease, and it is what actually protects the history when a lease expires under a slow worker. Rows are `UpsertReplace` rather than `Add` precisely because "the orchestration episode gets replayed due to a commit failure in one of the steps below" — a torn checkpoint is repaired by re-running the episode and overwriting the same row keys, and the sentinel's `IsCheckpointComplete = false` marks the half-written state until the final chunk lands.

The commit order is **not write-ahead**. `CompleteTaskOrchestrationWorkItemAsync` first enqueues the outbound activity, timer and orchestrator messages ("If a failure happens after this, duplicate messages will be written after the retry, but the results of those messages are expected to be de-dup'd later"), then commits the history ("This is the actual 'checkpoint'. Failures after this will result in a duplicate replay of the orchestration with no side-effects"), and only then deletes the triggering control-queue messages ("This is the final commit") ([`AzureStorageOrchestrationService.cs`][dtfx-azs-service]). Effects can therefore be launched whose intent is never journaled; the provider tolerates this because a duplicate activity message is dropped when its `TaskScheduledId` is not found in the reloaded history ([`OrchestrationSession.cs`][dtfx-azs-session]), and a response for an unknown instance is given "the benefit of the doubt" five dequeues before being treated as a "zombie event". There is no checksum on a row and no writer id beyond `ExecutionId`, which is checked on read (`GetHistoryEventsAsync` discards rows whose `ExecutionId` differs from the sentinel's) so that a `ContinueAsNew` generation never sees its predecessor's events ([`AzureTableTrackingStore.cs`][dtfx-azs-tracking]). The docs are explicit that this is eventual consistency and point at MSSQL and the Durable Task Scheduler for stronger guarantees ([docs][docs-orch]).

### 10. Operator recovery and intervention

The operator surface is the **instance management API**, exposed identically through the client binding, an HTTP webhook API (`/instances/{instanceId}/{terminate|suspend|resume|rewind|restart|raiseEvent/...}` — [`HttpApiHandler.cs`][ext-http]) and the `IDurableOrchestrationClient` interface (`GetStatusAsync`, `ListInstancesAsync`, `TerminateAsync`, `SuspendAsync`, `ResumeAsync`, `RewindAsync`, `RestartAsync`, `RaiseEventAsync`, `PurgeInstanceHistoryAsync` — [`IDurableOrchestrationClient.cs`][ext-client-iface]). Status queries return the full history on request (`showHistory`, `showHistoryOutput`) and a `RuntimeStatus` drawn from `Pending`, `Running`, `Completed`, `ContinuedAsNew`, `Failed`, `Canceled`, `Terminated`, `Suspended` ([instance management][docs-instances], [`OrchestrationRuntimeStatus.ts`][js-status]). The Azure Storage History table is itself readable with ordinary table tools, and the Durable Task Scheduler ships a management dashboard ([storage providers][docs-providers]).

Every intervention is **a message in the same queue**, so it leaves a trace and takes effect asynchronously: "A terminated instance eventually transitions into the `Terminated` state. But this transition doesn't happen immediately. Rather, the terminate operation is queued in the task hub along with other operations for that instance" ([instance management][docs-instances]). Termination is not cancellation: "Instance termination doesn't currently propagate. Activity functions and sub-orchestrations run to completion, regardless of whether you end the orchestration instance that called them." Suspend and resume are `ExecutionSuspended` / `ExecutionResumed` history events ([`TaskHubClient.cs`][dtfx-hub-client]).

**Rewind** is the one point-in-history recovery. `RewindAsync` "Rewinds the specified failed orchestration instance with a reason" ([`IDurableOrchestrationClient.cs`][ext-client-iface]); the Azure Storage implementation does not truncate the history but edits it in place: it finds the failed execution, rewrites each `TaskFailed` / `SubOrchestrationInstanceFailed` row and its matching `TaskScheduled` row to `EventType = GenericEvent` with `Reason = "Rewound: <original type>"` ("replay ignores row while dummy event preserves rowKey"), recurses into failed sub-orchestrations, resets the instance status and re-enqueues the deepest failed leaves ([`AzureTableTrackingStore.cs`][dtfx-azs-tracking]). The effect is that on the next replay the failed calls are re-scheduled with fresh ordinals while everything before them is kept. There is no API to edit a recorded result, skip a step, or supply a result by hand; no fork-from-index; and no quarantine state — an unprocessable instance either fails, is discarded as invalid ("Discarding execution results because the orchestration state is invalid" — [`AzureStorageOrchestrationService.cs`][dtfx-azs-service]) or sits in `Running` forever, which the versioning page lists as a real outcome of a bad deploy ([versioning][docs-versioning]).

### 11. Suspension and external input

Waiting primitives are durable timers, external events by name, sub-orchestration completion, entity calls (request-response via `EventSent` / `EventRaised`), and entity locks; all of them are ordinary open tasks, so a wait is not a distinct state — the orchestrator simply reaches the end of its history with tasks still open, returns, and "can be unloaded from memory" ([docs][docs-orch]). The extension makes that literal for out-of-process SDKs by awaiting `Task.Delay(Timeout.Infinite)` so DTFx sees an orchestrator blocked on its `TaskCompletionSource`s ([`OutOfProcOrchestrationShim.cs`][ext-shim]). No resources are held while waiting: "no billing charges are incurred while an orchestrator function is awaiting an external event task, no matter how long it waits" ([external events][docs-events]). The only threshold is the storage-provider cap on a single timer, worked around by `LongTimerTask`.

External input is addressed by **instance ID plus event name**, never by a token: "The `eventName` must match on both the _sending_ and _receiving_ ends in order for the event to be processed." An event that arrives early "is added to an in-memory queue" and consumed when the orchestrator next waits for that name; the JS executor's `deferredTasks` FIFO is that queue on the SDK side. An event for an unknown instance "is discarded"; a duplicate is delivered twice ("at-least-once"), which is why the docs ask for a de-duplication ID in the payload ([external events][docs-events]). Waits never time out on their own; a timeout is a race the author writes, `Task.any([eventTask, timerTask])`, and is journaled as a `TimerCreated` / `TimerFired` pair, with the losing timer cancelled explicitly ([timers][docs-timers]).

Human-in-the-loop is a documented first-class pattern built from exactly these pieces: "The orchestrator starts a durable timer and simultaneously waits for an external event from the person. If the person responds before the timer fires, the orchestrator processes the response. If the timer fires first, the orchestrator handles the timeout" ([human interaction][docs-human]). Separately from author-level waiting, **operator suspension** is a persisted state: `Suspended` is a `RuntimeStatus` a caller can observe, and while suspended DTFx queues every incoming event in `eventsWhileSuspended` (and parks any actions scheduled in that episode in `suspendedActionsMap`) until `ExecutionResumed` replays them in order ([`TaskOrchestrationContext.cs`][dtfx-context], [instance management][docs-instances]).

---

## Strengths

- **The replay contract is fully documented and the history is inspectable**: a table you can read, with a published event vocabulary and a README that defines the pairing fields.
- **Journaled substitutes for the unavoidable non-determinism** (`currentUtcDateTime`, `newGuid`) are cheap, deterministic functions of the history, not extra journal entries.
- **Fan-out/fan-in and retries are themselves durable tasks**, so a crash mid-fan-in loses nothing and a retry's backoff timer survives a restart.
- **Orchestration versioning** (version pinned at instance creation, `CurrentOrOlder` routing, `Reject` by default) is a small mechanism that closes most of the deployment gap.
- **Entities** give a snapshot-based actor with in-order, exactly-once-per-batch semantics next to the replay-based orchestrator, sharing one store.
- **A .NET analyzer set** turns the constraints list into compiler warnings.

## Weaknesses

- **Ordinal identity without an argument hash**: a changed input at the same position is silently served the old result. The name check lives only in DTFx, not in the JS SDK.
- **Two-process ID bookkeeping** (`sequenceNumber` in Node predicting `idCounter` in .NET, with hand-tuned slot counts for fire-and-forget actions) is fragile and is precisely the kind of invariant that breaks across SDK/extension version skew — hence the V1–V4 replay schemas.
- **No world reconciliation** and at-least-once delivery for activities and external events: idempotency and de-duplication are the user's job.
- **No compensation primitive**: `try/catch` plus a remembered activity call; a failed orchestration is terminal and cannot be resumed.
- **Replay cost is linear in history per episode**, and the mitigations (extended sessions, `continueAsNew`, splitting) are all manual.
- **Testing guidance mocks the context**, so the property the whole system depends on — same decisions given the same history — is never asserted by a user test.
- Storage-provider limits leak into the model (six-day timer cap for non-.NET SDKs, long timers decomposed into chains, 45 KB message spill).

---

## Key design decisions and trade-offs

| Decision                                                                                                   | Rationale                                                                             | Trade-off                                                                                             |
| ---------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Re-execute the function from the top on every wake-up                                                      | No state machine to write; local variables are the state                              | Linear replay cost; every orchestrator line must be deterministic                                     |
| Ordinal sequence IDs, name-checked by DTFx                                                                 | Trivial to mint in any language; no hashing of arbitrary inputs                       | Inserting, removing or reordering a call breaks every in-flight instance; argument drift is invisible |
| Out-of-process SDK returns an `actions` list, extension replays it through DTFx                            | One engine serves five languages; the SDK stays small                                 | The SDK must predict DTFx's IDs; a protocol schema version is needed to evolve the payload            |
| World access only via activities; results frozen in history                                                | Makes "journal wins" the only possible semantics, so no reconciliation code is needed | At-least-once side effects and stale observations must be handled by the user                         |
| `currentUtcDateTime` = `OrchestratorStarted.Timestamp`, `newGuid` = v5 UUID over (instance, time, counter) | Determinism without extra history rows                                                | The clock only advances per episode; GUID scheme is frozen forever (SHA-1) for old instances          |
| Entities persist a state blob via `ContinueAsNew` per batch                                                | Reuses the orchestration runtime; bounded history for long-lived actors               | No replay, so no free audit trail; request-response only from orchestrations                          |
| Orchestration versioning pinned at creation, `CurrentOrOlder` routing                                      | Zero-downtime deploys without a second task hub                                       | Old branches must stay byte-for-byte; legacy paths accumulate until instances drain                   |
| Extended sessions off by default                                                                           | Aggressive replay surfaces constraint violations during development                   | Production throughput needs an opt-in cache                                                           |

---

## Implications for a durable-execution library

- **Ordinal identity checked against name and kind, but never arguments**, is a
  precise statement of how much a positional scheme can detect (§1). The error
  message even asks the author whether the code changed, which is an admission
  that the scheme cannot tell.
- **A journaled clock and id generator can be pure functions of already-recorded
  data rather than records of their own.** `currentUtcDateTime` is the episode's
  start timestamp and `newGuid` is a version-5 UUID over instance, time and a
  counter. That is an elegant reduction: two sources of nondeterminism removed
  without adding a single journal entry.
- **Instance-pinned versioning with a refusal to resume a newer record under older
  code** is where this system converged after side-by-side task hubs proved
  unwieldy (§5). The refusal is the load-bearing half.
- **Record what the program asked for, not how the implementation coped.** Long
  timers and retries are decomposed into sub-steps that appear in the history, so
  the record describes a storage workaround rather than the author's intent. A
  library should journal at the operation boundary its users can see.
- **Entities show the opposite pole, in the same format.** They re-persist their
  whole state after every batch, into the same history a replayed orchestration
  uses, which demonstrates that snapshot and replay can share one record type.
- **The gap between its documentation and its own tests is instructive** (§8). The
  docs recommend mocking the context, which never exercises replay; the SDK's own
  suite drives orchestrators against hand-built partial histories. The second is
  the technique worth shipping to users.
- **At-least-once delivery with user-supplied deduplication is the whole answer to
  duplicate effects.** It works because every effect is a call to a service that
  can deduplicate, which is an assumption a general library cannot make on its
  users' behalf.

---

## Sources

- JS SDK source at `fcab779b`: `src/orchestrations/TaskOrchestrationExecutor.ts`, `Orchestrator.ts`, `DurableOrchestrationContext.ts`, `OrchestratorState.ts`, `ReplaySchema.ts`; `src/history/*.ts`; `src/task/*.ts`; `src/util/GuidManager.ts`, `testingUtils.ts`; `src/entities/*.ts`; `test/testobjects/testhistories.ts`; `test/integration/orchestrator-spec.ts`; `samples-js/functions/*.js`
- Extension source at `2317b407`: `src/WebJobs.Extensions.DurableTask/Listener/OutOfProcOrchestrationShim.cs`, `Listener/TaskEntityShim.cs`, `ContextImplementations/DurableOrchestrationContext.cs`, `EntityScheduler/SchedulerState.cs`, `Options/DurableTaskOptions.cs`, `DeterministicAttribute.cs`; `src/WebJobs.Extensions.DurableTask.Analyzers/Analyzers/Orchestrator/*.cs`
- DTFx source at `b385165a`: `src/DurableTask.Core/History/EventType.cs`, `History/README.md`, `TaskOrchestrationContext.cs`, `TaskOrchestrationExecutor.cs`
- Microsoft Learn: orchestrations overview, orchestrator code constraints, versioning, orchestration versioning, unit testing, storage providers, Azure Storage provider, error handling, timers, external events, sub-orchestrations, eternal orchestrations, entities (all fetched September 11, 2026)
- Netherite paper: [Serverless Workflows with Durable Functions and Netherite][netherite-paper]

<!-- References -->

[ext-repo]: https://github.com/Azure/azure-functions-durable-extension
[js-repo]: https://github.com/Azure/azure-functions-durable-js
[dtfx-repo]: https://github.com/Azure/durabletask
[mssql-repo]: https://github.com/microsoft/durabletask-mssql
[netherite-repo]: https://github.com/microsoft/durabletask-netherite
[netherite-paper]: https://arxiv.org/abs/2103.00033
[netherite-page]: ./netherite.md
[dapr-page]: ./dapr-workflow.md
[docs-orch]: https://learn.microsoft.com/en-us/azure/durable-task/common/durable-task-orchestrations
[docs-constraints]: https://learn.microsoft.com/en-us/azure/durable-task/common/durable-task-code-constraints
[docs-versioning]: https://learn.microsoft.com/en-us/azure/durable-task/durable-functions/durable-functions-versioning
[docs-orch-versioning]: https://learn.microsoft.com/en-us/azure/durable-task/common/durable-orchestration-versioning
[docs-testing]: https://learn.microsoft.com/en-us/azure/durable-task/durable-functions/durable-functions-unit-testing
[docs-providers]: https://learn.microsoft.com/en-us/azure/durable-task/common/durable-task-storage-providers
[docs-azstorage]: https://learn.microsoft.com/en-us/azure/durable-task/durable-functions/durable-functions-azure-storage-provider
[docs-errors]: https://learn.microsoft.com/en-us/azure/durable-task/common/durable-task-error-handling
[docs-timers]: https://learn.microsoft.com/en-us/azure/durable-task/common/durable-task-timers
[docs-events]: https://learn.microsoft.com/en-us/azure/durable-task/common/durable-task-external-events
[docs-subs]: https://learn.microsoft.com/en-us/azure/durable-task/common/durable-task-sub-orchestrations
[docs-eternal]: https://learn.microsoft.com/en-us/azure/durable-task/common/durable-task-eternal-orchestrations
[docs-entities]: https://learn.microsoft.com/en-us/azure/durable-task/common/durable-task-entities
[js-executor]: https://github.com/Azure/azure-functions-durable-js/blob/fcab779bf2bbe5c12f51969009b174c7c6476fdd/src/orchestrations/TaskOrchestrationExecutor.ts
[js-orchestrator]: https://github.com/Azure/azure-functions-durable-js/blob/fcab779bf2bbe5c12f51969009b174c7c6476fdd/src/orchestrations/Orchestrator.ts
[js-context]: https://github.com/Azure/azure-functions-durable-js/blob/fcab779bf2bbe5c12f51969009b174c7c6476fdd/src/orchestrations/DurableOrchestrationContext.ts
[js-state]: https://github.com/Azure/azure-functions-durable-js/blob/fcab779bf2bbe5c12f51969009b174c7c6476fdd/src/orchestrations/OrchestratorState.ts
[js-schema]: https://github.com/Azure/azure-functions-durable-js/blob/fcab779bf2bbe5c12f51969009b174c7c6476fdd/src/orchestrations/ReplaySchema.ts
[js-event-type]: https://github.com/Azure/azure-functions-durable-js/blob/fcab779bf2bbe5c12f51969009b174c7c6476fdd/src/history/HistoryEventType.ts
[js-event]: https://github.com/Azure/azure-functions-durable-js/blob/fcab779bf2bbe5c12f51969009b174c7c6476fdd/src/history/HistoryEvent.ts
[js-task-scheduled]: https://github.com/Azure/azure-functions-durable-js/blob/fcab779bf2bbe5c12f51969009b174c7c6476fdd/src/history/TaskScheduledEvent.ts
[js-task-completed]: https://github.com/Azure/azure-functions-durable-js/blob/fcab779bf2bbe5c12f51969009b174c7c6476fdd/src/history/TaskCompletedEvent.ts
[js-compound]: https://github.com/Azure/azure-functions-durable-js/blob/fcab779bf2bbe5c12f51969009b174c7c6476fdd/src/task/CompoundTask.ts
[js-when-all]: https://github.com/Azure/azure-functions-durable-js/blob/fcab779bf2bbe5c12f51969009b174c7c6476fdd/src/task/WhenAllTask.ts
[js-when-any]: https://github.com/Azure/azure-functions-durable-js/blob/fcab779bf2bbe5c12f51969009b174c7c6476fdd/src/task/WhenAnyTask.ts
[js-retryable]: https://github.com/Azure/azure-functions-durable-js/blob/fcab779bf2bbe5c12f51969009b174c7c6476fdd/src/task/RetryableTask.ts
[js-long-timer]: https://github.com/Azure/azure-functions-durable-js/blob/fcab779bf2bbe5c12f51969009b174c7c6476fdd/src/task/LongTimerTask.ts
[js-guid]: https://github.com/Azure/azure-functions-durable-js/blob/fcab779bf2bbe5c12f51969009b174c7c6476fdd/src/util/GuidManager.ts
[js-testing]: https://github.com/Azure/azure-functions-durable-js/blob/fcab779bf2bbe5c12f51969009b174c7c6476fdd/src/util/testingUtils.ts
[js-entity]: https://github.com/Azure/azure-functions-durable-js/blob/fcab779bf2bbe5c12f51969009b174c7c6476fdd/src/entities/Entity.ts
[js-entity-state]: https://github.com/Azure/azure-functions-durable-js/blob/fcab779bf2bbe5c12f51969009b174c7c6476fdd/src/entities/EntityState.ts
[js-testhistories]: https://github.com/Azure/azure-functions-durable-js/blob/fcab779bf2bbe5c12f51969009b174c7c6476fdd/test/testobjects/testhistories.ts
[js-orch-spec]: https://github.com/Azure/azure-functions-durable-js/blob/fcab779bf2bbe5c12f51969009b174c7c6476fdd/test/integration/orchestrator-spec.ts
[js-cancel-timer]: https://github.com/Azure/azure-functions-durable-js/blob/fcab779bf2bbe5c12f51969009b174c7c6476fdd/samples-js/functions/cancelTimer.js
[js-transfer]: https://github.com/Azure/azure-functions-durable-js/blob/fcab779bf2bbe5c12f51969009b174c7c6476fdd/samples-js/functions/transferTryFinally.js
[ext-shim]: https://github.com/Azure/azure-functions-durable-extension/blob/2317b407104b657ada289122090b356d8f4e3539/src/WebJobs.Extensions.DurableTask/Listener/OutOfProcOrchestrationShim.cs
[ext-entity-shim]: https://github.com/Azure/azure-functions-durable-extension/blob/2317b407104b657ada289122090b356d8f4e3539/src/WebJobs.Extensions.DurableTask/Listener/TaskEntityShim.cs
[ext-context]: https://github.com/Azure/azure-functions-durable-extension/blob/2317b407104b657ada289122090b356d8f4e3539/src/WebJobs.Extensions.DurableTask/ContextImplementations/DurableOrchestrationContext.cs
[ext-scheduler-state]: https://github.com/Azure/azure-functions-durable-extension/blob/2317b407104b657ada289122090b356d8f4e3539/src/WebJobs.Extensions.DurableTask/EntityScheduler/SchedulerState.cs
[ext-options]: https://github.com/Azure/azure-functions-durable-extension/blob/2317b407104b657ada289122090b356d8f4e3539/src/WebJobs.Extensions.DurableTask/Options/DurableTaskOptions.cs
[ext-deterministic]: https://github.com/Azure/azure-functions-durable-extension/blob/2317b407104b657ada289122090b356d8f4e3539/src/WebJobs.Extensions.DurableTask/DeterministicAttribute.cs
[ext-analyzer-datetime]: https://github.com/Azure/azure-functions-durable-extension/blob/2317b407104b657ada289122090b356d8f4e3539/src/WebJobs.Extensions.DurableTask.Analyzers/Analyzers/Orchestrator/DateTimeAnalyzer.cs
[ext-analyzer-guid]: https://github.com/Azure/azure-functions-durable-extension/blob/2317b407104b657ada289122090b356d8f4e3539/src/WebJobs.Extensions.DurableTask.Analyzers/Analyzers/Orchestrator/GuidAnalyzer.cs
[dtfx-event-type]: https://github.com/Azure/durabletask/blob/b385165ac10ecebbf183fdfdb07db33307756792/src/DurableTask.Core/History/EventType.cs
[dtfx-history-readme]: https://github.com/Azure/durabletask/blob/b385165ac10ecebbf183fdfdb07db33307756792/src/DurableTask.Core/History/README.md
[dtfx-context]: https://github.com/Azure/durabletask/blob/b385165ac10ecebbf183fdfdb07db33307756792/src/DurableTask.Core/TaskOrchestrationContext.cs
[dtfx-executor]: https://github.com/Azure/durabletask/blob/b385165ac10ecebbf183fdfdb07db33307756792/src/DurableTask.Core/TaskOrchestrationExecutor.cs
[docs-human]: https://learn.microsoft.com/en-us/azure/azure-functions/durable/durable-functions-phone-verification
[docs-instances]: https://learn.microsoft.com/en-us/azure/azure-functions/durable/durable-functions-instance-management
[dtfx-azs-service]: https://github.com/Azure/durabletask/blob/b385165ac10ecebbf183fdfdb07db33307756792/src/DurableTask.AzureStorage/AzureStorageOrchestrationService.cs
[dtfx-azs-session]: https://github.com/Azure/durabletask/blob/b385165ac10ecebbf183fdfdb07db33307756792/src/DurableTask.AzureStorage/Messaging/OrchestrationSession.cs
[dtfx-azs-tracking]: https://github.com/Azure/durabletask/blob/b385165ac10ecebbf183fdfdb07db33307756792/src/DurableTask.AzureStorage/Tracking/AzureTableTrackingStore.cs
[dtfx-hub-client]: https://github.com/Azure/durabletask/blob/b385165ac10ecebbf183fdfdb07db33307756792/src/DurableTask.Core/TaskHubClient.cs
[ext-client-iface]: https://github.com/Azure/azure-functions-durable-extension/blob/2317b407104b657ada289122090b356d8f4e3539/src/WebJobs.Extensions.DurableTask/ContextInterfaces/IDurableOrchestrationClient.cs
[ext-http]: https://github.com/Azure/azure-functions-durable-extension/blob/2317b407104b657ada289122090b356d8f4e3539/src/WebJobs.Extensions.DurableTask/HttpApiHandler.cs
[js-status]: https://github.com/Azure/azure-functions-durable-js/blob/fcab779bf2bbe5c12f51969009b174c7c6476fdd/src/orchestrations/OrchestrationRuntimeStatus.ts
