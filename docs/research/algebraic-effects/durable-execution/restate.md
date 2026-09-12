# Restate (Rust / TypeScript SDK)

A durable-execution engine whose server is a Rust log-structured state machine (Bifrost log → partition processors → RocksDB) and whose SDKs are thin language bindings over one shared Rust "core" state machine, so that a handler written as ordinary `async` code is replayed, command by command, against a journal the server streams back to it after every failure or suspension.

| Field             | Value                                                                                                                                                                                                                                                                                                                   |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | Server: Rust (edition 2024, `rust-version = "1.96.1"`). SDK: TypeScript over `restate-sdk-shared-core` (Rust compiled to WebAssembly via `wasm-bindgen`)                                                                                                                                                                |
| License           | Server: BUSL-1.1 (converts to Apache-2.0 at the change date). TypeScript SDK and service protocol: MIT                                                                                                                                                                                                                  |
| Repository        | [restatedev/restate][repo-server] · [restatedev/sdk-typescript][repo-sdk] · [restatedev/sdk-shared-core][repo-core] · [restatedev/service-protocol][repo-proto]                                                                                                                                                         |
| Documentation     | [docs.restate.dev][docs] · [Sagas guide][docs-sagas] · [Versioning][docs-versioning]                                                                                                                                                                                                                                    |
| Category          | durable-execution engine (server) + durable-execution SDK                                                                                                                                                                                                                                                               |
| Persistence model | replay                                                                                                                                                                                                                                                                                                                  |
| Journal store     | Per-invocation journal in the partition store (RocksDB), materialized from the Bifrost distributed log; streamed to the SDK over an HTTP/2 bidirectional stream on every attempt                                                                                                                                        |
| Latest release    | Server `v1.7.9` (September 4, 2026) · `@restatedev/restate-sdk` `v1.17.0` (August 31, 2026)                                                                                                                                                                                                                             |
| Local clone       | `$REPOS/restate` at `fbead57b941912ae0095027ce1795b36917131c2` · `$REPOS/restate-sdk-typescript` at `6879b36b6774c580c8dad9812cc6088150909dae` · `$REPOS/restate-documentation` at `de0378c9d7e6499cde94ac743f460161900b1e4c` (docs snapshot of November 6, 2025). The shared core is not cloned; cited at tag `v7.0.3` |

**Last reviewed:** September 12, 2026.

---

## Overview

### What it solves

Restate positions itself as "a distributed, durable version of common building blocks": durable functions, durable RPC and queues, durable promises and timers, and keyed state, all reached through a `ctx` object the SDK hands to a handler ([`docs/concepts/durable_building_blocks.mdx`][doc-blocks]). The failure model is spelled out in one paragraph of the concepts page ([`docs/concepts/durable_execution.mdx`][doc-de]):

> In case of a failure (e.g. timeout, infrastructure crash, network glitch), Restate will retry the execution by invoking the handler again and sending over the latest version of the journal. The handler then starts executing again and whenever it encounters an action on the Restate context, it will skip execution and will inject the response it finds in the journal.

The server sits in front of user services "similar to a reverse proxy or message broker" and drives each invocation to completion; the SDK's job is "tracking the progress of the execution and sending it to the runtime" ([`docs/concepts/services.mdx`][doc-services], [`docs/concepts/durable_execution.mdx`][doc-de]). Three service kinds share one journal mechanism: plain **services** (stateless, unlimited concurrency), **virtual objects** (a K/V store per key, one exclusive handler at a time per key) and **workflows** (a `run` handler that "executes exactly one time for each workflow instance", plus shared handlers that query state or resolve durable promises) ([`docs/concepts/services.mdx`][doc-services], [`docs/develop/ts/workflows.mdx`][doc-workflows]).

### Design philosophy

Two commitments shape everything below. First, the journal is the only channel to the world: nothing a handler observes survives a retry unless it went through a context operation, and the docs say so bluntly ([`docs/develop/ts/journaling-results.mdx`][doc-journaling]):

> Restate uses an execution log for replay after failures and suspensions. This means that non-deterministic results (e.g. database responses, UUID generation) need to be stored in the execution log.

Second, the engine is itself a log. The architecture reference describes Bifrost as recording "all events in the system before acting on them, similar to the function of a write-ahead log (WAL) in a database system", with partition processors deriving "the 'state of the world'" from it, including "the journal of each invocation, durable promises, and persisted key-value state" ([`docs/references/architecture.mdx`][doc-arch]). The service protocol's own header comment states the journal's shape in one line ([`service-protocol/dev/restate/service/protocol.proto`][proto]):

> The Journal is modelled as commands and notifications. Commands define the operations executed, while notifications can be: Completions to commands, Unnamed signals, Named signals.

---

## How it works

### The user-facing API

A handler receives a `Context` (or `ObjectContext` / `WorkflowContext`) and reaches every durable primitive through it. The docs' sign-up workflow shows the whole vocabulary in one handler ([`code_snippets/ts/src/develop/workflows/signup.ts`][snip-signup]):

```ts
const signUpWorkflow = restate.workflow({
  name: 'signup',
  handlers: {
    run: async (ctx: WorkflowContext, req: { email: string }) => {
      const secret = ctx.rand.uuidv4();
      ctx.set('status', 'Generated secret');

      await ctx.run('send email', () =>
        sendEmailWithLink({ email: req.email, secret }),
      );
      ctx.set('status', 'Sent email');

      const clickSecret = await ctx.promise<string>('email.clicked');
      ctx.set('status', 'Clicked email');

      return clickSecret == secret;
    },
    click: (ctx: restate.WorkflowSharedContext, secret: string) =>
      ctx.promise<string>('email.clicked').resolve(secret),
    getStatus: (ctx: restate.WorkflowSharedContext) =>
      ctx.get<string>('status'),
  },
});
```

The primitives, with the command each one journals (types from [`crates/types/src/journal_v2/command.rs`][cmd-rs]):

