# Orleans (.NET)

A virtual-actor framework whose persistence story is a state-and-log spectrum rather than a replay engine: a grain is a single-threaded activation of an always-existing logical entity, and its state is either a snapshot written through an e-tag, an event log applied by a pure transition function (`JournaledGrain`), a per-activation command journal with snapshots (`Orleans.Journaling`), or a prepared-then-committed transactional version chain. Nothing in Orleans replays _code_; everything replays _data_.

| Field             | Value                                                                                                                                                                                                                                                                                                                                                                                                       |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | C# (.NET 8/9/10 per the docs' version pivots)                                                                                                                                                                                                                                                                                                                                                               |
| License           | MIT ([`LICENSE`][license])                                                                                                                                                                                                                                                                                                                                                                                  |
| Repository        | [dotnet/orleans][repo]                                                                                                                                                                                                                                                                                                                                                                                      |
| Documentation     | [learn.microsoft.com/dotnet/orleans][doc-overview] · event sourcing: [overview][doc-es], [JournaledGrain basics][doc-es-basics], [log-consistency providers][doc-es-providers], [immediate vs. delayed confirmation][doc-es-confirm], [replicated instances][doc-es-replicated], [notifications][doc-es-notify], [configuration][doc-es-config], [diagnostics][doc-es-diag]                                 |
| Category          | event-sourced actors                                                                                                                                                                                                                                                                                                                                                                                        |
| Persistence model | snapshot (`StateStorage`, `IPersistentState`) · replay-of-events (`LogStorage`, `Orleans.Journaling`) · explicit state machine (transactions: prepared versions + commit sequence); the log-consistency provider is chosen per grain class                                                                                                                                                                  |
| Journal store     | Whatever `IGrainStorage` provider the grain names: the confirmed view plus metadata (`GrainStateWithMetaData`) or the whole `List<TEntry>` as one object (`LogStateWithMetaData`), both behind the provider's e-tag; `Orleans.Journaling` appends JSON Lines records to an `IJournalStorage` (Azure Blob/Table, S3, Redis, in-memory `VolatileJournalStorage`) and periodically replaces it with a snapshot |
| Latest release    | `v10.3.1`, published August 28, 2026 (GitHub releases); the checkout's `Directory.Build.props` carries `VersionPrefix` `10.0.0`                                                                                                                                                                                                                                                                             |
| Local clone       | `$REPOS/orleans` at `cff49293e9132dc889428c376fffee4a4cc95653`                                                                                                                                                                                                                                                                                                                                              |

**Last reviewed:** September 12, 2026.

---

## Overview

### What it solves

Orleans is not a durable-execution engine. It is the origin of the _virtual actor_ abstraction, and its durability features answer a different question from Temporal's: not "how do I resume a long program where it died?" but "how does an entity's state survive the server that held it, given that the entity itself can never die?" The 2014 technical report ([Bernstein et al., MSR-TR-2014-41][tr-2014]) defines the abstraction in four facets, the first of which is the one durable execution borrows:

> _"1. Perpetual existence: actors are purely logical entities that always exist, virtually. An actor cannot be explicitly created or destroyed and its virtual existence is unaffected by the failure of a server that executes it. Since actors always exist, they are always addressable. 2. Automatic instantiation: Orleans' runtime automatically creates in-memory instances of an actor called activations. … If the server where an actor currently is instantiated fails, the runtime will automatically re-instantiate it on a new server on its next invocation."_

The same report fixes the execution model that every persistence feature below relies on:

> _"Actor activations are single threaded and do work in chunks, called turns. An activation executes one turn at a time. A turn can be a method invocation or a closure executed on resolution of a promise. While Orleans may execute turns of different activations in parallel, each activation always executes one turn at a time."_

The earlier SOCC 2011 paper ([Bykov et al.][socc-2011]) already framed grains as _"isolated units of state and computation that communicate through asynchronous messages"_ and promised _"lightweight transactions that support a consistent view of state and provide a foundation for automatic error handling and failure recovery"_; those transactions were cut before release, and the 2014 report says plainly _"Orleans does not yet support cross-actor transactions."_ The transactions that exist today (`Orleans.Transactions`) are a later, separate design.

So where Temporal makes _the program_ recoverable by replaying its decisions, Orleans makes _the entity_ recoverable by reloading its state on the next activation, and offers four ways to represent that state on disk. The interesting one for this catalog is the event-sourced way, because it is the closest thing in a mainstream framework to a journal with a projection.

### Design philosophy

Three commitments shape the event-sourcing layer ([`src/Orleans.EventSourcing/`][es-dir]):

1. **The grain sees two states, confirmed and tentative.** `State` is the fold of the confirmed prefix of the log; `TentativeState` additionally applies the unconfirmed suffix. `Version` is defined as the length of the confirmed prefix ([`JournaledGrain.cs`][journaled-grain]): _"Gets the version of the current confirmed state. Equals the total number of confirmed events."_
2. **The transition function must be pure, by contract not by enforcement.** From the docs ([JournaledGrain basics][doc-es-basics]): _"Assume transition methods have no side effects other than modifying the state object and should be deterministic (otherwise, the effects are unpredictable). If the transition code throws an exception, Orleans catches it and includes it in a warning in the Orleans log, issued by the log-consistency provider."_
3. **What gets persisted is a provider decision, not an API decision.** The same `JournaledGrain` code runs over a provider that stores only the latest state, one that stores only the event list, or a user-supplied storage interface. The base class's own doc-comment gives the game away ([`PrimaryBasedLogViewAdaptor.cs`][pbla]): _"Note that the log itself is transient, i.e. not actually saved to storage - only the latest view and some metadata (the log position, and write flags) is stored in the primary."_

