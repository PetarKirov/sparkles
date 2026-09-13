# Netherite: Efficient Execution of Serverless Workflows (VLDB 2022)

The engine paper behind Durable Functions' second backend: it replaces per-step storage round trips with a per-partition event-sourced state machine whose commit log is the only truth, and then lets the next step run before the previous one's log write has landed.

| Field        | Value                                                                                                                                                                                                                                |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Authors      | Sebastian Burckhardt, Badrish Chandramouli, Chris Gillum, David Justo, Konstantinos Kallas, Connor McMahon, Christopher S. Meiklejohn, Xiangfeng Zhu                                                                                 |
| Venue / year | PVLDB 15(8), pages 1591–1604, 2022 ([VLDB PDF][vldb-pdf]); an earlier preprint, _Serverless Workflows with Durable Functions and Netherite_, is on [arXiv][arxiv] (submitted February 26, 2021)                                      |
| DOI or URL   | [10.14778/3529337.3529344][doi]                                                                                                                                                                                                      |
| Category     | theory (with the shipped engine as a secondary source)                                                                                                                                                                               |
| Grounds      | questions 1, 2, 3, 6, 7 and 8; questions 4 and 5 are explicitly outside the engine's contract (see [The model](#the-model))                                                                                                          |
| Engine       | [microsoft/durabletask-netherite][repo] (MIT), NuGet `Microsoft.Azure.DurableTask.Netherite` `3.1.1` (January 22, 2026, [NuGet][nuget]); the README still says "The current version of Netherite is _2.1.0_" ([`README.md`][readme]) |
| Local clone  | `$REPOS/durabletask-netherite` at `3ae7dfbc0f4f00a1d55bacb12ae017277f1c7e7d`                                                                                                                                                         |

**Last reviewed:** September 12, 2026.

---

## What it establishes

The paper's result is architectural rather than theorematic: grouping thousands of fine-grained workflow instances into 12–32 partitions, persisting each partition as an event-sourced state machine over a group-committed log, and pipelining execution ahead of persistence removes the IOPS bottleneck of the original Durable Functions (DF) backend without weakening its guarantee that "each individual workflow step commits like a serializable transaction" (§1.1). The measured consequence is a throughput improvement of up to 18.6× and a latency improvement of up to 31× at the 95th percentile against the original engine on the same hardware (§6).

The definition everything hangs on is in §5.2:

> "To achieve efficient continuous persistence, Netherite employs event sourcing, a dual persistence model using a combination of a commit log and checkpoints. With event sourcing, the partition state is a deterministic function of the sequence of events that were processed. We persist the partition state both continuously as an event log, and occasionally as a checkpoint—limiting the number of events that have to be replayed on recovery." ([paper][doi], §5.2)

Two more definitions carry the correctness argument. **Serializable commit** (§3.3.1): committing a work item means atomically removing the consumed messages from the instance queue, updating the instance state, and enqueueing the produced messages, and "all of these effects must appear to execute atomically and in isolation." **Causal dependence** (§1.1, footnote 2): "B is causally dependent on A if B consumes a message produced by A, if B reads an instance state written by A, or if there is a transitive chain of such dependencies." Pipelining is then stated as a constraint on commit order, not on execution order: "we can start executing B immediately after A completes execution, even before A is persisted; as long as we respect causal dependencies during persistence, i.e. do not commit B before committing A."

The paper is careful to bound the guarantee. Exactly-once holds for internal state and messages only; for external calls §3.3.3 says "Since there can be multiple execution attempts of a work item before it commits successfully, calls to external services may be duplicated. This issue is an unavoidable property of fault-tolerant workflow systems permitting external calls, and sometimes requires the application code to take extra precautions."

## The model

### The serverless message-passing model (§3)

DF applications compile to three things: **instances** (orchestrations and entities, each with a key, an inbound message queue and a state), **tasks** (stateless activity invocations in one task queue), and **messages**. Two kinds of transition, called work items, move the system forward:

1. A stateless task work item consumes a message `m` from the task queue, computes, and enqueues a response `m'` to the instance that produced `m`.
2. A stateful instance work item for instance `k` with state `v` consumes a batch of inbound messages `m1 … mn`, produces `v'` and outgoing messages `m1' … mk'`.

