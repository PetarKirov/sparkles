# Akka / Pekko Persistence (Scala / Java)

Event-sourced actors for the JVM: a command handler decides which _events_ to append, a pure event handler folds them into state, and an actor is rebuilt after a crash by replaying its own journal from the latest snapshot — the durable-execution shape realised as _state machine plus journal_ rather than as replayed code.

| Field             | Value                                                                                                                                                                                 |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | Scala (with a Java DSL); JVM                                                                                                                                                          |
| License           | Apache Pekko: Apache-2.0. Akka (since 2.7): Business Source License 1.1 with a change date of 2029-09-09 ([`LICENSE`][akka-license])                                                  |
| Repository        | [apache/pekko][repo] (the Apache fork of Akka 2.6); [akka/akka][akka-repo]                                                                                                            |
| Documentation     | [Event Sourcing][doc-es] · [Snapshotting][doc-snap] · [Schema evolution][doc-schema] · [Testing][doc-test] · [Persistence Query][doc-query] · [Durable State][doc-ds]                 |
| Category          | `event-sourced actors`                                                                                                                                                                |
| Persistence model | `explicit state machine` — replay of _events_ through a pure fold, from a snapshot; never replay of code                                                                              |
| Journal store     | Pluggable `AsyncWriteJournal` (in-memory, LevelDB in-tree; JDBC / Cassandra / R2DBC out of tree) plus a pluggable `SnapshotStore`; keyed by `persistenceId` and a per-id `sequenceNr` |
| Latest release    | Pekko `1.7.0`, tagged 2026-08-19 ([release notes][rel-17])                                                                                                                            |
| Local clone       | `$REPOS/pekko` at `ce44fbe7a1ee2697c293e355064b7dd893914bca` (2026-09-10); `$REPOS/akka` at `f24cb608fa88b650da8859d4604d46279f767cf0` (2026-09-09), consulted only for the license   |

**Last reviewed:** September 12, 2026.

---

## Overview

### What it solves

Akka Persistence, and its Apache fork Pekko Persistence, make an actor survive a crash, a restart, or a migration to another cluster node without losing state. The trick is that the actor's _state_ is never written; only the _events_ it decided to emit are, and the state is a deterministic fold over them. The typed documentation states the model plainly:

> _"An event sourced actor (also known as a persistent actor) receives a (non-persistent) command which is first validated if it can be applied to the current state. … If validation succeeds, events are generated from the command, representing the effect of the command. These events are then persisted and, after successful persistence, used to change the actor's state. When the event sourced actor needs to be recovered, only the persisted events are replayed of which we know that they can be successfully applied. In other words, events cannot fail when being replayed to a persistent actor, in contrast to commands."_ — [`docs/src/main/paradox/typed/persistence.md`][doc-es-src]

That last sentence is the whole design in miniature. A durable-execution engine such as [Temporal][temporal] replays the _program_ and hopes it takes the same branches; Pekko replays the _decisions_ (events) and folds them with a function that, by contract, cannot fail and cannot observe the world. Command handlers may be arbitrarily effectful; event handlers may not.