| API                                                                       | Journal command(s)                                                                                                                       | Completion / notification                           |
| ------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------- |
| handler entry / return                                                    | `InputCommand` / `OutputCommand`                                                                                                         | none                                                |
| `ctx.run(name?, fn, RunOptions?)`                                         | `RunCommand { completion_id, name }`                                                                                                     | `RunCompletion` (value or `Failure`)                |
| `ctx.sleep(duration, name?)`                                              | `SleepCommand { wake_up_time, completion_id, name }`                                                                                     | `SleepCompletion`                                   |
| `ctx.serviceClient(..).h(..)` / `ctx.objectClient` / `ctx.workflowClient` | `CallCommand { request: CallRequest { idempotency_key, .. }, .. }`                                                                       | `CallInvocationIdCompletion`, then `CallCompletion` |
| `ctx.serviceSendClient(..)` (one-way / delayed)                           | `OneWayCallCommand { invoke_time, .. }`                                                                                                  | `CallInvocationIdCompletion`                        |
| `ctx.awakeable()`                                                         | none for creation; the ID is an `ExternalSignalIdentifier { invocation_id, signal_index }` ([`crates/types/src/identifiers.rs`][ids-rs]) | `Signal` (indexed) when resolved or rejected        |
| `ctx.resolveAwakeable` / `ctx.rejectAwakeable`                            | `CompleteAwakeableCommand { id, result, name }`                                                                                          | none                                                |
| `ctx.get` / `ctx.set` / `ctx.clear` / `ctx.clearAll`                      | `GetEagerState` or `GetLazyState`, `SetState`, `ClearState`, `ClearAllState`                                                             | `GetLazyStateCompletion` when state is lazy         |
| `ctx.promise(name)` / `.peek()` / `.resolve()`                            | `GetPromise`, `PeekPromise`, `CompletePromise`                                                                                           | matching completions                                |
| `ctx.attach` / result retrieval                                           | `AttachInvocation`, `GetInvocationOutput`                                                                                                | matching completions                                |

`ctx.rand` is a `xoshiro256++` generator seeded from `StartMessage.random_seed` ([`packages/libs/restate-sdk/src/utils/rand.ts`][rand-ts], [`service-protocol/dev/restate/service/protocol.proto`][proto]), and `ctx.date.now()` is literally `this.run(() => Date.now())` ([`packages/libs/restate-sdk/src/context_impl.ts`][ctx-impl]): time is a journaled side effect, not a clock capability.

### The wire protocol and the attempt lifecycle

The server's invoker opens an HTTP/2 stream to the deployment and sends a `StartMessage` whose fields describe the replay it is about to perform ([`service-protocol/dev/restate/service/protocol.proto`][proto]):

```protobuf
message StartMessage {
  bytes id = 1;                      // invocation id, stable across replays
  string debug_id = 2;
  uint32 known_entries = 3;          // sum of known commands + notifications
  repeated StateEntry state_map = 4; // eager K/V state for keyed services
  bool partial_state = 5;
  string key = 6;
  uint32 retry_count_since_last_stored_entry = 7;
  uint64 duration_since_last_stored_entry = 8;
  uint64 random_seed = 9;
}
```

It then streams exactly `known_entries` journal entries out of the partition store; the invoker's `replay_loop` counts them and fails the attempt with `UnexpectedEntryCount` if the store yields fewer ([`crates/invoker-impl/src/invocation_task/service_protocol_runner_v4.rs`][runner]). On the SDK side the generic handler buffers those entries into the core VM before any user code runs, looping on `notify_input` until `is_ready_to_execute` ([`packages/libs/restate-sdk/src/endpoint/handlers/generic.ts`][generic-ts]). The core VM is an explicit state machine ([`src/vm/mod.rs` in the shared core][core-vm]):

```rust
pub(crate) enum State {
    WaitingStart,
    WaitingReplayEntries { received_entries: u32, commands: VecDeque<RawMessage>, .. },
    Replaying { commands: VecDeque<RawMessage>, run_state: RunState, .. },
    Processing { processing_first_entry: bool, run_state: RunState, .. },
    Closed,
}
```

While `Replaying`, every context call pops the front of `commands` and compares; once the queue drains the VM flips to `Processing` and the same calls instead **write** new commands to the output stream (`PopOrWriteJournalEntry`, [`src/vm/transitions/journal.rs`][core-journal]). The attempt ends with `EndMessage`, `SuspensionMessage` (carrying a `Future` tree that says what the code is blocked on) or `ErrorMessage` (with an `ErrorBehavior` of `RETRY`, `PAUSE` or `FAIL` since protocol V7) ([`service-protocol/dev/restate/service/protocol.proto`][proto]). Suspension is the normal way to sleep or wait: "Restate suspends the handler while it is sleeping, to free up resources" ([`docs/develop/ts/durable-timers.mdx`][doc-timers]), and the invoker's `inactivity_timeout` "triggers a graceful termination by asking the service invocation to suspend (which preserves intermediate progress)" ([`crates/types/src/config/worker.rs`][cfg-worker]).

### `ctx.run` in detail

`run` is the only place non-Restate code touches the journal. The implementation asks the VM for a handle and only registers the closure if the command was not replayed ([`packages/libs/restate-sdk/src/context_impl.ts`][ctx-impl]):

```ts
wasmRun = this.coreVm.sys_run(name ?? '');
const handle = wasmRun.handle;
const commandIndex = this.coreVm.last_command_index();

if (!wasmRun.replayed) {
  // Let's prepare the run task only if the run wasnt replayed.
  const doRun: () => Promise<any> = async () => {
    /* execute, then propose */
  };
  this.runClosuresTracker.registerRunClosure(handle, doRun);
}
```

The closure's outcome is **proposed**, not written: `propose_run_completion_success` / `_failure` / `_failure_transient` send a `ProposeRunCompletionMessage`, which "won't be written to the journal immediately, but will appear later as a new notification (meaning the result was stored)" ([`service-protocol/dev/restate/service/protocol.proto`][proto]). A `TerminalError` is journaled as a failure and never retried; a `RetryableError` carries an optional `retryAfter`; any other thrown value is a transient failure that follows the `RunOptions` policy (`maxRetryAttempts`, `maxRetryDuration`, `initialRetryInterval` defaulting to 50 ms, `maxRetryInterval` defaulting to 10 s, `retryIntervalFactor` defaulting to 2), and "when giving up, `ctx.run` will throw a `TerminalError` wrapping the original error message" ([`packages/libs/restate-sdk/src/context.ts`][ctx-ts]). The docstring of `run` states the exactly-once boundary honestly ([`packages/libs/restate-sdk/src/context.ts`][ctx-ts]):

> There is a small window where an action may be re-run, if a failure occurred between a successful run and persisting the result. No second action will be run while a previous run's result is not yet durable. That way, effects that build on top of each other can assume deterministic results from previous runs, and at most one run will be re-executed on replay.

### Idempotency keys

