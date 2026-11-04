# BuildKit (Go)

BuildKit is Docker's build engine: a client sends a content-addressed DAG of
operations — or a _frontend_ that produces one — and a daemon solves it with
concurrent, cache-aware execution before exporting an image, a directory, or a
cache artifact. It is the system behind `docker build` (via Buildx), Earthly,
Dagger and Tekton. Vocabulary is [concepts]'s; this page does not redefine
_scheduler_, _rebuilder_, _trace_, _minimality_ or _early cutoff_.

**Last reviewed:** November 2, 2026

| Field          | Value                                                                                      |
| -------------- | ------------------------------------------------------------------------------------------ |
| Language       | Go — `go.mod` declares `go 1.26.8`                                                         |
| License        | Apache License 2.0 — `LICENSE`                                                             |
| Repository     | [moby/buildkit][repo]                                                                      |
| Documentation  | In-tree: [`README.md`][readme], [`docs/dev/solver.md`][solver-doc]                         |
| Category       | Industry — container-image build engine and build-graph daemon                             |
| Clone (pinned) | `c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5` (HEAD committed 2026-10-30)                     |
| Frontends      | `dockerfile.v0` in tree, `gateway.v0` (any image), ~20 external languages listed in README |

## Overview

### What it solves

A Dockerfile is a script that mutates one filesystem, but a build is a graph:
stages depend on stages, `COPY --from` crosses them. BuildKit replaces the script
with a graph of content-addressed operations that execute concurrently,
deduplicate across builds, cache across machines, and export to whatever the
caller wants. Its own summary — "a toolkit for converting source code to build
artifacts in an efficient, expressive and repeatable manner"
([`README.md`][readme]) — is narrow on purpose: BuildKit adopts no language, and
lets anyone emit its IR — "LLB is to Dockerfile what LLVM IR is to C"
([`README.md`][readme]).

### Design philosophy

- **The graph is the interface.** LLB is a protobuf DAG
  ([`solver/pb/ops.proto`][ops-proto]) any language can generate; the Dockerfile
  frontend is one producer among many.
- **Content-addressed vertices make identical work one edge.** Merging by digest
  within a run means twenty images sharing a base share one pull.
- **The cache is a product.** Export/import is first-class, in the OCI image
  format, with six backends — so a registry suffices.
- **Hashing content is expensive, so do it late.** This is the solver's stated
  central constraint:

  > "calculating the content based checksum of snapshots between every operation
  > or after every command execution is too slow for common use cases and needs
  > to be postponed to when it is likely to have a meaningful impact."
  >
  > — [`docs/dev/solver.md`][solver-doc]

## How it works

### LLB: a static, content-addressed DAG

A `Definition` is an array of marshalled `Op` messages plus per-vertex metadata;
each `Input` names a vertex by digest and index ([`solver/pb/ops.proto`][ops-proto]):

```protobuf
message Op {
  repeated Input inputs = 1;
  oneof op { ExecOp exec = 2;  SourceOp source = 3;  FileOp file = 4;
             BuildOp build = 5; MergeOp merge = 6;  DiffOp diff = 7; }
  Platform platform = 10;
  // ...
}
message Input { string digest = 1; int64 index = 2; }
```

The client builder ([`client/llb/state.go`][llb-state]) is immutable: marshalling
appends one op per step. The vertex digest is "a checksum of the definition up to
the vertex including all of its inputs" ([`solver/types.go`][types]) — a
_within-run_ identity only, since "the vertex digest can only be used for
comparison while the solver is running and not between different invocations"
([`docs/dev/solver.md`][solver-doc]). `alpine:latest` resolves to one vertex per
run; across runs the resolved image digest is what enters the key.

### Solver: demand-driven pipes over a static graph

`Solver` ([`solver/jobs.go`][jobs]) owns jobs, a map of active vertex `state`s
keyed by digest, an `edgeIndex` and a `scheduler`. A `state` is the shared,
reference-counted execution of one vertex across all jobs; an `edge`
([`solver/edge.go`][edge]) pairs a vertex with one output index. The scheduler
([`solver/scheduler.go`][scheduler]) is not a worker pool per vertex: it keeps
`waitq`, `incoming` and `outgoing` maps of `edgePipe`s, runs one `loop` goroutine,
and dispatches an edge when its pipes carry updates. `edge.unpark` recomputes the
desired state, requests its dependencies, and never blocks a thread on a child.