Orchestration code itself is not part of the engine model. §3.2 restates the DF replay mechanism as a compilation step: "DF represents the state of an orchestration as a partial history of events, which can be replayed to reconstruct the state. The history replay is transparent; it does not re-execute completed tasks but reuses the results recorded in the history." Netherite stores that history; it does not interpret it. The sibling page on [Azure Durable Functions][azure-df] covers the application-level replay.

Error handling and compensation (question 4) are likewise pushed above the engine: "application-level errors, including function timeouts, are not automatically retried, but are handled in a manner defined by the programming model; in the case of DF, there are multiple error handling mechanisms available, such as exception handling, and limited retries. Importantly, these are implemented on top of the message-passing layer, and do not involve the execution engine" (§3.3.2). Versioning of workflow code against old histories (question 5) is not discussed at all; the engine persists `HistoryEvent` lists opaquely.

### One partition (§5.2, Figure 7c)

Every event a partition receives is placed into one totally ordered event queue and then duplicated into two streams: "The stream on the left is persisted to storage as-is, creating a commit log. The stream on the right is applied to the current in-memory state of the partition… That state is also saved to storage periodically, to create checkpoints." The partition state has five components (Figure 8): **I** instance states, **P** the last processed input-queue position plus a deduplication vector, **S** per-instance inbound buffers (sessions), **O** the outbox, **T** pending tasks. The four update events are `MessagesReceived` (P, S), `MessagesSent` (O), `TaskCompleted` (S, T) and `StepCompleted` (I, S, O, T).

The shipped engine keeps that shape. The partition's state is a set of `TrackedObject`s keyed by `TrackedObjectKey.TrackedObjectType`: the singletons `Activities`, `Dedup`, `Outbox`, `Reassembly`, `Sessions`, `Timers`, `Prefetch`, `Queries`, `Stats`, and the per-instance `History` and `Instance` objects ([`TrackedObjectKey.cs`][tok]). The paper's `StepCompleted` is `BatchProcessed`, an event whose fields are the whole step transition ([`BatchProcessed.cs`][bp]):

```csharp
// src/DurableTask.Netherite/Events/PartitionEvents/Internal/BatchProcessed.cs (abridged)
class BatchProcessed : PartitionUpdateEvent, IRequiresPrefetch
{
    [DataMember] public long SessionId { get; set; }
    [DataMember] public string InstanceId { get; set; }
    [DataMember] public long BatchStartPosition { get; set; }   // consumed messages: S
    [DataMember] public int BatchLength { get; set; }
    [DataMember] public List<HistoryEvent> NewEvents { get; set; } // appended history: I
    [DataMember] public OrchestrationStatus OrchestrationStatus { get; set; }
    [DataMember] public List<TaskMessage> ActivityMessages { get; set; } // T
    [DataMember] public List<TaskMessage> LocalMessages { get; set; }    // S (same partition)
    [DataMember] public List<TaskMessage> RemoteMessages { get; set; }   // O
    [DataMember] public List<TaskMessage> TimerMessages { get; set; }
    [DataMember] public PersistFirstStatus PersistFirst { get; set; }
    public enum PersistFirstStatus { NotRequired, Required, Done };

    public string WorkItemId => SessionsState.GetWorkItemId(this.PartitionId, this.SessionId, this.BatchStartPosition);
}
```

Applying an event is a visitor walk driven by an `EffectTracker`: `DetermineEffects` seeds the list of tracked objects to touch (for `BatchProcessed`, just `Sessions`), and each object's `Process` overload may add further keys, which are processed recursively until the list is empty ([`EffectTracker.cs`][effect-tracker]). `SessionsState.Process(BatchProcessed)` fans out to `Activities`, `Timers`, `Outbox`, the target sessions of local messages, and finally `Instance(id)` and `History(id)` ([`SessionsState.cs`][sessions]). `HistoryState.Process(BatchProcessed)` appends `NewEvents` to `List<HistoryEvent> History`, bumping `Episode` on each `OrchestratorStarted` ([`HistoryState.cs`][history]). That list is exactly the DF history the orchestration's own replay reads; the engine's log entry and the application's history are two different levels of event sourcing, one nested in the other.

### The commit log and the two workers

Intake serializes each update event, appends the bytes to a FASTER `FasterLog`, records the resulting tail address on the event as `NextCommitLogPosition`, and then hands the batch to two workers in parallel: the `StoreWorker` applies it to state and the `LogWorker` commits the log ([`LogWorker.cs`][log-worker]):

