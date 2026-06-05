# BuildBuddy (Remote execution)

An open-core, horizontally-scalable implementation of Bazel's Remote Execution
API (`REAPI`) — a `CAS` + `ActionCache` remote cache, a Redis-backed task
scheduler, and an autoscaling pool of containerized executors — written in Go and
React, that turns `bazel build //...` into a build that physically runs across a
farm of worker nodes and caches every action result org-wide.

| Field           | Value                                                                                                               |
| --------------- | ------------------------------------------------------------------------------------------------------------------- |
| Language        | Go (server, scheduler, executor) + React/TypeScript (web UI)                                                        |
| License         | MIT (open core; an enterprise edition adds auth, autoscaling, Firecracker, SSO)                                     |
| Repository      | [buildbuddy-io/buildbuddy][repo]                                                                                    |
| Documentation   | [buildbuddy.io/docs][docs] · [RBE Setup][rbe-setup] · [RBE Platforms][rbe-platforms]                                |
| Category        | Remote Execution Backend                                                                                            |
| Workspace model | **None of its own** — it is a _server_ for a build client (Bazel / [Buck2][buck2]); the "workspace" is the client's |
| First released  | 2019 (public open-source repo; company founded 2020)                                                                |
| Latest release  | `v2.275.0` (June 4, 2026)                                                                                           |

> **Latest release:** `v2.275.0`, cut **June 4, 2026** — one of a continuous
> stream of roughly bi-weekly `v2.x` server releases (the prior tag `v2.274.0`
> landed June 2, 2026). BuildBuddy ships no semantic "workspace" version: the
> server's contract is the wire-level **Remote Execution API** (`REAPI` v2) and
> **Build Event Protocol** (`BEP`), so its compatibility surface is the gRPC
> protocol, not a manifest format. As of June 5, 2026 it is offered as a managed
> cloud (`remote.buildbuddy.io`) and as a self-hostable Docker image.

---

## Overview

### What it solves

BuildBuddy is **not** a workspace tool, a package manager, or a build system. It
has no manifest, no `members` array, no dependency resolver, and no notion of a
"project." It is the _server side_ of the remote-build contract that [Bazel][bazel]
and [Buck2][buck2] speak: a thin build client running on a developer's laptop or a
CI runner ships **actions** — a command plus its exact declared input tree — over
gRPC, and BuildBuddy (a) returns a cached result if that action has run before
anywhere in the org, or (b) schedules the action onto a remote worker, runs it in
an isolated container, and streams the outputs back. It belongs in this monorepo
survey for the same reason `NativeLink` and `Buildbarn` do:
the _caching and remote-execution_ dimension (dimension 4) of a large monorepo is
often **outsourced** to a `REAPI` backend, and BuildBuddy is the most widely
deployed open-source one.

The problem it attacks is the one that defeats every language-native package
manager ([Cargo][cargo], `dub`, [Go modules][go-work]) at monorepo scale:
**redundant work.** In a repo with hundreds of thousands of targets, the same
compile/test action is run over and over — across every engineer's machine, every
CI shard, every branch. Bazel models each action as a pure function of its inputs
and hashes them into an **action digest**; BuildBuddy stores the result of that
function keyed by the digest in a **content-addressable store (`CAS`)**, so the
second time _anyone_ requests an action with the same digest, the bytes are
fetched instead of recomputed. Remote _execution_ extends this from "cache the
result" to "also run the function on a shared farm," giving a 4-core laptop the
throughput of a hundred-machine cluster (`--jobs=50` and up) and a uniform,
hermetic build environment regardless of the client OS.

### Design philosophy

From the project `README` ([`README.md`][readme]):

> _"BuildBuddy is an open source Bazel build event viewer, result store, and
> remote cache. It helps you collect, view, share and debug build events in a
> user-friendly web UI. It's written in Golang and React and can be deployed as a
> Docker image. … BuildBuddy's core is open sourced in this repo under the MIT
> License."_

