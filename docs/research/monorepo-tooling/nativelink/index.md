# NativeLink (Remote execution)

A Nix-powered, single-binary, Rust implementation of Bazel's Remote Execution
API (`REAPI`) — a content-addressed cache (`CAS` + `ActionCache`) and a worker
scheduler — whose distinguishing idea is a **composable store stack** declared in
one `JSON5` file and a **Local Remote Execution (`LRE`)** framework that uses Nix
to make a developer's local toolchain bit-for-bit identical to the remote one.

| Field           | Value                                                                                                                                               |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language        | Rust (≈86% of the tree) + Nix (toolchains, `LRE`, packaging) + a small TypeScript docs/UI surface                                                   |
| License         | `FSL-1.1-Apache-2.0` (Functional Source License 1.1, converting to Apache-2.0 two years after each release)                                         |
| Repository      | [TraceMachina/nativelink][repo]                                                                                                                     |
| Documentation   | [nativelink.com/docs][docs] · [config reference (`nativelink-config`)][config-src]                                                                  |
| Category        | Remote Execution Backend                                                                                                                            |
| Workspace model | **None of its own** — it is a `REAPI` _server_ for a build client ([Bazel][bazel], [Buck2][buck2], Reclient, Goma); the "workspace" is the client's |
| First released  | Public repo 2020-12-24 (as `turbo-cache`); rebranded NativeLink; `v1.0.0` GA on 2026-03-23                                                          |
| Latest release  | `v1.3.2` (2026-05-30)                                                                                                                               |

> **Latest release:** `v1.3.2`, cut **2026-05-30** — the tail of a rapid `v1.x`
> cadence (`v1.0.0` GA 2026-03-23, then `v1.1.0` 2026-05-06, `v1.2.0` 2026-05-15,
> `v1.3.0` 2026-05-21). Like every `REAPI` backend, NativeLink ships **no
> "workspace" version**: its compatibility surface is the wire-level **Remote
> Execution API** (`REAPI` v2) over gRPC, not a manifest format. As of June 5,
> 2026 it is offered as a self-hostable single binary / container image (the
> open-source core under [`FSL-1.1-Apache-2.0`][license]) and as a managed cloud.

---

## Overview

### What it solves

NativeLink is **not** a workspace tool, a package manager, or a build system. It
has no manifest, no `members` array, no dependency resolver, and no notion of a
"project." It is the _server side_ of the remote-build contract that
[Bazel][bazel], [Buck2][buck2], Pants, Soong, Reclient, and Goma speak: a build
client computes its own action graph, then ships individual **actions** — a
command plus the exact Merkle tree of declared inputs — over gRPC, and NativeLink
either (a) returns a cached `ActionResult` if that action digest has been seen
before anywhere in the org, or (b) schedules the action onto a worker, runs it,
and streams the outputs back into the `CAS`. It belongs in this monorepo survey
for the same reason [BuildBuddy][buildbuddy] and Buildbarn do: the
_caching and remote-execution_ dimension (dimension 4) of a large monorepo is
frequently **outsourced** to a `REAPI` backend, and NativeLink is the Rust,
single-binary, Nix-native member of that family.

The problem it attacks is the one that defeats every language-native package
manager ([Cargo][cargo], `dub`, [Go modules][go-work]) at monorepo scale:
**redundant work.** In a repo with hundreds of thousands of targets, the same
compile/test action is rerun across every engineer's machine, every CI shard, and
every branch. Bazel models each action as a pure function of its inputs and hashes
them into an **action digest**; NativeLink stores the result keyed by that digest
in a **content-addressable store (`CAS`)**, so the second time _anyone_ requests
the same digest, bytes are fetched instead of recomputed. Remote _execution_
extends this from "cache the result" to "run the function on a shared farm,"
giving a small laptop the throughput of a cluster.

What sets NativeLink apart inside the `REAPI`-backend family is twofold: (1) it is
written in **Rust** with a deliberately **garbage-collector-free, memory-safe**
core, pitched at safety-critical and mission-critical native codebases; and (2) it
treats the cache backend as a **composable stack of small stores** (`fast_slow`,
`dedup`, `compression`, `verify`, `shard`, `size_partitioning`, …) wired together
in one `JSON5` config, rather than a fixed three-tier cache.

### Design philosophy

From the project `README` ([`README.md`][readme]):

> _"NativeLink is an efficient, high-performance build cache and remote execution
> system that accelerates software compilation and testing while reducing
> infrastructure costs."_

The GitHub repository description sharpens the positioning to the cross-client,
Nix-native angle ([repository metadata][repo]):

