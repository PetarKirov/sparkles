# sbt (Scala / JVM engine)

sbt's engine in one sentence: a **macro-extracted task DAG** evaluated by an
identity-memoized in-process queue that _suspends_ a task discovering another at run
time, holding **no persistent rebuild information of its own** — incrementality is
delegated to Zinc and, from 2.x, to a content-addressed action cache in the task macro.
Engine companion to the workspace survey.

**Last reviewed:** November 3, 2026

| Field                 | Value                                                                                                          |
| --------------------- | -------------------------------------------------------------------------------------------------------------- |
| Language              | `Scala` 3.9.0 (`project/Dependencies.scala`); ~150k lines in 2,265 `.scala` files                              |
| License               | Apache-2.0 (`LICENSE`; `build.sbt` → `licenses := List("Apache-2.0" -> …)`)                                    |
| Repository            | [sbt/sbt][repo]; Zinc, `sbt.io` and library management are separate repos (`README.md`)                        |
| Documentation         | [scala-sbt.org][docs] (manual out of tree); in-tree design notes under `notes/2.0.0/`, `notes/2.1.0/`          |
| Category              | Language build tool / task engine; companion to [sbt (monorepo-tooling)][mono-sbt]                             |
| Clone (pinned)        | `$REPOS/build-systems-research/src/sbt`, commit `515ce25869e3be062ab1b53c619a478e85275a60` (2026-10-31)        |
| Tree version          | `build.sbt` → `2.1.0-SNAPSHOT`; `notes/2.1.0/meta.md` records `2.0.x` moving “past `2.0.8`”                    |
| Scheduler × rebuilder | Topological × per-invocation dirty bit — plus **suspension** for dynamic edges, and an action cache underneath |
| Sandbox / remote      | **None** / REAPI **cache-only** (Action Cache + CAS + ByteStream); no `Execution` service                      |

> [!NOTE]
> **Delta against the workspace page.** [sbt (monorepo-tooling)][mono-sbt] covers the
> `build.sbt` DSL, `Project` topology, `aggregate`/`dependsOn`, the scoped-key CLI and
> tag-based concurrency, and treats 1.x as production. This page goes into the engine: how
> a task body becomes a `Node`, what `Execute` does per tick, why `Def.taskDyn` neither
> restarts nor deadlocks, and what the 2.x cache key is made of. The clone is
> `2.1.0-SNAPSHOT`, so 2.x caching is present tense.

## Overview

### What it solves

A build written in the host language, where "this task reads that task" is an ordinary
expression and ordering, de-duplication and parallelism fall out of it rather than a
separate graph language: `build.sbt` is Scala over a key/value graph, and the engine turns
`.value` sites into edges.

### Design philosophy

**The graph is extracted, not declared.** `Def.task`, `:=`, `+=` are macros; the
`InputWrapper` markers they emit (`wrapInit_☃☃`, `wrapInitTask_☃☃`) are recognised and
lifted into a dependency tuple before anything runs, so a captured body cannot depend on a
run-time value — the macro rejects it:

> "Task dependency expressions cannot reference values defined inside this task. Move 'name'
> outside the task definition, or use Def.taskDyn to construct the dependent task."
>
> — `main-settings/src/main/scala/sbt/std/TaskMacro.scala`

**The engine is small and the tasks are large.** `Execute` knows nothing about files,
hashes or compilers; a `Node` is a dependency list plus a function from input results to a
result, and everything a build system normally owns — staleness, output tracking, cache
keys — lives inside task bodies. sbt 2.x kept that division: caching arrived by _wrapping
the task body_ from the macro, not by teaching the scheduler about digests. The tree's
summary:

> "sbt 2.x caches task results by default. `cacheVersion` provides an escape hatch
> to invalidate all caches when needed."
>
> — `notes/2.0.0/cache-version.md`

## How it works

### 1. Task model & scheduling