The docs introduction reframes this as an "open-core developer productivity
platform built for Bazel" ([`docs/introduction.mdx`][intro]):

> _"BuildBuddy is the open-core developer productivity platform built for Bazel.
> Speed up your builds with remote caching and remote execution …"_

Three architectural commitments follow, and they shape the whole system:

1. **The client owns the workspace; the server owns the work.** BuildBuddy
   deliberately knows nothing about `WORKSPACE`/`MODULE.bazel`, packages, or
   targets. Everything it sees is post-analysis: a stream of `Action`s addressed by
   digest. This is the inverse of [Nx][nx]/[Turborepo][turborepo], which own a
   project graph and a task pipeline; BuildBuddy is the substrate _under_ such an
   engine, reachable by any client that speaks `REAPI`.
2. **Stateless, horizontally scalable app tier.** The "app" servers (which
   terminate the gRPC `REAPI`/`BEP` services) hold no per-build state — coordination
   lives in **Redis** and durable bytes live in **blob storage** (disk / `GCS` /
   `S3`). Any app replica can serve any request, so the tier scales by adding
   replicas behind a load balancer ([`docs/remote-build-execution.md`][rbe-doc]
   lists _"Stateless, horizontally scalable architecture"_ as a headline feature).
3. **Content addressing is the whole correctness model.** Because every artifact is
   named by the digest of its bytes, the cache is immutable and self-verifying, and
   "build without the bytes" (let the client skip downloading intermediate outputs
   it does not need) becomes safe — the digest in the `ActionResult` is a sufficient
   proof of identity.

BuildBuddy sits in the same `REAPI`-backend family as `NativeLink`
(Rust, single-binary) and `Buildbarn` (Go, Kubernetes-native, highly
decomposed); the shared wire protocol is the reason a [Bazel][bazel] or
[Buck2][buck2] client can swap one for another by changing a single
`--remote_executor` URL. For how the client side drives this contract, see the
[Bazel][bazel] and [Buck2][buck2] deep-dives; for the D-language gap this whole
class of tooling exposes, see [the D landscape][d-landscape].

---

## Core components and gRPC surface

BuildBuddy is two deployables that talk over gRPC and Redis: the **app** (the
stateless server tier) and the **executor** (the worker that actually runs
actions). The app implements the standard `REAPI`/`BEP` services a Bazel client
connects to; an internal `Scheduler` service brokers work to executors.

| Concept                | Component / service                                                      | Role                                                                                   |
| ---------------------- | ------------------------------------------------------------------------ | -------------------------------------------------------------------------------------- |
| Cache (read/write)     | `ContentAddressableStorage`, `ByteStream`, `ActionCache`, `Capabilities` | Standard `REAPI` cache services the client hits for digests and action results         |
| Remote execution       | `Execution` service (`execution_server`)                                 | Accepts `Execute`/`WaitExecution`; turns an action digest into a scheduled task        |
| Scheduler              | `Scheduler` service (`scheduler_server`)                                 | Brokers tasks to executors via `ScheduleTask` / `EnqueueTaskReservation` / `LeaseTask` |
| Task routing           | `task_router`                                                            | Picks _preferred_ executors (affinity) for a task; Redis-backed routing table          |
| Action dedup / hedging | `action_merger`                                                          | Merges concurrent identical executions into one; Redis-backed                          |
| Executor               | `executor` + `runner` + `priority_task_scheduler`                        | Pulls leased tasks, materializes the input tree, runs the command in isolation         |
| Isolation              | `containers/` (`oci`, `podman`, `docker`, `firecracker`, `sandbox`)      | One **runner** per concurrent action; a **workspace** dir holds the input tree         |
| VM snapshots           | `snaploader` / `copy_on_write` / `uffd`                                  | Firecracker microVM snapshot/restore for fast warm starts                              |
| Local artifact cache   | `filecache`                                                              | Per-executor content-addressed cache of inputs/tools to avoid re-downloading           |
| Storage backends       | `cache` config (`disk` / `redis_target` / `gcs` / `s3`)                  | Three-tier durable blob storage under the `CAS`                                        |