> _"NativeLink is a Nix-powered, open source, high-performance build cache and
> remote execution server, compatible with Bazel, Soong, Pants, Buck2, Reclient,
> and other RE-compatible build systems. It offers drastically faster builds,
> reduced test flakiness, and support for specialized hardware."_

And the trust signal it leads with ([`README.md`][readme]):

> _"NativeLink is trusted in production environments to reduce costs and developer
> iteration times — handling over billions of requests per month for its
> customers, including large corporations such as Samsung."_

Four architectural commitments follow, and they shape the whole system:

1. **The client owns the workspace; the server owns the work.** NativeLink
   deliberately knows nothing about `WORKSPACE`/`MODULE.bazel`, `BUCK` files,
   packages, or targets. Everything it sees is post-analysis: a stream of
   `Action`s addressed by digest. This is the inverse of [Nx][nx]/[Turborepo][turborepo],
   which own a project graph and a task pipeline; NativeLink is the substrate
   _under_ such an engine, reachable by any client that speaks `REAPI`.
2. **Memory-safe, GC-free Rust as a correctness argument.** The choice of Rust is
   not incidental marketing — the pitch is that a remote-execution server sitting
   on the critical path of every build in a safety-critical org should have no
   garbage-collector pauses, no data races, and deterministic resource behavior.
   This is the same value proposition Rust brings to the async-I/O runtimes in the
   sibling survey (see [Glommio][glommio]/[Tokio][tokio]), applied to build
   infrastructure instead of network servers.
3. **The backend is a composed _store stack_, not a fixed cache.** Every storage
   concern — local disk, an S3/GCS/Redis backend, deduplication, compression,
   integrity verification, sharding, hot/cold tiering — is its own small `Store`
   implementation, and a deployment _assembles_ them by nesting store specs inside
   one another in `JSON5`. A `fast_slow` over a `dedup` over a `compression` over
   an `experimental_cloud_object_store` is a single declarative tree.
4. **Hermeticity is enforced down to the toolchain via Nix.** NativeLink's `LRE`
   framework generates the _same_ compiler/toolchain from a Nix flake for both the
   developer's machine and the remote workers, so local and remote actions hash
   identically and the cache hits across laptops, CI, and the farm — addressing the
   "but it built on my machine" cache-miss problem at its root.

NativeLink sits in the same `REAPI`-backend family as [BuildBuddy][buildbuddy]
(Go, open-core, autoscaling cloud + web UI) and Buildbarn (Go,
Kubernetes-native, highly decomposed); the shared wire protocol is the reason a
[Bazel][bazel] or [Buck2][buck2] client can swap one for another by changing a
single `--remote_executor` URL. For how the client side drives this contract, see
the [Bazel][bazel] and [Buck2][buck2] deep-dives; for the D-language gap this
whole class of tooling exposes, see [the D landscape][d-landscape].

---

## Core components and gRPC surface

NativeLink is a **single binary** (`nativelink`) that, depending on which services
its config file enables, plays the role of cache server, scheduler, and/or worker.
The same executable can run all roles in one process (the local quickstart) or be
deployed as separate cache / scheduler / worker tiers at scale. It implements the
standard `REAPI` services a Bazel client connects to, plus an internal
`WorkerApi` for workers to register and stream work.

