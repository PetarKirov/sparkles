# Marten (.NET / PostgreSQL)

An event store and document database for .NET that lives entirely inside PostgreSQL: two tables hold every event and every stream, projections fold those events into documents either in the writing transaction or in a background daemon whose only checkpoint is another table in the same database, and Wolverine supplies the durable-messaging half (outbox, sagas) on the same transaction.

| Field             | Value                                                                                                                                |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Language          | C# (.NET), with an F# helper surface                                                                                                 |
| License           | MIT ([`LICENSE`][license])                                                                                                           |
| Repository        | [JasperFx/marten][repo]                                                                                                              |
| Documentation     | [martendb.io/events][docs] · [Wolverine event-sourcing workflow][wolverine-es]                                                       |
| Category          | event store                                                                                                                          |
| Persistence model | replay (live and inline folds over the stream) with optional snapshot (inline/async projection documents, `Compacted<T>` compaction) |
| Journal store     | PostgreSQL tables `mt_events` / `mt_streams`; projection checkpoints in `mt_event_progression`                                       |
| Latest release    | `9.33.0` (September 9, 2026; [`Directory.Build.props`][buildprops] at the reviewed commit carries the same version)                  |
| Local clone       | `$REPOS/marten` at `1850d2d4575af3c8d36acdb9d822794ee644e028`                                                                        |

**Last reviewed:** September 12, 2026.

Marten is not a durable-execution engine: it does not replay _code_. It replays _events_ through fold functions. This page therefore translates the spine's replay-of-code dimensions into their event-sourcing analogues and says so at each step: a "journaled step" becomes an appended event, "replay matching" becomes the stream version check, "the workflow function" becomes the decider that turns a command plus an aggregate into new events, and "the world" is the same database the journal lives in.

---

## Overview

### What it solves

An event-sourced .NET application needs three things a plain relational schema does not give it: an append-only log of immutable facts per entity, a concurrency guard so two writers cannot both extend the same entity from the same starting state, and a way to turn the log back into queryable state. Marten answers all three with PostgreSQL alone. The docs' projections page frames the log as the system of record ([`docs/events/projections/index.md`][doc-proj-index]):

> _"So you've made the decision to use all the power of Event Sourcing to capture all the state changes in your system as first class events and that's now your system of record."_

Read models are then derived, and the page names three lifecycles for that derivation: `Live` (fold on read), `Inline` (fold inside the writing transaction) and `Async` (fold in a background daemon with eventual consistency). Because the events and the documents are in one database, an inline projection and the events it derives from commit atomically. That is the property the rest of this page keeps returning to.

### Design philosophy

The docs are explicit that the write side should be a pure decision function. The command-handler page warns, in the section on the identity-map optimization ([`docs/scenarios/command_handler_workflow.md`][doc-chw]):

> _"This optimization assumes the **decider pattern**: your handler returns events, the inline projection rebuilds aggregate state from those events on save, and you do \_not_ mutate fields on the `stream.Aggregate` instance returned by `FetchForWriting()`."\_

Wolverine's aggregate-handler documentation says the same from the other side: _"it would be best to completely isolate your business logic that decides what new events should be appended completely away from the infrastructure code so that you can more easily reason about that code and easily test that business logic"_ ([Wolverine event-sourcing guide][wolverine-es]). The versioning page extends the purity stance to schema evolution: upcasters are _"pure functions without side effects"_ that are _"easy to test with unit or contract tests"_ ([`docs/events/versioning.md`][doc-versioning]).

The second principle is that the daemon never guesses. Its high-water mark advances only over committed, contiguous sequence numbers, and it holds under a gap rather than skip it; the async-daemon page states _"This is why the daemon holds rather than guessing, and why it never skips past events that later commit"_ ([`docs/events/projections/async-daemon.md`][doc-daemon]).

---

## How it works

### The journal: `mt_events` and `mt_streams`

The schema is generated from code, not hand-written SQL. [`EventsTable.cs`][events-table] adds the columns in this order: a `SequenceColumn` (`seq_id`, the primary key), `id`, `stream_id`, `version`, the `data` JSONB column, a nullable `bdata` sibling for binary payloads, `type`, `timestamp` (default `now()`), `tenant_id`, `mt_dotnet_type` (nullable), the optional metadata columns (correlation, causation, headers, user name), an optional `is_skipped`, and finally `is_archived`. The unique index `pk_mt_events_stream_and_version` over `(stream_id, version)` is what makes the per-stream version a real invariant rather than a convention. The storage docs describe the columns in prose ([`docs/events/storage.md`][doc-storage]):