### The standard REAPI client contract

A Bazel client never names BuildBuddy components directly; it points three flags
at the same gRPC endpoint and BuildBuddy multiplexes the services
([`README.md`][readme], [`rbe-setup.md`][rbe-setup]):

```bash
# .bazelrc — the minimal "use BuildBuddy Cloud for everything" setup
build --bes_results_url=https://app.buildbuddy.io/invocation/   # where to view results
build --bes_backend=grpcs://remote.buildbuddy.io               # Build Event Protocol sink
build --remote_cache=grpcs://remote.buildbuddy.io              # REAPI CAS + ActionCache
build --remote_executor=grpcs://remote.buildbuddy.io           # REAPI Execution service
```

`--remote_cache` enables the cache services only; adding `--remote_executor`
promotes the same endpoint to a full remote-execution backend. The `--bes_backend`
flag is orthogonal: it streams the **Build Event Protocol** (the metadata that
powers the result-store web UI) and works even with no cache or executor at all —
which is why the two-line `README` quickstart sets only `--bes_results_url` and
`--bes_backend`.

---

## How it works

### Life of a cached action (the common case)

The fast path never reaches an executor. For each action Bazel computes an
**action digest** (a `sha256` over the command, environment, and the Merkle tree
of input-file digests) and issues a `GetActionResult` against the `ActionCache`. On
a hit, BuildBuddy returns an `ActionResult` listing the output-file digests; Bazel
then either fetches those blobs from the `CAS` via `ByteStream.Read`, or — with
`--remote_download_minimal` — skips the download entirely and records only the
digests ("build without the bytes"). The cache is content-addressed, so a hit is
correct by construction: the same inputs can only ever have produced the same
output bytes.

```bash
# Cache-only mode: reuse results org-wide, but run actions locally
bazel build //... --remote_cache=grpcs://remote.buildbuddy.io \
                  --remote_download_minimal
```

### Life of a remote execution (the cache-miss path)

On a miss, the client calls `Execute` on the `Execution` service with the action
digest. From there (`enterprise/server/remote_execution/execution_server`,
`enterprise/server/scheduling/scheduler_server`):

1. **Enqueue.** The `execution_server` records the execution and hands the task to
   the **scheduler** via `ScheduleTask`. The scheduler is defined by the internal
   `Scheduler` gRPC service ([`proto/scheduler.proto`][scheduler-proto]):

   ```proto
   // proto/scheduler.proto — the executor⇆app brokering service
   service Scheduler {
     rpc RegisterAndStreamWork(stream RegisterAndStreamWorkRequest)
         returns (stream RegisterAndStreamWorkResponse) {}
     rpc LeaseTask(stream LeaseTaskRequest) returns (stream LeaseTaskResponse) {}
     rpc TaskExists(TaskExistsRequest) returns (TaskExistsResponse) {}
     rpc ScheduleTask(ScheduleTaskRequest) returns (ScheduleTaskResponse) {}
     rpc ReEnqueueTask(ReEnqueueTaskRequest) returns (ReEnqueueTaskResponse) {}
     rpc EnqueueTaskReservation(EnqueueTaskReservationRequest)
         returns (EnqueueTaskReservationResponse) {}
   }
   ```

2. **Probe & reserve.** Rather than a central queue the executors poll, the
   scheduler **pushes reservations** to executors it has chosen. Each executor holds
   a long-lived `RegisterAndStreamWork` stream to an app; the app sends
   `EnqueueTaskReservation` down that stream. The scheduler probes **three**
   executors per task by default (`probesPerTask = 3` in
   [`scheduler_server.go`][scheduler-server]) and lets them race to claim it —
   power-of-_k_-choices load balancing, with a `100ms`
   `executorEnqueueTaskReservationTimeout` before falling on to another node.
