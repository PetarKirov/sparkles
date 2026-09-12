# KurrentDB / EventStoreDB (.NET)

The purpose-built event store: an append-only, chunked transaction log where every write is an event in a named stream, guarded by an expected-version check and an event-id idempotence check, exposed through one global `$all` order, catch-up and server-checkpointed subscriptions, and an in-server JavaScript projections engine.

| Field             | Value                                                                                                                                                                                |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Language          | C# / .NET                                                                                                                                                                            |
| License           | Kurrent License v1 (source-available; forbids offering it as a hosted service) for code after 24.6.x, with older parts still under the Event Store License ([`LICENSE.md`][license]) |
| Repository        | [kurrent-io/KurrentDB][repo]                                                                                                                                                         |
| Documentation     | [docs.kurrent.io][docs]                                                                                                                                                              |
| Category          | event store                                                                                                                                                                          |
| Persistence model | replay (the log is the truth; consumers fold it; snapshots are an application pattern)                                                                                               |
| Journal store     | Its own chunked transaction file (`chunk-NNNNNN.NNNNNN`, 256 MiB chunks) plus a hash index (`PTable`s) over it                                                                       |
| Latest release    | `v26.1.2`, August 11, 2026 ([releases][releases]); the clone's `src/Directory.Build.props` carries `VersionPrefix` `26.2.0` `prerelease`                                             |
| Local clone       | `$REPOS/kurrentdb` at `38fc23c5e971ee186871c03ffe94526be07c556c`                                                                                                                     |

**Last reviewed:** September 12, 2026.

---

## Overview

### What it solves

KurrentDB (renamed from EventStoreDB in 2025; the code still says `ESDB` in places such as the mutex name in [`ExclusiveDbLock.cs`][dblock]) is not a workflow engine. It is the storage half of the durable-execution problem, offered on its own: an immutable log of facts, addressed as streams, that applications fold into state. The concepts page states the contract plainly:

> _"The event log is an append-only sequence of events stored within the database. It is the ultimate source of truth, capturing every event appended to KurrentDB"_ and _"Once an event is appended, its type, body, or any part of it cannot be modified. The event remains unchanged forever."_ ([concepts][concepts])

In this catalog it is the **event-store** kind: no code is replayed by the database, so the replay-of-code dimensions of the spine translate to their event-store analogues and are analysed as such below. Step identity becomes stream identity plus event number plus event id; the journal-versus-world question becomes the expected-version check; determinism becomes the fold discipline of a projection; compensation becomes reversing events; versioning becomes upcasting; concurrency becomes the `$all` order and the multi-stream append; replay-or-snapshot becomes checkpoints and snapshot events; testing becomes an in-memory node or a container.

### Design philosophy

Three commitments shape everything:

1. **The log is a transaction file, not a table.** Writes go through a single `StorageWriterService` into `TFChunk` files; reads go through an index that maps `(stream hash, event number)` to a log position. There is one writer per database, enforced at process level by a named mutex ([`ExclusiveDbLock.cs`][dblock]) and at cluster level by leader election.
2. **Concurrency is optimistic, never locked.** The concepts page: the checks _"prevent accidental overwrites or lost updates due to race conditions"_ without _"resource locks, meaning these protections come without the performance hit of managing locks"_ ([concepts][concepts]).
3. **Everything derived is itself a stream.** Projection checkpoints, projection results, persistent-subscription checkpoints and parked messages are all ordinary events in `$`-prefixed system streams. The database has one storage primitive and uses it for its own bookkeeping.

---

## How it works

### The log: prepares, commits and positions

A write is stored as one `PrepareLogRecord` per event. The record carries the fields a consumer needs to re-identify it later ([`PrepareLogRecord.cs`][prepare]):

```csharp
// src/KurrentDB.Core/TransactionLog/LogRecords/PrepareLogRecord.cs (fields, abridged)
public long TransactionPosition { get; }
public int TransactionOffset { get; }
public long ExpectedVersion { get; }
public string EventStreamId { get; }
public Guid EventId { get; }
public Guid CorrelationId { get; }
public DateTime TimeStamp { get; }
public string EventType { get; }
public ReadOnlyMemory<byte> Data => ...;
public ReadOnlyMemory<byte> Metadata { get; }
```

`PrepareFlags` says what kind of record it is. Modern writes are `SingleWrite | IsCommitted`: the prepare is _"considered committed immediately, no commit will follow in TF"_ ([`PrepareLogRecord.cs`][prepare]). The separate `CommitLogRecord` (`TransactionPosition`, `FirstEventNumber`, `SortKey`, `CorrelationId`, `TimeStamp` in [`CommitLogRecord.cs`][commit]) survives for the legacy explicit-transaction path (`TransactionStart` / `TransactionWrite` / `TransactionCommit` under [`Services/RequestManager/Managers/`][rm-dir]).