Within a job, `edgeIndex` merges edges with the same cache key; across jobs,
`actives` maps the vertex digest to a live `state`, so two builds resolving the
same image wait on the same work — a build farm on one daemon shares every pull
and execution that hashes alike.

### Cache: constructive traces keyed on the definition

An op implements `CacheMap` (its contribution to the key), `Exec` and `Acquire`;
the per-vertex `sharedOp` wrapper adds `LoadCache`, `CalcSlowCache` and `Cache()`
([`solver/types.go`][types], [`solver/jobs.go`][jobs]). `CacheMap` is a digest
over a JSON serialization of the operation with everything irrelevant to its
result removed.
`ExecOp.CacheMap` ([`solver/llbsolver/ops/exec.go`][exec-op]) is the canonical
normalization list: mount selectors are cleared (a selector narrows _which_ files
are copied, not what the command computes), `CacheOpt.ID` and `Sharing` are
dropped for the default cache-mount case, proxy variables are dropped and
extra-host IPs zeroed, and the default root mount is omitted — "Special case for
cache compatibility with buggy versions that wrongly excluded Exec.Mounts".

The solver composes the key ([`solver/cachekey.go`][cachekey]):
`NewCacheKey(cacheMap.Digest, vertexDigest, outputIndex)` plus, per dependency,
its keys and selector. That is a Merkle hash of the _task description_ — the
constructive-trace shape, since the value stored against the key is a reference
to the produced snapshot, not a hash. Two levels exist: a **fast key** from the
op's `CacheMap` and its inputs' keys, and a **slow key**, a content hash over
selected paths of a dependency's output installed by `ComputeDigestFunc` only for
mounts that select files, e.g. `RUN --mount=type=bind,from=build,source=out`.

Slow keys are computed after dependencies complete, and their order avoids
pointless work — "slow cache keys can be computed in 2 phases if there are
multiple deps. first evaluate ones that didn't match any definition based keys"
([`solver/edge.go`][edge]).

The store is assembled from containerd components: a `content.Store` for blobs, a
snapshotter for filesystems, and a bbolt metadata store for the ref graph
([`cache/manager.go`][cache-manager]). `GetByBlob` reuses an existing ref found by
layer chain ID, so imported layers deduplicate against build outputs. Liveness is
reference counting plus containerd leases; reclamation is the GC policy in
`buildkitd.toml` (`reservedSpace`, `keepDuration`, filters such as
`type==source.git.checkout`).

Exporters are pluggable and orthogonal: an OCI or Docker image, a local directory,
or a tar stream; separately the _cache_ goes inline into the image, or to a
registry, directory, GitHub Actions cache, S3 or Azure Blob. The asymmetry is
documented — "the `inline` cache exporter only supports `min` cache mode. To
enable `max` cache mode, push the image and the cache separately by using
`registry` cache exporter" ([`README.md`][readme]). An exported cache is an OCI
image index of manifests ([`cache/remotecache/v1/chains.go`][chains]), so import
is just a pull.

### Provenance and attestations

Provenance is captured by _wrapping the graph accessor_, not by instrumenting each
operation: `provenanceBridge` ([`solver/llbsolver/provenance.go`][prov]) embeds
`llbBridge`, so every frontend `Solve`, nested build and `ResolveSourceMetadata`
is observed at the seam. `NewProvenanceCreator` then emits in-toto SLSA v0.2 or
v1; the record covers "Build dependencies with their immutable checksums"
([`docs/attestations/slsa-provenance.md`][slsa]); SBOMs come from a generator
image protocol. Both attach as OCI artifacts — "BuildKit stores attestations as
OCI artifacts when OCI media types are enabled"
([`docs/attestations/attestation-storage.md`][att-storage]) — or as files for
`local`/`tar`. Reproducibility is separate: `--source-policy-file` rewrites
unpinned sources to digests (then `recomputeDigests` rehashes vertices,
[`solver/llbsolver/vertex.go`][vertex]), and `SOURCE_DATE_EPOCH` with
`rewrite-timestamp=true` pins timestamps ([`docs/build-repro.md`][repro]).