3. **Route by affinity.** Before probing, the `task_router`
   ([`task_router.go`][task-router]) consults a Redis **routing table** to bias the
   choice toward an executor that has run a _similar_ action before (e.g. one with a
   warm input tree). Its doc constants spell out the strategy:

   ```go
   // enterprise/server/scheduling/task_router/task_router.go
   // The TTL for each node list in the routing table.
   routingPropsKeyTTL = 7 * day
   // The default max number of preferred nodes returned by the task router …
   // intentionally less than the number of probes (for load balancing purposes).
   defaultPreferredNodeLimit = 1
   ```

   CI-runner and persistent-worker tasks get higher preferred-node limits
   (`persistentWorkerRouterPreferredNodeLimit = 128`) because they _"strongly
   prefer … a node with a warm bazel workspace."_

4. **Lease & execute.** The winning executor `LeaseTask`s the work (a renewable
   lease: the executor _"must send another LeaseTaskRequest"_ before the lease
   expires, per [`proto/remote_execution.proto`][reapi-proto], so a crashed
   executor's task is automatically re-enqueued). It then materializes the input
   Merkle tree from the `CAS` (using the local `filecache` to avoid re-downloading
   shared inputs), runs the command inside an isolated **runner**, and uploads the
   outputs back to the `CAS` plus an `ActionResult` to the `ActionCache`.
5. **Stream status.** Throughout, the `Execution` service streams `Operation`
   updates back to the client over `WaitExecution`, and the whole invocation's events
   flow to the result-store UI over `BEP`.

### Action merging (deduplication & hedging)

When many clients (or `--jobs=200` within one client) request the _same_ action
digest concurrently, BuildBuddy collapses them into one execution via the
`action_merger` ([`action_merger.go`][action-merger]), keyed in Redis on the
action digest:

```go
// enterprise/server/remote_execution/action_merger/action_merger.go
// The execution ID of the canonical (first-submitted) execution
executionIDKey = "execution-id"
// The total number of running hedged executions for this action
hedgedExecutionCountKey = "hedged-execution-count"
```

The first submitter becomes the **canonical** execution; later identical requests
are _merged_ against it and all receive its result. A bounded number of **hedged**
executions can be launched for the same action to cut tail latency (a slow worker
is raced against a fresh one), and merging continues for a window expressed in
lease periods (`DefaultClaimedExecutionLeasePeriods = 4`).

### Isolation, runners, and warm starts

Each executor runs multiple **runners**; a runner owns a **workspace** (the
action's working directory and input tree) and an **isolation** strategy
([`rbe-platforms.md`][rbe-platforms]):

> _"When executing actions, each BuildBuddy executor can spin up multiple action
> **runners**. Each runner executes one action at a time. Each runner has a
> **workspace** which represents the working directory of the action … Each runner
> also has an **isolation** strategy which decides which technology is used to
> isolate the action."_

Available isolation types are `oci` (the cloud default), `podman`, `docker`,
`firecracker` (microVMs, for actions that need a kernel — e.g. nested `dockerd`),
`sandbox` (macOS), and `none`. The container image is itself content-addressed and
chosen per-action via `exec_properties`:

```python title="BUILD"
platform(
    name = "docker_image_platform",
    exec_properties = {
        "OSFamily": "Linux",
        "network": "off",
        "container-image": "docker://gcr.io/YOUR:IMAGE",
    },
)
```

Two performance features fight cold-start cost. **`recycle-runner`** keeps a
runner's container paused and reuses it for the next action (trading some
hermeticity for speed). **Remote persistent workers** (enabled by Bazel's
`--experimental_remote_mark_tool_inputs`) keep a JVM compiler hot across actions —
the remote analogue of Bazel's local persistent workers. For Firecracker, the
`snaploader`/`copy_on_write`/`uffd` machinery snapshots and restores VM memory so a
microVM resumes from a warm image instead of booting.

---

## The five dimensions

### 1. Workspace declaration & topology

**Not applicable in the usual sense — and that is the point.** BuildBuddy has no
workspace manifest, no `members` glob, no root config that enumerates
sub-packages. The "topology" it operates on is the **action graph the client
already computed**: a stream of `Action`s, each carrying a Merkle tree of input
digests. Discovery, globbing, and the dependency DAG all happen on the client
([Bazel][bazel]/[Buck2][buck2]) _before_ the first byte reaches BuildBuddy.

What BuildBuddy _does_ declare is **executor topology**: executors register into
named **pools** ([`rbe-pools.md`][rbe-pools]) via a `MY_POOL` environment
variable, and a task selects a pool with the `Pool` execution property. This is a
server-side fleet partition (`high-memory-pool`, `my-gpu-pool`,
`use-self-hosted-executors`), not a source-tree partition. Cross-action
"namespacing" is done with `--remote_instance_name`, which scopes cache entries
(e.g. separating CI from local caches) — the closest thing to a workspace
boundary, and it is a _cache_ boundary, not a project one.

> [!NOTE]
> For `dub`, the lesson is one of **layering**: a future `dub` `[workspace]` block
> (the client-side topology) is one concern; a `REAPI` backend like BuildBuddy
> would sit _below_ it, caching whatever actions a workspace-aware `dub` emits. The
> two concerns are orthogonal and compose.

### 2. Dependency handling & isolation

BuildBuddy isolates **at the action level**, not the package level, and it does so
with content addressing rather than symlink trees or hoisting. There is no
`node_modules`, no virtual store, no `workspace:` protocol — those are client-side
dependency models. What BuildBuddy guarantees is:

- **Input isolation per runner.** Every action runs in its own runner workspace
  whose input tree is materialized _exactly_ from the action's declared Merkle
  tree — nothing more is visible. `network: "off"` is the default, so an action
  cannot reach the internet to acquire an undeclared dependency. This is hermeticity
  enforced by the substrate, the same property [Buck2][buck2] leans on.
- **Content-addressed deduplication of inputs.** Shared inputs (a common header, a
  toolchain binary) appear once in the `CAS` and are fetched once per executor into
  the local `filecache`; the input tree is assembled by reference. This is the
  remote-execution analogue of a [pnpm][pnpm]/[Yarn][cargo]-style content-addressed
  store, but for _build inputs_ rather than package tarballs.
- **Container isolation between actions.** Concurrent runners on one executor are
  separated by `oci`/`firecracker`; `recycle-runner` deliberately relaxes this for
  speed, and the docs flag the trade-off as _"reduces action hermeticity."_

### 3. Task orchestration & scheduling

The **DAG lives on the client**; BuildBuddy schedules the _leaf actions_ that DAG
emits. It is a genuine distributed scheduler, not a DAG engine:

- **Push-based reservation, not a pulled queue.** The `scheduler_server` chooses
  candidate executors and pushes `EnqueueTaskReservation` down their persistent
  `RegisterAndStreamWork` streams; executors race to `LeaseTask`.
- **Power-of-_k_-choices.** `probesPerTask = 3` reservations per task, with
  preferred-node limits below the probe count, balances load while honoring affinity.
- **Affinity routing.** The `task_router` biases toward executors with warm input
  trees, persisted in a Redis routing table with a `7 * day` TTL.
- **Leased execution with auto-recovery.** Leases are renewable; a missed renewal
  triggers `ReEnqueueTask`, so a dead executor never strands a task.
- **Priority & resource awareness.** `--remote_execution_priority` (range
  `-1000..1000`) orders actions across an org; per-action `EstimatedCPU` /
  `EstimatedMemory` / `EstimatedComputeUnits` size the runner so the
  `priority_task_scheduler` can bin-pack a machine.

**Change detection** is the cache itself: an action whose digest is unchanged is
never scheduled at all — the `ActionCache` short-circuits it. This is the same
input-hashing model as [Nx][nx]/[Turborepo][turborepo], but at the granularity of
a single compiler invocation rather than a package-level task.

### 4. Caching & remote execution

This is BuildBuddy's reason to exist, and the dimension where it is a primary
implementation rather than a consumer. It is a full `REAPI` v2 server:

| Service / role                         | `REAPI` component                          | Client flag                   |
| -------------------------------------- | ------------------------------------------ | ----------------------------- |
| Content-addressable store              | `ContentAddressableStorage` + `ByteStream` | `--remote_cache=grpcs://…`    |
| Action results (digest → outputs)      | `ActionCache`                              | `--remote_cache=grpcs://…`    |
| Capability negotiation                 | `Capabilities`                             | (implicit on connect)         |
| Remote **execution** of actions        | `Execution` service                        | `--remote_executor=grpcs://…` |
| Build metadata for the result-store UI | Build Event Protocol (`BEP`)               | `--bes_backend=grpcs://…`     |

The durable cache is **three-tier** ([`docs/remote-build-execution.md`][rbe-doc]
lists _"Three-tier artifact caching"_), configured under one `cache:` block
([`config-cache.md`][config-cache]): an in-process/disk layer, a **Redis** layer
(`redis_target`, _"for improved RBE performance"_), and a durable blob store
(`gcs:` or `s3:`, with `ttl_days` eviction). `zstd` transcoding compresses cache
bytes (`--experimental_remote_cache_compression`). Because the app tier is
stateless and the bytes live in blob storage, the cache scales horizontally and is
shared across an entire org.

```yaml title="config.yaml — three-tier: Redis hot layer + GCS durable blobs"
cache:
  redis_target: 'my-redis.local:6379'
  gcs:
    bucket: 'buildbuddy_blobs'
    project_id: 'my-cool-project'
    ttl_days: 30
```

Crucially, BuildBuddy speaks the **same `REAPI` wire protocol** as
`NativeLink` and `Buildbarn`, so a [Bazel][bazel] or
[Buck2][buck2] client treats them as interchangeable; the differentiation is
operational (managed cloud, autoscaling executors, web UI, Firecracker microVMs,
`mTLS` auth) rather than protocol-level. The docs enumerate the enterprise
differentiators verbatim: _"Stateless, horizontally scalable architecture,"_
_"Automatic executor scaling,"_ _"mTLS authentication,"_ _"Build without the
bytes,"_ and _"Action deduplication / merging."_

### 5. CLI / UX ergonomics

**BuildBuddy ships no build CLI of its own** — its "command boundary" _is the
client's flags_. The entire BuildBuddy surface a developer touches is a handful of
Bazel flags plus per-action `exec_properties`:

| Concern                 | Mechanism                                                           |
| ----------------------- | ------------------------------------------------------------------- |
| Enable caching          | `--remote_cache=grpcs://remote.buildbuddy.io`                       |
| Enable remote execution | `--remote_executor=grpcs://remote.buildbuddy.io`                    |
| Result-store UI         | `--bes_backend=…` + `--bes_results_url=…`                           |
| Parallelism             | `--jobs=50` (docs recommend starting at 50 and raising)             |
| Cache namespace         | `--remote_instance_name=buildbuddy-io/buildbuddy/ci`                |
| Executor selection      | `exec_properties = {"Pool": …, "OSFamily": …, "Arch": …}`           |
| Per-action resources    | `exec_properties = {"EstimatedCPU": "2", "EstimatedMemory": "4GB"}` |
| Custom environment      | `exec_properties = {"container-image": "docker://…"}`               |

These are folded into a `.bazelrc` `--config=remote` block so a build is just
`bazel build //... --config=remote`. There _is_ an optional **BuildBuddy CLI**
(`bb`) that wraps Bazel to simplify auth and add plugins, and a **Remote Bazel**
feature that runs Bazel itself in the cloud — but the canonical UX is "point your
existing Bazel/Buck2 at a URL." The target-selection ergonomics (`//...`, `:target`,
`--filter`-equivalents) belong to the [Bazel][bazel]/[Buck2][buck2] client, not to
BuildBuddy.

