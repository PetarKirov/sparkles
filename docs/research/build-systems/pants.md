# Pants (Rust engine, Python rules)

A statically solved rule graph selects typed Python coroutines, a memoized in-memory DAG
runs them as a suspending scheduler keyed by generation counters, and every external
process is a content-addressed action in a sharded LMDB store, local or behind REAPI.

**Last reviewed:** November 2, 2026

| Field          | Value                                                                                                           |
| -------------- | --------------------------------------------------------------------------------------------------------------- |
| Language       | Rust engine (`src/rust`, ~86.6k lines in 252 files) + typed Python 3 rules (`src/python/pants`, ~308k lines)    |
| License        | Apache-2.0 (`LICENSE`)                                                                                          |
| Repository     | [pantsbuild/pants][repo]                                                                                        |
| Documentation  | [pantsbuild.org][docs]; in-tree [`how-does-pants-work.mdx`][how-doc], [`the-rules-api/concepts.mdx`][rules-doc] |
| Category       | Polyglot build orchestrator; engine companion to [pants (monorepo-tooling)][mono-pants]                         |
| Clone (pinned) | `$REPOS/build-systems-research/src/pants`                                                                       |
| Commit         | `88f57cf3ec558cd2c0e48b339a41155c2b531c60` (2026-11-01), "Per-process sandboxer socket path (#23720)"           |
| Tree version   | `src/python/pants/VERSION` is `2.34.0.dev4`; no tag points at HEAD                                              |
| Engine crates  | `src/rust/rule_graph` (static solver), `src/rust/graph` (runtime DAG), `src/rust/fs/store`                      |
| Store / remote | Sharded LMDB CAS + action cache; REAPI `v2` client for cache, execution and bytestream                          |

> [!NOTE]
> **Delta against the workspace page.** [pants (monorepo-tooling)][mono-pants] covers
> `pants.toml`, `BUILD` targets, source roots, resolves, the CLI and remote-cache
> configuration. This page goes below that surface: rule-graph construction, the
> dirty/clean protocol, digests and snapshots, what the "sandbox" really is, and the
> command-runner stack that reaches REAPI.

## Overview

### What it solves

A polyglot monorepo where the dependency graph is already encoded in source imports:

> "Pants is a scalable build system for _monorepos_: codebases containing
> multiple projects, often using multiple programming languages and frameworks,
> in a single unified code repository." — [`README.md`][readme]

### Design philosophy

Rules (`@rule`) are pure coroutines with complete type annotations; the engine owns
execution, memoization and concurrency:

> "A rule is a pure function (or, more precisely, a pure coroutine) that maps a set of
> statically-declared input types to a statically-declared output type." —
> [`the-rules-api/concepts.mdx`][rules-doc]

> "The engine is designed so that fine-grained invalidation, concurrency,
> hermeticity, caching, and remote execution happen naturally, without rule authors
> needing to think about it." — [`how-does-pants-work.mdx`][how-doc]

That purity is why the runtime DAG is a memo table. Rust owns ordering, invalidation and
RPC; Python owns the rules. `RuleGraph::new` runs once per scheduler
([`context.rs`][context]); the builder exists to "produce a RuleGraph that allows
dependency nodes to be found statically" ([`builder.rs`][builder]).

## How it works

### 1. Task model & scheduling

**Static selection.** Rule-graph nodes are `RuleEntry`, `Param`, `Root` and `Reentry`;
a `DependencyKey` carries the product, the params the callee may consume, the params it
must receive, and an optional by-name call signature ([`rules.rs`][rg-rules]). The dynamic
**node graph** (`Graph<NodeKey>`) instantiates that choice for concrete params. The
builder propagates live parameters, monomorphizes per valid parameter combination, prunes
edges, and keeps `UnreachableError` entries so a bad plugin fails with a graph explanation
([`builder.rs`][builder], [`rule_graph/lib.rs`][rg-lib]).

**Suspending execution.** A `Task` node carries interned params, an optional positional
argument key and the interned rule entry. On `await`, `Context::get` calls `Graph::get_inner`,
which ensures the target entry exists, adds the caller's edge, and awaits its result
([`graph/context.rs`][graph-ctx], [`graph/lib.rs`][graph]).
The caller is suspended, not restarted — JFP §4.3's mechanism on Rust futures; `bounded`
caps local and remote process parallelism separately ([`context.rs`][context]).