A `Task[A]` is an `AttributeMap` plus an `Action[A]`
(`tasks-standard/src/main/scala/sbt/Task.scala`); `Action` has six cases — `Pure`,
`Mapped`, `FlatMapped`, `DependsOn`, `Join`, `Selected` (`.../sbt/internal/Action.scala`).
`Transform.scala` lowers each into a `Node` — "Represents a task node in a format
understood by the task evaluation engine Execute" (`tasks/src/main/scala/sbt/Node.scala`) —
whose whole interface is `dependencies`, `computeInputs` and `work`, the last returning
`Either[TaskId[A], A]`.

`Execute` walks that structure on demand rather than precomputing a linear order: `addNew`
registers a node, subtracts done dependencies from its `forward` set and calls `ready` only
when nothing is left; `processAll` pulls the next `Completed` from a `CompletionService` (a
fixed pool behind `ExecutorCompletionService`). Parallelism is throttled by
`ConcurrentRestrictions` tags, defaulting to `Tags.limitAll(processors)` plus a fork budget
for test groups and exclusive groups for `Clean`
(`main/src/main/scala/sbt/Defaults.scala`). De-duplication is by **object identity**
(`Execute.taskMap` is a `java.util.IdentityHashMap`), so memoization is exact only because
a key's `Task` instance is built once per session.

Dynamic edges take the _third_ path of the [concepts] trio. `FlatMapped`'s `work` returns
`Left(target)`; `Execute.work` answers with `call(node, target)`, parks the caller in
`State.Calling`, registers the target, and later hands the caller the result through
`retire`/`callerResult`. The caller is **suspended, not restarted** — no work is discarded,
so `Def.taskDyn` over a large fan-out stays linear. Since no complete graph is known up
front, cycle detection splits between an eager `cycleCheck` and a deadlock check
(`snapshotCycleCheck`).

### 2. Rebuilding & correctness

There is **no persisted rebuild information per task**: `results`, `state`, `forward`,
`reverse` and `callers` are per-`Execute` maps and `runKeep` asserts the instance is fresh,
so every reachable task runs at least once per command — "minimal" here means _once per
invocation_, not _only if inputs changed_. In [concepts] terms sbt sits in the dirty-bit
cell with the bit being "no memo yet", the degenerate form. Cross-invocation staleness is
the task body's problem, and `util-tracking` ships the toolkit: `Tracked.inputChanged` /
`outputChanged` over a `CacheStore` plus a `SingletonCache[Long]` holding a **32-bit**
`Hasher.hash` of the previous inputs, with file-granularity flavours from `FileInfo.Style` —
a verifying trace in miniature, content-based and opt-in per task.

For compilation the rebuilder is **Zinc**, pinned at `2.1.0-M10`
(`project/Dependencies.scala`, overridable via `sbtzinc.path`) in a separate
repository. The sbt tree owns the wiring: `compileIncremental` produces an
`Analysis`, `compileAnalysisFile` names the `target/.../zinc` file, and
`AnalysisUtil.staticCachedStore` wraps it with `reproducible = true`; `clean`
clears the store before deleting outputs.

Inside the pinned Zinc `v2.1.0-M10` (`0401049…`), an `Analysis` is five coordinated structures:
source/product/library **stamps**, extracted **APIs**, **relations**,
per-source info, and compilation records ([`Analysis.scala`][zinc-analysis]).
Relations separately track produced products, class definitions, internal
class dependencies split into inheritance / local-inheritance / member-ref,
external dependencies, library use, and the names each class used
([`Relations.scala`][zinc-relations]). A compile is a sequence of cycles:
compute stamp changes, map invalidated classes (including package objects) to
sources, prune old classfiles/relations, compile, extract new APIs and
dependencies through the compiler bridge, then decide whether API changes
invalidate another cycle ([`IncrementalCommon.scala`][zinc-incremental]).

Name hashing is the early-cutoff policy. `MemberRefInvalidator` does not
invalidate every dependent for every API change: a private trait-member
change invalidates none through member-ref; ordinary `NamesChange` entries
invalidate only dependents whose recorded used-names intersect the modified
names; macro/annotation definitions and changes to implicit names invalidate
unconditionally; non-Scala dependencies bypass the filter
([`MemberRefInvalidator.scala`][zinc-invalidator]). The compiler bridge is
therefore an in-process dependency oracle, not a depfile afterthought: it
observes compiler phases, extracts APIs/names/dependencies directly, and
feeds them into the next cycle. Zinc's correctness boundary is the bridge's
ability to model Scala/Java compilation semantics (including macros,
annotations, package objects, local classes, and binary stamps), not the sbt
task graph's declared file inputs.

