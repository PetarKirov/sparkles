---
status: draft
owner: sparkles:build-primitives
reviewed: 2026-11-06
---

# Build, test and CI performance observability — Specification

## Abstract

`sparkles:build-primitives` and `apps/ci` measure every build, test and CI run
they perform, with no extra step. Each compile, archive, link, generator and
test action reports its time, CPU, memory, page faults, I/O, stall time,
hardware counters and build-cache outcome. Compiles also report where the
compiler spent its time, and tests their own memory and garbage collection.
Each run is kept as a small, schema-versioned record that names no person. CI
and developers share records through a data-only ref of the repository that
ordinary clones never fetch, so any checkout can show a run, compare two runs
and chart a task's history. The regression gate reads instructions retired
where the host counts them, and user CPU time with a wider threshold on hosted
CI runners that cannot; it never compares one with the other.

## Introduction

A Sparkles CI run compiles and tests dozens of packages, verifies hundreds of
documentation examples, and runs on three operating systems. When it gets
slower, the questions are always the same. Which step got slower: a compile, a
link or a test? Did the work grow, or did it wait for a CPU, for the disk or
for a cache that missed? Did a commit change the code, the toolchain, or only
the machine it ran on? Without measurement built into the tools, each answer
is an ad hoc script: a timing loop around `dub test`, a parser for a compiler
trace, a spreadsheet of CI step durations. Each script measures once and is
thrown away, so no question can be asked of last month.

Several things make these questions hard to answer by default. Measurement
costs something: a DMD time trace at its default granularity made one test
build take 21 s instead of 12.6 s and wrote 1.3 GB. The useful counters differ
by operating system and often need privileges, and a missing counter that
reads as zero is worse than no counter. Wall time on a shared or virtual
machine can vary by more than ten percent between identical runs, so a gate on
it either fires on noise or misses real regressions. And numbers from
different machines, toolchains or cache states are not comparable unless the
record says which they came from.