```csharp
// src/DurableTask.Netherite/StorageLayer/Faster/LogWorker.cs — IntakeWorker.Process (abridged)
var bytes = Serializer.SerializeEvent(evt, first | last);
this.logWorker.AddToFasterLog(bytes);
partitionUpdateEvent.NextCommitLogPosition = this.logWorker.log.TailAddress;
// ...
// the store worker and the log worker can now process these events in parallel
this.logWorker.storeWorker.SubmitBatch(batch);
this.logWorker.SubmitBatch(this.updateEvents);
```

When `log.CommitAsync()` returns, the `LogWorker` calls `DurabilityListeners.ConfirmDurable(evt)` on every event now below `CommittedUntilAddress`. That callback is the whole mechanism by which "not yet durable" is kept invisible: anything that must wait for durability registers as a listener on the event.

### Speculation, or "pipelining"

The paper calls it pipelining; the code calls it speculation (`// if speculation is disabled,` in [`SessionsState.cs`][sessions]) and exposes it as the setting `PersistStepsFirst`, documented as "Forces steps to pe persisted before applying their effects, disabling all pipelining." with default `false` ([`NetheriteOrchestrationServiceSettings.cs`][settings]). With pipelining on, `BatchProcessed` is applied to in-memory state as soon as the work item finishes; the next work item for that session, and any activity it scheduled, start immediately. With `PersistStepsFirst`, the event is parked in `StepsAwaitingPersistence`, and only the durability callback resubmits a clone marked `PersistFirstStatus.Done`.

What may **not** run ahead of the log is anything that leaves the partition. The outbox holds cross-partition messages and client responses keyed by the producing event's commit position and sends them only from the durability callback ([`OutboxState.cs`][outbox]):

```csharp
// src/DurableTask.Netherite/PartitionState/OutboxState.cs (abridged)
void SendBatchOnceEventIsPersisted(PartitionUpdateEvent evt, EffectTracker effects, Batch batch)
{
    var commitPosition = evt.NextCommitLogPosition;
    this.Outbox[commitPosition] = batch;
    foreach (var partitionMessageEvent in batch.OutgoingMessages)
    {
        partitionMessageEvent.OriginPartition = this.Partition.PartitionId;
        partitionMessageEvent.OriginPosition = commitPosition;
    }
    if (!effects.IsReplaying)
    {
        // register for a durability notification, at which point we will send the batch
        DurabilityListeners.Register(evt, this);
    }
}
public void ConfirmDurable(Event evt) => this.Send(((PartitionUpdateEvent)evt).OutboxBatch);
```

There is one further barrier inside a partition: a step whose local messages loop back to its own session forces the next batch to wait for persistence ("detect loopback messages, to guarantee that they act as a persistence barrier", `waitForPersistence: containsLoopbackMessages` in [`SessionsState.cs`][sessions], consumed by [`OrchestrationMessageBatch.cs`][omb]).

The paper's justification for restricting speculation to a single partition is the recovery cost of the alternative. A previous version propagated messages before persisting them, and "we decided to disable it and limit pipelining to a single partition because global pipelining requires significant coordination during recoveries: when one partition crashes, multiple other partitions may have to roll back to a previous state which can disrupt service of the whole system" (§5.3).

### Exactly-once between partitions