The newer `Orleans.Journaling` package (in this checkout, without a docs page yet) reverses the last point: there the journal _is_ the primary, entries are commands against typed durable collections, and snapshots are a compaction of it.

---

## How it works

### The user-facing shape

A journaled grain names its state type and its event base type, raises events, and optionally waits for them to be confirmed. The package README's bank account ([`src/Orleans.EventSourcing/README.md`][es-dir]), trimmed:

```csharp
public class BankAccountGrain : JournaledGrain<BankAccountState, object>, IBankAccountGrain
{
    public async Task Deposit(decimal amount)
    {
        RaiseEvent(new DepositEvent { Amount = amount });   // initiates a write, does not wait
        await ConfirmEvents();                              // waits for the storage ack
    }

    public Task<IReadOnlyList<object>> GetHistory()
        => RetrieveConfirmedEvents(0, Version);             // LogStorage only

    protected override void ApplyEvent(object @event) { /* fold one event into State */ }
}
```

The full surface of `JournaledGrain<TGrainState, TEventBase>` ([`JournaledGrain.cs`][journaled-grain]):

| Member                                           | Meaning                                                                                                                                        |
| ------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `RaiseEvent(e)` / `RaiseEvents(es)`              | `LogViewAdaptor.Submit` / `SubmitRange`: append to the pending queue; a range is written atomically                                            |
| `RaiseConditionalEvent(e)` → `Task<bool>`        | `TryAppend`: succeeds _"only if there are no conflicts, that is, no other events were raised in the meantime"_; returns `false` on a lost race |
| `State` / `Version`                              | `ConfirmedView` / `ConfirmedVersion`                                                                                                           |
| `TentativeState` / `UnconfirmedEvents`           | `TentativeView` / `UnconfirmedSuffix`                                                                                                          |
| `ConfirmEvents()`                                | `ConfirmSubmittedEntries`: wait until the worker has serviced the pending queue                                                                |
| `RefreshNow()`                                   | `Synchronize`: confirm everything and reload from storage (linearizable read across instances)                                                 |
| `RetrieveConfirmedEvents(from, to)`              | `RetrieveLogSegment`; throws `NotSupportedException` on providers that do not keep events                                                      |
| `TransitionState(state, event)`                  | the fold; the default is `dynamic s = state; dynamic e = @event; s.Apply(e);` (overload resolution on the runtime event type)                  |
| `OnStateChanged()` / `OnTentativeStateChanged()` | callbacks when the confirmed / tentative view changes                                                                                          |
| `OnConnectionIssue(issue)`                       | storage or cross-cluster trouble, reported every time it recurs, resolved once                                                                 |
| `ClearLogAsync()`                                | reset to the initial state; discards unconfirmed events                                                                                        |

`OnActivateAsync` defaults to `LogViewAdaptor.Synchronize()`: _"upon activation, the journaled grain waits until it has loaded the latest view from storage."_ The lifecycle hooks are wired in [`LogConsistentGrain.cs`][lcg], which subscribes the adaptor one stage before and one stage after the user's `Activate` stage and resolves the provider from the `[LogConsistencyProvider(ProviderName = …)]` attribute, falling back to `StateStorage.DefaultAdaptorFactory` when none is named.

### The adaptor: one worker, one primary, a pending queue

All three built-in providers derive from `PrimaryBasedLogViewAdaptor<TLogView, TLogEntry, TSubmissionEntry>` ([`PrimaryBasedLogViewAdaptor.cs`][pbla]). Its state is a `pending` list of `SubmissionEntry` records, a cached confirmed view, and a lazily computed tentative view:

```csharp
public class SubmissionEntry<TLogEntry>
{
    public TLogEntry Entry;
    public DateTime SubmissionTime;
    public TaskCompletionSource<bool>? ResultPromise;   // conditional updates only
    public int ConditionalPosition;                      // the log position this update must land at; -1 = unconditional
}
```

`Submit` appends to `pending`, folds the entry into the tentative view if one is materialized, fires `OnViewChanged(tentative: true)`, and pokes a background worker. `TryAppend` does the same but records `ConditionalPosition = ConfirmedVersion + pending.Count` and hands back a promise. The worker's cycle (`Work`) is: process notifications from other instances, read the primary if an initial read or refresh is due, then `UpdatePrimary`, which loops: drop stale conditional updates (`RemoveStaleConditionalUpdates`: any conditional entry whose `ConditionalPosition != version + pos`, and every conditional entry after it, is failed with `false` and removed), write the batch, retry on a zero-length result, and finally resolve promises and `pending.RemoveRange(0, writeResult)`.

The one piece of machinery that makes retried appends safe is the **write vector** ([`GrainStateWithMetaData.cs`][gswm], identical in [`LogStateWithMetaData.cs`][lswm]):

> _"Metadata that is used to avoid duplicate appends. Logically, this is a (string->bit) map, the keys being replica ids … Bits are toggled when writing, so that the retry logic can avoid appending an entry twice when retrying a failed append."_