> _"`seq_id` - A sequential identifier that acts as the primary key … `version` - A numerical version of the event's position within its event stream … `type` - A string identifier for the event type that's derived from the event type name … `mt_dotnet_type` - The full name of the underlying event type, including assembly name"_

Two identities per event, then: the store-global `seq_id` that projections advance along, and the per-stream `version` that writers guard on. [`StreamsTable.cs`][streams-table] holds one row per stream: `id`, `type` (the aggregate type name, nullable), `version`, `timestamp`, `created`, `tenant_id`, a `compacted_version` watermark, and `is_archived`. The stream row's `version` is the concurrency token.

### Append with an expected version

The `Quick` append mode (the Marten 9 default) does the whole append in one PL/pgSQL function that [`QuickAppendEventFunction.cs`][quick-fn] generates. The expected-version guard is the function's first act:

```sql
if expected_version IS NOT NULL then
    select version, is_archived into event_version, stream_is_archived
      from {schema}.mt_streams where id = stream;          -- optionally "for update"
    if COALESCE(event_version, 0) != expected_version then
        RAISE EXCEPTION 'Stream version mismatch on ''%'': expected %, actual %',
            stream, expected_version, COALESCE(event_version, 0) USING ERRCODE = 'MT003';
    end if;
end if;
```

then, per event, `event_version := event_version + 1` and one `insert into mt_events (seq_id, id, stream_id, version, data, bdata, type, tenant_id, timestamp, mt_dotnet_type, is_archived …)`. Appending to an archived stream raises `MT001`. Whether that version `select` carries `for update` is the `UseExclusiveLockOnConcurrentAppends` option; its doc comment in [`EventGraph.cs`][event-graph] explains the race it closes: two READ COMMITTED transactions can both pass the version check, both call `nextval()`, and the loser fails with a duplicate-key error _"leaving a permanent gap in mt_events_sequence that stalls QueryForNonStaleData"_. With the lock the loser blocks, re-reads, and raises `MT003` before any sequence number is burned.

The appending docs note that the explicit `Append(streamId, expectedVersion, events)` overload _"requires `EventAppendMode.Rich`"_ and steer new code to `FetchForWriting` instead ([`docs/events/appending.md`][doc-appending]).

### `FetchForWriting`: read the aggregate and arm the guard in one round trip

`FetchForWriting<T>(id)` is the write-model entry point ([`EventStore.FetchForWriting.cs`][efw]). It selects a fetch plan by projection lifecycle (live, inline, or async) and returns an `IEventStream<T>` carrying the aggregate plus the stream version it was read at. The live plan ([`FetchLivePlan.ForUpdate.cs`][live-forupdate]) batches two statements: the stream version query and the events query, folds the events into the aggregate, and records the version on the resulting `StreamAction` as `ExpectedVersionOnServer`. The version query is built by [`EventStore.ConcurrentAppends.cs`][concurrent-appends]:

```csharp
builder.Append("select version from ");
builder.Append(_store.Events.DatabaseSchemaName);
builder.Append(".mt_streams where id = ");
builder.AppendParameter(streamId);
// …
if (forUpdate)
{
    builder.Append(" for update");
}
```

`FetchForExclusiveWriting` passes `forUpdate: true`, which also opens a transaction first so the row lock lives until `SaveChangesAsync` or dispose; a lock conflict surfaces as `StreamLockedException`. The explicit-version overload ([`FetchLivePlan.ExpectedVersion.cs`][live-expected]) compares the fetched version against what the caller claims and throws `ConcurrencyException("Expected the existing version to be {expected}, but was {version}")` before the handler even runs. The docs describe the effect: if another process commits to the stream between `FetchForWriting()` and `SaveChangesAsync()`, _"the entire command will fail with a Marten `ConcurrencyException`"_ ([`docs/scenarios/command_handler_workflow.md`][doc-chw]).

The handler shape the docs recommend:

```csharp
public async Task Handle1(MarkItemReady command, IDocumentSession session)
{
    var stream = await session.Events.FetchForWriting<Order>(command.OrderId);
    var order = stream.Aggregate;
    if (order.Items.TryGetValue(command.ItemName, out var item))
        stream.AppendOne(new ItemReady(command.ItemName));
    else
        throw new InvalidOperationException($"Item {command.ItemName} does not exist in this order");
    if (order.IsReadyToShip())
        stream.AppendOne(new OrderReady());
    await session.SaveChangesAsync();
}
```

### Projections: live, inline, async

