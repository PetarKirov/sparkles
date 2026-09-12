# Resonate (Durable Promises)

A durable-execution platform whose entire state model is one primitive — a _durable promise_ with a caller-chosen id — and whose SDKs turn an ordinary `async` function into a tree of such promises, so a crashed execution is resumed by re-running the function and reading settled promises back instead of re-executing them.

| Field             | Value                                                                                                                                                                                                                           |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | Server: Rust (a rewrite of the earlier Go server, now archived as `resonate-legacy-server`). SDKs: TypeScript (surveyed here), Python, Rust, Go, Java                                                                           |
| License           | Apache-2.0 (server, SDK, specification)                                                                                                                                                                                         |
| Repository        | [resonatehq/resonate][repo] (server) · [resonatehq/resonate-sdk-ts][repo-sdk] · [resonatehq/resonate-specification][repo-spec-lean] (Lean 4) · [resonatehq/durable-promise-specification][repo-dps] (archived stub)             |
| Documentation     | [docs.resonatehq.io][docs] · [distributed-async-await.io specification][daa-spec-dp]                                                                                                                                            |
| Category          | durable-execution engine + durable-execution SDK                                                                                                                                                                                |
| Persistence model | replay (function re-runs from the top; each step dedups against its promise)                                                                                                                                                    |
| Journal store     | A `promises` table in SQLite / Postgres / MySQL / ScyllaDB / blob storage (one row per promise, the task folded into the same row); no event log — the journal _is_ the set of promise rows                                     |
| Latest release    | Server `v0.9.8` (June 4, 2026; `Cargo.toml` at HEAD says `0.10.1`). SDK `v0.11.5` (September 3, 2026)                                                                                                                           |
| Local clone       | `$REPOS/resonate` at `33c7a3f460fc10690b71aad77b06b15ecbc9b7b3` · `$REPOS/resonate-sdk-ts` at `a3a3ccf3f92c636afcf51d4f10c4ad44d2b5399b` · `$REPOS/durable-promise-specification` at `8b0d401a72ce3a2790f458c9ee6d9ebcd7519f4b` |

**Last reviewed:** September 12, 2026.

> **A note on sources.** The `durable-promise-specification` clone is now a one-page stub: its `Readme.md` says the spec _"has been folded into the broader Distributed Async Await Specification"_ and that the repository _"is preserved for historical reference"_ ([`Readme.md`][dps-readme]). The canonical text lives in the `distributed-async-await.io` site repository, cited below at commit `baee8c0577095e1db6fe683c381bd7e220a30b26`; the machine-checked model is the Lean 4 repository at `6b120adc47a45f5b2e796fede1ae6b245e1a6d66`. The server clone is the Rust rewrite; the Go server with its `test/dst` suite lives on in `resonatehq/resonate-legacy-server`, cited at `f4153f76f22277f3da55b5de7cb222c4cd66ef06`.

---

## Overview

### What it solves

Every durable-execution system needs a way to say "this step already happened, here is its result". Temporal answers with an event history; DBOS with a step table keyed by workflow id and step number. Resonate collapses the whole answer into one object. From the stub spec ([`Readme.md`][dps-readme]):

> _"A Durable Promise is a language-agnostic, persistent representation of an asynchronous computation. Unlike an in-memory promise or future, a Durable Promise survives process crashes, restarts, and network partitions — its state is stored externally and can be observed or completed by any process that holds its identifier."_

and it exists because _"Existing primitives (OS threads, language-level promises, message queues) either do not survive failures or require significant infrastructure to make durable."_ The three guarantees the stub lists are the whole contract: the promise _"Persists its state (pending, resolved, rejected) independently of any single process"_, _"Allows multiple callers to await the same computation without duplicating work (idempotent creation)"_, and _"Can be completed by any process — not just the one that created it"_.

Everything else — durable functions, RPC between workers, sleeps, human-in-the-loop, cron schedules — is built by giving something a promise id. A function invocation is a promise whose `param` carries `{func, args, version}`; a sleep is a promise tagged `resonate:timer` whose deadline resolves it; a human approval is a promise with no function behind it, settled by an out-of-band `promise.settle`.

### Design philosophy

The canonical spec frames promises as the coordination primitive first and the recovery primitive second ([`durable-promise-specification.mdx`][daa-spec-dp]):

> _"Promises are **fundamental units of coordination**. Distributed Async Await proposes Durable Promises — promises that persist in storage and enable coordination across process boundaries."_
>
> _"Within the Distributed Async Await specification, each execution — whether a function execution or an action taking place in the physical world — pairs to a promise."_

"Distributed async await" is the name Resonate gives to the resulting programming model: `await` on a durable promise may cross a process boundary, a machine boundary, or a crash. The durable-function spec states the correctness claim as an equivalence ([`durable-function-specification.mdx`][daa-spec-df]):

> _"A program `p` is interruption-tolerant if, starting from an initial configuration `⟨p⟩`, an execution in the presence of interruptions `(⟨p⟩, →(+interruption))` is equivalent to some execution in the absence of interruptions `(⟨p⟩, →(-interruption))`."_

with three preconditions on the function: determinism, idempotency, and _"Activation lifetime"_ — _"A function execution cannot outlive the physical process that hosts it."_ The server's own README adds the engineering stance ([`README.md`][srv-readme]): _"Durable by construction. Promises, tasks, and schedules are persisted before they are acted on. A crash mid-flight is a resume, not a loss."_ and _"Formally specified. The protocol has a machine-checked specification … with mechanized invariants — not a prose document that drifted."_

---

## How it works

### The promise record and its state machine

The wire record is `PromiseRecord` in the server ([`crates/resonate-core/src/types.rs`][srv-types]):

