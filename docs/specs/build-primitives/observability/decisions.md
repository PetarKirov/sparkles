---
status: draft
owner: sparkles:build-primitives
reviewed: 2026-11-06
---

# Observability — Decisions

Each record states its question, the alternatives, the choice and when to
revisit it. Records marked **accepted** were decided by the owner on
2026-11-06: OD1–OD4 in the brief that commissioned this specification, OD18
after its first review, and OD5–OD17, OD19 and OD20 when the owner answered
the review's questions. Records marked **proposed** await the owner's decision,
and a record marked **superseded** names the record that replaced it. Open questions close the page, each
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

## OD2: History lives on an orphan branch of this repository (superseded)

_Superseded by [OD19](#od19-history-lives-on-refs-perf-data-accepted). The
record is kept as the owner's first choice and its reasons._

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

_Refined by [OD20](#od20-hosted-runners-without-counters-gate-on-user-cpu-time-accepted),
which adds a CPU-time gate where hosts have no counters._

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

## OD5: Local records are published only by `ci perf push` (accepted)

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

## OD6: The vocabulary is a leaf package beside the in-binary packages (accepted)

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

## OD7: Records live outside the build store (accepted)

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

## OD8: The compiler summarizes its own time trace (accepted)

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

## OD9: Measurements are side outputs, outside every key (accepted)

**Question.** A compile's time summary differs on every run. How is it stored
without breaking reuse?

**Choice.** It is written to a measurement directory whose path normalization
replaces, stored as metadata of the result like the diagnostics, never
declared as an output, and under the Nix backend a separate derivation output
that backend agreement does not compare (OBD8). So the object's content
address is unchanged, a dependent never reads timing data, and two producers
of one result stay interchangeable. The build graph's BGA3, BGA6 and BGN5 are
amended to name the measurement directory.

## OD10: Series keys keep the compiler vendor, comparability keys the toolchain (accepted)

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

## OD11: Noise is estimated from executions with equal inputs (accepted)

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

## OD12: Four qualities, not three (accepted)

**Question.** The brief names three qualities: exact, lower bound and
unavailable. Are they enough?

**Evidence.** A hardware counter that the kernel time-shared with other events
returns a scaled count, which is neither exact nor a bound. The test runner
already labels such values as estimates
([test runner §6.3](../../test-runner/SPEC.md#_6-3-degradation-rules-normative)).

**Choice.** Exact, lower bound and estimate are qualities of a value, and
unavailable is the absence of a value, with a reason (OBV7–OBV8). An estimate
is never gated.

## OD13: Memory is three metrics, not one (accepted)

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

## OD14: Platform counters with different meanings get different ids (accepted)

**Question.** Windows' process cycle time and macOS's `ri_instructions` are
counters too. Are they `task.cycles` and `task.instructions`?

**Choice.** No. Windows' process cycle time counts kernel and user cycles as
that call defines them, so it is `task.cycles.reference`. macOS's per-process
counters cover both modes of the root process only, so they are
`task.instructions.all` and `task.cycles.all`. Windows' I/O transfer counts
include pipes and devices, so they are `task.io.read-calls` and
`task.io.write-calls`, not storage reads. Only the Linux user-mode counters are
`task.instructions` and `task.cycles`, and only they are gated.

## OD15: Flakiness instead of retries (accepted)

**Question.** The brief asks for retries and flaky results per test binary.

**Evidence.** The test runner does not retry tests. It replaces a worker that
died during a test, and `ci` runs every package's tests in two legs, `-t 1` and
`-t N` ([CIC6](../../ci/task-dag/SPEC.md#_5-2-ordinary-package-tests-and-coverage)).

**Choice.** `binary.worker.restarts` counts replacements, and flakiness is
derived: a verdict that differs between the two legs of a run, or between runs
with equal input keys (OBT3).

## OD16: CI's records come from the run that validated the landed tree (accepted)

**Question.** `main` does not re-run CI when the landed tree equals the tree a
pull request or merge-queue run built; the mirroring job copies its checks.
Which run's records describe a `main` commit?

**Choice.** The validating run's, appended by the job that establishes
`main`'s checks: from that run's artifacts on the mirror path, and by the
rebuilt run itself on the rebuild path (OBH4). Pull request runs never append,
so the history holds nothing from CI but `main`.

**Trade-offs.** Nothing on the server stops a pull request's workflow, or
anyone with write access, from pushing to `refs/perf/data` (OD19). What a
pull request cannot obtain is the CI signing key, which lives in an environment
restricted to `main`, and readers trust only signed commits (OBH8). An
environment restricts by ref, not by job, so review of `main`'s workflows keeps
the key to the two jobs that need it, and the appending job lives in
`main-checks.yml`, never in `ci.yml`, which also runs for pull requests and the
merge queue.

## OD17: ELF first for object and link analysis (accepted)

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

## OD19: History lives on `refs/perf/data` (accepted)

**Question.** OD2 put the history on an orphan branch, `perf-data`. Every
ordinary clone fetches every branch, and the branch appears in the
repository's branch lists. Is a branch the right home?

**Alternatives.**

- **The branch**, bounded by compaction, with a negative refspec documented for
  contributors who want to leave it out.
- **A ref outside `refs/heads/` and `refs/tags/`**, `refs/perf/data`, which
  ordinary clones and fetches never download and no branch list shows.

**Choice.** `refs/perf/data`, decided by the owner on 2026-11-06, superseding
the branch of OD2 so that clones stay small and no branch clutters the
repository's interface. `ci perf fetch` and every lazy read fetch the ref
explicitly with `--filter=blob:none`, and `ci perf push` and CI's appending job
push to it with the same conflict-free `mktree` append (OBH1–OBH10).

**Evidence.** GitHub documents three kinds of ruleset: branch, tag and push.
Branch and tag rulesets select branches and tags by name pattern; push
rulesets restrict file paths, extensions and sizes, and can be created only for
private and internal repositories
([creating rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository),
[the rulesets REST API](https://docs.github.com/en/rest/repos/rules?apiVersion=2022-11-28)).
No documented ruleset protects a ref such as `refs/perf/data`, and this
repository is public. So nothing on the server limits updates, rewinds or
deletion of the ref beyond write access to the repository. Spike S7 confirms
that GitHub accepts, keeps and serves the ref, including to partial fetches,
and that a push to it starts no workflow.

**Consequence.** The App and the rulesets of the branch design are dropped.
Integrity moves to the readers: every commit is signed with a key from an
allowed-signers file on `main`, readers ignore and report unsigned additions,
and a rewind is believed only when it is a signed compaction (OBH8). The
negative-refspec advice is no longer needed.

**Revisit when** GitHub offers rulesets for arbitrary refs, which would put
the push right back on the server.

## OD20: Hosted runners without counters gate on user CPU time (accepted)

**Question.** OD3 gates on instructions retired only. GitHub's hosted runners
are virtual machines that may expose no PMU, in which case no CI comparison
could gate. What gates there?

**Choice.** Decided by the owner on 2026-11-06, refining OD3. Test first:
spike S1 checks whether hosted runners count user-mode instructions.

- **Where the host counts them**, the gate is instructions retired, as OD3
  decided.
- **On hosted runners that cannot**, the gate is user CPU time,
  `task.cpu.user`, with its own noise estimate and wider floors (OBG4–OBG5).
- **Developers' machines** gate on perf counters; one without them is not
  gated.

Each run records its gate metric (OBG1). A comparison states which gate it ran
under, and gates only when both sides share the metric; instructions from one
side are never compared with CPU time from the other (OBG10).

**Trade-offs.** CPU time on a shared virtual machine is far noisier than
instructions, so the CPU gate catches only large regressions. Its floors stay
uncalibrated, and the gate report-only, until S2 measures hosted-runner noise.

**Revisit when** hosted runners expose counters, or a self-hosted runner with a
PMU takes over the gated leg.

## Questions

Every question was resolved by the owner on 2026-11-06; each entry records the
answer and where the contract states it.

- **Q1: The gate on hosted CI runners.** Resolved on 2026-11-06 by OD20: test
  first with S1, and gate on user CPU time where hosted runners have no
  counters.
- **Q2: Build-action task ids.** Resolved on 2026-11-06, as recommended: a
  build action's task id is `<kind>:<package>:<role>:<vendor>:<d>`, where `<d>`
  is the first twelve hexadecimal digits of the variant key with its toolchain
  identity replaced by the compiler's vendor (OBD2). A toolchain bump keeps the
  series, and the comparability key tells the bump apart. The build graph
  adopts the form in BGA8 at E2.
- **Q3: The vocabulary package's name.** Resolved on 2026-11-06:
  `sparkles:metrics`.
- **Q4: Retention thresholds.** Resolved on 2026-11-06: 90 days of
  detail, 365 days of runs and 256 MiB, revisited after S6.
- **Q5: Gating local comparisons.** Resolved on 2026-11-06, as recommended:
  `--gate --local` compares only two local records of one machine, with equal
  host facts, and a local run compared with CI records is report-only (OBG3).
- **Q6: Nix fetch figures before `ci` exists.** Resolved on 2026-11-06, as
  recommended: the setup build writes Nix's `--log-format internal-json` log to
  a file, and the job's `ci` run ingests it through `--nix-log FILE` (OBJ2).
- **Q7: A branch, or a ref outside `refs/heads/`.** Resolved on 2026-11-06 by
  OD19: `refs/perf/data`.