Callers attach an `Idempotency-Key` header to an ingress request; "after the invocation completes, Restate persists the response for a retention period of one day (24 hours)" and a repeat with the same key gets the stored response without re-execution ([`docs/invoke/http.mdx`][doc-http]). Inside a handler the same field is journaled on `CallRequest.idempotency_key`, and `AttachInvocationTarget::IdempotentRequest` lets a later caller attach to the earlier invocation by key ([`crates/types/src/journal_v2/command.rs`][cmd-rs]). Workflows are keyed the same way: "You can only submit once per workflow ID" ([`docs/develop/ts/workflows.mdx`][doc-workflows]).

### Persistence: Bifrost and the partition store

Every event, including each journal entry, is first appended to a Bifrost log and only then applied by the partition processor that owns the key range ([`docs/references/architecture.mdx`][doc-arch]). A Bifrost log "is a chain of append-only segments", each backed by a loglet whose contract is that "if an append returns an offset, it **must** be durably committed" ([`crates/bifrost/src/loglet.rs`][loglet-rs]). The partition store exposes the materialized journal through `ReadJournalTable`: `get_journal_entry(invocation_id, index)`, `get_journal(invocation_id, length)`, `get_notifications_index`, `get_command_by_completion_id` and memory-budgeted variants that lease from a `LocalMemoryPool` before decoding ([`crates/storage-api/src/journal_table_v2/mod.rs`][jt-rs]). Each invocation records a `PinnedDeployment { deployment_id, service_protocol_version }` so replays always go back to the code that wrote the journal ([`crates/types/src/deployment.rs`][deploy-rs]).

---

## Analysis

### 1. Step identity and replay matching

Identity is **positional**: a command's identity is its index in the invocation's journal, and the SDK verifies the code by popping the next recorded command and comparing headers ([`src/vm/transitions/journal.rs`][core-journal]):

```rust
State::Replaying { ref mut commands, .. } => {
    let actual = commands.pop_front()
        .ok_or(UnavailableEntryError::new(M::ty()))?
        .decode_to::<M>(context.journal.command_index())?;
    let new_state = self.try_transition_to_processing();
    let ignore_payload_equality = should_ignore_payload_equality(
        context.non_deterministic_checks_ignore_payload_equality, options);
    check_entry_header_match(context.journal.command_index(), &actual, &expected,
        ignore_payload_equality)?;
    Ok((new_state, actual))
}
```

What "header" means is per message type, via `CommandMessageHeaderEq::header_eq` ([`src/service_protocol/messages.rs`][core-msgs]): `RunCommandMessage`, `GetLazyState`, `ClearState`, `AttachInvocation` and friends use full structural equality (so a `ctx.run` **name** is part of its identity); `SleepCommandMessage` compares only `name` (the computed `wake_up_time` is expected to differ on every attempt); `CallCommandMessage` compares service, handler, key, headers, idempotency key, scope and completion ids, and the parameter unless payload equality is disabled; `SetStateCommandMessage` compares `name` and `key`, and `value` only when payload checks are on; `InputCommandMessage` compares nothing. Completions are not positional: each command allocates `completion_id`s and a notification is matched by `NotificationId::CompletionId` / `SignalIndex` / `SignalName` ([`crates/types/src/journal_v2/notification.rs`][notif-rs]). There is no hash of arguments and no attempt counter in the key; `retry_count_since_last_stored_entry` is informational and "might get reset in case Restate crashes/changes leader" ([`service-protocol/dev/restate/service/protocol.proto`][proto]).

### 2. Journal versus world

The journal wins, unconditionally. There is no re-observation step: the world is reachable only through `ctx.run`, whose stored result is injected on replay, and any other observation is by definition non-deterministic and must not influence control flow. Disagreement between **code** and journal is detected by the header check above and reported as error code 570, `JOURNAL_MISMATCH` ([`crates/types/src/errors.rs`][errors-rs]), which the invoker renders as ([`crates/invoker-impl/src/error.rs`][invoker-err]):

> Detected journal mismatch. Either some code within the handler is non-deterministic, or the code was updated without registering a new service deployment.

The documented error page lists the canonical causes: branching on "the elapsed time between now and another timestamp, or the result of an HTTP request that was not recorded using the `ctx.run` feature", passing a non-deterministic argument to a context operation, and iterating "a data structure with non-deterministic iteration order" ([`crates/errors/src/error_codes/RT0016.md`][rt0016]). What happens next is configurable per handler: `onJournalMismatchErrors: "retry" | "pause" | "fail"`, where `"pause"` parks the invocation "so it can be inspected and manually resumed once the non-determinism in the code is fixed" ([`packages/libs/restate-sdk/src/types/rpc.ts`][rpc-ts]). Disagreement between the journal and the **external** world (a payment went through but the proposal was lost) is acknowledged as the "small window" of one re-executed `ctx.run` and pushed onto the user: use `ctx.rand.uuidv4()` as an idempotency key and "register the compensation before doing the action, because there is a chance that the action succeeded but that we never got the confirmation" ([`docs/guides/sagas.mdx`][doc-sagas]).

### 3. Determinism enforcement

By **discipline, checked at runtime**. TypeScript offers no language-level barrier; the SDK instead (a) substitutes deterministic sources for the usual offenders (`ctx.rand` seeded per invocation, `ctx.date` as a run, `ctx.console` that "automatically excludes logs during replay") ([`packages/libs/restate-sdk/src/context.ts`][ctx-ts]), (b) forbids context use inside `run` ("You cannot use the Restate context within `ctx.run`") and warns that an un-awaited run "can get interleaved with the other context calls in the journal in a non-deterministic way" ([`docs/develop/ts/journaling-results.mdx`][doc-journaling]), and (c) verifies every command against the journal on every attempt, as in dimension 1. The check is header-shaped, not semantic: payload equality can be switched off globally (`non_deterministic_checks_ignore_payload_equality`) or per call (`PayloadOptions.unstable_serialization`) ([`src/vm/transitions/journal.rs`][core-journal]), so a serializer that is not byte-stable is tolerated rather than rejected. The test harness adds a stress knob, `alwaysReplay`, which sets `RESTATE_WORKER__INVOKER__INACTIVITY_TIMEOUT=0s` so that every suspension point forces a full replay, "useful to hunt non-deterministic bugs" ([`packages/libs/restate-sdk-testcontainers/src/restate_test_environment.ts`][testenv]).

### 4. Compensation and failure handling