### Frontends: the graph is produced by a program

A frontend is an interface, not a file format: `frontend.Frontend` is a single
`Solve(ctx, llbBridge, executor, opt, inputs, sid, sessionManager)` method
([`frontend/frontend.go`][frontend]); the request lifecycle is documented step by
step in [`docs/dev/request-lifecycle.md`][lifecycle]. `gateway.v0` runs an
arbitrary image as the producer, so Dockerfile features ship independently of the
daemon, and `BuildOp` lets a frontend call back into the solver with a definition
it just generated. A gRPC _session_ supplies local directories, secrets and SSH
sockets; `allowedRepositories` restricts gateway images.

## Analysis spine

**Topological × constructive traces** — the cell [concepts] assigns to
`CloudBuild`, and the mismatch is worth stating. BuildKit satisfies the
_topological_ precondition trivially: the definition declares every edge before
execution, so nothing is discovered by running a task and no restart or
suspension is needed. But it does not topologically _sort_; it runs a
demand-driven dataflow where an edge is dispatched when its pipes update. The
rebuilder is a constructive trace — a Merkle hash of the normalized op plus its
dependencies' keys, whose value is a real snapshot materializable without
re-execution. Three deviations: the trace's value is a **snapshot, not a hash**,
so content deduplication happens below the build cache; content keys are
**selective**, making the system a hybrid of definition- and content-keyed edges;
and monadic structure is **quarantined** inside `build` ops, where the solver is
re-entered with a frontend-generated definition.

It fits no _suspend_ or _restart_ cell, because no task ever observes a missing
dependency. It also fits no cell for _hermeticity_: execution is in a container,
not an observing sandbox, so an undeclared read — a network fetch, a `/proc`
peek, a path outside the declared mounts — is invisible to the key.

### 1. Task model & scheduling

An op is `exec`, `source`, `file`, `merge`, `diff`, `build` or `passthrough`;
dependencies are its `Input` list, index-addressed per vertex output. Scheduling
is concurrent dataflow: one dispatch loop, per-edge pipes, an edge unparked when a
dependency delivers a key or result. No speculation and no priority — the DAG's
shape is the schedule, and parallelism is a per-worker semaphore.

### 2. Rebuilding & correctness

Dirty checking is a cache lookup at two key levels; minimality within a run is
exact thanks to vertex-digest merging, and across runs it is as good as the key.
**Early cutoff is partial**: a downstream key contains its input's _key_, so a
rebuilt-but-unchanged input leaves dependents matching, but a nondeterministic
input producing different bytes under the same key does not invalidate them.
Outputs are not verified and declarations are not checked against observations.
The shared-dependency cache-miss test
([`solver/cachemiss_stale_dep_test.go`][stale-test]) shows the subtlety from the
other side: a completed dependency kept alive in `actives` must still hand its key
to a later job.

### 3. Dependency discovery

Declared, entirely. LLB is a static definition and `RUN`'s file accesses are not
observed — the opposite stance to BuildXL and Rattle. An under-declared `RUN` is
a silently unsound cache entry rather than an error, and the network is the common
case that is not part of the key.

### 4. Store & caching

A content store, a snapshotter and a leased ref graph; GC policy in TOML; cache
export/import in OCI layout to registry, directory, GHA, S3 or Azure Blob. Cache
mounts (`RUN --mount=type=cache`) sit deliberately outside the key and the
exported cache — right for package managers, a trap for reproducibility.

### 5. Hermeticity & provenance

Hermeticity is _the container_: namespaces, a default seccomp profile, optional
rootless execution. It is isolation, not observation — the engine learns nothing
from it. Rootless mode narrows further: "Network mode is always set to
`network.host`" ([`docs/rootless.md`][rootless]). Provenance is first-class by
contrast: SLSA v0.2/v1 and SPDX SBOMs captured at the bridge, source policies for
pinning and `SOURCE_DATE_EPOCH` for timestamps.

### 6. Distribution