```rust
pub enum PromiseState { Pending, Resolved, Rejected, RejectedCanceled, RejectedTimedout }

pub struct PromiseRecord {
    pub id: String,
    pub state: PromiseState,
    pub param: PromiseValue,   // { headers?, data? }  — the input
    pub value: PromiseValue,   // the settled output
    pub tags: HashMap<String, String>,
    pub timeout_at: i64,
    pub created_at: i64,
    pub settled_at: Option<i64>,
}
```

`Pending` is the only non-terminal state. A settle request carries one of `resolved | rejected | rejected_canceled` (`SettleState`); `rejected_timedout` is server-owned and is written only when `timeout_at` passes. The spec's canonical state table is written over `(id, ikc, iku)` — an idempotency key for create and one for complete — with a `strict` flag, and enumerates well over a hundred transitions such as row 35, _"Pending(id, ikc, -) | Create(id, ikc, T) | Pending(id, ikc, -) | OK, Deduplicated"_ ([`durable-promise-specification.mdx`][daa-spec-dp]). The same page then says the idempotency keys and `strict` are _"surface the Lean 4 abstract machine … does not model"_ and that _"Where this page and the Lean model overlap and disagree, the Lean model wins."_ The Rust server follows the Lean model: there is no idempotency-key field anywhere in `types.rs`, and create is an `INSERT OR IGNORE` on the id alone ([`crates/resonate-server-sqlite/src/lib.rs`][srv-sqlite]):

```rust
// Idempotent insert
let inserted = self.conn.execute(
    "INSERT OR IGNORE INTO promises (id, state, param_headers, param_data, tags, timeout_at, created_at, settled_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)", …)?;
let was_created = inserted > 0;
```

A duplicate create returns `200` with the existing row, whatever its `param` says; the Lean handler is the same shape — `match ← readObject req.id now with | some o => return { status := 200, promise := … }` ([`spec/02-abstract/external.lean`][lean-external]). A settle on an already-settled promise likewise returns `200` with the existing record and changes nothing.

**Timeouts** are a property of the promise, not of a task. `timeout_at` is absolute; a promise created with `now >= timeout_at` is born `rejected_timedout` (or `resolved`, if it is a timer), and every operation on an id first calls `try_timeout`, which settles any expired pending promise in the touched set before the operation proceeds ([`crates/resonate-server-sqlite/src/lib.rs`][srv-sqlite]). So a timeout is never a background race: it is applied lazily on first touch and eagerly by a sweep only for promises that carry a task.

### Storage: one row per promise, task folded in

The schema is one migration per backend, and the Postgres one explains itself ([`crates/resonate-server-postgres/migrations/0001_initial.sql`][srv-pg-mig]):

> _"One promise is one row. Beside it sits only `schedules` — a separate id space and a genuinely different entity. Replaces the eight tables of the multi-table backend: promises, promise_timeouts, tasks, task_timeouts, callbacks, listeners, outgoing_execute, outgoing_unblock … There is no outbox either. A message is returned by the transition that emitted it and delivered by the caller, so there is nothing to store and nothing to drain."_

The SQLite shape ([`crates/resonate-server-sqlite/migrations/0001_initial.sql`][srv-sqlite-mig]):

```sql
CREATE TABLE IF NOT EXISTS promises (
  id TEXT PRIMARY KEY,
  state TEXT NOT NULL DEFAULT 'pending'
    CHECK (state IN ('pending', 'resolved', 'rejected', 'rejected_canceled', 'rejected_timedout')),
  param_headers TEXT, param_data TEXT, value_headers TEXT, value_data TEXT,
  tags TEXT NOT NULL DEFAULT '{}',
  target    TEXT GENERATED ALWAYS AS (json_extract(tags, '$.resonate:target')) STORED,
  origin_id TEXT GENERATED ALWAYS AS (CASE WHEN instr(id, ':') > 0 THEN substr(id, 1, instr(id, ':') - 1) ELSE id END) STORED,
  parent_id TEXT GENERATED ALWAYS AS (json_extract(tags, '$.resonate:parent')) STORED,
  branch_id TEXT GENERATED ALWAYS AS (json_extract(tags, '$.resonate:branch')) STORED,
  is_timer  BOOLEAN NOT NULL GENERATED ALWAYS AS (COALESCE(json_extract(tags, '$.resonate:timer'), '') = 'true') STORED,
  timeout_at BIGINT NOT NULL, created_at BIGINT NOT NULL, settled_at BIGINT,
  -- was the `tasks` table. NULL task_state means this promise has no task
  task_state TEXT CHECK (task_state IS NULL OR task_state IN ('pending', 'acquired', 'suspended', 'halted', 'fulfilled')),
  task_version INT NOT NULL DEFAULT 0,
  retry_timeout_at BIGINT, lease_timeout_at BIGINT, ttl BIGINT, pid TEXT
);
CREATE TABLE IF NOT EXISTS callbacks (awaited_id TEXT …, awaiter_id TEXT …, ready BOOLEAN …, PRIMARY KEY (awaited_id, awaiter_id));
CREATE TABLE IF NOT EXISTS listeners (promise_id TEXT …, address TEXT …, PRIMARY KEY (promise_id, address));
CREATE TABLE IF NOT EXISTS schedules (id TEXT PRIMARY KEY, cron TEXT NOT NULL, promise_id TEXT NOT NULL, …, next_run_at BIGINT NOT NULL, last_run_at BIGINT);
```

The Postgres file goes further and installs the Lean catalogue's invariants as `CHECK` constraints named after the catalogue entries — `consistent_task_iff_targeted_promise`, `well_formed_promise_settled_at_iff_not_pending`, `well_formed_task_acquired_iff_has_pid`, and dozens more — so that _"a database carrying the tables carries the constraints too and there is no configuration under which the server runs without them"_ ([`0001_initial.sql`][srv-pg-mig]). Both files also note the migration set is deliberately _"Edited in place, not followed by a 0002"_ until release.

### The id tree: how a function becomes promises