**Cycles.** The graph is a DAG "enforced on mutation" ([`graph/lib.rs`][graph]); every
500 ms a watchdog breaks one member of each running SCC, and a node invalidated during
a run is retried after 500 ms. `RunId` scopes a run, `RunToken` one attempt, and
`Generation` is what dependents observe ([`entry.rs`][entry]).

### 2. Rebuilding & correctness

In [concepts] terms this is **suspending × verifying step traces** (the `Shake` cell), with
a constructive action cache below it, so it straddles JFP §5.2 and §5.3.
An entry is `NotStarted`, `Running` or `Completed`; a completed value is `Clean`, `Dirty`,
`Uncacheable` or `UncacheableDependencies` ([`entry.rs`][entry]). The rebuilder is a
verifying step trace: each dependency is recorded as `(EntryId, Generation)`, and cleaning
re-requests every dependency and compares generations:

> "Unlike the RunToken (which is incremented whenever a node re-runs), the Generation is
> only incremented when the output of a node has changed." — [`entry.rs`][entry]

That is early cutoff: a re-run whose value compares equal does not advance its generation,
so dependents stay clean — exact value equality, not a hash approximation.

Cleaning is speculative and parallel: `attempt_cleaning` joins all dependency checks with
`try_join_all`, fails fast on the first mismatch, and cancels the rest; a mismatch clears
the node's outbound edges and forces a re-run ([`graph/lib.rs`][graph]). `restartable()`
decides whether invalidation may propagate _through_ a running node, and `cacheable()` /
`_uncacheable_rule` mark results that must not outlive a run ([`node.rs`][node],
[`rules.py`][py-rules]). The durable part is the process layer: a process is keyed by its
action digest, so a cold daemon can still hit the on-disk action cache.

### 3. Dependency discovery

Three layers are often confused:

1. **Rule-to-rule edges** are declared by type annotations and `await` calls; the Rust
   solver resolves them statically, and the AST visitor exists so a dynamically chosen call
   still contributes a static edge ([`rule_visitor.py`][rule-visitor]).
2. **File-to-file edges inside a target** are inferred by parsing source text. Native Rust
   parsers for Python, JavaScript and Dockerfile live under `src/rust/dep_inference`;
   Python merges their output with explicit `dependencies` in `resolve_dependencies`
   ([`graph.py`][py-graph]).
3. **Package boundaries** are `DependencyRule` allow/deny/warn actions
   ([`dep_rules.py`][dep-rules]).

There is no syscall, FUSE or `ptrace` tracing: inference is static parsing. `find_owners`
maps a path back to its target, and target-graph cycles are detected separately, with
file-level dependencies tolerated ([`graph.py`][py-graph]) — the "declared, then trusted"
position of [please], not the traced model of [buildxl].

### 4. Store & caching

**CAS.** `Store` wraps a local `ByteStore` and an optional remote one. The local half is
`ShardedLmdb`: because "each LMDB directory can have at most one concurrent writer", it
shards by the high bits of the fingerprint into 16 environments by default so writes proceed
in parallel ([`sharded_lmdb/src/lib.rs`][sharded-lmdb]). Files at or above 512 KiB spill to a
filesystem store, a threshold chosen so two to three reads break even
([`store/local.rs`][store-local]). Loads are local-first, then remote back-fill and a
second local read ([`store/src/lib.rs`][store]).

**Digests and snapshots.** `Digest { hash, size_bytes }` is the content handle, and a
`Snapshot` is a digest plus a `DigestTrie`; its `PartialEq` compares only the digest
([`store/snapshot.rs`][snapshot]). The `Snapshot` node does not watch paths: it expands
globs through `Scandir`/`DigestFile` children, the actual invalidation roots
([`snapshot.rs`][snapshot-node], [`nodes/mod.rs`][nodes-mod]).

**Action cache.** `PersistentCache` stores small values keyed by `CacheKey`:

> "In order for this to be a cache, rather than storing the value under its _own_
> Fingerprint, the value is stored under the Fingerprint of the CacheKey." —
> [`cache/src/lib.rs`][persistent-cache]

A runner stack composes local/workspace and Docker/nailgun dispatch, `bounded` parallelism,
remote execution, and the remote and local action caches ([`context.rs`][context]).
`ProcessCacheScope` decides where a result may be cached; `CacheContentBehavior` whether a
hit's digests are fetched, validated or deferred ([`process_execution/lib.rs`][pe-lib]).

