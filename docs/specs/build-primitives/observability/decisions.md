---
status: draft
owner: sparkles:build-primitives
reviewed: 2026-11-06
---

# Observability — Decisions

Each record states its question, the alternatives, the choice and when to
revisit it. Records marked **accepted** were decided by the owner on
2026-11-06: OD1–OD4 in the brief that commissioned this specification, and
OD18 after its first review. Records marked
**proposed** await the owner's decision. Open questions close the page, each
with a recommended answer, its resolver and the point by which it must be
decided.

## OD1: One specification, referenced by its consumers (accepted)

**Question.** Observation touches the task DAG, the build graph, `apps/ci`,
Event Horizon and the test runner. Where does its contract live?

**Alternatives.**

- A section in each consumer's specification.
- One specification that owns the metric set, the records, the history and the
  gate, with each consumer linking to it for its obligations.

**Choice.** One specification in `docs/specs/build-primitives/observability/`.
The task-DAG, build-graph, `apps/ci` and test-runner specifications reference
it, and each requirement family names its owning package (SPEC §2).

**Revisit when** a family gains a consumer outside this repository, which
would justify a package specification of its own.

## OD2: History lives on an orphan branch of this repository (accepted)

**Question.** Where do run records from CI and from developers' machines meet,
so that a fresh checkout can compare and chart without local history?

**Alternatives.**

- **A hosted database or object store.** Needs credentials, an account and a
  service nobody else maintains; a fresh checkout cannot read it without them.
- **CI artifacts only.** They expire after 90 days, need the API to list, and
  hold nothing from developers' machines.
- **A separate repository.** Separates permissions cleanly, but adds a second
  remote to clone and keep in step.
- **`git notes` on `main`'s commits.** They attach naturally to a commit, but
  concurrent writers conflict on one ref and need custom merge logic.
- **An orphan branch, `perf-data`, in this repository.**

**Choice.** The orphan branch. Its layout is one directory per run, sharded by
date, so concurrent appends touch disjoint paths and never conflict (SPEC
OBH1–OBH3). `ci perf` reads it through a partial clone, fetching only the blobs
it needs (OBH9).

**Trade-offs.**

- **Clones pay for it.** An ordinary clone fetches every branch, so every
  clone downloads the history. Compaction bounds its packed size at 256 MiB
  (OBH7), and the contributor documentation names a negative refspec,
  `^refs/heads/perf-data`, that leaves it out. Q7 asks whether a ref outside
  `refs/heads/` is preferable.
- **The server keeps what compaction drops** until GitHub collects
  unreachable objects, on its own schedule. Spike S6 measures it.
- **Forged history.** Anyone who can push to the branch can forge history.
  Records are validated as untrusted input, the branch holds no code, and
  only the App and the maintainers may push (OBH2, OBH5, OBH8).

**Revisit when** the compacted branch approaches its bound, or the repository
gains contributors whose pushes cannot be trusted with it.

## OD3: The gate reads instructions retired only (accepted)

**Question.** Which metric may fail a comparison?

**Alternatives.**

- Wall time, with repetitions and a statistical test.
- CPU time.
- User-mode instructions retired, with a noise threshold.

**Choice.** Instructions retired. Wall time, CPU time and memory are
informational. Where the counter is unavailable, the series is not gated and
the reason is reported (OBG6).