A root promise id is chosen by the caller (`resonate.run("greet-001", greet, "Bob")`). Everything below is minted by the SDK. The rule lives in one file ([`src/ids.ts`][sdk-ids]):

> _"The server treats a promise id as `<origin>:<lineage>`: the **origin** is everything before the first `:`, and the lineage segments below it are `.`-separated: `root -> root:1 -> root:1.1 -> root:1.1.1`"_

```ts
export function joinId(ancestor: string, segment: string): string {
  const sep = ancestor.includes(ORIGIN_SEP) ? LINEAGE_SEP : ORIGIN_SEP;
  return `${ancestor}${sep}${segment}`;
}
```

Each context carries a sequence counter; every durable call takes the next number ([`src/async/context.ts`][sdk-actx]):

```ts
const idChanged = opts.id !== undefined;
const id = idChanged ? (opts.id as string) : this.seqid(); // seqid() = joinId(this.id, `${this.seq}`)
this.seq++;
```

So the _n_-th durable call made by the invocation `root:1` is `root:1.n`, regardless of what it calls. The server enforces the tree: `promise.create` rejects an id that does not extend its declared `resonate:origin` / `resonate:branch` / `resonate:parent` tags, with the same `:`/`.` separator rule ([`crates/resonate-core/src/types.rs`][srv-types], `validate_promise_create_data`). Colons are reserved: a root id may not contain one (`validateRootId`), because the origin is recovered by splitting on the first `:`.

The generator engine (`src/context.ts`) exposes the four primitive call shapes, with `run`/`rpc`/`beginRun`/`beginRpc` as aliases ([`src/context.ts`][sdk-gctx]):

| Primitive | Alias      | Where it runs           | Await       | Promise tags                                              |
| --------- | ---------- | ----------------------- | ----------- | --------------------------------------------------------- |
| `lfi`     | `beginRun` | this process            | later       | `resonate:scope=local`, parent/branch/origin              |
| `lfc`     | `run`      | this process            | immediately | same                                                      |
| `rfi`     | `beginRpc` | any worker for `target` | later       | `resonate:scope=global`, `resonate:target`, branch = self |
| `rfc`     | `rpc`      | any worker for `target` | immediately | same                                                      |

The async engine (`src/async/`) keeps only `run`, `rpc`, `sleep`, `promise`, `detached`; all are eager and return a `DurablePromise`, so _"Awaiting one now is call-and-wait; holding several and awaiting them later is fan-out"_ ([`src/async/context.ts`][sdk-actx]). The `Context` doc there also states the replay rule that the brand exists to enforce:

> _"replay determinism requires that `await` only ever targets durable promises — awaiting a timer, I/O, or a plain async-helper chain lets durable ids be assigned in completion order, which cross-wires them on replay."_

### Replay: read the promise, or run the step

Replay is a dedup at each `promise.create`. The `Effects` layer keeps a cache seeded from a `preload` list the server returns with every task acquire (the settled siblings on the same branch, `ORDER BY id ASC LIMIT preload_limit`, `compute_preload` in [`crates/resonate-server-sqlite/src/lib.rs`][srv-sqlite]); a create for a cached id never goes to the network ([`src/util.ts`][sdk-util]):

```ts
promiseCreate: async (req, func = "unknown") => {
  const cached = cache.get(req.data.id);
  if (cached) return cached;
  …
  const res = await sendFenced(req);   // task.fence { id, version, action: promise.create }
```

On a cache miss the create is sent _fenced_: wrapped in `task.fence` with the task's `(id, version)`, so a worker whose lease expired cannot create or settle anything (the server answers `409`). What comes back decides the branch in `run` ([`src/async/context.ts`][sdk-actx]):

```ts
if (rec.state !== 'pending') {
  // Replay: the child is already settled → dedup, no spawn/return.
  this.trace.emit({ kind: 'dedup', id, state, value: rec.value?.data });
  return recordOutcome(rec);
}
// Pending: spawn the child, then execute it in-process via the recursive runner …
this.trace.emit({ kind: 'spawn', id });
```

A local child that finishes is settled through `promise.settle` (also fenced). A remote child (`rpc`, `sleep`, `promise`) that is still pending makes the user-facing promise _hang_ and fires the pass's suspend signal; the pass ends with a `task.suspend` carrying one `promise.register_callback` per awaited id ([`src/async/core.ts`][sdk-acore]). When those promises settle, the server's _settlement chain_ — `settle → resume → execute` — moves the awaiter's task back to `pending` and emits an `execute` message; the next worker to `task.acquire` it re-runs the function from the top, and every already-settled child dedups ([`recovery-protocol.mdx`][daa-spec-recovery]).

Each pass emits a nine-kind lifecycle trace — `run, rpc, spawn, block, await, resume, suspend, return, dedup` — with well-formedness predicates such as `uniqueSpawn` and `exclusiveLifecycle` (_"A promise has at most one of: spawn, block, dedup"_) that the tests check ([`src/trace.ts`][sdk-trace]).

### Tasks: claiming a function on any worker

A task exists exactly when a promise carries a `resonate:target` (the Postgres constraint `consistent_task_iff_targeted_promise`). Its lifecycle is `pending → acquired → (suspended | fulfilled | halted)`, and the `version` is an optimistic-concurrency token that increments only on `task.acquire` ([`daa-spec-dp`][daa-spec-dp]): _"All mutating task operations require the caller to present the current `version` — a mismatch returns conflict (status `409`)."_ The SDK's worker loop is `task.acquire` (with `pid`, `ttl`) → heartbeat → run a pass → `task.fulfill` (carrying the `promise.settle`), `task.suspend`, or `task.release` on an infrastructure error ([`src/async/core.ts`][sdk-acore]). A lease that lapses moves the task back to `pending` without bumping the version and re-emits `execute`; the successor's acquire bumps it, which is what fences the zombie.