sbt 2.x adds a second, independent rebuilder as an **action cache**. `Def.cachedTask` and
`@cacheLevel` make the macro wrap the body in `ActionCache.cache`; `Def.uncached` and
`@transient` opt out; `CacheLevelTag.InputOnly` is the middle case — "the task is not
cached, so it runs every time, but its value still takes part in the cache key of the tasks
that read it" (`util-cache/src/main/scala/sbt/util/ActionCache.scala`). The key is SHA-256
over three digests (`mkInput`): a `HashWriter` digest of the task's **input values**, a
`codeContentHash`, and an `extraHash` — plus `cacheVersion` when non-zero. `codeContentHash`
is `Digest.dummy(body.show.##)`, a 32-bit hash of the printed body tree computed at compile
time (`core-macros/.../appmacro/Cont.scala`); `extraHash` is `0L`. Because the key hashes
input _values_, a hit reproduces identical values for consumers whose keys are then
unchanged — value-level early cutoff from the cache, not the scheduler.

### 3. Dependency discovery

At task-graph level, declared only: `.value` in a task macro, plus
`Def.taskDyn` when the _shape_ depends on a value. No tracing, no FUSE, no
depfile ingestion, no strict-deps mode. Compilation is the exception by
delegation: Zinc's compiler bridge discovers class/API/name dependencies from
inside `scalac`/Java compilation and stores them in `Analysis` relations, so
source-level discovery is compiler-observed even though task-level discovery
is macro-declared.
`validateTaskReferences` is the sole enforcement point — rejecting captured locals is what
keeps the extracted edge set sound — and the rest is convention: an undeclared read of a
file, environment or global is neither detected nor diagnosable. `Def.cachedTask` also
refuses `java.io.File`/`Path` outputs and errors when declared outputs escape
`rootOutputDirectory`.

### 4. Store & caching

`ActionCacheStore` is REAPI-shaped rather than bespoke — "An abstraction of a remote or
local cache store" (`util-cache/src/main/scala/sbt/util/ActionCacheStore.scala`) — speaking
`UpdateActionResultRequest` → `ActionResult`, not "task name → blob":

```scala
def put(request: UpdateActionResultRequest): Either[Throwable, ActionResult]
def get(request: GetActionResultRequest): Either[Throwable, ActionResult]
def putBlobs(blobs: Seq[VirtualFile]): Seq[HashedVirtualFileRef]
```

That is the catalog's **manifest then blobs** lookup: one small `ActionResult` (output refs,
`origin`, `exitCode`) per input digest, then content-addressed blobs. `DiskActionCacheStore`
lays it out as `ac/` and `cas/`, seals CAS files read-only and writes blobs in parallel;
`AggregateActionCacheStore` reads first-hit and writes to every store. Local blobs are
trusted (copied unhashed, verified lazily); remote ones are not:

> "Blobs may come from a remote cache and are untrusted, so the digest is computed
> while the stream is written out; on mismatch the staged file is discarded and the
> caller fails rather than syncing tampered content into the build."
>
> — `util-cache/src/main/scala/sbt/util/ActionCacheStore.scala`

Backends are `GrpcActionCacheStore` and `HttpActionCacheStore`, both carrying
`build.bazel.remote.execution.v2` protos: Action Cache, CAS, ByteStream,
`DigestFunction.Sha256`, 1 MiB chunked uploads, a 100-thread transfer pool, ≤10 s metadata
deadlines against a longer transfer timeout, TLS material from `remoteCacheTls*`.
`CacheEventLog` records `Found(storeName)`/`OnsiteTask`/`Error` and prints a hit-rate
summary; an optional `SpawnExec` log records per-task `cacheHit` with origin.

### 5. Hermeticity & provenance