`ProjectionLifecycle` has three members and `SnapshotLifecycle` two; [`ProjectionLifecycle.cs`][lifecycle] maps between them and throws _"Snapshot lifecycle cannot be live!"_ because a snapshot is by definition persisted. `AggregateStreamAsync<T>` is the live fold: read the stream, order by version, apply each event ([`docs/events/projections/live-aggregates.md`][doc-live]). Inline projections run _"at the time that `IDocumentSession.SaveChanges()` is called to commit a unit of work"_ ([`docs/events/projections/inline.md`][doc-inline]). Multi-stream projections default to async because inline execution under load produces _"contention between requests that effectively stomps over previous updates and leads to apparent 'event skipping'"_ ([`docs/events/projections/multi-stream-projections.md`][doc-multi]).

### The async daemon: high-water mark and progression

The daemon is an in-process hosted service; it needs nothing but PostgreSQL. Its checkpoint table is generated by [`EventProgressionTable.cs`][progression-table]: `name` (primary key, the shard identity), `last_seq_id`, `last_updated`, plus `mode`, `rebuild_threshold`, `assigned_node`, heartbeat/status/pause columns and failure-classification columns. The progress write is a compare-and-set ([`UpdateProjectionProgress.cs`][update-progress]):

```sql
update mt_event_progression
   set last_seq_id = ?, last_updated = transaction_timestamp()
 where name = ? and last_seq_id = ?
```

with the floor of the just-processed range as the third parameter; zero rows affected throws `ProgressionProgressOutOfOrderException`. Progress therefore cannot go backwards or skip, even if two agents briefly believe they own the shard.

The high-water mark is itself a row in the same table. [`HighWaterDetector.cs`][hw-detector] computes it from [`GapDetector.cs`][gap-detector], whose query is deliberately a single statement so all three readings share one snapshot:

```sql
select
  (select min(seq_id) from mt_events where seq_id > :start) as first_after,
  (select seq_id
   from (select seq_id, lead(seq_id) over (order by seq_id) as next_seq
         from mt_events where seq_id >= :start) gaps
   where next_seq is not null and next_seq - seq_id > 1
   order by seq_id limit 1) as gap_edge,
  (select max(seq_id) from mt_events where seq_id >= :start) as max_seq
```

Under a gap the mark holds. The detector then records when it first saw the gap, waits `StaleSequenceThreshold`, and runs a `GapLivenessProbe` against `pg_stat_activity`, fenced by the snapshot `xmax` and the allocation timestamps it observed, to ask whether any transaction that could have reserved the missing numbers is still alive. Only when the gap is proven dead does it skip the whole dead span, capped at the reserved ceiling it recorded, and it logs that _"Any sequence numbers in that range that never committed were lost to rolled-back appends"_. A `SkipStaleGapsDespiteLiveTransactionsAfter` cap exists as an escape hatch and the docs say to use it deliberately because _"past the cap the daemon skips on a suspicion of deadness"_ ([`docs/events/projections/async-daemon.md`][doc-daemon]).

### Rebuilds, snapshots, compaction, archiving

A rebuild resets a projection's progression row and re-folds from sequence zero through the daemon ([`docs/events/projections/rebuilding.md`][doc-rebuild]); cancelling one leaves the row _"either unchanged from before the rebuild or at the actual partial position the rebuild reached. Never a torn, in-between state."_ Snapshots are ordinary projection documents: `opts.Projections.Snapshot<T>(SnapshotLifecycle.Inline)` persists the fold's result as a document on every commit ([`docs/events/projections/single-stream-projections.md`][doc-single]). Stream compaction goes further: `CompactStreamAsync<T>` replaces events at or below a version with one `Compacted<T>(T Snapshot, …)` event, moves the removed events through an `IEventsArchiver` callback, and records the watermark in `mt_streams.compacted_version` ([`docs/events/compacting.md`][doc-compacting]). Archiving flips `is_archived` on the stream and its events, or moves them to a partition; the daemon and LINQ queries exclude archived events by default ([`docs/events/archiving.md`][doc-archiving]). Event skipping (`is_skipped`) exists for the regulatory case where an erroneous event may be neither deleted nor compensated ([`docs/events/skipping.md`][doc-skipping]).

### Versioning: type-name mapping and upcasters

Every event row carries both `type` (a snake_case name derived from the class) and `mt_dotnet_type` (the assembly-qualified CLR name). A namespace move needs only `AddEventType<T>()`; a class rename needs `MapEventType<T>("old_type_name")`. Payload changes go through `Upcast` on `IEventStoreOptions` ([`IEventStoreOptions.cs`][options]), either over CLR types or raw JSON:

```csharp
options.Events
    .Upcast<ShoppingCartOpened, ShoppingCartOpenedWithStatus>(
        "shopping_cart_opened",
        oldEvent => new ShoppingCartOpenedWithStatus(
            oldEvent.ShoppingCartId, new Client(oldEvent.ClientId), ShoppingCartStatus.Opened));
```

Upcasting _"is performed on the fly each time the event is read"_; the stored row is never rewritten ([`docs/events/versioning.md`][doc-versioning]).

### Wolverine: the durable-messaging half

Wolverine's `[AggregateHandler]` middleware generates the `FetchForWriting` → invoke → append → `SaveChangesAsync` sequence around a handler that takes a command and an aggregate and returns events ([Wolverine event-sourcing guide][wolverine-es]). Its transactional outbox writes outgoing messages in the same transaction as the events: _"Marten is persisting the new `Order` document **and** creating database records for the outgoing `OrderCreated` message in the same transaction"_, and only after commit are they handed to the sending agents ([Wolverine outbox guide][wolverine-outbox]). Sagas persist their state as Marten documents and use `TimeoutMessage` scheduled deliveries for time-based transitions ([Wolverine sagas guide][wolverine-sagas]).

---

## Analysis

### 1. Step identity and replay matching

The analogue of a journaled step is an appended event, and its identity is the pair `(stream_id, version)` enforced by the unique index in [`EventsTable.cs`][events-table], with the global `seq_id` as a second, total-order identity. There is no attempt counter and no args hash: a command handler that runs twice against the same starting version has its second append rejected by the `MT003` version-mismatch check in [`QuickAppendEventFunction.cs`][quick-fn], not deduplicated. Idempotency across retries is the caller's job (or Wolverine's message deduplication); Marten's contribution is that the version guard makes a duplicate visible rather than silent. Projection progress is matched by `seq_id` alone through the compare-and-set in [`UpdateProjectionProgress.cs`][update-progress].

### 2. Journal versus world

Marten collapses the distinction: the journal (`mt_events`) and the world (projection documents, `mt_streams.version`, the outbox rows) are tables in one PostgreSQL database, so an inline projection, the events it derives from, and any outbox messages commit or roll back together. Disagreement is therefore detected as a version mismatch at append time (`ConcurrencyException`, [`FetchLivePlan.ExpectedVersion.cs`][live-expected]), never by reconciliation after the fact. Where an external world does exist, it is on the projection side: an async projection lags the log, and a rebuild re-derives the world from the journal by definition, so the journal always wins. The one place the world can silently diverge from the journal is the identity-map optimization the docs warn about ([`docs/scenarios/command_handler_workflow.md`][doc-chw]): mutate `stream.Aggregate` and the persisted snapshot _"diverges from the canonical `AggregateStreamAsync` rebuild"_.

### 3. Determinism enforcement

By discipline, with one runtime backstop. The fold (`Apply`/`Create`/`Evolve` methods) is expected to be a pure function of the events, and upcasters are expected to be pure; nothing checks this. The backstop is that any projection can be rebuilt from scratch and compared against the live fold, which the docs use as the canonical answer whenever a stored document is suspect. Marten does, however, enforce determinism of _order_: `seq_id` is assigned inside the append transaction, the daemon advances only over committed contiguous sequence numbers ([`GapDetector.cs`][gap-detector]), and the progression compare-and-set forbids out-of-order progress, so a projection sees exactly one total order no matter how many times it is rebuilt.

### 4. Compensation and failure handling

There is no compensation registry and no LIFO scope; Marten's versioning page argues the opposite discipline for the journal itself: _"The best strategy is not to change the past data but compensate our mishaps. In Event Sourcing, that means appending the new event with correction"_ ([`docs/events/versioning.md`][doc-versioning]). Failure handling is per-layer. On the write side a failed `SaveChangesAsync` rolls the whole batch back and burns its sequence numbers. On the daemon side errors are classified: `SkipApplyErrors`, `SkipSerializationErrors` and `SkipUnknownEvents` default to true for continuous processing and false for rebuilds, a non-skipped error pauses the projection, and skipped events land in a `DeadLetterEvent` document _"along with the exception"_ for later replay ([`docs/events/projections/async-daemon.md`][doc-daemon]). Wolverine layers sagas with scheduled `TimeoutMessage`s on top for cross-service processes ([Wolverine sagas guide][wolverine-sagas]).

### 5. Versioning against old histories