`WriteAsync` flips the bit for `Services.MyClusterId`, writes, and on any exception re-reads the primary in a loop (_"be stubborn until we can read what is there"_) and compares the stored bit to the one it wrote: _"check if last apparently failed write was in fact successful"_ ([`StateStorage/LogViewAdaptor.cs`][ss-adaptor]). A write whose acknowledgement was lost is therefore recognised as committed rather than re-applied.

### The three log-consistency providers

| Provider        | What the primary holds                                                                                 | On activation                                 | `RetrieveConfirmedEvents` | Docs' verdict                                                                                                                      |
| --------------- | ------------------------------------------------------------------------------------------------------ | --------------------------------------------- | ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `StateStorage`  | `GrainStateWithMetaData<TView>`: `State`, `GlobalVersion`, `WriteVector`, behind the storage e-tag     | read the snapshot                             | throws                    | _"stores grain state snapshots"_; _"the events aren't persisted"_ ([providers][doc-es-providers])                                  |
| `LogStorage`    | `LogStateWithMetaData<TEntry>`: `List<TEntry> Log`, `WriteVector`; `GlobalVersion` is `Log.Count`      | read the whole list, fold every entry         | from the in-memory list   | _"not suitable for production use unless the event sequences are guaranteed to remain fairly short … to illustrate the semantics"_ |
| `CustomStorage` | whatever the grain's `ICustomStorageInterface<TState, TDelta>` does with `(version, state)` and deltas | `ReadStateFromStorage()` → `(version, state)` | throws                    | _"doesn't make specific assumptions about whether the stored data consists of state snapshots or events"_                          |

The custom contract is small and is the clearest statement of the protocol's expectations ([`ICustomStorageInterface.cs`][custom-iface]):

```csharp
public interface ICustomStorageInterface<TState, TDelta>
{
    Task<KeyValuePair<int, TState>> ReadStateFromStorage();
    // "returns true, if the version in storage matches the expected version. Otherwise, does nothing and returns false.
    //  If successful, the version of storage must be increased by the number of deltas."
    Task<bool> ApplyUpdatesToStorage(IReadOnlyList<TDelta> updates, int expectedVersion);
    Task ClearStoredState() => throw new NotSupportedException();
}
```

The docs add the duplication caveat that the write vector solves for the built-in providers and hands to the user here ([providers][doc-es-providers]): _"If `ApplyUpdatesToStorage` fails with an exception, the consistency provider retries. This means some events could be duplicated if such an exception is thrown but the event was persisted. You are responsible for ensuring this is safe."_

### Delayed confirmation and replicated instances

By default a grain confirms before returning, which the docs call immediate confirmation: no `[Reentrant]`, always `await ConfirmEvents()`. The cost is availability: _"If the connection to a remote cluster or storage is temporarily interrupted, the grain becomes unavailable"_ ([confirmation][doc-es-confirm]). Delayed confirmation lets methods return with events still in flight, at which point `TentativeState` is _"a 'best guess' at what will likely become the next confirmed state … there's no guarantee it actually will become the confirmed state. This is because the grain might fail, or the events might race against other events and lose, causing them to be canceled (if conditional) or appear later in the sequence than anticipated (if unconditional)."_

Multiple activations of one grain (multi-cluster deployments, or a transient duplicate during a partition) all submit to the same primary, and the primary's e-tag serialises them: _"if two instances see the same version number, they see the same state"_ ([replicated instances][doc-es-replicated]). After a successful write the writer sends an `UpdateNotificationMessage { Version, Origin, Updates, ETag }` to the other instances; the receiver keeps them in a `SortedList` keyed by starting version, applies only the one whose key equals its current version, discards older ones, and leaves a gap to be filled by a refresh ([`LogStorage/LogViewAdaptor.cs`][ls-adaptor]). The test grains show both conflict styles: [`AccountGrain.cs`][account-grain] guards withdrawals with `RaiseConditionalEvent` (_"so we can guarantee that we never overdraw even if racing with other clusters"_), while [`SeatReservationGrain.cs`][seat-grain] raises unconditionally and lets the fold decide (_"this is a 'first writer wins' conflict resolution"_): a reservation for a taken seat is applied as a no-op and the caller re-reads `State` to learn whether it won.

### `Orleans.Journaling`: durable collections over an appendable journal

The newer package ([`src/Orleans.Journaling/`][journaling-dir]) is a different design under the same word. A `DurableGrain` ([`DurableGrain.cs`][durable-grain]) owns an `IJournaledStateManager`; named states (`IDurableList<T>`, `IDurableDictionary<K,V>`, `IDurableSet<T>`, `IDurableQueue<T>`, `IDurableValue<T>`, `IPersistentState<T>` via `DurableState<T>`, `DurableTaskCompletionSource<T>`) register with it. A mutation applies in memory and writes a command to the state's stream at once; `WriteStateAsync()` flushes. The contract's own summary ([`IJournaledState.cs`][ijs]):

> _"In other words, in-memory mutations are journaled within the same grain turn and become durable when the journal flushes. Implementations are free to apply mutations eagerly (before the durable write completes); recovery rebuilds in-memory state from the journal, so a turn-failure-and-recovery cycle observably rewinds any unflushed changes."_