Absent, and the absence is the finding. Tasks run in the sbt JVM (forked JVMs only for
`run`/`test`) with full filesystem, network and environment — a repository-wide search for
"sandbox" finds only `lm-coursier`'s unrelated "sandbox configuration" for `scala-tool`. No
mount namespace, no `ptrace`/`seccomp` observer, no read tracking: a key is only as honest
as the body. The one enforced boundary is outputs — a cached task whose declared outputs
escape `rootOutputDirectory` is refused with `Cannot cache task because its output files
are outside the output directory`. Provenance is cache telemetry only (`ActionResult.origin`
names the store a hit came from): no attestations, no in-toto/SLSA hooks, no signing in
`sbt-remote-cache`.

### 6. Distribution

No remote execution. `sbt-remote-cache` is cache-only — Action Cache, CAS, ByteStream — and
never calls the REAPI `Execution` service, so a hit skips work that would otherwise run
locally and a miss always runs locally. What exists is a **build server**:
`client/src/main/java/sbt/client/Client.java` is a Native-Image thin client over a socket to
a resident sbt, with its JSON-RPC handshake in `server.md`, plus a BSP endpoint for IDEs —
daemon-resident operation, not distribution. `~`/`watch` is the nearest rescheduler:
`Continuous.scala` watches globbed inputs, records `FileStamp`s and re-invokes the whole
command — a loop _above_ the scheduler.

### 7. Sparkles relevance

`sparkles.build_primitives.task` is a static in-process DAG with no store, so the
borrowings are mechanisms:

- **Suspension beats restart for dynamic deps.** `Left(target)` plus a `Calling` state and a
  `callers` set buys the [concepts] §2 property a topological scheduler otherwise cannot
  have, for very little machinery.
- **Identity as memo key is a trap, and `InputOnly` is missing vocabulary.** De-dup is
  exact only while a key's `Task` instance is unique per session, and "runs every time, but
  its value is still an input to everyone else's key" is exactly a cheap setting read in a
  cached DAG — one enum case, not a subsystem.
- **Layer the cache in the wrapper, not the scheduler.** sbt gained content-addressed
  caching without touching `Execute`; the price is two coexist models (Zinc analysis, action
  cache) with different key material — copy its `cacheVersion`-in-key and `clean`-as-epoch
  levers alongside.

## Strengths

- **Tiny, inspectable core.** Six `Action` cases and one `Node` interface carry every
  scheduling behaviour, dynamic dependencies and cancellation included; `Def.taskDyn` costs
  a parked state, not a re-execution.
- **Caching with no scheduler change.** A REAPI-compatible content-addressed cache arrived by
  wrapping task bodies; the graph engine is untouched and any REAPI server is a backend.
- **Cached failures.** Storing the `CachedCompileFailure` makes a warm CI re-report an error
  instead of recompiling to rediscover it.

## Weaknesses

- **Nothing survives the session at task level.** Only tasks wrapped in `cachedTask` are
  incremental across commands.
- **Two incrementality models, two key materials.** Zinc's name-hashing analysis and the action
  cache's value digests can disagree about "changed", and nothing reconciles them.
- **`codeContentHash` is weak.** A 32-bit hash of the printed body tree folds into the SHA-256;
  a body edit with identical printing is invisible and `extraHash` is zero.
- **No sandbox, no read observation, no eviction.** The key is exactly as honest as the body,
  undeclared inputs give silently wrong hits, the disk CAS never sweeps, and the cache-only
  REAPI client leaves CI parallelism to sharding.
- **Recovery is task-by-task.** `dirzip-restore-on-hit.md` records a real bug: deleting a
  declared output directory left a `.sbtdir.zip` sibling, so the cache believed everything was
  in sync and `run` failed with `ClassNotFoundException` — fixed by re-extracting a missing
  directory at "the cost of a single stat on the warm path".

## Key design decisions and trade-offs

| Decision                                      | Rationale                                                       | Trade-off                                                          |
| --------------------------------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------ |
| `.value` extracted at compile time by a macro | Edges are ordinary Scala, checked by the compiler, no graph DSL | Captured locals rejected; data-dependent shape needs `Def.taskDyn` |
| Suspension for dynamic dependencies           | Minimal: no discarded work, no restart loop                     | Callers pinned in `Calling`; graph unknowable before it runs       |
| Identity-keyed memo tables                    | O(1) de-dup with no equality contract on `Task`                 | De-dup depends on instance uniqueness per session                  |
| No persistent task-level trace                | Zero bookkeeping, no stale state, correct per invocation        | Every task runs each command; incrementality pushed into bodies    |
| Key includes input _values_, not digests      | Downstream keys see unchanged values — early cutoff for free    | Wide keys; large inputs must hash cheaply                          |
| REAPI-shaped `ActionCacheStore`               | Any REAPI server is a backend; format is not sbt-specific       | Assumes manifest-then-blobs structure and `ActionResult` semantics |