This is where an event store is strongest. Rows carry `type` and `mt_dotnet_type`, so a CLR rename is a mapping change; payload evolution is an upcaster applied on read, never a migration of stored rows ([`docs/events/versioning.md`][doc-versioning]). Because the fold is re-run on every rebuild, new fold code against old events is the normal case, not a special one. Blue/green deployment of new event types is handled by `SkipUnknownEvents` on the daemon. What Marten lacks is any notion of _code_ version in the journal: nothing records which version of a projection produced a document, beyond the `rebuild_threshold` column in `mt_event_progression`, so an incompatible fold change is discovered by rebuilding, not by a version check.

### 6. Concurrency under replay

Within one stream, appends are serialized by the version guard, and the exclusive variants (`FetchForExclusiveWriting`, `AppendExclusive`, `UseExclusiveLockOnConcurrentAppends`) turn optimistic failure into a row lock ([`EventStore.ConcurrentAppends.cs`][concurrent-appends]). Across streams there is no coordination on the write side and no replay problem to solve: the fold is per stream. The daemon reads the log in `seq_id` order but shards work per projection, so two projections replay independently and each has its own progression row. Multi-stream projections are the case where interleaving matters, and the docs default them to async precisely so one daemon agent serializes them ([`docs/events/projections/multi-stream-projections.md`][doc-multi]). Rebuild concurrency is capped per database at `max(1, MaxPoolSize / 8)` cells ([`docs/events/projections/rebuilding.md`][doc-rebuild]).

### 7. Replay or snapshot

Both, layered. `Live` is pure replay and _"perfectly appropriate for short streams, but maybe a performance issue in longer event streams"_ ([`docs/events/projections/single-stream-projections.md`][doc-single]). `Inline` and `Async` snapshots trade replay cost for a stored document that can drift if the fold code changes, which a rebuild repairs. `CompactStreamAsync` is the irreversible option: it rewrites the journal to start from a `Compacted<T>` snapshot and hands the removed events to an archiver ([`docs/events/compacting.md`][doc-compacting]). The rule the docs express is that snapshots are cheap to throw away and rebuild, so keep the journal authoritative and treat every snapshot as a cache.

### 8. Testing

There is no in-memory store: the testing page's examples open a real `DocumentStore` against a connection string and the integration page starts PostgreSQL in Docker ([`docs/events/projections/testing.md`][doc-testing], [`docs/testing/integration.md`][doc-integration]). The recommended shape is _"integration ('social') testing as much as possible and test your projection code through Marten itself"_. For a live projection the test appends events and calls `AggregateStreamAsync`; for an inline one it loads the persisted document; for async ones it runs the daemon in `Solo` mode and waits for non-stale data. Because deciders return events, the decision logic itself is unit-testable without a database, which is the split Wolverine's guide argues for. Wolverine's tracked session closes the async gap: `InvokeMessageAndWaitAsync` _"will not return until the other messages that are routed locally are finished processing or the test times out"_ and aggregates any handler exceptions ([Wolverine testing guide][wolverine-testing]). Nothing resembles crash-at-every-index testing; the daemon's correctness under crashes rests on the compare-and-set progression write and on rebuilds being idempotent.

### 9. Journal integrity and the single writer

Marten's integrity story is PostgreSQL's, and its most valuable contribution to this
survey is a precisely documented account of how an optimistic version check can
still go wrong.

**The conditional append is a version comparison, and the unique index enforces it.**
A stream's expected version is checked at append time and violated appends raise
`MT003`, with the `(stream_id, version)` unique index as the backstop (§1). This is
the same mechanism as KurrentDB's expected version, expressed as a database
constraint rather than as a storage decision.

**The race that survives a version check is written down.** With `READ COMMITTED`
isolation, _"two concurrent transactions both pass the version check before either
commits, both call nextval(), and the loser fails with a 23505 duplicate key
violation — leaving a permanent gap in `mt_events_sequence` that stalls
`QueryForNonStaleData`"_ ([`EventGraph.cs`][event-graph]). The opt-in fix adds
`FOR UPDATE` to the version select so the loser blocks, re-reads, and raises the
concurrency error _"before any `nextval()` call"_. Two things are worth taking from
this. First, an optimistic check under a weak isolation level is not sufficient on
its own. Second, the damage was not a lost write but a **gap in the global
sequence**, which broke a reader rather than a writer — an integrity failure one
level removed from the append itself.

**Exclusive writing is available as a distinct operation.**
`FetchForExclusiveWriting` takes a lock rather than relying on the version check
([`EventStore.WriteToAggregate.cs`][write-to-aggregate]), so a caller that would
rather block than retry can say so. Offering both, as separate methods, is better
than choosing for the caller.

