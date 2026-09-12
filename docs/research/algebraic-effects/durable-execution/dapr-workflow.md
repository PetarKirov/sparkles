# Dapr Workflow and the Durable Task Framework (.NET / Go)

The Durable Task Framework (DTFx) is Microsoft's original "orchestration as code" replay engine: an orchestrator function is re-executed from the top against an append-only history of typed events, and every scheduling call is matched to its history record by a per-execution sequence number. Dapr Workflow embeds the Go port of that engine (`durabletask-go`) inside the Dapr sidecar and makes each workflow instance an actor whose history is a run of keys in a state store, with actor reminders as the crash-recovery mechanism. This page covers the family; Azure Durable Functions, the serverless packaging of the same engine, has its own page ([sibling][adf]).

| Field             | Value                                                                                                                                                                                                                                                                                                                                                   |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | C# (`Azure/durabletask`, `microsoft/durabletask-dotnet`), Go (`dapr/durabletask-go`, `dapr/dapr`)                                                                                                                                                                                                                                                       |
| License           | Apache-2.0 (DTFx .NET, Dapr runtime); MIT (`durabletask-go`, per the Dapr engine README)                                                                                                                                                                                                                                                                |
| Repository        | [Azure/durabletask][repo-dtfx] · [microsoft/durabletask-dotnet][repo-dotnet] · [dapr/durabletask-go][repo-go] · [dapr/dapr][repo-dapr]                                                                                                                                                                                                                  |
| Documentation     | [Dapr Workflow docs][docs-overview] (features, architecture, patterns, versioning); DTFx's [`History/README.md`][hist-readme]                                                                                                                                                                                                                           |
| Category          | durable-execution engine (DTFx core, `durabletask-go` backend) + durable-execution SDK (the `.NET` and Go authoring surfaces) + event-sourced actors (Dapr's workflow/activity actors)                                                                                                                                                                  |
| Persistence model | replay                                                                                                                                                                                                                                                                                                                                                  |
| Journal store     | Pluggable `IOrchestrationService` backends in DTFx (Azure Storage, Service Bus, MSSQL, in-memory emulator); in Dapr, the actor state store: `history-NNNNNN`, `inbox-NNNNNN`, `metadata` keys per workflow actor                                                                                                                                        |
| Latest release    | `DurableTask.Core` `VersionPrefix` 3.9.0 ([csproj][core-csproj]); `Microsoft.DurableTask` 1.25.0 ([`Release.props`][dotnet-release]); `durabletask-go` `v0.14.1` (pinned by [Dapr's `go.mod`][dapr-gomod])                                                                                                                                              |
| Local clone       | `$REPOS/durabletask` at `b385165ac10ecebbf183fdfdb07db33307756792` · `$REPOS/durabletask-dotnet` at `bc2bc12ca5ee3a12a6e633250ade5efe6ae90ef4` · `$REPOS/durabletask-go` at `18cd4b5a26a5d53f127a12dd7aa2d496314f3de6` · `$REPOS/dapr` at `e9f08dc2dfbb37c9d52fa17186c1bbf6d9d94444` · `$REPOS/dapr-docs` at `78b25330358bbe68b7e0f2d704f02d0432aebb75` |

**Last reviewed:** September 12, 2026.

---

## Overview

### What it solves

A long-running business process — order fulfilment, a rollout, a multi-step release — is naturally written as one sequential function, but a sequential function dies with its process. DTFx keeps the sequential form and makes it survive: the orchestrator function is pure decision logic, every side effect is delegated to an _activity_ (a separately dispatched, at-least-once unit of work), and the engine records what the orchestrator asked for and what came back. After a crash the function is simply run again; every request it makes that the history already answers is satisfied from the history instead of being re-issued, so the function fast-forwards to where it was.

Dapr Workflow packages this for polyglot microservices. The engine lives in the sidecar, the application only pulls work items over a gRPC stream, and durability comes from the actor runtime the sidecar already has: a workflow instance is an actor, its history is that actor's state, and a one-shot reminder guarantees the instance is re-driven if the host dies mid-turn.

### Design philosophy

The Dapr docs describe the persistence model in one paragraph ([features and concepts][docs-features]):

> _"Dapr Workflows maintain their execution state by using a technique known as event sourcing. Instead of storing the current state of a workflow as a snapshot, the workflow engine manages an append-only log of history events that describe the various steps that a workflow has taken. When using the workflow SDK, these history events are stored automatically whenever the workflow "awaits" for the result of a scheduled task."_

And the consequence the whole family lives with:

> _"Using this replay technique, a workflow is able to resume execution from any "await" point as if it had never been unloaded from memory. Even the values of local variables from previous runs can be restored without the workflow engine knowing anything about what data they stored."_

The engine does **not** know what the local variables are. It never inspects the function; it only checks that the sequence of scheduling requests the function emits agrees, position by position, with the requests in the history. That is the single invariant everything else — determinism rules, versioning, patching, the nondeterminism error — exists to protect. The DTFx protocol reference states it as the ownership rule ([state and history][docs-proto-state]): _"The history is the "source of truth". If the orchestration code changes in a non-deterministic way (e.g., adding a new activity call in the middle of existing code), the replay will fail because the code's requests won't match the recorded history."_

---

## How it works

### The history event model

DTFx's history is a list of `HistoryEvent` subclasses. The base class carries the fields every event shares ([`History/HistoryEvent.cs`][hist-base]):

```csharp
[DataContract]
public abstract class HistoryEvent : IExtensibleDataObject
{
    [DataMember] public int EventId { get; internal set; }
    [DataMember] public bool IsPlayed { get; set; }
    [DataMember] public DateTime Timestamp { get; set; }
    [DataMember] public virtual EventType EventType { get; private set; }
}
```

`EventType` enumerates the vocabulary ([`History/EventType.cs`][hist-enum]): `ExecutionStarted`, `ExecutionCompleted`, `ExecutionFailed`, `ExecutionTerminated`, `TaskScheduled`, `TaskCompleted`, `TaskFailed`, `SubOrchestrationInstanceCreated`, `SubOrchestrationInstanceCompleted`, `SubOrchestrationInstanceFailed`, `TimerCreated`, `TimerFired`, `OrchestratorStarted`, `OrchestratorCompleted`, `EventSent`, `EventRaised`, `ContinueAsNew`, `GenericEvent`, `HistoryState`, `ExecutionSuspended`, `ExecutionResumed`, `ExecutionRewound`. Each has a class under `src/DurableTask.Core/History/`; the ones that matter for replay pair up by id:

| Request event                                                    | Resolution event                                                                 | Correlation                                                    |
| ---------------------------------------------------------------- | -------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| `TaskScheduledEvent` (`Name`, `Version`, `Input`, `Tags`)        | `TaskCompletedEvent` (`Result`) / `TaskFailedEvent` (`Reason`, `FailureDetails`) | `TaskScheduledId` == request's `EventId` ([source][hist-task]) |
| `SubOrchestrationInstanceCreatedEvent` (`Name`, `InstanceId`, …) | `SubOrchestrationInstanceCompletedEvent` / `…FailedEvent`                        | `TaskScheduledId` == request's `EventId`                       |
| `TimerCreatedEvent` (`FireAt`)                                   | `TimerFiredEvent` (`TimerId`, `FireAt`)                                          | `TimerId` == request's `EventId`                               |
| `EventSentEvent`                                                 | — (one-way)                                                                      | —                                                              |
| — (external)                                                     | `EventRaisedEvent` (`Name`, `Input`)                                             | matched by **name**, FIFO, not by id                           |

Two bookkeeping events bracket every turn. The `History/README.md` explains them ([source][hist-readme]): `OrchestratorStarted` marks _"the orchestrator function is starting a new execution. You will see many of these events in your history - one for each time that an orchestrator resumes from an `await`"_, and _"The timestamp of this event is used to populate the `CurrentDateTimeUtc` property"_; `OrchestratorCompleted` marks that the function _"has awaited and committed any side effects"_. `ExecutionStarted` is _"always the second event in an orchestration history"_ and carries `Name`, `Version`, `Input`, `Tags`, `ParentInstance`, `Generation` ([source][hist-started]). `ContinueAsNewEvent` is an `ExecutionCompletedEvent` subclass ([source][hist-can]).

The Go port carries the same model as a protobuf `oneof` ([`api/protos/history_events.pb.go`][go-proto]): `EventId`, `Timestamp`, then `ExecutionStarted`, `ExecutionCompleted`, `ExecutionTerminated`, `TaskScheduled`, `TaskCompleted`, `TaskFailed`, `ChildWorkflowInstanceCreated`/`Completed`/`Failed` (renamed from "sub-orchestration"), `TimerCreated`, `TimerFired`, `WorkflowStarted`/`WorkflowCompleted` (renamed from "orchestrator started/completed"), `EventSent`, `EventRaised`, `ContinueAsNew`, `ExecutionSuspended`, `ExecutionResumed`, and two Dapr additions: `ExecutionStalled` and `DetachedWorkflowInstanceCreated`.

### The user-facing API

DTFx's abstract `OrchestrationContext` ([source][oc]) is the only handle an orchestrator gets. The replay-relevant members:

```csharp
public abstract class OrchestrationContext
{
    [ThreadStatic] public static bool IsOrchestratorThread;   // detects illegal async use
    public string Version { get; }                            // from ExecutionStartedEvent
    public virtual DateTime CurrentUtcDateTime { get; }       // "Replay-safe current UTC datetime"
    public bool IsReplaying { get; }                          // true while past events are replayed
    public abstract Task<TResult> ScheduleTask<TResult>(string name, string version, params object[] parameters);
    public abstract Task<T> CreateSubOrchestrationInstance<T>(string name, string version, string instanceId, object input);
    public abstract Task<T> CreateTimer<T>(DateTime fireAt, T state);
    public abstract void SendEvent(OrchestrationInstance orchestrationInstance, string eventName, object eventData);
    public abstract void ContinueAsNew(object input);
}
```

The newer `.NET` SDK adds `NewGuid()`, documented as _"a name-based UUID V5 … The name input used to generate this value is a combination of the orchestration instance ID, the current time, and an internally managed sequence number"_ ([source][dotnet-ctx]) — i.e. randomness derived from replay-stable inputs. The Go `WorkflowContext` exposes the same surface as `CallActivity`, `CallChildWorkflow`, `CreateTimer`, `WaitForSingleEvent`, `ContinueAsNew`, `IsPatched`, with `IsReplaying` and `CurrentTimeUtc` as plain fields ([source][go-orch]).

### The replay algorithm

Each turn, the dispatcher loads the instance's `OrchestrationRuntimeState` — `PastEvents` (the stored history) plus `NewEvents` (the messages that woke the instance) ([source][runtime-state]) — and hands it to `TaskOrchestrationExecutor`. The loop is short enough to quote whole ([source][executor]):

```csharp
void ProcessEvents(IEnumerable<HistoryEvent> events)
{
    foreach (HistoryEvent historyEvent in events)
    {
        if (historyEvent.EventType == EventType.OrchestratorStarted)
        {
            var decisionStartedEvent = (OrchestratorStartedEvent)historyEvent;
            this.context.CurrentUtcDateTime = decisionStartedEvent.Timestamp;
            continue;
        }
        this.ProcessEvent(historyEvent);
        historyEvent.IsPlayed = true;
    }
}

this.context.IsReplaying = true;
ProcessEvents(pastEvents);

this.context.IsReplaying = false;
ProcessEvents(newEvents);
```

`ExecutionStarted` invokes the user function; every other event is routed to a handler on `TaskOrchestrationContext`. The function runs on a `SynchronousTaskScheduler` whose queue is executed inline ([source][sync-sched]), so an `await` on an unresolved task parks the continuation and returns control to the loop instead of blocking a thread. The Go port has no scheduler to hijack: `Await` pumps `processNextEvent()` until its task resolves, and if the history runs out it `panic`s with `ErrTaskBlocked`, which `start()` recovers as the normal "yield" ([source][go-task]).

Matching is by **sequence number**. Every scheduling call takes `idCounter++` and files an action under it ([source][ctx]):

```csharp
public async Task<object> ScheduleTaskInternal(string name, string version, string taskList, Type resultType,
    ScheduleTaskOptions options, params object[] parameters)
{
    int id = this.idCounter++;
    var scheduleTaskTaskAction = new ScheduleTaskOrchestratorAction { Id = id, Name = name, Version = version, Input = serializedInput, Tags = options.Tags };
    this.orchestratorActionsMap.Add(id, scheduleTaskTaskAction);
    var tcs = new TaskCompletionSource<string>();
    this.openTasks.Add(id, new OpenTaskInfo { Name = name, Version = version, Result = tcs });
    string serializedResult = await tcs.Task;
    return this.MessageDataConverter.Deserialize(serializedResult, resultType);
}
```

When replay reaches the `TaskScheduledEvent` that a previous turn persisted for that id, the handler checks that the current execution produced the same request — same id, same action kind, same name (case-insensitive) — and, if so, removes the pending action so it is not re-emitted. Any mismatch is a `NonDeterministicOrchestrationException` ([source][ctx]):

```csharp
public void HandleTaskScheduledEvent(TaskScheduledEvent scheduledEvent)
{
    int taskId = scheduledEvent.EventId;
    if (!this.orchestratorActionsMap.ContainsKey(taskId))
        throw new NonDeterministicOrchestrationException(scheduledEvent.EventId,
            $"A previous execution of this orchestration scheduled an activity task with sequence ID {taskId} and name "
            + $"'{scheduledEvent.Name}' (version '{scheduledEvent.Version}'), but the current replay execution hasn't "
            + "(yet?) scheduled this task. Was a change made to the orchestrator code after this instance had already started running?");
    var orchestrationAction = this.orchestratorActionsMap[taskId];
    if (orchestrationAction is not ScheduleTaskOrchestratorAction currentReplayAction)
        throw new NonDeterministicOrchestrationException(/* "…replay instead produced a {type} action with this sequence number…" */);
    if (!string.Equals(scheduledEvent.Name, currentReplayAction.Name, StringComparison.OrdinalIgnoreCase))
        throw new NonDeterministicOrchestrationException(/* "…replay instead scheduled an activity task named '{name}'…" */);
    this.orchestratorActionsMap.Remove(taskId);
}
```

The exception's constructor prefixes every message with `"Non-Deterministic workflow detected: "` ([source][nde]); the executor catches it and fails the orchestration. Resolution events are the other half: `HandleTaskCompletedEvent` looks up `openTasks[TaskScheduledId]` and sets the `TaskCompletionSource`, which resumes the parked `await`; a resolution with no open task is logged as a duplicate and dropped, not treated as an error. `HandleEventRaisedEvent` bypasses ids entirely and calls the orchestration's `RaiseEvent` by name. Inputs are **not** compared on replay — only id, kind and name — so an orchestration whose activity _argument_ changes is not detected.

The Go port's `onTaskScheduled` is the same check with the same message shape ([source][go-orch]): _"a previous execution called CallActivity for '%s' and sequence number %d at this point in the workflow logic, but the current execution doesn't have this action with this sequence number"_. Its runtime state layer additionally deduplicates resolutions on a `(kind, id)` correlator — `KindTask`/`KindTimer`/`KindChild` × `TaskScheduledId`/`TimerId` — before they ever reach the orchestrator, returning `ErrDuplicateEvent` ([source][go-dedup], [source][go-rs]).

### Actions out, events in

An execution turn does not write history events for its requests directly. It returns `OrchestratorActions` (schedule task, create timer, create sub-orchestration, send event, complete/continue-as-new); the dispatcher turns each into the corresponding request event appended to history plus an outbound message, and only the backend's commit persists both atomically. A `ContinueAsNew` action becomes a `ContinueAsNewEvent` in the old history and a brand-new `ExecutionStartedEvent` message with a fresh `ExecutionId`, the same `Name`, and `Version = NewVersion ?? runtimeState.Version` ([source][dispatcher]). The dispatcher also caps events per turn: past `MaxMessageCount` it appends a fake timer with a reserved id (`FakeTimerIdToSplitDecision`) to defer the rest to the next turn, and the context skips that id on replay.

### Dapr's actor-based engine

Dapr's engine README states the layering ([source][dapr-readme]): _"Internally, this engine depends on the Durable Task Framework for Go … an MIT-licensed open-source project for authoring workflows (or "orchestrations") as code."_ The `durabletask-go` `backend.Backend` interface is implemented by an actors backend ([source][dapr-backend]) that registers two internal actor types ([architecture docs][docs-arch]): `dapr.internal.<ns>.<app>.workflow` and `dapr.internal.<ns>.<app>.activity`.

**Workflow actor.** One per instance, id = instance id. Its state is a set of keys in the actor state store ([`wfengine/state/state.go`][dapr-state]): `inbox-NNNNNN` (the FIFO of unprocessed events, six-digit zero-padded index), `history-NNNNNN` (the append-only history), `customStatus`, `metadata` (inbox length, history length, `Generation`), plus signing-related keys. The docs describe the history keys as _"Like an append-only log, workflow history events are only added and never removed (except when a workflow performs a "continue as new" operation, which purges all history and restarts a workflow with a new input)"_ ([source][docs-arch]). A turn (`runWorkflow`, [source][dapr-run]) loads the state, appends any reminder payload (a fired timer or a cascaded terminate) to the inbox, drains the inbox into `NewEvents`, calls the application over the work-item stream, applies the returned actions to the runtime state, and saves. The docs' five-step lifecycle: _"1. A workflow actor is activated when it receives a new message. 2. New messages then trigger the associated workflow code … 3. Once the result is received, the actor schedules any tasks as necessary. 4. After scheduling, the actor updates its state in the state store. 5. Finally, the actor goes idle …"_

**Activity actor.** One per scheduled activity, id = workflow id + sequence number + generation. It stores no state; `InvokeMethod` _"creates a reminder that executes the activity logic. InvokeMethod returns immediately after creating the reminder, enabling the workflow to continue processing other events in parallel"_ ([source][dapr-activity]). The reminder name is constant per actor so retries collapse onto one scheduler entry ([source][dapr-act-rem]).

**Reminders are the durability primitive.** Durable timers are reminders named `timer-<id>` carrying a pre-built `TimerFired` event and the generation that created them ([source][dapr-timer]); `runWorkflow` discards a timer from an older generation. The docs state the guarantee: _"Prior to invoking application workflow code, the workflow or activity actor will create a new reminder. These reminders are made "one shot", meaning that they will expire after successful triggering. … if the node or the sidecar hosting the associated workflow or activity crashes, the reminder will reactivate the corresponding actor and the execution will be retried, forever."_ ([source][docs-arch])

---

## Analysis

### 1. Step identity and replay matching

Identity is **positional**: a per-execution monotonic `idCounter` (Go: `sequenceNumber`), reset to zero at the start of every turn, assigned in the order the orchestrator function makes scheduling calls. The persisted `TaskScheduledEvent.EventId` _is_ that counter value; a completion carries it back as `TaskScheduledId` ([README][hist-readme]). Matching on replay checks three things — id present in the current turn's action map, action kind, activity name (case-insensitive) — and nothing else ([`HandleTaskScheduledEvent`][ctx]). There is no stable name, no attempt counter, no args hash; retries are visible only as further `TaskScheduled` events with higher ids (_"there may be multiple `Task***` events generated if an activity task is retried"_). External events are the exception: `EventRaisedEvent` is matched by **name**, FIFO across waiters, and buffered in history if it arrives before a waiter exists (_"the event will be saved into the workflow's history and consumed immediately after the workflow requests the event"_ — [features][docs-features]; Go: `bufferedExternalEvents` in [`onExternalEventRaised`][go-orch]).

### 2. Journal versus world

The journal wins, unconditionally. The orchestrator never observes the world: the determinism rule is _"Workflows must not interact with global variables, environment variables, the file system, or make network calls"_ ([features][docs-features]); every observation is an activity whose result is a `TaskCompletedEvent`, and on replay that recorded result is returned verbatim, never re-fetched. Disagreement is therefore undetectable by design at the orchestrator level — the model has no notion of a re-observed value. What the engine _does_ detect is journal-versus-**code** disagreement, via the sequence-number check. The Dapr layer adds one world-versus-journal check outside the orchestrator: history **signing** (`sigcert`/`signature` keys in [`state.go`][dapr-state]), which verifies that the stored history was written by an authorised sidecar, i.e. tamper-evidence rather than reconciliation.

### 3. Determinism enforcement

By **discipline plus a coarse runtime check**. The language does nothing: C# and Go both allow `DateTime.UtcNow`, `rand`, goroutines and I/O inside an orchestrator. The docs enumerate the rules verbatim ([features][docs-features]):

> _"APIs that generate random numbers, random UUIDs, or the current date are non-deterministic. To work around this limitation, you can: Use these APIs in activity functions, or (Preferred) Use built-in equivalent APIs offered by the SDK."_
>
> _"Workflow functions must only interact indirectly with external state. External data includes any data that isn't stored in the workflow state. Workflows must not interact with global variables, environment variables, the file system, or make network calls."_
>
> _"Workflow functions must execute only on the workflow dispatch thread. … Workflow functions must never: Schedule background threads, or Use APIs that schedule a callback function to run on another thread. Failure to follow this rule could result in undefined behavior."_

The replay-safe substitutes are `CurrentUtcDateTime` (the `OrchestratorStartedEvent.Timestamp` of the current turn, so stable within a turn and monotone across turns) and `NewGuid()` (UUID v5 over instance id + time + sequence). `IsReplaying` is offered for side-effect suppression (logging) — the `.NET` SDK's loggers _"automatically check `IsReplaying` and suppress"_ ([source][dotnet-ctx]). The runtime check catches a subset of violations: a divergent _sequence of scheduling calls_ fails as `NonDeterministicOrchestrationException`; a divergent _argument_, a data-dependent branch that happens to schedule the same names, or a direct side effect are invisible. DTFx also sets a thread-static `IsOrchestratorThread` _"for detecting illegal async usage in orchestration code"_ ([source][oc]). The `.NET` SDK ships Roslyn analyzers (`src/Analyzers`) for the common mistakes; Go and the Dapr SDKs rely on review.

### 4. Compensation and failure handling

**Retries** are an orchestrator-side loop over durable timers, not an engine feature: `RetryInterceptor.Invoke` calls the activity, catches the `TaskFailedException`, computes back-off from `RetryOptions` and `CurrentUtcDateTime`, and `await`s `CreateTimer(retryAt, …)` before trying again ([source][retry]); the Go port's `internalScheduleTaskWithRetries` is the same shape ([source][go-orch]). Every attempt and every back-off timer is therefore in the history — the docs warn _"The actions performed by a retry policy are saved into a workflow's history. Care must be taken not to change the behavior of a retry policy after a workflow has already been executed"_ ([features][docs-features]). `FailureDetails.IsNonRetriable` short-circuits the loop.

**Compensation** is a documented pattern with no engine support. The patterns page ([source][docs-patterns]) defines it — _"The compensation pattern (also known as the saga pattern) provides a mechanism for rolling back or undoing operations that have already been executed when a workflow fails partway through"_ — and then shows user code: push a compensation name onto a list after each successful step, `catch`, reverse the list, call each compensating activity. The benefits list makes the absence explicit: _"Compensation Control: You have full control over when and how compensation activities are executed."_ There is no scope, no registration API, no LIFO guarantee beyond what the user writes, and because the compensation calls are themselves activities they get sequence numbers and are subject to the same replay rules.

**Failure propagation**: an activity's unhandled exception becomes `TaskFailedEvent` and resumes the orchestrator's `await` with `TaskFailedException`; a sub-orchestration's failure surfaces as `SubOrchestrationFailedException`. Unhandled in the orchestrator, it fails the instance (`ExecutionCompleted` with failure details). Dapr adds `ExecutionStalled` (see §5) as a non-terminal failure state.

### 5. Versioning against old histories

Three mechanisms, layered:

1. **Instance-level version string.** `ExecutionStartedEvent.Version` is set at creation and readable as `OrchestrationContext.Version`; `INameVersionObjectManager` resolves `(Name, Version)` to an orchestration class, so old instances keep routing to old code. `ContinueAsNew(newVersion, input)` is the only way an instance changes version ([source][dispatcher]). DTFx 3.x adds worker-side `VersioningSettings` — `MatchStrategy` `None`/`Strict`/`CurrentOrOlder` and `FailureStrategy` `Reject` (abandon the work item so another worker picks it up) or `Fail` (complete the instance with `VersionMismatch`) — evaluated before the executor runs ([source][versioning-settings], [dispatcher][dispatcher]).
2. **Patches** (Dapr / Go). `ctx.IsPatched("use-sms")` returns true at the end of history (new decision) or if the patch name is recorded on a prior `WorkflowStarted` event's `version.patches`, and false when replaying inside history without a record ([source][go-orch]). The docs: _"Patch checks are recorded in the workflow instance history the first time they are evaluated"_, and the rules — never reuse an identifier, never remove or reorder patches, only nest new patches inside old ones ([versioning][docs-versioning]).
3. **Named workflow versioning** (Dapr). Duplicate the function, register with `AddVersionedWorkflow("Workflow", isLatest, fn)`; new instances get the latest, in-flight instances their recorded name. _"the runtime does not migrate workflows between versions sequentially … so there's is no need to handle any compensation logic between versions"_ ([source][docs-versioning]).

The failure mode when these are not followed is **stalling**, not crashing: `hasPatchMismatch` requires the history's patch list to be an exact prefix of the current run's; on mismatch or an unregistered version name `stallWorkflow` discards the turn's `NewEvents`, appends `ExecutionStalled`, saves, and blocks the actor until context cancellation ([source][dapr-versioning]). _"Workflows can remain stalled for the entire duration of the rollout, until there are only new replicas available"_ ([versioning][docs-versioning]).

### 6. Concurrency under replay

Fan-out is ordinary code: schedule N tasks without awaiting, then `await Task.WhenAll(tasks)` (C#, [patterns][docs-patterns]) or, in Go, loop `Await` over the slice ([`samples/parallel/parallel.go`][go-parallel]). It works because scheduling and awaiting are decoupled: ids are assigned at **schedule** time in program order (`idCounter++` inside `ScheduleTaskInternal`), so the N `TaskScheduled` events are deterministic regardless of completion order, and completions resolve `openTasks[TaskScheduledId]` whichever order they arrive in. `WhenAll`/`WhenAny` are the plain `.NET` combinators running on the `SynchronousTaskScheduler`; the engine never sees them. The Go port has no `WhenAll` helper at all — `Await` on the first task pumps history, so later tasks may already be resolved by the time they are awaited. The limit is `IsReplaying`: it flips once, when the loop crosses from `PastEvents` to `NewEvents`, so there is no per-task "is this branch replaying" — the per-event `IsPlayed` flag exists in the history but is not surfaced to the orchestrator. Dapr bounds parallelism operationally (per-sidecar and global concurrency limits, [docs][docs-features]) rather than in the model.

### 7. Replay or snapshot

Pure replay; there is no snapshot path in the modern backends (`HistoryStateEvent` exists in the enum — _"contains a snapshot of the orchestration history. This event type is not used in most modern backend types"_ — [README][hist-readme]). Costs: every turn re-runs the function from the top over the full history, and Dapr loads `history-NNNNNN` keys individually from the state store each turn, so the docs push `ContinueAsNew` for anything long-lived: _"Continue-as-new restarts the workflow immediately and discards the results of any incomplete tasks - including activities, timers, and child workflows that were started but not awaited"_ and _"truncates the existing history, replacing it with a new history"_ ([features][docs-features]). Dapr's `Generation` counter (in `metadata`, on timers, on activity actor ids) is what lets a continued-as-new instance ignore stragglers from its previous life ([`runWorkflow`][dapr-run]). What replay rules out: the engine cannot inspect or migrate state (it has none of its own), and cannot tolerate a changed call sequence — hence §5.

### 8. Testing

DTFx ships an in-process backend, `DurableTask.Emulator.LocalOrchestrationService` — _"Fully functional in-proc orchestration service for testing"_ — implementing `IOrchestrationService` and `IOrchestrationServiceClient` over in-memory queues ([source][emulator]); the `.NET` SDK's `DurableTaskTestHost` does the same behind the gRPC sidecar protocol, _"without requiring any external backend (Azure Storage, SQL, etc)"_, backed by `InMemoryOrchestrationService` ([source][dotnet-testhost]). `durabletask-go` has `backend/local` for an in-memory task backend ([source][go-local]) and an sqlite backend. The engine's own suites include an explicit nondeterminism test — `NonDeterministicOrchestrationTest` drives `FAILTIMER`/`FAILTASK`/`FAILSUBORCH` variants of an orchestration and asserts the instance fails ([source][dtfx-nde-test]) — and the Go tests cover sequence-number reconciliation against synthetic optional timers ([source][go-exec-test]). What is **absent**: no crash-injection harness, no "replay this stored history against new code" fixture, and no guidance in the Dapr docs on unit-testing a workflow function (the SDK pages document no mocking API). The DTFx unit of test is a whole orchestration run end-to-end against the emulator.

### 9. Journal integrity and the single writer

Dapr's answer is inherited from its actor runtime, and it adds one mechanism
nothing else in this survey has: the record is cryptographically signed.

**The single writer is an actor activation.** A workflow instance is an actor, and
the actor runtime _"provides a simple turn-based access model for accessing actor
methods. Turn-based access greatly simplifies concurrent systems as there is no
need for synchronization mechanisms for data access"_
([actors overview][doc-actors]). Placement guarantees one live activation per
actor id across the cluster, so "one writer per workflow" is a property of the
platform rather than of the journal format, and there is no expected-version check
on an individual history append.

**Appends are transactional, at the state-store level.** History events, the inbox
and the metadata key are written through the actor state store's transactional
API, which the state store must support — the component has to declare
`actorStateStore` true ([actors overview][doc-actors]). A turn's worth of events
therefore commits together, which is what makes the per-turn `idCounter` scheme of
§1 sound.

**Every history event is signed, and the signature is checked on every load.**
_"Every history event produced during a workflow's lifetime is signed using the
sidecar's mTLS identity … creating an auditable chain of signatures that is
verified each time the workflow state is loaded"_
([history signing][doc-signing]). No other system surveyed treats its own record
as potentially tampered with. The documentation is also unusually candid about the
operational cost: signing trusts the Dapr root certificate authority, the default
self-signed root lasts a year, and _"if that root expires, or if you rotate to a
new root with a different private key, **every signed workflow issued under the
old root stops verifying** and fails to load with error type
`SignatureVerificationFailed`. There is no re-sign path."_ That is a durability
mechanism whose failure mode is the loss of every in-flight record, stated plainly
by its own authors.

**Tamper detection is not writer fencing.** A signature proves the sidecar's
identity wrote the event; it does not order two writers or reject a stale one.
Those remain the actor placement's job.

**Torn writes are the state store's problem**, and the choice of store therefore
decides what "durable" means — a deliberate consequence of the pluggable-component
model.

**Retention is a first-class policy.** History is kept indefinitely by default,
and a retention policy can be set per terminal state (`Completed`, `Failed`,
`Terminated`) with a Go duration, with deletion only once a workflow is terminal
([retention policy][doc-retention]). Few systems here make "how long is the record
kept" a configurable per-outcome decision.

### 10. Operator recovery and intervention

Seven operations exist as public API handlers, which is a broader surface than
most and narrower than it looks.

**The verbs are get, start, terminate, raise-event, pause, resume and purge**
([`workflow.go`][dapr-wf-api]), each versioned three times over (alpha, beta and
stable) — which is itself evidence that the operator surface is treated as part of
the product contract rather than as tooling.

**Pause and resume act on an in-flight instance**, unlike Inngest's function-level
pause: a paused workflow stops consuming its inbox and resumes where it stopped.

**Purge deletes a terminal instance's state**, and is the manual counterpart to the
retention policy.

**Terminate has no cancellation counterpart.** There is no operation that delivers
a cancellation the orchestrator can observe and handle, so compensation — which is
user code in a `catch` (§4) — does not get a turn when an operator stops a
workflow. That is a real gap next to Temporal's cancel-versus-terminate or
Restate's cancel-versus-kill.

**Raise-event doubles as the intervention channel**, letting an operator supply a
value the workflow is waiting for (§11) without touching the state store.

**Inspection is get-workflow plus whatever the state store allows.** There is no
API that returns the history event by event, so "what did this workflow do" is
answered by reading the actor's state keys directly — and, when signing is on, by
a record that verifies.

**A mismatch stalls rather than corrupts.** A version or patch mismatch puts the
instance in a stalled state (§5), which is the right default: it leaves the record
intact for an operator to act on instead of failing the run or guessing.

### 11. Suspension and external input

**Waiting is not running.** The workflow actor is deactivated while it waits, and a
durable timer is a reminder registered with the actor runtime; the reminder is what
brings the actor back. Because reminders are the platform's own durability
primitive, the documentation states the consequence bluntly: _"if the node or the
sidecar hosting the associated workflow or activity crashes, the reminder will
reactivate the corresponding actor and the execution will be retried, forever."_

**The primitives** are durable timers, external events
(`WaitForExternalEvent`/`RaiseEvent`), child workflows, and activity completion.
They are the Durable Task Framework's set, unchanged.

**External input is addressed by workflow id plus event name**, and events are
matched to waiters by name in arrival order (§1). An event that arrives before the
orchestrator reaches its wait is buffered in the history; one that arrives twice
is two events, so deduplication is the author's job; one that never arrives leaves
the instance waiting until a timer the author raced against it fires.

**There is no distinct persisted "suspended" state for a wait.** The runtime status
vocabulary covers running, completed, failed, terminated, pending, suspended — but
`Suspended` there means operator-paused, not waiting-on-input. A caller cannot
distinguish "blocked on an external event" from "activity in flight" without
reading the history.

**Human-in-the-loop is the documented pattern** and is built from a timer raced
against an external event, with the timer as escalation — the same construction as
Azure Durable Functions, from which this model descends.

---

## Strengths

- **The matching rule fits on one screen.** Id + kind + name; the error message says exactly what was expected and what was produced, and names the likely cause (_"Was a change made to the orchestrator code after this instance had already started running?"_).
- **Fan-out needs no engine support**: ids at schedule time, results by id, plain `WhenAll`.
- **Retries are just code over timers**, so they are visible in history and replay like anything else.
- **Dapr's reminder-driven turn** gives at-least-once re-drive of a crashed turn with no separate queue; timers, activity dispatch and re-drive are all the same primitive.
- **Patches + named versions + stall** is a complete rollout story: old code stays, new instances take the new path, mismatches park instead of corrupting.
- **In-process backends** (emulator, `InMemoryOrchestrationService`, `backend/local`) make end-to-end tests cheap.

## Weaknesses

- **Inputs are never compared on replay**, so an activity whose argument changed replays with the old result silently.
- **Determinism is discipline**: nothing prevents `DateTime.UtcNow` or a network call in an orchestrator; the runtime check only fires when the _call sequence_ diverges.
- **No re-observation model**: the journal always wins, so a world that changed under a resumed instance is invisible until an activity runs.
- **Compensation is a pattern with no API**: the docs' saga is a hand-maintained list reversed in a `catch`.
- **Per-turn replay cost is linear in history** and Dapr fetches history one key per event; `ContinueAsNew` is the only relief and it discards in-flight work.
- **No replay-against-stored-history test fixture**; nondeterminism is found in production or by an end-to-end test that happens to cover the change.

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                   | Trade-off                                                                                        |
| ----------------------------------------------------------------- | --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| Positional sequence ids, reset per turn                           | Zero API burden; ids fall out of program order; fan-out is free             | Any insertion/reorder of a scheduling call breaks every in-flight instance; no stable step names |
| Match id + kind + name, not input                                 | Cheap, catches the common code-edit mistake                                 | Argument drift is silent                                                                         |
| Orchestrator is forbidden from observing the world                | Makes replay trivially deterministic; no reconciliation logic in the engine | Every observation is an activity round-trip; stale results are re-served forever                 |
| Actions returned, events appended by the dispatcher               | Requests and outbound messages commit atomically per turn                   | A turn is a batch: a crash mid-turn re-runs the whole turn                                       |
| `IsReplaying` as a single flip at the past/new boundary           | Simple, enough for log suppression                                          | No per-task replay awareness; concurrent branches cannot tell which of them is "new"             |
| Retries as orchestrator code over durable timers                  | Fully durable, visible in history, no engine state                          | Changing a retry policy is a nondeterministic code change                                        |
| Dapr: workflow = actor, history = state keys, reminder = re-drive | Reuses placement, state stores and reminders the sidecar already has        | Per-event key I/O; state-store semantics (ETags, bulk ops) bound throughput                      |
| Patches recorded on `WorkflowStarted`; mismatch ⇒ stall           | Rollouts with mixed replicas never corrupt history                          | A stalled instance needs an operator; patch identifiers are forever                              |
| `ContinueAsNew` as the only history truncation                    | Keeps the model pure replay                                                 | Drops unfinished tasks; needs a generation counter to fence stragglers                           |

---

## Implications for a durable-execution library

- **Signing the record is a mechanism nobody else has, and its failure mode is
  instructive** (§9). Cryptographic tamper detection verified on every load is a
  real capability; trusting a certificate authority whose expiry invalidates every
  in-flight record, with no re-sign path, is a real hazard. A library adding
  integrity checks should prefer something whose key material cannot expire —
  a content hash rather than a signature — unless tamper-_attribution_ is actually
  required.
- **Placement-based single-writer is strong and unportable.** One live activation
  per id across a cluster is a better guarantee than any lease, and it is
  available only to a library that owns a placement service. A library without one
  has to fence explicitly.
- **Terminate without a cancel counterpart is a gap** (§10). If compensation is
  user code, an operator stop that never gives the program a turn cannot run it.
  Offering only the abrupt verb silently makes rollback unreachable.
- **Stall on mismatch, rather than fail** (§5). Leaving the record intact and the
  instance parked is the recovery-friendly default, and it composes with an
  operator surface that can then resume.
- **Retention as a per-terminal-state policy** is the right granularity: a failed
  run is worth keeping longer than a successful one, and a library that keeps
  everything forever eventually becomes a storage problem for its users.
- **Positional per-turn identity survives fan-out because ids are assigned at
  schedule time** (§6), which is the general lesson: positional schemes are safe
  under concurrency exactly when the position is fixed before any await.
- **A journaled clock and id generator derived from already-recorded data** is
  inherited from the Durable Task Framework and remains the cheapest way to remove
  two sources of nondeterminism (§3).
- **Retry forever is a default worth questioning.** Reminder-driven reactivation
  means a permanently failing activity retries indefinitely with no quarantine
  state, so an operator must notice.

---

## Sources

- [Azure/durabletask — GitHub repository][repo-dtfx]
- [microsoft/durabletask-dotnet — GitHub repository][repo-dotnet]
- [dapr/durabletask-go — GitHub repository][repo-go]
- [dapr/dapr — GitHub repository][repo-dapr]
- [`src/DurableTask.Core/History/README.md` — history event catalogue][hist-readme]
- [`src/DurableTask.Core/History/HistoryEvent.cs` — base event][hist-base]
- [`src/DurableTask.Core/History/EventType.cs` — event enum][hist-enum]
- [`src/DurableTask.Core/History/TaskScheduledEvent.cs`][hist-task] · [`ExecutionStartedEvent.cs`][hist-started] · [`ContinueAsNewEvent.cs`][hist-can]
- [`src/DurableTask.Core/TaskOrchestrationExecutor.cs` — the replay loop][executor]
- [`src/DurableTask.Core/TaskOrchestrationContext.cs` — sequence ids, matching, nondeterminism checks][ctx]
- [`src/DurableTask.Core/OrchestrationContext.cs` — `IsReplaying`, `CurrentUtcDateTime`, `Version`][oc]
- [`src/DurableTask.Core/OrchestrationRuntimeState.cs` — `PastEvents` / `NewEvents`][runtime-state]
- [`src/DurableTask.Core/TaskOrchestrationDispatcher.cs` — actions to events, `ContinueAsNew`, versioning gate][dispatcher]
- [`src/DurableTask.Core/RetryInterceptor.cs` — retries over durable timers][retry]
- [`src/DurableTask.Core/Settings/VersioningSettings.cs`][versioning-settings]
- [`src/DurableTask.Core/Exceptions/NonDeterministicOrchestrationException.cs`][nde]
- [`src/DurableTask.Core/SynchronousTaskScheduler.cs`][sync-sched]
- [`src/DurableTask.Core/DurableTask.Core.csproj` — version][core-csproj]
- [`src/DurableTask.Emulator/LocalOrchestrationService.cs` — in-proc backend][emulator]
- [`test/DurableTask.ServiceBus.Tests/DispatcherTests.cs` — `NonDeterministicOrchestrationTest`][dtfx-nde-test]
- [`src/Abstractions/TaskOrchestrationContext.cs` (.NET SDK) — `NewGuid`, `IsReplaying` docs][dotnet-ctx]
- [`src/InProcessTestHost/DurableTaskTestHost.cs` (.NET SDK)][dotnet-testhost] · [`InMemoryOrchestrationService.cs`][dotnet-inmem] · [`eng/targets/Release.props`][dotnet-release]
- [`task/orchestrator.go` (Go) — `WorkflowContext`, `onTaskScheduled`, `IsPatched`][go-orch]
- [`task/task.go` (Go) — `Await` / `ErrTaskBlocked`][go-task]
- [`backend/runtimestate/runtimestate.go` (Go) — `addEventWithDedup`][go-rs] · [`dedup/key.go`][go-dedup]
- [`api/protos/history_events.pb.go` (Go) — `HistoryEvent` oneof][go-proto]
- [`backend/local/task.go` (Go) — in-memory backend][go-local] · [`tests/task_executor_test.go`][go-exec-test] · [`samples/parallel/parallel.go`][go-parallel]
- [`pkg/runtime/wfengine/README.md` (Dapr)][dapr-readme]
- [`pkg/runtime/wfengine/backends/actors/actors.go` (Dapr) — the actors backend][dapr-backend]
- [`pkg/runtime/wfengine/state/state.go` (Dapr) — state-store key layout][dapr-state]
- [`pkg/actors/targets/workflow/orchestrator/run.go` (Dapr) — a workflow actor turn][dapr-run]
- [`pkg/actors/targets/workflow/orchestrator/timer.go` (Dapr) — timers as reminders][dapr-timer]
- [`pkg/actors/targets/workflow/orchestrator/versioning.go` (Dapr) — patch mismatch, stall][dapr-versioning]
- [`pkg/actors/targets/workflow/activity/activity.go` (Dapr) — activity actor][dapr-activity] · [`reminder.go`][dapr-act-rem]
- [`go.mod` (Dapr) — pinned `durabletask-go`][dapr-gomod]
- [Dapr docs: Workflow overview][docs-overview] · [Features and concepts][docs-features] · [Architecture][docs-arch] · [Patterns][docs-patterns] · [Versioning][docs-versioning] · [Protocol: state and history][docs-proto-state]
- [Related: Azure Durable Functions][adf] · [Temporal][temporal] · [Catalog index][index] · [Comparison][comparison]

<!-- References -->

[repo-dtfx]: https://github.com/Azure/durabletask
[repo-dotnet]: https://github.com/microsoft/durabletask-dotnet
[repo-go]: https://github.com/dapr/durabletask-go
[repo-dapr]: https://github.com/dapr/dapr
[hist-readme]: https://github.com/Azure/durabletask/blob/b385165ac10ecebbf183fdfdb07db33307756792/src/DurableTask.Core/History/README.md
[hist-base]: https://github.com/Azure/durabletask/blob/b385165ac10ecebbf183fdfdb07db33307756792/src/DurableTask.Core/History/HistoryEvent.cs
[hist-enum]: https://github.com/Azure/durabletask/blob/b385165ac10ecebbf183fdfdb07db33307756792/src/DurableTask.Core/History/EventType.cs
[hist-task]: https://github.com/Azure/durabletask/blob/b385165ac10ecebbf183fdfdb07db33307756792/src/DurableTask.Core/History/TaskScheduledEvent.cs
[hist-started]: https://github.com/Azure/durabletask/blob/b385165ac10ecebbf183fdfdb07db33307756792/src/DurableTask.Core/History/ExecutionStartedEvent.cs
[hist-can]: https://github.com/Azure/durabletask/blob/b385165ac10ecebbf183fdfdb07db33307756792/src/DurableTask.Core/History/ContinueAsNewEvent.cs
[executor]: https://github.com/Azure/durabletask/blob/b385165ac10ecebbf183fdfdb07db33307756792/src/DurableTask.Core/TaskOrchestrationExecutor.cs
[ctx]: https://github.com/Azure/durabletask/blob/b385165ac10ecebbf183fdfdb07db33307756792/src/DurableTask.Core/TaskOrchestrationContext.cs
[oc]: https://github.com/Azure/durabletask/blob/b385165ac10ecebbf183fdfdb07db33307756792/src/DurableTask.Core/OrchestrationContext.cs
[runtime-state]: https://github.com/Azure/durabletask/blob/b385165ac10ecebbf183fdfdb07db33307756792/src/DurableTask.Core/OrchestrationRuntimeState.cs
[dispatcher]: https://github.com/Azure/durabletask/blob/b385165ac10ecebbf183fdfdb07db33307756792/src/DurableTask.Core/TaskOrchestrationDispatcher.cs
[retry]: https://github.com/Azure/durabletask/blob/b385165ac10ecebbf183fdfdb07db33307756792/src/DurableTask.Core/RetryInterceptor.cs
[versioning-settings]: https://github.com/Azure/durabletask/blob/b385165ac10ecebbf183fdfdb07db33307756792/src/DurableTask.Core/Settings/VersioningSettings.cs
[nde]: https://github.com/Azure/durabletask/blob/b385165ac10ecebbf183fdfdb07db33307756792/src/DurableTask.Core/Exceptions/NonDeterministicOrchestrationException.cs
[sync-sched]: https://github.com/Azure/durabletask/blob/b385165ac10ecebbf183fdfdb07db33307756792/src/DurableTask.Core/SynchronousTaskScheduler.cs
[core-csproj]: https://github.com/Azure/durabletask/blob/b385165ac10ecebbf183fdfdb07db33307756792/src/DurableTask.Core/DurableTask.Core.csproj
[emulator]: https://github.com/Azure/durabletask/blob/b385165ac10ecebbf183fdfdb07db33307756792/src/DurableTask.Emulator/LocalOrchestrationService.cs
[dtfx-nde-test]: https://github.com/Azure/durabletask/blob/b385165ac10ecebbf183fdfdb07db33307756792/test/DurableTask.ServiceBus.Tests/DispatcherTests.cs
[dotnet-ctx]: https://github.com/microsoft/durabletask-dotnet/blob/bc2bc12ca5ee3a12a6e633250ade5efe6ae90ef4/src/Abstractions/TaskOrchestrationContext.cs
[dotnet-testhost]: https://github.com/microsoft/durabletask-dotnet/blob/bc2bc12ca5ee3a12a6e633250ade5efe6ae90ef4/src/InProcessTestHost/DurableTaskTestHost.cs
[dotnet-inmem]: https://github.com/microsoft/durabletask-dotnet/blob/bc2bc12ca5ee3a12a6e633250ade5efe6ae90ef4/src/InProcessTestHost/Sidecar/InMemoryOrchestrationService.cs
[dotnet-release]: https://github.com/microsoft/durabletask-dotnet/blob/bc2bc12ca5ee3a12a6e633250ade5efe6ae90ef4/eng/targets/Release.props
[go-orch]: https://github.com/dapr/durabletask-go/blob/18cd4b5a26a5d53f127a12dd7aa2d496314f3de6/task/orchestrator.go
[go-task]: https://github.com/dapr/durabletask-go/blob/18cd4b5a26a5d53f127a12dd7aa2d496314f3de6/task/task.go
[go-rs]: https://github.com/dapr/durabletask-go/blob/18cd4b5a26a5d53f127a12dd7aa2d496314f3de6/backend/runtimestate/runtimestate.go
[go-dedup]: https://github.com/dapr/durabletask-go/blob/18cd4b5a26a5d53f127a12dd7aa2d496314f3de6/backend/runtimestate/dedup/key.go
[go-proto]: https://github.com/dapr/durabletask-go/blob/18cd4b5a26a5d53f127a12dd7aa2d496314f3de6/api/protos/history_events.pb.go
[go-local]: https://github.com/dapr/durabletask-go/blob/18cd4b5a26a5d53f127a12dd7aa2d496314f3de6/backend/local/task.go
[go-exec-test]: https://github.com/dapr/durabletask-go/blob/18cd4b5a26a5d53f127a12dd7aa2d496314f3de6/tests/task_executor_test.go
[go-parallel]: https://github.com/dapr/durabletask-go/blob/18cd4b5a26a5d53f127a12dd7aa2d496314f3de6/samples/parallel/parallel.go
[dapr-readme]: https://github.com/dapr/dapr/blob/e9f08dc2dfbb37c9d52fa17186c1bbf6d9d94444/pkg/runtime/wfengine/README.md
[dapr-backend]: https://github.com/dapr/dapr/blob/e9f08dc2dfbb37c9d52fa17186c1bbf6d9d94444/pkg/runtime/wfengine/backends/actors/actors.go
[dapr-state]: https://github.com/dapr/dapr/blob/e9f08dc2dfbb37c9d52fa17186c1bbf6d9d94444/pkg/runtime/wfengine/state/state.go
[dapr-run]: https://github.com/dapr/dapr/blob/e9f08dc2dfbb37c9d52fa17186c1bbf6d9d94444/pkg/actors/targets/workflow/orchestrator/run.go
[dapr-timer]: https://github.com/dapr/dapr/blob/e9f08dc2dfbb37c9d52fa17186c1bbf6d9d94444/pkg/actors/targets/workflow/orchestrator/timer.go
[dapr-versioning]: https://github.com/dapr/dapr/blob/e9f08dc2dfbb37c9d52fa17186c1bbf6d9d94444/pkg/actors/targets/workflow/orchestrator/versioning.go
[dapr-activity]: https://github.com/dapr/dapr/blob/e9f08dc2dfbb37c9d52fa17186c1bbf6d9d94444/pkg/actors/targets/workflow/activity/activity.go
[dapr-act-rem]: https://github.com/dapr/dapr/blob/e9f08dc2dfbb37c9d52fa17186c1bbf6d9d94444/pkg/actors/targets/workflow/activity/reminder.go
[dapr-gomod]: https://github.com/dapr/dapr/blob/e9f08dc2dfbb37c9d52fa17186c1bbf6d9d94444/go.mod
[docs-overview]: https://docs.dapr.io/developing-applications/building-blocks/workflow/workflow-overview/
[docs-features]: https://docs.dapr.io/developing-applications/building-blocks/workflow/workflow-features-concepts/
[docs-arch]: https://docs.dapr.io/developing-applications/building-blocks/workflow/workflow-architecture/
[docs-patterns]: https://docs.dapr.io/developing-applications/building-blocks/workflow/workflow-patterns/
[docs-versioning]: https://docs.dapr.io/developing-applications/building-blocks/workflow/workflow-versioning/
[docs-proto-state]: https://github.com/dapr/docs/blob/78b25330358bbe68b7e0f2d704f02d0432aebb75/daprdocs/content/en/contributing/protocol-reference/workflow-protocol/workflow-protocol-state-and-history.md
[adf]: ./azure-durable-functions.md
[temporal]: ./temporal.md
[index]: ./index.md
[comparison]: ./comparison.md
[dapr-wf-api]: https://github.com/dapr/dapr/blob/e9f08dc2dfbb37c9d52fa17186c1bbf6d9d94444/pkg/api/universal/workflow.go
[doc-actors]: https://github.com/dapr/docs/blob/78b25330358bbe68b7e0f2d704f02d0432aebb75/daprdocs/content/en/developing-applications/building-blocks/actors/actors-overview.md
[doc-retention]: https://github.com/dapr/docs/blob/78b25330358bbe68b7e0f2d704f02d0432aebb75/daprdocs/content/en/developing-applications/building-blocks/workflow/workflow-history-retention-policy.md
[doc-signing]: https://github.com/dapr/docs/blob/78b25330358bbe68b7e0f2d704f02d0432aebb75/daprdocs/content/en/developing-applications/building-blocks/workflow/workflow-history-signing.md
