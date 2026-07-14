# Buildbarn (Remote execution)

A modular, horizontally-scalable Go implementation of Bazel's Remote Execution
API (`REAPI`) — a content-addressable cache (`CAS` + `ActionCache`), a
size-class-aware scheduler, and a worker/runner split that streams build actions
onto a farm — assembled not as a monolith but as a tree of composable
`BlobAccess` decorators and gRPC daemons (`bb-storage`, `bb-scheduler`,
`bb-worker`, `bb-runner`, `bb-browser`) wired together by Jsonnet configuration.

| Field           | Value                                                                                                                |
| --------------- | -------------------------------------------------------------------------------------------------------------------- |
| Language        | Go (server daemons; ~94%) + Starlark (Bazel build rules) + Jsonnet (configuration)                                   |
| License         | Apache-2.0                                                                                                           |
| Repository      | [buildbarn/bb-storage][bb-storage] · [buildbarn/bb-remote-execution][bb-re] · [buildbarn/bb-deployments][bb-deploy]  |
| Documentation   | [Architecture Decision Records (`bb-adrs`)][bb-adrs] · in-repo `README.md` + `.proto` config schemas                 |
| Category        | Remote Execution Backend                                                                                             |
| Workspace model | **None of its own** — it is the _server_ side of the `REAPI`; the "workspace" belongs to the client ([Bazel][bazel]) |
| First released  | 2018 (initial public `bb-storage`/`bb-remote-execution` repos)                                                       |
| Latest release  | Date-tagged CI builds, e.g. `bb-remote-execution` `20260601T183023Z-ca3fedb` (June 1, 2026)                          |

> **Latest release:** Buildbarn does **not** cut semantic versions. Each repo
> publishes **date-based CI tags** of the form `YYYYMMDDTHHMMSSZ-<commit>` —
> `bb-storage` was at `20260527T152149Z-3991d6e` (May 27, 2026) and
> `bb-remote-execution` at `20260601T183023Z-ca3fedb` (June 1, 2026) as of this
> review. Its real compatibility surface is the wire-level **Remote Execution
> API** (`REAPI` v2) and the **ByteStream**/`ContentAddressableStorage` gRPC
> services, not a manifest format — exactly as for sibling backends
> [BuildBuddy][buildbuddy] and the Rust-native NativeLink. Consumers pin a Git
> commit (Bazel `http_archive` / `go.mod` pseudo-version), not a release number.

---

## Overview

### What it solves

Buildbarn is **not** a workspace tool, a package manager, or a build system. Like
[BuildBuddy][buildbuddy], it has no manifest, no `members` array, no dependency
resolver, and no concept of a "project." It is the _server side_ of the
remote-build contract that [Bazel][bazel] (and [Buck2][buck2], BuildStream,
`recc`) speak: the client hashes a build **action** — an `Action` proto pointing
at a `Command` and an input `Directory` tree, all stored by digest — and ships it
over gRPC. Buildbarn either (a) returns a cached `ActionResult` if that exact
digest has executed before anywhere in the fleet, or (b) queues the action,
matches it to a worker, runs it in an isolated directory, and uploads the outputs
back into the `CAS`.

It earns a place in this monorepo survey for the same reason the other
[remote-execution backends][buildbuddy] do: the **caching & remote-execution**
dimension (dimension 4) of a large monorepo is routinely _outsourced_ to a
`REAPI` backend. Where a language-native package manager ([Cargo][cargo], `dub`,
[Go modules][go-work]) re-runs every compile on every machine, a `REAPI` server
models each action as a pure function of its inputs and memoizes it
fleet-wide — turning a 4-core laptop's `bazel build //...` into the throughput of
a worker cluster while guaranteeing a hermetic, uniform build environment.

Within the survey's backend trio, Buildbarn is the **most modular and
self-hostable** of the three: where BuildBuddy ships an opinionated open-core
binary plus a managed cloud, Buildbarn is a kit of small single-purpose Go
daemons you compose yourself, and where the Rust-native NativeLink emphasizes a
single fast process, Buildbarn leans into a many-process, decorator-stack
topology that scales by sharding stateless frontends in front of stateful
storage.

### Design philosophy

From the `bb-storage` `README.md` ([buildbarn/bb-storage][bb-storage-readme]):