This specification makes measurement part of the machinery that already runs
the work. A _run_ is one `ci` command executing a graph of _tasks_; a task
whose work is one tool invocation is an _action_: a compile, an archive, a
link, a generator that writes source files, or a test binary's run. The
[task DAG](../task-dag/SPEC.md) executes tasks, and each process it starts
runs under [Event Horizon](../../event-horizon/SPEC.md#_13-5-supervised-runs-m19)'s
supervision, which accounts for the whole process tree. The
[build graph](../build-graph/SPEC.md) turns builds into actions and reuses
their results from a content-addressed store; it reports each lookup's
outcome and asks the compiler and linker for compact summaries of their own
work. The [test runner](../../test-runner/SPEC.md)'s core reports each test.
All of them speak one metric vocabulary, in which every value carries its unit
and its quality: exact, a lower bound, an estimate, or absent with a reason.
A run's measurements become a [run record](../../../glossary.md#run-record),
keyed so that the same task lines up across runs and machines. Records travel
through a data-only ref of this repository, `refs/perf/data`, appended by CI
and pushed explicitly by developers. A comparison gates on user-mode
instructions retired where the host counts them, and on user CPU time on hosted
CI runners that cannot, never mixing the two, between samples whose
[comparability key](../../../glossary.md#comparability-key) matches, against a
noise threshold estimated from repeated executions of identical inputs.

The specification owns the metric set, the overhead budget, the record format,
the history ref, privacy, comparison and the gate, and the `ci perf`
commands. It does not own how work is scheduled, built or tested; the task
DAG, the build graph and the test runner keep those contracts and link here
for their observation obligations. The test runner's `--bench` mode, which
measures individual test bodies with statistical repetition, is a separate
measurement model; it shares this vocabulary, and its results do not enter run
records. Sampling profilers, per-function hardware counters, dashboards
outside the repository and alerting are out of scope. So is a long-term store
other than `refs/perf/data`, for the reasons
[decisions.md](./decisions.md#od19-history-lives-on-refs-perf-data-accepted)
records.

Section 1 states the invariants and §2 the owners. Section 3 defines the
metric vocabulary. Sections 4–9 define the metrics, by scope: every action,
compiles, links and archives, tests, runs and CI jobs. Section 10 sets the
overhead budget. Sections 11–13 define the run record, the `refs/perf/data` history
and the privacy rules, §14 comparison and the regression gate, §15 the
`ci perf` commands and §16 how reporters show metrics. Delivery order lives in
[PLAN.md](./PLAN.md), oracles, spikes and evidence in [testing.md](./testing.md),
and the choices behind each section in [decisions.md](./decisions.md).

## 1. Invariants

1. **Observation never changes a verdict.** Task outcomes, the primary cause,
   exit statuses and the plain transcript with timings off are the same
   whether observation succeeds, fails or is off. A failed or unavailable
   measurement is reported, never turned into a task outcome. Only
   `ci perf compare --gate` turns measurements into an exit status.
2. **No value without its quality.** Every recorded value is exact, a lower
   bound or an estimate, and says which. A metric that could not be measured is
   absent, with a reason. Nothing unmeasured is recorded as zero.
3. **Measurements are never outputs.** No measurement is part of an action's
   outputs, is read by a dependent action, or enters a key. A family that needs
   a compiler or linker flag is part of the action's argument vector, so
   results are reused only between runs with the same such families on.
4. **Bounded cost.** The families on by default fit the overhead budget of §10,
   measured per compiler. A family that does not fit is off by default.
5. **Records name no person.** A record holds no username, real name, email
   address, hostname or absolute path outside the Nix store, and no text copied
   from tool output except identifiers derived from the repository's sources:
   module, template, symbol, test and file names.
6. **One vocabulary.** The build graph, the task DAG, Event Horizon, the test
   runner and `ci perf` name metrics and qualities through one package. No
   component keeps a private copy of a metric's identity, unit or quality.

## 2. Ownership

| Obligation                                                           | Owner                       | Sections   |
| -------------------------------------------------------------------- | --------------------------- | ---------- |
| Metric identities, units, qualities, absence reasons, the catalog    | `sparkles:metrics`          | §3         |
| Process-tree accounting at exit, counters attached before `exec`     | `sparkles:event-horizon`    | §4         |
| Queue wait, the measurement table, the run metrics of §8's table     | `sparkles:build-primitives` | §4, §8     |
| Cache, compile, link and archive metrics; measurement side outputs   | `sparkles:build-primitives` | §4–§6, §11 |
| Per-test usage in the runner protocol                                | `sparkles:test-runner`      | §7         |
| §8's facts, CI job metrics, records, history, privacy, gate, reports | `apps/ci`                   | §8–§16     |

`sparkles:metrics` depends only on `sparkles:metadata`, which depends on
nothing. The test runner's harness, the package of its process model that runs
inside every test binary, `sparkles:event-horizon`,
`sparkles:build-primitives` and `apps/ci` depend on `sparkles:metrics`. It
performs no I/O.

## 3. The metric vocabulary

**OBV1: One vocabulary package.** Every metric that a run record, a report or
the test runner's `--bench` catalog names **must** be declared in
`sparkles:metrics`. The test runner's catalog types (`MetricClass`,
`MetricFormat`, `MetricCell` and `MetricDescriptor`) **must** be declared there
and used from there, with `MetricCell` carrying a quality (OBV7) in place of
an estimate flag. No other package declares a metric's identity, unit or
quality.

_Rationale:_ a metric defined twice drifts: one copy renames it, rescales it or
changes what its quality means, and records stop lining up with reports.

**OBV2: A dependency-free leaf.** `sparkles:metrics` **must** depend on no
repository package other than `sparkles:metadata`, and **must** test itself
without the test-runner shim, as the test runner's harness does. Because the
harness uses it, the test runner's in-binary dependency rule (TRP1 of its
process model) **must** admit these two packages before the harness depends on
them.

**OBV3: Two kinds of metric.** A descriptor **must** say whether its metric is
_recorded_ or _derived_:

- a **recorded** metric is a measured value that a run record stores, under
  the rules OBV4–OBV7 state;
- a **derived** metric is computed for display from recorded or `--bench`
  values: a ratio, a rate, a percentage or a per-iteration figure. It is never
  stored in a run record, and its identity and rendering follow the test
  runner's catalog contract, which keeps `--bench`'s existing names stable.

**OBV4: Metric identity.** A recorded metric **must** be identified by a
stable **metric id**: lowercase ASCII segments separated by `.`, each made of
letters, digits and single hyphens, such as `task.cpu.user`. An id **must
not** be renamed, reused, or given a new definition, unit or scope. A changed
definition is a new id.

**OBV5: Descriptors.** Every recorded metric **must** have a descriptor
stating:

- its definition, in one sentence;
- its unit: `ns`, `bytes`, `count`, `instructions`, `cycles`, `boolean`, or
  `enum` with the enum's values;
- its scope: `task`, `compile`, `object`, `link`, `archive`, `test`, `binary`,
  `run` or `ci-job`;
- its [metric class](../../../glossary.md#metric-class), `quantitative` or
  `diagnostic`, as the test runner defines it;
- its family (OBO3);
- its source and quality per platform, as the catalogs below state.

**OBV6: Integer values.** A recorded value **must** be a non-negative integer
in its descriptor's unit. Durations are nanoseconds. A source with a coarser
resolution, such as whole seconds, reports a multiple of its resolution, and
its descriptor states the resolution.

**OBV7: Quality.** Every recorded value **must** carry one
[metric quality](../../../glossary.md#metric-quality):

- **exact:** the value is the truth about the metric's definition;
- **lower bound:** the true value is at least this, because a sampler, a
  budget, or a boundary that part of the work can leave missed some of it;
- **estimate:** the source scaled a partial count, such as a multiplexed
  hardware counter.

**OBV8: Absence.** A metric that a source cannot produce **must** be absent
from the record, with a [reported absence](../../../glossary.md#reported-absence):
the metric id, the scope it applies to, and a reason drawn from a closed set:

| Reason       | Meaning                                                                   |
| ------------ | ------------------------------------------------------------------------- |
| `platform`   | the platform has no source for it                                         |
| `privilege`  | the source exists and refused this process                                |
| `no-pmu`     | the host exposes no hardware counters, as in many virtual machines        |
| `kernel`     | the kernel lacks the interface, or it is disabled                         |
| `tier`       | the run's containment tier lacks the file (a cgroup without a controller) |
| `format`     | no reader for the object format or linker                                 |
| `toolchain`  | the compiler or linker cannot report it                                   |
| `family-off` | its family is off                                                         |
| `protocol`   | the worker's protocol does not carry it                                   |
| `failed`     | the source failed while reading                                           |

An absence **may** carry a detail, such as the `perf_event_paranoid` value,
that names no person. A counter that reports zero work where other evidence
shows work happened, such as zero cycles beside non-zero CPU time, **must** be
treated as absent with reason `failed`.

**OBV9: Event Horizon's quality is the vocabulary's.** Event Horizon's
`MetricQuality` **must** be replaced by the vocabulary's quality type. A value
Event Horizon could not measure is reported absent with the reason its probe
gave.

In the catalogs below, a source cell names the source and its quality: **E**
exact, **L** lower bound, **~** estimate, and **—** absent with reason
`platform`, `format` or `toolchain`. Where the quality depends on the host,
the cell names the condition.

## 4. Action metrics

These metrics apply to every action that runs as a supervised process tree:
every build-graph action, and every process task a `ci` command plans. The
cache family applies to build-graph actions only.

**OBA1: Read at the root's exit.** Process-tree accounting **must** be read
after the root process has exited and before it is reaped, so that nothing the
root did is lost:

- **Linux:** the run cgroup's files and the root's `/proc/<pid>/io` while the
  root is a zombie, then the root's resource usage as its reaping returns it;
- **macOS:** `proc_pid_rusage` with `RUSAGE_INFO_V4` while the root is a
  zombie, then the resource usage `wait4` returns;
- **Windows:** the run's Job Object accounting, and the root process's cycle
  time and memory counters, before its handle closes.

**OBA2: Counters from the first instruction.** On Linux, hardware counters
**must** be opened for the child in user mode only, inherited by its
descendants, and enabled by its `exec`, before it executes the target program.
A spawn path that cannot do that, because the child cannot be held before
`exec`, **must** report the counters as lower bounds. One such path is a
trampoline that opens the counters on itself, passes them to the supervisor,
and then executes the target.

**OBA3: Privilege is probed, not assumed.** A counter refused for privilege,
such as `perf_event_paranoid` above 2 on Linux, or absent because the host has
no PMU, **must** be reported as an absence with that reason, probed once per
run, and **must not** fail the action.

**OBA4: Queue wait.** `task.queue` **must** be measured from the executor's
`TaskReady` event to its `TaskStarted` event for the same task, on the
executor's clock ([TDM12](../task-dag/SPEC.md#_3-5-events)).

**OBA5: The measurement table.** The executor **must** own one fixed-size
measurement block per planned task, filled from the task's observation when
its action ends. When the run ends, ownership of the table **must** pass to the
command, which writes the record and hands the table to the reporters' final
summaries. Variable-size measurements, such as a compile's top template
instances, **must** be written to the action's measurement directory (OBD8)
and collected into the record when the run ends.

_Rationale:_ events hold no pointers
([T7](../task-dag/decisions.md#t7-events-hold-no-pointers)), and a
measurement block in every event would enlarge every event. Live reporters
need only the running tasks' memory and CPU, which `TaskUsage` already carries.

| ID                       | Definition                                                  | Unit         | Linux                                                                             | macOS                              | Windows                               | Overhead            |
| ------------------------ | ----------------------------------------------------------- | ------------ | --------------------------------------------------------------------------------- | ---------------------------------- | ------------------------------------- | ------------------- |
| `task.wall`              | `TaskStarted` to `TaskFinished`                             | ns           | executor clock, E                                                                 | E                                  | E                                     | none                |
| `task.queue`             | `TaskReady` to `TaskStarted`                                | ns           | executor clock, E                                                                 | E                                  | E                                     | none                |
| `task.cpu.user`          | user CPU time of the process tree                           | ns           | reap usage, L; cgroup `cpu.stat`, E when the child starts in the cgroup           | reap usage, L                      | job accounting, E                     | one read            |
| `task.cpu.sys`           | system CPU time of the process tree                         | ns           | as `task.cpu.user`                                                                | reap usage, L                      | job accounting, E                     | one read            |
| `task.rss.process`       | largest resident set of any single process of the tree      | bytes        | reap usage `ru_maxrss`, L                                                         | reap usage, L                      | root's peak working set, L            | none                |
| `task.rss.tree`          | largest sampled sum of the tree's resident sets             | bytes        | tree sampler, L                                                                   | tree sampler, L                    | tree sampler, L                       | one sample per tick |
| `task.mem.cgroup`        | peak memory of the run cgroup, page cache included          | bytes        | `memory.peak`, accounted tier, E                                                  | —                                  | —                                     | one read            |
| `task.mem.commit`        | peak committed memory of the job                            | bytes        | —                                                                                 | —                                  | job peak memory used, E               | one read            |
| `task.faults.minor`      | page faults served without I/O                              | count        | `memory.stat` `pgfault` minus `pgmajfault`, accounted tier, L; else reap usage, L | reap usage, L                      | —                                     | one read            |
| `task.faults.major`      | page faults that needed I/O                                 | count        | `memory.stat` `pgmajfault`, accounted tier, L; else reap usage, L                 | reap usage, L                      | —                                     | one read            |
| `task.faults.all`        | every page fault, soft and hard                             | count        | —                                                                                 | —                                  | job page-fault count, E               | one read            |
| `task.ctxsw.voluntary`   | voluntary context switches                                  | count        | reap usage, L                                                                     | reap usage, L                      | —                                     | none                |
| `task.ctxsw.involuntary` | involuntary context switches                                | count        | reap usage, L                                                                     | reap usage, L                      | —                                     | none                |
| `task.instructions`      | user-mode instructions retired by the tree                  | instructions | `perf_event_open`, inherited, E per OBA2; ~ when multiplexed                      | —                                  | —                                     | one counter group   |
| `task.cycles`            | user-mode core cycles of the tree                           | cycles       | as `task.instructions`                                                            | —                                  | —                                     | same group          |
| `task.instructions.all`  | instructions retired in user and kernel mode by the root    | instructions | —                                                                                 | `ri_instructions`, L               | —                                     | one call            |
| `task.cycles.all`        | core cycles in user and kernel mode of the root             | cycles       | —                                                                                 | `ri_cycles`, L                     | —                                     | same call           |
| `task.cycles.reference`  | CPU cycles as the platform's process cycle time counts them | cycles       | —                                                                                 | —                                  | `QueryProcessCycleTime`, root only, L | one call            |
| `task.io.read`           | bytes the tree caused to be read from storage               | bytes        | `io.stat` `rbytes`, io controller, E; else root's `read_bytes`, L                 | root's `ri_diskio_bytesread`, L    | —                                     | one read            |
| `task.io.write`          | bytes the tree caused to be written to storage              | bytes        | `io.stat` `wbytes`, L; else root's `write_bytes`, L                               | root's `ri_diskio_byteswritten`, L | —                                     | one read            |
| `task.io.read-calls`     | bytes passed through read calls, any file type              | bytes        | root's `rchar`, L                                                                 | —                                  | job read transfer count, E            | one read            |
| `task.io.write-calls`    | bytes passed through write calls, any file type             | bytes        | root's `wchar`, L                                                                 | —                                  | job write transfer count, E           | one read            |
| `task.stall.cpu`         | time some task of the run cgroup waited for a CPU           | ns           | `cpu.pressure` `some total`, owned tier, E                                        | —                                  | —                                     | two reads           |
| `task.stall.memory`      | time some task of the run cgroup stalled on memory          | ns           | `memory.pressure` `some total`, owned tier, E                                     | —                                  | —                                     | two reads           |
| `task.stall.io`          | time some task of the run cgroup stalled on I/O             | ns           | `io.pressure` `some total`, owned tier, E                                         | —                                  | —                                     | two reads           |

The sources' bounds have these causes:

- **Reap usage** is the resource usage the reaping call returns for the root
  and every descendant the tree waited for. A descendant that escaped the tree
  is missed.
- **A root-only source** sees no descendant. The root's `/proc/<pid>/io` read
  while it is a zombie includes the descendants it waited for.
- **The run cgroup** misses whatever the child did before it joined the
  cgroup. Its fault and storage-write counters also miss work charged after
  the action ends, such as delayed writeback.
- **Pressure** is read at the action's start and end and recorded as the
  difference.

**OBA6: Stall beside work.** `ci perf show` **must** show an action's stall
times in the same row as its CPU time. `ci perf compare` **must** mark a
series `stalled` when its wall time grew, both sides have stall times, and
the sum of its stall times grew by at least half as much as its wall time. A
series without stall times on both sides is never marked.

### 4.1 The cache family

**OBA7: Cache outcome.** Every build-graph action **must** record
`cache.outcome`: `hit`, `miss`, `uncacheable` (a test whose result may not be
reused, [BGX3](../build-graph/SPEC.md#_9-test-actions-and-result-reuse)) or
`unpublished` (a miss whose result was not published, such as a failed
action).

**OBA8: Miss reasons.** A miss **must** record the first `cache.miss-reason`
of this list that applies:

1. `corrupt`: a manifest of its declared key matches, and its result failed
   the digest check ([BGS6](../build-graph/SPEC.md#_6-the-shared-store));
2. `evicted`: a manifest matches and its result is missing; or the declared
   key has no manifest and is in the eviction journal (OBA9);
3. `input-changed`: the declared key has manifests and none matches, and the
   most recently used manifest has a file entry whose digest differs; the
   record names that entry's first differing path, root-relative or in the
   Nix store;
4. `absent-appeared`: as `input-changed`, but the most recently used manifest
   differs only in an absent candidate that now exists, which the record names;
5. `conservative`: the action is keyed by whole roots
   ([BGK6](../build-graph/SPEC.md#_5-keys-and-the-input-manifest));
6. `no-entry`: anything else.

**OBA9: The eviction journal.** The store **must** keep a journal of the
declared keys whose last result it evicted, bounded to 65 536 entries by
default, dropping the oldest first.

| ID                      | Definition                                                                  | Unit    | All platforms                       | Overhead       |
| ----------------------- | --------------------------------------------------------------------------- | ------- | ----------------------------------- | -------------- |
| `cache.outcome`         | as OBA7                                                                     | enum    | store, E                            | none           |
| `cache.miss-reason`     | as OBA8                                                                     | enum    | store, E                            | none           |
| `cache.key-time`        | time to compute the declared key, file digests included                     | ns      | E                                   | clock reads    |
| `cache.lookup-time`     | time to match manifests, take the lease and open the result                 | ns      | E                                   | clock reads    |
| `cache.stats`           | files whose metadata was read for keying and matching                       | count   | E                                   | none           |
| `cache.hashed-bytes`    | bytes read to compute digests the digest cache did not hold                 | bytes   | E                                   | none           |
| `cache.reused-bytes`    | bytes of the outputs a hit reused                                           | bytes   | E                                   | none           |
| `cache.published-bytes` | bytes a miss published                                                      | bytes   | E                                   | none           |
| `cache.identical-rerun` | a miss whose outputs equal those of the series' previous recorded execution | boolean | E; absent without a previous record | one comparison |

_Rationale:_ an identical rerun is work a finer key would have saved, such as a
compile repeated after a comment-only edit. Dependent actions already stop at
it, because their keys cover its output digests.

## 5. Compile metrics

A compile's time trace says where the compiler spent its time. Its raw form
costs too much to keep on (§10), so the compiler or the action driver reduces
it to a summary.

**OBC1: Phases.** A compile **must** report, for each phase of the table
below, its self time, its inclusive time and its event count:

- an event's **self time** is its duration minus the durations of the events
  directly nested in it, and a phase's self time is the sum over its events,
  so the phases' self times partition the traced time;
- a phase's **inclusive time** is the sum of the durations of its events that
  have no enclosing event of the same phase.

The phases group the D frontend's time-trace event types, which LDC and DMD
share in `dmd/timetrace.d`, and the events LDC adds:

| Phase      | Frontend event types, or LDC events                                          |
| ---------- | ---------------------------------------------------------------------------- |
| `parse`    | `parseGeneral`, `parse`                                                      |
| `import`   | `sema1Import`                                                                |
| `sema`     | `semaGeneral`                                                                |
| `sema1`    | `sema1Module`, `sema1TemplateDecl`, `sema1TemplateInstance`, `sema1Function` |
| `sema2`    | `sema2`                                                                      |
| `sema3`    | `sema3`                                                                      |
| `ctfe`     | `ctfe`, `ctfeCall`                                                           |
| `dfa`      | `dfa`                                                                        |
| `codegen`  | `codegenGlobal`, `codegenModule`, `codegenFunction`; LDC's `Generate IR`     |
| `optimize` | LDC's `Optimize`                                                             |
| `emit`     | LDC's `Write file(s)`                                                        |
| `other`    | every other event, such as `generic`, `link` and LDC's `Preprocess C file`   |

The event names are those of `PetarKirov/ldc` branch `sparkles/main` at
`0a4e8b9a9fd0b5a46af6c9a08d5e026778b213ee`.

**OBC2: The heaviest events and modules.** A compile **must** report:

- the ten `sema1TemplateInstance` events with the longest self time, and the
  ten with the longest duration, each with its name truncated to 256 bytes and
  its self and inclusive time;
- the ten modules with the most self time, summing the self time of the events
  whose location lies in the module, and the ten with the most inclusive time,
  summing the durations of their `parse`, `sema1Module` and `codegenModule`
  events.

The lists rank single events, not per-symbol sums.

**OBC3: Totals include every event.** Phase totals and counts **must** include
every event, whatever its duration. A source that drops events below a
granularity **must** report the phase totals as lower bounds.

_Rationale:_ at a coarse granularity, a thousand short template
instantiations vanish from the totals while one long one remains, which hides
exactly the growth this family exists to show.

**OBC4: Template counts.** A compile **must** report the counts the
frontend's template statistics (`-vtemplates`) give, and **must** keep those
statistics out of the action's recorded diagnostics on every run alike, so
that a hit and a miss replay the same diagnostics.

**OBC5: Sources from the manifest.** The module and source-size metrics
**must** come from the compile's input manifest
([BGK2](../build-graph/SPEC.md#_5-keys-and-the-input-manifest)). Lines **must**
be counted while digesting, and the digest cache
([BGK5](../build-graph/SPEC.md#_5-keys-and-the-input-manifest)) **must** keep
each file's line count beside its digest, so that a cached digest still yields
its lines.

**OBC6: Object analysis after the action.** Section sizes and symbol
statistics **must** be computed by the executor from the action's outputs
after the action ends, never through a compiler flag, and **must** be stored
with the result as measurements (OBD8), so that a hit recomputes nothing.

**OBC7: Time-trace sources.** The time-trace family **must** come from one of
two sources, chosen per compiler by the overhead budget (OBO2):

- **Summary mode:** the compiler aggregates its own events into the summary of
  OBC1–OBC2 and writes only that summary (OBC8).
- **Reduced trace:** for a compiler without summary mode, the compiler writes
  a trace at a coarse granularity, the action driver reduces it to the summary
  as it reads it, and the trace is deleted. Its phase totals are lower bounds
  (OBC3).

**OBC8: The summary mode.** The compiler's summary mode **must**:

- time every event it would trace, whatever its duration;
- keep memory bounded by the event nesting depth, the top-ten tables and one
  entry per module compiled or imported;
- compute an event's name only when the event enters a top-ten table;
- take no memory-statistics sample per event;
- write one JSON summary of at most 64 KiB into the action's measurement
  directory (OBD8).

| ID                                        | Definition                                                                                  | Unit         | Linux (ELF)            | macOS (Mach-O)     | Windows (COFF)     | Overhead                |
| ----------------------------------------- | ------------------------------------------------------------------------------------------- | ------------ | ---------------------- | ------------------ | ------------------ | ----------------------- |
| `compile.phase.<phase>.self`              | as OBC1                                                                                     | ns           | per OBC7               | per OBC7           | per OBC7           | budgeted, §10           |
| `compile.phase.<phase>.inclusive`         | as OBC1                                                                                     | ns           | per OBC7               | per OBC7           | per OBC7           | budgeted                |
| `compile.phase.<phase>.events`            | as OBC1                                                                                     | count        | per OBC7               | per OBC7           | per OBC7           | budgeted                |
| `compile.top.instances`                   | as OBC2, a list                                                                             | list         | per OBC7               | per OBC7           | per OBC7           | budgeted                |
| `compile.top.modules`                     | as OBC2, a list                                                                             | list         | per OBC7               | per OBC7           | per OBC7           | budgeted                |
| `compile.templates.instances`             | template instances the frontend created                                                     | count        | template statistics, E | E                  | E                  | budgeted                |
| `compile.templates.distinct`              | template declarations instantiated at least once                                            | count        | template statistics, E | E                  | E                  | budgeted                |
| `compile.modules.own`                     | the variant's own modules compiled                                                          | count        | manifest, E            | E                  | E                  | none                    |
| `compile.modules.imported`                | modules read by import and not compiled                                                     | count        | manifest, E            | E                  | E                  | none                    |
| `compile.source.own.bytes`, `.lines`      | size and line count of the own modules                                                      | bytes, count | manifest, E            | E                  | E                  | counted while digesting |
| `compile.source.imported.bytes`, `.lines` | size and line count of the imported modules and string imports                              | bytes, count | manifest, E            | E                  | E                  | counted while digesting |
| `object.section.<class>.bytes`            | bytes per section class: `text`, `data`, `rodata`, `bss`, `tls`, `debug`, `unwind`, `other` | bytes        | section headers, E     | section headers, E | section headers, E | headers read once       |
| `object.symbols`                          | symbols the object defines                                                                  | count        | symbol table, E        | symbol table, E    | symbol table, E    | one symbol-table read   |
| `object.symbols.name-bytes`               | total length of the defined symbols' mangled names                                          | bytes        | symbol table, E        | symbol table, E    | symbol table, E    | same read               |
| `object.symbols.templates`                | defined symbols whose mangled name contains a template instance (`__T`)                     | count        | symbol table, E        | symbol table, E    | symbol table, E    | same read               |
| `object.symbols.comdat`                   | defined symbols in a COMDAT group, or of weak binding                                       | count        | symbol table, E        | symbol table, E    | symbol table, E    | same read               |

The `list` unit of the two top-ten metrics is a detail record of names and
nanosecond times; lists live in the record's `detail/` files (OBD4).

## 6. Link and archive metrics

**OBL1: Link inputs and outputs.** A link **must** report its input objects
and their bytes, and its output's size and section sizes, by the section
classes of `object.section.<class>.bytes`.

**OBL2: What the linker reports.** With `ld.lld`, a link **must** pass flags
that make the linker report the archive members it extracts and the sections
`--gc-sections` discards, and **must** keep the discarded-section lines out of
the recorded diagnostics on every run alike. A linker that cannot report them
yields absences with reason `toolchain`.

**OBL3: Duplicate template code.** A link **must** report the COMDAT groups
that more than one of its inputs defines, and the bytes the linker kept only
once: for a group defined by `k` inputs, `(k − 1) × s`, where `s` is the
group's size in the first input that defines it, in link order.

| ID                                  | Definition                                        | Unit  | Linux (`ld.lld`)                                 | macOS                  | Windows (`lld-link`)      | Overhead             |
| ----------------------------------- | ------------------------------------------------- | ----- | ------------------------------------------------ | ---------------------- | ------------------------- | -------------------- |
| `link.inputs.objects`               | object files and archive members linked           | count | declared inputs and `--why-extract`, E           | —                      | —                         | none                 |
| `link.inputs.bytes`                 | bytes of the declared inputs                      | bytes | declared inputs, E                               | E                      | E                         | none                 |
| `link.archives.members-pulled`      | archive members the linker extracted              | count | `--why-extract`, E                               | —                      | —                         | one file             |
| `link.output.bytes`                 | size of the linked executable                     | bytes | E                                                | E                      | E                         | none                 |
| `link.output.section.<class>.bytes` | as `object.section.<class>.bytes`, for the output | bytes | section headers, E                               | section headers, E     | section headers, E        | headers read once    |
| `link.gc.removed-bytes`             | bytes of input sections `--gc-sections` discarded | bytes | `--print-gc-sections` and input section sizes, E | —                      | —                         | budgeted, §10        |
| `link.comdat.duplicate-groups`      | COMDAT groups more than one input defines         | count | input symbol tables, E                           | input symbol tables, E | input symbol tables, E    | from stored analyses |
| `link.comdat.duplicate-bytes`       | as OBL3                                           | bytes | input symbol tables, E                           | input symbol tables, E | input symbol tables, E    | from stored analyses |
| `link.phase.<name>.inclusive`       | inclusive time of each top-level linker phase     | ns    | `--time-trace`, reduced, E                       | —                      | `/time-trace`, reduced, E | budgeted             |
| `archive.members`                   | members of the archive                            | count | E                                                | E                      | E                         | none                 |
| `archive.output.bytes`              | size of the archive                               | bytes | E                                                | E                      | E                         | none                 |

## 7. Test metrics

A test action is one leg of one test binary, run through the runner core, the
library that drives test workers in the
[test runner](../../test-runner/SPEC.md)'s process model. A worker process
runs one test at a time, so its process-wide counters, read at a test's two
edges, belong to that test.

**OBT1: Per-test usage in the protocol.** The worker's `result` frame **must**
carry a `usage` member with the per-test metrics below, as an addition within
its protocol version:

- a runner that predates the member ignores it, as the protocol requires of
  unknown members;
- a client reading a worker that sends no `usage` **must** record the per-test
  metrics as absent with reason `protocol`.

**OBT2: Per-test peak memory on Linux.** On Linux, the worker **must** reset
its peak resident set (`/proc/self/clear_refs` with `5`) before each test, and
read `VmHWM` after it. The reset also lowers the worker's lifetime peak, which
the reaping call reports. So the client **must** compute `binary.worker.rss` as
the maximum of the worker's per-test peaks and of the peak its reaping
reports, and a test action's `task.rss.process` as the maximum over its
workers.

**OBT3: Flakiness is derived, not retried.** The runner does not retry tests.
A test whose verdict differs between the `-t 1` and `-t N` legs of one run, or
between two runs of test actions with equal input keys (OBG4), **must** be
marked flaky in the record.

| ID                       | Definition                                                           | Unit  | Linux                            | macOS         | Windows              | Overhead            |
| ------------------------ | -------------------------------------------------------------------- | ----- | -------------------------------- | ------------- | -------------------- | ------------------- |
| `test.wall`              | the test body's wall time                                            | ns    | harness clock, E                 | E             | E                    | none                |
| `test.cpu`               | the worker process's CPU time across the test                        | ns    | `getrusage` of itself, E         | E             | `GetProcessTimes`, E | two calls           |
| `test.cpu.children`      | CPU time of the child processes the test waited for                  | ns    | `getrusage` of children, L       | L             | —                    | two calls           |
| `test.rss`               | the worker's peak resident set during the test                       | bytes | OBT2, E                          | —             | —                    | one write, one read |
| `test.gc.bytes`          | bytes the test's thread allocated from the GC, as the GC rounds them | bytes | `GC.allocatedInCurrentThread`, E | E             | E                    | two calls           |
| `test.gc.collections`    | GC collections in the worker during the test                         | count | `GC.profileStats`, E             | E             | E                    | two calls           |
| `test.gc.pause`          | time the worker's threads were paused for GC during the test         | ns    | `GC.profileStats`, E             | E             | E                    | same calls          |
| `binary.handshake`       | worker spawn to its `listed` frame                                   | ns    | client clock, E                  | E             | E                    | none                |
| `binary.worker.rss`      | a worker's peak resident set                                         | bytes | OBT2, L                          | reap usage, E | peak working set, E  | none                |
| `binary.ctfe.wall`       | wall time of the `@ctfe` probe compile                               | ns    | client clock, E                  | E             | E                    | none                |
| `binary.ctfe.cpu`        | CPU time of the probe compile                                        | ns    | as `task.cpu.user` plus `.sys`   | as §4         | as §4                | as §4               |
| `binary.worker.restarts` | workers started to replace one that died during a test               | count | client, E                        | E             | E                    | none                |
| `binary.legs.disagree`   | tests whose verdict differs between this run's two legs              | count | client, E                        | E             | E                    | none                |

`binary.worker.rss` is a lower bound on Linux because a peak between one
test's read and the next reset is missed.

## 8. Run metrics and facts

**OBR1: Critical path.** `run.critical-path` **must** be the longest path
through the executed graph, weighting each task by its `task.wall` and
following only edges whose condition was satisfied. `run.work` **must** be the
sum of `task.wall` over executed tasks.

**OBR2: Parallel efficiency.** `run.cpu` **must** be the sum of `task.cpu.user`
and `task.cpu.sys` over executed tasks, with the weakest quality among them,
and `run.cores` the number of logical CPUs the run may use. Reports derive
parallel efficiency as `run.cpu ÷ (run.cores × run.wall)`, and idle-core time
as `run.cores × run.wall − run.cpu`, never below zero.

**OBR3: Load over time.** The run **must** record two step functions: the
number of ready but unadmitted tasks, and the admitted weight, each changing at
every admission and completion. Each is reduced to 512 intervals of equal
duration over `run.wall`, keeping each interval's maximum. The run also records
`run.queue.max` and the time-weighted mean `run.queue.mean`.

**OBR4: Planning time.** The planner **must** record the wall time of each
planning stage it performs: `run.plan.discover`, `run.plan.resolve`,
`run.plan.version-scan`, `run.plan.layout-lint`, `run.plan.pkg-config`,
`run.plan.key` and `run.plan.total`. A stage the command does not perform is
absent with reason `family-off`.

**OBR5: The no-op run.** A run that executes no action, because every action
hit and no test ran, **must** be marked `noop`. `ci perf history` charts the
wall time of such runs as the no-op time.

**OBR6: Store state.** A run **must** record its hit and miss counts over
cacheable actions, the store's size and entry count at its end, and the
results it evicted, by count and bytes.

**OBR7: Facts.** A run record **must** carry these facts, which are not
metrics:

- **Toolchain:** the toolchain identity digest
  ([BGT1](../build-graph/SPEC.md#_8-toolchain-identity)), and the compiler's
  and linker's vendor and version;
- **Source:** the commit, whether the tree was dirty, and, for CI runs only,
  the branch name or pull request number;
- **Host:** the CPU model string, vendor, family and model number, the logical
  and physical core counts, the instruction-set feature level, the operating
  system and kernel release, total memory rounded to GiB, the CPU frequency
  governor, whether it runs under a hypervisor, the load average at start, the
  cgroup tier, and `perf_event_paranoid`;
- **Run:** the command and its options, normalized like an action's argument
  vector ([BGA6](../build-graph/SPEC.md#_4-the-action-graph)), the families
  enabled, the capacity, the backend, and in CI the provider and the runner
  labels that OBP3 allows.

| ID                                      | Definition                      | Unit         | Source, all platforms                | Overhead            |
| --------------------------------------- | ------------------------------- | ------------ | ------------------------------------ | ------------------- |
| `run.wall`                              | `GraphPlanned` to `RunFinished` | ns           | executor clock, E                    | none                |
| `run.critical-path`                     | as OBR1                         | ns           | measurement table, E                 | one pass over edges |
| `run.work`                              | as OBR1                         | ns           | measurement table, E                 | none                |
| `run.cpu`                               | as OBR2                         | ns           | measurement table, weakest input     | none                |
| `run.cores`                             | logical CPUs the run may use    | count        | online CPUs and the affinity mask, E | none                |
| `run.queue.max`, `.mean`                | as OBR3                         | count        | events, E                            | none                |
| `run.plan.<stage>`                      | as OBR4                         | ns           | planner clock, E                     | clock reads         |
| `run.cache.hits`, `.misses`             | as OBR6                         | count        | store, E                             | none                |
| `run.store.bytes`, `.entries`           | as OBR6                         | bytes, count | store, E                             | one index walk      |
| `run.store.evictions`, `.evicted-bytes` | as OBR6                         | count, bytes | store, E                             | none                |

## 9. CI job metrics

**OBJ1: Provider timings.** For each CI job that ran a `ci` command, the
record **must** carry the job's queue time, from creation to start, its wall
time, and the wall time of its steps, grouped into the step classes
`checkout`, `nix-setup`, `nix-build`, `ci-run` and `upload` by a declared map
from step name to class. They come from the provider's API, through the fetch
layer of [`ci stats`](../../ci/stats/SPEC.md), in the job that appends
records (OBH4). On a provider without such an API they are absent.

**OBJ2: Substitution.** A job **must** record the store paths and bytes Nix
fetched while building the `ci` tool, read from Nix's internal-JSON log of
that build. The job's setup step runs that build with
`--log-format internal-json`, writing the log to a file, and the job's `ci`
invocation ingests the file through its `--nix-log FILE` option, so no shell
step parses it. The job also records the bytes it pushed to the binary cache,
when it pushed any.

**OBJ3: Per-job critical path.** `ci.job.critical-path` **must** be the
`run.critical-path` of the job's `ci` run, or the sum over its runs when it ran
several in sequence.

| ID                      | Definition                                  | Unit  | GitHub Actions                     | Other providers | Overhead     |
| ----------------------- | ------------------------------------------- | ----- | ---------------------------------- | --------------- | ------------ |
| `ci.job.queue`          | job created to started, to the second       | ns    | jobs API, E                        | —               | one API page |
| `ci.job.wall`           | job started to completed, to the second     | ns    | jobs API, E                        | —               | same page    |
| `ci.step.<class>.wall`  | wall time of the job's steps of that class  | ns    | jobs API, E                        | —               | same page    |
| `ci.nix.fetched-paths`  | store paths substituted while building `ci` | count | Nix internal-JSON log, E           | E               | log parse    |
| `ci.nix.fetched-bytes`  | bytes downloaded for them                   | bytes | Nix internal-JSON log, E           | E               | log parse    |
| `ci.cache.pushed-bytes` | bytes the job pushed to the binary cache    | bytes | push output, E; absent without one | E               | none         |
| `ci.job.critical-path`  | as OBJ3                                     | ns    | E                                  | E               | none         |

## 10. Overhead budget

**OBO1: The budget.** With every default family on, observation **must** cost,
for each compiler the toolchain offers and for each action kind, at most:

- 3% of CPU time;
- 3% of user-mode instructions retired;
- 5% of peak resident set;
- 1 MiB written per compile before reduction.

Each is measured on the fixed corpus of
[testing.md](./testing.md#oracle-14-overhead-budget) as the median over
interleaved repetitions.

_Rationale:_ an always-on measurement that costs more than the run-to-run noise
of what it measures distorts the history it keeps, and slows every run.

**OBO2: Each family alone.** Each family with a compiler or linker flag
**must** meet OBO1 on its own as well as with the others.

**OBO3: Families.** Every recorded metric **must** belong to one family:
`process`, `counters`, `stall`, `cache`, `time-trace`, `templates`, `objects`,
`link`, `test`, `run` or `ci`. A family that does not meet OBO1 for a compiler
**must** be off by default for it. Every command that executes a graph
**must** accept `--observe LIST`, whose items are a family name, which turns it
on, `no-` followed by a family name, which turns it off, or `default`.

**OBO4: Raw traces are discarded.** A raw compiler or linker trace **must** be
deleted once reduced, unless `--keep-traces` is given; then it is moved to the
run's directory and its path printed. `--keep-traces` adds trace flags to the
affected actions' argument vectors, so those actions are not served from the
store.

## 11. Run records

**OBD1: Run identity.** Each run **must** have a run identifier made of
lowercase letters, digits and hyphens, at most 64 characters:

- **GitHub Actions:** `gh-<run id>-<attempt>-<job>-<n>`, where `<job>` is the
  first twelve hexadecimal digits of the SHA-256 of the job's key in the
  workflow that defines it and its matrix values, never its displayed name,
  which differs when another workflow calls it, and `<n>` the ordinal of the `ci` invocation within the job;
- **elsewhere:** `local-` followed by 32 random hexadecimal digits.

It is a name, never an ordering input.

**OBD2: Series keys.** Each task in a record **must** carry a
[series key](../../../glossary.md#series-key): the SHA-256 of its `TaskId`
([TDM1](../task-dag/SPEC.md#_3-1-task-nodes)) and, for a build-graph action, of
its variant key ([BGV1](../build-graph/SPEC.md#_3-variants)) with the
toolchain identity replaced by the compiler's vendor. A task id **must not**
itself embed a toolchain identity or a result key. A build-graph action's task
id **must** have the form `<kind>:<package>:<role>:<vendor>:<d>`, where
`<vendor>` is the compiler's vendor and `<d>` the first twelve hexadecimal
digits of the variant key with its toolchain identity replaced by that vendor;
the build graph adopts the form in BGA8.

_Rationale:_ a toolchain bump changes every variant key, and a series that
broke at every bump could not show what the bump did. Keeping the vendor
keeps LDC and DMD builds of one variant apart.

**OBD3: Comparability keys.** Each task in a record **must** carry a
comparability key: the SHA-256 of the toolchain identity, the CPU vendor,
family and model number, the operating system, and the families enabled for
that action. Two samples of one series are comparable only when their
comparability keys are equal.

**OBD4: Layout.** A run record **must** be a directory:

```text
run.json          run identity, facts, run and CI job metrics, absences, run degradations
tasks/<s>.json    the tasks of shard <s>: keys, outcome, timestamps, measurements
detail/<s>.json   their variable-size measurements: top-ten lists, per-test metrics
```

`<s>` is the series key's first hexadecimal digit divided by two: `0` to `7`.
A task's timestamps are nanoseconds since the run's start; the start itself is
a UTC time to the second.

**OBD5: Encoding.** Every file **must** be UTF-8 JSON with a fixed member
order, integers rendered without exponent or fraction, and no floating-point
value. A value whose quality is exact **must** omit its quality.

**OBD6: Schema versioning.** `run.json` **must** begin with
`"schema": "sparkles.perf.run"` and an integer `"version"`. Within one
version, a reader **must** ignore unknown members and unknown metric ids. A
change that removes a member, or changes a member's meaning or type, **must**
increment the version. A reader **must** read its own version and the one
before it, and **must** skip a record of any other version with a warning that
names the version.

**OBD7: Immutable records.** A record **must not** change once written. The
only exception is compaction of `refs/perf/data`, which removes `detail/` files and
replaces old records by rollups (OBH7).

**OBD8: Measurements are side outputs.** An action's measurement files, such
as a compile's summary and the analyses of its outputs, **must**:

- be written into a measurement directory beside the action's output
  directory, which argument normalization replaces by a placeholder of its own
  ([BGA6](../build-graph/SPEC.md#_4-the-action-graph)), so its path does not
  enter the key;
- not be declared outputs ([BGA3](../build-graph/SPEC.md#_4-the-action-graph)),
  nor be read by any dependent action;
- be stored with the result as metadata, like its diagnostics
  ([BGA7](../build-graph/SPEC.md#_4-the-action-graph));
- under the Nix backend, be a separate derivation output that the backends'
  agreement ([BGN5](../build-graph/SPEC.md#_10-the-nix-backend)) does not
  compare, so that content addressing still stops at an unchanged object.

**OBD9: A hit's stored measurements.** A hit **must** record its own
measurements, such as `task.wall` for the lookup, and, in a separate `stored`
member, the measurements stored with the result it reused. Stored measurements
**must not** enter a comparison or a history series unless asked for.

**OBD10: Bounded size.** A record **must not** exceed 4 MiB uncompressed. A
record that would **must** drop, in order, per-test metrics, then top-ten
lists, then compile phase detail, and **must** say what it dropped.

**OBD11: Run degradations.** A record that cannot be written, a source that
failed, or a record that fails the privacy scan (OBP4) **must** be reported as
a run degradation: a line in the run's summary and an entry in `run.json`'s
`degradations`, with its reason. A run degradation is not a task outcome and
**must not** change any outcome or exit status.

**OBD12: Local records.** `ci` **must** write each run's record under
`$XDG_CACHE_HOME/sparkles/perf/runs/<yyyy>/<mm>/<dd>/<run id>/`, with
`~/.cache` when the variable is unset, outside the build store, so that store
eviction never removes history. Local records older than 90 days, or beyond
512 MiB in total, **must** be removed oldest first; both bounds are
configurable.

## 12. History on `refs/perf/data`

The ref `refs/perf/data` of this repository holds the shared history: a
chain of commits with no common ancestor with `main`, holding data only. It
lies outside `refs/heads/` and `refs/tags/`, so an ordinary clone or fetch
never downloads it and no branch list shows it.

**OBH1: Layout.** The ref's tree **must** hold:

```text
README.md                                      what the ref is, with the schema's link
runs/<yyyy>/<mm>/<dd>/<commit12>-<run id>/     one run record, as OBD4
rollups/<yyyy>/<mm>/<s>.json                   compacted series summaries (OBH7)
```

The date is the run's start date in UTC, and `<commit12>` the first twelve
hexadecimal digits of the commit it measured. An appender **must** derive a
run's directory name from the identity it trusts (OBH5), never from the
record's own claims, and a directory once written is never written again.

**OBH2: Data only.** Every writer **must** refuse to commit a tree containing
a `.github/` directory or an executable file, so that the ref carries no code
even if a later tool checks it out.

**OBH3: Append without conflicts.** Appending **must**:

1. fetch the ref, `+refs/perf/data:refs/perf/data`, and verify its tip
   (OBH8);
2. build the new tree with `git mktree` from the tip's tree and the new run
   directories, through no index and no working tree, skipping a directory
   that already exists;
3. create a signed commit with the fixed identity of OBH6, and push it to
   `refs/perf/data` without force;
4. on a rejected push, repeat from step 1, with jittered back-off, for at most
   ten minutes, and then fail, reporting the runs not appended.

Each run writes only its own directory, so two appenders never touch the same
path and a retry needs no merge. A repeated append of the same runs is a no-op.

**OBH4: CI appends what landed.** Records reach the ref from the workflow
that establishes `main`'s checks:

- **Mirror path:** when the landed tree equals the tree that a pull request or
  merge-queue run built, the mirroring job **must** append that run's records,
  downloaded from its workflow artifacts, under the landed commit. Records
  whose artifacts have expired are reported as not appended.
- **Rebuild path:** when the trees differ, the rebuilt run **must** append its
  own records.
- **Pull requests:** a pull request run **must** upload its records as
  artifacts and **must not** append them.

The appending job **must** live in `main-checks.yml` for both paths, after the
mirroring step or after the rebuild it `needs`, never in `ci.yml`, which also
runs for pull requests and the merge queue. It reads artifacts with
`actions: read`, pushes with `contents: write`, signs with the CI key of OBH8,
and runs on `.#ci-minimal`.

**OBH5: Appended records are untrusted.** An appender **must** take a run's
identity from the provider's API for the run it appends, and **must** validate
every record before appending it: the run identifier's syntax, its schema
version, its size (OBD10), the privacy scan (OBP4), and at most four records
per job the API lists for the run. The invocation ordinal `<n>` is the one part
of the identifier a record supplies; the appender checks that it is a small
integer and drops a second record that claims the same identifier. A record
that fails is dropped and reported in the job's summary, and the others are
appended.

_Rationale:_ a pull request's code writes its own records, so a record is
attacker-controlled input until checked. A forged record can mislead a
comparison but cannot run code or overwrite another run.

**OBH6: Local publication is explicit.** A developer's records **must** reach
the ref only through `ci perf push`, which **must** refuse a record of a dirty
tree unless `--allow-dirty` is given, run the privacy scan, mark each record
`origin: local`, and append as OBH3 states, signing with the developer's key.
Every commit on the ref **must** carry the fixed author and committer
`perf-data <perf-data@users.noreply.invalid>`, whatever identity the
environment supplies; the signature, not the identity, says who wrote it.

**OBH7: Retention and size.** A scheduled workflow **must** compact the ref
monthly:

1. remove `detail/` files older than 90 days;
2. replace the run directories older than 365 days by rollups: per series,
   comparability key, gate metric, month and quality, the sample count and the
   median, minimum and maximum of each numeric metric, and the count of each
   value of an enum or boolean metric;
3. write the result as a new root commit, signed with the CI key and marked as
   a compaction, and replace the ref with
   `--force-with-lease=refs/perf/data:<old tip>`, starting again from step 1
   when the lease fails.

The thresholds are configurable. After compaction, the history's packed size
**must not** exceed 256 MiB; a compaction that cannot meet the bound **must**
fail and name the largest series.

**OBH8: Integrity by signature.** GitHub's rulesets protect branches and tags,
and its push rulesets, which restrict file paths and sizes, apply only to
private and internal repositories. So nothing on the server limits who may
update, rewind or delete `refs/perf/data` beyond write access to the
repository. Integrity is therefore checked by readers:

- every commit on the ref **must** be signed with an SSH key listed in the
  allowed-signers file `nix/perf-data-signers` on `main`, whose principals are
  role names, such as `ci` or `maintainer-1`, never a person's name or email;
- the CI key **must** live in a deployment environment whose deployment
  branches allow only `main`; an environment restricts by ref, not by job, so
  review of `main`'s workflows keeps the key to the appending and compaction
  jobs;
- a reader **must** verify the commits it uses, and **must** ignore, and
  report, the runs a commit with a missing or unlisted signature added;
- a reader **must** accept a tip that does not descend from its cached tip only
  when the new tip is a compaction commit signed with the CI key; otherwise it
  keeps its cached history and reports the rewind;
- an appender **must** refuse to append onto a tip it cannot verify, and fail.

_Rationale:_ a signature check on read protects every reader whatever the
server allows. A rewind or deletion by someone with write access loses at most
what no reader had cached, and is reported rather than believed.

**OBH9: Lazy fetch.** `ci perf` **must** read the ref through a bare partial
clone at `$XDG_CACHE_HOME/sparkles/perf/cache.git`, created on first use, from
the repository's canonical URL, which `apps/ci` declares and
`--history-remote URL` overrides. It **must** fetch only
`+refs/perf/data:refs/perf/data`, with `--filter=blob:none`, fetch the blobs a
command needs in one batched request per command, and reach every git command
through `runGit`.

**OBH10: Offline.** When the remote cannot be reached, `ci perf` **must** use
the cached clone and the local records, and **must** report the age of the
cached tip as a run degradation.

## 13. Privacy

**OBP1: Forbidden content.** A record **must not** contain:

- a username, real name or email address;
- a hostname, machine identifier or network address;
- an absolute path, other than a Nix store path;
- an environment variable's value, other than the provider facts of OBR7;
- text copied from a task's output or diagnostics, other than the
  source-derived identifiers of invariant 5.

**OBP2: Paths.** A path in a record **must** be relative to the repository
root, or a Nix store path. Any other path **must** be replaced by its class:
`<home>`, `<temp>`, `<build-store>` or `<other>`.

**OBP3: Host facts are an allowlist.** Host facts **must** be exactly those of
OBR7, each read from a source that names no person. Runner names and machine
names **must not** be recorded. A runner label **must** be recorded only if it
appears in the label allowlist `apps/ci` declares, and otherwise as `<label>`.

**OBP4: The scan.** Before a record is written, pushed or appended, a scanner
**must** reject it if any string in it:

- contains an email address, or an absolute path that is not a Nix store path,
  including `/home/…`, `/Users/…` and `C:\Users\…` forms;
- equals, or has as a segment of an absolute path, the producing user's name,
  the home directory's last segment, or the host's name; a root-relative
  repository path is not checked against these, so a user named `ci` or `nix`
  does not reject every record;
- contains the producing user's git email.

The producer runs the whole scan. An appender, which does not know the
producer's identity, runs the first rule. A source-derived identifier that
fails a rule, such as a template instance with a path in a string argument,
**must** be redacted to its class (OBP2) instead of rejecting the record. Any
other failure rejects it, and a rejected record is not written.

## 14. Comparison and the regression gate

**OBG1: The gate metric.** Each run record **must** state its gate metric, one
of:

- `instructions`, `task.instructions`, when the run's host counts exact
  user-mode instructions (OBA2, OBA3);
- `cpu-user`, `task.cpu.user`, when it cannot and the run is on a CI
  provider's hosted runner;
- none otherwise, with the reason the counters are absent.

The gate **must** read only the gate metric, and only values that some run
measured by executing the action, found as OBG3 states: exact values for
`instructions`, and exact or lower-bound values of the same quality on both
sides for `cpu-user`. Every other metric is informational: compared, shown,
and never gated.

**OBG10: One gate metric per comparison.** A comparison **must** gate only when
both runs have the same gate metric, and **must** state that metric in its
report and its JSON. A series whose sides would need different metrics, such
as instructions from a developer's machine and CPU time from a hosted runner,
**must** be `ungated` with reason `gate-metric-differs`; instructions are never
compared with CPU time.

_Rationale:_ on a host that counts them, the user-mode instructions of a
deterministic action vary by well under a percent between identical runs.
Hosted virtual machines may expose no counters, and their CPU time, although
far noisier, is still a measure of work rather than of waiting; a wider
threshold and its own noise estimate keep it usable.

**OBG2: Comparable pairs.** A series **must** be compared only between samples
with equal comparability keys (OBD3). A series whose samples differ in
comparability key **must** be shown as `not-comparable`, naming the components
that differ.

**OBG3: The two sides.** For `ci perf compare <base> <head>`, each side is a
run, or a revision resolving to its CI record of the same job, or with
`--local` to its newest local record. For each series:

- when both sides have the same input key (OBG4), the series is `unchanged`;
- otherwise each side's value is the measured exact value of its own input
  key with head's comparability key: the side's own measurement when it
  executed the action, else the measurement of the run that produced the
  result it reused, which its `stored` member names (OBD9), looked up in
  history;
- a side with no such measurement makes the series `ungated` with reason
  `stored`, and the report names the run each value came from.

With `--gate --local`, both sides **must** be local records of one machine,
whose OBR7 host facts are equal; otherwise the comparison is refused. A
comparison of a local run with CI records **must** be report-only: it gates
nothing, and its report says so.

**OBG4: The noise model.** Each series' noise **must** be estimated, separately
for each gate metric and from that metric's samples, from executions with
equal inputs. An action's **input key** is its result key for
a compile and its declared key ([BGK1](../build-graph/SPEC.md#_5-keys-and-the-input-manifest))
otherwise. From the series' history with head's comparability key:

1. group the measured samples that OBG1 admits by input key, and order each group by run
   start, then by run identifier;
2. within each group of two or more, take the relative difference of each pair
   of consecutive samples, `(x₂ − x₁) ÷ x₁`;
3. keep the 64 differences whose later sample is newest;
4. the series' noise `σ` is 1.4826 times the median absolute deviation of
   those differences from their median.

At least 16 differences are required; otherwise the series uses its kind's
prior. `σ` estimates the spread of the difference between two samples, which
is what a comparison observes.

**OBG5: The threshold.** A series **must** be a regression when its relative
increase over base exceeds `max(f, k × σ)` and its absolute increase exceeds
`a`. Here `f` is the kind's floor, `a` its absolute floor, and `k` the
multiplier, 5 by default. The defaults are:

| Gate metric    | Kind                                     | Prior `σ` | Floor `f` | Absolute floor `a` |
| -------------- | ---------------------------------------- | --------- | --------- | ------------------ |
| `instructions` | `compile`, `archive`, `link`, `generate` | 0.3%      | 0.5%      | 10⁷ instructions   |
| `instructions` | `test`                                   | none      | 2%        | 10⁸ instructions   |
| `cpu-user`     | `compile`, `archive`, `link`, `generate` | none      | 5%        | 200 ms             |
| `cpu-user`     | `test`                                   | none      | 10%       | 1 s                |

A series whose row has no prior is not gated without 16 differences. Spike S2
calibrates the `cpu-user` rows on hosted runners before they gate. Every default is
configurable.

_Rationale:_ at `k = 5` a normal tail flags about three series in ten million,
which leaves room for heavier tails and for the error of a median absolute
deviation over a few dozen differences; OBG9 checks the combined rate.

**OBG6: No gate without its metric.** A series **must** be gated only when both
sides have a value of the comparison's gate metric that OBG1 admits.
Otherwise it is `ungated`, with the reason: the absence reason of a side,
`estimate`, `stored`, `not-comparable`, `gate-metric-differs` or
`insufficient-noise`. When a comparison gates no series,
its outcome **must** be `Degraded(noGate)`, with the reasons counted, and its
exit status zero.

**OBG7: Exit statuses.** `ci perf compare --gate` **must** exit 1 when any
gated series regresses, and 0 otherwise. A selector that matches no record, or
an unreadable record, is a planning failure with exit status 1
([TDC5](../task-dag/SPEC.md#_5-structured-cancellation-and-fail-fast)) and a
message naming it. An improvement beyond the threshold is reported, never
gated.

**OBG8: Determinism.** For the same two records and the same history, a
comparison **must** produce the same classifications and the same report.

**OBG9: The false-positive bound.** For each gate metric, over A/A pairs, two
runs of one commit with one comparability key, the gate **must** flag at least
one series in no more than 5% of pairs.

## 15. The `ci perf` commands

```text
ci perf show [RUN] [--task SELECTOR...] [--metrics LIST] [--json FILE]
ci perf compare BASE HEAD [--gate] [--local] [--metrics LIST] [--json FILE]
ci perf history TASK [--metric ID] [--since DATE] [--limit N] [--origin ci|local|all] [--json FILE]
ci perf push [RUN...] [--allow-dirty]
ci perf fetch [--since DATE]
```

Every `ci perf` command also accepts `--history-remote URL` (OBH9).

**OBQ1: Run selectors.** `RUN`, `BASE` and `HEAD` **must** accept a run
identifier or a unique prefix of one, `latest` for the newest local record, a
path to a record directory, or a git revision (OBG3). A selector that is
ambiguous, or matches nothing, is an error naming the candidates.

**OBQ2: `show`.** `ci perf show` **must** print the run's facts, its run and CI
job metrics, and a table of its tasks in presentation order, with wall time,
CPU time, stall times, peak memory, instructions and cache outcome, and each
value's quality marker. `--task` filters by the task-DAG selector forms
([TDS4](../task-dag/SPEC.md#_2-2-from)) applied to task ids.

**OBQ3: `compare`.** `ci perf compare` **must** print the comparison's gate
metric, or the reason it has none (OBG10), and one row per series of either
run: the base and head values of each selected metric, the relative
delta, the threshold, and the classification: `regression`, `improvement`,
`within-noise`, `unchanged`, `ungated` with its reason, `not-comparable`,
`added` or `removed`, plus the `stalled` mark (OBA6). Rows are sorted by
classification in that order, then by descending absolute instruction delta,
then by task id.

**OBQ4: `history`.** `ci perf history` **must** chart one series' metric over
its records, oldest first, ordered by the commit's position in `main`'s
first-parent history when known and by run start otherwise. It **must** mark
changes of comparability key, flaky verdicts (OBT3) and no-op runs (OBR5).

**OBQ5: `push` and `fetch`.** `ci perf push` publishes as OBH6 states.
`ci perf fetch` fetches `+refs/perf/data:refs/perf/data` with
`--filter=blob:none` and then the blobs of a date range, ahead of use; every
other command fetches lazily what it needs (OBH9).

**OBQ6: Machine output.** `--json FILE` **must** write one JSON document with
the content of the human report, in the vocabulary's ids and units
([TDO5](../task-dag/SPEC.md#_7-5-machine-output)).

**OBQ7: A small closure.** `ci perf` **must** work in `.#ci-minimal`, needing
only git and network access.

**OBQ8: One-node graphs.** Each `ci perf` command **must** run as a one-node
graph ([CIC2](../../ci/task-dag/SPEC.md#_1-1-canonical-commands)).

## 16. Reporting

**OBU1: Plain summaries.** The plain reporter's final summary **must** add the
run's wall time, CPU time, critical path, parallel efficiency, hit count and
largest task memory, and the five tasks with the longest wall time. These
lines are timings, which the plain transcript omits when timings are off
([TDO3](../task-dag/SPEC.md#_7-3-non-tty-default)).

**OBU2: TTY summaries.** The TTY reporter **must** show the same summary as a
table after the live region ends, and each running task's CPU time and memory
as `TaskUsage` events arrive ([TDO2](../task-dag/SPEC.md#_7-2-interactive-tty)).

**OBU3: CI provider summaries.** Under a provider with a step summary
([TDO6](../task-dag/SPEC.md#_7-6-ci-provider-integration)), the reporter
**must** write the summary of OBU1 as a Markdown table with the ten slowest
tasks, and, when a comparison ran, its gate metric, its regressions and the
count of ungated series by reason.

**OBU4: Markers.** Every report **must** mark a lower bound with `≥`, an
estimate with `≈`, a stored measurement with `*` and an absent value with
`—`, and **must** list the absence reasons once per report.

**OBU5: Task output is untouched.** No measurement **may** appear in a task's
replayed output block, so that a reused result replays the same lines (TRM6 of
the test runner's process model).

## Terminology

<GlossaryList owner="sparkles:build-primitives" />