**Gaps are treated as possibly-temporary, which is the subtle part.** The async
daemon's high-water detector holds at a gap rather than skipping it, because a gap
may be an uncommitted transaction that is about to land
([`GapDetector.cs`][gap-detector]). Only after a liveness probe establishes that no
writer is going to fill it does the projection advance past it. A naive reader that
treats "sequence number missing" as "nothing there" will silently skip events that
commit a moment later.

**Everything commits in one database transaction**, so a batch of events, the stream
version bump and any inline projection update are atomic together — the strongest
form of the multi-record append this survey looks for, obtained by having a real
transaction available.

**Torn writes do not exist as a concept**, and no writer identity is recorded: the
row's provenance is whatever the application chose to put in it.

### 10. Operator recovery and intervention

Because the record is ordinary tables in a database the operator already
administers, most of this dimension is answered by SQL — which is both the strength
and the limit.

**Rebuilding a projection is the primary operation.** The async daemon can rebuild a
projection from scratch, discarding its documents and its checkpoint in
`mt_event_progression` and refolding from the beginning. That is the operator action
for "the read model is wrong", and it is safe precisely because projections are
derived.

**The journal itself is not rewritten, on principle.** The documentation argues the
discipline directly: _"The best strategy is not to change the past data but
compensate our mishaps. In Event Sourcing, that means appending the new event with
correction."_ So there is no supported edit, no fork, and no rewind of a stream —
the correction is a new event.

**Archiving is the retention lever.** A stream can be archived, optionally into a
separate table partition, which keeps it readable while removing it from the hot
path.

**Compaction is the in-journal snapshot.** `CompactStreamAsync` replaces a stream's
prefix with a single compacted event at a version, with an archiver callback for the
events it removes. It is explicitly irreversible, which makes it the one destructive
operation in the model and the reason the callback exists.

**A record the projection cannot apply is skipped and recorded.** The daemon's
default is to skip the offending event and log it as a dead letter, rather than
stalling the projection; during a rebuild the default is to pause instead. Two
different policies for the same failure, chosen by context, is a distinction most
systems do not draw.

**Inspection is SQL, and that is the whole answer.** Any operator with database
access can read `mt_events`, join against `mt_streams`, and inspect
`mt_event_progression` to see how far each projection has advanced. No tool is
needed and none is provided.

**What is absent is anything about a computation**, exactly as with KurrentDB: no
cancellation, no pausing a program, no resuming one from a point — because the
library models data, not control flow.

### 11. Suspension and external input

**This dimension does not apply to the store**, and the boundary is the same one
KurrentDB draws: Marten accepts appends and serves reads, and no program of its own
waits for anything.

**The async daemon is the one thing that resumes**, and it resumes as a reader. Its
position lives in `mt_event_progression` and is advanced with a compare-and-set, so
a daemon that dies continues from its recorded checkpoint rather than from the
beginning. That is the projection-resumption primitive a durable-execution layer
would build on, and it is the same shape as a catch-up subscription's checkpoint.

**Waiting for a projection to catch up is exposed to callers**, because an inline
projection is synchronous with the append while an async one is not; the library
therefore offers a way to wait until the daemon has reached a given sequence. That
is a _reader_ waiting on a _writer_, not a durable program waiting on the world.

**External input is an append**, undistinguished from any other. Nothing models who
produced an event or whether anything was waiting for it.

**Timers and approvals are absent by design.** A durable delay, an addressable
waiting computation, and a state meaning "blocked on input" would all have to come
from a layer above — which is precisely the layer this catalog is about.

---

## Strengths

- **One database is the journal, the world and the checkpoint.** Events, inline projections, outbox rows and daemon progress commit together; there is no cross-store reconciliation problem to design around.
- **The version guard is enforced in SQL,** as a unique index plus a PL/pgSQL check, so no client library bug can produce two events at one stream version.
- **Gap handling is evidence-based.** The daemon holds under a gap, probes `pg_stat_activity` with snapshot fences, and skips only proven-dead spans, logging exactly which range was abandoned.
- **Versioning is on-read.** Type mapping and upcasters mean stored rows are never rewritten and every rebuild is a chance to apply new fold code to old facts.
- **Snapshots are explicitly disposable.** Inline and async documents, and even compaction, are framed as caches over an authoritative log.

## Weaknesses