The storage format is JSON Lines, one record per entry: `[8,["set","alpha",1]]` is stream `8`, command `set`, operands `"alpha", 1` ([`README.md`][journaling-dir]). `IJournalStorage` ([`IJournalStorage.cs`][ijstorage]) has exactly the operations a WAL needs: `ReadAsync` (stream everything to a consumer), `AppendAsync`, `ReplaceAsync` (the snapshot), `DeleteAsync`, an `IsCompactionRequested` flag, and format-key metadata. The manager's work loop decides per write whether to append or snapshot ([`JournaledStateManager.cs`][jsm]): a snapshot is taken when the user asks, when the storage requests compaction, or when the recovered data was written in a different format (`_migrationSnapshotRequired`). A `TODO` in that loop admits the policy is unfinished: _"decide whether it's best to snapshot or append. Eg, by summing the size of the most recent snapshots and the current journal length."_

Recovery (`RecoverAsync`) resets every state, streams the journal through the format's `Replay`, and dispatches each entry to the state registered under its stream id; an entry for a stream no grain code registers any more lands in a `RetiredState` that is dropped after a grace period (`RetirementGracePeriod`, default 7 days). Each entry carries its own format key, so `JournalReplayContext.GetRequiredCommandCodec` can decode an old-format entry with the old codec while new writes use the configured one ([`JournalReplayContext.cs`][jrc]).

### The contrast case: transactions

`Orleans.Transactions` does not journal and does not replay. A grain declares `ITransactionalState<TState>` ([`ITransactionalState.cs`][its]) and touches state only through `PerformRead`/`PerformUpdate` lambdas; methods carry `[Transaction(TransactionOption.Create | Join | CreateOrJoin | …)]` ([`TransactionAttribute.cs`][txattr]). Storage keeps a committed state plus a chain of prepared versions ([`ITransactionalStateStorage.cs`][itss]): `Store(expectedETag, metadata, statesToPrepare, commitUpTo, abortAfter)`, where each `PendingTransactionState` is _"A snapshot of the state after this transaction executed"_ with a dense local `SequenceId`. Recovery reads the authoritative record and asks the transaction manager about the fate of each prepared version. The docs' guarantee is ACID across grains with no central coordinator, and their failure contract is the durable-execution one turned inside out: an `OrleansTransactionAbortedException` means retry, but _"Any other exception thrown indicates the transaction terminated with an unknown state. Since transactions are distributed operations, a transaction in an unknown state could have succeeded, failed, or still be in progress"_ ([transactions][doc-tx]).

---

## Analysis

The eight questions were written for replay-of-code systems. For an event-sourced actor, "step" becomes "event", "journal" becomes "log or snapshot", and "the world" becomes "the storage primary". Each subsection says which translation it is using.

### 1. Step identity and replay matching

There are no steps to match, because nothing re-executes grain code. An event's identity is its **position in the confirmed sequence**: `Version` is the count of confirmed events, and the fold is order-dependent by definition. Two things are keyed off that position. A conditional event carries `ConditionalPosition` (the version it expects to land at) and is dropped if the confirmed version has moved ([`PrimaryBasedLogViewAdaptor.cs`][pbla], `RemoveStaleConditionalUpdates`). A retried write is keyed by the per-replica bit in the `WriteVector`, which is how the adaptor tells "my lost-ack write landed" from "somebody else wrote" ([`GrainStateWithMetaData.cs`][gswm]). Events carry no names, no attempt counters and no argument hashes; deduplication is by _batch_, not by event. In `Orleans.Journaling` an entry is identified by its stream id and its order within the journal ([`README.md`][journaling-dir]); there is no per-entry id at all.

### 2. Journal versus world

Storage _is_ the world, and storage always wins. `RefreshNow` and activation both reload from the primary; a write is accepted only through the provider's e-tag (`GrainStateWithMetaDataAndETag.ETag`, `ApplyUpdatesToStorage(…, expectedVersion)`), and a mismatch is detected as a rejected write, never as a divergence to reconcile. On conflict the adaptor re-reads, re-folds its pending unconditional events on top of the newer state (they are resubmitted, so they may _"appear later in the sequence than anticipated"_, [confirmation][doc-es-confirm]), and fails its conditional ones. There is no notion of an observation that the journal recorded and the world later contradicted, because the journal never records observations: it records _decisions_ (events), and the fold is the only reader. The one place "the world disagrees with what I thought I did" is the lost-ack write, and the write vector answers it ([`StateStorage/LogViewAdaptor.cs`][ss-adaptor]). In `Orleans.Journaling` the same role is played by `InconsistentStateException` from `AppendAsync`/`ReplaceAsync` ([`IJournalStorage.cs`][ijstorage]), after which the manager re-runs recovery from the journal.

### 3. Determinism enforcement

By discipline. The docs say transition methods _"should be deterministic (otherwise, the effects are unpredictable)"_ ([JournaledGrain basics][doc-es-basics]) and the runtime does nothing to check it; the default `TransitionState` is a `dynamic` dispatch to `Apply` overloads ([`JournaledGrain.cs`][journaled-grain]), so even the choice of transition is resolved at run time. Worse for auditability, an exception in the fold is caught, logged (`Services.CaughtUserCodeException("UpdateView", …)`), and the version advances anyway ([`LogStorage/LogViewAdaptor.cs`][ls-adaptor], `UpdateConfirmedView`); a non-deterministic or throwing fold silently produces a view that no longer equals the fold of the log. What Orleans does enforce is the _scheduling_ half: the turn-based model guarantees the fold and the grain method never run in parallel ([request scheduling][doc-scheduling]: _"Grain activations have a single-threaded execution model"_), and `Orleans.Journaling` states that _"Implementations are owned by a single `JournaledStateManager` and are accessed from one logical thread at a time"_ ([`IJournaledState.cs`][ijs]). Event _construction_ is unconstrained: the docs' own example stamps `Timestamp = DateTime.UtcNow` into the event, which is fine precisely because the timestamp is data in the log, not a value re-derived on replay.