Absent as execution distribution, present as cache distribution: one daemon owns
its workers, whose interface demands that the "ID needs to be unique in the
cluster" ([`worker/worker.go`][worker]); ops declare a `Platform` and may carry a
`WorkerConstraints` filter, and multi-platform builds repeat the solve per
platform ([`docs/multi-platform.md`][multi-platform]). Multiple machines
coordinate through a shared registry/object cache plus client-side consistent
hashing. There is **no REAPI client and no remote-execution protocol** — a
tree-wide grep for `REAPI` or "remote execution" outside `vendor/` finds nothing
— so this scales _sharing_, not _compute_.

### 7. Sparkles relevance

`sparkles.build_primitives.task` is a static DAG with an in-process executor and
no persistent memory, so four borrowings are cheap:

- **Per-op key declaration.** `CacheMap` is a small, op-owned description of what
  enters the key, composed bottom-up. A `TaskKey` hook of that shape (op →
  normalized bytes; solver → Merkle hash with inputs) beats one global hasher.
- **The normalization checklist.** Proxy variables, host IPs, cache-mount IDs,
  selectors and an "implied mount" special case are the accidental invalidators a
  `dub`-based engine will meet; the list is a test plan.
- **Two key levels, the second opt-in.** A cheap definition key everywhere, with
  content hashing only where content genuinely matters, keeps the fast path fast.
- **Provenance at the seam.** Capturing requests at the single graph-access point
  is far less invasive than instrumenting executors, and survives new op kinds.

What does not transfer: a container per action (far too heavy for a compiler
step) and the ref/snapshot/lease machinery a mutable store drags in.

## Strengths

- **The right IR at the right time.** LLB's op set is small enough to implement
  and expressive enough to host Dockerfile, buildpacks, HLB and Nix frontends;
  the gateway frontend turns "the builder is an image" into a deployment model.
- **Concurrency and deduplication are the design.** Pipes plus vertex states let
  one daemon serve many builds sharing one pull, one execution, one layer — the
  property that let it displace the legacy builder.
- **Cache portability is unusually good.** An OCI index in a registry moves a
  cache between CI providers; six exporters cover the practical backends without
  a bespoke daemon protocol.

## Weaknesses

- **No observation means an unsound cache is possible.** A `RUN` that fetches over
  the network or reads an undeclared path caches a stale result and the engine
  cannot tell; `--no-cache` and `RUN --network=none` are remedies, not a
  guarantee.
- **No remote execution, and a large operational surface** — workers, snapshotters,
  GC policy, leases, metadata compaction, sessions and a frontend trust list: the
  cost of being a platform rather than a library.

## Key design decisions and trade-offs

| Decision                                      | Rationale                                                      | Trade-off                                                                   |
| --------------------------------------------- | -------------------------------------------------------------- | --------------------------------------------------------------------------- |
| LLB as a protobuf DAG, not a DSL              | Any language can emit it; Dockerfile becomes replaceable       | A second IR to version; capability gates per daemon                         |
| Content-addressed vertices, merged in-process | One pull/execution per identical op across concurrent jobs     | Merging is run-scoped; cross-run identity needs the persisted cache key     |
| Key = normalized op + input keys              | Cheap, no content scan, stable across machines                 | Undeclared inputs and nondeterminism are invisible; no output verification  |
| Content hashes only for selected mounts       | Content addressing where it pays, without scanning every layer | Two key levels and a phased scheduler; opt-in per mount                     |
| Defer snapshot hashing                        | Hashing between every step is too slow                         | Early cutoff is key-based, so identical content under different keys misses |
| Containerd content store + snapshotter        | Reuse mature layer storage, dedupe imports, lazy pull (stargz) | Heavy dependency; GC, leases and metadata become operator concerns          |
| Export cache as an OCI index                  | A registry is the universal shared cache; no new protocol      | Inline cache is `min`-only; `max` needs a second push target                |
| Frontend as an image (`gateway.v0`)           | Ship Dockerfile features without shipping a daemon             | Executing a frontend is code execution; needs a trust list                  |
| Provenance captured at the bridge             | Works for every frontend and every nested solve                | Records what was requested, not that the result is reproducible             |
| Container as the sandbox                      | Strong isolation with no syscall interposer or per-access cost | No input observation; network reads are uncacheable in principle            |

## Sources

