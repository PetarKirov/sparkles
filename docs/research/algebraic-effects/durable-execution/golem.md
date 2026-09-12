# Golem (WebAssembly)

A durable-execution _runtime_ rather than an SDK: every agent is a WebAssembly component whose host calls are journaled to a per-agent append-only "oplog", and recovery re-instantiates the component and replays it against that log, so the program itself is never written against a workflow API.

| Field             | Value                                                                                                                                                                                                                                                                                               |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | Rust (runtime, on `wasmtime`); guest SDKs for Rust, TypeScript, Scala and MoonBit                                                                                                                                                                                                                   |
| License           | Business Source License 1.1 with an additional use grant; source headers name it the "Golem Source License v1.1" ([`LICENSE`][license])                                                                                                                                                             |
| Repository        | [golemcloud/golem][repo]                                                                                                                                                                                                                                                                            |
| Documentation     | [learn.golem.cloud][docs] (source lives in-tree under `docs/`; the published `v1.5` tree and the unreleased `next` tree differ, see below)                                                                                                                                                          |
| Category          | durable-execution engine (also `contrast case`: the persisted unit is the WASM host-call boundary, not a user-named step)                                                                                                                                                                           |
| Persistence model | replay, with optional user-defined snapshots that truncate the replay prefix                                                                                                                                                                                                                        |
| Journal store     | Per-agent oplog in three layers: primary indexed storage (Redis streams or in-memory), a compressed secondary layer in the same store, a tertiary compressed archive in blob storage (S3 or filesystem); payloads above a size limit are spilled to blob storage ([`persistence.mdx`][persist-mdx]) |
| Latest release    | `v1.5.1`, published May 11, 2026 ([GitHub release][release]; the docs site pins the same version in [`releases.tsx`][releases-tsx])                                                                                                                                                                 |
| Local clone       | `$REPOS/golem` at `d43c34ddb6f99335ed2d43c13465377a0f474b37` (main, September 11, 2026; 269 commits past `v1.5.1`)                                                                                                                                                                                  |

**Last reviewed:** September 12, 2026.

---

## Overview

### What it solves

Golem's unit of work is the _agent_: a running instance of an agent type defined in a WASM component, with an identity formed from component id, agent type and constructor parameters. The published concept page states the promise directly ([`agents.mdx`][agents-mdx], [site][agents-site]):

> _"**Durable State**. All agent state, including in-memory state, is durable, and can be treated as automatically persistent. This means that state survives failures, restarts, and updates without the loss of any information. Agents may treat their memory as a database, and use it to persist state indefinitely and across any number of invocations."_

The mechanism behind that sentence is the one this catalog cares about: because Golem supplies its own implementation of every WASI and `golem:*` host interface, it sits on the only boundary through which a sandboxed component can observe or affect the world. Each crossing is recorded; linear memory itself is never persisted (except by an opt-in snapshot). Recovery is therefore "run the same deterministic code again and feed it the same answers" ([`snapshotting.mdx`][snapshotting-mdx], [site][snapshotting-site]):

> _"Golem recovers agent state by **replaying the oplog** — the log of all operations performed by the agent. For long-running or CPU-heavy agents, this replay can become slow. Golem 1.5 introduces **user-defined snapshotting**, allowing agents to opt in to periodic snapshots so that recovery only needs to replay entries recorded_ after _the last snapshot."_

This is the contrast case for the catalog. [DBOS][dbos] and [Restate][restate] persist named steps chosen by the programmer; Golem persists whatever the guest asked the host for, with no step names, and gets determinism from the sandbox instead of from discipline.

### Design philosophy

Three commitments recur through the source and the docs:

1. **The oplog is the single source of truth.** Agent metadata in the key-value store is a cache "not always completely up-to-date; it store[s] the last oplog index it was calculated from, and its latest version can be reproduced by reading and processing the newer oplog entries" ([`persistence.mdx`][persist-mdx]).
2. **Replay is strict.** A recorded `Start` that the re-executing guest does not ask for again, or a request the guest makes that has no matching `Start`, is an `UnexpectedOplogEntry` error, not a warning ([`claims.rs`][claims]).
3. **Durability is a dial, exposed to the guest.** The `golem:api/host` interface lets code inside the sandbox mark atomic regions, force oplog commits, change idempotence mode, generate committed idempotency keys, jump backwards in its own oplog and fork itself ([`golem-host.wit`][host-wit]).

---

## How it works

### The journal: `OplogEntry`

The entry type is generated by a macro from a DSL in [`golem-common/src/base_model/oplog/mod.rs`][oplog-model]; each variant declares a `hint` flag (hint entries are skipped by the replay cursor), a raw binary shape and a public JSON shape. The durable core is three entries:

```rust
// golem-common/src/base_model/oplog/mod.rs (abridged; the DSL is rendered as an enum here)
/// Marks the start of a durable host call (or scope such as a batched-write).
Start {
    parent_start_index: Option<OplogIndex>,
    function_name: HostFunctionName,       // e.g. "http::client" / "send"
    invocation_id: Option<Uuid>,
    observational_owner: Option<OplogIndex>,
    request: Option<OplogPayload<HostRequest>>,
    durable_function_type: DurableFunctionType,
}
/// Marks the successful completion of a durable host call started by the `Start` at `start_index`.
End {
    start_index: OplogIndex,
    response: Option<OplogPayload<HostResponse>>,
    forced_commit: bool,
}
/// The call was cancelled (e.g. dropped from a `select!`) before producing a final response.
Cancelled { start_index: OplogIndex, partial: Option<OplogPayload<HostResponse>> }
```