### 4. Compensation and failure handling

None, in the saga sense. The event-sourcing layer offers three failure behaviours and no rollback primitive: a conditional event fails fast and returns `false` to the caller, who decides ([`AccountGrain.cs`][account-grain]); an unconditional event is retried against storage _forever_ (`while (true) // be stubborn`), surfacing only through `OnConnectionIssue` callbacks ([diagnostics][doc-es-diag]) and the grain's unavailability; and the fold can encode application-level conflict resolution, as the seat grain's first-writer-wins no-op does ([`SeatReservationGrain.cs`][seat-grain]). There is no way to un-raise a confirmed event other than raising a compensating one, and the framework does not know which event compensates which. `Orleans.Journaling` adds `RevertPendingChangesAsync` ([`JournaledStateManager.cs`][jsm]), which discards unflushed mutations by re-running recovery, a rollback of _memory_ to the last durable point, not of the world. The transactions package is the compensation story Orleans actually ships: prepared versions that are committed or aborted as a unit ([`ITransactionalStateStorage.cs`][itss]), with the explicit warning that a non-abort exception leaves the outcome unknown ([transactions][doc-tx]).

### 5. Versioning against old histories

The docs answer this per provider, and the answer is the classic event-sourcing trade ([JournaledGrain basics][doc-es-basics]): _"Some providers, like the `LogStorage` log-consistency provider, replay the event sequence every time the grain loads. Therefore, as long as the event objects can still be properly deserialized from storage, you can radically modify the `GrainState` class and the transition methods. However, for other providers, such as the `StateStorage` log-consistency provider, only the `GrainState` object is persisted. In this case, you must ensure it can be deserialized correctly when read from storage."_ Compatibility is delegated to the serializer (version-tolerant JSON by default, [grain persistence][doc-persistence]). There is no schema version on the log, no upcaster hook, and no equivalent of Temporal's `patched` gate; a changed fold simply produces a different view of the same events, which is a feature here (the fold is a projection) and a hazard for a durable program (a changed decision is not a projection). `Orleans.Journaling` is more deliberate: every entry carries a format key, an old-format journal is decoded with its own codec and rewritten as a snapshot in the new format on the next write, and streams that code no longer registers are quarantined as `RetiredState` for a grace period before being dropped ([`JournalReplayContext.cs`][jrc], [`JournaledStateManager.cs`][jsm]).

### 6. Concurrency under replay

Replay is a fold over a totally ordered list, so there is nothing to interleave: the primary assigns the order, and every instance folds the same sequence ([replicated instances][doc-es-replicated]). Concurrency exists _around_ the log: within one activation, delayed confirmation plus `[Reentrant]` lets several grain methods be in flight while events are unconfirmed, and the docs' guarantee is exactly the tail-resumptive one this catalog's host relies on: _"even though several methods might be in progress, only one can be actively executing—all others are stuck at an `await`. … The properties `State`, `TentativeState`, `Version`, and `UnconfirmedEvents` can change during the execution of a method. However, such changes can only happen while stuck at an `await`"_ ([confirmation][doc-es-confirm]). Across activations, races are resolved by the e-tag and reported as `false` (conditional) or reordering (unconditional). The test suite is candid about the cost: the tentative-vs-confirmed test has to run _inside_ the grain because _"otherwise the interleaving of the individual steps is nondeterministic"_ ([`PersonGrainTests.cs`][person-tests]).

### 7. Replay or snapshot

Orleans refuses to choose, and the refusal is the finding. `StateStorage` is snapshot-only: every write serialises the whole view (_"this provider isn't suitable for objects with very large grain states"_) and the history is gone. `LogStorage` is replay-only: every read and write moves the whole `List<TEntry>` as one storage object, which is why the docs call it a teaching provider. `CustomStorage` is "you decide", and the docs' stated plan is to grow the provider list _"to more easily allow you to plug in standard event storage systems"_ ([overview][doc-es]). `Orleans.Journaling` finally does both in one store: append entries, snapshot on request or on compaction pressure, with the append-vs-snapshot heuristic still a `TODO` ([`JournaledStateManager.cs`][jsm]). What replay buys here is cheap: the fold is pure over data, activation cost is linear in log length, and there is no code to keep deterministic beyond `Apply`. What it rules out is _reading_ a step's result before the log is written; there is no "started" record, so a crash between raising and confirming loses the event, which the docs accept as the meaning of "unconfirmed".

### 8. Testing

Integration-first, with in-memory storage and a real cluster in-process. `TestCluster` and the newer `InProcessTestCluster` ([testing][doc-testing], [`TestCluster.cs`][test-cluster]) start silos in the test process; the event-sourcing fixture registers all three providers plus `AddMemoryGrainStorageAsDefault` and a `FaultInjectionMemoryStorage` with a 15 ms latency ([`EventSourcingClusterFixture.cs`][es-fixture], [`FaultInjectionStorageProvider.cs`][fault-storage]). `Orleans.Journaling` tests run over `VolatileJournalStorageProvider` ([`VolatileJournalStorage.cs`][volatile], [`DurableStateAndTcsRecoveryTests.cs`][journaling-recovery-tests]) and check `Grain_State_Should_Persist_Between_Activations` ([`DurableGrainTests.cs`][durable-grain-tests]). The adaptor itself has unit tests that drive the protocol directly: a conditional range that observes the activation read advancing the version completes `false` and removes the whole range; a notification arriving during a blocked write is applied in the next worker cycle; a throwing view-changed callback is reported, not propagated ([`PrimaryBasedLogViewAdaptorTests.cs`][pbla-tests]). There is no crash-at-every-index harness and no deterministic scheduler; the `PersonGrainTests` comment above is the admission.