- **No in-memory or simulated store.** Every test that touches persistence needs PostgreSQL, so crash-and-resume matrices are expensive to write.
- **Purity is a convention.** Nothing stops a fold from reading a clock or a projection from calling out; the identity-map warning shows how easily an impure handler corrupts a snapshot.
- **No attempt identity.** A retried command is either rejected by the version guard or, if the version moved for a legitimate reason, appended again; deduplication is the caller's or Wolverine's job.
- **Dead gaps are a fact of life.** Rolled-back appends burn sequence numbers, and the whole liveness-probe machinery exists to tolerate that.
- **Projection code has no recorded version.** Whether a stored document was produced by the current fold is unknowable without a rebuild.

---

## Key design decisions and trade-offs

| Decision                                                        | Rationale                                                                                     | Trade-off                                                                                                    |
| --------------------------------------------------------------- | --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Two identities per event: global `seq_id`, per-stream `version` | Projections need a total order; writers need a per-entity concurrency token                   | Sequence gaps from rolled-back transactions must be detected and skipped by the daemon                       |
| Append in a PL/pgSQL function (`Quick` mode)                    | One round trip; the version check, stream upsert and inserts share a transaction and snapshot | Inline projections lose `Sequence`/`Version` metadata; `Append(id, expectedVersion, …)` needs `Rich` mode    |
| Optimistic by default, `for update` on request                  | Most streams are uncontended; a row lock is a cheap upgrade when they are not                 | Optimistic losers burn sequence numbers, which is exactly what `UseExclusiveLockOnConcurrentAppends` avoids  |
| Progression as compare-and-set on `last_seq_id`                 | Two agents that both think they own a shard cannot both advance it                            | A stale agent fails loudly (`ProgressionProgressOutOfOrderException`) rather than degrading                  |
| Hold under a gap; skip only with liveness evidence              | Never skip an event that later commits                                                        | A leaked idle-in-transaction session can stall every projection; a time cap trades that for possible loss    |
| Upcast on read, never migrate rows                              | Stored facts stay immutable; new code sees the new shape                                      | Every read pays the transformation; old CLR types or JSON DOM code linger in the codebase                    |
| Rebuild as the universal repair                                 | Snapshots are caches; the log is truth                                                        | Rebuild cost grows with the log, mitigated by archiving and compaction, both of which are operator decisions |
| Real PostgreSQL in every test                                   | The behaviors that matter (locks, snapshots, gaps) are PostgreSQL behaviors                   | No deterministic simulation; crash matrices are integration tests                                            |

---

## Implications for a durable-execution library

- **An optimistic version check is not sufficient under weak isolation** (§9), and
  Marten documents the exact failure: two transactions pass the check, both take a
  sequence number, and the loser's duplicate-key error leaves a permanent gap that
  stalls readers. The fix is to make the check take a lock. Any library whose
  conditional append is not genuinely atomic has this bug latent.
- **The damage from that race was a gap in the global order, not a lost write.** An
  integrity failure can surface one level removed from the append, in whatever reads
  the record — which is an argument for testing the reader against a partially
  written record, not only the writer.
- **A gap must be treated as possibly-temporary.** Marten's high-water detector holds
  at a gap until a liveness probe proves no writer will fill it (§9). A reader that
  treats a missing position as "nothing there" silently skips records that commit a
  moment later.
- **Offer both optimistic and locking writes as separate operations** (§9). A caller
  that would rather block than retry should be able to say so, rather than having the
  library choose.
- **Do not rewrite the record; append a correction** (§10). Marten argues this as
  discipline, and it is the reason it needs no fork, rewind, or edit operation — the
  correction is an ordinary event.
- **Two failure policies for the same error, chosen by context**, is a distinction
  worth copying: skip-and-dead-letter while running, pause while rebuilding (§10).
- **An in-journal snapshot with a callback for what it removes** is the right shape
  for compaction (§10): irreversible, explicit, and it hands the discarded prefix to
  the application rather than dropping it.
- **A projection's checkpoint advanced by compare-and-set** is the whole
  projection-resumption primitive (§11), and it is all a read model needs.
- **Keeping the record in the application's own database is a real trade.**
  Inspection becomes free and requires no tooling; the library inherits schema
  migration, retention and backup as its users' problems rather than its own.

---

## Sources