Around them sit the lifecycle entries (`Create`, `AgentInvocationStarted` with its `idempotency_key`, `AgentInvocationFinished`, `PendingAgentInvocation`, `Suspend`, `Interrupted`, `Exited`, `Restart`), the control entries (`Error` with `retry_from`, `NoOp`, `Jump`, `Revert`, `BeginAtomicRegion`/`EndAtomicRegion`, `BeginRemoteTransaction`/`PreCommitRemoteTransaction`/`CommittedRemoteTransaction`/`RolledBackRemoteTransaction`, `SetRetryPolicy`/`RemoveRetryPolicy`), the update entries (`PendingUpdate`, `SuccessfulUpdate`, `FailedUpdate`, `Snapshot`), observability entries (`Log`, `StartSpan`/`FinishSpan`/`SetSpanAttribute`, `GrowMemory`, `CreateResource`/`DropResource`), the concurrency markers `CompletionDelivered` and `CompletionDiscarded`, and a family of permission-card and durable-stream records. The `Error` entry's doc comment is the retry contract in one field:

> _"Points to the oplog index where the retry should start from. Normally this can be just the current oplog index (after the last persisted side-effect). When failing in an atomic region or batched remote writes, this should point to the start of the region."_ ([`oplog/mod.rs`][oplog-model])

### Which host calls are journaled

`HostFunctionName` is generated from a `host_payload_pairs!` table of 174 rows in [`payload/mod.rs`][payload], each pairing an interface and function name with a typed request and response payload. The interfaces covered are the WASI set (`clocks::monotonic-clock`, `clocks::system-clock`, `random::random`, `random::insecure`, `random::insecure-seed`, `cli::environment`, `filesystem::types::descriptor` and its streams, `sockets::types::tcp-socket`/`udp-socket`, `sockets::ip-name-lookup`, `io::poll`, `wasi:config/store`), the outgoing HTTP client (`http::client`, `http::types::request`/`response`, the body and trailer futures), the Golem-specific APIs (`golem::api`, `golem::agent`, `golem::rpc::wasm-rpc` with its future results and cancellation tokens, `golem::secrets::reveal`, `golem::quota`, `golem::permissions::*`, `golem::tool::*`, `golem:websocket/client`), and the storage extensions (`keyvalue::*`, `blobstore::*`, `rdbms::{postgres,mysql,ignite2}::*`). Each call is tagged with a `DurableFunctionType` from [`golem-oplog.wit`][oplog-wit]:

```text
read-local | write-local | read-remote | write-remote
| write-remote-batched(option<oplog-index>) | write-remote-transaction(option<oplog-index>)
```

The variant decides how strictly the call's commit is treated and whether it may be re-executed on recovery: a `write-remote` whose `Start` has no `End` is exactly the at-least-once window the docs warn about.

### Live and replay paths

Every durable host call goes through `DurableCallSession` in [`concurrent/call.rs`][call]. The module header of [`concurrent/mod.rs`][concurrent] states the mechanism:

> _"A durable host call is identified by the `OplogIndex` of its `Start` entry. While live, the call eagerly appends a `Start` (capturing its request) and later an `End` (its response) or a `Cancelled`. During replay the `ConcurrentReplayResolver` matches each completed `End`/`Cancelled` back to the awaiting `DurableCallSession` via a `ReplayableOneshot`, so the two halves of a call no longer have to be adjacent in the oplog — which is what lets us track async, parallel host functions."_

On replay, the session builds a `StartClaim` and asks the replay cursor for the recorded `Start`. The identity predicate in [`claims.rs`][claims] is structural:

```rust
// golem-worker-executor/src/durable_host/replay_state/claims.rs
pub(super) fn matches_start_identity(&self, entry: &OplogEntry) -> bool {
    matches!(entry, OplogEntry::Start { function_name, invocation_id, observational_owner,
                                        request, durable_function_type, parent_start_index, .. }
        if self.matches_function_name(function_name)
            && self.expected_function_type().is_none_or(|expected| durable_function_type == expected)
            && invocation_id.is_none()
            && *observational_owner == self.expected_observational_owner()
            && request.is_some() == self.carries_request()
            && *parent_start_index == self.expected_parent_start_index())
}
```

A claim may additionally carry a `matching_request` payload, in which case the recorded request is compared too (the "expected" side of the error then reads `request: Some(<matching payload>)`). When no `Start` is found before the replay target, the cursor returns `unexpected_oplog_entry(expected, "no matching Start between the replay cursor and the replay target")`; a `Start` that lies inside a jumped-over region is reported as `"matching Start belongs to a deleted replay region"` ([`claims.rs`][claims]).

### The guest-facing dial: `golem:api/host`

The host interface ([`golem-host.wit`][host-wit]) is where the user-controllable durability primitives live:

```wit
// wit/deps/golem-1.x/golem-host.wit (excerpt)
get-oplog-index: func() -> oplog-index;
/// Makes the current agent travel back in time and continue execution from the given position
set-oplog-index: func(oplog-idx: oplog-index);
/// Blocks the execution until the oplog has been written to at least the specified number of replicas
oplog-commit: func(replicas: u8);
/// In case of a failure within the region selected by `mark-begin-operation` and `mark-end-operation`
/// the whole region will be reexecuted on retry.
mark-begin-operation: func() -> oplog-index;
mark-end-operation: func(begin: oplog-index);
trap: func(reason: string);
/// True means side-effects are treated idempotent and Golem guarantees at-least-once semantics.
/// In case of false the executor provides at-most-once semantics, failing the agent in case it is
/// not known if the side effect was already executed.
set-idempotence-mode: func(idempotent: bool);
/// Generates an idempotency key. This operation will never be replayed —
/// i.e. not only is this key generated, but it is persisted and committed
generate-idempotency-key: func() -> uuid;
update-agent: func(agent-id: agent-id, target-revision: component-revision, mode: update-mode) -> result<_, agent-operation-error>;
fork-agent: func(source-agent-id: agent-id, target-agent-id: agent-id, oplog-idx-cut-off: oplog-index) -> result<_, agent-operation-error>;
revert-agent: func(agent-id: agent-id, revert-target: revert-agent-target) -> result<_, agent-operation-error>;
fork: func() -> result<fork-result, agent-operation-error>;
```

The `update-mode` enum has two members, `automatic` and `snapshot-based`; the same file declares the `save-snapshot` and `load-snapshot` interfaces a component exports to take part in the latter.

The implementations in [`golem/v1x.rs`][v1x] are short and readable. `mark_begin_operation` appends `BeginAtomicRegion` and records the returned index so that a later `Error.retry_from` points at it; `set_oplog_index` refuses to jump forward, refuses to jump into an already deleted region, refuses while any durable host call is in flight, and otherwise appends a `Jump` whose region is deleted from replay; `generate_idempotency_key` is itself a `write-remote` durable call whose value is derived from the `Start` index, so it is stable across re-execution of an incomplete attempt.

### Persistence levels: released, then removed

The `v1.5` documentation still teaches a three-valued persistence level ([`v1.5/develop/durability.mdx`][durability-v15-mdx], [site][durability-site]):

| Level                      | Description                                                                                                                                                            |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PersistNothing`           | "Turns off persistence for a section. In case the agent is recovered or restarted, all the side-effecting functions will be reexecuted"                                |
| `PersistRemoteSideEffects` | "Persists all the side-effects that are affecting the outside world. In case of recovery the side-effects won't be reexecuted and the persisted results will be used." |
| `Smart`                    | "The default setting; Let Golem decide what to persist to optimize performance"                                                                                        |

At the reviewed `main` commit the feature is gone: `PersistenceLevel` no longer exists in `golem-common` or the executor, the `ChangePersistenceLevel` entry is absent from the `OplogEntry` DSL, `golem-host.wit` has no `set-persistence-level`, and the `next` docs list only "idempotence, define atomic regions, commit the oplog, and change retry policies" ([`next/develop/durability.mdx`][durability-next-mdx]). A stale doc comment in [`concurrent/call.rs`][call] still describes the old behaviour ("a live call inside a persist-nothing zone still appends its `Start`/`End` … the replay cursor skips whole persist-nothing zones"). The crash-recovery how-to explains the direction of travel: "Durable agents always write to the oplog by design — there is no way to opt out of persistence for a durable agent" ([`golem-test-crash-recovery.mdx`][crash-mdx]).

### Custom durable operations

Library authors can fold several raw host calls into one logical journaled operation through `golem:durability@1.6.0` ([`golem-durability.wit`][durability-wit]): `begin-custom-durable-invocation(function-name, request, function-type)` returns either `live(resource)` or `replayed(recorded-response)`; host effects made while the live resource exists are recorded as "replay-inert observational entries"; dropping the resource without `finish` leaves the operation incomplete, "so normal recovery re-executes it". The Rust SDK wraps this as `Durability<SOk, SErr>` in [`durability.rs`][sdk-durability].

### Transactions and compensation in the SDK

Compensation is an SDK construct over the primitives above ([`transaction/mod.rs`][sdk-tx]):

```rust
// sdks/rust/golem-rust/src/transaction/mod.rs
pub async fn infallible_transaction<Out>(
    f: impl for<'a> FnOnce(&'a mut InfallibleTransaction) -> LocalBoxFuture<'a, Out>,
) -> Out {
    let oplog_index = get_oplog_index();
    let _atomic_region = mark_atomic_operation();
    let mut transaction = InfallibleTransaction::new(oplog_index);
    f(&mut transaction).await
}