A position in the log is a `TFPos` pair, `(CommitPosition, PreparePosition)`, rendered as 32 hex digits ([`TFPos.cs`][tfpos]). This is the coordinate of the `$all` stream and what a catch-up subscription checkpoints.

The file layout is fixed in [`TFConsts.cs`][tfconsts]: `ChunkSize = 256 * 1024 * 1024`, a 128-byte header and footer, and `MaxLogRecordSize = 16 * 1024 * 1024`. Each chunk header records a `ChunkId`, a format `Version` and `MinCompatibleVersion`, and `IsScavenged` ([`ChunkHeader.cs`][chunkhdr]).

### The write path and `ExpectedVersion`

The sentinel expected versions are in [`ExpectedVersion.cs`][ev]:

```csharp
// src/KurrentDB.Core/Data/ExpectedVersion.cs
public static class ExpectedVersion {
	public const long Any = -2;
	public const long NoStream = -1;
	public const long Invalid = -3;
	public const long StreamExists = -4;
	public const long SoftDeleted = -5;
	public const long MinValue = SoftDeleted;
}
```

Any non-negative value means "the last event number of the stream must be exactly this". The client SDK spells the same thing as `StreamState.NoStream`, `StreamState.Any`, `StreamState.StreamExists` or a `StreamRevision` ([.NET appending events][dotnet-append]):

```csharp
// docs.kurrent.io, .NET client v1.4, appending-events
var eventData = new EventData(
  Uuid.NewUuid(), "OrderPlaced", "{\"orderId\": \"123\"}"u8.ToArray()
);

await client.AppendToStreamAsync(
  "order-123",
  StreamState.NoStream,
  new List<EventData> { eventData }
);
```

Every append is decided by `IndexWriter<TStreamId>.CheckCommit` ([`IndexWriter.cs`][indexwriter]), which the writer calls once per stream in the request ([`StorageWriterService.cs`][writer]). It returns a `CommitCheckResult` whose `Decision` is one of ([`CommitDecision.cs`][decision]):

```csharp
// src/KurrentDB.Core/Services/Storage/ReaderIndex/CommitDecision.cs
public enum CommitDecision {
	Ok,
	ConsistencyCheckFailure,
	Idempotent,
	/// <summary>Some of the events in the stream are idempotent and others are not</summary>
	CorruptedIdempotency,
	InvalidTransaction,
	/// <summary>Idempotent write, but not yet indexed</summary>
	IdempotentNotReady,
}
```

The decision procedure, read from [`IndexWriter.cs`][indexwriter]:

- A hard-deleted stream (`EventNumber.DeletedStream`) rejects any append with events _"regardless of the specified expected version"_.
- `StreamExists` fails on a soft-deleted stream and on a stream with neither events nor a metadata stream.
- Otherwise: `expectedVersion > curVersion` is a `ConsistencyCheckFailure` ("writing after the end"); `expectedVersion == curVersion` is `Ok`; `expectedVersion < curVersion` enters the idempotence check below.

### The idempotence rule, precisely

The rule the docs give is short: _"If two events with the same `Uuid` are appended to the same stream in quick succession, KurrentDB will only append one of the events."_ ([.NET appending events][dotnet-append]). The code is more specific, and the distinction matters for anyone copying the rule.

There are two tiers, named in comments in [`IndexWriter.cs`][indexwriter]:

- **Strong idempotency** applies when the request names an exact expected version and that version is _behind_ the stream head. The writer walks the batch: for event `i` it expects event number `expectedVersion + 1 + i`, and the event is "already written" only if a record with that **event id** exists at that **event number** in that **stream** (checked first in the recently-committed cache `_committedEvents`, then by `_indexReader.ReadPrepare`). If every event in the batch is already there, the decision is `Idempotent`. If the first event is missing, it is an ordinary `ConsistencyCheckFailure`. If some but not all match, it is `CorruptedIdempotency`, which the writer reports as a consistency failure _"since caller will need to sync with that stream"_ ([`StorageWriterService.cs`][writer]).
- **Weak idempotency** applies when the expected version is `Any`, `StreamExists` or `SoftDeleted`. The comment is explicit about the limit: _"if the request doesn't specify what the event numbers must be, so we don't know where in the stream to look for them. check recently written events only."_ Only the in-memory `_committedEvents` cache of recent event ids is consulted. A duplicate old enough to have left that cache is appended again.

So the exact rule is: **same stream + same event id + (with an explicit expected version) same event number ⇒ no-op; with `Any`, same stream + same event id within the recent-write window ⇒ no-op.** The batch must be all-or-nothing; a partially duplicated batch is refused.

