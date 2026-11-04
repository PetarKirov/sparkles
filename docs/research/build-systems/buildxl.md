# BuildXL (C#)

BuildXL — Microsoft's "Build Accelerator", internally _Domino_ — answers one question:
can an engine stay correct over build languages that under-declare their inputs? Its answer
is to stop trusting declarations and _observe_ every file access at the OS boundary, then
make the observation the cache key. Vocabulary is [concepts]'s; this page does not redefine
_scheduler_, _rebuilder_, _trace_, _minimality_ or _early cutoff_.

**Last reviewed:** November 3, 2026

| Field          | Value                                                                                       |
| -------------- | ------------------------------------------------------------------------------------------- |
| Language       | C# (~5,290 `.cs` files under `Public/Src`), C/C++/eBPF for the sandboxes                    |
| License        | MIT — `LICENSE` carries `Copyright (c) 2019 Microsoft`                                      |
| Repository     | [microsoft/BuildXL][repo]                                                                   |
| Documentation  | In-tree: [Documentation/INDEX.md][doc-index]; specs under `Documentation/Specs/`            |
| Category       | Industry — engine for very large monorepos; Windows-first, also Linux (Ubuntu, Azure Linux) |
| Clone (pinned) | `ea34998661867b5959d7f496f8b5650611a3e446`                                                  |
| Frontends      | DScript (native), MSBuild static graph, JavaScript (Rush/Yarn/Lage), Ninja/CMake, NuGet     |

## Overview

### What it solves

Two entangled problems. Scale first: [`README.md`][readme] reports 150,000+ builds a day over
"codebases up to a half-terabyte in size with a half-million process executions per build",
where a clean build is hopeless and an incremental build must be _provably_ correct. Legacy
languages second: MSBuild project-level edges, CMake/Ninja target-level edges, JavaScript task
graphs — all under-declared. BuildXL wraps those graphs rather than replacing them.

The motive is in [`WhyBuildXL.md`][why]: in 2016, Office-client forks took about 90 hours to
build and release to dogfood, because the wrappers "were not meant to be distributed across
machines".

### Design philosophy

A _declared_ dependency set is a hypothesis; a _syscall_ is a fact. The sandbox is not a
safety feature bolted onto a scheduler — it is the source of truth for what a pip read:

> "BuildXL relies on runtime file-access monitoring for correct caching and distribution."
>
> — [`Documentation/Wiki/CoreConcepts.md`][core-concepts]

Where declaration and observation disagree the engine does not guess: an undeclared read is
a `file-access violation` error and makes the pip uncacheable, and undeclared writes are
classified after the fact by [`FileMonitoringViolationAnalyzer`][violation] as
`DoubleWrite`, `ReadRace`, `UndeclaredOrderedRead`, `MissingSourceDependency`,
`UndeclaredReadCycle`, `UndeclaredOutput` or `ReadUndeclaredOutput`. Correctness is
_enforced_, not argued: DScript "typically leads to a build break on incorrect inputs to
force improvements to input predictions", while MSBuild and CMake "rely much more on
two-phase caching for correctness" ([`WhyBuildXL.md`][why]).

## How it works

### Two phases, and two cached artifacts

The pip graph is complete before anything runs. Frontends evaluate DScript, call the MSBuild
static-graph API, or adapt a JavaScript orchestrator's graph; a pip _Q_ depends on _P_ when
_P_'s declared output is _Q_'s declared input.