### 5. Hermeticity & provenance

The sandbox is a **directory**, not a namespace. Each process gets a temporary directory,
its input digests are materialized (directly, via the sandboxer, or as symlinks to
immutable inputs), and the child runs with a cleared environment:

> "It would be really nice not to have to manually set PATH but this is sadly the only
> way to stop automatic PATH searching." — [`process_execution/src/local.rs`][local]

`Process::env` documents the contract: "No other environment variables will be set
(except possibly for an empty PATH variable)" ([`process_execution/lib.rs`][pe-lib]).
Absolute paths outside the sandbox remain readable and no read is intercepted, so
hermeticity is enforced by declaration and cache-key construction, not by the kernel. A
grep for `bubblewrap`, `bwrap`, `ptrace`, `seccomp`, `landlock` and `unshare` across
`src/rust/process_execution` finds nothing.

The component named `sandboxer` is not an isolation boundary: it exists because
materializing an executable while another fork inherits the write handle causes `ETXTBSY`,
so a dedicated process writes executables over a Unix socket ([`sandboxer/src/lib.rs`][sandboxer]).

Provenance is absent: no `SLSA`, `in-toto` or attestation code outside Docker test fixtures.

### 6. Distribution

Distribution is REAPI and only REAPI: `remote::CommandRunner` speaks
`build.bazel.remote.execution.v2`, submits an `ExecuteRequest`, waits on the long-running
operation, and treats missing remote digests as retryable ([`remote.rs`][remote]). The
remote _cache_ runner wraps a lower runner and consults the REAPI Action Cache before
executing, with its own read/write flags and warning backoff ([`remote_cache.rs`][remote-cache]).
Byte-store providers are pluggable (REAPI bytestream, `file://`, GitHub Actions cache), with
action-cache providers selected the same way ([`remote_provider`][provider]).

`ProcessExecutionStrategy` has four cases — `Local`, `LocalInWorkspace`,
`RemoteExecution(platform_properties)`, `Docker(image)` — each contributing a distinct
cache-key value ([`process_execution/lib.rs`][pe-lib]); placement and queueing belong to
the backend, and Pants runs no server-side graph.

### 7. Sparkles relevance

`sparkles.build_primitives.task` is a static, in-process DAG with no daemon and no
persistent store, so the borrowings are mechanisms, not architecture:

- **Generation counters as the dirty check.** Equal output means no generation bump, so
  dependents stop.
- **Per-edge dependency records.** `(dependency, generation)` makes clean/rebuild reasoning
  inspectable.
- **Cycle policy split.** Enforce a DAG on mutation, plus a watchdog that kills one SCC
  member.
- **Small-value cache beside a blob store.** A key/value cache for action results plus a
  filesystem/object store for contents is cheaper than one CAS for everything.

## Strengths

- **Typed rule graph catches configuration errors before execution.** Unreachable and
  shadowed rules are graph diagnostics, not runtime surprises.
- **Early cutoff without hashing.** Value equality and generation counters keep the check exact.
- **A content-addressed process layer.** Local cache, remote cache and REAPI execution share one key.
- **Fine-grained invalidation.** Only `Scandir`/`DigestFile`/`PathMetadata` nodes are roots;
  a `Snapshot` inherits invalidation through them.

## Weaknesses

- **Hermeticity is declared, not enforced.** No namespaces, `ptrace`, `seccomp` or
  `landlock`; an undeclared absolute read succeeds invisibly. `sandboxer` names a
  materialization workaround, not isolation.
- **The graph is daemon-resident.** Cross-run reuse needs `pantsd` alive; a cold start
  re-derives the graph and relies on the action cache.
- **Inference is static parsing.** Dynamic imports, generated modules and non-import file
  dependencies need explicit edges; there is no read observation to fall back on.
- **Eviction is lease-based and incomplete.** The local process cache has TODOs for GC.
- **Two languages, a large surface.** Rule bugs surface as Python exceptions inside a Rust
  scheduler, and ~86.6k lines of Rust plus ~308k of Python is a lot to match.

## Key design decisions and trade-offs