impl InfallibleTransaction {
    /// Stop executing the transaction and retry from the beginning, after executing the compensation actions
    pub async fn retry(&mut self) {
        for compensation_action in self.compensations.drain(..).rev() {
            let _ = compensation_action.execute().await;
        }
        set_oplog_index(self.begin_oplog_index);
    }
}
```

A fallible transaction runs compensations in reverse and returns the error; an infallible one runs them in reverse and _jumps the oplog back_ to the transaction start so the whole block re-executes under the active retry policy. The sibling `infallible_transaction_with_strong_rollback_guarantees`, documented as guaranteeing compensation "even if it fails due to a panic or an external executor failure", is `unimplemented!()` in the same file.

---

## Analysis

### 1. Step identity and replay matching

A step is a host call, and its identity is positional plus structural. The claim in [`claims.rs`][claims] matches on `function_name`, `durable_function_type`, `parent_start_index` (the enclosing scope's `Start`), the presence of a request payload and, for claims that carry one, the request itself. There is no user-supplied name and no attempt counter; the ordinal is the oplog position, and a `Start` consumed by a claim cannot be claimed again. The `Start`/`End` split means a crash between the two is visible: the `Start` exists, the `End` does not, and recovery re-executes the call ("incomplete-replay re-execution", [`v1x.rs`][v1x]). The `custom durable invocation` API adds a derived UUID "from the top-level idempotency key, the parent custom invocation when nested, and a deterministic ordinal in that logical parent's namespace" ([`next/develop/durability.mdx`][durability-next-mdx]), which is the closest Golem comes to the catalog's name-plus-attempt-plus-args key, and it is only for SDK authors.

### 2. Journal versus world

The journal wins, unconditionally. A replaying agent never re-observes the world; recorded responses to `wall_clock`, `random`, HTTP and RPC are fed back verbatim, and a guest that asks something different from what was recorded fails with `UnexpectedOplogEntry`. Disagreement is detected by the claim predicate above and, at invocation granularity, by result comparison during automatic update: "If the new component produces a different result value for a past invocation than the old one" is an _invocation result divergence_ ([`agents.mdx`][agents-mdx], [site][agents-site]). The classifier in [`invocation.rs`][invocation] lists `UnexpectedOplogEntry` among the guest-semantic traps, so the failure is attributed to the program, not to infrastructure. Where the world may legitimately have moved (an HTTP request that was sent but whose response was never recorded) Golem does not reconcile; it re-sends under `idempotent = true` or fails the agent under `idempotent = false` ([`golem-host.wit`][host-wit]).

### 3. Determinism enforcement

By the runtime, through the sandbox. A WASM component has no ambient source of nondeterminism: time, randomness, environment, sockets, files and HTTP all arrive through imports that Golem implements, and each is a journaled `Start`/`End`. The `next` docs list what a read-only method must avoid because the runtime cannot see it, and the list is short and telling: mutating in-memory state, and reads of clock, randomness, environment and remote data whose values are journaled but whose _use_ is not ([`read-only-methods.mdx`][readonly-mdx]). Two residual discipline requirements exist: replay must not span a `set-oplog-index` while durable calls are in flight (the host refuses, [`v1x.rs`][v1x]), and a custom durable operation must "make repeated attempts safe" because a trap inside it re-runs its whole body ([`next/develop/durability.mdx`][durability-next-mdx]). Concurrency ordering is enforced by the `CompletionDelivered`/`CompletionDiscarded` markers (below). A guest test, `monotonic_clock_now_replay_parity` in [`tests/durability.rs`][tests-durability], pins that the clock reads back identically on replay.

### 4. Compensation and failure handling

Three layers, from runtime to library:

- **Runtime retry.** Any trap recovers the agent "to the point before the failure" and retries under an exponential-backoff policy with a cap, after which the agent is `failed`; the `Error` entry records `retry_from` and, optionally, a `retry_policy_state` for the composable named policies (`count-box`, `clamp-delay`, `exponential`, predicates) introduced with `SetRetryPolicy` ([`retries.mdx`][retries-mdx], [`oplog/mod.rs`][oplog-model]). The docs warn that "a previous operation's unwanted result (if it did not end in an exception) has been already persisted, in which case it won't be retried".
- **Atomic regions.** `mark-begin-operation`/`mark-end-operation` group host calls so a failure inside re-executes the region from its `BeginAtomicRegion`; the SDK's `atomically` guard deliberately leaves the region open when unwinding from a panic so recovery re-runs it ([`lib.rs`][sdk-lib]).
- **SDK transactions.** `Operation { execute, compensate }` values are recorded as they succeed and compensated in reverse order (LIFO) on a domain error; the infallible variant then `set_oplog_index`s back to the start ([`transaction/mod.rs`][sdk-tx], [`transactions.mdx`][transactions-mdx], [site][transactions-site]). Compensations are explicit, registered by the transaction object rather than by a scope, and there is no runtime-guaranteed rollback on crash: the "strong rollback guarantees" entry point is unimplemented.

### 5. Versioning against old histories

This is where Golem is most explicit, and directly answers the catalog's question 5. Two update modes are declared in `update-mode` ([`golem-host.wit`][host-wit]):

- **`automatic`**: the executor "interrupts the agent, reloads it using the new component version and then replays the agent's oplog from the beginning of time"; replay under the new code must reproduce every recorded invocation result and every recorded side effect, otherwise the update fails, a `FailedUpdate` entry is written and the agent "gets reverted to the original component version and continues running with that" ([`agents.mdx`][agents-mdx], [site][agents-site]). The docs concede that this "is only useful when the changed code is minor or it affects code paths that haven't run yet". The test `failing_auto_update_on_idle` in [`tests/hot_update.rs`][tests-hot-update] encodes exactly that: the new `f1` would return 150 instead of 300, the update is rejected, and the agent stays on `ComponentRevision::INITIAL`.
- **`snapshot-based`**: the old component exports `save-snapshot`, the new one `load-snapshot`; the update is queued like an invocation, runs only when idle, and a `load` failure reverts to the old version ([`updating.mdx`][updating-mdx], [site][updating-site]). Snapshot loading runs "in read-only mode and writes nothing from it to the oplog"; mutating host calls, HTTP and RPC inside it are rejected ([`snapshotting.mdx`][snapshotting-mdx]).

There is no per-step version marker and no patch-style branching inside a history; Golem's answer to code evolution is _prove equivalence by replay, or migrate state by hand_.

### 6. Concurrency under replay

Agents are single-threaded ("Golem agents are single threaded", [`forking.mdx`][forking-mdx]); parallelism is obtained by RPC to child agents or by `fork`, which clones the oplog at the current index and returns `original` on one side and `forked` on the other. Within one agent, WASI Preview 3 style async host calls can overlap, and the oplog supports that: a call's `Start` and `End` need not be adjacent, the replay resolver matches an `End` to its awaiting session by `start_index`, and two hint entries restore delivery order. `CompletionDelivered` "is a guest execution boundary: replay may prepare the recorded host result earlier, but must not hand it to the guest until this marker, so callbacks run in their recorded order"; `CompletionDiscarded` marks a completion the guest dropped (the loser of a `select!`) so that "the call parks unresolved so the deterministic guest drops it at the same point it did live" ([`oplog/mod.rs`][oplog-model], [`concurrent/mod.rs`][concurrent]). Tests `concurrent_delivery_order.rs` and `concurrent_runtime_events.rs` under `golem-worker-executor/tests/` cover this ordering ([`tests/`][tests-dir]).

### 7. Replay or snapshot

Replay is the default and the only mode that supports automatic update; snapshots are an opt-in acceleration and the vehicle for manual update. Costs are stated plainly: replay grows with oplog length ("heartbeats, polling loops, recurring tasks" are called out, [`golem-test-crash-recovery.mdx`][crash-mdx]), and the fix is a `snapshotting` policy of `every(N)` invocations or `periodic(duration)`, after which "recovery only needs to replay entries recorded after the last snapshot". A snapshot rules things out: it is a byte payload the component itself must be able to load, so it is meaningful only for state the SDK can serialize (default JSON via `serde`/`zod`/`zio-blocks-schema`, or a custom pair), and an automatic snapshot that fails to load is discarded rather than retried with an older one ([`snapshotting.mdx`][snapshotting-mdx], [site][snapshotting-site]). The oplog is also compacted in a different sense: entries migrate through compressed layers into blob storage and the atomic-region markers "can be removed during oplog compaction" ([`persistence.mdx`][persist-mdx], [site][persistence-site]; [`oplog/mod.rs`][oplog-model]). Two further operations are unique in this catalog: `revert-agent` (drop a suffix of the oplog, by index or by "last N invocations", `Revert` entry) and `set-oplog-index` (a guest-initiated `Jump`), both of which are time travel over the same log ([`golem-host.wit`][host-wit]; tests in [`tests/revert.rs`][tests-revert]).

### 8. Testing

Golem tests its runtime with real components and real crashes, not with a mocked journal:

- **Crash-then-recover integration tests.** `golem-worker-executor/tests/` runs compiled test components against an executor with Redis and blob storage; `durability.rs` contains `custom_durability_crash_mid_live_invocation_reexecutes_whole_body`, `snapshot_based_recovery`, `snapshot_load_rejects_write_http_and_rpc_and_falls_back_to_full_replay` and the clock-parity test; `transactions.rs` covers `golem_rust_jump`, `golem_rust_atomic_region`, `golem_rust_idempotence_on`/`_off`, `golem_rust_fallible_transaction`, `golem_rust_infallible_transaction`; `hot_update.rs` has 27 update scenarios; `retry_lifecycle.rs` interrupts and deletes agents during a delayed retry ([`tests/durability.rs`][tests-durability], [`tests/transactions.rs`][tests-transactions], [`tests/hot_update.rs`][tests-hot-update], [`tests/retry_lifecycle.rs`][tests-retry]).
- **Golden oplogs.** `compatibility/worker_recovery.rs` restores agents from checked-in `worker_recovery_<case>.oplog.bin` files (a jump case, an auto-update case, shopping-cart and counter examples among them) and waits for recovery, so a change to the replay engine is checked against histories written by older executors ([`worker_recovery.rs`][tests-recovery], [`goldenfiles/`][goldenfiles]); `golem_error_unexpected_oplog_entry.bin` pins the divergence error's serialization.
- **Operator-facing.** `golem agent simulate-crash` interrupts a live agent and forces replay; `golem agent oplog` streams or Lucene-searches the log ([`golem-test-crash-recovery.mdx`][crash-mdx]).

There is no deterministic-simulation harness and no "crash at every index" sweep; determinism is assumed from the sandbox and checked by specific parity tests.

### 9. Journal integrity and the single writer

Golem is the only system in this survey that exposes a **durability barrier to the
program itself**, which makes it the clearest statement of the write-ahead
question anywhere in the catalog.

**`oplog-commit` is an explicit flush, with a replication count.** The host
function _"Blocks the execution until the oplog has been written to at least the
specified number of replicas, or the maximum number of replicas if the requested
number is higher"_ ([`golem-host.wit`][host-wit]). An author who is about to do
something externally visible can therefore insist the record is durable first —
turning the write-ahead discipline from an invariant the runtime hopes to maintain
into an operation the program can demand. Every other system here decides that
question on its users' behalf.

**Atomic regions bound re-execution rather than preventing it.**
`mark-begin-operation` returns an oplog index and `mark-end-operation` closes it;
_"In case of a failure within the region selected by `mark-begin-operation` and
`mark-end-operation` the whole region will be reexecuted on retry"_
([`golem-host.wit`][host-wit]). So the unit of at-least-once is author-chosen,
which is a different and more honest primitive than a transaction: it does not
promise atomicity, it promises where re-execution restarts.

**Single-writer is shard assignment.** An agent belongs to a shard, shards are
assigned to worker executors by a shard manager, and the executor checks ownership
before acting on an agent — `check_worker(agent_id)` on the `ShardService`, with
shard assignment revocable and a not-ready state when no assignment is held
([`shard.rs`][shard-rs]). A request for an agent the executor does not own is an
error rather than a second writer.

**Appends are positional by construction.** The oplog is an index-addressed
sequence and entries are appended in execution order; there is no expected-version
parameter because there is only one writer and one tail. `get-oplog-index` exposes
that position to the program.

**Torn writes and record identity** are the storage backend's concern — Redis and
blob storage in the tested configuration — and the oplog format carries no
per-entry checksum of its own. Nothing stamps which executor wrote an entry.

### 10. Operator recovery and intervention

Golem's recovery surface is the most unusual in the survey because the same
primitive is available to the program and to the operator: moving the oplog
position.

**Reverting is a first-class operation with two targets.** `revert-agent` takes
either `revert-to-oplog-index`, where _"The given index will be the last one to be
kept"_, or `revert-last-invocations(u64)` ([`golem-host.wit`][host-wit]). The
second is the operator-friendly form: undo the last N invocations without needing
to know the log's internal numbering.

**The program can do the same thing to itself.** `set-oplog-index` _"Makes the
current agent travel back in time and continue execution from the given position
in the persistent op log"_, and the SDK's infallible transaction variant uses
exactly this to rewind after compensating (§4). A library that offers rewind only
to operators has drawn the line somewhere Golem does not.

**Forking is explicit and the program can tell which side it is on.** `fork`
returns `original` or `forked` with the new agent's id, so a fork is usable as a
programming construct rather than only as a recovery tool.

**Crash simulation is a shipped command.** The CLI can interrupt a live agent and
force replay, which means "does this program actually survive a crash here" is a
question an operator can answer on a real deployment rather than only in a test
harness.

**The oplog is streamable and searchable**, including a query syntax, so "what did
this agent do" is answerable without reading storage directly — the affordance
several systems here lack.

**Update is an intervention too** (§5): an automatic update replays the whole
oplog under new code and fails the update if the replay diverges, and a
snapshot-based update runs the component's own save and load pair. Both are queued
like invocations and act on an idle agent.

**What is missing is a dead-letter state.** A permanently failing agent retries
under its policy and then becomes `failed`; there is no quarantine that preserves
it for inspection while excluding it from retry.

### 11. Suspension and external input

**Promises are the external-input primitive, and they are host functions rather
than a library.** `create-promise` mints an id, `get-promise` returns an awaitable
handle — _"Can only be called in the same agent that orignally created the
promise"_ — and `complete-promise` delivers a payload and _"Returns true if the
promise was completed, false if the promise was already completed"_
([`golem-host.wit`][host-wit]).

**Duplicate completion is answered by the return value**, not by an error: the
second completion simply reports that it lost. That is the cleanest duplicate-input
contract in the survey, because the caller learns which one won.

**The promise id is the address**, and it is a value the agent can hand to anything
— an email, a webhook payload, another agent — which is what makes human-in-the-loop
a use of the primitive rather than a pattern layered on top.

**Waiting suspends the agent, and replay is how it resumes.** Because every host
call is journaled, an agent that is waiting is simply an agent whose oplog ends at
an await; reactivation re-instantiates the component and replays. There is no
threshold and no in-memory fast path for short waits.

**There is no separate persisted "suspended" status** distinct from idle: an agent
not currently executing is not executing, whether because it finished a call or
because it is awaiting a promise. The oplog tail says which.

**A wait cannot time out on its own.** Nothing in the promise contract carries a
deadline, so a bound has to be built from a sleep raced against the promise —
which, since sleeps are journaled host calls, replays correctly but is the
author's job to write.

---

## Strengths

- **Nothing to name.** Durability falls out of the host boundary; the program is ordinary code in four languages with no workflow DSL and no step decorators.
- **Determinism by construction.** The sandbox turns the usual "do not read the clock" discipline into a host-call that is journaled like any other.
- **Precise failure classification.** `Start` without `End`, `Cancelled`, `CompletionDiscarded`, `retry_from`, `inside_atomic_region` are all first-class in the log, which makes at-least-once windows and retry budgets legible after the fact.
- **Time travel is a primitive.** `Jump`, `Revert` and `fork` operate on the same log and are what the SDK's infallible transactions are built from.
- **Honest versioning story.** Automatic update either proves equivalence by replay or is refused; snapshot update is a user-written migration.
- **Layered storage with spill.** Three oplog layers plus payload spilling keep a Redis primary bounded without changing the log's semantics.

## Weaknesses

- **Journal granularity is not chosen by the author.** Every `wall_clock` read and every `random` byte is an entry; the docs' own remedy for long logs is snapshots, and the `persist-nothing` escape hatch has been removed on `main`.
- **No reconciliation with the world.** Anything the journal says is the truth on replay; an observation that would legitimately differ (a git tag created since) is not a concept the engine has.
- **Compensation is library-level and best-effort.** LIFO compensation lives in the SDK's transaction object; the "strong rollback guarantees" variant is `unimplemented!()`.
- **Automatic update is narrow by design.** Any change that alters a past invocation's result or side-effect sequence is refused, so most real code changes require the snapshot path.
- **Heavy runtime.** Executor, shard manager, component service, Redis and blob storage are the minimum deployment; the guest must be a WASM component.
- **Docs drift.** The published `v1.5` docs and the reviewed `main` disagree on persistence levels; source comments still describe the removed feature.

---

## Key design decisions and trade-offs

| Decision                                                       | Rationale                                                                        | Trade-off                                                                                            |
| -------------------------------------------------------------- | -------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Journal the WASI/host boundary, not user-named steps           | Zero annotation; determinism is enforced by the sandbox rather than trusted      | Log grows with every clock and random read; no step-level naming for evolution                       |
| Split `Start`/`End` entries with `start_index` back-references | Crash-between is visible; async calls may interleave; cancellation is recordable | Replay needs a resolver and delivery-order markers instead of a linear cursor                        |
| Strict divergence (`UnexpectedOplogEntry`) on replay           | A silently wrong replay is worse than a failed one                               | No forgiveness for benign drift; automatic update becomes an equivalence proof                       |
| `Error.retry_from` plus atomic regions                         | Retry granularity is per side effect by default and per region on request        | Author must know which effects are safe to repeat; `idempotent=false` fails the agent instead        |
| Guest-visible `Jump`/`Revert`/`fork`                           | Transactions and undo become library code over one primitive                     | Time travel over a log that also feeds automatic update; jumps and in-flight calls must be fenced    |
| Two update modes: replay-equivalence or user snapshot          | Makes the evolution question explicit instead of patching histories              | Most changes need the manual path; snapshot loading is read-only and cannot re-derive from the world |
| Opt-in snapshots that truncate replay                          | Bounded recovery time for long-lived agents                                      | Only state the SDK can serialize; a bad snapshot falls back to full replay, not to an older snapshot |
| Three-layer oplog with payload spill                           | Keeps a hot Redis primary small and archives cold agents in blob storage         | More moving parts; metadata cache can lag the log                                                    |

---

## Implications for a durable-execution library

- **Exposing a durability barrier to the program is the survey's most interesting
  single idea** (§9). `oplog-commit(replicas)` lets an author insist the record is
  durable to a chosen replication level before doing something externally visible,
  which converts the write-ahead rule from a runtime invariant into a program-level
  operation. Any library whose users perform irreversible effects should consider
  offering it.
- **Author-chosen re-execution boundaries beat implicit ones.** An atomic region
  does not promise atomicity; it promises where a retry restarts (§9). That is a
  weaker and more honest primitive than a transaction, and it is expressible
  without a transactional store.
- **Rewind should be available to the program, not only to operators** (§10).
  Golem's `set-oplog-index` is what makes its compensating-transaction helper
  possible, and it is the same mechanism an operator's revert uses.
- **Prove compatibility by replay** (§5). Replaying an entire record under new code
  and failing the upgrade unless every recorded result reproduces is the only
  mechanism surveyed that decides code compatibility rather than asserting it.
  It is expensive and it is correct.
- **A duplicate external completion should report which one won.**
  `complete-promise` returning false for an already-completed promise is a better
  contract than silence or an error, because the loser learns its fate (§11).
- **Journaling at the host-call boundary removes the naming problem and creates a
  legibility problem.** There are no step names to collide, and equally no step
  names to read: the record is a list of host calls, so the operator tooling has to
  carry the interpretation (§1, §10).
- **Replay cost is proportional to the record, and the record grows with every
  poll.** Golem names the hazard itself — heartbeats and polling loops — and its
  answer is an author-supplied snapshot (§7). Any library that journals at a fine
  granularity inherits this.
- **A sandbox makes determinism a non-question** (§3), and the price is that the
  program must be compiled for the sandbox. That is a defensible trade for a
  platform and usually not available to a library inside an existing language.

---

## Sources

- Golem repository, `main` at `d43c34ddb6f99335ed2d43c13465377a0f474b37`: the oplog model ([`oplog/mod.rs`][oplog-model], [`payload/mod.rs`][payload]), the replay engine ([`concurrent/mod.rs`][concurrent], [`concurrent/call.rs`][call], [`replay_state/mod.rs`][replay-state], [`replay_state/claims.rs`][claims]), the host API implementation ([`golem/v1x.rs`][v1x]), trap classification ([`worker/invocation.rs`][invocation]), the oplog service ([`services/oplog/mod.rs`][oplog-service]), the WIT contracts ([`golem-host.wit`][host-wit], [`golem-oplog.wit`][oplog-wit], [`golem-durability.wit`][durability-wit]), the Rust SDK ([`lib.rs`][sdk-lib], [`durability.rs`][sdk-durability], [`transaction/mod.rs`][sdk-tx]), and the tests ([`tests/`][tests-dir]).
- In-tree documentation sources for [learn.golem.cloud][docs]: the `v1.5` durability page ([`durability.mdx`][durability-v15-mdx]) and the `next` pages on durability, agents, snapshotting, updating, transactions, retries, forking, read-only methods, persistence, reliability and crash testing (cited inline above).
- Published documentation pages read on September 11, 2026: [agents][agents-site], [durability][durability-site], [snapshotting][snapshotting-site], [updating][updating-site], [transactions][transactions-site], [persistence][persistence-site].
- [GitHub release `v1.5.1`][release] (published May 11, 2026).

<!-- References -->

[repo]: https://github.com/golemcloud/golem
[docs]: https://learn.golem.cloud
[release]: https://github.com/golemcloud/golem/releases/tag/v1.5.1
[license]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/LICENSE
[releases-tsx]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/docs/src/lib/releases.tsx
[oplog-model]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/golem-common/src/base_model/oplog/mod.rs
[payload]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/golem-common/src/model/oplog/payload/mod.rs
[concurrent]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/golem-worker-executor/src/durable_host/concurrent/mod.rs
[call]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/golem-worker-executor/src/durable_host/concurrent/call.rs
[replay-state]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/golem-worker-executor/src/durable_host/replay_state/mod.rs
[claims]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/golem-worker-executor/src/durable_host/replay_state/claims.rs
[v1x]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/golem-worker-executor/src/durable_host/golem/v1x.rs
[invocation]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/golem-worker-executor/src/worker/invocation.rs
[oplog-service]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/golem-worker-executor/src/services/oplog/mod.rs
[host-wit]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/wit/deps/golem-1.x/golem-host.wit
[oplog-wit]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/wit/deps/golem-1.x/golem-oplog.wit
[durability-wit]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/wit/deps/golem-durability/golem-durability.wit
[sdk-lib]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/sdks/rust/golem-rust/src/lib.rs
[sdk-durability]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/sdks/rust/golem-rust/src/durability.rs
[sdk-tx]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/sdks/rust/golem-rust/src/transaction/mod.rs
[tests-dir]: https://github.com/golemcloud/golem/tree/d43c34ddb6f99335ed2d43c13465377a0f474b37/golem-worker-executor/tests
[tests-durability]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/golem-worker-executor/tests/durability.rs
[tests-transactions]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/golem-worker-executor/tests/transactions.rs
[tests-hot-update]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/golem-worker-executor/tests/hot_update.rs
[tests-revert]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/golem-worker-executor/tests/revert.rs
[tests-retry]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/golem-worker-executor/tests/retry_lifecycle.rs
[tests-recovery]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/golem-worker-executor/tests/compatibility/worker_recovery.rs
[goldenfiles]: https://github.com/golemcloud/golem/tree/d43c34ddb6f99335ed2d43c13465377a0f474b37/golem-worker-executor/tests/goldenfiles
[durability-v15-mdx]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/docs/src/content/v1.5/develop/durability.mdx
[durability-next-mdx]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/docs/src/content/next/develop/durability.mdx
[agents-mdx]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/docs/src/content/next/concepts/agents.mdx
[snapshotting-mdx]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/docs/src/content/next/develop/snapshotting.mdx
[updating-mdx]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/docs/src/content/next/develop/updating.mdx
[transactions-mdx]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/docs/src/content/next/develop/transactions.mdx
[retries-mdx]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/docs/src/content/next/develop/retries.mdx
[forking-mdx]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/docs/src/content/next/develop/forking.mdx
[readonly-mdx]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/docs/src/content/next/develop/read-only-methods.mdx
[persist-mdx]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/docs/src/content/next/operate/persistence.mdx
[crash-mdx]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/docs/src/content/next/how-to-guides/common/golem-test-crash-recovery.mdx
[agents-site]: https://learn.golem.cloud/v1.5/concepts/agents
[durability-site]: https://learn.golem.cloud/v1.5/develop/durability
[snapshotting-site]: https://learn.golem.cloud/v1.5/develop/snapshotting
[updating-site]: https://learn.golem.cloud/v1.5/develop/updating
[transactions-site]: https://learn.golem.cloud/v1.5/develop/transactions
[persistence-site]: https://learn.golem.cloud/v1.5/operate/persistence
[dbos]: ./dbos.md
[restate]: ./restate.md
[shard-rs]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/golem-worker-executor/src/services/shard.rs