The transport is pluggable: the server returns emitted messages from the transition (`Outgoing::Execute { address, task_id, version }`, `Outgoing::Unblock { address, promise }`) instead of writing an outbox ([`crates/resonate-sql/src/engine.rs`][srv-engine]), and worker plugins (`transport_http_push`, `transport_http_poll`, `transport_gcps`, `worker_bash`) deliver them ([`README.md`][srv-readme]).

### Detached versus attached

`run`/`rpc` children are attached: their timeout is clamped to the parent's (`Math.min(now + opts.timeout, this.timeoutAt)`), they share the parent's origin and branch, and a parent cannot finish its pass while one is pending. `detached` is the escape hatch ([`src/async/context.ts`][sdk-actx]):

> _"Spawns a workflow as a fresh root promise — independent execution lifecycle and replay scope (lineage break, new originId). … it survives parent completion and is dispatched independently by the server."_

Its id is `${origin}:d${cyrb53(seqid)}` — one hashed segment past the origin, so a recursive tail-spawn does not grow an id per iteration — and its timeout is _not_ clamped ([`src/util.ts`][sdk-util], `detachedId`). The generator-engine docstring explains why this matters ([`src/context.ts`][sdk-gctx]): _"a forever loop in a single durable invocation accumulates child promises on every iteration. On cold-start, each replay re-walks the full history. Once replay duration exceeds the acquired-task lease, the server reassigns the task mid-execution … and cadence collapses."_ The published constraint is the same in the docs: _"Bound Promise Count Per Execution"_ ([docs: constraints][docs-constraints]).

### Schedules and latent promises

A schedule is a stored `promise.create` template with a cron: <span v-pre>`{cron, promiseId: "run-{{.timestamp}}", promiseParam, promiseTags}`</span>; when it fires, the server substitutes the template and creates the promise, which (having a `resonate:target`) spawns a task ([`docs/triggers.md`][srv-triggers]). `ctx.promise()` creates a promise with no function behind it, tagged `resonate:external=true`; only `resonate.promises.resolve(id)` from outside can settle it, and the parent suspends on it like any remote child ([`src/async/context.ts`][sdk-actx], [`src/promises.ts`][sdk-promises]).

---

## Analysis

### 1. Step identity and replay matching

A step's identity is a **promise id derived from the parent's id plus a per-invocation sequence counter**: `root:1.2.3` is the third durable call of the second durable call of the first durable call under root `root` ([`src/ids.ts`][sdk-ids], [`src/async/context.ts`][sdk-actx]). Nothing about the step is in the key: not the function name, not the arguments, not a hash. Matching on replay is a single `promise.create` for that id; if the server already has the row, the returned record's `state`/`value` is the step's result and the SDK emits `dedup` instead of `spawn`. The function name and args _are_ stored, but in the promise's `param` for a remote worker to read, never compared. An explicit `opts.id` breaks the lineage and starts a fresh self-anchored tree ("breaksLineage"), which is how a caller-meaningful idempotency key (a Kafka `${topic}-${partition}-${offset}`, in the docs) becomes a promise id ([docs: typescript][docs-ts]).

### 2. Journal versus world

The journal wins, unconditionally, and disagreement is **not detected**. `promise.create` is `INSERT OR IGNORE` and returns the stored row; a create with a different `param` for an existing id returns `200` with the _old_ param and no error ([`crates/resonate-server-sqlite/src/lib.rs`][srv-sqlite]; Lean: [`external.lean`][lean-external]). The spec's canonical table did have detection — row 37, `Create(id, ikc*, T)` → `KO, Already Pending` when the idempotency key differs — but the page marks `ikc`/`iku`/`strict` as legacy surface the Lean model omits, and the Rust server implements the Lean model ([`daa-spec-dp`][daa-spec-dp]). There is no notion of an "observation" that is re-read: `ctx.date.now()` and `ctx.math.random()` are implemented as `ctx.run` over `Date.now`/`Math.random`, i.e. they are journaled decisions ([`src/async/context.ts`][sdk-actx]). The only world-vs-journal reconciliation is the timeout: `try_timeout` settles a pending promise as `rejected_timedout` when the clock has passed `timeout_at`, before any operation on it proceeds.

### 3. Determinism enforcement

By **discipline, with two runtime guards**. The docs state the contract plainly — _"Functions Must Be Deterministic"_ and _"Functions Must Be Idempotent"_ ([docs: constraints][docs-constraints]) — and the durable-function spec makes them preconditions of the equivalence ([`daa-spec-df`][daa-spec-df]). The runtime cannot see a divergent branch: an id mismatch simply creates a new promise. What it does catch: (a) a `DurablePromise` brand plus a pass "drain" that runs `Promise.allSettled` over every started op in rounds, then yields `DRAIN_YIELDS = 16` microtask generations, then _closes_ the context so that a durable op started from a continuation parked on a timer or I/O panics instead of running as a zombie ([`src/async/context.ts`][sdk-actx], `run`); (b) `task.fence` on every create/settle, so a worker that lost its lease cannot write. The generator engine adds nothing more; its `yield*` discipline is the same contract with the JS runtime handing back control at each step. Ordering of ids in the async engine is made source-order rather than completion-order by a _creation sequencer_ (`claimCreateSlot`) that serializes `promiseCreate` calls in the order the ops were issued.

### 4. Compensation and failure handling