An idempotent write is not reported as a failure. The writer replies `StorageMessage.AlreadyCommitted` carrying the original `LogPosition` and first/last event numbers ([`StorageMessage.cs`][storagemsg]), and the request manager completes the client's request as a success at that position, logging `IDEMPOTENT WRITE TO STREAM` ([`RequestManagerBase.cs`][rmbase]). The client cannot tell a replayed append from a first one. One caveat: `IdempotentNotReady`, an idempotent match against a write not yet replicated to the cluster, is simply dropped with _"just drop the write and wait for the client to retry"_ ([`StorageWriterService.cs`][writer]).

### Atomicity across events and streams

A single `AppendToStreamAsync` with several `EventData` is one transaction: all prepares are written together and share a `TransactionPosition`. Since 25.1 `MultiStreamAppend` and since 26.1 `AppendRecords` extend this to several streams: _"either all writes succeed or the entire operation fails"_, and with `AppendRecords`, _"Records from different streams can be mixed, and their exact order is preserved in the global log."_ ([.NET appending events][dotnet-append]). Server-side, the `WritePrepares` handler runs `CheckCommit` for every stream in the request before writing any prepare, and a stream may be included as a **check-only** stream with no events (`HasEventsToWrite == false` in [`CommitCheckResult.cs`][checkresult]), which is how a consistency check on stream B can guard an append to stream A ([`StorageWriterService.cs`][writer]).

### Streams, `$all`, metadata and scavenging

Every event has two coordinates: `(stream, eventNumber)` and its `TFPos` in `$all`, _"a dedicated paged stream containing all events"_ ([streams][streams]). `$all` is read straight off the transaction file ([`StorageReaderWorker.All.cs`][readall]); stream reads go through the `TableIndex` / `PTable` hash index ([`PTable.cs`][ptable]).

Retention is stream metadata, itself an event in `$$stream`. The keys are `$maxCount`, `$maxAge`, `$tb` (truncate before), `$cacheControl` and `$acl` ([streams][streams]; parsed in [`StreamMetadata.cs`][streammeta]). Setting `$tb` is a soft delete; a hard delete appends a `$streamDeleted` tombstone. None of this frees bytes: _"events are...still present in the database and will be visible in reads and subscriptions to the `$all` stream. To remove these events from the database...you need to run a 'scavenge.'"_ ([scavenge][scavenge]). Scavenging _"removes events and reclaims disk space by creating a copy of the relevant chunk, minus those events, and then deleting the old chunk"_, then merges small chunks. It is driven by a `ScavengePoint` (`SP-{EventNumber}`, the position to scavenge up to, exclusive) and per-stream `DiscardPoint`s (`FirstEventNumberToKeep`) ([`ScavengePoint.cs`][scavengepoint], [`DiscardPoint.cs`][discardpoint]).

### Subscriptions and checkpoints

Two families, distinguished by who holds the position:

- **Catch-up subscriptions** are client-driven. _"A checkpoint is the position of an event in the `$all` stream to which your application has processed."_ The client stores it and resubscribes from it; positions are exclusive ([.NET subscriptions][dotnet-subs]):

  ```csharp
  // docs.kurrent.io, .NET client v1.4, subscriptions (abridged)
  var checkpoint = FromStream.Start; // or read from persistent store
  await using var subscription = client.SubscribeToStream("order-123", checkpoint);
  await foreach (var message in subscription.Messages) {
    switch (message) {
      case StreamMessage.Event(var evnt):
        checkpoint = FromStream.After(evnt.OriginalEventNumber);
        break;
    }
  }
  ```

  For filtered `$all` subscriptions the server also emits `AllStreamCheckpointReached` messages so a consumer that filters out everything still advances.

- **Persistent subscriptions** are server-driven competing consumers. _"The subscription checkpoint is maintained by the server."_ ([.NET persistent subscriptions][dotnet-psubs]). The checkpoint is a `$SubscriptionCheckpoint` event in `$persistentsubscription-{stream}::{group}-checkpoint` ([`PersistentSubscriptionCheckpointWriter.cs`][pscw]), written by `TryMarkCheckpoint` at the lowest position that has no outstanding or retrying message ahead of it ([`PersistentSubscription.cs`][psub]). Delivery is at-least-once: consumers ack or nack (`Park`, `Retry`, `Skip`), and messages exceeding the retry count go to a `-parked` stream ([server persistent subscriptions][srv-psubs]).

### The projections engine

Projections run inside the server on the leader node, in a Jint JavaScript interpreter ([`JintProjectionStateHandler.cs`][jint]). The global functions `emit` and `linkTo` are installed on the engine, and the definition DSL (`fromStream`, `fromAll`, `fromCategory`, `fromStreams`, `when`, `partitionBy`, `outputState`, `transformBy`, `filterBy`) is a state machine of which call may follow which ([`JintProjectionStateHandler.cs`][jint]). A projection is a fold: `$init` returns the seed, each handler receives `(state, event)` and mutates or returns the state ([.NET projections][dotnet-proj]):