> _"The Buildbarn project provides an implementation of the Remote Execution
> protocol. This protocol is used by tools such as Bazel, BuildStream and recc to
> cache and optionally execute build actions remotely. … This repository provides
> Buildbarn's storage daemon. This daemon can be used to build a scalable build
> cache."_

Three principles follow from that framing, and they shape the whole codebase:

1. **Storage is a stack of composable decorators, not a backend.** The central
   interface is `BlobAccess` — "store a blob by digest / fetch a blob by digest."
   Every capability (sharding, mirroring, read-through caching, completeness
   checking, on-disk persistence) is a `BlobAccess` _decorator_ wrapping an inner
   `BlobAccess`. A production storage tier is literally a nested expression of
   these decorators, written in Jsonnet. (See [Dependency handling &
   isolation](#dependency-handling--isolation-cas-as-the-virtual-store).)
2. **The build farm is many small daemons, not one server.** Stateless
   _frontends_ fan RPCs out across _sharded storage_; a _scheduler_ owns the
   operation queue; _workers_ pull actions and orchestrate I/O; _runners_ do
   nothing but `fork`/`exec` the command. Each is independently scalable.
3. **A build action is a content-addressed pure function.** Inputs, command, and
   environment are all hashed into an `Action` digest; the result is keyed by that
   digest in the `ActionCache`. This is the same memoization thesis that powers
   [Bazel][bazel], [Buck2][buck2], [Nx][nx], and [Turborepo][turborepo] — but
   Buildbarn implements the _server_ that makes it shareable across a fleet.

The project is unusually well-documented for its category through its
**Architecture Decision Records** ([buildbarn/bb-adrs][bb-adrs]), which narrate
the storage redesign (`0002-storage`), CAS decomposition (`0003`), the on-disk
persistency model (`0005`), the NFSv4 virtual filesystem (`0009`), the
filesystem-access cache (`0010`), and rendezvous hashing (`0011`).

---

## How it works

### The component topology

A Buildbarn cluster is a set of cooperating gRPC daemons. The
[`bb-deployments`][bb-deploy] repo ships ready-to-run `docker-compose`, `bare`,
and `kubernetes` variants of exactly this topology:

| Daemon                | Repo            | Role                                                                                                |
| --------------------- | --------------- | --------------------------------------------------------------------------------------------------- |
| `bb-storage` frontend | `bb-storage`    | **Stateless** gRPC frontend: terminates `CAS`/`AC`/`Execution`/`ByteStream`, fans out to shards     |
| `bb-storage` (shard)  | `bb-storage`    | **Stateful** on-disk `LocalBlobAccess` shard holding part of the keyspace                           |
| `bb-scheduler`        | `bb-re`         | Owns the in-memory operation queue; matches actions to workers by platform + size class             |
| `bb-worker`           | `bb-re`         | Pulls actions from the scheduler, populates the input root, orchestrates execution, uploads outputs |
| `bb-runner`           | `bb-re`         | Minimal `fork`/`exec` helper that actually runs the `Command` (privilege-separated from the worker) |
| `bb-browser`          | `bb-browser`    | Web UI for inspecting actions, action results, failed builds, and `CAS` contents                    |
| `bb-autoscaler`       | `bb-autoscaler` | Scales worker count from the scheduler's queue depth                                                |

> [!NOTE]
> The split between a **stateless frontend** and **stateful sharded storage** is
> the deployment keystone. As the `bb-deployments` docs put it: _"Sharded storage,
> using the Buildbarn storage daemon. To apply the sharding to client RPCs, a
> separate set of stateless frontend servers is used to fan out requests."_ The
> rationale is that the `ByteStream` path is CPU/memory/network-intensive while
> the scheduling load is light, so the two scale independently.

### The action lifecycle

A single `bazel build` action traverses the cluster as follows:

1. **Upload inputs.** The client writes the `Command`, input files, and nested
   `Directory` protos into the `CAS` via `ByteStream.Write`, addressing each by
   `{hash, size_bytes}`.
2. **Check the cache.** It calls `ActionCache.GetActionResult(actionDigest)`. A
   hit returns the recorded `ActionResult` (output digests, exit code, stdout) and
   the build skips execution entirely — this is the **remote cache** path that
   most CI traffic uses.
3. **Queue for execution.** On a miss, the client calls
   `Execution.Execute(actionDigest)` against the frontend, which forwards to
   `bb-scheduler`. The scheduler enqueues an `Operation` in the platform/size-class
   queue keyed by the action's `Platform` properties.
4. **Worker pulls.** A `bb-worker` whose advertised platform matches dequeues the
   operation, lazily materializes the input root (see [virtual filesystem](#task-orchestration--scheduling)),
   and hands the prepared directory to `bb-runner`.
5. **Run + upload.** `bb-runner` executes the `Command`; `bb-worker` captures
   outputs, writes them into the `CAS`, records an `ActionResult` in the
   `ActionCache`, and streams `ExecuteResponse` back to the client.

Pointing a client at the cluster is a matter of `REAPI` flags — there is no
Buildbarn-specific client. From [`bb-deployments`][bb-deploy]:

```bash
bazel build \
    --remote_executor=grpc://localhost:8980 \
    --remote_instance_name=fuse \
    --remote_default_exec_properties=OSFamily=linux \
    --remote_default_exec_properties=container-image="docker://..." \
    @abseil-hello//:hello_main
```

The `8980` gRPC endpoint multiplexes `ContentAddressableStorage`, `ActionCache`,
`Capabilities`, `ByteStream`, and `Execution` onto one port; `--remote_cache=` may
point at the same address to use caching without remote execution.

### Storage as a `BlobAccess` decorator stack

`LocalBlobAccess` is the leaf on-disk backend introduced in ADR `0002-storage` to
replace the older `inMemory` and (buggy) `circular` backends. Its design goal is
**self-cleaning storage with no garbage collector**, achieved by writing into a
fixed set of rotating blocks and never overwriting live data in place:

> _"An easy way to prevent data corruption is thus to stop overwriting existing
> data. Instead, we can let it keep track of its data by storing it in a small set
> of blocks."_ — [`bb-adrs/0002-storage.md`][bb-adr-storage]

> _"Whereas 'circular' uses FIFO eviction, we can let our new backend provide
> LRU-like eviction by copying blobs from older blocks to newer ones upon
> access."_ — [`bb-adrs/0002-storage.md`][bb-adr-storage]

That pseudo-LRU "refresh on access" is what makes Buildbarn safe for Bazel's
_Builds without the Bytes_ (`--remote_download_minimal`), where the `CAS` must not
evict a blob the running build still references. Writes are _smeared_ across
blocks so refresh waves don't cascade.

Everything above the leaf is a decorator. A production `blobstore` is a Jsonnet
expression composing them:

```jsonnet
// Conceptual blobstore config (bb-storage Jsonnet schema)
local contentAddressableStorage = {
    sharding: {                         // ShardingBlobAccess: split keyspace
        shards: [
            { backend: { grpc: { address: 'storage-0:8981' } } },
            { backend: { grpc: { address: 'storage-1:8981' } } },
        ],
    },
};
```

| Decorator (`BlobAccess`)         | What it adds                                                                          |
| -------------------------------- | ------------------------------------------------------------------------------------- |
| `LocalBlobAccess`                | Leaf on-disk store: a big file indexed by a hash table, self-cleaning, no GC          |
| `ShardingBlobAccess`             | Partitions the digest keyspace across N backends (hash → shard); scales beyond a box  |
| `MirroredBlobAccess`             | RAID-1 replication across a pair of backends; `Sharding`+`Mirrored` ≈ RAID-10         |
| `ReadCachingBlobAccess`          | A fast local cache in front of a remote source-of-truth (write-through, read-fill)    |
| `CompletenessCheckingBlobAccess` | Verifies that an `ActionResult`'s referenced blobs all still exist before a cache hit |
| `grpc` backend                   | Forwards `BlobAccess` calls to another `bb-storage` over gRPC (frontend → shard)      |

ADR `0011-rendezvous-hashing` later refined `ShardingBlobAccess` to use
**rendezvous (HRW) hashing** so that adding or removing a shard reshuffles only a
`1/N` fraction of the keyspace instead of remapping everything.

---

## Workspace declaration & topology

**Not applicable as a first-class feature — by design.** Buildbarn has no
workspace manifest, no `members` glob, no root config that enumerates packages.
The unit of work it understands is a single `REAPI` `Action`, not a project graph.
The "topology" it _does_ declare is its own **cluster topology** — which daemons
exist, how storage is sharded, and which platform queues the scheduler offers —
expressed in **Jsonnet** configuration files (one per daemon), not in a build
manifest.

The closest analogue to a "workspace selector" is the **`instance_name`**: a
`REAPI` request carries an instance name (`--remote_instance_name=fuse` above),
and Buildbarn can route different instance names to different storage tiers or
scheduler queues — a coarse multi-tenancy axis rather than a member-package list.

For how a _client_ declares the workspace whose actions land here, see the build
tools that drive it: [Bazel][bazel] (`WORKSPACE`/`MODULE.bazel`, `BUILD` files)
and [Buck2][buck2]. Buildbarn never sees those files; it only ever sees the
hashed action graph they compile down to.

## Dependency handling & isolation (CAS as the virtual store)

This is where a remote-execution backend's analogue to "dependency isolation" and
"virtual store" lives, and Buildbarn's answer is the **content-addressable store**
itself. Every input — source file, header, compiler binary, intermediate
artifact — is a `CAS` blob addressed by `{sha256, size}`. This gives properties a
package manager's hoisting/symlink scheme strives for, for free:

- **Perfect deduplication.** Two actions sharing a header reference the same `CAS`
  digest; the bytes are stored once across the entire fleet. This is the
  content-addressed equivalent of [pnpm][pnpm]'s global store or [Nix][nix-flakes]'s
  `/nix/store`, but keyed by build-artifact hash rather than package version.
- **Hermetic input roots.** Each action's input root is an exact, immutable
  `Directory` tree of digests. The worker materializes _only_ those inputs into an
  isolated build directory — there is no ambient filesystem, no hoisted
  `node_modules`, no version drift. Isolation is total because the input set is
  enumerated by digest up front.
- **Indirection for external assets.** ADR `0004-icas` adds an **Indirect CAS**
  (`ICAS`) that stores _references_ to remote assets (URLs) rather than copying
  their bytes into central storage, so bandwidth-limited clients don't have to
  upload large external blobs; workers fetch them on demand.

Cross-action "dependencies" are therefore implicit: action B depends on action A
iff B's input root contains a digest that A produced as output. The client (Bazel)
computes that graph; Buildbarn just resolves digests against the `CAS`. There is
no `workspace:` protocol because there is no notion of a sibling local package —
only digests.

## Task orchestration & scheduling

The orchestration story splits across **`bb-scheduler`** (the DAG executor's
queue) and **`bb-worker`** (per-action I/O and execution).

### The scheduler, platform queues, and size classes

`bb-scheduler` receives `Execute` requests and maintains an **in-memory operation
queue** partitioned by the action's `Platform` properties (e.g.
`OSFamily=linux`, `container-image=...`). Workers advertise the platform they
satisfy and pull matching operations — a pull-based, not push-based, dispatch.

On top of platform matching sits Buildbarn's distinctive **size-class** feature:
the same logical platform can be backed by several worker _size classes_ (e.g.
small vs. large machines), and the scheduler learns which actions need the big
machines. It records per-action-key execution statistics in an **Initial Size
Class Cache** (`ISCC`), a gRPC service in `pkg/proto/iscc` exposing
`GetPreviousExecutionStats` / `UpdatePreviousExecutionStats`. On a new action it
predicts a size class from the history of similar actions, runs it there, and — if
a small machine times out — **falls back** to a larger class, feeding the outcome
back into the `ISCC`. This is a feedback-driven autoscaling-of-machine-size that
the other backends in this survey do not implement.

> [!NOTE]
> The `ISCC` is _not_ the `ActionCache`. The `AC` memoizes an action's _result_;
> the `ISCC` memoizes an action's _resource profile_ (how long it ran, which size
> class succeeded) to schedule the _next_ similar action better. Both are keyed off
> the action, but they answer different questions.

### The worker / runner split

`bb-worker` owns the per-action data plane; `bb-runner` is a deliberately minimal
process that only spawns the command. The README gives three reasons for the
split ([buildbarn/bb-remote-execution][bb-re-readme]):

> _"To make it possible to use privilege separation. Privilege separation is used
> to prevent build actions from overwriting input files."_

> _"To make execution pluggable. `bb_worker` communicates with `bb_runner` using
> a simple gRPC-based protocol."_

> _"To work around a race condition that effectively prevents multi-threaded
> processes from writing executables to disk and spawning them."_

Privilege separation runs `bb-worker` as root (UID 0) and the build as an
unprivileged `build` user (UID 1), so an action cannot corrupt the hardlinked
input cache. The pluggable-runner seam is also how custom execution
environments — e.g. running foreign-architecture actions under QEMU — are slotted
in without touching the worker.

### The virtual input root (lazy CAS materialization)

The orchestration optimization that defines Buildbarn is that workers **do not
download the whole input root before running**. Instead the worker mounts a
**virtual filesystem** over the build directory and lazily fetches each blob from
the `CAS` on first access. Two backends exist:

- **FUSE** — the original userspace filesystem.
- **NFSv4** — a from-scratch in-process NFSv4 server (ADR `0009-nfsv4`), motivated
  by FUSE's portability and performance limits (notably on macOS). Because FUSE and
  NFSv4 are _"conceptually identical request-response based services for accessing
  a POSIX-like file system,"_ the shared logic was refactored into a
  protocol-independent `pkg/filesystem/virtual` package, with `nfsv4` and `fuse`
  as thin front-ends.

ADR `0010-file-system-access-cache` goes further: it records _which_ files of an
input root an action actually reads, so the worker can prefetch just those next
time instead of faulting them in lazily. The net effect is that an action with a
10 GB declared input root that touches 50 MB transfers ~50 MB, not 10 GB — the
remote-execution analogue of a build system's fine-grained change detection.

Concurrency is horizontal and pull-based: arbitrarily many `bb-worker` processes
pull from one `bb-scheduler`, and `bb-autoscaler` adjusts the worker count from
queue depth. There is no single-process work-stealing scheduler as in
[Bazel][bazel] itself — the parallelism unit is a whole worker machine.

## Caching & remote execution

Caching _is_ the product. Buildbarn implements the full `REAPI` cache surface:

- **`ContentAddressableStorage` + `ByteStream`** — the blob store for inputs and
  outputs, with the `LocalBlobAccess`/`Sharding`/`Mirrored` stack above.
- **`ActionCache`** — maps an action digest to its `ActionResult`. A hit is a
  zero-execution build step.
- **`CompletenessCheckingBlobAccess`** — before serving an `AC` hit, it verifies
  every blob the `ActionResult` references still lives in the `CAS`, so a partially
  evicted result is treated as a miss rather than a broken download.
- **Wire compression** (ADR `0012`) — ByteStream payloads can be transferred
  zstd-compressed.

Because it _is_ a `REAPI` server, Buildbarn is a drop-in cache/execution backend
for any `REAPI` client — the same role filled by [BuildBuddy][buildbuddy] and
NativeLink, and consumed identically by [Bazel][bazel], [Buck2][buck2], and
(via `REAPI`) [Pants][pants] and [Please][please]. A monorepo whose build tool
emits `REAPI` actions can point `--remote_cache`/`--remote_executor` at a
Buildbarn cluster and get fleet-wide memoization plus distributed execution
without changing a line of `BUILD` files.

What Buildbarn does **not** provide is the _client-side_ machinery that decides
_what_ an action is — the hashing, the input-tree construction, the affected-target
analysis. That is the build tool's job. Buildbarn is the substrate; the
[task-DAG and change-detection][turborepo] live in the client.

## CLI / UX ergonomics

Buildbarn has **no developer CLI** in the package-manager sense — no
`--filter`, no `-p`, no `:target`, no `--since`. Its three user surfaces are:

1. **Daemon binaries + Jsonnet config.** Operators run `bb_storage config.jsonnet`,
   `bb_scheduler config.jsonnet`, `bb_worker config.jsonnet`, etc. The "UX" is the
   configuration schema (defined in `.proto` files, written in Jsonnet), and the
   `bb-deployments` repo's `./run.sh` one-liner that brings a whole cluster up.
2. **The `REAPI` gRPC flags on the client.** All developer-facing ergonomics are
   the build _client's_ flags — `--remote_executor`, `--remote_cache`,
   `--remote_instance_name`, `--remote_default_exec_properties`,
   `--remote_download_minimal`. Buildbarn is invisible behind them.
3. **`bb-browser`.** A web UI to inspect an action, its input root, its
   `ActionResult`, stdout/stderr, and timing — the debugging surface when a remote
   action fails or a cache key behaves unexpectedly. Failed-build URLs from Bazel
   deep-link into it.

For a monorepo author, the takeaway is that the _filter/slice/since_ ergonomics
this survey cares about live entirely in the client ([Bazel][bazel],
[Turborepo][turborepo], [Nx][nx]); Buildbarn's ergonomics are an _operator's_
concern — provisioning, sharding, and sizing a cluster.

---

## Strengths

- **Maximally modular and self-hostable.** A kit of small, single-purpose Go
  daemons you compose with Jsonnet; no vendor lock-in, Apache-2.0, runs on bare
  metal, `docker-compose`, or Kubernetes via `bb-deployments`.
- **Composable storage decorators.** `Sharding` + `Mirrored` + `ReadCaching` +
  `CompletenessChecking` stack into RAID-10-like, geo-replicated, self-cleaning
  storage tiers declaratively, with no GC.
- **Lazy virtual input roots (FUSE/NFSv4).** Workers fault inputs in on demand and
  (with the file-system-access cache) prefetch only what an action reads — huge
  for sparse access over large input roots and _Builds without the Bytes_.
- **Size-class smart scheduling.** The `ISCC` learns each action's resource
  profile and right-sizes the machine, with automatic fallback — unique among the
  surveyed backends.
- **Stateless-frontend scaling.** Decoupling the CPU/network-heavy ByteStream path
  from the light scheduling path lets each scale independently.
- **Exceptional design documentation.** The `bb-adrs` record the reasoning behind
  every major redesign — rare for infrastructure of this kind.

## Weaknesses

- **Operationally heavy.** Many daemons, sharded stateful storage, Jsonnet config,
  and a FUSE/NFSv4 mount per worker make a production cluster a real ops project;
  [BuildBuddy][buildbuddy]'s managed cloud is far lower-effort to adopt.
- **No semantic versioning.** Date-tagged CI builds mean consumers pin Git commits
  and must track compatibility themselves; there is no "stable release" line.
- **Not a workspace/monorepo tool at all.** It contributes only dimension 4
  (caching/remote execution); the workspace declaration, task DAG, and
  change-detection all live in the client. It is a backend, not a front door.
- **`REAPI`-coupled.** Useful only to build tools that speak the Remote Execution
  API; a tool without `REAPI` output (today, `dub`) cannot use it without first
  emitting `REAPI` actions.
- **Sparse prose documentation.** Outside the ADRs and `.proto` schemas, learning
  Buildbarn means reading Go and Jsonnet; there is no polished docs site.

## Key design decisions and trade-offs

| Decision                                      | Rationale                                                                                   | Trade-off                                                                                   |
| --------------------------------------------- | ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| Many small daemons, not a monolith            | Each tier (frontend / storage / scheduler / worker / runner) scales and fails independently | Operationally complex; more moving parts, more config, more failure modes than one binary   |
| Stateless frontend ⟂ stateful sharded storage | ByteStream is CPU/network-heavy; scheduling is light — scale them separately                | An extra network hop; the frontend tier is one more thing to deploy and monitor             |
| Storage as composable `BlobAccess` decorators | RAID-10 / read-through / completeness-checking tiers built declaratively from one interface | The "right" stack is non-obvious; misconfiguration silently degrades durability or hit rate |
| `LocalBlobAccess`: blocks + hash index, no GC | Self-cleaning, corruption-resistant on-disk store; LRU-ish refresh keeps live blobs         | Capacity is fixed by block count; eviction is approximate, not exact LRU                    |
| Worker ⟂ runner process split                 | Privilege separation, pluggable execution (QEMU), dodges Go's fork/exec-of-executable race  | Extra gRPC hop per action; two processes to deploy and reason about per worker              |
| Lazy virtual input root (FUSE / NFSv4)        | Transfer only the bytes an action touches; enables _Builds without the Bytes_               | A filesystem mount per worker; FUSE/NFS performance and portability quirks (hence NFSv4)    |
| Size-class scheduling via the `ISCC`          | Right-size machines from learned per-action history; cheap actions don't book big workers   | Cold-start mispredictions; an extra cache to operate; fallback re-runs waste the first try  |
| Date-tagged CI builds, no semver              | Continuous delivery; the wire `REAPI` is the contract, not a release number                 | Consumers pin commits and own compatibility; no curated stable line                         |
| Rendezvous (HRW) hashing for sharding         | Adding/removing a shard reshuffles only `1/N` of keys, not the whole keyspace               | Slightly more per-request hashing than a modulo scheme                                      |

---

## Relevance to `dub`

Buildbarn is a _backend_, not a workspace tool, so it informs `dub` obliquely —
through the **shape of the contract** a workspace tool needs in order to _consume_
remote execution, not through manifest syntax:

- **Content-addressed action memoization is the end-state.** The reason a
  [`[workspace]`][cargo] with a unified lockfile and a topological build loop
  matters is that it makes builds _cacheable as pure functions_. Buildbarn shows
  the payoff: once an action is a digest, the result is shareable across an entire
  fleet. A future `dub` that hashes a compile invocation + its exact inputs could,
  in principle, emit `REAPI` actions and reuse Buildbarn unchanged — the backend is
  language-agnostic.
- **The client owns the graph; the server owns the cache.** Buildbarn deliberately
  knows nothing about workspaces, members, or affected-target detection. That clean
  split tells `dub` exactly where its own work lies: the workspace topology, the
  task DAG, and `--since` change-detection are _client_ concerns
  ([Turborepo][turborepo], [Nx][nx]); only the content-addressed cache layer is
  outsourceable. `dub`'s near-term wins ([unified lockfile, topological
  execution][go-work]) are all client-side and must exist before any backend is
  worth wiring up.