There is **no compensation primitive** in the journal or the context. The sagas guide is explicit that it is a user-code pattern: "Track compensations in a list, and execute them on non-transient failures", and, concretely, "wrap your business logic in a try-block ... For each step you do in your try-block, add a compensation to a list. In the catch block, in case of a terminal error, you run the compensations in reverse order, and rethrow the error" ([`docs/guides/sagas.mdx`][doc-sagas]). The reference code is just an array of closures over `ctx.run` ([`code_snippets/ts/src/guides/sagas/booking_workflow.ts`][snip-saga]):

```ts
const compensations = [];
const bookingId = await ctx.run(() => flightClient.reserve(customerId, flight));
compensations.push(() => ctx.run(() => flightClient.cancel(bookingId)));
await ctx.run(() => flightClient.confirm(bookingId));

const paymentId = ctx.rand.uuidv4();
compensations.push(() => ctx.run(() => paymentClient.refund(paymentId)));
await ctx.run(() => paymentClient.charge(paymentInfo, paymentId));
```

Because the compensations themselves go through `ctx.run`, they are journaled and replayed like any step; ordering is LIFO by convention only. Failure classes are two: transient errors are retried "infinitely with an exponential backoff strategy" by default ([`docs/develop/ts/error-handling.mdx`][doc-errors]) and, when a policy caps attempts, the server's `OnMaxAttempts` decides between `Pause` (the default) and `Kill` ([`crates/types/src/config/invocation.rs`][cfg-inv]); `TerminalError` ends the invocation and propagates to the caller. Operator cancellation is implemented as a terminal error delivered at the current await point after cancelling "the leaves of the current invocation, i.e. interrupt ongoing sleeps and awakeables or try to cancel calls to other services", which is precisely what lets a saga's `catch` run; `kill` bypasses that and "immediately stops every call in the call tree" ([`docs/operate/invocation.mdx`][doc-invocation]).

### 5. Versioning against old histories

Restate's answer is **immutable deployments plus pinning**, with no in-code patching API. "Service deployments are considered **immutable** and to be reachable throughout the entire lifecycle of an invocation" ([`docs/deploy/deploy.mdx`][doc-deploy]); a new version is a new `restate deployments register <uri>`, after which "new invocations are always routed to the latest service revision, while old invocations will continue to use the previous deployment", with the caution that "it must be guaranteed that the old deployment lives until all the existing invocations complete" ([`docs/operate/versioning.mdx`][doc-versioning]). The pin is stored per invocation as `PinnedDeployment` ([`crates/types/src/deployment.rs`][deploy-rs]). For a bug that strands in-flight invocations the escape hatch is an in-place update (`PUT /deployments/{id}` to a patched URI), under the rule that "any changes must be from the point of failure onwards" so that already-replayed commands still match ([`docs/operate/versioning.mdx`][doc-versioning]). The journal itself has been "immutable" since protocol V4, and the shared core has a dedicated error for the most common edit, an added `await`: "'await' could not be replayed. This usually means the code was mutated adding an 'await' without registering a new service revision" ([`src/vm/errors.rs`][core-errors]). State compatibility is on the user: virtual-object state "must ensure state entries are evolved in a backward compatible way" ([`docs/operate/versioning.mdx`][doc-versioning]).

### 6. Concurrency under replay

Concurrency is expressed with `RestatePromise.all` / `any` / `race` / `allSettled`, and the docs are firm that the native `Promise` combinators are not deterministic here: "Restate then logs the order in which they are resolved or rejected, to make them deterministic on replay" ([`docs/develop/ts/journaling-results.mdx`][doc-journaling]). Mechanically there is no combinator **command** in protocol V4; the `CombinatorType` enum (`FIRST_COMPLETED`, `ALL_COMPLETED`, `FIRST_SUCCEEDED_OR_ALL_FAILED`, `ALL_SUCCEEDED_OR_FIRST_FAILED`) appears in the `Future` tree that `SuspensionMessage` and `AwaitingOnMessage` carry to describe the await point ([`service-protocol/dev/restate/service/protocol.proto`][proto]), and `CombinatorRestatePromise.unresolvedFuture()` builds that tree from its children ([`packages/libs/restate-sdk/src/promises.ts`][promises-ts]). Determinism comes from the notification **order in the journal**: each child command has its own `completion_id`, the runtime stores completions in the order they arrived, and the protocol requires that a run's `ProposeRunCompletionAckMessage` "is sent in the same order relative to the other notifications" on replay ([`service-protocol/dev/restate/service/protocol.proto`][proto]). Parallel `ctx.run`s are therefore fine: each is registered as its own closure with the `PromisesExecutor` and completes independently. The `Interceptor.run` hook documents the replay boundary for them: it "only fires for runs that actually execute — replayed runs (already in the journal) are skipped" ([`packages/libs/restate-sdk/src/hooks.ts`][hooks-ts]). Combining promises from different contexts is rejected outright ([`packages/libs/restate-sdk/src/promises.ts`][promises-ts]).

### 7. Replay or snapshot

Pure **replay** at the invocation level, with suspension as a first-class outcome: a sleeping or awaiting handler is torn down and re-invoked from `known_entries` when its notification arrives, which is why the docs sell it as "cost savings on FaaS" ([`docs/develop/ts/durable-timers.mdx`][doc-timers]). Replay cost is linear in journal length on every resume; the invoker bounds memory rather than time (each entry is size-peeked and leased from a `LocalMemoryPool` before decoding, [`crates/storage-api/src/journal_table_v2/mod.rs`][jt-rs]). Snapshots exist only one layer down: partition-store snapshots to an object store let processors "skip ahead in the log" and enable log trimming ([`docs/references/architecture.mdx`][doc-arch]); they are a storage-recovery mechanism, not a way to shorten an invocation's replay. What replay rules out is any handler-local state that is not reconstructible from commands: a virtual object's K/V state is sent eagerly in `StartMessage.state_map`, so it is effectively a snapshot alongside the journal ([`service-protocol/dev/restate/service/protocol.proto`][proto]).

### 8. Testing