**There is no compensation mechanism.** Neither the server nor the SDK has a saga, undo, or scope primitive; `grep -ri compensat` over `src/`, `tests/`, and `doc/` finds only the example. That example, `examples/generator/saga.ts`, is ordinary code: `try { hotelRef = yield* ctx.rpc("reserveHotel", …) } catch { yield* compensate(ctx, "", flightRef); throw … }`, where `compensate` runs the inverse steps in reverse order as further `ctx.rpc` calls and logs their failures — _"Compensation failures are logged, not surfaced -- the saga has already failed; the goal is best-effort rollback"_ ([`examples/generator/saga.ts`][sdk-saga]). Because the compensations are themselves durable calls with sequence-numbered ids, a crash mid-rollback resumes the rollback: _"if the worker crashes between two steps a restart skips the settled steps and runs only the missing ones -- including the compensations."_ Failure handling proper is: per-call retry policies (`Exponential`/`Linear`/`Constant`/`Never`) with `nonRetryableErrors`, run in-process under a fresh child context per attempt so children dedup across attempts ([`src/async/context.ts`][sdk-actx], `runWithRetry`); a rejected child promise rejects the awaiting `await`; a `ctx.panic` aborts the whole pass and releases the task for redelivery. Cancellation is a downstream settle to `rejected_canceled`, propagated to whoever awaits.

### 5. Versioning against old histories

**Function-level versions, no history-level check.** `resonate.register(fn, { version: 2 })` keeps a `Registry` keyed by name and integer version; a promise's `param` records the `version` it was created with, and a worker resolves `registry.get(func, version)` and asserts `version === registered.version` (`0` means latest) ([`src/registry.ts`][sdk-registry], [`src/async/core.ts`][sdk-acore]). That pins a _pending_ execution to the code that started it, provided the old version stays registered. It does nothing about the shape of the tree: if `v2` inserts a durable call before an existing one, the new call takes id `root:1.2`, dedups against the _old_ step's promise, and reads the wrong value. There is no schema hash, no "patched" marker, no unknown-step error — the id carries no information that could raise one. The intended mitigation is structural: keep old versions registered and let in-flight roots drain, and bound roots with `detached` so histories stay short.

### 6. Concurrency under replay

Fan-out is `Promise.all` over eager `DurablePromise`s in the async engine (_"operations are eager, fan-out is ordinary `Promise.all`"_, [docs: typescript][docs-ts]) or `yield ctx.beginRun(...)` handles in the generator engine. Ids are assigned at **issue time in source order** by the sequence counter, and the creation sequencer guarantees the `promise.create` requests reach the server in that order even though the underlying promises settle in any order. On replay, the same source order assigns the same ids, so a completed sibling dedups and an incomplete one runs, independent of which finished first originally. The cost is the rule quoted in §3: a non-durable `await` between two durable calls can reorder the counter, and the runtime only detects the extreme case (a call after the pass closed). The server-side counterpart is that `task.suspend` registers one callback per awaited id, and the task resumes when _any_ of them settles; the re-run pass then blocks again on the ones still pending ([`src/async/core.ts`][sdk-acore]).

### 7. Replay or snapshot

**Pure replay, with a per-branch preload as the only acceleration.** No continuation is ever captured; a suspended function's stack is thrown away and rebuilt by re-running the body (the docs: _"When your process crashes, Resonate replays your function from the beginning, but instead of re-executing expensive operations … it uses recorded results"_, [docs: develop][docs-develop]). Replay cost is linear in the number of children under the root, which is why the constraints page names it and why `detached` exists ([docs: constraints][docs-constraints]). The `preload` returned by `task.acquire`/`task.suspend` — settled siblings on the same `branch_id`, capped at `preload_limit` (default 10) — turns the first N dedups into cache hits rather than round-trips, but does not change the asymptotics. What replay rules out: any non-serializable state living across a suspend (a socket, a handle), and any step whose _effect_ is not idempotent — the second half of idempotency the spec leaves to the author.

### 8. Testing

Three layers, each cited:

- **Machine-checked specification.** `resonate-specification` is _"an executable **abstract machine** in Lean 4 — a state, a set of effects, and one transition per request — together with a **catalogue of properties** that every run of it satisfies"_; its README reports 92 catalogue entries checked over 1 464 enumerated scripts by kernel `decide` at build time, 31 proved outright, and a trace checker (`lake exe checktrace < trace.ndjson`) that asks _"whether the machine can account for"_ a trace recorded from a real server ([`README.md`][lean-readme], [`spec/02-abstract/properties.lean`][lean-props]). A TLA+ twin (`tlap/`) removes atomicity and rechecks the catalogue. The Postgres schema installs the same names as constraints.
- **Differential random testing of the server.** `diff/differential.rs` drives one random request sequence through SQLite, an in-memory `resonate-oracle` reference model, and (when configured) Postgres and MySQL, asserting _"identical responses and state snapshots at every step"_, with a coverage requirement that all 22 operation kinds (`promise.create` … `debug.tick`) return at least one `2xx` before the run may end ([`diff/differential.rs`][srv-diff], [`crates/resonate-oracle/src/lib.rs`][srv-oracle]). Time rides in the envelope (`resonate:debug_time`) so all backends see the same `now`; deadlines a transition arms are compared against the before/after snapshot diff. The oracle uses `BTreeMap` throughout because `HashMap` iteration order broke seeded reproduction. A `concurrency-stress` feature inserts `tokio::task::yield_now()` before every transaction to widen interleavings ([`crates/resonate-server-sqlite/src/lib.rs`][srv-sqlite]).
- **Deterministic simulation of the SDK.** `sim/` runs a seeded LCG (`Random`), a `StepClock`, an in-memory `Server` (`src/network/local.ts`), and N `WorkerProcess`es under a tick loop with message drop/duplicate/delay/corruption and worker deactivate/activate probabilities, all drawn from the seed when unspecified ([`sim/main.ts`][sdk-sim-main], [`sim/src/simulator.ts`][sdk-sim], [`sim/src/server.ts`][sdk-sim-server]). `npm run dst:diff` runs the generator and async engines on the same `(seed, workload, faults)` and asserts convergence to the same canonical `debug.snap` — _"Strong oracle = promises + tasks + callbacks + root outcome"_ — reporting _"0 failures across 160+ seeds"_ ([`diff-testing.md`][sdk-diff-doc], [`sim/src/differential.ts`][sdk-sim-diff], [`tests/equivalence/oracle.ts`][sdk-oracle]). The docs add that CI runs each seed twice and diffs the logs, and that failures file GitHub issues with the repro command ([docs: how tested][docs-tested]).
- **The legacy Go DST.** The Go server's `test/dst` (now in `resonate-legacy-server`) is a linearizability harness: a `Generator` produces requests per tick, a `Validator` per request kind advances a `Model` of promises/callbacks/schedules/tasks, and the operations are checked with `porcupine`; backchannel validators (`ValidateTasksWithSameRootPromiseId`, `ValidateNotify`, `ValidateTaskExpiry`) check the messages the server emitted ([`test/dst/dst.go`][go-dst], [`test/dst/model.go`][go-dst-model], [`test/dst/validator.go`][go-dst-validator]). The Rust rewrite replaced it with the oracle differential above.