- **Lazy, hash-keyed inputs beat hoisting.** Buildbarn's virtual input root —
  fetch only the digests an action touches — is the content-addressed answer to the
  dependency-isolation problem that [pnpm][pnpm] solves with symlinks and
  [Cargo][cargo] with a shared target dir. A `dub` build cache keyed on input
  digests would get the same deduplication without a hoisting scheme.

See the [comparison][comparison] synthesis for how the three remote-execution
backends ([BuildBuddy][buildbuddy], Buildbarn, NativeLink) relate to the
client-side tools, and [d-landscape][d-landscape] for where `dub` sits today.

---

## Sources

- [buildbarn/bb-storage — storage daemon (`CAS`/`AC`/frontends)][bb-storage]
- [buildbarn/bb-remote-execution — scheduler, worker, runner][bb-re]
- [buildbarn/bb-deployments — docker-compose / bare / kubernetes topologies][bb-deploy]
- [buildbarn/bb-adrs — Architecture Decision Records][bb-adrs]
- [`bb-adrs/0002-storage.md` — `LocalBlobAccess`, decorators, no-GC eviction][bb-adr-storage]
- [`bb-adrs/0009-nfsv4.md` — virtual filesystem, FUSE → NFSv4][bb-adr-nfsv4]
- [`bb-storage` `README.md` — project positioning (quoted)][bb-storage-readme]
- [`bb-remote-execution` `README.md` — worker/runner split (quoted)][bb-re-readme]
- [Bazel Remote Execution API (`REAPI`)][reapi]
- Sibling backends & clients: [BuildBuddy][buildbuddy] · [Bazel][bazel] · [Buck2][buck2] · [Pants][pants] · [Please][please]
- Related dimensions: [Turborepo][turborepo] · [Nx][nx] · [Cargo][cargo] · [pnpm][pnpm] · [Nix flakes][nix-flakes] · [Go `go.work`][go-work] · [comparison][comparison] · [`dub` landscape][d-landscape]