---

## Strengths

- **Single-writer activation is a runtime guarantee, not a convention.** The turn model means the fold and the method body cannot race, which is the property every journaling scheme needs and most SDKs have to police with sandboxes.
- **Confirmed versus tentative is first-class in the API.** `State`/`Version` versus `TentativeState`/`UnconfirmedEvents`, plus `OnStateChanged`/`OnTentativeStateChanged`, give the caller a precise vocabulary for "durable" versus "in flight".
- **Lost-acknowledgement writes are solved, cheaply.** The per-replica flip bit in the write vector turns "did my write land?" into a re-read and a bit comparison, with no idempotency key per event.
- **Conflict handling is a choice the fold can make.** Conditional events (fail fast) and unconditional events with a resolving fold (first writer wins) coexist on one grain.
- **The provider seam decouples the programming model from the persistence model.** The same grain runs snapshot-only, log-only or custom, and `CustomStorage` is a 20-line interface.
- **`Orleans.Journaling` gets the storage format right.** JSON Lines, append plus replace, per-entry format keys, retired-stream quarantine, and a storage contract small enough to implement over a file.

## Weaknesses

- **Purity of the fold is unenforced and its failures are swallowed.** A throwing `Apply` is logged and the version still advances; the view and the log silently diverge.
- **`LogStorage` is not a production event store.** The whole list is one blob per read and write; the docs say so, and the promised pluggable event stores have not shipped in `Orleans.EventSourcing`.
- **No schema versioning for events.** Compatibility is whatever the serializer tolerates; nothing records which code produced an event.
- **No "started" record.** Nothing is durable before the write completes, so there is no way to distinguish "never attempted" from "attempted, ack lost" for anything except the storage write itself.
- **No compensation model.** Retry-forever for unconditional writes and `false` for conditional ones is the whole failure vocabulary of the event-sourcing layer.
- **Testing is integration-heavy and timing-sensitive.** No deterministic scheduler; the tests that need a fixed interleaving move the test body into the grain.

## Key design decisions and trade-offs

| Decision                                                                  | Rationale                                                                                    | Trade-off                                                                                                                       |
| ------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| Virtual actors: always exist, activated on demand, one turn at a time     | Removes creation, lookup, supervision and locking from application code                      | State must be reloadable on every activation; long in-memory computations are cut into turns by the runtime, not the programmer |
| Two views, confirmed and tentative, with `Version` = confirmed length     | Lets a grain answer from memory while writes are in flight, and reason about what is durable | Tentative state is a guess; callers must choose which view to read                                                              |
| The log is transient unless the provider keeps it                         | Same API over cheap snapshot storage and over a real event log                               | `RetrieveConfirmedEvents` and "radically modify the state class" work on some providers only                                    |
| Conflicts resolved by the primary's e-tag, surfaced as `false`            | No coordinator, works across clusters, one round trip                                        | Unconditional events can be reordered behind a lost race; the caller learns by re-reading                                       |
| Write vector bit per replica                                              | Detects a committed-but-unacknowledged write without per-event idempotency keys              | Only distinguishes "my last batch" from "not mine"; two lost acks in a row from one replica are ambiguous                       |
| Fold purity by documentation; exceptions caught and logged                | Never let user code wedge the protocol worker                                                | Divergence between log and view is possible and quiet                                                                           |
| `Orleans.Journaling`: append entries, snapshot on compaction or migration | Bounded recovery time with an append-only hot path                                           | The append-vs-snapshot policy is a `TODO`; snapshots are whole-journal `ReplaceAsync`                                           |
| Transactions as prepared versions, not a journal                          | ACID across grains without a central coordinator                                             | Unknown outcome on non-abort failure; no history                                                                                |

## Relevance to sparkles

