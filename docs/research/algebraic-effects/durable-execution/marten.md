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

## Relevance to sparkles

- **Confirms the single-writer guard, and shows a stronger form of it.** `FetchForWriting` reads the aggregate and the version it was read at in one round trip, and the append fails on `MT003` if the version moved. The `release` journal should carry the analogue: the journal's own "version" (its entry count, or the sequence of the last `completed` record) is read at resume and asserted at every append, so two resumed runs cannot both extend the same `journal.jsonl`. `FetchForExclusiveWriting` suggests the cheaper option for a CLI: take an exclusive lock on the journal file for the life of the run.
- **Argues against re-observe-and-reconcile as the primary mechanism.** Marten has no reconciliation rule table because it has no external mutable truth: the world _is_ the journal. `release` cannot have that (git tags and GitHub releases are the world), but the lesson is to shrink the reconcilable surface: record each world observation as an event with its own identity so the reconciliation step is a diff between two typed facts, not a free-form rule per op.
- **The progression table is the projection-offset pattern the design needs for its UI.** "UI is a projection of the journal" implies a checkpoint per consumer: `mt_event_progression` keyed by consumer name, advanced by compare-and-set, and reset on rebuild. A `release` UI projection that stores `last_seq_id` per view can be rebuilt from `journal.jsonl` at any time, which also makes the projection code's own evolution a non-event.
- **The gap logic is the concrete answer to "which record identity can be trusted after a crash".** A crashed `release` run leaves a `started` record with no `completed`; Marten's dead-gap reasoning (hold, then prove no live writer, then skip and _log the exact range_) maps onto the `--split` case where a partially published release must be either completed or explicitly abandoned, and says the abandonment must be a journaled fact, not an inference.
- **Upcasters are the versioning tool, and they should be pure and registered by type name.** Journal records in `release` should carry a `type` string decoupled from the D type name, and evolution should be a registered `old → new` function applied on read, never a rewrite of `journal.jsonl`. This is the design's biggest gap: the decided design keys records by name plus attempt plus args hash and says nothing about what happens when a step's args schema changes.
- **Snapshots are caches, compaction is a policy.** Marten's `Compacted<T>` event is the model for a `--plan` file or publish manifest: a snapshot inserted _into_ the journal at a version, so replay can start from it, rather than a separate file the journal does not know about.
- **What the design has that Marten lacks:** explicit compensations, attempt counters, and crash-at-every-index testing. Marten's error-handling story is skip-and-dead-letter, which is right for projections but not for a workflow that must undo a half-made GitHub release. Keep the compensation scope; borrow the checkpoint discipline.

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
