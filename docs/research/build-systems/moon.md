# moon (Rust action-graph engine)

A repository orchestrator whose engine is a materialized DAG of typed _actions_ rather
than tasks: the graph is cycle-checked and sorted before any work starts, dispatch is
a Kahn-style ready counter bucketed by priority, each task node's dirty check is one
composite SHA-256 fingerprint, and a hit is a CAS-backed action result.

**Last reviewed:** November 2, 2026

| Field                 | Value                                                                                                                                 |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Language              | Rust — 73 crates under `crates/`, ~140.6k lines of `.rs` (tests included)                                                             |
| License               | MIT (`LICENSE`, "Copyright (c) 2021 moonrepo, Inc.")                                                                                  |
| Repository            | [moonrepo/moon][repo]                                                                                                                 |
| Documentation         | [moonrepo.dev][docs]; in-tree [`concepts/cache.mdx`][docs-cache], [`action-graph.mdx`][ag-doc]                                        |
| Category              | Polyglot task orchestrator; engine companion to [moon (monorepo-tooling)][mono-moon]                                                  |
| Clone (pinned)        | `$REPOS/build-systems-research/src/moon`                                                                                              |
| Commit                | `332983a450cb3803d5466177963c087a3f30a102` (2026-10-29), tagged `v2.6.5`; `crates/cli/Cargo.toml` → `2.6.5`, nothing ahead of the tag |
| Scheduler × rebuilder | Topological × constructive (action cache) — the `CloudBuild` cell; see §2                                                             |
| Remote                | REAPI **cache only**: Action Cache + CAS + ByteStream, gRPC or HTTP; no `Execution` service                                           |

> [!NOTE]
> **Delta against the workspace page.** [moon (monorepo-tooling)][mono-moon] covers
> `.moon/workspace.yml`, `moon.yml` projects, `dependsOn` scopes, the CLI surface and
> the cache configuration keys. This page goes below that: how the action graph is
> built and typed, what the dispatcher does per tick, how the fingerprint is composed
> (including what a dependency contributes), the two-phase manifest-then-blobs lookup,
> CAS layout and GC, and the cache-only REAPI client.

## Overview

### What it solves

Many projects, tasks that run in dependency order and only when their inputs changed,
and outputs of a previous run — here or elsewhere — replayable: a graph, a fingerprint
and a store.

### Design philosophy

Three commitments shape the engine. First, graph nodes are **actions**, not tasks:

> "Unlike other task runners in the industry that represent each node in the graph as
> a task to run, we represent each node in the graph as an action to perform."
>
> — [`how-it-works/action-graph.mdx`][ag-doc]

So toolchain setup, dependency install, project sync and the task itself are peers in
one DAG with typed edges, not a preamble wrapped around a task runner. Second,
**hashing is the only dirty check**: "each time a target is ran we generate a hash, and
if this hash already exists we abort early (cache hit), otherwise we continue the run
(cache miss)" ([`concepts/cache.mdx`][docs-cache]). Third, the cache is **best-effort**: a
slow, unreachable or incomplete backend degrades to a miss, stated as a constant in the
storage layer, where shutdown bounds queued uploads at 300 s because "a hung backend
must never make exiting slower than just running the task would have been"
([`storage.rs`][storage]). The lineage is declared in the README — "Many of the
concepts within moon are heavily inspired from Bazel and other popular build systems"
([`README.md`][readme]).

## How it works

### 1. Task model & scheduling

`ActionNode` is a closed enum of seven variants — `SyncWorkspace`, `SetupProto`,
`SetupToolchain`, `SetupEnvironment`, `InstallDependencies`, `SyncProject`, `RunTask` —
each identifying one unit of setup or work ([`action_node.rs`][action-node]).

Edges are typed: the graph is a `daggy::Dag` weighted by `TaskDependencyType` —
`Required` (default), `Cleanup` (runs _after_ the task, even on failure, and only if
the command ran), `Wait` (the dependent waits only for the dependency to have
_started_), and an internal `Optional` ([`task_config.rs`][task-config]).
`ActionGraphBuilder` links task-dependency, project-relationship, toolchain-setup and
cleanup edges ([`action_graph_builder.rs`][agb]); `sort_topological` reports a cycle as a
`→`-joined label path before `petgraph::algo::toposort` ([`action_graph.rs`][action-graph]).