- **Confirms the per-checkout lock, and names its real job.** Orleans' single activation per grain is the same invariant as `release`'s one-writer-per-checkout: the lock is not a concurrency convenience, it is what makes "the journal is the only history" true. Orleans additionally shows what happens when the invariant is briefly violated (duplicate activations during a partition): the _storage_ e-tag catches it, not the lock. The sparkles journal should carry an e-tag-shaped fence too (journal length or last-entry hash checked on append), so a second `release` process on the same checkout is rejected at the write, not just at the lock file.
- **`started`/`completed` is stronger than tentative/confirmed, and the difference is exactly the write vector.** Orleans has no "started" record; it needs the flip-bit trick to recover a lost ack because nothing durable says "I attempted this". The sparkles design's `started` entry _is_ that durable attempt marker, per op rather than per batch. Keep it. The flip bit is a reminder that `started` alone does not answer "did it land?" for an external effect; the reconciliation rule table still has to re-observe (does the tag exist? does the release exist?) for every `started`-without-`completed` op.
- **Snapshot versus log: Orleans argues for journal-plus-projection, from both directions.** `StateStorage` shows what a snapshot-only design loses (history, `RetrieveConfirmedEvents`, radical state-class changes); `LogStorage` shows what a naïve log costs (whole-list I/O). The sparkles choice, an append-only `journal.jsonl` with the UI as a projection, is `Orleans.Journaling`'s shape, and that package's per-entry format key plus forced-snapshot-on-migration is the versioning mechanism the sparkles design currently lacks: record the producing code version on every entry, and treat a version mismatch on resume as "re-project, do not replay decisions".
- **Argues against relying on discipline for purity of the fold.** Orleans documents that `Apply` must be pure, does not check it, and swallows its exceptions. The sparkles design's "journaling combinator is the single pure-cast" is the same bet in a language that can partly enforce it: make the projection and the replay-decode functions `pure` in D, and make a throw during replay a hard stop, not a logged warning.
- **Conditional events are the model for confirmation gates and observations.** `RaiseConditionalEvent` is "apply this only if the world is still at the version I decided against"; that is precisely a re-observed observation with an expected value. The reconciliation rule table can be expressed as conditional appends: an observation entry records the expected world value, and resume re-observes and either confirms (`true`, continue) or fails the entry (`false`, re-ask), with the rule table deciding which of the two an observation kind gets.
- **Missing in Orleans, present in the design: compensation and crash-at-every-index testing.** Orleans' event-sourcing layer has neither, and its transactions layer has undo but no history. The `PersonGrainTests` comment ("the interleaving … is nondeterministic") is the argument for sparkles' `TestClock`/`SimNet`/`SimProc` doubles: the crash-at-every-event-index harness only works because the capability row makes the schedule deterministic, which Orleans' in-process test cluster cannot offer.
- **Do not copy the retry-forever default.** An unconditional Orleans write blocks the grain until storage returns; `release` has a human on the other end. Bounded retry with the journal recording the last attempt, then a confirmation gate, is the right translation.

## Sources

- Bernstein, Bykov, Geller, Kliot, Thelin, _Orleans: Distributed Virtual Actors for Programmability and Scalability_, MSR-TR-2014-41 (March 2014): [publication page][tr-2014], [PDF][tr-2014-pdf].
- Bykov, Geller, Kliot, Larus, Pandya, Thelin, _Orleans: Cloud Computing for Everyone_, SOCC 2011: [DOI][socc-2011-doi], [publication page][socc-2011].
- Orleans documentation on learn.microsoft.com: [overview][doc-overview], [event sourcing][doc-es] and its sub-pages, [request scheduling][doc-scheduling], [grain persistence][doc-persistence], [transactions][doc-tx], [unit testing][doc-testing].
- `dotnet/orleans` at `cff49293e9132dc889428c376fffee4a4cc95653`: `src/Orleans.EventSourcing/`, `src/Orleans.Journaling/`, `src/Orleans.Transactions/`, `src/Orleans.TestingHost/`, and the event-sourcing and journaling test projects.
- Sibling pages: [Temporal][temporal] (replay-of-code contrast), [the catalog index][catalog-index], [the algebraic-effects topic][topic-index].

<!-- References -->