What is _not_ tested: crash-at-every-step of a user workflow against a mutated world. The SDK DST crashes workers at random ticks, which subsumes crash-at-every-index probabilistically, but the world it resumes into is the simulated server's own state, never an externally mutated one.

---

## Strengths

- **One primitive, fully specified.** Promise + task + schedule is the entire server; the Lean catalogue and the differential make "correct" a checkable word rather than a comparison with another implementation.
- **Ids are the API.** Caller-chosen root ids give idempotent invocation for free; sequence-derived child ids give replay matching with no step names to maintain.
- **Cross-process `await`.** A suspended function costs nothing on any worker; resumption goes to whichever worker claims the task, and the fence/version token makes lease loss safe.
- **Two engines, one contract**, held together by differential simulation rather than by shared code.
- **Server-side invariants as `CHECK` constraints** mean a corrupt state cannot be committed, not merely detected later.
- **Detached spawn** as a documented, id-bounded answer to unbounded histories.

## Weaknesses

- **No divergence detection.** A changed program, a non-deterministic branch, or a reordered call silently reads another step's value; nothing compares what the step _was_ with what it _is_.
- **No compensation primitive.** Sagas are hand-written `try/catch` over durable calls; ordering, LIFO, and "only undo what completed" are the author's problem.
- **Versioning is per function, not per history.** Old code must stay registered for in-flight roots; no migration or patch mechanism for the tree shape.
- **The determinism contract is subtle in JS.** "Only await durable promises" is enforced only at the edges (brand, drain, close); `Promise.all` over a mix of durable and plain promises is off-contract and undetected.
- **Replay is linear in children** with a lease as the hard ceiling; the mitigation (`detached`) changes program structure.
- **Idempotency keys are gone.** The canonical spec's `ikc`/`iku` dedup-with-detection was dropped from the Lean model and the Rust server; create is unconditional `INSERT OR IGNORE`.

---

## Key design decisions and trade-offs

| Decision                                                    | Rationale                                                                              | Trade-off                                                                                    |
| ----------------------------------------------------------- | -------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Promise id = parent id + sequence counter                   | No step names; identical for any language; the server can validate the tree            | Zero information in the key; any reordering is silent misattribution                         |
| `INSERT OR IGNORE` create, no idempotency keys              | Matches the Lean machine; create is an algebraic idempotent                            | A create with different `param` is not an error; drift is invisible                          |
| One row per promise, task folded in, no outbox              | Invariants become `CHECK` constraints; a transition returns what it emitted            | Every task transition rewrites the whole promise row; schema edited in place pre-release     |
| Replay from the top with per-branch `preload`               | No continuation capture; any worker can resume                                         | Linear replay cost; lease as the ceiling; `detached` needed to bound histories               |
| Task version bumps only on `acquire`; every write is fenced | Lease loss cannot corrupt state; late writers get `409`                                | Every create/settle is an extra envelope; the SDK must thread `(id, version)` everywhere     |
| Timeouts are promise properties, applied lazily on touch    | No timer races; the deadline is a fact about the row                                   | Target-less promises only time out when someone touches them                                 |
| Async engine: eager ops + drain + close                     | Ordinary `async`/`await` and `Promise.all`; no generators                              | Off-contract awaits are caught only at the pass boundary; 16 microtask yields is a heuristic |
| Retries in-process under a fresh child context              | Children dedup across attempts exactly as across crashes                               | Retry state is not durable; a crash mid-backoff restarts the attempt count                   |
| Server correctness by Lean catalogue + oracle differential  | "Correct" is a property name shared by Lean, Go, TypeScript, and the Postgres `CHECK`s | Three SDK engines and four storage engines must each be held to it separately                |

---

## Relevance to sparkles