The same module also ships a second, non-event-sourced flavour, `DurableStateBehavior`, which stores only the latest state under an optimistic revision counter; it is covered briefly in [Replay or snapshot](#7-replay-or-snapshot) because it is the "snapshot-only" corner of the design space.

### Design philosophy

Three commitments recur through the source and the docs.

1. **Single writer per `persistenceId`.** A journal is a set of independent streams, one per id, each with a dense `sequenceNr`. Correctness rests on one actor instance appending to a stream at a time; Cluster Sharding exists largely to make that true across a cluster ([`persistence.md`][doc-es-src] § _Cluster Sharding and EventSourcedBehavior_).
2. **Side effects only after the write, and only at most once.** `thenRun` callbacks fire when the journal has acknowledged the write and are never re-run on recovery; the documented guarantee is _at-most-once_, not at-least-once (see [Compensation and failure handling](#4-compensation-and-failure-handling)).
3. **The event handler is a pure fold.** From the same page: _"The event handler must only update the state and never perform side effects, as those would also be executed during recovery of the persistent actor."_ ([`persistence.md`][doc-es-src]).

Everything that a replay-of-code engine enforces with a sandbox (no clocks, no random, no I/O inside workflow code) Pekko enforces by making the replayed thing a _data fold_ whose inputs are entirely in the journal.

---

## How it works

### The user-facing shape

An `EventSourcedBehavior` is four values: a stable id, an empty state, a command handler and an event handler ([`EventSourcedBehavior.scala`][esb]):

```scala
// persistence-typed/.../scaladsl/EventSourcedBehavior.scala
def apply[Command, Event, State](
    persistenceId: PersistenceId,
    emptyState: State,
    commandHandler: (State, Command) => Effect[Event, State],
    eventHandler: (State, Event) => State): EventSourcedBehavior[Command, Event, State]
```

The command handler returns an `Effect` directive, never performs the write itself. The factory in [`Effect.scala`][effect] offers `persist(event)`, `persist(events)` (one atomic batch), `none`, `unhandled`, `stash`, `unstashAll`, `reply`, `noReply`, and `stop`; an `EffectBuilder` chains `thenRun(State => Unit)`, `thenReply`, `thenUnstashAll`, `thenStop`. Internally every one of those is a `CompositeEffect(persistingEffect, sideEffects)` ([`EffectImpl.scala`][effectimpl]), which is what lets the runtime separate _what to append_ from _what to do afterwards_.

The docs' bank-account example ([`AccountExampleWithEventHandlersInState.scala`][account]) shows the idiom, including `withEnforcedReplies`, which turns "forgot to reply" into a compile error:

```scala
case class Deposited(amount: BigDecimal) extends Event

EventSourcedBehavior.withEnforcedReplies(persistenceId, EmptyAccount, commandHandler(accountNumber), eventHandler)

// inside the command handler
Effect.persist(Deposited(cmd.amount)).thenReply(cmd.replyTo)(_ => StatusReply.Ack)
```

Behaviour is further configured by builder methods on the returned value: `withRetention(RetentionCriteria)`, `snapshotWhen(predicate)`, `eventAdapter(EventAdapter)`, `snapshotAdapter`, `withTagger`, `withRecovery(Recovery)`, `onPersistFailure(BackoffSupervisorStrategy)`, `receiveSignal` ([`EventSourcedBehavior.scala`][esb]).

### The four-phase recovery machine

An `EventSourcedBehavior` is implemented as a chain of four internal behaviours, each documented as "N (of four)" in its header:

| Phase | File                                       | What it does                                                                                                                                                                                                                                                                                                              |
| ----- | ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1     | [`RequestingRecoveryPermit.scala`][permit] | Asks the `RecoveryPermitter` for a permit (`max-concurrent-recoveries = 50` by default in [`reference.conf`][refconf]) so a cluster restart does not stampede the journal; stashes every incoming message meanwhile                                                                                                       |
| 2     | [`ReplayingSnapshot.scala`][snapshot]      | Loads the latest snapshot matching `SnapshotSelectionCriteria`; on success `state = setup.snapshotAdapter.fromJournal(snapshot)` and the sequence number is taken from the snapshot metadata; on `LoadSnapshotFailed` it either fails recovery or, with `snapshot-is-optional = true`, restarts from `emptyState` at `0L` |
| 3     | [`ReplayingEvents.scala`][replaying]       | Sends `ReplayMessages(seqNr + 1, toSeqNr)` to the journal and folds every `ReplayedMessage(repr)` through `setup.eventAdapter.fromJournal` and then `setup.eventHandler(state.state, event)`; `RecoverySuccess(highestJournalSeqNr)` moves to phase 4                                                                     |
| 4     | [`Running.scala`][running]                 | Three sub-behaviours: `HandlingCommands`, `PersistingEvents` (commands stashed until the journal acks), `StoringSnapshot` (commands stashed until the snapshot store acks)                                                                                                                                                |

The fold in phase 3 is literally one line ([`ReplayingEvents.scala`][replaying]):

```scala
val newState = setup.eventHandler(state.state, event)
```

Any `NonFatal` exception thrown there becomes `onRecoveryFailure`, which cancels the replay, emits the `RecoveryFailed` signal, returns the permit and throws a `JournalFailureException` naming the event class and sequence number. When recovery completes, `RecoveryCompleted` is delivered with the recovered state, the internal stash is drained one message at a time by `tryUnstashOne(new running.HandlingCommands(...))`, and, if the number of replayed events already exceeds the retention threshold, a snapshot is taken first.

### The write path

`Running.HandlingCommands.onCommand` calls the user's command handler and hands the `Effect` to `applyEffects` ([`Running.scala`][running]), which unwraps `CompositeEffect`, accumulates the side effects, and dispatches on the persisting effect. For `Persist(event)`, `handleEventPersist` does something worth noticing: it applies the event handler _before_ writing, so that a validation exception in the event handler is raised before an invalid event reaches the journal.

```scala
// persistence-typed/.../internal/Running.scala (handleEventPersist, abridged)
_currentSequenceNumber = state.seqNr + 1
val stateAfterApply = state.applyEvent(setup, event)
val eventToPersist = adaptEvent(stateAfterApply.state, event)
val eventAdapterManifest = setup.eventAdapter.manifest(event)
internalPersist(setup.context, cmd, stateAfterApply, eventToPersist, eventAdapterManifest, OptionVal.None)
...
persistingEvents(newState2, state /* visible until ack */, numberOfEvents = 1, shouldSnapshotAfterPersist, shouldPublish = true, sideEffects)
```

`internalPersist` ([`ExternalInteractions.scala`][ext]) builds the journal record and sends `WriteMessages` to the journal actor:

```scala
val repr = PersistentRepr(
  event,
  persistenceId = setup.persistenceId.id,
  sequenceNr = newRunningState.seqNr,
  manifest = eventAdapterManifest,
  writerUuid = setup.writerIdentity.writerUuid,
  sender = ActorRef.noSender)
val write = AtomicWrite(repr) :: Nil
setup.journal.tell(JournalProtocol.WriteMessages(write, setup.selfClassic, setup.writerIdentity.instanceId), setup.selfClassic)
```

The actor then sits in `PersistingEvents`, whose `onMessage` stashes every `IncomingCommand`, until `WriteMessageSuccess(p, id)` arrives for its own writer `instanceId`. Only then does `onWriteResponse` set `visibleState = state`, run `applySideEffects(sideEffects, state)`, and unstash. `WriteMessageRejected` raises `EventRejectedException`; `WriteMessageFailure` emits the `JournalPersistFailed` signal and throws `JournalFailureException`, which stops the actor unless `onPersistFailure` installed a backoff supervisor.

### The journal record and the journal contract

The unit of storage is [`PersistentRepr`][persistent] — the fields are the schema, whatever the backing store:

| Field           | Meaning                                                                                                                                                 |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `persistenceId` | The stream key; `PersistenceId(entityTypeHint, entityId)` joins them with a vertical bar (`DefaultSeparator`) by default ([`PersistenceId.scala`][pid]) |
| `sequenceNr`    | Dense, per-stream, assigned by the writer (`state.seqNr + 1`)                                                                                           |
| `payload`       | The (adapted) event                                                                                                                                     |
| `manifest`      | The type hint the `EventAdapter` returned, replayed back into `fromJournal`                                                                             |
| `writerUuid`    | Identifies the actor _incarnation_ that wrote it; the replay filter uses it to detect overlapping writers                                               |
| `timestamp`     | Wall-clock at write                                                                                                                                     |
| `metadata`      | Optional; used by Replicated Event Sourcing for version vectors                                                                                         |

An [`AtomicWrite`][persistent] wraps one or more `PersistentRepr` from a single `persist` effect. The plugin contract is one method ([`AsyncWriteJournal.scala`][awj]):

```scala
def asyncWriteMessages(messages: immutable.Seq[AtomicWrite]): Future[immutable.Seq[Try[Unit]]]
```

whose doc comment fixes the semantics a store must honour: _"All `PersistentRepr` of the `AtomicWrite` must be written to the data store atomically, i.e. all or none must be stored."_ … _"The `Future` must only be completed with success when all messages in the batch have been confirmed to be stored successfully, i.e. they will be readable, and visible, in a subsequent replay. If there is uncertainty about if the messages were stored or not the `Future` must be completed with failure."_ Rejections (a serialization error, a store that cannot do multi-event atomic writes) are per-`AtomicWrite` `Try` failures and mean the event _was not_ stored; connection problems _"must not be signaled as rejections."_ Deletion never lowers the highest sequence number.

### Snapshots and retention

`RetentionCriteria.snapshotEvery(numberOfEvents, keepNSnapshots)` ([`RetentionCriteria.scala`][retention]) saves a snapshot every N events and deletes older snapshots outside the retained window; `.withDeleteEventsOnSnapshot` additionally deletes the events that the retained snapshots make redundant. The default is `RetentionCriteria.disabled`: no snapshots are ever taken unless asked. `snapshotWhen((state, event, seqNr) => Boolean)` takes ad-hoc snapshots but never triggers deletion. In `Running.StoringSnapshot`, `SaveSnapshotSuccess` drives the delete of old events _before_ old snapshots, so that at no point does a surviving snapshot depend on deleted events ([`Running.scala`][running]; [Snapshotting][doc-snap]).

### Projections

`persistence-query` exposes read-side streams over the same journal. `EventsByPersistenceIdQuery.eventsByPersistenceId(persistenceId, fromSequenceNr, toSequenceNr)` returns a live `Source[EventEnvelope, NotUsed]` ordered by sequence number that _"is not completed when it reaches the end of the currently stored events, but it continues to push new events when new events are persisted"_ ([`EventsByPersistenceIdQuery.scala`][query-src]). The docs describe it as _"a query equivalent to replaying an event sourced actor"_ ([Persistence Query][doc-query]) and point resumable projections (store the processed offset, resume from it) to the separate Pekko Projections module.

---

## Analysis

The eight questions below were written for replay-of-code engines. Where a question is about "replaying code", this page translates it to the event-sourcing analogue and says so.

### 1. Step identity and replay matching

_Analogue: how is a persisted event identified, and how is it matched on recovery?_

By position, not by name. Every event carries `(persistenceId, sequenceNr)`; the writer assigns `sequenceNr = state.seqNr + 1` in `internalPersist` ([`ExternalInteractions.scala`][ext]) and recovery asks the journal for the contiguous range `seqNr + 1 .. toSeqNr` ([`ReplayingEvents.scala`][replaying]). There is no step name, no args hash and no attempt counter, because there is nothing to _match against_: the replayed thing is the event stream itself, and the consumer of it, the event handler, has no other input. The `manifest` string is the only "identity" a payload carries, and it identifies the event's _schema_ for the adapter, not its position in a program.

The one matching problem that does exist is _writer_ identity: a `writerUuid` per incarnation lets the [`ReplayFilter`][replayfilter] _"detect corrupt event stream during replay … to find events emitted by overlapping writers"_. That is the event-sourcing form of the "two runs journaled into one file" hazard.

### 2. Journal versus world

_Analogue: when the journal and the world disagree, which wins?_

The journal wins, unconditionally, and the design makes disagreement structurally impossible to _detect_ during recovery: the event handler may not observe the world (no I/O, no clock), so there is no code path in phases 2 to 3 in which world and journal could be compared. Recovery is a fold over stored facts, and the docs guarantee that _"events cannot fail when being replayed"_ ([`persistence.md`][doc-es-src]).

Where the world does re-enter is _after_ recovery, in the `RecoveryCompleted` signal handler, and the docs are explicit that this is where one reconciles unacknowledged side effects: _"You may inspect the state when receiving the `RecoveryCompleted` signal and execute side effects that have not been acknowledged at that point. That may possibly result in executing side effects more than once."_ ([`persistence.md`][doc-es-src] § _Side effects ordering and guarantees_). The runtime offers no rule table and no re-observation: the application encodes "what was started but not confirmed" _in the state_ and decides.

The journal-vs-_journal_ case is handled: `replay-filter.mode` (`repair-by-discard-old` / `fail` / `warn` / `off`) says what to do when two writers produced the same sequence number ([`ReplayFilter.scala`][replayfilter]; [`persistence.md`][doc-es-src] § _Replay filter_). And snapshot-vs-journal has a documented policy: with `snapshot-is-optional = true` a snapshot that fails to load is discarded and the full event stream is authoritative ([Snapshotting][doc-snap] § _Optional snapshots_), with the caveat that this is unsafe if events were deleted.

### 3. Determinism enforcement

_Analogue: command handler determinism, event handler purity._

**By discipline, documented as a hard rule, with the type signature doing the only mechanical work.** The event handler's type is `(State, Event) => State` ([`EventSourcedBehavior.scala`][esb]); nothing stops a Scala function of that type from reading a clock, and the runtime does not sandbox it. The docs state the rule and the reason:

> _"The same event handler is also used when the entity is started up to recover its state from the stored events. The event handler must only update the state and never perform side effects, as those would also be executed during recovery of the persistent actor. Side effects should be performed in `thenRun` from the command handler after persisting the event or from the `RecoveryCompleted` after Recovery."_ — [`persistence.md`][doc-es-src]

The **command handler**, by contrast, is _not_ required to be deterministic. It runs once, on the live path, and is explicitly allowed to do _"a conversation with several external services"_ ([`persistence.md`][doc-es-src]). Its decision is captured as an event; nothing about the decision is ever recomputed. This is the cleanest split in the survey: the nondeterministic part is never replayed, and the replayed part is a fold with no ambient access.

Two mechanical aids exist. `withEnforcedReplies` makes the compiler reject a command handler that forgets to reply. And `handleEventPersist` applies the event handler _before_ the write ([`Running.scala`][running]), so an event that the handler cannot fold never enters the journal — a cheap invariant check that a replay-of-code engine cannot offer, because there the "handler" is the rest of the program.

### 4. Compensation and failure handling

**There is no compensation primitive.** The docs for `persistence-typed` never mention sagas or compensation; the word does not occur in `docs/src/main/paradox/typed/persistence*.md`. A saga is written as an ordinary event-sourced entity (or a process manager) whose state records which steps are done and whose command handler emits `StepCompensated` events. Ordering and triggering are therefore whatever the application's state machine says.

What the runtime _does_ define is the side-effect guarantee, and it is weaker than the brief expected:

> _"Any side effects are executed on an at-most-once basis and will not be executed if the persist fails. Side effects are not run when the actor is restarted or started again after being stopped."_ — [`persistence.md`][doc-es-src]

The mechanism is in `Running.PersistingEvents.onWriteResponse` ([`Running.scala`][running]): the accumulated `sideEffects` list is applied only after the journal's `WriteMessageSuccess` for the last event of the batch, and the list lives in actor memory, so a crash between ack and callback loses it. The at-least-once story is _opt-in_ by the application: persist a "started" fact, run the effect in `thenRun`, persist a "confirmed" fact on the reply, and re-drive the unconfirmed ones from `RecoveryCompleted`. That is exactly the `started`/`completed` pair, but Pekko leaves it to the user to write.

Failure of the _write_ has a sharp policy: `WriteMessageFailure` throws `JournalFailureException` and the default is to stop the actor; `onPersistFailure` accepts only a `BackoffSupervisorStrategy` because, as the API doc says, _"Resume is not allowed as it will be unknown if the event has been persisted"_ ([`EventSourcedBehavior.scala`][esb]). Rejections (`EventRejectedException`) are distinct: the event is known _not_ to be stored, so the actor may continue.

Atomicity is the other lever: `Effect.persist(events)` becomes a single `AtomicWrite`, so _"the recovery of a persistent actor will therefore never be done partially with only a subset of events persisted by a single `persist` effect"_ ([`persistence.md`][doc-es-src] § _Atomic writes_).

### 5. Versioning against old histories

_Analogue: schema evolution of events._

This is where the design is richest, and it is the dimension the sparkles design has least. The premise is stated up front:

> _"Since events are never deleted, we need to have a way to be able to replay (read) old events, in such way that does not force the `PersistentActor` to be aware of all possible versions of an event that it may have persisted in the past. Instead, we want the Actors to work on some form of 'latest' version of the event and provide some means of either converting old 'versions' of stored events into this 'latest' event type, or constantly evolve the event definition - in a backwards compatible way - such that the new deserialization code can still read old events."_ — [`persistence-schema-evolution.md`][doc-schema-src]

The page then catalogues the four common changes — add a field, rename or remove a field, remove an event type, split one event into several — with a pattern for each, and it is careful to say that the serializer (protobuf, Jackson with its own schema-evolution support, Avro) carries most of the load, with Java serialization explicitly disrecommended for anything that must persist.

The runtime hook is [`EventAdapter[E, P]`][adapter]: `toJournal(e): P` (declared _"must be an 1-to-1 transformation. It is not allowed to drop incoming events"_), `manifest(event): String`, and `fromJournal(p, manifest): EventSeq[E]`, which _"may be adapted into multiple (or none) events"_. The adapter's own docs list its uses: envelope extraction, domain-to-data-model mapping, _"migration by splitting up events into sequences of other events"_ and _"migration filtering out unused events, or replacing an event with another"_. Because the manifest is stored beside the payload, an adapter can upcast by version tag. The schema-evolution page adds the "tombstone" refinement: a `SerializerWithStringManifest` can recognise a retired manifest and return a placeholder _without deserializing_, so the old class can be deleted from the codebase.

Two limits are stated in the source. `fromJournal` _"is not called in any read side so will need to be applied manually when using Query"_ ([`EventAdapter.scala`][adapter]), so projections must repeat the adaptation. And snapshots have their own, coarser story: a `SnapshotAdapter`, or simply `SnapshotSelectionCriteria.None` to _"replay all journaled events … if snapshot serialization format has changed in an incompatible way"_ ([Snapshotting][doc-snap]).

What is _absent_ is any versioning of the _handlers_: there is no `getVersion`/`patched` marker as in Temporal or Azure Durable Functions, because nothing about the handlers is journaled. Changing the event handler silently changes what every old stream folds to; the only guard is the fact that the fold is pure and therefore testable against a recorded stream.

### 6. Concurrency under replay

_Analogue: one actor is one writer; what happens to concurrent inputs during recovery and during a write?_

Concurrency is excluded rather than replayed. Within one `persistenceId`:

- During all three pre-`Running` phases, every `IncomingCommand` goes to the internal stash (`stashInternal`) ([`ReplayingSnapshot.scala`][snapshot], [`ReplayingEvents.scala`][replaying]); the docs: _"New messages sent to the actor during recovery do not interfere with replayed events. They are stashed and received by the `EventSourcedBehavior` after the recovery phase completes."_ ([`persistence.md`][doc-es-src]).
- During a write, `PersistingEvents.onCommand` stashes; during a snapshot, `StoringSnapshot.onCommand` stashes ([`Running.scala`][running]). Exactly one `WriteMessages` is outstanding per actor at any time; the journal doc relies on it: _"A PersistentActor will not send a new WriteMessages request before the previous one has been completed."_ ([`AsyncWriteJournal.scala`][awj]).
- The stash is bounded (`stash-capacity = 4096`, [`reference.conf`][refconf-typed]) with a `Drop` or `Fail` overflow strategy ([`StashManagement.scala`][stash]), and the user-level `Effect.stash` buffer is _"kept in an in-memory buffer, so in case of a crash they will not be processed"_ ([`Effect.scala`][effect]).

Across nodes, the single-writer rule is delegated to Cluster Sharding: _"Pekko Persistence is based on the single-writer principle, for a particular `PersistenceId` only one persistent actor instance should be active at one time. … Cluster Sharding ensures that there is only one active entity for each id."_ ([`persistence.md`][doc-es-src]). When that invariant is nonetheless broken, the `ReplayFilter` is the after-the-fact repair.

Recovery itself is throttled cluster-wide by the permit (`max-concurrent-recoveries`), and the journal paces one actor's replay with `replay-batch-size` and `ReplayBatchAck` ([`ReplayingEvents.scala`][replaying]). Replicated Event Sourcing (multi-writer with version vectors, the `metadata` field) is the deliberate exception and is out of scope here.

### 7. Replay or snapshot

Both, layered, and the choice is a retention policy rather than an architecture. Recovery always starts from the latest snapshot (if any) and replays only the tail; with `RetentionCriteria.disabled` (the default) that means full replay forever. `snapshotEvery(N, keepN)` bounds replay to at most about N events plus the retained window; adding `withDeleteEventsOnSnapshot` turns the journal into a rolling window and gives up the audit history and the ability to rebuild after a bad snapshot ([`RetentionCriteria.scala`][retention]; [Snapshotting][doc-snap]). Snapshot cost is paid on the write path: the actor sits in `StoringSnapshot` and stashes commands until the store acks, which is why _"the state can safely be mutable although the serialization and storage of the state is performed asynchronously"_ ([Snapshotting][doc-snap]).

`DurableStateBehavior` is the pure-snapshot pole: _"only the latest state is stored, we don't have access to any of the history of changes"_; its `persist` _"will be updated only if the revision number of the incoming record is 1 more than the already existing record. Otherwise `persist` will fail"_ ([Durable State][doc-ds]). That is the compare-and-set version of single-writer, and it rules out projections over history and any after-the-fact reinterpretation.

### 8. Testing

Two kits, both in `persistence-testkit`, both against an in-memory journal ([`PersistenceTestKitPlugin.scala`][tk-plugin]).

[`EventSourcedBehaviorTestKit`][tk-esb] drives a _real_ actor one command at a time and returns a synchronous `CommandResult` with `events`, `event`, `state`, `stateOfType`, and, for `runCommand[R](replyTo => cmd)`, the `reply` ([`AccountExampleDocSpec.scala`][account-spec]):

```scala
val result = eventSourcedTestKit.runCommand[StatusReply[Done]](AccountEntity.CreateAccount(_))
result.reply shouldBe StatusReply.Ack
result.event shouldBe AccountEntity.AccountCreated
result.stateOfType[AccountEntity.OpenedAccount].balance shouldBe 0
```

It also verifies, by default, that every command, event and state survives a serialization round trip (`SerializationSettings`), and `restart()` re-runs the whole four-phase recovery against what the test persisted: _"It will restart the behavior, which will then recover from stored snapshot and events from previous commands."_ ([Testing][doc-test]). `initialize(state, events*)` seeds the storage so a test can start from a hand-written history.

[`PersistenceTestKit`][tk-ptk] is the fault injector: `expectNextPersisted`, `expectNothingPersisted`, `persistedInStorage(persistenceId)`, `persistForRecovery`, and the failure knobs `failNextPersisted`, `failNextNPersisted`, `rejectNextPersisted`, `failNextRead`, plus a user-supplied `ProcessingPolicy` for arbitrary per-operation decisions ([`ProcessingPolicy.scala`][tk-policy]). Together they cover "crash the write at event _k_" and "the store rejects this event" without touching a real database.

What is missing relative to the sparkles test plan: there is no built-in "crash at every event index and resume" driver (it is a short loop over `failNextNPersisted` + `restart`), and no notion of mutating the world between crash and resume, because the runtime has no world-observation step to mutate around.

---

## Strengths

- **The cleanest determinism boundary in the survey.** Nondeterminism lives in the command handler, which runs once; the replayed fold has no inputs but state and event. No sandbox, no forbidden-API list, no "deterministic time" shim.
- **Journal semantics are a written contract for plugin authors** — atomic batches, "uncertain means failed", rejection vs failure, never-decreasing highest sequence number ([`AsyncWriteJournal.scala`][awj]).
- **Schema evolution is a first-class topic** with a stored manifest, an adapter that can split, drop or upcast, and a long documented playbook ([`persistence-schema-evolution.md`][doc-schema-src]).
- **Fold-before-write** catches un-foldable events before they are stored ([`Running.scala`][running]).
- **Projections are the same stream** the actor recovers from, ordered by the same sequence number ([`EventsByPersistenceIdQuery.scala`][query-src]).
- **Testing is honest**: the test kit runs the real recovery machine, and the storage plugin is a fault injector.

## Weaknesses

- **At-most-once side effects, and the at-least-once discipline is homework.** The started/completed pattern is neither a primitive nor a documented recipe beyond one paragraph.
- **No compensation model at all.** Sagas are entirely application code.
- **Handler evolution is invisible.** Only events have versions; a changed event handler re-derives every old state with no marker and no check.
- **Purity is by contract.** The `(State, Event) => State` type is the only enforcement.
- **Command-during-recovery is stash-or-drop**, and both stashes are memory-only; a bounded buffer with `Drop` silently loses commands under load.
- **The single-writer guarantee is outsourced** to Cluster Sharding; without it, the `ReplayFilter` can only repair after the fact.
- **`fromJournal` does not run on the read side**, so projections re-implement adaptation.

---

## Key design decisions and trade-offs

| Decision                                               | Rationale                                                                                | Trade-off                                                                                                  |
| ------------------------------------------------------ | ---------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Journal _events_, not state or code                    | Events cannot fail on replay; nondeterminism is confined to the once-run command handler | The application must design an event vocabulary; every state change is a schema decision                   |
| Pure fold `(State, Event) => State`                    | Recovery is a deterministic function of the stream; no sandbox needed                    | Purity is unenforced; a stray side effect fires on every recovery                                          |
| Side effects after ack, at-most-once, in memory        | Never act on an unpersisted decision; keep the runtime simple                            | At-least-once must be encoded in state by the user; crash between ack and callback loses the callback      |
| One outstanding `WriteMessages`, stash everything else | Dense sequence numbers, ordered stream, journal writes serialized per id                 | Throughput per entity bounded by journal latency; stash is bounded and memory-only                         |
| Dense per-id `sequenceNr` + `writerUuid`               | Cheap contiguity checks; overlapping writers are detectable                              | Detection is post hoc; the real guard (sharding) is a separate module                                      |
| `AtomicWrite` per `persist` effect                     | Multi-event decisions are all-or-nothing                                                 | Journals that cannot batch reject them; the actor must handle `EventRejectedException`                     |
| Snapshot = optimisation, retention = policy            | Full-replay semantics by default; bound recovery only when asked                         | Snapshot save stalls the actor; event deletion trades history for space and forbids `snapshot-is-optional` |
| `EventAdapter` + stored manifest                       | Old events are upcast at the boundary; the fold sees only the latest shape               | Not applied on the query side; snapshots need their own adapter                                            |
| `onPersistFailure` allows backoff but never resume     | After a failed write it is unknown whether the event was stored                          | The actor restarts and replays; a slow journal turns into restart storms without careful backoff tuning    |
| Sagas out of scope                                     | Keep the entity model minimal; process managers are entities too                         | Every compensation order and trigger is application-specific code                                          |

---

## Relevance to sparkles

- **Confirms the journal + snapshot + projection triad** as three views of one append-only stream keyed by a dense sequence number. Pekko's `eventsByPersistenceId` is the literal "UI as projection of the journal": same records, same order, live tail. The design should make `journal.jsonl` readable by a projection without the workflow's cooperation, exactly as the read journal is a plugin over the write journal.
- **Argues against "side effects are at-least-once by default".** Pekko documents _at-most-once_ for `thenRun` and pushes at-least-once into the state. The `started`/`completed` pair the sparkles design journals is the right answer, but Pekko shows the failure mode it must cover: the crash between "journal acked `completed`" and "the callback that used it", which is why the reconciler on resume must be driven from the journal, not from in-memory continuations.
- **Argues for splitting decisions from observations at the type level, not the naming level.** Pekko's whole determinism story is that the command handler (may observe the world, runs once) and the event handler (may not, runs on every recovery) have different _types_. The sparkles design's "decisions replay verbatim; observations are re-observed" is the same split expressed as a rule table over ops. Consider making it two op kinds in the capability row rather than two rows in a table.
- **Adopt fold-before-write.** Pekko applies the event handler before persisting so an event the state cannot absorb never hits the journal. The sparkles journaling combinator should apply the `completed` record to the in-memory workflow state _before_ appending it, for the same reason.
- **What it does that the design lacks: event adapters with a stored manifest.** The design has no versioning tool at all. Pekko's minimal, proven answer is a `manifest` string on every record plus an upcasting `fromJournal(payload, manifest): EventSeq` at the read boundary, so old journals are promoted to the current shape before the workflow sees them. That is cheaper than Temporal-style `patched` markers and fits a JSONL journal directly: put a `manifest` (or `v`) on every line and give the reader an adapter.
- **What the design lacks and Pekko also lacks: compensation.** Neither has a runtime primitive; Pekko's honest position is that a saga is an entity whose state is the saga's progress. The sparkles LIFO scope registration is more than Pekko offers, but its compensations must themselves be journaled events (started/completed) or they inherit Pekko's at-most-once hole.
- **The replay filter is worth copying as a check.** A `writerUuid` per run plus contiguous sequence numbers lets a resumed `release` detect that another run wrote into the same journal, and choose `fail` rather than silently interleaving. The design keys steps by name and attempt; add a run id per line.
- **Testing shape to copy**: a test kit that runs the _real_ recovery path (`restart()`), a storage double that can fail or reject the _next_ write, and seeding the journal by hand (`initialize`, `persistForRecovery`) so "crash at every event index" is a loop, not a bespoke harness.

---

## Sources

- Pekko source at `ce44fbe7a1ee2697c293e355064b7dd893914bca`: [`EventSourcedBehavior.scala`][esb], [`Effect.scala`][effect], [`EffectImpl.scala`][effectimpl], [`RequestingRecoveryPermit.scala`][permit], [`ReplayingSnapshot.scala`][snapshot], [`ReplayingEvents.scala`][replaying], [`Running.scala`][running], [`ExternalInteractions.scala`][ext], [`StashManagement.scala`][stash], [`RetentionCriteria.scala`][retention], [`EventAdapter.scala`][adapter], [`PersistenceId.scala`][pid], [`AsyncWriteJournal.scala`][awj], [`Persistent.scala`][persistent], [`ReplayFilter.scala`][replayfilter], [`EventsByPersistenceIdQuery.scala`][query-src], [`EventSourcedBehaviorTestKit.scala`][tk-esb], [`PersistenceTestKit.scala`][tk-ptk], [`PersistenceTestKitPlugin.scala`][tk-plugin], [`ProcessingPolicy.scala`][tk-policy], [`reference.conf` (persistence)][refconf], [`reference.conf` (persistence-typed)][refconf-typed], [`AccountExampleWithEventHandlersInState.scala`][account], [`AccountExampleDocSpec.scala`][account-spec]
- Pekko documentation sources in the same tree: [`typed/persistence.md`][doc-es-src], [`persistence-schema-evolution.md`][doc-schema-src]
- Official docs (Pekko 1.7.0): [Event Sourcing][doc-es], [Snapshotting][doc-snap], [Schema Evolution][doc-schema], [Testing][doc-test], [Persistence Query][doc-query], [Durable State][doc-ds], [Release notes 1.7][rel-17]
- Akka license at `f24cb608fa88b650da8859d4604d46279f767cf0`: [`LICENSE`][akka-license]
- Sibling pages: [Temporal][temporal], [this catalog's index][index]

<!-- References -->

[repo]: https://github.com/apache/pekko
[akka-repo]: https://github.com/akka/akka
[akka-license]: https://github.com/akka/akka/blob/f24cb608fa88b650da8859d4604d46279f767cf0/LICENSE
[rel-17]: https://pekko.apache.org/docs/pekko/current/release-notes/releases-1.7.html
[doc-es]: https://pekko.apache.org/docs/pekko/current/typed/persistence.html
[doc-snap]: https://pekko.apache.org/docs/pekko/current/typed/persistence-snapshot.html
[doc-schema]: https://pekko.apache.org/docs/pekko/current/persistence-schema-evolution.html
[doc-test]: https://pekko.apache.org/docs/pekko/current/typed/persistence-testing.html
[doc-query]: https://pekko.apache.org/docs/pekko/current/persistence-query.html
[doc-ds]: https://pekko.apache.org/docs/pekko/current/typed/durable-state/persistence.html
[doc-es-src]: https://github.com/apache/pekko/blob/ce44fbe7a1ee2697c293e355064b7dd893914bca/docs/src/main/paradox/typed/persistence.md
[doc-schema-src]: https://github.com/apache/pekko/blob/ce44fbe7a1ee2697c293e355064b7dd893914bca/docs/src/main/paradox/persistence-schema-evolution.md
[esb]: https://github.com/apache/pekko/blob/ce44fbe7a1ee2697c293e355064b7dd893914bca/persistence-typed/src/main/scala/org/apache/pekko/persistence/typed/scaladsl/EventSourcedBehavior.scala
[effect]: https://github.com/apache/pekko/blob/ce44fbe7a1ee2697c293e355064b7dd893914bca/persistence-typed/src/main/scala/org/apache/pekko/persistence/typed/scaladsl/Effect.scala
[effectimpl]: https://github.com/apache/pekko/blob/ce44fbe7a1ee2697c293e355064b7dd893914bca/persistence-typed/src/main/scala/org/apache/pekko/persistence/typed/internal/EffectImpl.scala
[permit]: https://github.com/apache/pekko/blob/ce44fbe7a1ee2697c293e355064b7dd893914bca/persistence-typed/src/main/scala/org/apache/pekko/persistence/typed/internal/RequestingRecoveryPermit.scala
[snapshot]: https://github.com/apache/pekko/blob/ce44fbe7a1ee2697c293e355064b7dd893914bca/persistence-typed/src/main/scala/org/apache/pekko/persistence/typed/internal/ReplayingSnapshot.scala
[replaying]: https://github.com/apache/pekko/blob/ce44fbe7a1ee2697c293e355064b7dd893914bca/persistence-typed/src/main/scala/org/apache/pekko/persistence/typed/internal/ReplayingEvents.scala
[running]: https://github.com/apache/pekko/blob/ce44fbe7a1ee2697c293e355064b7dd893914bca/persistence-typed/src/main/scala/org/apache/pekko/persistence/typed/internal/Running.scala
[ext]: https://github.com/apache/pekko/blob/ce44fbe7a1ee2697c293e355064b7dd893914bca/persistence-typed/src/main/scala/org/apache/pekko/persistence/typed/internal/ExternalInteractions.scala
[stash]: https://github.com/apache/pekko/blob/ce44fbe7a1ee2697c293e355064b7dd893914bca/persistence-typed/src/main/scala/org/apache/pekko/persistence/typed/internal/StashManagement.scala
[retention]: https://github.com/apache/pekko/blob/ce44fbe7a1ee2697c293e355064b7dd893914bca/persistence-typed/src/main/scala/org/apache/pekko/persistence/typed/scaladsl/RetentionCriteria.scala
[adapter]: https://github.com/apache/pekko/blob/ce44fbe7a1ee2697c293e355064b7dd893914bca/persistence-typed/src/main/scala/org/apache/pekko/persistence/typed/EventAdapter.scala
[pid]: https://github.com/apache/pekko/blob/ce44fbe7a1ee2697c293e355064b7dd893914bca/persistence-typed/src/main/scala/org/apache/pekko/persistence/typed/PersistenceId.scala
[awj]: https://github.com/apache/pekko/blob/ce44fbe7a1ee2697c293e355064b7dd893914bca/persistence/src/main/scala/org/apache/pekko/persistence/journal/AsyncWriteJournal.scala
[persistent]: https://github.com/apache/pekko/blob/ce44fbe7a1ee2697c293e355064b7dd893914bca/persistence/src/main/scala/org/apache/pekko/persistence/Persistent.scala
[replayfilter]: https://github.com/apache/pekko/blob/ce44fbe7a1ee2697c293e355064b7dd893914bca/persistence/src/main/scala/org/apache/pekko/persistence/journal/ReplayFilter.scala
[query-src]: https://github.com/apache/pekko/blob/ce44fbe7a1ee2697c293e355064b7dd893914bca/persistence-query/src/main/scala/org/apache/pekko/persistence/query/scaladsl/EventsByPersistenceIdQuery.scala
[tk-esb]: https://github.com/apache/pekko/blob/ce44fbe7a1ee2697c293e355064b7dd893914bca/persistence-testkit/src/main/scala/org/apache/pekko/persistence/testkit/scaladsl/EventSourcedBehaviorTestKit.scala
[tk-ptk]: https://github.com/apache/pekko/blob/ce44fbe7a1ee2697c293e355064b7dd893914bca/persistence-testkit/src/main/scala/org/apache/pekko/persistence/testkit/scaladsl/PersistenceTestKit.scala
[tk-plugin]: https://github.com/apache/pekko/blob/ce44fbe7a1ee2697c293e355064b7dd893914bca/persistence-testkit/src/main/scala/org/apache/pekko/persistence/testkit/PersistenceTestKitPlugin.scala
[tk-policy]: https://github.com/apache/pekko/blob/ce44fbe7a1ee2697c293e355064b7dd893914bca/persistence-testkit/src/main/scala/org/apache/pekko/persistence/testkit/ProcessingPolicy.scala
[refconf]: https://github.com/apache/pekko/blob/ce44fbe7a1ee2697c293e355064b7dd893914bca/persistence/src/main/resources/reference.conf
[refconf-typed]: https://github.com/apache/pekko/blob/ce44fbe7a1ee2697c293e355064b7dd893914bca/persistence-typed/src/main/resources/reference.conf
[account]: https://github.com/apache/pekko/blob/ce44fbe7a1ee2697c293e355064b7dd893914bca/cluster-sharding-typed/src/test/scala/docs/org/apache/pekko/cluster/sharding/typed/AccountExampleWithEventHandlersInState.scala
[account-spec]: https://github.com/apache/pekko/blob/ce44fbe7a1ee2697c293e355064b7dd893914bca/cluster-sharding-typed/src/test/scala/docs/org/apache/pekko/cluster/sharding/typed/AccountExampleDocSpec.scala
[temporal]: ./temporal.md
[index]: ./index.md