**Evidence.** The test runner's measurement layer separates quantitative
counters from timings for the same reason
([test runner §1](../../test-runner/SPEC.md#_1-overview)). Repeating every CI
action to make wall time significant would multiply CI's cost.

**Trade-offs.** On a host without a usable PMU nothing is gated. Instructions
do not see a regression that adds waiting rather than work, such as a lock or
an I/O stall; the stall family and the `stalled` mark show those (OBA6).

**Revisit when** spike S1 shows that CI's hosted runners expose no counters, so
that no gate runs in CI; see Q1.

## OD4: Delivery alongside the build graph's E3 (accepted)

**Question.** When is observation delivered relative to the build graph and the
`ci test` cutover?

**Choice.** The vocabulary, process-tree accounting, queue wait, the
measurement table and the cache family are built alongside build-graph E3,
whose actions and store they measure. Task-level wall time, CPU time, memory
and queue wait reach users with `apps/ci` M7, whose `ci test` writes the first
records, because Event Horizon's supervised runs already sample them. History
and the gate follow (PLAN.md).

## OD5: Local records are published only by `ci perf push` (proposed)

**Question.** How do developers' records reach `perf-data`?

**Alternatives.**

- **Automatic upload** after each run, opted into once in a configuration
  file. History grows fastest, but runs of dirty trees, half-finished
  experiments and loaded laptops are published with no moment for the
  developer to check what leaves the machine.
- **An explicit `ci perf push`.**

**Choice.** The explicit command. It is the moment the developer chooses to
publish; it refuses dirty trees by default and runs the privacy scan (OBH6).
Local records are marked `origin: local` and are never CI's baseline.

**Revisit when** local records become the main history of some platform, such
as a self-hosted macOS machine; then an opt-in for that machine is cheaper
than remembering to push.

## OD6: The vocabulary is a leaf package beside the in-binary packages (proposed)

**Question.** The build graph, the task DAG, Event Horizon, `apps/ci` and the
test runner must share one vocabulary (invariant 6). The test runner's catalog
types live in its in-binary harness, which may depend on no other repository
package. Where does the vocabulary go?

**Alternatives.**

- In `sparkles:base`, or in `sparkles:build-primitives`. The harness can
  depend on neither.
- Two copies: the harness keeps its catalog types and `apps/ci` translates.
  This is the drift invariant 6 forbids.
- A new leaf, `sparkles:metrics`, that depends only on `sparkles:metadata`,
  which itself depends on nothing, admitted beside the in-binary packages.

**Choice.** The leaf (OBV1–OBV2). The test runner's catalog types move into
it, and the process model's TRP1 is amended to admit the two packages. Event
Horizon's `MetricQuality` is replaced by the vocabulary's quality (OBV9), so
Event Horizon depends on the leaf too. The leaf distinguishes recorded metrics,
which run records store as integers, from derived ones, such as `--bench`'s
ratios and rates, whose names stay as the test runner's catalog contract fixes
them (OBV3).

**Trade-offs.** The leaf cannot use `sparkles:base`'s buffers or text
writers: it holds descriptors and values, not rendering. It tests itself
without the shim, as the harness does.

**Revisit when** the test runner's in-binary rule changes.

## OD7: Records live outside the build store (proposed)

**Question.** Where are local records kept?

**Alternatives.**

- Beside the build store's results, in `$XDG_CACHE_HOME/sparkles/build/runs/`.
- In `apps/ci`'s run directory, `$XDG_CACHE_HOME/sparkles/ci/runs/<run-id>/`.
- In a directory of their own, `$XDG_CACHE_HOME/sparkles/perf/`.

**Choice.** A directory of their own (OBD12). The build store evicts by size
and holds content-addressed results only
([BGS5](../build-graph/SPEC.md#_6-the-shared-store)), and history must not be
evicted to make room for objects. The run directory holds task directories,
which are removed after reporting.

## OD8: The compiler summarizes its own time trace (proposed)

**Question.** A DMD time trace of one `sparkles:build-primitives` test-root
compile, at the frontend's default granularity of 500 µs, made it take about
21 s instead of 12.6 s and wrote 1.3 GB. How does a compile report where its
time went, on every run?

**Evidence.** The frontend's profiler, `dmd/timetrace.d`, which LDC and DMD
share, keeps every event above the granularity. For each kept event it
computes a name and details through `toChars` or `toPrettyChars`, and it takes
a memory-counter sample. D template instance names can run to kilobytes. A
coarser granularity keeps fewer events, but it also drops short events from
the totals, which hides growth spread over many small instantiations (OBC3).

**Alternatives.**

- **A coarse trace, reduced afterwards.** Works with any compiler. Its totals
  are lower bounds, and names are still computed for every kept event.
- **A summary mode in the frontend.** It times every event, aggregates per
  event type in place, keeps top-ten tables, and computes a name only for an
  event that enters one (OBC8). Memory stays bounded, totals are exact, and the
  output is a few kilobytes.

**Choice.** The summary mode, in the LDC fork's copy of the frontend, written
to be upstreamed to dlang/dmd, so that DMD gains it as well. A compiler without
it uses the reduced coarse trace. Spike S3 measures both against the budget
(OBO2), and a source that misses it is off by default (OBO3).

**Revisit when** upstream DMD ships an equivalent mode, or S3 shows that the
summary mode's clock reads exceed the budget, for example one per CTFE call.
The summary mode would then time CTFE per evaluated expression, not per call.

## OD9: Measurements are side outputs, outside every key (proposed)

**Question.** A compile's time summary differs on every run. How is it stored
without breaking reuse?

**Choice.** It is written to a measurement directory whose path normalization
replaces, stored as metadata of the result like the diagnostics, never
declared as an output, and under the Nix backend a separate derivation output
that backend agreement does not compare (OBD8). So the object's content
address is unchanged, a dependent never reads timing data, and two producers
of one result stay interchangeable. The build graph's BGA3, BGA6 and BGN5 are
amended to name the measurement directory.

## OD10: Series keys keep the compiler vendor, comparability keys the toolchain (proposed)

**Question.** A series must line up across runs and machines, keyed by task id
and variant key. The variant key includes the toolchain identity, so every
toolchain bump would start a new series. How are series and comparability
separated?

**Choice.** The series key replaces the toolchain identity by the compiler's
vendor (OBD2), so a bump continues the series while LDC and DMD builds stay
apart. The toolchain identity, the CPU, the operating system and the enabled
families form the comparability key (OBD3). History marks a bump as a change of
comparability key, and the gate never compares across one.

A test binary's own result key is not in the comparability key: a code change
changes the binary, and the comparison exists to measure exactly that.

## OD11: Noise is estimated from executions with equal inputs (proposed)

**Question.** A series' history mixes real changes with noise. How is noise
estimated from it?

**Alternatives.**

- The spread of the last N samples. It counts every real change as noise, so
  the threshold widens exactly where the code changes most.
- Repetitions at comparison time. They double CI's cost.
- The spread of differences between consecutive samples with equal inputs:
  the same input key and the same comparability key.

**Choice.** Differences between equal-input samples (OBG4). A difference of two
samples has the spread a base-against-head comparison sees, so `σ` needs no
correction. Groups of one sample contribute nothing, which avoids the bias of
deviations from a group's own median. The scaled median absolute deviation
resists the occasional outlier. Test actions re-execute on every run, and
compiles re-execute whenever a CI job starts from a cold store, so such pairs
accumulate without extra work. A multiplier of 5 leaves room for heavy tails and for the
estimator's error over a few dozen differences, and the A/A oracle checks the
rate it gives (OBG5, OBG9). A kind's prior covers new series of deterministic kinds; a new test
series is not gated until it has history.

**Revisit when** S2 shows that equal-input pairs are too rare for most compile
series, for example because CI's store stays warm.

## OD12: Four qualities, not three (proposed)

**Question.** The brief names three qualities: exact, lower bound and
unavailable. Are they enough?

**Evidence.** A hardware counter that the kernel time-shared with other events
returns a scaled count, which is neither exact nor a bound. The test runner
already labels such values as estimates
([test runner §6.3](../../test-runner/SPEC.md#_6-3-degradation-rules-normative)).

**Choice.** Exact, lower bound and estimate are qualities of a value, and
unavailable is the absence of a value, with a reason (OBV7–OBV8). An estimate
is never gated.

## OD13: Memory is three metrics, not one (proposed)

**Question.** The brief asks for peak tree RSS. What can each platform report
truthfully?

**Evidence.** The reaping call's `ru_maxrss` is the peak of the largest single
process, not of the tree. Event Horizon's sampler sums the tree's resident sets
at each tick, which misses peaks between ticks. The cgroup's `memory.peak`
includes page cache. Windows reports a job's peak committed memory, which is
not a resident set.

**Choice.** `task.rss.process`, `task.rss.tree` and `task.mem.cgroup`, plus
Windows' `task.mem.commit`, each defined by what its source measures. A single
"peak tree RSS" would mean a different thing on each platform.

## OD14: Platform counters with different meanings get different ids (proposed)

**Question.** Windows' process cycle time and macOS's `ri_instructions` are
counters too. Are they `task.cycles` and `task.instructions`?

**Choice.** No. Windows' process cycle time counts kernel and user cycles as
that call defines them, so it is `task.cycles.reference`. macOS's per-process
counters cover both modes of the root process only, so they are
`task.instructions.all` and `task.cycles.all`. Windows' I/O transfer counts
include pipes and devices, so they are `task.io.read-calls` and
`task.io.write-calls`, not storage reads. Only the Linux user-mode counters are
`task.instructions` and `task.cycles`, and only they are gated.

## OD15: Flakiness instead of retries (proposed)

**Question.** The brief asks for retries and flaky results per test binary.

**Evidence.** The test runner does not retry tests. It replaces a worker that
died during a test, and `ci` runs every package's tests in two legs, `-t 1` and
`-t N` ([CIC6](../../ci/task-dag/SPEC.md#_5-2-ordinary-package-tests-and-coverage)).

**Choice.** `binary.worker.restarts` counts replacements, and flakiness is
derived: a verdict that differs between the two legs of a run, or between runs
with equal input keys (OBT3).

## OD16: CI's records come from the run that validated the landed tree (proposed)

**Question.** `main` does not re-run CI when the landed tree equals the tree a
pull request or merge-queue run built; the mirroring job copies its checks.
Which run's records describe a `main` commit?

**Choice.** The validating run's, appended by the job that establishes
`main`'s checks: from that run's artifacts on the mirror path, and by the
rebuilt run itself on the rebuild path (OBH4). Pull request runs never append,
so `perf-data` holds nothing from CI but `main`.

**Trade-offs.** The append right needs a credential that a pull request's
workflow cannot obtain. `GITHUB_TOKEN` cannot provide that, because every job
holding it is the same actor, and a ruleset bypass names actors, not
workflows. Hence the App, whose credentials live in an environment restricted
to `main` (OBH8). An environment restricts by ref, not by job, so review of
`main`'s workflows keeps the credential to the two jobs that need it, and the
appending job lives in `main-checks.yml`, never in `ci.yml`, which also runs for
pull requests and the merge queue. Maintainers stay on the ruleset's bypass
list for fast-forward updates, so that `ci perf push` works with their own
credentials.

## OD17: ELF first for object and link analysis (proposed)

**Question.** Object and link analysis needs a reader per object format and a
report from each linker.

**Choice.** The contract covers ELF, Mach-O and COFF, and `ld.lld` and
`lld-link`. ELF and `ld.lld` are delivered first, because every gated CI leg
is Linux; the others report absences with reason `format` or `toolchain` until
their milestone (PLAN O7).

## OD18: The metric set is accepted as a whole (accepted)

**Question.** Which metrics does observation cover?

**Choice.** The owner accepted the proposed set as a whole: every action, the
compile, archive and link families, tests, the whole run, and CI jobs (SPEC
§4–§9). Definitions, sources, qualities and overhead remain open to
refinement. An item that evidence shows cannot stay on within the overhead
budget (OBO1) is not dropped: it becomes off by default under OBO3, with the
measurement and the proposed change recorded here for the owner.

## Open questions

Unless a question says otherwise, its resolver is the owner.

- **Q1: The gate on hosted CI runners.** Affects OBG1, OBG6 and OBH4. Hosted
  virtual machines often expose no PMU to the guest, and some images set
  `perf_event_paranoid` above 2. If spike S1 confirms that, no CI comparison
  can gate. _Recommended:_ keep the rule; set `perf_event_paranoid` to 2 in the
  CI jobs that can; and add one self-hosted Linux runner with a PMU that runs
  the gated `ci test` leg for `main` and for pull requests. _Decide by_ O6.
- **Q2: Build-action task ids.** Affects OBD2 and build graph BGA8, which
  requires stable ids but not their form. _Recommended:_ BGA8 states the form
  `<kind>:<package>:<role>:<vendor>:<d>`, where `<d>` is the first twelve
  hexadecimal digits of the variant key with its toolchain identity replaced
  by the vendor, so that no id embeds a toolchain or a result key and two
  vendors' variants stay distinct in one graph. _Resolver:_ the build graph's
  owner. _Decide by_ E2, which exposes the ids.
- **Q3: The vocabulary package's name.** Affects OBV1. _Recommended:_
  `sparkles:metrics`. _Decide by_ O1.
- **Q4: Retention thresholds.** Affects OBD12 and OBH7. _Recommended:_ the
  stated defaults (detail 90 days, runs 365 days, 256 MiB), revisited when S6
  measures the branch's real growth. _Decide by_ O5.
- **Q5: Gating local comparisons.** Affects OBG3. _Recommended:_ `--gate` with
  `--local` compares two local runs of the same machine only, which is useful
  before pushing and never mixes machines. _Decide by_ O6.
- **Q6: Nix fetch figures before `ci` exists.** Affects OBJ2. The figures come
  from the build of `ci` itself. _Recommended:_ the workflow's setup step runs
  that build with Nix's internal-JSON log written to a file, and the job's `ci`
  run ingests the file through an option, so no shell script parses it.
  _Decide by_ O5.
- **Q7: A branch, or a ref outside `refs/heads/`.** Affects OBH1, OBH7 and
  OBH8. A ref such as `refs/perf/data` is not fetched by ordinary clones, but
  rulesets protect only branches and tags, so its push right could not be
  limited to the App. _Recommended:_ keep the branch, with the 256 MiB bound and
  the documented negative refspec. _Decide by_ O5.