| Decision                                              | Rationale                                                                         | Trade-off                                                     |
| ----------------------------------------------------- | --------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| Static rule graph at startup, instantiated at runtime | Type errors and unreachable rules fail before work; edges known for dynamic calls | A solver to maintain; reboots on rule-set changes             |
| Suspending scheduler over Rust futures                | Minimal work with dynamic dependencies; no restart-and-redo                       | Every edge is an `await`; cancellation and invalidation races |
| Generation counters, not hashes, for dirty checks     | Cheap, exact early cutoff on comparable values                                    | Only works while the graph is resident; not a portable trace  |
| Speculative parallel cleaning, fail-fast              | Hides dependency-check latency on wide graphs                                     | Wasted checks on first mismatch; cancellation complexity      |
| Directory sandbox with cleared environment            | Cheap, portable, needs no kernel features                                         | Undeclared reads allowed; isolation is a convention           |
| Sharded LMDB CAS plus FSDB for large files            | Parallel writers without a central lock; small values stay fast                   | Two storage paths; threshold and schema version to manage     |
| One action key across local cache, remote cache, exec | A hit is a hit anywhere; backends are swappable                                   | Strict key discipline (strategy, platform, env)               |
| `ProcessCacheScope` as a typed enum                   | Cache lifetime is a deliberate per-process decision                               | Seven variants and a default to get right                     |

## Sources

- [`pantsbuild/pants`][repo] at commit
  `88f57cf3ec558cd2c0e48b339a41155c2b531c60` (clone at
  `$REPOS/build-systems-research/src/pants`; HEAD dated 2026-11-01). Quotes are verbatim
  from the files cited inline at that commit.
- Engine: [`rule_graph/lib.rs`][rg-lib], [`builder.rs`][builder], [`rules.rs`][rg-rules],
  [`graph/lib.rs`][graph], [`entry.rs`][entry], [`node.rs`][node],
  [`graph/context.rs`][graph-ctx], [`engine/context.rs`][context],
  [`nodes/snapshot.rs`][snapshot-node], [`nodes/mod.rs`][nodes-mod]; Python:
  [`engine/rules.py`][py-rules], [`internals/graph.py`][py-graph],
  [`rule_visitor.py`][rule-visitor], [`dep_rules.py`][dep-rules].
- Store and execution: [`fs/store/src/lib.rs`][store], [`store/local.rs`][store-local],
  [`store/snapshot.rs`][snapshot], [`sharded_lmdb/src/lib.rs`][sharded-lmdb],
  [`cache/src/lib.rs`][persistent-cache], [`process_execution/src/lib.rs`][pe-lib],
  [`local.rs`][local], [`sandboxer/src/lib.rs`][sandboxer],
  [`remote/src/remote.rs`][remote], [`remote/src/remote_cache.rs`][remote-cache],
  [`remote_provider`][provider].
- Docs in the clone: [`how-does-pants-work.mdx`][how-doc], [`the-rules-api/concepts.mdx`][rules-doc].
- Siblings: [concepts], [please], [bazel], [buck2], [buildxl], [buildkit], [rattle],
  [perfect-dependencies], [shake].

<!-- References -->