Dispatch is not a topo-sort walk. `JobDispatcher` precomputes
`group_priorities(sort_topological())`, a `BTreeMap<u8, Vec<NodeIndex>>` keyed by
priority (0 critical … 3 low, task default 2); each `next()` drains completed jobs,
then scans groups for the first _applicable_ index — blockers all finished —
decrementing a `ready_nodes` counter that skips the scan when nothing can run
([`job_dispatcher.rs`][dispatcher]). A `RunTask` whose `id` matches a running job is
deferred, and `Cleanup` jobs are skipped once the abort token is cancelled. Parallelism
defaults to `num_cpus::get()` ([`action_pipeline.rs`][pipeline]). JFP §4.1's topological
scheduler plus a readiness test: nothing is discovered at run time.

### 2. Rebuilding & correctness

In [concepts] terms the rebuilder is a **constructive trace** — the `CloudBuild` cell of
JFP §6, Table 2 — except that moon stores no dependency _vector_: everything folds into
one action key.

`TaskFingerprint` is that key's schema ([`task_fingerprint.rs`][fingerprint]): command,
script, args, env, `inputs` (path → SHA-256), `outputs`, `deps` (target → hash),
`project_deps`, `toolchains`, `cache_key`, and a `version` counter documented as "Bump
this to invalidate all caches". `TaskHasher` fills it, sorting for determinism
([`task_hasher.rs`][hasher]).

What a dependency contributes is a policy: `dep_hash_input` inserts, per required
dependency, its _own fingerprint hash_ under `'hash'` (the default), the constant
`"outputs"` under `'outputs'` — invalidation then comes from the dependency's outputs,
which `inject_deps_outputs` copies into the consumer's inputs — and `"ignored"` under
`'ignored'`. A dependency that failed or was skipped contributes `None` and is dropped
([`task_hashing.rs`][task-hashing]).

**Consequence — no early cutoff on content.** Because the key folds _input_ hashes, a
dependency that re-runs and emits byte-identical outputs still yields a new key, which
changes every consumer's key and forces their re-execution. Cutoff exists only in the
degenerate direction: an unchanged key never runs, so its hash is stable and its
consumers hit. JFP §2.3's early cutoff — stop once a rebuilt value is unchanged — is
absent. Each fingerprint is also persisted as a CAS manifest the docs call "purely for
debugging purposes" ([`concepts/cache.mdx`][docs-cache]).

### 3. Dependency discovery

Discovery is **declared, never traced**. `inputs`/`outputs` are literal paths, globs or
`@group(...)` references; `deps`/`dependsOn` are explicit. A grep for `ptrace`,
`seccomp`, `landlock`, `bwrap`, `unshare` and FUSE across `crates/` returns only test
fixtures — no syscall interception and no compiler-depfile parsing anywhere in the
engine. Two things soften the burden, neither of them discovery: `inject_deps_outputs`
copies a `cacheStrategy: 'outputs'` dependency's outputs into the consumer's _inputs_,
so the consumer tracks bytes not the producer's key ([`task_expander.rs`][task-expander]);
and WASM toolchain plugins answer `HashTaskContentsInput` with lockfile contents
([`task_hashing.rs`][task-hashing]).

`--affected` is pruning, not discovery: `AffectedTracker` intersects the VCS changed
files with each task's declared inputs and walks relations to mark dependents, and the
builder filters on those marks _before_ insertion ([`affected_tracker.rs`][affected]) —
an undeclared input is invisible to both.

### 4. Store & caching

Lookup is tiered, cheapest first ([`task_runner.rs`][task-runner]): if the last run had
the same hash, exited 0 and its declared outputs still exist, moon returns
`HydrateFrom::PreviousOutput` without touching storage; otherwise it checks the local
`tar.gz` archive at `.moon/cache/outputs/<hash>.tar.gz`
([`output_hydrater.rs`][hydrater]), then falls through to `Storage`, which has **two
phases**. `load_task_manifest` asks each readable backend for the _manifest_ alone
(`manifests/<prefix>/<hash>/`) and returns the first hit with the backend that served
it; `hydrate_task_manifest` then fetches only the missing blobs, starting with that
same backend "as that's the most likely to have all the blobs available", falling back
across the others and copying what it finds back. A partially hydrated manifest is a
miss, not a partial build. On a remote hit the local tier is warmed from the in-memory
blobs "so the next run resolves locally instead of round-tripping to the remote again"
([`storage.rs`][storage]).