---

## Strengths

- **Drop-in `REAPI` server.** Any `REAPI` client ([Bazel][bazel], [Buck2][buck2],
  [Pants][pants], [Please][please]) gets org-wide caching and farm-scale execution
  by changing one URL; no build rewrite.
- **Both cache _and_ execution, plus a result-store UI.** Unlike a pure cache,
  BuildBuddy bundles the `CAS`/`ActionCache`, the executor farm, and a build-event
  web UI (timing profiles, test logs, invocation diffs) in one product.
- **Stateless, horizontally scalable app tier.** Coordination in Redis, bytes in
  blob storage, so the server scales by adding replicas; executors autoscale to
  thousands of nodes.
- **Sophisticated scheduling.** Affinity routing to warm workspaces, power-of-_k_
  probing, action merging + hedged executions, renewable leases with auto-recovery,
  and per-action resource estimation.
- **Strong isolation options.** `oci` by default, Firecracker microVMs for
  kernel-level isolation and `dockerd`-in-VM, with snapshot/restore for warm starts.
- **Open core, self-hostable.** The MIT core runs from a single Docker image; you
  are not locked into the managed cloud.

## Weaknesses

- **Bazel-shaped, not language-native.** It only helps clients that already model
  builds as hermetic, content-addressed actions. A tool without that model (`dub`
  today, [Cargo][cargo], [npm][npm]) cannot benefit until it _emits_ `REAPI`
  actions — a large client-side investment.