Each `PartitionMessageEvent` carries `OriginPartition` and `OriginPosition` (the sender's commit-log position), combined into a `DedupPosition` tuple ([`PartitionMessageEvent.cs`][pme]). The receiver's `DedupState` keeps `Dictionary<uint, (long Position, int SubPosition)> LastProcessed` per origin partition and drops any event whose position is not strictly greater ([`DedupState.cs`][dedup]). Since the outbox resends everything unconfirmed on recovery, and Event Hubs delivers in order, at-least-once resend plus monotone-position dedup yields exactly-once. The `Event.SafeToRetryFailedSend` comment states the same partition of responsibility ([`Event.cs`][event]): client requests "are not safe to duplicate as they could restart an orchestration or deliver a message twice", while "duplicate partition events are deduplicated by Dedup".

### Recovery (§5.2.2)

"On recovery, a partition first recovers its latest persisted state. It does so by retrieving the latest checkpoint (if any), and then replaying the commit log (if the commit log has persisted events beyond what is in the checkpoint). After this step, the states of P, S, O, I, and T have been reestablished. Next, we restart tasks: (1) Start a stateful work item for each session in S. (2) Start a stateless work item for each task in T. (3) Start a sender loop, which (re-)sends all messages in O. (4) Start a receiver loop, which starts receiving from the position stored in P."

`PartitionStorage.CreateOrRestoreAsync` is that paragraph in code ([`PartitionStorage.cs`][partition-storage]): `FindCheckpointAsync`, then `store.RecoverAsync()` (which returns the checkpoint's `CommitLogPosition`, `InputQueuePosition` and `InputQueueFingerprint`, [`FasterKV.cs`][fasterkv]), then `ReplayCommitLog` from that position to `log.TailAddress` with `effectTracker.IsReplaying = true` ([`StoreWorker.cs`][store-worker]), then `RestartThingsAtEndOfRecovery`, which submits a `RecoveryCompleted` event whose effects touch `Activities`, `Sessions`, `Outbox`, `Timers`, `Prefetch`, `Queries` and `Dedup` ([`RecoveryCompleted.cs`][recovery-completed]). A fresh partition takes an empty checkpoint before its first log write "so we can recover from it next time".

## Results

All numbers are from §6 of the [paper][doi]; the baseline is the original Azure Storage backend on the same Elastic Premium cluster, 12 partitions.

| Measurement                               | Result                                                                                            |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Throughput vs original DF (Q1)            | up to 12.2× (Hello5), 7.8× (Bank), 18.6× (WordCount), 2.35× (CollisionSearch); 1.1–3.5× on 1 core |
| Storage requests vs original DF (Q2)      | 4.4× to 71.6× fewer; fewer bytes read and written too, from the binary event encoding             |
| Pipelining's effect on throughput (Q3)    | 6%, 1.2%, 0.8%, 0.4% on the four benchmarks: "pipelining is a latency optimization"               |
| Pipelining's effect on latency (Q3)       | median / 95th: 7.3× / 7.1× (Hello3), 7.7× / 7.7× (Sequence), 8% / 6% (Image Recognition)          |
| Latency vs original DF (Q4)               | median 16×, 14×, 17%; 95th 31×, 19×, 33% (Hello3, Sequence, Image Recognition)                    |
| Latency vs queues / storage triggers (Q4) | queues: median 19×, 95th 29×; triggers: 1,000× to 10,000×                                         |
| Latency vs AWS Step Functions (Q4)        | Hello3 median 30×, 95th 25×, calling AWS Lambdas over HTTP from Azure                             |

The docs site states the practical version of the same claim: "Multiple orchestration steps can be persisted in a single storage write, which reduces latency when issuing a sequence of very short activities. It can improve throughput by up to 10x." ([engine considerations][docs-engine]).

The correctness "result" is an argument, not a proof. §5.2.3: "Netherite satisfies serializable commit because it commits work items as a single StepCompleted event in the commit log. Writes to the commit log are atomic, thus the transition commits at the moment this event is persisted in the log." And §5.3 on pipelining: "The important bit is that the pipeline never commits a transition that has a dependency on an uncommitted transition. In fact, a case can be made that the pipelining optimization is analogous to a combination of group commit and early lock release, two well-known optimizations in transaction processing."

## Relevance to durable execution

### 1. Step identity and replay matching

At the engine level a step is a `BatchProcessed` event and its identity is positional: `WorkItemId` is `(PartitionId, SessionId, BatchStartPosition)`, the log assigns `NextCommitLogPosition`, and cross-partition messages are identified by `(OriginPartition, OriginPosition, SubPosition)`. There is no name, no arguments hash, and no attempt counter; identity is the position in a totally ordered stream. Replay matching is idempotence by position: `EffectTracker.ProcessEffectOn` applies an update to a tracked object only if `trackedObject.LastUpdate < this.currentUpdate.NextCommitLogPosition` ([`EffectTracker.cs`][effect-tracker]), which is what makes replaying a log tail over a checkpoint that already reflects some of it safe. Application-level step identity (which activity result matches which `await`) lives one level up in the DF history and is out of scope for the paper.

### 2. Journal versus world

The log wins, unconditionally, and the world is never consulted. Recovery re-establishes P, S, O, I and T from checkpoint plus log tail; anything the previous incarnation did that did not reach the log did not happen. Two consequences: activities that ran ahead of a lost log write are re-run (at-least-once), and the paper concedes that pipelining widens that window: "without pipelining, the scope of reexecution of external effects is limited to those belonging to a single transition, while pipelining can lead to a reexecution of external effects belonging to more than one transition" (§5.3). The design rule that keeps this tolerable is that only **engine-owned** effects are deferred until durable (outbox sends, client responses, loopback batches); user code's external effects are not deferred and are explicitly at-least-once.

The one place the engine detects the world changing under it is the input queue: the checkpoint records an `InputQueueFingerprint`, and if the Event Hubs queue was recreated the fingerprint differs, `RestartThingsAtEndOfRecovery` resets the receive position to `(0,0)`, and `RecoveryCompleted.ResetInputQueue` makes the outbox resend every batch including confirmed ones ([`StoreWorker.cs`][store-worker], [`OutboxState.cs`][outbox]). Disagreement is detected by a fingerprint on the channel, not by re-observing content.

### 3. Determinism enforcement

Enforced by construction and checked by test, not by language. "Since each event's effect on the partition state must be deterministic, it is often necessary to decompose processes into chains of multiple events" (§5.2): anything nondeterministic (a completed work item, a timer firing, a received message, an acknowledgement) enters the state only as a logged event, so state application is a pure fold. Replay-time suppression is by a flag: `EffectTracker.IsReplaying` is documented as "True if we are replaying this effect during recovery. Typically, external side effects (such as launching tasks, sending responses, etc.) are suppressed during replay." ([`EffectTracker.cs`][effect-tracker]), and every `Process` overload that would start a work item or send a message is guarded by `if (!effects.IsReplaying)`. The `ReplayChecker` test hook then verifies the determinism claim (see 8).

### 6. Concurrency under replay

Concurrency is between sessions, never within the log. Work items for different instances run in parallel on the host's task and instance workers, but each commits as one event in one totally ordered queue, so "Dependent events may thus be committed simultaneously, but never out of order" (§5.2.3). On replay there is nothing to reorder: the log is a linearization already. Within a session, batches are strictly sequential (`BatchStartPosition` must equal the session's current position or the event is discarded as "session was replaced", [`SessionsState.cs`][sessions]). Cross-partition concurrency is resolved by the outbox-plus-dedup protocol, which is why global pipelining had to be abandoned: it would have made a partition's committed state depend on another partition's uncommitted state.

### 7. Replay or snapshot

Both, with a stated division of labor: the log is the truth and is written continuously; the FasterKV checkpoint exists only to bound replay time and is taken asynchronously and incrementally. Triggers in the shipped engine are a log growth of `MaxNumberBytesBetweenCheckpoints` (default 20 MB), `MaxNumberEventsBetweenCheckpoints` (default 10,000), or an idle period (default 60 s), and the checkpoint records the log position and input-queue position it corresponds to ([`NetheriteOrchestrationServiceSettings.cs`][settings], [`StoreWorker.cs`][store-worker]). The reason given for continuous logging rather than periodic snapshots is the external-effect problem: "We chose to provide continuous persistence (not just sporadic checkpointing) because it minimizes re-execution of tasks on recovery. This is desirable for workflow applications because tasks can have external effects, such as sending an e-mail, and applications may not always de-duplicate such effects" (§5.1). The costs the paper accepts: a serialized state (every tracked object and event is `[DataContract]`), a larger-than-memory store to hold checkpoints (FASTER's hybrid log), and lazy loading so a moved partition can start before its whole checkpoint is read.

Orchestration histories are the second replay layer: `HistoryState` holds the DF `List<HistoryEvent>`, and a work item is rebuilt either `ContinueFromCursor` (the cached `OrchestrationWorkItem` from the last step, when `CacheOrchestrationCursors` is on) or `ContinueFromHistory` (re-run the orchestration code over the stored history) ([`OrchestrationMessageBatch.cs`][omb]). The engine snapshots and logs at its level so that the application's replay only ever has to happen once per resumed instance, not once per recovery.

### 8. Testing

The paper has no testing section; the engine has four hooks on `TestHooks` ([`TestHooks.cs`][test-hooks]):

- `ReplayChecker` "Validates the replay, by maintaining an ongoing checkpoint and confirming the commutative diagram serialize(new-state) = serialize(deserialize(old-state) + event)" ([`ReplayChecker.cs`][replay-checker]). It is enabled for the whole xunit suite by [`HostFixture.cs`][host-fixture], so every scenario test also asserts that every event's effect is a deterministic function of serialized state.
- `FaultInjector` fails storage accesses on a schedule (`IncrementSuccessRuns` fails after one more success each run; `FailClientStartup`), with tests `InjectStartup`, `CanRecoverFromFailedStartup`, `InjectHelloCreation` and `InjectHelloCompletion` ([`FaultInjector.cs`][fault-injector], [`FaultInjectionTests.cs`][fault-tests]).
- `CheckpointInjector` lets a test decide when checkpoints and compaction happen instead of the heuristics ([`CheckpointInjector.cs`][checkpoint-injector]).
- `RecoveryTester` is a diagnostic partition manager that "recovers one or more partitions, but does not modify any files", a read-only replay of production state ([`RecoveryTester.cs`][recovery-tester]).

`PersistStepsFirst` doubles as the A/B switch: the same suite runs with and without speculation. Fault injection is at the storage boundary, not at every event index, and there is no deterministic simulation of the transport.

### 9. Journal integrity and the single writer

Netherite is the paper in this catalog that treats the log as the product, and its
integrity argument is the clearest statement of the write-ahead rule applied to a
workflow engine.

**The commit log is the single source of truth and the single writer is the partition
owner.** Each partition is an event-sourced state machine, and its state is _"a
deterministic function of the sequence of events that were processed"_. One host owns
a partition, appends to its log, and applies events; nobody else writes it.

**Applying an event is idempotent against the log position.** The state records how far
it has been updated, and an event whose position is already reflected is skipped —
which is exactly ARIES's `page_LSN` comparison, in an application-level state
machine. Recovery therefore replays the log tail from the checkpoint without needing to
know which of those events had already been applied.

**Speculation is bounded by a rule about dependencies, not by a timer.** The engine
executes ahead of the commit for latency, and _"The important bit is that the pipeline
never commits a transition that has a dependency on an uncommitted transition."_ That
is the precise condition under which running ahead of durability is safe, and it is
the sentence a library should quote when deciding whether an effect may be issued
before its intent has been flushed.

**External effects are held back until the log is durable.** Outgoing messages and
client responses are deferred until the commit confirms, so speculation is invisible
outside the partition — while user activities are not, and are re-executed
at-least-once after a crash. The asymmetry is the design: engine-owned effects get
exactly-once, user effects do not.

**Cross-partition duplicates are deduplicated by origin and position**, which is the
same epoch-and-sequence idea Restate uses, at a different granularity.

**The input queue is fingerprinted.** A change of input channel is detected by
comparing a fingerprint rather than being silently absorbed — the one instance in the
survey of validating that the record's _source_ is the one it was built from.

### 10. Operator recovery and intervention

**The paper offers nothing here, and says so by omission.** Its subject is the engine
beneath a programming model, and every operator affordance — inspecting an
orchestration, resetting one, cancelling one — belongs to the layer above. What it does
provide is the substrate those affordances would need: a totally ordered log per
partition, checkpoints that bound replay, and an idempotent apply.

**The engine's own test hooks are the nearest thing**, and they are aimed at the
implementation rather than at an operator: a replay checker that verifies the
commutative diagram after every event, fault injectors for storage and checkpoints,
and a read-only recovery tester. That is a strong internal toolkit and not an
intervention surface.

---

## Implications for a durable-execution library

- **Make the apply idempotent against the record's position.** Storing how far the
  state reflects the log turns recovery into "replay the tail" with no bookkeeping
  about which events were already applied — the same mechanism ARIES uses for pages,
  and the reason a projection should carry its offset.
- **Speculation is safe under a statable rule**, and the rule is not "wait a bit": never
  commit a transition that depends on an uncommitted one (§9). A library deciding
  whether an effect may run before its intent is durable should be able to state its
  condition that precisely, or not speculate.
- **Separate engine-owned effects from user-owned ones.** Netherite holds its own
  outgoing messages until the log commits, and lets user activities run ahead and be
  re-executed. Naming which effects get exactly-once and which get at-least-once is
  more honest than a single guarantee for both.
- **Fingerprint the record's source.** Detecting that the input channel changed, rather
  than silently absorbing it, is the only instance in the survey of validating that a
  record belongs to the world it was built from — and the analogue for a library is to
  record which target its effects were aimed at.
- **A checkpoint bounds replay and is not the truth.** The log stays authoritative and
  the checkpoint is an optimisation with its own trigger thresholds (§7), which is the
  relationship a library should keep.
- **The replay checker is the best internal test in the survey.** Asserting that
  serialising a freshly folded state equals serialising a deserialised state with the
  event applied catches divergence between the in-memory and reconstructed paths, and
  it runs on every event of an existing test suite rather than needing new fixtures.
- **Per-step storage round trips are the thing to design away.** The paper's entire
  motivation is that a step-per-round-trip engine is slow, and its answer is batching
  under one log. A library appending to a local file gets this cheaply and should not
  lose it by flushing per record without reason.
- **Compensation and versioning are deliberately out of scope here** (§4, §5), which
  is a reminder that an engine can be complete at its own level while leaving both
  unanswered for the layer above.

---

## Sources

- Burckhardt, Chandramouli, Gillum, Justo, Kallas, McMahon, Meiklejohn, Zhu. _Netherite: Efficient Execution of Serverless Workflows._ PVLDB 15(8): 1591–1604, 2022. [DOI 10.14778/3529337.3529344][doi], [VLDB PDF][vldb-pdf].
- Burckhardt, Gillum, Justo, Kallas, McMahon, Meiklejohn. _Serverless Workflows with Durable Functions and Netherite._ [arXiv 2103.00033][arxiv], February 26, 2021 (the preprint; the paper's artifact tag in the repository is `vldb-oct-2021`).
- The engine: [microsoft/durabletask-netherite][repo] at `3ae7dfbc0f4f00a1d55bacb12ae017277f1c7e7d`, files cited inline; [Engine considerations][docs-engine] on the docs site; [NuGet listing][nuget].
- FASTER, the log and key-value substrate: [microsoft/FASTER][faster].
- Sibling pages: [Azure Durable Functions][azure-df] (the application-level history replay this engine stores), [DBOS Transact][dbos] (the row-per-step contrast), and the catalog [index][index].

<!-- References -->

[doi]: https://doi.org/10.14778/3529337.3529344
[vldb-pdf]: https://www.vldb.org/pvldb/vol15/p1591-burckhardt.pdf
[arxiv]: https://arxiv.org/abs/2103.00033
[repo]: https://github.com/microsoft/durabletask-netherite
[nuget]: https://www.nuget.org/packages/Microsoft.Azure.DurableTask.Netherite
[docs-engine]: https://microsoft.github.io/durabletask-netherite/#/engine.md
[faster]: https://github.com/microsoft/FASTER
[readme]: https://github.com/microsoft/durabletask-netherite/blob/3ae7dfbc0f4f00a1d55bacb12ae017277f1c7e7d/README.md
[tok]: https://github.com/microsoft/durabletask-netherite/blob/3ae7dfbc0f4f00a1d55bacb12ae017277f1c7e7d/src/DurableTask.Netherite/Abstractions/PartitionState/TrackedObjectKey.cs
[effect-tracker]: https://github.com/microsoft/durabletask-netherite/blob/3ae7dfbc0f4f00a1d55bacb12ae017277f1c7e7d/src/DurableTask.Netherite/Abstractions/PartitionState/EffectTracker.cs
[bp]: https://github.com/microsoft/durabletask-netherite/blob/3ae7dfbc0f4f00a1d55bacb12ae017277f1c7e7d/src/DurableTask.Netherite/Events/PartitionEvents/Internal/BatchProcessed.cs
[recovery-completed]: https://github.com/microsoft/durabletask-netherite/blob/3ae7dfbc0f4f00a1d55bacb12ae017277f1c7e7d/src/DurableTask.Netherite/Events/PartitionEvents/Internal/RecoveryCompleted.cs
[pme]: https://github.com/microsoft/durabletask-netherite/blob/3ae7dfbc0f4f00a1d55bacb12ae017277f1c7e7d/src/DurableTask.Netherite/Events/PartitionEvents/External/FromPartitions/PartitionMessageEvent.cs
[event]: https://github.com/microsoft/durabletask-netherite/blob/3ae7dfbc0f4f00a1d55bacb12ae017277f1c7e7d/src/DurableTask.Netherite/Events/Event.cs
[sessions]: https://github.com/microsoft/durabletask-netherite/blob/3ae7dfbc0f4f00a1d55bacb12ae017277f1c7e7d/src/DurableTask.Netherite/PartitionState/SessionsState.cs
[history]: https://github.com/microsoft/durabletask-netherite/blob/3ae7dfbc0f4f00a1d55bacb12ae017277f1c7e7d/src/DurableTask.Netherite/PartitionState/HistoryState.cs
[outbox]: https://github.com/microsoft/durabletask-netherite/blob/3ae7dfbc0f4f00a1d55bacb12ae017277f1c7e7d/src/DurableTask.Netherite/PartitionState/OutboxState.cs
[dedup]: https://github.com/microsoft/durabletask-netherite/blob/3ae7dfbc0f4f00a1d55bacb12ae017277f1c7e7d/src/DurableTask.Netherite/PartitionState/DedupState.cs
[log-worker]: https://github.com/microsoft/durabletask-netherite/blob/3ae7dfbc0f4f00a1d55bacb12ae017277f1c7e7d/src/DurableTask.Netherite/StorageLayer/Faster/LogWorker.cs
[store-worker]: https://github.com/microsoft/durabletask-netherite/blob/3ae7dfbc0f4f00a1d55bacb12ae017277f1c7e7d/src/DurableTask.Netherite/StorageLayer/Faster/StoreWorker.cs
[partition-storage]: https://github.com/microsoft/durabletask-netherite/blob/3ae7dfbc0f4f00a1d55bacb12ae017277f1c7e7d/src/DurableTask.Netherite/StorageLayer/Faster/PartitionStorage.cs
[fasterkv]: https://github.com/microsoft/durabletask-netherite/blob/3ae7dfbc0f4f00a1d55bacb12ae017277f1c7e7d/src/DurableTask.Netherite/StorageLayer/Faster/FasterKV.cs
[replay-checker]: https://github.com/microsoft/durabletask-netherite/blob/3ae7dfbc0f4f00a1d55bacb12ae017277f1c7e7d/src/DurableTask.Netherite/StorageLayer/Faster/ReplayChecker.cs
[fault-injector]: https://github.com/microsoft/durabletask-netherite/blob/3ae7dfbc0f4f00a1d55bacb12ae017277f1c7e7d/src/DurableTask.Netherite/StorageLayer/Faster/FaultInjector.cs
[checkpoint-injector]: https://github.com/microsoft/durabletask-netherite/blob/3ae7dfbc0f4f00a1d55bacb12ae017277f1c7e7d/src/DurableTask.Netherite/StorageLayer/Faster/CheckpointInjector.cs
[settings]: https://github.com/microsoft/durabletask-netherite/blob/3ae7dfbc0f4f00a1d55bacb12ae017277f1c7e7d/src/DurableTask.Netherite/OrchestrationService/NetheriteOrchestrationServiceSettings.cs
[omb]: https://github.com/microsoft/durabletask-netherite/blob/3ae7dfbc0f4f00a1d55bacb12ae017277f1c7e7d/src/DurableTask.Netherite/OrchestrationService/OrchestrationMessageBatch.cs
[test-hooks]: https://github.com/microsoft/durabletask-netherite/blob/3ae7dfbc0f4f00a1d55bacb12ae017277f1c7e7d/src/DurableTask.Netherite/OrchestrationService/TestHooks.cs
[recovery-tester]: https://github.com/microsoft/durabletask-netherite/blob/3ae7dfbc0f4f00a1d55bacb12ae017277f1c7e7d/src/DurableTask.Netherite/TransportLayer/EventHubs/RecoveryTester.cs
[fault-tests]: https://github.com/microsoft/durabletask-netherite/blob/3ae7dfbc0f4f00a1d55bacb12ae017277f1c7e7d/test/DurableTask.Netherite.Tests/FaultInjectionTests.cs
[host-fixture]: https://github.com/microsoft/durabletask-netherite/blob/3ae7dfbc0f4f00a1d55bacb12ae017277f1c7e7d/test/DurableTask.Netherite.Tests/HostFixture.cs
[azure-df]: ./azure-durable-functions.md
[dbos]: ./dbos.md
[index]: ./index.md