## Sources

- [`sbt/sbt`][repo] at commit `515ce25869e3be062ab1b53c619a478e85275a60` (2026-10-31, branch
  `2.x`), clone at `$REPOS/build-systems-research/src/sbt`; quotes verbatim from the cited files.
- Engine: [`Execute.scala`][execute], [`Node.scala`][node], [`Action.scala`][action],
  [`Transform.scala`][transform], [`Task.scala`][task], [`TaskMacro.scala`][taskmacro],
  [`Def.scala`][defn], [`Cont.scala`][cont], [`ConcurrentRestrictions.scala`][restrictions],
  [`CompletionService.scala`][completion].
- Cache and compile wiring: [`ActionCache.scala`][actioncache], [`ActionCacheStore.scala`][acstore],
  [`Tracked.scala`][tracked], [`FileInfo.scala`][fileinfo], [`CacheEventLog.scala`][cachelog],
  [`GrpcActionCacheStore.scala`][grpc], [`HttpActionCacheStore.scala`][http],
  [`Defaults.scala`][defaults], [`AnalysisUtil.scala`][analysisutil], [`Dependencies.scala`][deps],
  [`cache-version.md`][cache-version], [`dirzip-restore-on-hit.md`][dirzip], [`meta.md`][meta].
- Server, client, context: [`Continuous.scala`][continuous], [`Client.java`][client],
  [`server.md`][servermd], [`README.md`][readme], [`build.sbt`][buildsbt]; siblings [concepts],
  [bazel], [buck2], [please], [moon], [buildkit], [buildxl], [mono-sbt].

<!-- References -->