[repo]: https://github.com/pantsbuild/pants
[docs]: https://www.pantsbuild.org/
[readme]: https://github.com/pantsbuild/pants/blob/88f57cf3ec558cd2c0e48b339a41155c2b531c60/README.md
[how-doc]: https://github.com/pantsbuild/pants/blob/88f57cf3ec558cd2c0e48b339a41155c2b531c60/docs/docs/introduction/how-does-pants-work.mdx
[rules-doc]: https://github.com/pantsbuild/pants/blob/88f57cf3ec558cd2c0e48b339a41155c2b531c60/docs/docs/writing-plugins/the-rules-api/concepts.mdx
[rg-lib]: https://github.com/pantsbuild/pants/blob/88f57cf3ec558cd2c0e48b339a41155c2b531c60/src/rust/rule_graph/src/lib.rs
[builder]: https://github.com/pantsbuild/pants/blob/88f57cf3ec558cd2c0e48b339a41155c2b531c60/src/rust/rule_graph/src/builder.rs
[rg-rules]: https://github.com/pantsbuild/pants/blob/88f57cf3ec558cd2c0e48b339a41155c2b531c60/src/rust/rule_graph/src/rules.rs
[graph]: https://github.com/pantsbuild/pants/blob/88f57cf3ec558cd2c0e48b339a41155c2b531c60/src/rust/graph/src/lib.rs
[entry]: https://github.com/pantsbuild/pants/blob/88f57cf3ec558cd2c0e48b339a41155c2b531c60/src/rust/graph/src/entry.rs
[node]: https://github.com/pantsbuild/pants/blob/88f57cf3ec558cd2c0e48b339a41155c2b531c60/src/rust/graph/src/node.rs
[graph-ctx]: https://github.com/pantsbuild/pants/blob/88f57cf3ec558cd2c0e48b339a41155c2b531c60/src/rust/graph/src/context.rs
[context]: https://github.com/pantsbuild/pants/blob/88f57cf3ec558cd2c0e48b339a41155c2b531c60/src/rust/engine/src/context.rs
[snapshot-node]: https://github.com/pantsbuild/pants/blob/88f57cf3ec558cd2c0e48b339a41155c2b531c60/src/rust/engine/src/nodes/snapshot.rs
[nodes-mod]: https://github.com/pantsbuild/pants/blob/88f57cf3ec558cd2c0e48b339a41155c2b531c60/src/rust/engine/src/nodes/mod.rs
[py-rules]: https://github.com/pantsbuild/pants/blob/88f57cf3ec558cd2c0e48b339a41155c2b531c60/src/python/pants/engine/rules.py
[py-graph]: https://github.com/pantsbuild/pants/blob/88f57cf3ec558cd2c0e48b339a41155c2b531c60/src/python/pants/engine/internals/graph.py
[rule-visitor]: https://github.com/pantsbuild/pants/blob/88f57cf3ec558cd2c0e48b339a41155c2b531c60/src/python/pants/engine/internals/rule_visitor.py
[dep-rules]: https://github.com/pantsbuild/pants/blob/88f57cf3ec558cd2c0e48b339a41155c2b531c60/src/python/pants/engine/internals/dep_rules.py
[store]: https://github.com/pantsbuild/pants/blob/88f57cf3ec558cd2c0e48b339a41155c2b531c60/src/rust/fs/store/src/lib.rs
[store-local]: https://github.com/pantsbuild/pants/blob/88f57cf3ec558cd2c0e48b339a41155c2b531c60/src/rust/fs/store/src/local.rs
[snapshot]: https://github.com/pantsbuild/pants/blob/88f57cf3ec558cd2c0e48b339a41155c2b531c60/src/rust/fs/store/src/snapshot.rs
[sharded-lmdb]: https://github.com/pantsbuild/pants/blob/88f57cf3ec558cd2c0e48b339a41155c2b531c60/src/rust/sharded_lmdb/src/lib.rs
[persistent-cache]: https://github.com/pantsbuild/pants/blob/88f57cf3ec558cd2c0e48b339a41155c2b531c60/src/rust/cache/src/lib.rs
[pe-lib]: https://github.com/pantsbuild/pants/blob/88f57cf3ec558cd2c0e48b339a41155c2b531c60/src/rust/process_execution/src/lib.rs
[local]: https://github.com/pantsbuild/pants/blob/88f57cf3ec558cd2c0e48b339a41155c2b531c60/src/rust/process_execution/src/local.rs
[sandboxer]: https://github.com/pantsbuild/pants/blob/88f57cf3ec558cd2c0e48b339a41155c2b531c60/src/rust/process_execution/sandboxer/src/lib.rs
[remote]: https://github.com/pantsbuild/pants/blob/88f57cf3ec558cd2c0e48b339a41155c2b531c60/src/rust/process_execution/remote/src/remote.rs
[remote-cache]: https://github.com/pantsbuild/pants/blob/88f57cf3ec558cd2c0e48b339a41155c2b531c60/src/rust/process_execution/remote/src/remote_cache.rs
[provider]: https://github.com/pantsbuild/pants/blob/88f57cf3ec558cd2c0e48b339a41155c2b531c60/src/rust/remote_provider/src/lib.rs
[concepts]: ./concepts.md
[please]: ./please.md
[bazel]: ./bazel.md
[buck2]: ./buck2.md
[buildxl]: ./buildxl.md
[buildkit]: ./buildkit.md
[rattle]: ./rattle.md
[perfect-dependencies]: ./perfect-dependencies.md
[shake]: ./shake.md
[mono-pants]: ../monorepo-tooling/pants/