The manifest _is_ a REAPI `ActionResult`: `TaskManifest` holds output files, symlinks,
exit code and stdout/stderr digests, and converts losslessly to and from
`build.bazel.remote.execution.v2.ActionResult` — "In Bazel terms, this source path is
the 'action', while this manifest is the 'action result'" ([`task_manifest.rs`][manifest]).

Blobs are a plain CAS: SHA-256 addressed in a "git-style prefix-sharded directory
layout", written temp-file-plus-rename with no fsync — "Power-loss before durability
flush would leave a missing blob, which on the next run just becomes a cache miss"
([`cas.rs`][cas]). Eviction is an mtime sweep plus a reachability pass with a one-hour
`BLOB_GRACE` for blobs whose manifest is unwritten ([`gc.rs`][gc],
[`local_storage.rs`][local]); `CacheMode` (via `MOON_CACHE`) gates reads and writes, and
`cacheLifetime` makes a warm entry stale ([`cache_engine.rs`][cache-engine]).

### 5. Hermeticity & provenance

There is no sandbox. `CommandBuilder` builds an `AugmentedCommand`, sets `cwd` to the
task's working directory (the project root by default), injects `MOON_*` variables and
`PWD`, layers `.env` files, and hands the process the inherited environment
([`command_builder.rs`][command-builder]). Reads outside the project succeed
invisibly; writes outside declared outputs succeed and are simply not archived. The
compensating controls are declaration-side: a build-type task that produced nothing
declared fails with `MissingOutputs` rather than caching an empty result
([`output_archiver.rs`][archiver]); hydration rejects an undeclared output; and the key
carries the environment the task can see (`env`, `input_env`, toolchain id and
version). Provenance is absent — no `SLSA`, `in-toto` or attestation code in the tree.

### 6. Distribution

Distribution is **cache-only**. `GrpcRemoteStorage` instantiates `ActionCacheClient`,
`ContentAddressableStorageClient`, `CapabilitiesClient` and `ByteStreamClient` from
`bazel-remote-apis` — and no `ExecutionClient` ([`grpc_remote_storage.rs`][grpc]).
Every action still executes on the invoking machine; the remote contributes bytes. The
client negotiates rather than assumes: `GetCapabilities` populates a trimmed
`CacheCapabilities`, and batch versus streamed paths follow from those numbers
([`capabilities.rs`][capabilities]). Failures are classified, not fatal: `NotFound` is
a miss, `OutOfRange` becomes "Cache miss because the expected payload is too large",
`ResourceExhausted` becomes `GrpcOutOfStorageSpace`. An HTTP backend speaks Bazel's HTTP
protocol instead ([`http_remote_storage.rs`][http]).

Two local mechanisms stand in for a cluster. The **daemon** offloads archiving and
hydration over a Unix socket, falling back in-process when the RPC fails — "if the RPC
fails … archive in-process instead of failing a task that passed"
([`output_archiver.rs`][archiver]). **CI sharding** is a static partition:
`--job`/`--job-total` slice the affected target list into contiguous chunks of
`div_ceil(len, total)` while each job still pulls `Required` dependencies in — so
dependencies are recomputed per shard and only the cache dedupes them
([`action_graph_builder.rs`][agb]).

### 7. Sparkles relevance

`sparkles.build_primitives.task` is a static, in-process DAG with no store, so the
borrowings are mechanisms:

- **Typed edges, not just ordering.** `Cleanup` (after, even on failure) and `Wait` (on
  start, not completion) are vocabulary a task-DAG lacks; cheap as edge kinds,
  expensive to retrofit.
- **Per-dependency contribution policy.** `hash`/`outputs`/`ignored` turns "how much
  does this edge invalidate" into a declaration, and dropping failed or skipped
  dependencies is the conservative move.
- **What not to copy.** Collapsing dependency hashes into the key forfeits early
  cutoff; an engine wanting both should keep the per-dependency record of [concepts] §3.

## Strengths

- **A real action graph, not a task list.** Toolchain setup, dependency install and
  project sync are first-class nodes, so "install `node_modules` once" is a graph
  property, not a special case.
- **Degradation is designed.** Slow, hung, full or absent backends become misses;
  partial hydration is refused; a failed daemon RPC falls back in-process.