<!-- References -->

[bb-storage]: https://github.com/buildbarn/bb-storage
[bb-storage-readme]: https://github.com/buildbarn/bb-storage/blob/bdd785e3d1daccb280256016129d12198ea50e39/README.md
[bb-re]: https://github.com/buildbarn/bb-remote-execution
[bb-re-readme]: https://github.com/buildbarn/bb-remote-execution/blob/b5d49abbef7b81a98b31cf8d08e4bb8695a0bf08/README.md
[bb-deploy]: https://github.com/buildbarn/bb-deployments
[bb-adrs]: https://github.com/buildbarn/bb-adrs
[bb-adr-storage]: https://github.com/buildbarn/bb-adrs/blob/00164e0caac384cc3c76e875773a1053fb1c4ef6/0002-storage.md
[bb-adr-nfsv4]: https://github.com/buildbarn/bb-adrs/blob/00164e0caac384cc3c76e875773a1053fb1c4ef6/0009-nfsv4.md
[reapi]: https://github.com/bazelbuild/remote-apis
[buildbuddy]: ../buildbuddy/
[bazel]: ../bazel/
[buck2]: ../buck2/
[pants]: ../pants/
[please]: ../please/
[turborepo]: ../turborepo/
[nx]: ../nx/
[cargo]: ../cargo/
[pnpm]: ../pnpm/
[nix-flakes]: ../nix-flakes/
[go-work]: ../go-work/
[comparison]: ../comparison.md
[d-landscape]: ../../async-io/d-landscape.md