```javascript
// docs.kurrent.io, .NET client v1.4, projections
fromAll()
  .when({
    $init: function () {
      return { count: 0 };
    },
    $any: function (s, e) {
      s.count += 1;
    },
  })
  .outputState();
```

The engine's own bookkeeping is streams: `$projections-{name}-checkpoint`, `-result`, `-state`, `-emittedstreams`, `-order`, `-partitions` ([`ProjectionNamesBuilder.cs`][projnames]). A checkpoint is a `$ProjectionCheckpoint` event ([`CoreProjectionCheckpointWriter.cs`][projckw]) whose body is a `CheckpointTag`: a `Phase`, a `TFPos` `Position` and, for stream-mode projections, a `Streams` dictionary of per-stream event numbers ([`CheckpointTag.cs`][cktag]). The docs: _"Checkpoints store how far along a projection is in the streams it is processing from. There is a performance overhead with writing a checkpoint, as it does more than append an event, and writing them too often can slow projections down."_ ([custom projections][custom-proj]). Five system projections (`$by_category` → `$ce-`, `$by_event_type` → `$et-`, `$stream_by_category`, `$by_correlation_id` → `$bc-`, `$streams`) write **link events** rather than copies ([system projections][sys-proj]).

Two rules matter for anyone modelling a UI on this: _"Streams where projections emit events cannot be used to append events from applications"_, and resetting a projection deletes its checkpoint and soft-deletes its output streams so it reprocesses from the beginning ([projections][projections], [.NET projections][dotnet-proj]).

---

## Analysis

### 1. Step identity and replay matching

There is no step: the unit is an **event**, and it has three identities. The application's `EventId` (a `Uuid` the client must generate) is the idempotence key. The `(EventStreamId, eventNumber)` pair is the position identity that an expected-version append asserts. The `TFPos` is the global identity that subscriptions checkpoint. Replay matching is the strong-idempotency walk in [`IndexWriter.cs`][indexwriter]: "is there already a record with this event id at this event number in this stream". Matching is by identity only; the event's `Data` is never compared, so a re-append with the same id and a different body is silently a no-op. That is a documented consequence of "same `Uuid`", not a bug, and it means the idempotence key must encode everything that distinguishes an attempt.

### 2. Journal versus world

The journal **is** the world, so the question becomes: what happens when a writer's belief about the stream is stale? The answer is the expected-version check, and the store always wins. A writer that read version `n`, computed, and appends with `expectedVersion = n` succeeds only if nobody else appended in between; otherwise `WrongExpectedVersion` ([`RequestManagerBase.cs`][rmbase]). There is no reconciliation rule table; the writer's job is to re-read and re-decide. Disagreement is detected by one integer comparison at commit time, which is exactly why it is cheap and why the docs can promise it without locks ([concepts][concepts]). The `$all` position of a catch-up subscription plays the same role on the read side: a consumer that checkpoints `p` and crashes resumes from `p`, and the store never advances a client-held checkpoint on its own.

### 3. Determinism enforcement

Not enforced, by design: the database stores facts and does not run application code, so it cannot police how the facts were produced. The one place it does run code, the projections engine, makes the fold deterministic by construction: a handler only sees `(state, event)`, the runtime restricts which DSL calls are legal after which ([`JintProjectionStateHandler.cs`][jint]), and the engine owns the checkpoint so that a restart re-folds from the last `$ProjectionCheckpoint` rather than from a handler's memory. Nothing stops a JavaScript handler from consulting `Date`, but there is no clock or I/O capability exposed to it beyond `emit`/`linkTo`. Outside projections, determinism between events is the application's discipline.

### 4. Compensation and failure handling

There is no compensation primitive. Failure handling is layered as (a) reject the write (`ConsistencyCheckFailure`, or refuse the whole batch on `CorruptedIdempotency`), (b) atomicity for a multi-stream append so no partial fact set is ever visible ([.NET appending events][dotnet-append]), and (c) for consumers, the persistent-subscription nack ladder: `Retry`, `Park` to a poison stream, `Skip` ([.NET persistent subscriptions][dotnet-psubs]). Undoing a fact is itself a new fact, appended by the application. Scavenging is the only thing that removes data, and only what metadata already declared dead ([scavenge][scavenge]).

### 5. Versioning against old histories

The store is neutral: an event type is a string and a body is bytes. Evolution is an application pattern documented on the Kurrent blog: _"as you load an old version of the event, you upconvert (or upcast) the old event to the new version through a small piece of code, before passing it to the projection logic."_, with the alternative that _"a parser may be a better option than upcasting. The parser would receive the raw serialised format of any version of an event and directly parse it to an in-memory structure before replaying the event."_, and, for the drastic case, _"A copy-replace is a process where we copy events from one event store to a new event store, at the same time making all the necessary changes."_ ([event immutability][blog-immut]). The chunk format has its own compatibility scheme (`Version` and `MinCompatibleVersion` in [`ChunkHeader.cs`][chunkhdr]) so old chunks stay readable by newer servers. Note the asymmetry with a replay engine: an upcaster runs on **read**, so old histories are never rewritten and the code that produced them is irrelevant.