- **Cache format is Bazel-compatible on the wire and on disk**, so a local CAS hit and
  a remote REAPI hit reconstruct identical outputs, and any REAPI server is a backend.

## Weaknesses

- **No early cutoff on content.** A producer with byte-identical outputs still
  invalidates every consumer, which keys on the producer's _input_ hash.
- **No sandbox and no read observation.** Hermeticity rests on `inputs` being honest;
  an undeclared read is neither detected nor diagnosable.
- **Discovery is entirely declared.** No depfiles, no tracing, no dynamic edges; a
  codegen step whose outputs are undeclared produces stale consumers.
- **Remote execution is out of scope** despite speaking the Remote Execution API — the
  name promises more than the client implements, and CI parallelism is sharding.

## Key design decisions and trade-offs

| Decision                                           | Rationale                                                               | Trade-off                                                          |
| -------------------------------------------------- | ----------------------------------------------------------------------- | ------------------------------------------------------------------ |
| Actions, not tasks, as graph nodes                 | Setup/install/sync become schedulable, deduplicable peers               | Seven node variants, each needing a cache and hash story           |
| Full graph materialized before dispatch            | Cycles and missing targets fail before any work; readiness is a counter | No dynamic dependencies; the graph cannot grow during a run        |
| One composite SHA-256 fingerprint per task         | Cheap, comparable, dumpable; a single `version` bumps everything        | No early cutoff; no per-dependency record to re-verify selectively |
| Dependency contributes its _hash_, policy per edge | Consumers see semantic change, not mtime or producer timing             | `'outputs'` exists precisely because hashes over-invalidate        |
| Content-addressed store with manifest indirection  | Remote hits cheap to check and hydrate; partial hits detectable         | Two-phase lookup, cross-backend fallback, reachability GC          |
| No sandbox                                         | Zero overhead, no kernel dependency, identical everywhere               | Correctness rests on declared inputs; undeclared I/O is invisible  |
| REAPI for cache only                               | Reuses an ecosystem of servers without building an execution platform   | Every action is local; CI parallelism comes from sharding          |

## Sources

- [`moonrepo/moon`][repo] at commit `332983a450cb3803d5466177963c087a3f30a102` (tag
  `v2.6.5`, 2026-10-29), clone at `$REPOS/build-systems-research/src/moon`; quotes are
  verbatim from the files cited inline.
- Graph and scheduling: [`action_graph.rs`][action-graph], [`action_graph_builder.rs`][agb],
  [`action_node.rs`][action-node], [`job_dispatcher.rs`][dispatcher], [`action_pipeline.rs`][pipeline].
  Hashing: [`task_fingerprint.rs`][fingerprint], [`task_hasher.rs`][hasher],
  [`task_hashing.rs`][task-hashing], [`task_expander.rs`][task-expander],
  [`affected_tracker.rs`][affected], [`task_config.rs`][task-config].
- Store and cache: [`task_runner.rs`][task-runner], [`output_hydrater.rs`][hydrater],
  [`output_archiver.rs`][archiver], [`cache_engine.rs`][cache-engine], [`storage.rs`][storage],
  [`capabilities.rs`][capabilities], [`local_storage.rs`][local], [`cas.rs`][cas], [`gc.rs`][gc],
  [`task_manifest.rs`][manifest], [`grpc_remote_storage.rs`][grpc],
  [`http_remote_storage.rs`][http], [`command_builder.rs`][command-builder].
- Docs and metadata in the clone: [`concepts/cache.mdx`][docs-cache],
  [`how-it-works/action-graph.mdx`][ag-doc], [`README.md`][readme], `CHANGELOG.md`,
  `crates/cli/Cargo.toml`, `Cargo.toml`, `LICENSE`. Siblings: [concepts], [bazel],
  [buck2], [please], [pants], [buildkit], [buildxl], [shake], [rattle].

<!-- References -->