- **Confirms the journaling combinator as the single pure cast, and confirms replay over snapshot.** Resonate journals nothing but promise rows, re-runs the body, and dedups per step; the SDK's `Effects.promiseCreate` cache-then-fence is exactly the "started + completed" seam the design puts around each capability op. Its `preload` is a cheap idea worth stealing: hand the replaying function the settled entries for its branch up front so the first N steps are cache hits.
- **Argues against name-plus-args-hash keys — partly.** Resonate keys steps by _position_ alone and pays for it with silent misattribution on any reorder (§2, §5). The design's `name + attempt + args-hash` key is strictly more informative: a hash mismatch is a detectable "the program changed" signal Resonate cannot produce. Keep the hash, and make a mismatch an explicit outcome (error, or re-execute-and-reconcile) rather than a dedup.
- **Argues against treating observations as decisions.** `ctx.date.now()` is `ctx.run(Date.now)`: journaled once, replayed forever. For `release`, `git tag -l` and `HEAD` are the cases where that is wrong, which is why the design re-observes and reconciles by rule table. Resonate has no category for this; the closest thing is the lazy `try_timeout`, a single fact the server re-derives from the clock on every touch. The rule table is a genuine addition, not something to drop.
- **Confirms that compensation must be explicit and belongs to the program, and adds a useful property.** Resonate's saga is `try/catch` over durable calls, but because compensations are themselves journaled steps, a crash during rollback resumes the rollback. The design's LIFO scope registry should preserve that: a compensation is an op through the row, journaled like any other, so `crash-during-compensation` is just another resume point.
- **Warns about the concurrency key.** With position-based ids, `Promise.all` is safe only because ids are assigned in source order at issue time, and the runtime has to serialize creates and police stray awaits. The design's keys are name-based, so concurrent ops within one scope collide unless the attempt counter is per name and the ordering of _issuance_ is itself deterministic; write the crash test for two concurrent ops of the same name.
- **Missing in the design: an interruption-tolerance statement and a lease.** Resonate's spec states the goal as an equivalence with an interruption-free run and derives its three preconditions from it; `release` should state the same thing for its journal (what "equivalent" means when confirmation gates re-ask). And `release` has no notion of two concurrent resumes of one run; a lock file with a fencing token is the one-process analogue of `task.acquire`'s version.
- **Missing in the design: a fence between "the world moved" and "this run's writes".** Resonate fences every write with the task version. `release`'s equivalent is checking that the tag or GitHub release it is about to create is still absent at write time, not only at observe time — the reconciliation rule should run immediately before each irreversible op, not once at resume.
- **Testing: adopt the two-oracle shape.** Resonate proves the SDK against the server's durable state (canonical snapshot + root outcome) and the server against a reference model. For `release`, the "canonical snapshot" is the journal plus the world (tags, releases, manifest); crash-at-every-index-then-resume should assert equality of that pair against an uninterrupted run, which is the interruption-tolerance equivalence made executable. Mutate-the-world-between-crash-and-resume is the case Resonate's DST never exercises and is the design's distinctive contribution.

---

## Sources

- Spec stub: [`durable-promise-specification/Readme.md`][dps-readme] (clone at `8b0d401a72ce3a2790f458c9ee6d9ebcd7519f4b`).
- Canonical spec (site repository at `baee8c0577095e1db6fe683c381bd7e220a30b26`): [Durable Promise Specification][daa-spec-dp] · [Durable Function Specification][daa-spec-df] · [Recovery Protocol][daa-spec-recovery].
- Lean model (at `6b120adc47a45f5b2e796fede1ae6b245e1a6d66`): [`README.md`][lean-readme] · [`spec/02-abstract/properties.lean`][lean-props] · [`spec/02-abstract/external.lean`][lean-external].
- Server (clone at `33c7a3f460fc10690b71aad77b06b15ecbc9b7b3`): [`README.md`][srv-readme] · [`crates/resonate-core/src/types.rs`][srv-types] · [`crates/resonate-server-sqlite/src/lib.rs`][srv-sqlite] · [`crates/resonate-server-sqlite/migrations/0001_initial.sql`][srv-sqlite-mig] · [`crates/resonate-server-postgres/migrations/0001_initial.sql`][srv-pg-mig] · [`crates/resonate-sql/src/engine.rs`][srv-engine] · [`crates/resonate-oracle/src/lib.rs`][srv-oracle] · [`diff/differential.rs`][srv-diff] · [`docs/triggers.md`][srv-triggers].
- TypeScript SDK (clone at `a3a3ccf3f92c636afcf51d4f10c4ad44d2b5399b`): [`src/ids.ts`][sdk-ids] · [`src/async/context.ts`][sdk-actx] · [`src/async/core.ts`][sdk-acore] · [`src/context.ts`][sdk-gctx] · [`src/util.ts`][sdk-util] · [`src/registry.ts`][sdk-registry] · [`src/trace.ts`][sdk-trace] · [`src/promises.ts`][sdk-promises] · [`examples/generator/saga.ts`][sdk-saga] · [`diff-testing.md`][sdk-diff-doc] · [`sim/main.ts`][sdk-sim-main] · [`sim/src/simulator.ts`][sdk-sim] · [`sim/src/server.ts`][sdk-sim-server] · [`sim/src/differential.ts`][sdk-sim-diff] · [`tests/equivalence/oracle.ts`][sdk-oracle].
- Legacy Go server (at `f4153f76f22277f3da55b5de7cb222c4cd66ef06`): [`test/dst/dst.go`][go-dst] · [`test/dst/model.go`][go-dst-model] · [`test/dst/validator.go`][go-dst-validator].
- Official docs: [Constraints][docs-constraints] · [TypeScript SDK][docs-ts] · [Develop][docs-develop] · [How it works][docs-how] · [How Resonate is tested][docs-tested].
- Sibling pages: [Temporal][temporal] · [DBOS][dbos] · [catalog index][index].

<!-- References -->