The supported path is **integration against a real server** via `@restatedev/restate-sdk-testcontainers`: `RestateTestEnvironment.start((server) => server.bind(router))` boots a `docker.io/restatedev/restate` container, registers the test endpoint, and `stateOf(objectDef, key)` returns a typed `StateProxy` to read and mutate virtual-object or workflow state through the admin API ([`packages/libs/restate-sdk-testcontainers/src/restate_test_environment.ts`][testenv], [`docs/develop/ts/testing.mdx`][doc-testing]). Two options target durability specifically: `alwaysReplay` (replay at every suspension point, dimension 3) and `disableRetries`, which sets `RESTATE_DEFAULT_RETRY_POLICY__MAX_ATTEMPTS=1` and `ON_MAX_ATTEMPTS=kill` so "failures surface immediately instead of hanging through retry backoff" ([`packages/libs/restate-sdk-testcontainers/src/restate_test_environment.ts`][testenv]). What is absent: there is no user-facing replayer that feeds a recorded journal to a handler without a server, no crash-injection API, and no "mutate the world between attempts" hook; the deterministic tests live below the SDK, in the shared core's own suite (`src/tests/run.rs`, `sleep.rs`, `suspensions.rs`, ...) which drives the VM with hand-built protocol messages ([`sdk-shared-core` tree at `v7.0.3`][core-tree]). The wasm bindings carry that VM into TypeScript but expose no test double for it ([`sdk-shared-core-wasm-bindings/src/lib.rs`][wasm-lib]).

### 9. Journal integrity and the single writer

Restate's integrity story is a log-replication story: the journal is state
derived from a replicated log, and the guard is leadership of the partition that
owns it.

**A leader epoch fences the partition.** `LeaderEpoch` is a monotonic counter with
an `INVALID` zero and an `INITIAL` one, advanced by `next()`
([`identifiers.rs`][ids-rs]). Messages a partition produces can be deduplicated
either independently of leadership or against it, and the two cases are named in
the storage API: `Sn` is _"Sequence number to deduplicate messages … independent
of the sender's leader epoch"_, while `Esn` carries an `EpochSequenceNumber` and
is used _"to deduplicate messages being produced during a given leader epoch and
fence off messages coming from an older leader epoch"_
([`deduplication_table/mod.rs`][dedup-rs]). That is a fencing token in the
textbook sense, and it is applied to inter-partition traffic rather than to
individual journal appends.

**The journal is not appended by the SDK at all.** The SDK proposes commands and
the partition processor decides, applies them to the partition store, and streams
the resulting journal back on the next attempt. There is therefore no
client-visible expected-version check: the ordering guarantee comes from the log,
and a losing writer is a deposed leader rather than a rejected append.

**Torn writes are the storage engine's problem**, not the protocol's. The journal
lives in RocksDB column families inside the partition store, so a half-written
record is not a case the journal format has to describe — which is the same
delegation Effect makes to SQL, reached by a different route.

**Duplicate submissions are deduplicated by idempotency key**, with a retention
period, and the resulting behaviour is a lookup that returns the original
invocation's result rather than a second execution.

**The one integrity check the SDK does perform is the journal-versus-code
comparison** (§1, §2): each replayed command's header is compared with what the
code now asks for, and a mismatch is `JOURNAL_MISMATCH` (RT0016). It protects
against the program diverging, not against two writers.

### 10. Operator recovery and intervention

Restate has the broadest command-line surface in the survey, and its verbs are
distinct operations with different consequences rather than aliases.

**Six operations on a live invocation** ship as first-class CLI commands:
`cancel`, `kill`, `pause`, `resume`, `purge` and `restart-as-new`
([`kill.rs`][cli-kill], [`pause.rs`][cli-pause], [`purge.rs`][cli-purge],
[`restart_as_new.rs`][cli-restart]). Each accepts an invocation id or a target
prefix, so an operator can act on one invocation or on every invocation of a
handler.

**Cancel and kill differ in whether compensation runs.** Cancellation delivers a
terminal error at the invocation's current await point, so the handler's `catch`
blocks — which is where sagas live (§4) — execute. Kill stops the invocation
without giving it that turn, and therefore skips compensation entirely. A tool
that offers only one of these has made the choice for its users.

**Pause and resume make "stopped, on purpose" a state.** This pairs with the
per-handler mismatch policy, whose `pause` option parks an invocation whose code
no longer matches its journal instead of failing it — so the operator's fix is to
deploy corrected code and resume, with the journal intact.

**`restart-as-new` is the fork affordance**, replaying the invocation as a fresh
one rather than resuming the old journal.

**Inspection is SQL.** The CLI's invocation listing and `describe` are queries
over a DataFusion view of the partition stores, so an operator can filter
invocations by status, target or age with a query rather than an API call.

**`purge` removes a completed invocation's record**, which is the retention lever
as well as the "forget this ever happened" lever.

**What is not offered:** editing a journal entry's recorded value. The supported
moves are re-run everything (`restart-as-new`), stop (`cancel`/`kill`), or wait
for a fix (`pause`).

### 11. Suspension and external input

Suspension is a protocol message, and it carries the most structural description
of a wait in the survey.

**Suspending is explicit and describes the await point.** _"Implementations MUST
send this message when suspending an invocation"_, and the message's payload is a
`Future` tree: `waiting_completions`, `waiting_signals`, `waiting_named_signals`,
`nested_futures` and a `combinator_type` ([`protocol.proto`][proto]). So the
runtime learns not merely that the handler is blocked but the shape of what it is
blocked on, including combinators over several waits. Nothing else surveyed tells
the runtime that much.

**The process genuinely ends.** After suspending, the SDK's handler invocation
returns; the runtime re-invokes it and replays the journal when one of the
awaited things arrives. There is no threshold and no held connection, which is
what lets a handler wait for weeks on a serverless deployment.

**The primitives** are `ctx.sleep` (a journaled timer), awakeables (a
runtime-minted id the handler hands out and an external party completes),
workflow promises (`ctx.promise`, named and durable per workflow), and calls to
other handlers, which suspend the caller until the callee completes.

**External input is addressed by an explicit token or a name.** An awakeable id is
handed out by the handler; a workflow promise is addressed by name within the
workflow's key. A completion that arrives before the handler awaits is already in
the journal when it gets there; one that arrives twice is a duplicate
notification for a `completion_id` that is already settled; one that never
arrives leaves the invocation suspended until something else — a timeout the
handler itself raced, or an operator — ends it.

**Human-in-the-loop is the awakeable's primary use case**, and the fact that the
token is a value the handler can put in an email or a webhook payload is what
makes it one.

---

## Strengths