[repo]: https://github.com/moonrepo/moon
[docs]: https://moonrepo.dev/docs
[readme]: https://github.com/moonrepo/moon/blob/332983a450cb3803d5466177963c087a3f30a102/README.md
[docs-cache]: https://github.com/moonrepo/moon/blob/332983a450cb3803d5466177963c087a3f30a102/website/docs/concepts/cache.mdx
[ag-doc]: https://github.com/moonrepo/moon/blob/332983a450cb3803d5466177963c087a3f30a102/website/docs/how-it-works/action-graph.mdx
[action-graph]: https://github.com/moonrepo/moon/blob/332983a450cb3803d5466177963c087a3f30a102/crates/action-graph/src/action_graph.rs
[agb]: https://github.com/moonrepo/moon/blob/332983a450cb3803d5466177963c087a3f30a102/crates/action-graph/src/action_graph_builder.rs
[action-node]: https://github.com/moonrepo/moon/blob/332983a450cb3803d5466177963c087a3f30a102/crates/action/src/action_node.rs
[dispatcher]: https://github.com/moonrepo/moon/blob/332983a450cb3803d5466177963c087a3f30a102/crates/action-pipeline/src/job_dispatcher.rs
[pipeline]: https://github.com/moonrepo/moon/blob/332983a450cb3803d5466177963c087a3f30a102/crates/action-pipeline/src/action_pipeline.rs
[fingerprint]: https://github.com/moonrepo/moon/blob/332983a450cb3803d5466177963c087a3f30a102/crates/task-hasher/src/task_fingerprint.rs
[hasher]: https://github.com/moonrepo/moon/blob/332983a450cb3803d5466177963c087a3f30a102/crates/task-hasher/src/task_hasher.rs
[task-hashing]: https://github.com/moonrepo/moon/blob/332983a450cb3803d5466177963c087a3f30a102/crates/task-hasher/src/task_hashing.rs
[task-expander]: https://github.com/moonrepo/moon/blob/332983a450cb3803d5466177963c087a3f30a102/crates/task-expander/src/task_expander.rs
[affected]: https://github.com/moonrepo/moon/blob/332983a450cb3803d5466177963c087a3f30a102/crates/affected/src/affected_tracker.rs
[task-config]: https://github.com/moonrepo/moon/blob/332983a450cb3803d5466177963c087a3f30a102/crates/config/src/task_config.rs
[task-runner]: https://github.com/moonrepo/moon/blob/332983a450cb3803d5466177963c087a3f30a102/crates/task-runner/src/task_runner.rs
[hydrater]: https://github.com/moonrepo/moon/blob/332983a450cb3803d5466177963c087a3f30a102/crates/task-runner/src/output_hydrater.rs
[archiver]: https://github.com/moonrepo/moon/blob/332983a450cb3803d5466177963c087a3f30a102/crates/task-runner/src/output_archiver.rs
[command-builder]: https://github.com/moonrepo/moon/blob/332983a450cb3803d5466177963c087a3f30a102/crates/task-runner/src/command_builder.rs
[cache-engine]: https://github.com/moonrepo/moon/blob/332983a450cb3803d5466177963c087a3f30a102/crates/cache/src/cache_engine.rs
[storage]: https://github.com/moonrepo/moon/blob/332983a450cb3803d5466177963c087a3f30a102/crates/cache-storage/src/storage.rs
[capabilities]: https://github.com/moonrepo/moon/blob/332983a450cb3803d5466177963c087a3f30a102/crates/cache-storage/src/capabilities.rs
[local]: https://github.com/moonrepo/moon/blob/332983a450cb3803d5466177963c087a3f30a102/crates/cache-local/src/local_storage.rs
[cas]: https://github.com/moonrepo/moon/blob/332983a450cb3803d5466177963c087a3f30a102/crates/cas/src/cas.rs
[gc]: https://github.com/moonrepo/moon/blob/332983a450cb3803d5466177963c087a3f30a102/crates/cas/src/gc.rs
[manifest]: https://github.com/moonrepo/moon/blob/332983a450cb3803d5466177963c087a3f30a102/crates/manifest/src/task_manifest.rs
[grpc]: https://github.com/moonrepo/moon/blob/332983a450cb3803d5466177963c087a3f30a102/crates/cache-remote/src/grpc_remote_storage.rs
[http]: https://github.com/moonrepo/moon/blob/332983a450cb3803d5466177963c087a3f30a102/crates/cache-remote/src/http_remote_storage.rs
[concepts]: ./concepts.md
[bazel]: ./bazel.md
[buck2]: ./buck2.md
[please]: ./please.md
[pants]: ./pants.md
[buildkit]: ./buildkit.md
[buildxl]: ./buildxl.md
[shake]: ./shake.md
[rattle]: ./rattle.md
[mono-moon]: ../monorepo-tooling/moon/