- **No workspace/topology features of its own.** It contributes nothing to
  workspace declaration, dependency isolation, or task-DAG construction; those are
  entirely the client's job. In this survey it is a _backend_, not a workspace tool.
- **Operational weight.** A self-hosted deployment means running app replicas, a
  Redis, blob storage, and an executor fleet with container/microVM isolation —
  justified only at real scale; tiny repos see little benefit over a local cache.
- **Open-core split.** Autoscaling, auth/`SSO`, Firecracker, and several scheduling
  features live in the enterprise edition; the MIT core is a single-tenant subset.
- **Hermeticity foot-guns.** `recycle-runner` and `preserve-workspace` trade
  correctness for speed; the docs explicitly warn they _"reduce action
  hermeticity."_
- **Niche audience.** Only meaningful inside the Bazel/Buck2/Pants ecosystem; the
  broader package-manager world ([uv][uv], [pnpm][pnpm], `dub`) does not speak
  `REAPI` at all.

## Key design decisions and trade-offs

| Decision                                                  | Rationale                                                                                 | Trade-off                                                                                  |
| --------------------------------------------------------- | ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Implement `REAPI`/`BEP`, own no workspace model           | One protocol serves every client; the build graph stays on the client where it belongs    | Useless to clients that don't already emit content-addressed actions; no topology help     |
| Content addressing as the correctness model               | Immutable, self-verifying cache; org-wide reuse; "build without the bytes" is safe        | Requires perfectly declared inputs upstream; an under-declared action poisons the cache    |
| Stateless app tier; state in Redis + blob storage         | Horizontal scale by adding replicas; any replica serves any request                       | A Redis and a blob store become hard operational dependencies                              |
| Three-tier cache (disk → Redis → `GCS`/`S3`)              | Hot small reads from Redis, durable bulk bytes in object storage with `ttl_days` eviction | More moving parts to configure and monitor than a single local cache                       |
| Push-based reservations + power-of-3 probing              | Low-latency dispatch with load balancing; no central queue to bottleneck                  | Probing overhead per task; tuning preferred-node limits vs. probe count is subtle          |
| Affinity routing to warm workspaces (Redis routing table) | Reuse a warm input tree / hot JVM → big wins for CI-runner and persistent-worker tasks    | Routing state is best-effort and TTL'd; cold fleets see no benefit                         |
| Renewable leases with `ReEnqueueTask`                     | A crashed executor's task is auto-recovered; no stuck builds                              | Lease bookkeeping; mis-tuned lease durations cause spurious re-enqueues                    |
| Action merging + hedged executions                        | Collapse duplicate concurrent work; race out slow workers to cut tail latency             | Hedging spends extra capacity; merge windows add coordination state in Redis               |
| Firecracker microVMs + snapshot/restore                   | Kernel-level isolation and nested `dockerd` with near-warm-start latency                  | Heavyweight; snapshot machinery (`uffd`, `copy_on_write`) is complex and enterprise-gated  |
| Open core (MIT) + enterprise edition                      | Free self-hostable substrate; sustainable business funds the farm-scale features          | Autoscaling/auth/Firecracker behind the commercial edition; core is a single-tenant subset |