- **One state machine, many languages.** The replay/verify logic is written once in Rust (`restate-sdk-shared-core`) and reused by the TypeScript SDK through WebAssembly, so mismatch semantics cannot drift between SDKs ([`sdk-shared-core-wasm-bindings/Cargo.toml`][wasm-cargo]).
- **The journal is a real log, not a table of results.** Commands and notifications are separate entries with explicit `completion_id` correlation, which is what makes concurrent completions replayable without a combinator entry.
- **Honest exactly-once boundary.** The `run` docstring states the one-re-execution window instead of hiding it, and the sagas guide builds its idempotency advice on that statement.
- **Suspension is cheap and first-class.** Sleeps, awakeables and durable promises release the process; the server owns the timers.
- **Operational levers for the failure case.** `pause` on mismatch or on max attempts, in-place deployment patching, cancel-versus-kill, and per-handler retry policy.

## Weaknesses

- **Positional identity is brittle.** Inserting or reordering any context call ahead of an in-flight invocation's frontier is a `JOURNAL_MISMATCH`; the only remedies are a new deployment or an in-place patch that preserves all completed paths.
- **No compensation model in the engine.** Sagas are a list-of-closures convention; nothing enforces LIFO order, registration-before-action, or idempotency of the undo.
- **No re-observation of the world.** The design has no notion of "observe again and reconcile": a `ctx.run` result is truth forever, even for facts (a git tag, a HEAD) that are cheap to re-read.
- **Header checks are partial by design.** `Sleep` compares only its name and payload checks are optional, so some classes of non-determinism pass silently.
- **Testing is container-only.** No journal replayer, no crash-at-index harness at the SDK level; the server must run for any durability test.
- **Licensing split.** The server is BUSL-1.1; only the SDKs and the protocol are MIT.

## Key design decisions and trade-offs

| Decision                                                              | Rationale                                                                  | Trade-off                                                                                         |
| --------------------------------------------------------------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Positional command matching with per-type `header_eq`                 | Zero annotation burden; ordinary code is the workflow                      | Any control-flow edit before the frontier is a mismatch; no patching API                          |
| Commands and notifications as separate entries keyed by completion id | Concurrent awaits replay by notification order, no combinator entry needed | The SDK must reproduce the exact relative order of run acks versus other notifications            |
| `ctx.run` results are proposed, then confirmed by a notification      | Exactly one durable write path; the ack doubles as the replayed completion | A one-re-execution window that the user must close with idempotency keys                          |
| Immutable deployments pinned per invocation                           | Old journals always replay against the code that wrote them                | Old deployments must stay alive until drained; long workflows pin old code for months             |
| Suspension instead of blocking                                        | FaaS-friendly; server-owned timers survive process death                   | Every resume is a full replay; cost grows with journal length                                     |
| Shared Rust core compiled to wasm for every SDK                       | Mismatch and protocol semantics identical across languages                 | A wasm boundary in every context call; SDK-level tests cannot see inside the VM                   |
| Bifrost WAL under RocksDB partition stores                            | Every journal write is a committed log record before it is acted on        | Operational surface of a distributed log (loglets, sealing, snapshots) for a single-node user too |

---

## Implications for a durable-execution library

- **Separating matching from checking is the right factoring.** Restate finds a
  recorded entry by position and then compares its header, per command type, with
  computed fields deliberately excluded (§1). Keying on a hash conflates two jobs;
  keeping them apart lets the library report drift without changing which entry it
  matched.
- **A mismatch deserves more than one outcome.** `retry`, `pause` and `fail` are
  configurable per handler (§2), and `pause` is the interesting one: it parks the
  invocation with its journal intact so the fix is to deploy corrected code and
  resume. A library with a single "fail" has thrown that recovery away.
- **Describing the await point structurally is a better protocol than signalling
  "blocked".** The suspension message carries a tree of what is awaited, including
  combinators (§11), so the runtime can decide what to watch for. This is the most
  informative wait description in the survey and costs one message type.
- **Cancel and kill must be separate verbs** (§10), because one runs the handler's
  compensation and the other does not. Restate makes the distinction at the
  command line, where the operator can see it.
- **Epoch-fenced deduplication is how a log-replicated system stays single-writer**
  (§9): a sequence number qualified by the producer's leader epoch, so a deposed
  leader's messages are recognised and dropped. A library over a plain file needs
  the same idea in whatever form its storage allows.
- **Pinning a deployment per invocation trades evolution for safety.** Immutable
  deployments mean an in-flight program never meets new code, and the cost is that
  old code must be kept alive as long as any invocation might resume into it (§5).
- **Suspension without a threshold is achievable, and worth it.** Every wait ends
  the invocation, short or long, so there is no second code path for "brief
  waits" to get wrong.
- **Testing against a real server rather than a mock** (§8) buys fidelity and
  costs speed, and Restate's `alwaysReplay` knob shows the useful middle: force
  the replay path on every step so the expensive case is the one under test.

---

## Sources