### 6. Concurrency under replay

Concurrency is resolved at append time, not at replay time. Within one stream the expected version serializes writers; across streams there is no ordering promise except what `$all` records: with `MultiStreamAppend`, _"ordering across streams is not guaranteed"_, whereas `AppendRecords` preserves the exact interleaving in the global log ([.NET appending events][dotnet-append]). Replay of a consumer is therefore always sequential over one total order (`$all`, or one stream), and the concurrency of the original writers is invisible except through their positions. Persistent subscriptions reintroduce concurrency on the consumer side and are explicit that ordering is then a best effort: the `Pinned` strategy _"is not a guarantee, and you should handle the usual ordering and concurrency issues."_ ([.NET persistent subscriptions][dotnet-psubs]).

### 7. Replay or snapshot

Replay is the default and the only built-in mechanism for **state**; **position** is what gets snapshotted. Every consumer kind records a position (client checkpoint, `$SubscriptionCheckpoint`, `$ProjectionCheckpoint`) and replays events after it. Projection checkpoints are the exception that stores state too: a `$ProjectionCheckpoint` carries the folded state, which is why writing one _"does more than append an event"_ ([custom projections][custom-proj]). Application-level snapshots of aggregates are a documented pattern, not a feature: _"Snapshots are a way of storing the current state of an aggregate at a particular point in time, and can be used to skip over the previous events when loading the aggregate."_, kept in a separate stream with `$maxCount` so _"only one snapshot event"_ survives, with the warning that _"The need to use snapshots may hint to the model's design flaw."_ ([snapshots][blog-snap]). The cost of pure replay is the length of the stream; the cost of a snapshot is a second schema to version.

### 8. Testing

Two supported paths. In-process: `MiniNode` in [`MiniNode.cs`][mininode] boots a full `ClusterVNode` with `inMemDb = true` by default, and the server's own suites under `src/KurrentDB.Core.Tests` are written against it. The `--mem-db` option that backs it is deprecated: _"`--mem-db` has been deprecated as of version 25.1.0 and will be removed in a future version to allow us to simplify and unify some core code paths."_ ([db config][dbconfig]; `[Deprecated(...)]` on `MemDb` in [`ClusterVNodeOptions.cs`][vnodeopts]). Out-of-process: the official clients test against a container: _"Integration tests run against a server using Docker. Tests are written using TestContainers and require Docker to be installed."_ with the image chosen by `KURRENTDB_IMAGE` ([Java client][java-client]). There is no simulation of the log itself; the substrate is tested by running it.

---

## Strengths

- **Idempotence with the right key.** Event id plus stream plus position, batch-atomic, and the duplicate returns the original position as a success. This is the "re-appended attempt is a no-op" rule done properly.
- **One integer for concurrency.** Expected version is cheap, lock-free and composable across streams via check-only entries in a multi-stream append.
- **Everything derived is inspectable.** Checkpoints, projection state and parked messages are streams you can read with the same API, which makes debugging a stuck consumer a read, not a log dive.
- **A total order exists.** `$all` gives every consumer one sequence to checkpoint against, and link events let system projections re-slice it without copying.
- **Explicit retention.** Nothing is deleted except by metadata plus scavenge, and scavenge is a copy-then-swap of whole chunks.

## Weaknesses

- **Weak idempotency is a window, not a guarantee.** With `StreamState.Any` the duplicate check consults only a recent-write cache; a late retry appends twice. Callers must use an explicit expected version to get the strong rule, which is not what the docs' one-line summary suggests.
- **No compensation, no workflow.** Sagas, timeouts and retries of application steps are entirely the application's problem; the store only refuses or accepts facts.
- **Projections are a JavaScript sandbox inside the database.** Powerful for read models, but `emit` creates write amplification, projections run only on the leader, and a reset soft-deletes output streams ([projections][projections]).
- **The in-memory test mode is on its way out.** `--mem-db` is deprecated, pushing tests toward containers.
- **License.** Kurrent License v1 is source-available, not open source, for versions after 24.6.x ([`LICENSE.md`][license]).

---

## Key design decisions and trade-offs