- [`moby/buildkit`][repo] at commit `c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5`
  (clone at `$REPOS/build-systems-research/src/buildkit`; HEAD committed
  2026-10-30). Every quote is verbatim from the file cited beside it, opened at
  that SHA. Design and lifecycle: [`README.md`][readme],
  [`docs/dev/solver.md`][solver-doc], [`docs/dev/request-lifecycle.md`][lifecycle].
- Graph, solver and keys: [`solver/pb/ops.proto`][ops-proto], [`solver/types.go`][types],
  [`client/llb/state.go`][llb-state], [`solver/scheduler.go`][scheduler],
  [`solver/edge.go`][edge], [`solver/cachekey.go`][cachekey], [`solver/jobs.go`][jobs],
  [`solver/llbsolver/vertex.go`][vertex], [`solver/llbsolver/ops/exec.go`][exec-op],
  [`solver/cachemiss_stale_dep_test.go`][stale-test].
- Store, export, provenance and execution: [`cache/manager.go`][cache-manager],
  [`cache/remotecache/v1/chains.go`][chains], [`docs/buildkitd.toml.md`][daemon-toml],
  [`solver/llbsolver/provenance.go`][prov], [`docs/attestations/slsa-provenance.md`][slsa],
  [`docs/attestations/attestation-storage.md`][att-storage], [`docs/build-repro.md`][repro],
  [`worker/worker.go`][worker], [`docs/rootless.md`][rootless],
  [`docs/multi-platform.md`][multi-platform], [`frontend/frontend.go`][frontend].
- Sibling pages: [concepts] for the vocabulary and Table 2 placement, [a-la-carte]
  for the scheduler/rebuilder grid, [shake] for the suspending scheduler and
  verifying step traces this page contrasts with.

<!-- References -->

[repo]: https://github.com/moby/buildkit
[readme]: https://github.com/moby/buildkit/blob/c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5/README.md
[solver-doc]: https://github.com/moby/buildkit/blob/c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5/docs/dev/solver.md
[lifecycle]: https://github.com/moby/buildkit/blob/c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5/docs/dev/request-lifecycle.md
[ops-proto]: https://github.com/moby/buildkit/blob/c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5/solver/pb/ops.proto
[types]: https://github.com/moby/buildkit/blob/c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5/solver/types.go
[llb-state]: https://github.com/moby/buildkit/blob/c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5/client/llb/state.go
[scheduler]: https://github.com/moby/buildkit/blob/c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5/solver/scheduler.go
[edge]: https://github.com/moby/buildkit/blob/c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5/solver/edge.go
[cachekey]: https://github.com/moby/buildkit/blob/c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5/solver/cachekey.go
[jobs]: https://github.com/moby/buildkit/blob/c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5/solver/jobs.go
[stale-test]: https://github.com/moby/buildkit/blob/c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5/solver/cachemiss_stale_dep_test.go
[vertex]: https://github.com/moby/buildkit/blob/c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5/solver/llbsolver/vertex.go
[exec-op]: https://github.com/moby/buildkit/blob/c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5/solver/llbsolver/ops/exec.go
[cache-manager]: https://github.com/moby/buildkit/blob/c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5/cache/manager.go
[chains]: https://github.com/moby/buildkit/blob/c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5/cache/remotecache/v1/chains.go
[daemon-toml]: https://github.com/moby/buildkit/blob/c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5/docs/buildkitd.toml.md
[prov]: https://github.com/moby/buildkit/blob/c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5/solver/llbsolver/provenance.go
[slsa]: https://github.com/moby/buildkit/blob/c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5/docs/attestations/slsa-provenance.md
[att-storage]: https://github.com/moby/buildkit/blob/c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5/docs/attestations/attestation-storage.md
[repro]: https://github.com/moby/buildkit/blob/c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5/docs/build-repro.md
[worker]: https://github.com/moby/buildkit/blob/c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5/worker/worker.go
[rootless]: https://github.com/moby/buildkit/blob/c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5/docs/rootless.md
[multi-platform]: https://github.com/moby/buildkit/blob/c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5/docs/multi-platform.md
[frontend]: https://github.com/moby/buildkit/blob/c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5/frontend/frontend.go
[concepts]: ./concepts.md
[a-la-carte]: ./a-la-carte.md
[shake]: ./shake.md