- [restatedev/restate — GitHub repository][repo-server]
- [restatedev/sdk-typescript — GitHub repository][repo-sdk]
- [restatedev/sdk-shared-core — GitHub repository][repo-core]
- [restatedev/service-protocol — GitHub repository][repo-proto]
- [`service-protocol/dev/restate/service/protocol.proto` — `StartMessage`, `Future`/`CombinatorType`, `ProposeRunCompletionMessage`, the commands-and-notifications model][proto]
- [`crates/types/src/journal_v2/command.rs` — the `Command` enum and every command struct][cmd-rs]
- [`crates/types/src/journal_v2/notification.rs` — `Notification`, `Completion`, `NotificationId`][notif-rs]
- [`crates/types/src/journal_v2/mod.rs` — `Entry`, `EntryType`][journal-mod]
- [`crates/types/src/errors.rs` — `JOURNAL_MISMATCH 570`][errors-rs]
- [`crates/errors/src/error_codes/RT0016.md` — the journal-mismatch error page][rt0016]
- [`crates/invoker-impl/src/error.rs` — the mismatch message the invoker logs][invoker-err]
- [`crates/invoker-impl/src/invocation_task/service_protocol_runner_v4.rs` — the replay phase and `replay_loop`][runner]
- [`crates/storage-api/src/journal_table_v2/mod.rs` — `ReadJournalTable`][jt-rs]
- [`crates/bifrost/src/lib.rs` and `crates/bifrost/src/loglet.rs` — Bifrost and the loglet contract][bifrost-lib]
- [`crates/types/src/deployment.rs` — `PinnedDeployment`][deploy-rs]
- [`crates/types/src/config/worker.rs` — `inactivity_timeout`][cfg-worker]
- [`crates/types/src/config/invocation.rs` — `OnMaxAttempts`][cfg-inv]
- [`packages/libs/restate-sdk/src/context.ts` — `Context`, `RunOptions`, the `run` docstring][ctx-ts]
- [`packages/libs/restate-sdk/src/context_impl.ts` — `run`, `sleep`, `awakeable`, `date`][ctx-impl]
- [`packages/libs/restate-sdk/src/promises.ts` — `RestatePromise` combinators and `unresolvedFuture`][promises-ts]
- [`packages/libs/restate-sdk/src/hooks.ts` — `Interceptor.run`][hooks-ts]
- [`packages/libs/restate-sdk/src/types/rpc.ts` — `onJournalMismatchErrors`][rpc-ts]
- [`packages/libs/restate-sdk/src/utils/rand.ts` — seeded `xoshiro256++`][rand-ts]
- [`packages/libs/restate-sdk/src/endpoint/handlers/generic.ts` — `bufferJournalReplayInCoreVm`][generic-ts]
- [`packages/libs/restate-sdk-testcontainers/src/restate_test_environment.ts` — `RestateTestEnvironment`, `alwaysReplay`, `disableRetries`][testenv]
- [`sdk-shared-core-wasm-bindings/src/lib.rs` and `Cargo.toml` — the wasm surface over the shared core][wasm-lib]
- [`src/vm/mod.rs` (shared core `v7.0.3`) — the `State` machine][core-vm]
- [`src/vm/transitions/journal.rs` (shared core `v7.0.3`) — `PopJournalEntry`, `check_entry_header_match`][core-journal]
- [`src/service_protocol/messages.rs` (shared core `v7.0.3`) — `CommandMessageHeaderEq`][core-msgs]
- [`src/vm/errors.rs` (shared core `v7.0.3`) — `CommandMismatchError`, `UncompletedDoProgressDuringReplay`][core-errors]
- [`docs/concepts/durable_execution.mdx`][doc-de] · [`docs/concepts/durable_building_blocks.mdx`][doc-blocks] · [`docs/concepts/services.mdx`][doc-services] · [`docs/references/architecture.mdx`][doc-arch]
- [`docs/develop/ts/journaling-results.mdx`][doc-journaling] · [`docs/develop/ts/durable-timers.mdx`][doc-timers] · [`docs/develop/ts/awakeables.mdx`][doc-awakeables] · [`docs/develop/ts/workflows.mdx`][doc-workflows] · [`docs/develop/ts/error-handling.mdx`][doc-errors] · [`docs/develop/ts/testing.mdx`][doc-testing]
- [`docs/guides/sagas.mdx`][doc-sagas] · [`docs/operate/versioning.mdx`][doc-versioning] · [`docs/deploy/deploy.mdx`][doc-deploy] · [`docs/operate/invocation.mdx`][doc-invocation] · [`docs/invoke/http.mdx`][doc-http]
- [`code_snippets/ts/src/guides/sagas/booking_workflow.ts`][snip-saga] · [`code_snippets/ts/src/develop/workflows/signup.ts`][snip-signup]
- Related: [Temporal][temporal] · [Catalog index][index] · [Effect (TypeScript)][effect] · [Comparison][comparison]

<!-- References -->