| Decision                                                    | Rationale                                                                                   | Trade-off                                                                                        |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| Expected version instead of locks                           | Cheap, composable, no lock lifetime to manage; a stale writer just re-reads                 | Writers must be written as read-decide-append loops; no "wait for the lock"                      |
| Idempotence keyed by client-supplied event id               | Lets the client retry blindly after a timeout; duplicate returns the original position      | Body is not compared, so the id must encode the attempt; `Any` degrades to a cache window        |
| Partial-duplicate batch is refused (`CorruptedIdempotency`) | A batch is one fact set; half-applied is worse than rejected                                | A retry after a genuinely mixed batch fails and the caller must resync                           |
| `$all` as a first-class stream                              | One total order for every consumer to checkpoint against                                    | Filtered consumers need server checkpoint messages to make progress                              |
| Checkpoints are events in system streams                    | One storage primitive; checkpoints replicate and scavenge like anything else                | Checkpoint writes cost a full append (plus state for projections), so frequency is a tuning knob |
| Projections in-server, JavaScript, DSL-restricted           | Read models without an external process; handler surface is small enough to keep folds pure | Write amplification, leader-only, sandbox limits                                                 |
| Retention by metadata plus explicit scavenge                | Deletion is declared, not performed; the log stays append-only                              | Deleted data is visible in `$all` until scavenge; scavenge is a copy of whole chunks             |
| Upcasting on read, never rewriting history                  | Old chunks and old events stay byte-stable                                                  | Every reader carries every upcaster forever unless a copy-replace migration is run               |

---

## Relevance to sparkles

- **Confirms the idempotence key shape, and sharpens it.** The design's `name + attempt + args hash` corresponds to KurrentDB's `EventId` with the position acting as the attempt. KurrentDB's strong rule matches **id and position**, never the body; so `journal.jsonl` entries should be matched on key and the args hash should be treated as part of the key (a mismatch is a `CorruptedIdempotency`-style refusal), not as data to reconcile.
- **Confirms expected-version as the single-writer analogue, and shows it is a different tool from a lock file.** `ExclusiveDbLock` is the lock file (one process per database); `ExpectedVersion` is the per-append check that catches the case a lock file cannot: a second `release` run that read the same journal tail and both try to append. Appending to `journal.jsonl` with "expected length = N lines" is cheap and would make the resume path safe against a concurrent resume.
- **Argues against `Any`-style appends anywhere in the journaling combinator.** KurrentDB's weak idempotency is a cache window. If the combinator ever appends without asserting the journal's current length, a retried step can be journaled twice. Always assert.
- **Confirms "UI is a projection of the journal", with a concrete pattern for the projection's own state.** The catch-up subscription's client-held checkpoint plus `$ProjectionCheckpoint` (position **and** folded state) is the recorded-offset projection the design wants. The lesson is to checkpoint position always and state optionally, and to make the projection reset a soft-delete plus refold.
- **Argues for atomic multi-record appends in the journal.** A `started`/`completed` pair, or a step plus the compensation it registers, should land as one write or not at all, the way `MultiStreamAppend` refuses a partial batch. A line-at-a-time `.jsonl` append needs an explicit batch boundary (one line holding several records, or a terminating marker) to get this.
- **What the design lacks that KurrentDB has: link events and system projections.** `$et-` and `$ce-` streams re-slice the log by type and by category without copying. The `--split` mode's many chained releases are a category; a journal viewer that shows "all confirmation gates" or "all steps of release 3" is a link-event projection. Cheap to add once records carry a type and a category.
- **What KurrentDB lacks that the design has: compensations and reconciliation.** KurrentDB has no compensation registry and no journal-versus-world rule table, because it never observes a world. Nothing here argues against those parts of the design; the event store is the substrate under them, not a replacement.
- **Testing: the substrate is not simulated.** KurrentDB tests its log by running a real in-process node, and its clients by running a container. The design's crash-at-every-event-index tests are a layer above what any event store provides and should be kept; but the journal file itself deserves an in-process "node" (open, append with expected length, read from position) with its own tests, as `MiniNode` is to `ClusterVNode`.

---

## Sources