[repo]: https://github.com/resonatehq/resonate
[repo-sdk]: https://github.com/resonatehq/resonate-sdk-ts
[repo-spec-lean]: https://github.com/resonatehq/resonate-specification
[repo-dps]: https://github.com/resonatehq/durable-promise-specification
[docs]: https://docs.resonatehq.io/
[docs-constraints]: https://docs.resonatehq.io/develop/constraints
[docs-ts]: https://docs.resonatehq.io/develop/typescript
[docs-develop]: https://docs.resonatehq.io/develop
[docs-how]: https://docs.resonatehq.io/evaluate/how-it-works
[docs-tested]: https://docs.resonatehq.io/evaluate/how-resonate-is-tested
[dps-readme]: https://github.com/resonatehq/durable-promise-specification/blob/8b0d401a72ce3a2790f458c9ee6d9ebcd7519f4b/Readme.md
[daa-spec-dp]: https://github.com/resonatehq/distributed-async-await.io/blob/baee8c0577095e1db6fe683c381bd7e220a30b26/content/docs/spec/programming-model/durable-promise-specification.mdx
[daa-spec-df]: https://github.com/resonatehq/distributed-async-await.io/blob/baee8c0577095e1db6fe683c381bd7e220a30b26/content/docs/spec/programming-model/durable-function-specification.mdx
[daa-spec-recovery]: https://github.com/resonatehq/distributed-async-await.io/blob/baee8c0577095e1db6fe683c381bd7e220a30b26/content/docs/spec/execution-model/recovery-protocol.mdx
[lean-readme]: https://github.com/resonatehq/resonate-specification/blob/6b120adc47a45f5b2e796fede1ae6b245e1a6d66/README.md
[lean-props]: https://github.com/resonatehq/resonate-specification/blob/6b120adc47a45f5b2e796fede1ae6b245e1a6d66/spec/02-abstract/properties.lean
[lean-external]: https://github.com/resonatehq/resonate-specification/blob/6b120adc47a45f5b2e796fede1ae6b245e1a6d66/spec/02-abstract/external.lean
[srv-readme]: https://github.com/resonatehq/resonate/blob/33c7a3f460fc10690b71aad77b06b15ecbc9b7b3/README.md
[srv-types]: https://github.com/resonatehq/resonate/blob/33c7a3f460fc10690b71aad77b06b15ecbc9b7b3/crates/resonate-core/src/types.rs
[srv-sqlite]: https://github.com/resonatehq/resonate/blob/33c7a3f460fc10690b71aad77b06b15ecbc9b7b3/crates/resonate-server-sqlite/src/lib.rs
[srv-sqlite-mig]: https://github.com/resonatehq/resonate/blob/33c7a3f460fc10690b71aad77b06b15ecbc9b7b3/crates/resonate-server-sqlite/migrations/0001_initial.sql
[srv-pg-mig]: https://github.com/resonatehq/resonate/blob/33c7a3f460fc10690b71aad77b06b15ecbc9b7b3/crates/resonate-server-postgres/migrations/0001_initial.sql
[srv-engine]: https://github.com/resonatehq/resonate/blob/33c7a3f460fc10690b71aad77b06b15ecbc9b7b3/crates/resonate-sql/src/engine.rs
[srv-oracle]: https://github.com/resonatehq/resonate/blob/33c7a3f460fc10690b71aad77b06b15ecbc9b7b3/crates/resonate-oracle/src/lib.rs
[srv-diff]: https://github.com/resonatehq/resonate/blob/33c7a3f460fc10690b71aad77b06b15ecbc9b7b3/diff/differential.rs
[srv-triggers]: https://github.com/resonatehq/resonate/blob/33c7a3f460fc10690b71aad77b06b15ecbc9b7b3/docs/triggers.md
[sdk-ids]: https://github.com/resonatehq/resonate-sdk-ts/blob/a3a3ccf3f92c636afcf51d4f10c4ad44d2b5399b/src/ids.ts
[sdk-actx]: https://github.com/resonatehq/resonate-sdk-ts/blob/a3a3ccf3f92c636afcf51d4f10c4ad44d2b5399b/src/async/context.ts
[sdk-acore]: https://github.com/resonatehq/resonate-sdk-ts/blob/a3a3ccf3f92c636afcf51d4f10c4ad44d2b5399b/src/async/core.ts
[sdk-gctx]: https://github.com/resonatehq/resonate-sdk-ts/blob/a3a3ccf3f92c636afcf51d4f10c4ad44d2b5399b/src/context.ts
[sdk-util]: https://github.com/resonatehq/resonate-sdk-ts/blob/a3a3ccf3f92c636afcf51d4f10c4ad44d2b5399b/src/util.ts
[sdk-registry]: https://github.com/resonatehq/resonate-sdk-ts/blob/a3a3ccf3f92c636afcf51d4f10c4ad44d2b5399b/src/registry.ts
[sdk-trace]: https://github.com/resonatehq/resonate-sdk-ts/blob/a3a3ccf3f92c636afcf51d4f10c4ad44d2b5399b/src/trace.ts
[sdk-promises]: https://github.com/resonatehq/resonate-sdk-ts/blob/a3a3ccf3f92c636afcf51d4f10c4ad44d2b5399b/src/promises.ts
[sdk-saga]: https://github.com/resonatehq/resonate-sdk-ts/blob/a3a3ccf3f92c636afcf51d4f10c4ad44d2b5399b/examples/generator/saga.ts
[sdk-diff-doc]: https://github.com/resonatehq/resonate-sdk-ts/blob/a3a3ccf3f92c636afcf51d4f10c4ad44d2b5399b/diff-testing.md
[sdk-sim-main]: https://github.com/resonatehq/resonate-sdk-ts/blob/a3a3ccf3f92c636afcf51d4f10c4ad44d2b5399b/sim/main.ts
[sdk-sim]: https://github.com/resonatehq/resonate-sdk-ts/blob/a3a3ccf3f92c636afcf51d4f10c4ad44d2b5399b/sim/src/simulator.ts
[sdk-sim-server]: https://github.com/resonatehq/resonate-sdk-ts/blob/a3a3ccf3f92c636afcf51d4f10c4ad44d2b5399b/sim/src/server.ts
[sdk-sim-diff]: https://github.com/resonatehq/resonate-sdk-ts/blob/a3a3ccf3f92c636afcf51d4f10c4ad44d2b5399b/sim/src/differential.ts
[sdk-oracle]: https://github.com/resonatehq/resonate-sdk-ts/blob/a3a3ccf3f92c636afcf51d4f10c4ad44d2b5399b/tests/equivalence/oracle.ts
[go-dst]: https://github.com/resonatehq/resonate-legacy-server/blob/f4153f76f22277f3da55b5de7cb222c4cd66ef06/test/dst/dst.go
[go-dst-model]: https://github.com/resonatehq/resonate-legacy-server/blob/f4153f76f22277f3da55b5de7cb222c4cd66ef06/test/dst/model.go
[go-dst-validator]: https://github.com/resonatehq/resonate-legacy-server/blob/f4153f76f22277f3da55b5de7cb222c4cd66ef06/test/dst/validator.go
[temporal]: ./temporal.md
[dbos]: ./dbos.md
[index]: ./index.md