[repo-server]: https://github.com/restatedev/restate
[repo-sdk]: https://github.com/restatedev/sdk-typescript
[repo-core]: https://github.com/restatedev/sdk-shared-core
[repo-proto]: https://github.com/restatedev/service-protocol
[docs]: https://docs.restate.dev/
[docs-sagas]: https://docs.restate.dev/guides/sagas
[docs-versioning]: https://docs.restate.dev/operate/versioning
[proto]: https://github.com/restatedev/restate/blob/fbead57b941912ae0095027ce1795b36917131c2/service-protocol/dev/restate/service/protocol.proto
[cmd-rs]: https://github.com/restatedev/restate/blob/fbead57b941912ae0095027ce1795b36917131c2/crates/types/src/journal_v2/command.rs
[notif-rs]: https://github.com/restatedev/restate/blob/fbead57b941912ae0095027ce1795b36917131c2/crates/types/src/journal_v2/notification.rs
[journal-mod]: https://github.com/restatedev/restate/blob/fbead57b941912ae0095027ce1795b36917131c2/crates/types/src/journal_v2/mod.rs
[errors-rs]: https://github.com/restatedev/restate/blob/fbead57b941912ae0095027ce1795b36917131c2/crates/types/src/errors.rs
[rt0016]: https://github.com/restatedev/restate/blob/fbead57b941912ae0095027ce1795b36917131c2/crates/errors/src/error_codes/RT0016.md
[invoker-err]: https://github.com/restatedev/restate/blob/fbead57b941912ae0095027ce1795b36917131c2/crates/invoker-impl/src/error.rs
[runner]: https://github.com/restatedev/restate/blob/fbead57b941912ae0095027ce1795b36917131c2/crates/invoker-impl/src/invocation_task/service_protocol_runner_v4.rs
[jt-rs]: https://github.com/restatedev/restate/blob/fbead57b941912ae0095027ce1795b36917131c2/crates/storage-api/src/journal_table_v2/mod.rs
[bifrost-lib]: https://github.com/restatedev/restate/blob/fbead57b941912ae0095027ce1795b36917131c2/crates/bifrost/src/lib.rs
[loglet-rs]: https://github.com/restatedev/restate/blob/fbead57b941912ae0095027ce1795b36917131c2/crates/bifrost/src/loglet.rs
[deploy-rs]: https://github.com/restatedev/restate/blob/fbead57b941912ae0095027ce1795b36917131c2/crates/types/src/deployment.rs
[ids-rs]: https://github.com/restatedev/restate/blob/fbead57b941912ae0095027ce1795b36917131c2/crates/types/src/identifiers.rs
[cfg-worker]: https://github.com/restatedev/restate/blob/fbead57b941912ae0095027ce1795b36917131c2/crates/types/src/config/worker.rs
[cfg-inv]: https://github.com/restatedev/restate/blob/fbead57b941912ae0095027ce1795b36917131c2/crates/types/src/config/invocation.rs
[ctx-ts]: https://github.com/restatedev/sdk-typescript/blob/6879b36b6774c580c8dad9812cc6088150909dae/packages/libs/restate-sdk/src/context.ts
[ctx-impl]: https://github.com/restatedev/sdk-typescript/blob/6879b36b6774c580c8dad9812cc6088150909dae/packages/libs/restate-sdk/src/context_impl.ts
[promises-ts]: https://github.com/restatedev/sdk-typescript/blob/6879b36b6774c580c8dad9812cc6088150909dae/packages/libs/restate-sdk/src/promises.ts
[hooks-ts]: https://github.com/restatedev/sdk-typescript/blob/6879b36b6774c580c8dad9812cc6088150909dae/packages/libs/restate-sdk/src/hooks.ts
[rpc-ts]: https://github.com/restatedev/sdk-typescript/blob/6879b36b6774c580c8dad9812cc6088150909dae/packages/libs/restate-sdk/src/types/rpc.ts
[rand-ts]: https://github.com/restatedev/sdk-typescript/blob/6879b36b6774c580c8dad9812cc6088150909dae/packages/libs/restate-sdk/src/utils/rand.ts
[generic-ts]: https://github.com/restatedev/sdk-typescript/blob/6879b36b6774c580c8dad9812cc6088150909dae/packages/libs/restate-sdk/src/endpoint/handlers/generic.ts
[testenv]: https://github.com/restatedev/sdk-typescript/blob/6879b36b6774c580c8dad9812cc6088150909dae/packages/libs/restate-sdk-testcontainers/src/restate_test_environment.ts
[wasm-lib]: https://github.com/restatedev/sdk-typescript/blob/6879b36b6774c580c8dad9812cc6088150909dae/sdk-shared-core-wasm-bindings/src/lib.rs
[wasm-cargo]: https://github.com/restatedev/sdk-typescript/blob/6879b36b6774c580c8dad9812cc6088150909dae/sdk-shared-core-wasm-bindings/Cargo.toml
[core-tree]: https://github.com/restatedev/sdk-shared-core/tree/bcdf52777955b36bed611483abd227db03b9a09c/src/tests
[core-vm]: https://github.com/restatedev/sdk-shared-core/blob/bcdf52777955b36bed611483abd227db03b9a09c/src/vm/mod.rs
[core-journal]: https://github.com/restatedev/sdk-shared-core/blob/bcdf52777955b36bed611483abd227db03b9a09c/src/vm/transitions/journal.rs
[core-msgs]: https://github.com/restatedev/sdk-shared-core/blob/bcdf52777955b36bed611483abd227db03b9a09c/src/service_protocol/messages.rs
[core-errors]: https://github.com/restatedev/sdk-shared-core/blob/bcdf52777955b36bed611483abd227db03b9a09c/src/vm/errors.rs
[doc-de]: https://github.com/restatedev/documentation/blob/de0378c9d7e6499cde94ac743f460161900b1e4c/docs/concepts/durable_execution.mdx
[doc-blocks]: https://github.com/restatedev/documentation/blob/de0378c9d7e6499cde94ac743f460161900b1e4c/docs/concepts/durable_building_blocks.mdx
[doc-services]: https://github.com/restatedev/documentation/blob/de0378c9d7e6499cde94ac743f460161900b1e4c/docs/concepts/services.mdx
[doc-arch]: https://github.com/restatedev/documentation/blob/de0378c9d7e6499cde94ac743f460161900b1e4c/docs/references/architecture.mdx
[doc-journaling]: https://github.com/restatedev/documentation/blob/de0378c9d7e6499cde94ac743f460161900b1e4c/docs/develop/ts/journaling-results.mdx
[doc-timers]: https://github.com/restatedev/documentation/blob/de0378c9d7e6499cde94ac743f460161900b1e4c/docs/develop/ts/durable-timers.mdx
[doc-awakeables]: https://github.com/restatedev/documentation/blob/de0378c9d7e6499cde94ac743f460161900b1e4c/docs/develop/ts/awakeables.mdx
[doc-workflows]: https://github.com/restatedev/documentation/blob/de0378c9d7e6499cde94ac743f460161900b1e4c/docs/develop/ts/workflows.mdx
[doc-errors]: https://github.com/restatedev/documentation/blob/de0378c9d7e6499cde94ac743f460161900b1e4c/docs/develop/ts/error-handling.mdx
[doc-testing]: https://github.com/restatedev/documentation/blob/de0378c9d7e6499cde94ac743f460161900b1e4c/docs/develop/ts/testing.mdx
[doc-sagas]: https://github.com/restatedev/documentation/blob/de0378c9d7e6499cde94ac743f460161900b1e4c/docs/guides/sagas.mdx
[doc-versioning]: https://github.com/restatedev/documentation/blob/de0378c9d7e6499cde94ac743f460161900b1e4c/docs/operate/versioning.mdx
[doc-deploy]: https://github.com/restatedev/documentation/blob/de0378c9d7e6499cde94ac743f460161900b1e4c/docs/deploy/deploy.mdx
[doc-invocation]: https://github.com/restatedev/documentation/blob/de0378c9d7e6499cde94ac743f460161900b1e4c/docs/operate/invocation.mdx
[doc-http]: https://github.com/restatedev/documentation/blob/de0378c9d7e6499cde94ac743f460161900b1e4c/docs/invoke/http.mdx
[snip-saga]: https://github.com/restatedev/documentation/blob/de0378c9d7e6499cde94ac743f460161900b1e4c/code_snippets/ts/src/guides/sagas/booking_workflow.ts
[snip-signup]: https://github.com/restatedev/documentation/blob/de0378c9d7e6499cde94ac743f460161900b1e4c/code_snippets/ts/src/develop/workflows/signup.ts
[temporal]: ./temporal.md
[index]: ./index.md
[effect]: ../typescript-effect.md
[comparison]: ./comparison.md
[cli-kill]: https://github.com/restatedev/restate/blob/fbead57b941912ae0095027ce1795b36917131c2/cli/src/commands/invocations/kill.rs
[cli-pause]: https://github.com/restatedev/restate/blob/fbead57b941912ae0095027ce1795b36917131c2/cli/src/commands/invocations/pause.rs
[cli-purge]: https://github.com/restatedev/restate/blob/fbead57b941912ae0095027ce1795b36917131c2/cli/src/commands/invocations/purge.rs
[cli-restart]: https://github.com/restatedev/restate/blob/fbead57b941912ae0095027ce1795b36917131c2/cli/src/commands/invocations/restart_as_new.rs
[dedup-rs]: https://github.com/restatedev/restate/blob/fbead57b941912ae0095027ce1795b36917131c2/crates/storage-api/src/deduplication_table/mod.rs