- Clone: `$REPOS/kurrentdb` at `38fc23c5e971ee186871c03ffe94526be07c556c` (September 9, 2026).
- [`src/KurrentDB.Core/Data/ExpectedVersion.cs`][ev]
- [`src/KurrentDB.Core/Services/Storage/ReaderIndex/IndexWriter.cs`][indexwriter]
- [`src/KurrentDB.Core/Services/Storage/ReaderIndex/CommitDecision.cs`][decision]
- [`src/KurrentDB.Core/Services/Storage/ReaderIndex/CommitCheckResult.cs`][checkresult]
- [`src/KurrentDB.Core/Services/Storage/StorageWriterService.cs`][writer]
- [`src/KurrentDB.Core/Services/RequestManager/Managers/RequestManagerBase.cs`][rmbase]
- [`src/KurrentDB.Core/Messages/StorageMessage.cs`][storagemsg]
- [`src/KurrentDB.Core/TransactionLog/LogRecords/PrepareLogRecord.cs`][prepare]
- [`src/KurrentDB.Core/TransactionLog/LogRecords/CommitLogRecord.cs`][commit]
- [`src/KurrentDB.Core/TransactionLog/Chunks/TFConsts.cs`][tfconsts]
- [`src/KurrentDB.Core/TransactionLog/Chunks/ChunkHeader.cs`][chunkhdr]
- [`src/KurrentDB.Core/TransactionLog/Scavenging/Data/ScavengePoint.cs`][scavengepoint]
- [`src/KurrentDB.Core/TransactionLog/Scavenging/Data/DiscardPoint.cs`][discardpoint]
- [`src/KurrentDB.Core/Services/PersistentSubscription/PersistentSubscription.cs`][psub]
- [`src/KurrentDB.Projections.JavaScript/Services/Interpreted/JintProjectionStateHandler.cs`][jint]
- [`src/KurrentDB.Projections.Shared/Services/Processing/ProjectionNamesBuilder.cs`][projnames]
- [`src/KurrentDB.Projections.Shared/Services/Processing/Checkpointing/CheckpointTag.cs`][cktag]
- [`src/KurrentDB.Core.Testing/Helpers/MiniNode.cs`][mininode]
- Kurrent docs: [concepts][concepts], [streams][streams], [scavenge][scavenge], [projections][projections], [custom projections][custom-proj], [system projections][sys-proj], [persistent subscriptions][srv-psubs], [database settings][dbconfig]; .NET client: [appending events][dotnet-append], [catch-up subscriptions][dotnet-subs], [persistent subscriptions][dotnet-psubs], [projections][dotnet-proj].
- Kurrent blog: [Event immutability and dealing with change][blog-immut] (Savvas Kleanthous, January 20, 2021); [Snapshots in Event Sourcing][blog-snap] (Oskar Dudycz, May 20, 2021).
- [KurrentDB Java client README][java-client] (TestContainers guidance).
- Sibling pages: [Temporal][temporal] (replay engine), [idempotence][idempotence], [write-ahead logging][wal], [catalog index][index].

<!-- References -->