| Concept               | Component / service                                                    | Role                                                                                         |
| --------------------- | ---------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Cache (read/write)    | `cas`, `ac`, `bytestream`, `capabilities` services                     | Standard `REAPI` cache surface the client hits for blob digests and action results           |
| Remote execution      | `execution` service                                                    | Accepts `Execute`/`WaitExecution`; turns an action digest into a scheduled job               |
| Scheduling            | `schedulers[]` (`simple`, `grpc`, `cache_lookup`, `property_modifier`) | Matches a queued action to a worker whose `platform_properties` satisfy the action           |
| Worker brokering      | `worker_api` service (private listener)                                | Workers register, stream capabilities, lease jobs, and report results                        |
| Worker                | `workers[]` (`local`)                                                  | Pulls leased actions, materializes the input tree on disk, runs the command, uploads outputs |
| Storage               | `stores[]` (a composable stack — see [How it works](#how-it-works))    | Every cache/CAS backend; nested store specs form the durable substrate                       |
| Toolchain hermeticity | `local-remote-execution/` (`LRE`)                                      | Nix-generated toolchains identical local↔remote for ~100% cache hit rate                     |
| Server / listeners    | `servers[]` (`listener.http`, `services`)                              | One or more gRPC listeners; public cache/exec ports vs. private worker/admin ports           |

### The standard REAPI client contract

A Bazel (or Buck2 / Reclient / Goma) client never names NativeLink components
directly; it points its remote flags at the public gRPC listener and NativeLink
multiplexes the `REAPI` services behind it:

```bash
# .bazelrc — point Bazel at a NativeLink endpoint
build --remote_cache=grpc://localhost:50051      # REAPI CAS + ActionCache + ByteStream
build --remote_executor=grpc://localhost:50051   # REAPI Execution service (omit for cache-only)
```

`--remote_cache` enables the cache services only; adding `--remote_executor`
promotes the same endpoint to a full remote-execution backend (if unset,
`--remote_cache` defaults to the executor's value). Because the contract is the
wire protocol, the very same client config works against [BuildBuddy][buildbuddy]
or Buildbarn — the differentiation is operational, not protocol-level.

---

## How it works

### The composable store stack — the defining idea

NativeLink's signature design is that **storage is built from small, nestable
`Store` implementations** rather than one monolithic cache. The `stores[]` array
in the config is a list of named stores, and most store types take _other stores_
as fields, so a deployment composes a tree. The variants (from
[`nativelink-config/src/stores.rs`][stores-src]) include:

| Store spec                        | Doc-comment role (quoted / paraphrased from source)                                                                         |
| --------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `memory`                          | _"Memory store will store all data in a hashmap in memory."_                                                                |
| `filesystem`                      | _"Stores the data on the filesystem"_ (local persistent CAS; required as a worker's `fast` store)                           |
| `fast_slow`                       | _"will first try to fetch the data from the fast store and then if it does not exist try the slow store"_                   |
| `dedup`                           | rolling-hash (`fastcdc`) chunking + `sha256` per slice; `index_store` (small/fast) + `content_store`                        |
| `compression`                     | _"will compress the data inbound and outbound"_ (LZ4: _"extremely fast … does not perform very well in compression ratio"_) |
| `verify`                          | _"used to apply verifications to an underlying store implementation"_ (size + `sha256` digest integrity)                    |
| `completeness_checking`           | _"verifies if the output files & folders exist in the CAS before forwarding the request"_                                   |
| `existence_cache`                 | _"wrap around another store and cache calls to `has` so that subsequent calls will be faster"_                              |
| `shard`                           | _"Shards the data to multiple stores"_ by digest hash for load distribution                                                 |
| `size_partitioning`               | routes small vs. large objects to different underlying stores by the digest's size field                                    |
| `ref_store`                       | _"reference a store in the root store manager"_ — share one store instance across the tree                                  |
| `grpc`                            | _"pass-through calls to another GRPC store"_ (proxy to an upstream `CAS`)                                                   |
| `redis`                           | _"Stores data in any stores compatible with Redis APIs."_                                                                   |
| `experimental_cloud_object_store` | one blob backend over AWS S3, GCS, Azure Blob, NetApp ONTAP S3, Cloudflare R2                                               |
| `experimental_mongo`              | MongoDB backend for `CAS` and scheduler state (optional change streams)                                                     |
| `noop`                            | _"sends streams into the void and all data retrieval will return 404"_                                                      |
| `cache_metrics`                   | _"wraps another store and emits low-cardinality OpenTelemetry cache operation metrics"_                                     |

The power is in the nesting. A realistic durable CAS might read:
`fast_slow { fast: filesystem, slow: dedup { index_store: redis, content_store: compression { experimental_cloud_object_store: s3 } } }` — a local disk hot tier
backed by content-defined-chunked, LZ4-compressed blobs in S3 with the chunk index
in Redis. Each layer is independently testable and reusable. This is the same
"shell-with-hooks / capability composition" instinct the Sparkles guidelines
prize, applied to a storage substrate.

> [!NOTE]
> The `fast_slow` store is a tiered _mirror_, not a write-through-to-slow cache,
> and the source warns about it explicitly: _"this store will never check to see if
> the objects exist in the slow store if it exists in the fast store."_ For remote
> execution, where workers must reach the authoritative slow store, that subtlety
> is a real foot-gun — the `basic_cas.json5` example even routes its `slow` to
> `noop` precisely because the CAS and worker share one filesystem locally.

### Content-defined deduplication

The `dedup` store is where NativeLink earns its "content-addressed" credentials
beyond whole-blob hashing. From [`stores.rs`][stores-src]:

> _"A dedup store will take the inputs and run a rolling hash algorithm on them to
> slice the input into smaller parts then run a sha256 algorithm on the slice."_

The chunk sizes are tunable (`min_size` default 64 KiB, `normal_size` 256 KiB,
`max_size` 512 KiB), and slices are split via content-defined chunking (`fastcdc`)
so that an edit to one region of a large file re-uploads only the affected
chunks — the rest are already present by digest. The slice index lives in a small,
fast `index_store`; the chunk bytes go to a large, slow `content_store`. This is
the build-artifact analogue of a [pnpm][pnpm]-style content-addressed package
store, but at sub-file granularity.

### A complete config, end to end

The canonical single-process example
([`nativelink-config/examples/basic_cas.json5`][basic-cas]) wires stores,
scheduler, worker, and two listeners into one running server. Abridged:

```json5
{
  stores: [
    {
      name: 'AC_MAIN_STORE',
      filesystem: {
        content_path: '…/content_path-ac',
        temp_path: '…',
        eviction_policy: { max_bytes: 1000000000 },
      },
    },
    {
      name: 'WORKER_FAST_SLOW_STORE',
      fast_slow: {
        // "fast" must be a "filesystem" store because the worker uses it to make
        // hardlinks on disk to a directory where the jobs are running.
        fast: {
          filesystem: {
            content_path: '…/content_path-cas',
            eviction_policy: { max_bytes: 10000000000 },
          },
        },
        slow: { noop: {} }, // CAS and worker share local storage → slow is a noop
      },
    },
  ],
  schedulers: [
    {
      name: 'MAIN_SCHEDULER',
      simple: {
        supported_platform_properties: {
          cpu_count: 'minimum',
          memory_kb: 'minimum',
          cpu_arch: 'exact',
          OSFamily: 'priority',
          'container-image': 'priority',
          ISA: 'exact',
          InputRootAbsolutePath: 'ignore',
        },
      },
    },
  ],
  workers: [
    {
      local: {
        worker_api_endpoint: { uri: 'grpc://127.0.0.1:50061' },
        cas_fast_slow_store: 'WORKER_FAST_SLOW_STORE',
        upload_action_result: { ac_store: 'AC_MAIN_STORE' },
        work_directory: '/tmp/nativelink/work',
        platform_properties: {
          cpu_count: { values: ['16'] },
          cpu_arch: { values: ['x86_64'] },
          ISA: { values: ['x86-64'] },
        },
      },
    },
  ],
  servers: [
    {
      name: 'public',
      listener: { http: { socket_address: '0.0.0.0:50051' } },
      services: {
        cas: [{ instance_name: '', cas_store: 'WORKER_FAST_SLOW_STORE' }],
        ac: [{ instance_name: '', ac_store: 'AC_MAIN_STORE' }],
        execution: [
          {
            instance_name: '',
            cas_store: 'WORKER_FAST_SLOW_STORE',
            scheduler: 'MAIN_SCHEDULER',
          },
        ],
        capabilities: [
          {
            instance_name: '',
            remote_execution: { scheduler: 'MAIN_SCHEDULER' },
          },
        ],
        bytestream: [
          { instance_name: '', cas_store: 'WORKER_FAST_SLOW_STORE' },
        ],
      },
    },
    {
      name: 'private_workers_servers',
      listener: { http: { socket_address: '0.0.0.0:50061' } },
      services: {
        worker_api: { scheduler: 'MAIN_SCHEDULER' },
        admin: {},
        health: {},
      },
    },
  ],
  global: { max_open_files: 24576 },
}
```

Three structural facts are worth drawing out:

- **Services are bound to stores by name.** `cas`, `ac`, `execution`, and
  `bytestream` each reference a store by its string `name`; the same store can back
  multiple services and multiple `instance_name`s (the `REAPI` namespace that scopes
  a cache, e.g. `""` vs `"main"`).
- **Public vs. private listeners are separate ports with different permission
  sets.** The `public` listener exposes the cache/exec frontend; the
  `private_workers_servers` listener exposes `worker_api`/`admin`/`health` — a
  backend API that should _not_ be internet-reachable.
- **A worker is just another store consumer.** The `local` worker references the
  `fast_slow` CAS store for inputs/outputs and the `ac` store for results, and
  declares the `platform_properties` it can satisfy.

### Scheduling: matching actions to workers

The `simple` scheduler is the default in-process matcher
([`nativelink-config/src/schedulers.rs`][schedulers-src]). Its job is to pair a
queued action against a worker whose advertised `platform_properties` satisfy the
action's `Platform` requirements. Each property name carries a **matching
strategy** in `supported_platform_properties`:

| Strategy   | Meaning                                                                                       |
| ---------- | --------------------------------------------------------------------------------------------- |
| `exact`    | the worker's value must equal the action's requested value (e.g. `cpu_arch`, `ISA`)           |
| `minimum`  | numeric: the worker must advertise _at least_ the requested amount (`cpu_count`, `memory_kb`) |
| `priority` | the property steers placement preference (e.g. `OSFamily`, `container-image`, `lre-rs`)       |
| `ignore`   | the property is dropped from matching (e.g. `InputRootAbsolutePath`)                          |

`SimpleSpec` also exposes operational knobs: `allocation_strategy`
(`least_recently_used` — _"Prefer workers that have been least recently used to run
a job"_ — vs `most_recently_used`), `worker_timeout_s` (_"Remove workers from pool
once the worker has not responded in this amount of time"_), `max_job_retries`
(_"If a job returns an internal error or times out this many times … the scheduler
will return the last error to the client"_), and `client_action_timeout_s`.

The other scheduler variants are **wrappers**, composed the same way stores are:

- `grpc` — _"A scheduler that simply forwards requests to an upstream scheduler …
  useful when doing some kind of local action cache or CAS away from the main
  cluster of workers."_ This is how a local proxy tier delegates execution to a
  central farm.
- `cache_lookup` — short-circuits execution by returning a cached `ActionResult`
  (an `ActionCache` hit) instead of scheduling the action.
- `property_modifier` — rewrites an action's platform properties before handing it
  to a nested scheduler (e.g. inject a default `container-image`).

A production scheduler is therefore often a stack:
`cache_lookup → property_modifier → simple`, exactly mirroring the store-stack
philosophy.

### Local Remote Execution (`LRE`) — Nix-enforced toolchain parity

NativeLink's most distinctive feature beyond the store stack is `LRE`. The
recurring pain of any remote-execution deployment is **toolchain drift**: a
developer's locally-installed compiler differs from the remote worker's, so action
digests differ and the cache never hits across the local/CI/farm boundary. `LRE`
attacks this with Nix. From [`local-remote-execution/README.md`][lre-readme], `LRE`
is:

> _"a framework to build, distribute, and rapidly iterate on custom toolchain
> setups that are transparent, fully hermetic, and reproducible across machines of
> the same system architecture."_

It _"mirrors toolchains for remote execution in your local development
environment,"_ letting developers _"reuse build artifacts with virtually perfect
cache hit rate across different repositories, developers, and CI."_ Because the
local toolchain and the remote worker image are derived from the **same `nixpkgs`
pin**, they resolve to byte-identical Nix store paths, so an action built locally
and the same action built remotely produce the same digest — and the cache hits.
This is the deepest expression of point 4 above: hermeticity not just at the action
level (declared inputs) but at the _toolchain_ level (the compiler itself is a
content-addressed input).

---

## The five dimensions

### 1. Workspace declaration & topology

**Not applicable in the usual sense — and that is the point.** NativeLink has no
workspace manifest, no `members` glob, no root config enumerating sub-packages.
The "topology" it operates on is the **action graph the client already computed**:
a stream of `Action`s, each carrying a Merkle tree of input digests. Discovery,
globbing, and the dependency DAG all happen on the client
([Bazel][bazel]/[Buck2][buck2]) _before_ the first byte reaches NativeLink.

What NativeLink _does_ declare — and declares unusually richly — is **server and
fleet topology**: the `stores[]` stack (storage topology), the `schedulers[]`
(matching topology), the `workers[]` and their `platform_properties` (fleet
topology), and the `servers[]`/listeners (network topology). Cross-action
"namespacing" is done with the `REAPI` `instance_name` (the `""`/`"main"` keys in
the config), which scopes cache entries — a _cache_ boundary, not a project one.

> [!NOTE]
> For `dub`, the lesson is one of **layering**: a future `dub` `[workspace]` block
> (the client-side topology) is one concern; a `REAPI` backend like NativeLink
> would sit _below_ it, caching whatever actions a workspace-aware `dub` emits. The
> two concerns are orthogonal and compose — NativeLink contributes nothing to
> workspace declaration and everything to the cache/exec substrate beneath it.

### 2. Dependency handling & isolation

NativeLink isolates **at the action level**, not the package level, and it does so
with content addressing rather than symlink trees or hoisting. There is no
`node_modules`, no virtual store, no `workspace:` protocol — those are client-side
dependency models. What NativeLink guarantees is:

- **Input isolation per job.** Each action runs in a fresh worker `work_directory`
  whose input tree is materialized _exactly_ from the action's declared Merkle tree
  (the worker hardlinks blobs from its `fast` filesystem store into the job dir).
  Nothing undeclared is visible — hermeticity enforced by the substrate, the same
  property [Buck2][buck2] leans on.
- **Content-addressed deduplication of inputs.** Shared inputs (a common header, a
  toolchain binary) live once in the `CAS`; with a `dedup` store they are split into
  content-defined chunks so even partially-overlapping large inputs share storage.
  The worker's `fast_slow` store fetches each blob once and hardlinks it into every
  job that needs it.
- **Toolchain isolation via `LRE`.** Uniquely, the _compiler itself_ is a
  content-addressed, Nix-pinned input, so "dependency isolation" extends past the
  source tree to the build environment — the cause of most spurious cache misses
  elsewhere.

### 3. Task orchestration & scheduling

The **DAG lives on the client**; NativeLink schedules the _leaf actions_ that DAG
emits. It is a genuine distributed scheduler, not a DAG engine:

- **Property-based worker matching.** The `simple` scheduler pairs each queued
  action with a worker whose `platform_properties` satisfy the action's `Platform`,
  per the `exact`/`minimum`/`priority`/`ignore` strategies above — so heterogeneous
  fleets (GPU workers, specific `ISA`s, particular container images) route
  correctly.
- **Composable scheduler stack.** `cache_lookup` (short-circuit on an
  `ActionCache` hit), `property_modifier` (rewrite properties), and `grpc` (forward
  to an upstream farm) wrap a `simple` core the same way stores nest.
- **Allocation strategy & resilience.** `least_recently_used` /
  `most_recently_used` worker selection, `worker_timeout_s` to evict silent
  workers, `max_job_retries` to bound retries before surfacing the error, and
  `client_action_timeout_s` to reap abandoned operations.

**Change detection** is the cache itself: an action whose digest is unchanged is
never scheduled at all — the `ActionCache` (optionally fronted by a `cache_lookup`
scheduler) short-circuits it. This is the same input-hashing model as
[Nx][nx]/[Turborepo][turborepo], but at the granularity of a single compiler
invocation rather than a package-level task — and made far more reliable by `LRE`'s
toolchain pinning, since drift is the usual reason a "should-hit" action misses.

### 4. Caching & remote execution

This is NativeLink's reason to exist, and the dimension where it is a primary
implementation rather than a consumer. It is a full `REAPI` v2 server:

| Service / role                    | `REAPI` component                       | Client flag                  |
| --------------------------------- | --------------------------------------- | ---------------------------- |
| Content-addressable store         | `cas` + `bytestream` services           | `--remote_cache=grpc://…`    |
| Action results (digest → outputs) | `ac` (`ActionCache`) service            | `--remote_cache=grpc://…`    |
| Capability negotiation            | `capabilities` service                  | (implicit on connect)        |
| Remote **execution** of actions   | `execution` service                     | `--remote_executor=grpc://…` |
| Worker brokering                  | `worker_api` service (private listener) | (internal; workers connect)  |

Where BuildBuddy hard-codes a three-tier (disk → Redis → blob) cache, NativeLink
makes the **entire cache backend a user-assembled store stack** — `fast_slow`,
`dedup`, `compression`, `verify`, `shard`, `size_partitioning`, `existence_cache`,
and the cloud/`redis`/`mongo` backends compose into whatever topology a deployment
needs. The `experimental_cloud_object_store` spans S3, GCS, Azure Blob, ONTAP S3,
and R2 from one spec. Integrity is opt-in via the `verify` store (size + `sha256`)
and `completeness_checking` (outputs really exist before an `ActionResult` is
served). Crucially, NativeLink speaks the **same `REAPI` wire protocol** as
[BuildBuddy][buildbuddy] and Buildbarn, so a [Bazel][bazel]/[Buck2][buck2] client
treats the three as interchangeable; the differentiation is the Rust single-binary
deployment, the composable stores, and `LRE`, not the protocol.

### 5. CLI / UX ergonomics

**NativeLink ships no build CLI of its own** — its "command boundary" _is the
client's flags_. The developer-facing surface is two parts: a handful of Bazel (or
Buck2 / Reclient / Goma) remote flags, and the `JSON5` config that operators write.

| Concern                 | Mechanism                                                                    |
| ----------------------- | ---------------------------------------------------------------------------- |
| Run the server          | `nativelink path/to/config.json5` (single binary; container image too)       |
| Enable caching          | `--remote_cache=grpc://<endpoint>:50051`                                     |
| Enable remote execution | `--remote_executor=grpc://<endpoint>:50051`                                  |
| Cache namespace         | `instance_name` in config (the `REAPI` instance the client targets)          |
| Worker selection        | action `Platform` properties matched against worker `platform_properties`    |
| Parallelism             | the client's `--jobs=N` (Bazel/Buck2 fan-out), bounded by fleet capacity     |
| Toolchain parity        | `LRE` Nix flake (`nix run`/`bazel` configs generated from one `nixpkgs` pin) |

The target-selection ergonomics (`//...`, `:target`, `--filter`-equivalents,
`--since`) belong entirely to the [Bazel][bazel]/[Buck2][buck2] client, not to
NativeLink. The _operator's_ ergonomics, by contrast, are unusually expressive:
the `JSON5` config (comments, trailing commas, unquoted keys) is the whole control
surface, and the nesting of stores and schedulers means most behavior changes are a
config edit, not a recompile or a flag.

---

## Strengths

- **Single Rust binary, no GC.** One statically-linkable executable runs cache,
  scheduler, and worker roles; no garbage-collector pauses on the build critical
  path; memory-safe by construction. Operationally far lighter than a multi-service,
  Redis-plus-blob-store deployment for small/medium fleets.
- **Composable store stack.** The standout feature — `fast_slow`, `dedup`,
  `compression`, `verify`, `shard`, `size_partitioning`, `existence_cache`, and
  cloud/`redis`/`mongo` backends nest arbitrarily, so storage topology is a
  declarative `JSON5` tree, independently testable layer by layer.
- **`LRE` toolchain hermeticity.** Nix-generated toolchains make local and remote
  actions hash identically, delivering near-100% cache hit rates across laptops, CI,
  and the farm — solving the toolchain-drift cache-miss problem at its root.
- **Drop-in `REAPI` server.** Any `REAPI` client ([Bazel][bazel], [Buck2][buck2],
  Pants, Reclient, Goma, Soong) gets org-wide caching and farm-scale execution by
  changing one URL; no build rewrite.
- **Content-defined deduplication.** `fastcdc` chunking + per-slice `sha256` shares
  storage across partially-overlapping large inputs, not just whole-blob identity.
- **Production-proven at scale.** The project reports billions of requests/month
  for customers including Samsung.

## Weaknesses

- **Bazel-shaped, not language-native.** It only helps clients that already model
  builds as hermetic, content-addressed actions. A tool without that model (`dub`
  today, [Cargo][cargo], [npm][npm]) cannot benefit until it _emits_ `REAPI`
  actions — a large client-side investment.
- **No workspace/topology features of its own.** It contributes nothing to
  workspace declaration, dependency isolation at the package level, or task-DAG
  construction; those are entirely the client's job. In this survey it is a
  _backend_, not a workspace tool.
- **Configuration is powerful but unguarded.** The composable store stack is a
  sharp tool: the `fast_slow` "never re-checks the slow store" subtlety, mismatched
  `instance_name`s, or a `noop` slow store in the wrong place can silently break
  correctness or remote execution. Expressiveness shifts burden onto the operator.
- **Several backends marked `experimental`.** The cloud object store, MongoDB
  store, and parts of the cloud scheduler are explicitly experimental; the most
  battle-tested path is filesystem + `fast_slow`.
- **`LRE`'s parity guarantee is Nix-bound.** The near-perfect cache-hit story
  assumes a Nix-based toolchain and the same `nixpkgs` pin everywhere; teams not on
  Nix get the `REAPI` server but not the headline hermeticity feature.
- **`FSL` license, not pure OSS.** `FSL-1.1-Apache-2.0` restricts competing-product
  use for two years before each release converts to Apache-2.0 — more permissive
  than many source-available licenses, but not OSI-approved-open on day one.
- **Niche audience.** Only meaningful inside the Bazel/Buck2/Pants/Reclient
  ecosystem; the broader package-manager world ([uv][uv], [pnpm][pnpm], `dub`) does
  not speak `REAPI` at all.

## Key design decisions and trade-offs

| Decision                                                               | Rationale                                                                                   | Trade-off                                                                                            |
| ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Implement `REAPI`/`ByteStream`, own no workspace model                 | One protocol serves every client; the build graph stays on the client where it belongs      | Useless to clients that don't already emit content-addressed actions; no topology help               |
| Rust core, garbage-collector-free                                      | No GC pauses on the build critical path; memory safety for safety-critical orgs             | Smaller contributor pool than Go's `REAPI` servers; Rust build/learning curve for hackers            |
| Single binary playing all roles (cache/scheduler/worker)               | Trivial local quickstart; light ops for small fleets; same image scales out by config       | Less prescriptive than a decomposed (Buildbarn) design; large fleets must shard manually             |
| Composable store stack (nested `Store` specs in `JSON5`)               | Storage topology is declarative, layered, reusable, and independently testable              | Powerful but unguarded — wrong nesting (e.g. `fast_slow`/`noop` slow) can silently break correctness |
| Content-defined `dedup` (`fastcdc` + per-slice `sha256`)               | Shares storage across partially-overlapping large blobs, not just whole-file identity       | Extra index store + chunking CPU; tuning `min`/`normal`/`max` chunk sizes is non-obvious             |
| Composable scheduler stack (`cache_lookup`/`property_modifier`/`grpc`) | Same nesting philosophy as stores; local proxy tiers and property rewriting are first-class | Behavior is spread across a stack; reasoning about a multi-layer scheduler takes care                |
| Property-based worker matching (`exact`/`minimum`/`priority`/`ignore`) | Heterogeneous fleets (GPU, specific `ISA`, container images) route correctly                | Operators must keep worker `platform_properties` and action `Platform` requests in sync              |
| `LRE`: Nix-pinned toolchains identical local↔remote                    | Near-100% cache hits by eliminating toolchain drift — the usual cause of spurious misses    | Requires committing to Nix and a shared `nixpkgs` pin; non-Nix teams lose the headline feature       |
| `FSL-1.1-Apache-2.0` (delayed-open license)                            | Funds the project while still converting to Apache-2.0 after two years                      | Not OSI-open on day one; competing-product restriction during the embargo window                     |

---

## Sources

- [TraceMachina/nativelink — GitHub repository][repo] (source for the cited config, stores, and schedulers)
- [`README.md` — positioning, production usage (Samsung, billions of requests), `FSL` license][readme]
- [NativeLink documentation][docs] — concepts, on-prem deployment, `REAPI` setup
- [`nativelink-config/src/stores.rs` — every `StoreSpec` variant + doc comments (`fast_slow`, `dedup`, `compression`, `verify`, …)][stores-src]
- [`nativelink-config/src/schedulers.rs` — `simple`/`grpc`/`cache_lookup`/`property_modifier`, allocation strategy, timeouts][schedulers-src]
- [`nativelink-config/examples/basic_cas.json5` — the end-to-end single-process config quoted above][basic-cas]
- [`local-remote-execution/README.md` — `LRE`: Nix-generated identical local↔remote toolchains][lre-readme]
- [Functional Source License 1.1 (Apache-2.0 future grant)][license]
- [Bazel Remote Execution API (`REAPI`) — the cross-vendor protocol NativeLink implements][remote-apis]
- Related deep-dives: [BuildBuddy][buildbuddy] · [Bazel][bazel] · [Buck2][buck2] · [Pants][pants] · [Please][please] · [Nx][nx] · [Turborepo][turborepo] · [Cargo][cargo] · [pnpm][pnpm] · [the D landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/TraceMachina/nativelink
[readme]: https://github.com/TraceMachina/nativelink/blob/main/README.md
[docs]: https://nativelink.com/docs
[config-src]: https://github.com/TraceMachina/nativelink/tree/main/nativelink-config/src
[stores-src]: https://github.com/TraceMachina/nativelink/blob/main/nativelink-config/src/stores.rs
[schedulers-src]: https://github.com/TraceMachina/nativelink/blob/main/nativelink-config/src/schedulers.rs
[basic-cas]: https://github.com/TraceMachina/nativelink/blob/main/nativelink-config/examples/basic_cas.json5
[lre-readme]: https://github.com/TraceMachina/nativelink/blob/main/local-remote-execution/README.md
[license]: https://github.com/TraceMachina/nativelink/blob/main/LICENSE
[remote-apis]: https://github.com/bazelbuild/remote-apis
[buildbuddy]: ../buildbuddy/
[bazel]: ../bazel/
[buck2]: ../buck2/
[pants]: ../pants/
[please]: ../please/
[nx]: ../nx/
[turborepo]: ../turborepo/
[cargo]: ../cargo/
[go-work]: ../go-work/
[npm]: ../npm/
[pnpm]: ../pnpm/
[uv]: ../uv/
[glommio]: ../../async-io/glommio.md
[tokio]: ../../async-io/tokio.md
[d-landscape]: ../../async-io/d-landscape.md