[repo]: https://github.com/dotnet/orleans
[license]: https://github.com/dotnet/orleans/blob/cff49293e9132dc889428c376fffee4a4cc95653/LICENSE
[es-dir]: https://github.com/dotnet/orleans/blob/cff49293e9132dc889428c376fffee4a4cc95653/src/Orleans.EventSourcing/README.md
[journaled-grain]: https://github.com/dotnet/orleans/blob/cff49293e9132dc889428c376fffee4a4cc95653/src/Orleans.EventSourcing/JournaledGrain.cs
[pbla]: https://github.com/dotnet/orleans/blob/cff49293e9132dc889428c376fffee4a4cc95653/src/Orleans.EventSourcing/Common/PrimaryBasedLogViewAdaptor.cs
[ss-adaptor]: https://github.com/dotnet/orleans/blob/cff49293e9132dc889428c376fffee4a4cc95653/src/Orleans.EventSourcing/StateStorage/LogViewAdaptor.cs
[gswm]: https://github.com/dotnet/orleans/blob/cff49293e9132dc889428c376fffee4a4cc95653/src/Orleans.EventSourcing/StateStorage/GrainStateWithMetaData.cs
[ls-adaptor]: https://github.com/dotnet/orleans/blob/cff49293e9132dc889428c376fffee4a4cc95653/src/Orleans.EventSourcing/LogStorage/LogViewAdaptor.cs
[lswm]: https://github.com/dotnet/orleans/blob/cff49293e9132dc889428c376fffee4a4cc95653/src/Orleans.EventSourcing/LogStorage/LogStateWithMetaData.cs
[custom-iface]: https://github.com/dotnet/orleans/blob/cff49293e9132dc889428c376fffee4a4cc95653/src/Orleans.EventSourcing/CustomStorage/ICustomStorageInterface.cs
[lcg]: https://github.com/dotnet/orleans/blob/cff49293e9132dc889428c376fffee4a4cc95653/src/Orleans.EventSourcing/LogConsistency/LogConsistentGrain.cs
[journaling-dir]: https://github.com/dotnet/orleans/blob/cff49293e9132dc889428c376fffee4a4cc95653/src/Orleans.Journaling/README.md
[durable-grain]: https://github.com/dotnet/orleans/blob/cff49293e9132dc889428c376fffee4a4cc95653/src/Orleans.Journaling/DurableGrain.cs
[ijs]: https://github.com/dotnet/orleans/blob/cff49293e9132dc889428c376fffee4a4cc95653/src/Orleans.Journaling/IJournaledState.cs
[ijstorage]: https://github.com/dotnet/orleans/blob/cff49293e9132dc889428c376fffee4a4cc95653/src/Orleans.Journaling/IJournalStorage.cs
[jsm]: https://github.com/dotnet/orleans/blob/cff49293e9132dc889428c376fffee4a4cc95653/src/Orleans.Journaling/JournaledStateManager.cs
[jrc]: https://github.com/dotnet/orleans/blob/cff49293e9132dc889428c376fffee4a4cc95653/src/Orleans.Journaling/JournalReplayContext.cs
[volatile]: https://github.com/dotnet/orleans/blob/cff49293e9132dc889428c376fffee4a4cc95653/src/Orleans.Journaling/VolatileJournalStorage.cs
[its]: https://github.com/dotnet/orleans/blob/cff49293e9132dc889428c376fffee4a4cc95653/src/Orleans.Transactions/Abstractions/ITransactionalState.cs
[itss]: https://github.com/dotnet/orleans/blob/cff49293e9132dc889428c376fffee4a4cc95653/src/Orleans.Transactions/Abstractions/ITransactionalStateStorage.cs
[txattr]: https://github.com/dotnet/orleans/blob/cff49293e9132dc889428c376fffee4a4cc95653/src/Orleans.Transactions/TransactionAttribute.cs
[test-cluster]: https://github.com/dotnet/orleans/blob/cff49293e9132dc889428c376fffee4a4cc95653/src/Orleans.TestingHost/TestCluster.cs
[fault-storage]: https://github.com/dotnet/orleans/blob/cff49293e9132dc889428c376fffee4a4cc95653/src/Orleans.TestingHost/TestStorageProviders/FaultInjectionStorageProvider.cs
[es-fixture]: https://github.com/dotnet/orleans/blob/cff49293e9132dc889428c376fffee4a4cc95653/test/Orleans.EventSourcing.Tests/EventSourcingTests/EventSourcingClusterFixture.cs
[person-tests]: https://github.com/dotnet/orleans/blob/cff49293e9132dc889428c376fffee4a4cc95653/test/Orleans.EventSourcing.Tests/EventSourcingTests/PersonGrainTests.cs
[pbla-tests]: https://github.com/dotnet/orleans/blob/cff49293e9132dc889428c376fffee4a4cc95653/test/Orleans.EventSourcing.Tests/EventSourcingTests/PrimaryBasedLogViewAdaptorTests.cs
[account-grain]: https://github.com/dotnet/orleans/blob/cff49293e9132dc889428c376fffee4a4cc95653/test/Grains/TestGrains/EventSourcing/AccountGrain.cs
[seat-grain]: https://github.com/dotnet/orleans/blob/cff49293e9132dc889428c376fffee4a4cc95653/test/Grains/TestGrains/EventSourcing/SeatReservationGrain.cs
[journaling-recovery-tests]: https://github.com/dotnet/orleans/blob/cff49293e9132dc889428c376fffee4a4cc95653/test/Orleans.Journaling.Tests/DurableStateAndTcsRecoveryTests.cs
[durable-grain-tests]: https://github.com/dotnet/orleans/blob/cff49293e9132dc889428c376fffee4a4cc95653/test/Orleans.Journaling.Tests/DurableGrainTests.cs
[doc-overview]: https://learn.microsoft.com/en-us/dotnet/orleans/overview
[doc-es]: https://learn.microsoft.com/en-us/dotnet/orleans/grains/event-sourcing/
[doc-es-basics]: https://learn.microsoft.com/en-us/dotnet/orleans/grains/event-sourcing/journaledgrain-basics
[doc-es-providers]: https://learn.microsoft.com/en-us/dotnet/orleans/grains/event-sourcing/log-consistency-providers
[doc-es-confirm]: https://learn.microsoft.com/en-us/dotnet/orleans/grains/event-sourcing/immediate-vs-delayed-confirmation
[doc-es-replicated]: https://learn.microsoft.com/en-us/dotnet/orleans/grains/event-sourcing/replicated-instances
[doc-es-notify]: https://learn.microsoft.com/en-us/dotnet/orleans/grains/event-sourcing/notifications
[doc-es-config]: https://learn.microsoft.com/en-us/dotnet/orleans/grains/event-sourcing/event-sourcing-configuration
[doc-es-diag]: https://learn.microsoft.com/en-us/dotnet/orleans/grains/event-sourcing/journaledgrain-diagnostics
[doc-scheduling]: https://learn.microsoft.com/en-us/dotnet/orleans/grains/request-scheduling
[doc-persistence]: https://learn.microsoft.com/en-us/dotnet/orleans/grains/grain-persistence/
[doc-tx]: https://learn.microsoft.com/en-us/dotnet/orleans/grains/transactions
[doc-testing]: https://learn.microsoft.com/en-us/dotnet/orleans/implementation/testing
[tr-2014]: https://www.microsoft.com/en-us/research/publication/orleans-distributed-virtual-actors-for-programmability-and-scalability/
[tr-2014-pdf]: https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/Orleans-MSR-TR-2014-41.pdf
[socc-2011]: https://www.microsoft.com/en-us/research/publication/orleans-cloud-computing-for-everyone/
[socc-2011-doi]: https://doi.org/10.1145/2038916.2038932
[temporal]: ./temporal.md
[catalog-index]: ./index.md
[topic-index]: ../index.md