- [`src/Marten/Events/Schema/EventsTable.cs`][events-table], [`StreamsTable.cs`][streams-table], [`EventProgressionTable.cs`][progression-table], [`QuickAppendEventFunction.cs`][quick-fn]: the generated schema and the append function.
- [`src/Marten/Events/EventStore.FetchForWriting.cs`][efw], [`EventStore.ConcurrentAppends.cs`][concurrent-appends], [`Fetching/FetchLivePlan.ForUpdate.cs`][live-forupdate], [`Fetching/FetchLivePlan.ExpectedVersion.cs`][live-expected], [`EventGraph.cs`][event-graph]: the write model.
- [`src/Marten/Events/Daemon/HighWater/HighWaterDetector.cs`][hw-detector], [`GapDetector.cs`][gap-detector], [`Daemon/Progress/UpdateProjectionProgress.cs`][update-progress]: the daemon's checkpoint and gap logic.
- [`src/Marten/Events/Projections/ProjectionLifecycle.cs`][lifecycle], [`src/Marten/Events/IEventStoreOptions.cs`][options]: lifecycles and the upcasting API.
- Docs in the clone: [appending][doc-appending], [storage][doc-storage], [versioning][doc-versioning], [archiving][doc-archiving], [compacting][doc-compacting], [skipping][doc-skipping], [projections index][doc-proj-index], [inline][doc-inline], [live aggregation][doc-live], [single-stream and snapshots][doc-single], [multi-stream][doc-multi], [async daemon][doc-daemon], [rebuilding][doc-rebuild], [testing projections][doc-testing], [integration testing][doc-integration], [command handler workflow][doc-chw].
- Wolverine guides: [event sourcing][wolverine-es], [outbox][wolverine-outbox], [sagas][wolverine-sagas], [testing][wolverine-testing].
- Sibling pages: [catalog index][catalog], [Temporal][temporal] (replay-of-code contrast), [sagas][sagas-page], [idempotence][idempotence], [write-ahead logging][wal], and the parent [algebraic-effects index][parent].

<!-- References -->

[repo]: https://github.com/JasperFx/marten
[docs]: https://martendb.io/events/
[license]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/LICENSE
[buildprops]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/Directory.Build.props
[events-table]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/src/Marten/Events/Schema/EventsTable.cs
[streams-table]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/src/Marten/Events/Schema/StreamsTable.cs
[progression-table]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/src/Marten/Events/Schema/EventProgressionTable.cs
[quick-fn]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/src/Marten/Events/Schema/QuickAppendEventFunction.cs
[efw]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/src/Marten/Events/EventStore.FetchForWriting.cs
[concurrent-appends]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/src/Marten/Events/EventStore.ConcurrentAppends.cs
[live-forupdate]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/src/Marten/Events/Fetching/FetchLivePlan.ForUpdate.cs
[live-expected]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/src/Marten/Events/Fetching/FetchLivePlan.ExpectedVersion.cs
[event-graph]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/src/Marten/Events/EventGraph.cs
[hw-detector]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/src/Marten/Events/Daemon/HighWater/HighWaterDetector.cs
[gap-detector]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/src/Marten/Events/Daemon/HighWater/GapDetector.cs
[update-progress]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/src/Marten/Events/Daemon/Progress/UpdateProjectionProgress.cs
[lifecycle]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/src/Marten/Events/Projections/ProjectionLifecycle.cs
[options]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/src/Marten/Events/IEventStoreOptions.cs
[doc-appending]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/docs/events/appending.md
[doc-storage]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/docs/events/storage.md
[doc-versioning]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/docs/events/versioning.md
[doc-archiving]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/docs/events/archiving.md
[doc-compacting]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/docs/events/compacting.md
[doc-skipping]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/docs/events/skipping.md
[doc-proj-index]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/docs/events/projections/index.md
[doc-inline]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/docs/events/projections/inline.md
[doc-live]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/docs/events/projections/live-aggregates.md
[doc-single]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/docs/events/projections/single-stream-projections.md
[doc-multi]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/docs/events/projections/multi-stream-projections.md
[doc-daemon]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/docs/events/projections/async-daemon.md
[doc-rebuild]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/docs/events/projections/rebuilding.md
[doc-testing]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/docs/events/projections/testing.md
[doc-integration]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/docs/testing/integration.md
[doc-chw]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/docs/scenarios/command_handler_workflow.md
[wolverine-es]: https://wolverinefx.net/guide/durability/marten/event-sourcing.html
[wolverine-outbox]: https://wolverinefx.net/guide/durability/marten/outbox.html
[wolverine-sagas]: https://wolverinefx.net/guide/durability/sagas.html
[wolverine-testing]: https://wolverinefx.net/guide/testing.html
[catalog]: ./index.md
[temporal]: ./temporal.md
[sagas-page]: ./sagas.md
[idempotence]: ./idempotence.md
[wal]: ./write-ahead-logging.md
[parent]: ../index.md
[write-to-aggregate]: https://github.com/JasperFx/marten/blob/1850d2d4575af3c8d36acdb9d822794ee644e028/src/Marten/Events/EventStore.WriteToAggregate.cs