---

## Sources

- [buildbuddy-io/buildbuddy — GitHub repository][repo] (source for the cited components and protos)
- [`README.md` — open-source positioning, MIT, Golang/React, Docker][readme]
- [`docs/introduction.mdx` — "open-core developer productivity platform built for Bazel"][intro]
- [RBE Setup — `--remote_executor`, toolchains, platforms, `--jobs`, `--remote_instance_name`][rbe-setup]
- [RBE Platforms — `exec_properties`, runners/workspaces/isolation, `container-image`, pools][rbe-platforms]
- [RBE Executor Pools — `MY_POOL`, `Pool` property, `default_pool_name`][rbe-pools]
- [Remote Build Execution — three-tier caching, stateless scaling, action dedup, build without the bytes][rbe-doc]
- [Cache Configuration — `disk`/`redis_target`/`gcs`/`s3`, `zstd` transcoding, `ttl_days`][config-cache]
- [`proto/scheduler.proto` — the `Scheduler` gRPC service (`ScheduleTask`/`LeaseTask`/`EnqueueTaskReservation`)][scheduler-proto]
- [`scheduling/scheduler_server/scheduler_server.go` — `probesPerTask = 3`, reservation streamer][scheduler-server]
- [`scheduling/task_router/task_router.go` — affinity routing, Redis routing table, preferred-node limits][task-router]
- [`remote_execution/action_merger/action_merger.go` — canonical execution, hedging, merge TTLs][action-merger]
- [`proto/remote_execution.proto` — renewable `LeaseTask` semantics][reapi-proto]
- [Bazel Remote Execution API (`REAPI`) — the cross-vendor protocol BuildBuddy implements][remote-apis]
- Related deep-dives: [Bazel][bazel] · [Buck2][buck2] · [Pants][pants] · [Please][please] · `NativeLink` · `Buildbarn` · [Nx][nx] · [Turborepo][turborepo] · [Cargo][cargo] · [the D landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/buildbuddy-io/buildbuddy
[docs]: https://www.buildbuddy.io/docs/introduction/
[readme]: https://github.com/buildbuddy-io/buildbuddy/blob/master/README.md
[intro]: https://github.com/buildbuddy-io/buildbuddy/blob/master/docs/introduction.mdx
[rbe-setup]: https://www.buildbuddy.io/docs/rbe-setup/
[rbe-platforms]: https://www.buildbuddy.io/docs/rbe-platforms/
[rbe-pools]: https://www.buildbuddy.io/docs/rbe-pools/
[rbe-doc]: https://github.com/buildbuddy-io/buildbuddy/blob/master/docs/remote-build-execution.md
[config-cache]: https://github.com/buildbuddy-io/buildbuddy/blob/master/docs/config-cache.md
[scheduler-proto]: https://github.com/buildbuddy-io/buildbuddy/blob/master/proto/scheduler.proto
[scheduler-server]: https://github.com/buildbuddy-io/buildbuddy/blob/master/enterprise/server/scheduling/scheduler_server/scheduler_server.go
[task-router]: https://github.com/buildbuddy-io/buildbuddy/blob/master/enterprise/server/scheduling/task_router/task_router.go
[action-merger]: https://github.com/buildbuddy-io/buildbuddy/blob/master/enterprise/server/remote_execution/action_merger/action_merger.go
[reapi-proto]: https://github.com/buildbuddy-io/buildbuddy/blob/master/proto/remote_execution.proto
[remote-apis]: https://github.com/bazelbuild/remote-apis
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
[d-landscape]: ../../async-io/d-landscape.md