A pip is a _Primitive Indivisible Process_: `process` (a sandboxed process tree, the only
kind that costs measurement), `write-file`/`copy-file` (no process launched),
`seal-directory` (freezes a directory's membership and gives readers an edge to it), and
`service`/`IPC`. Three sealing strengths exist — source, exclusive _opaque_, and _shared
opaque_, which lets several pips contribute undeclared files, at the price of scrubbing its
content before every build and of "marked perpetually dirty" producers
([`Shared-Opaque-Directories.md`][shared-opaque]).

Both the graph and its inputs are cached. The graph's key, the _pip graph weak fingerprint_,
hashes the config file, qualifiers, evaluation filters, source/object/temp layout, subst
target, engine commit and host OS/architecture; its dependency set is the spec files,
enumerated directory memberships, queried environment variables and mounts, with USN records
avoiding re-hashes of unchanged specs. The engine cache (one graph, cheap) is checked before
the real cache (many graphs) ([`Graph-Reuse.md`][graph-reuse]) — which is why a
`Environment.getStringValue("BUILD_ID")` call is expensive.

### The scheduler is a ready-set over a static DAG

Not a topological sort executed in order: ready pips enter per-kind priority queues
([`PipQueue.cs`][pip-queue], driven from [`Scheduler.cs`][scheduler]), and each walks a
fixed step pipeline enumerated in [`PipExecutionStep.cs`][pip-step]:

```text
Start -> CheckIncrementalSkip -> [DelayedCacheLookup] -> CacheLookup
      -> RunFromCache | MaterializeInputs -> ExecuteProcess -> PostProcess
      -> HandleResult -> [MaterializeOutputs] -> Done
```

Three details are industrial rather than academic:

- **Priority is predicted critical path.** Each pip's runtime is estimated from its
  declared input/output count or recorded history, summed with everything downstream,
  and used as priority; history is serialized _and pushed to the cache_, so a shared
  datacenter cache lends runtimes across machines ([`Scheduler-Prioritization.md`][sched-prio]).
- **Weight, not just slot count.** A pip declares a `weight` in units of `/maxproc` slots —
  statically or from historical CPU-time over wall time — so one 32-core link does not
  starve thirty compilations ([`Pip-Weight.md`][pip-weight]).
- **Lookups are throttled.** `/delayCacheLookupMin` and `/delayCacheLookupMax` (defaults 1
  and 2) bound the queue depth between lookup and execution, so the engine cannot run so far
  ahead of its workers that a concurrent build caches the same pips first
  ([`Cache-Convergence.md`][convergence]). The store-side twin is _convergence_: on a
  conflicting entry from another build, a pip may adopt the stored result (`DX2728`).

### The sandbox is the input oracle

| Platform | Mechanism                                                                                        | Cost as stated                                               |
| -------- | ------------------------------------------------------------------------------------------------ | ------------------------------------------------------------ |
| Windows  | hardened [Detours][detours]: user-mode API hooks at start                                        | "adds 1-5% of time overhead" ([`Sandboxing.md`][sandboxing]) |
| Linux    | `LD_PRELOAD` interposition of libc wrappers; `ptrace` + `seccomp` for statically linked binaries | not stated in the clone                                      |
| Linux    | eBPF, rolling out, intended to replace interposition                                             | not stated in the clone                                      |

The `ptrace` path has a precise justification: "The ptrace based sandbox exists due the
Linux function interpose based sandbox not being able to detect file accesses from binaries
that statically link libc" ([`PTraceSandbox.md`][ptrace]). eBPF answers the same gap one
layer lower: `io_uring` has no libc wrapper to interpose, so only the kernel sees a direct
syscall ([`Sandboxing.md`][sandboxing]).

What the sandbox reports is not just reads: five kinds, and the distinctions are
load-bearing ([`ObservedInput.cs`][obs-input]) — `FileContentRead`, `DirectoryEnumeration`,
`ExistingFileProbe`, `ExistingDirectoryProbe`, `AbsentPathProbe`. Recording _absent_ probes
is the subtle half: a compiler's search path is a set of negative facts, and if
`include2/foo.h` starts existing the build must change — only a recorded miss sees that.

### Observed inputs become a cache key: weak, pathset, strong

A static specification is too weak a key, and an observed set is too expensive to compute
without running, so the key has three levels:

1. **Weak fingerprint** — hashes of everything statically declared: command line,
   declared input/output paths and their content hashes, working directory,
   environment.
2. **Pathset** — paths a _previous_ execution touched. Crucially, "pathsets list only
   pathname hits (or misses, as we'll see soon), not actual file hashes or even file
   versions" ([`Two-Phase-Cache-Lookup.md`][two-phase]); matching one costs only
   existence checks.
3. **Strong fingerprint** — weak fingerprint plus content hashes of the files the
   matching pathset names.

Lookup is a search, not a comparison: fetch every pathset under the weak fingerprint, keep
those whose hit/miss pattern still matches the filesystem, and compute strong fingerprints
until one resolves; then fetch the output content list from the CAS. This generalises a
verifying trace — the trace's dependency list is the pathset — and permits a _family_ of
traces per pip rather than one.

The pathological case is documented and mitigated: when a weak fingerprint is too weak (many
pips, few declared inputs, shared reads) candidate pathsets explode, so BuildXL cascades the
entry under an augmented weak fingerprint derived from the common paths of the first `n`
pathsets. `/pathSetThreshold` (default 5) and `/augmentingPathSetCommonalityFactor` (default
0.4) tune it; augmentation is on by default for the JavaScript, MSBuild and CMake/Ninja
resolvers.

### Incremental scheduling prunes the graph before any fingerprint is computed

Even a lookup per pip costs something at half a million pips, so an optional layer above the
cache removes pips that provably cannot have changed:

> "Incremental scheduling in BuildXL is a feature that allows BuildXL to avoid processing
> pips based on the filesystem's change (or USN) journal records tracked from the previous
> builds."
>
> — [`Incremental-Scheduling.md`][incremental]

It is off by default (`/incrementalScheduling+`). [`DirtyNodeTracker.cs`][dirty] holds a
dirty set, a _perpetual_ dirty set and a _materialized_ set, with the invariant that marking
a node dirty marks every transitive dependent dirty — a transitively closed dirty bit, the
safe over-approximation. Two markers per pip, not one, because lazy output materialization
can leave a pip clean with only its content hash recorded; re-selecting it later must not
assume the bytes are on disk. Clean pips are stored with the _version_ at which they became
clean, so a graph change that renumbers pips does not resurrect stale cleanliness
([`GraphAgnosticIncrementalSchedulingState.cs`][graph-state]). The incompatibility table is
the honest part — where a dirty bit is unsound: distributed builds (a peer cache cannot be
assumed to hold an intermediate another machine needs), the uncacheable allowlist,
anti-dependencies, lazy outputs, shared opaque directories, unflushed page cache, drops.

### Service pips: long-lived processes at the graph's edge

BuildXL's ordinary process contract is short-lived, atomic, and well-defined
(SLAWD). Service pips are the explicit escape hatch for background uploaders
and compiler servers: a long-lived service starts once, and small IPC pips
delegate operations to it during the build. The service documentation is
blunt about what had to be given up ([`Service-Pips.md`][service-pips]):

- a client pip may depend on the service having started;
- incremental widening of a service's input/output permissions after each
  operation was **not implemented**;
- depending on outputs produced in the middle of a service's lifetime was
  **also never implemented**;
- service pips are monitored but all file accesses are allowed — "service
  pips are trusted with respect to their input specification" — and they are
  never cached;
- in a distributed build, a service pip is started on **every** worker,
  unlike an ordinary pip assigned to one dynamically chosen worker.

That makes service pips closer to Bazel persistent workers than to cached
actions. The correctness burden moves from the engine's fingerprint proof to
the service client contract: IPC operations must be deterministic functions
of the client pip's declared inputs even though the service process may batch,
authenticate, retry, and retain state across many pips.

### Cache convergence and delayed lookup: correctness under concurrent builders

A shared cache is not only read; concurrent builds race to populate it.
BuildXL's cache-convergence behaviour lets a losing build adopt the result
already stored under the same strong fingerprint instead of keeping its own
possibly non-deterministic output, allowing downstream pips to rejoin the
winning build's cache lineage ([`Cache-Convergence.md`][convergence]).
The build logs both converged-entry count and wasted execution time
(`ProcessPipTwoPhaseCacheEntriesConverged`,
`ExecuteConvergedProcessDurationMs`).

Delayed cache lookup attacks the same race earlier. The scheduler throttles
how far lookups run ahead of execution slots (multipliers default to 1–2
times aggregate slots) so a pip is less likely to be declared a miss, wait in
a queue for tens of minutes, and then duplicate work another build cached in
the interval. Together these features treat the cache as a concurrent
distributed system with races and convergence rules, not as a passive
key/value store — a materially richer model than a local action-cache lookup.

### Distribution is BuildXL's own protocol, not REAPI

An orchestrator constructs the graph and schedules; workers execute. A worker starts knowing
nothing, receives an attach request carrying hashes of the graph files, pulls them from the
cache, then waits for per-step requests. Only `IPC` and process pips are distributed, and of
their steps only `CacheLookup`, `MaterializeInputs`, `ExecuteProcess` and `PostProcess`,
which "must happen on the same worker for the same pip to ensure cache convergence"
([`Distributed-Builds.md`][dist]). Transport is gRPC over [`Interfaces.proto`][dist-proto];
lost workers are retried via `/numRetryFailedPipsOnAnotherWorker`. There is no REAPI client
— a tree-wide grep of `*.cs`, `*.proto` and `*.md` for `REAPI` finds nothing — and there are
"no public versions of the dev or datacenter caches" ([`WhyBuildXL.md`][why]).

## Analysis spine

**Topological × verifying traces** — the `Ninja` cell of [concepts]'s Table 2: a static pip
graph run by a ready-set queue, with a previous run's pathset supplying the verifying trace's
dependency list. Three deviations: that list is _observed_, not extracted; there is a
_family_ of traces per weak fingerprint, searched rather than compared one-to-one; and a
dirty-bit layer above the lookup prunes the graph before any fingerprint is computed. It does
not fit a _dynamic-dependency_ cell, because an undeclared read is an error to fix, not a
dependency to follow — and the experimental `unsafe_EnableDynamicGraph` mode, which admits
pips "while graph-producing frontends are still publishing the graph", shows the price:
distribution, incremental scheduling, graph caching, scrubbing and observed-input anomaly
analysis all rejected or degraded ([`DynamicGraphWorkingNotes.md`][dynamic-graph]).

### 1. Task model & scheduling

A pip is a process, a file write, a copy, a directory seal, or a service/IPC pair.
Dependencies are static, derived from declared artifact flow. Execution is a ready-set over
that DAG with critical-path priority, weights as concurrency credits, and a step pipeline
pre-emptible at step boundaries. Speculation exists only as priority and lookahead
throttling.

### 2. Rebuilding & correctness

Two layers. Incremental scheduling is transitive closure over USN records — safe, coarse,
no early cutoff. Cache lookup is a verifying trace over content hashes — fine, effectively
minimal, and it _does_ yield early cutoff: byte-identical output leaves dependents' strong
fingerprints matching, so they hit the cache. Correctness is not proved but enforced, by
refusing to cache a pip whose observations exceeded its declarations.

### 3. Dependency discovery

Hybrid by construction, and the design's centre. Declarations exist and are checked; sandbox
observations fill the gaps _for the next build's key_. Missing declarations produce
violations with a taxonomy rather than silence — the opposite stance to tracing-first
systems, where observation replaces declaration instead of validating it.

### 4. Store & caching

A separable subsystem: a content store (CAS) and a memoization store (fingerprint →
content list). Blobs are identified by a paged hash — 2 MB blocks, 64 KB pages,
hash-of-hashes, "VSO-Hash" — so a cloud API can validate and de-duplicate segments in
transit ([`Cache/README.md`][cache-readme], [`PagedHash.md`][paged-hash]). The CAS supports
`Pin` to reserve a blob without fetching it; local stores hard-link, and distributed tiers
are Azure DevOps (internal APIs) or Azure blob storage.

### 5. Hermeticity & provenance

Hermeticity is the product, with measured cost on Windows (1–5%) and unstated cost on
Linux. Enforcement is layered: untracked paths, two allowlist kinds
(`cacheableFileAccessAllowlist` ignores and caches; `fileAccessAllowlist` ignores but
poisons the cache), and _observation reclassification_, choosing a file-system view so
absent-then-present outputs do not thrash fingerprints
([`Observation-Reclassification.md`][obs-reclass]). Provenance in the SLSA/in-toto sense is
**absent**: a rich execution log, but no attestation machinery — neither term appears in the tree.

### 6. Distribution

Orchestrator/worker over its own gRPC protocol, a shared CAS as data plane, per-step remote
execution, retry on worker loss. No REAPI, hence no interop with the Bazel/Buck2/Pants
ecosystem, and the design optimises for a homogeneous fleet.

### 7. Sparkles relevance

`sparkles.build_primitives.task` is a validated static DAG with a single-pass executor and
no memory of a previous run. What ports is not the sandbox — a D toolchain cannot pay a
`ptrace` tax — but the _fingerprint arithmetic_: a cheap static key fanning out to candidate
dynamic keys, each checked before any hashing, collapsing to the static key when there are
no observations. Two borrowings are cheap and high-value: track _absent probes_ alongside
reads (a glob matching nothing is a dependency on emptiness), and distinguish _clean_ from
_clean and materialized_ so an interrupted run is not mistaken for a complete one. The rest —
transitive dirty closure, graph-as-cache-entry, the violation taxonomy — deserves measurement
before adoption.

## Strengths

- **The strongest answer to under-declared inputs.** Checking declarations against
  observations, and grading the disagreements, beats trusting declarations or never
  checking them.
- **A real cache abstraction.** CAS plus memoization store, paged hashing, `Pin`,
  TTL/LRU and a documented degradation path make the store a component, not a side
  effect; the operational details around it — critical-path priority from recorded
  runtimes, weights, delayed lookup, convergence, incompatibility tables — are written
  only by people who have been paged at 3 a.m.

## Weaknesses

- **Windows-first assumptions leak.** USN-based incremental scheduling, the 1–5%
  figure and the datacenter tiers originate on Windows; the Linux sandboxes are
  described as catching up (eBPF).
- **No public distribution, and two sets of semantics.** Distribution and the
  datacenter cache are internal products; strict and loose frontends give different
  guarantees, so "BuildXL builds it correctly" is not portable. Enforcement also costs
  developer time — right at Microsoft's scale, poor for a small project.

## Key design decisions and trade-offs

| Decision                                   | Rationale                                                                 | Trade-off                                                                     |
| ------------------------------------------ | ------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| Observe accesses, never trust declarations | Legacy languages cannot be fixed; a wrong dependency set is a wrong build | Sandbox overhead plus a fragile syscall surface (`io_uring`, static binaries) |
| Undeclared access is an error, not an edge | Keeps the graph static and the schedule computable up front               | Every legitimate new read is a build break someone must declare               |
| Weak → pathset → strong fingerprint        | A cheap static key narrows to few dynamic candidates before hashing       | Pathset explosion, cured by a heuristic with two knobs                        |
| Pathsets store paths, not hashes           | Matching is existence checks; hashing only for surviving candidates       | A structural match may still require a full rehash                            |
| Dirty bit above the trace lookup           | Half a million pips cannot each afford a lookup                           | Coarse, no early cutoff, unsound for distributed/opaque/drop features         |
| Clean vs clean-and-materialized markers    | Lazy materialization is a real state the engine must not misread          | More persisted state, and perpetual dirtiness for what cannot be narrowed     |
| Cache the pip graph itself                 | Graph construction costs minutes on a large repo                          | One changing env var or log path invalidates the whole graph cache            |
| Own gRPC distribution over a shared CAS    | Controls scheduling granularity and convergence semantics                 | No REAPI interop; unusable outside Microsoft's fleet                          |
| DScript as the strict frontend             | Precise declarations make caching and distribution sound                  | A new language, and the ecosystem's tools do not speak it                     |

## Sources

- [`microsoft/BuildXL`][repo] at commit `ea34998661867b5959d7f496f8b5650611a3e446`
  (clone at `$REPOS/build-systems-research/src/buildxl`; HEAD dated 2026-10-31).
  Every quote is verbatim from the files cited inline, opened at that SHA.
- Architecture: [`README.md`][readme], [`Documentation/INDEX.md`][doc-index],
  [`CoreConcepts.md`][core-concepts], [`WhyBuildXL.md`][why].
- Pipeline and sandboxing: [`PipExecutionStep.cs`][pip-step], [`Sandboxing.md`][sandboxing],
  [`PTraceSandbox.md`][ptrace], [`ObservedInput.cs`][obs-input].
- Caching, scheduling and incrementality: [`Cache/README.md`][cache-readme],
  [`Two-Phase-Cache-Lookup.md`][two-phase], [`PagedHash.md`][paged-hash],
  [`Graph-Reuse.md`][graph-reuse], [`Cache-Convergence.md`][convergence],
  [`Observation-Reclassification.md`][obs-reclass], [`Incremental-Scheduling.md`][incremental],
  [`Scheduler-Prioritization.md`][sched-prio], [`Pip-Weight.md`][pip-weight],
  [`DirtyNodeTracker.cs`][dirty], [`GraphAgnosticIncrementalSchedulingState.cs`][graph-state],
  [`DynamicGraphWorkingNotes.md`][dynamic-graph].
- Validation and distribution: [`FileMonitoringViolationAnalyzer.cs`][violation],
  [`Shared-Opaque-Directories.md`][shared-opaque], [`Distributed-Builds.md`][dist],
  [`Interfaces.proto`][dist-proto].
- Sibling pages: [concepts] for the vocabulary and Table 2 placement, [a-la-carte] for the
  scheduler/rebuilder grid, [perfect-dependencies] for Rattle's tracing-and-validation stance.

<!-- References -->

[repo]: https://github.com/microsoft/BuildXL
[readme]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/README.md
[doc-index]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Documentation/INDEX.md
[core-concepts]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Documentation/Wiki/CoreConcepts.md
[why]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Documentation/Wiki/WhyBuildXL.md
[sandboxing]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Documentation/Specs/Sandboxing.md
[ptrace]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Documentation/Wiki/LinuxDevelopment/PTraceSandbox.md
[two-phase]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Documentation/Wiki/Advanced-Features/Two-Phase-Cache-Lookup.md
[incremental]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Documentation/Wiki/Advanced-Features/Incremental-Scheduling.md
[graph-reuse]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Documentation/Wiki/Advanced-Features/Graph-Reuse.md
[convergence]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Documentation/Wiki/Advanced-Features/Cache-Convergence.md
[sched-prio]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Documentation/Wiki/Advanced-Features/Scheduler-Prioritization.md
[pip-weight]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Documentation/Wiki/Advanced-Features/Pip-Weight.md
[obs-reclass]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Documentation/Wiki/Advanced-Features/Observation-Reclassification.md
[shared-opaque]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Documentation/Wiki/Advanced-Features/Sealed-Directories/Shared-Opaque-Directories.md
[dist]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Documentation/Wiki/Distributed-Builds.md
[dynamic-graph]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/DynamicGraphWorkingNotes.md
[cache-readme]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Public/Src/Cache/README.md
[paged-hash]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Documentation/Specs/PagedHash.md
[service-pips]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Documentation/Wiki/Service-Pips.md
[pip-step]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Public/Src/Engine/Scheduler/PipExecutionStep.cs
[pip-queue]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Public/Src/Engine/Scheduler/PipQueue.cs
[scheduler]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Public/Src/Engine/Scheduler/Scheduler.cs
[obs-input]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Public/Src/Engine/Scheduler/Fingerprints/ObservedInput.cs
[violation]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Public/Src/Engine/Scheduler/FileMonitoringViolationAnalyzer.cs
[dirty]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Public/Src/Engine/Scheduler/DirtyNodeTracker.cs
[graph-state]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Public/Src/Engine/Scheduler/IncrementalScheduling/GraphAgnosticIncrementalSchedulingState.cs
[dist-proto]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Public/Src/Engine/Distribution.Grpc/Interfaces.proto
[detours]: https://github.com/microsoft/Detours
[concepts]: ./concepts.md
[a-la-carte]: ./a-la-carte.md
[perfect-dependencies]: ./perfect-dependencies.md