[repo]: https://github.com/kurrent-io/KurrentDB
[docs]: https://docs.kurrent.io/
[releases]: https://github.com/kurrent-io/KurrentDB/releases
[license]: https://github.com/kurrent-io/KurrentDB/blob/38fc23c5e971ee186871c03ffe94526be07c556c/LICENSE.md
[dblock]: https://github.com/kurrent-io/KurrentDB/blob/38fc23c5e971ee186871c03ffe94526be07c556c/src/KurrentDB.Core/ExclusiveDbLock.cs
[ev]: https://github.com/kurrent-io/KurrentDB/blob/38fc23c5e971ee186871c03ffe94526be07c556c/src/KurrentDB.Core/Data/ExpectedVersion.cs
[indexwriter]: https://github.com/kurrent-io/KurrentDB/blob/38fc23c5e971ee186871c03ffe94526be07c556c/src/KurrentDB.Core/Services/Storage/ReaderIndex/IndexWriter.cs
[decision]: https://github.com/kurrent-io/KurrentDB/blob/38fc23c5e971ee186871c03ffe94526be07c556c/src/KurrentDB.Core/Services/Storage/ReaderIndex/CommitDecision.cs
[checkresult]: https://github.com/kurrent-io/KurrentDB/blob/38fc23c5e971ee186871c03ffe94526be07c556c/src/KurrentDB.Core/Services/Storage/ReaderIndex/CommitCheckResult.cs
[writer]: https://github.com/kurrent-io/KurrentDB/blob/38fc23c5e971ee186871c03ffe94526be07c556c/src/KurrentDB.Core/Services/Storage/StorageWriterService.cs
[readall]: https://github.com/kurrent-io/KurrentDB/blob/38fc23c5e971ee186871c03ffe94526be07c556c/src/KurrentDB.Core/Services/Storage/StorageReaderWorker.All.cs
[rm-dir]: https://github.com/kurrent-io/KurrentDB/tree/38fc23c5e971ee186871c03ffe94526be07c556c/src/KurrentDB.Core/Services/RequestManager/Managers
[rmbase]: https://github.com/kurrent-io/KurrentDB/blob/38fc23c5e971ee186871c03ffe94526be07c556c/src/KurrentDB.Core/Services/RequestManager/Managers/RequestManagerBase.cs
[storagemsg]: https://github.com/kurrent-io/KurrentDB/blob/38fc23c5e971ee186871c03ffe94526be07c556c/src/KurrentDB.Core/Messages/StorageMessage.cs
[prepare]: https://github.com/kurrent-io/KurrentDB/blob/38fc23c5e971ee186871c03ffe94526be07c556c/src/KurrentDB.Core/TransactionLog/LogRecords/PrepareLogRecord.cs
[commit]: https://github.com/kurrent-io/KurrentDB/blob/38fc23c5e971ee186871c03ffe94526be07c556c/src/KurrentDB.Core/TransactionLog/LogRecords/CommitLogRecord.cs
[tfpos]: https://github.com/kurrent-io/KurrentDB/blob/38fc23c5e971ee186871c03ffe94526be07c556c/src/KurrentDB.Core/Data/TFPos.cs
[tfconsts]: https://github.com/kurrent-io/KurrentDB/blob/38fc23c5e971ee186871c03ffe94526be07c556c/src/KurrentDB.Core/TransactionLog/Chunks/TFConsts.cs
[chunkhdr]: https://github.com/kurrent-io/KurrentDB/blob/38fc23c5e971ee186871c03ffe94526be07c556c/src/KurrentDB.Core/TransactionLog/Chunks/ChunkHeader.cs
[ptable]: https://github.com/kurrent-io/KurrentDB/blob/38fc23c5e971ee186871c03ffe94526be07c556c/src/KurrentDB.Core/Index/PTable.cs
[streammeta]: https://github.com/kurrent-io/KurrentDB/blob/38fc23c5e971ee186871c03ffe94526be07c556c/src/KurrentDB.Core/Data/StreamMetadata.cs
[scavengepoint]: https://github.com/kurrent-io/KurrentDB/blob/38fc23c5e971ee186871c03ffe94526be07c556c/src/KurrentDB.Core/TransactionLog/Scavenging/Data/ScavengePoint.cs
[discardpoint]: https://github.com/kurrent-io/KurrentDB/blob/38fc23c5e971ee186871c03ffe94526be07c556c/src/KurrentDB.Core/TransactionLog/Scavenging/Data/DiscardPoint.cs
[psub]: https://github.com/kurrent-io/KurrentDB/blob/38fc23c5e971ee186871c03ffe94526be07c556c/src/KurrentDB.Core/Services/PersistentSubscription/PersistentSubscription.cs
[pscw]: https://github.com/kurrent-io/KurrentDB/blob/38fc23c5e971ee186871c03ffe94526be07c556c/src/KurrentDB.Core/Services/PersistentSubscription/PersistentSubscriptionCheckpointWriter.cs
[jint]: https://github.com/kurrent-io/KurrentDB/blob/38fc23c5e971ee186871c03ffe94526be07c556c/src/KurrentDB.Projections.JavaScript/Services/Interpreted/JintProjectionStateHandler.cs
[projnames]: https://github.com/kurrent-io/KurrentDB/blob/38fc23c5e971ee186871c03ffe94526be07c556c/src/KurrentDB.Projections.Shared/Services/Processing/ProjectionNamesBuilder.cs
[projckw]: https://github.com/kurrent-io/KurrentDB/blob/38fc23c5e971ee186871c03ffe94526be07c556c/src/KurrentDB.Projections.V1/Services/Processing/Checkpointing/CoreProjectionCheckpointWriter.cs
[cktag]: https://github.com/kurrent-io/KurrentDB/blob/38fc23c5e971ee186871c03ffe94526be07c556c/src/KurrentDB.Projections.Shared/Services/Processing/Checkpointing/CheckpointTag.cs
[mininode]: https://github.com/kurrent-io/KurrentDB/blob/38fc23c5e971ee186871c03ffe94526be07c556c/src/KurrentDB.Core.Testing/Helpers/MiniNode.cs
[vnodeopts]: https://github.com/kurrent-io/KurrentDB/blob/38fc23c5e971ee186871c03ffe94526be07c556c/src/KurrentDB.Core/Configuration/ClusterVNodeOptions.cs
[concepts]: https://docs.kurrent.io/getting-started/concepts.html
[streams]: https://docs.kurrent.io/server/v25.1/features/streams.html
[scavenge]: https://docs.kurrent.io/server/v25.1/operations/scavenge.html
[projections]: https://docs.kurrent.io/server/latest/features/projections/
[custom-proj]: https://docs.kurrent.io/server/v26.0/features/projections/custom.html
[sys-proj]: https://docs.kurrent.io/server/latest/features/projections/system.html
[srv-psubs]: https://docs.kurrent.io/server/latest/features/persistent-subscriptions.html
[dbconfig]: https://docs.kurrent.io/server/v26.0/configuration/db-config
[dotnet-append]: https://docs.kurrent.io/clients/dotnet/v1.4/appending-events.html
[dotnet-subs]: https://docs.kurrent.io/clients/dotnet/v1.4/subscriptions.html
[dotnet-psubs]: https://docs.kurrent.io/clients/dotnet/v1.4/persistent-subscriptions.html
[dotnet-proj]: https://docs.kurrent.io/clients/dotnet/v1.4/projections.html
[blog-immut]: https://kurrentdb.kurrent.io/blog/event-immutability-and-dealing-with-change/
[blog-snap]: https://kurrentdb.kurrent.io/blog/snapshots-in-event-sourcing/
[java-client]: https://github.com/kurrent-io/KurrentDB-Client-Java
[temporal]: ./temporal.md
[idempotence]: ./idempotence.md
[wal]: ./write-ahead-logging.md
[index]: ./index.md