[repo]: https://github.com/sbt/sbt
[docs]: https://www.scala-sbt.org/
[readme]: https://github.com/sbt/sbt/blob/515ce25869e3be062ab1b53c619a478e85275a60/README.md
[buildsbt]: https://github.com/sbt/sbt/blob/515ce25869e3be062ab1b53c619a478e85275a60/build.sbt
[execute]: https://github.com/sbt/sbt/blob/515ce25869e3be062ab1b53c619a478e85275a60/tasks/src/main/scala/sbt/Execute.scala
[node]: https://github.com/sbt/sbt/blob/515ce25869e3be062ab1b53c619a478e85275a60/tasks/src/main/scala/sbt/Node.scala
[restrictions]: https://github.com/sbt/sbt/blob/515ce25869e3be062ab1b53c619a478e85275a60/tasks/src/main/scala/sbt/ConcurrentRestrictions.scala
[completion]: https://github.com/sbt/sbt/blob/515ce25869e3be062ab1b53c619a478e85275a60/tasks/src/main/scala/sbt/CompletionService.scala
[action]: https://github.com/sbt/sbt/blob/515ce25869e3be062ab1b53c619a478e85275a60/tasks-standard/src/main/scala/sbt/internal/Action.scala
[transform]: https://github.com/sbt/sbt/blob/515ce25869e3be062ab1b53c619a478e85275a60/tasks-standard/src/main/scala/sbt/std/Transform.scala
[task]: https://github.com/sbt/sbt/blob/515ce25869e3be062ab1b53c619a478e85275a60/tasks-standard/src/main/scala/sbt/Task.scala
[taskmacro]: https://github.com/sbt/sbt/blob/515ce25869e3be062ab1b53c619a478e85275a60/main-settings/src/main/scala/sbt/std/TaskMacro.scala
[defn]: https://github.com/sbt/sbt/blob/515ce25869e3be062ab1b53c619a478e85275a60/main-settings/src/main/scala/sbt/Def.scala
[cont]: https://github.com/sbt/sbt/blob/515ce25869e3be062ab1b53c619a478e85275a60/core-macros/src/main/scala/sbt/internal/util/appmacro/Cont.scala
[actioncache]: https://github.com/sbt/sbt/blob/515ce25869e3be062ab1b53c619a478e85275a60/util-cache/src/main/scala/sbt/util/ActionCache.scala
[acstore]: https://github.com/sbt/sbt/blob/515ce25869e3be062ab1b53c619a478e85275a60/util-cache/src/main/scala/sbt/util/ActionCacheStore.scala
[fileinfo]: https://github.com/sbt/sbt/blob/515ce25869e3be062ab1b53c619a478e85275a60/util-cache/src/main/scala/sbt/util/FileInfo.scala
[cachelog]: https://github.com/sbt/sbt/blob/515ce25869e3be062ab1b53c619a478e85275a60/util-cache/src/main/scala/sbt/internal/util/CacheEventLog.scala
[tracked]: https://github.com/sbt/sbt/blob/515ce25869e3be062ab1b53c619a478e85275a60/util-tracking/src/main/scala/sbt/util/Tracked.scala
[defaults]: https://github.com/sbt/sbt/blob/515ce25869e3be062ab1b53c619a478e85275a60/main/src/main/scala/sbt/Defaults.scala
[analysisutil]: https://github.com/sbt/sbt/blob/515ce25869e3be062ab1b53c619a478e85275a60/main/src/main/scala/sbt/internal/AnalysisUtil.scala
[continuous]: https://github.com/sbt/sbt/blob/515ce25869e3be062ab1b53c619a478e85275a60/main/src/main/scala/sbt/internal/Continuous.scala
[grpc]: https://github.com/sbt/sbt/blob/515ce25869e3be062ab1b53c619a478e85275a60/sbt-remote-cache/src/main/scala/sbt/internal/GrpcActionCacheStore.scala
[http]: https://github.com/sbt/sbt/blob/515ce25869e3be062ab1b53c619a478e85275a60/sbt-remote-cache/src/main/scala/sbt/internal/HttpActionCacheStore.scala
[deps]: https://github.com/sbt/sbt/blob/515ce25869e3be062ab1b53c619a478e85275a60/project/Dependencies.scala
[cache-version]: https://github.com/sbt/sbt/blob/515ce25869e3be062ab1b53c619a478e85275a60/notes/2.0.0/cache-version.md
[dirzip]: https://github.com/sbt/sbt/blob/515ce25869e3be062ab1b53c619a478e85275a60/notes/2.0.0/dirzip-restore-on-hit.md
[meta]: https://github.com/sbt/sbt/blob/515ce25869e3be062ab1b53c619a478e85275a60/notes/2.1.0/meta.md
[client]: https://github.com/sbt/sbt/blob/515ce25869e3be062ab1b53c619a478e85275a60/client/src/main/java/sbt/client/Client.java
[servermd]: https://github.com/sbt/sbt/blob/515ce25869e3be062ab1b53c619a478e85275a60/server.md
[concepts]: ./concepts.md
[bazel]: ./bazel.md
[buck2]: ./buck2.md
[please]: ./please.md
[moon]: ./moon.md
[buildkit]: ./buildkit.md
[buildxl]: ./buildxl.md
[mono-sbt]: ../monorepo-tooling/sbt/
[zinc-analysis]: https://github.com/sbt/zinc/blob/040104911bd6a9585545af030b42da45bd19e276/internal/zinc-core/src/main/scala/sbt/internal/inc/Analysis.scala
[zinc-relations]: https://github.com/sbt/zinc/blob/040104911bd6a9585545af030b42da45bd19e276/internal/zinc-core/src/main/scala/sbt/internal/inc/Relations.scala
[zinc-incremental]: https://github.com/sbt/zinc/blob/040104911bd6a9585545af030b42da45bd19e276/internal/zinc-core/src/main/scala/sbt/internal/inc/IncrementalCommon.scala
[zinc-invalidator]: https://github.com/sbt/zinc/blob/040104911bd6a9585545af030b42da45bd19e276/internal/zinc-core/src/main/scala/sbt/internal/inc/MemberRefInvalidator.scala
