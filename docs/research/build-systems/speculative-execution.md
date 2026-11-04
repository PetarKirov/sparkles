# Speculative Execution (Theme)

A build system speculates when it starts work whose need the plan has not yet
established. That definition excludes most of what the catalog's systems call
speculation: Bazel's dynamic-execution strategy and Buck2's hybrid executor race
two executions of an action they already need, and BuildXL uses recorded runtimes
to order work it will run anyway. In this catalog, only Rattle bets on future
demand. This page separates the three mechanisms, records what their authors do
and do not claim, and says where "critical-path speculation" has no shipped
implementation to cite.

**Last reviewed:** November 3, 2026

> [!NOTE]
> **Catalog inference** marks a claim this page derives from the cited sources
> rather than one a source states. Where no system publishes a correctness or
> termination argument, the page says so instead of supplying one.

| Field      | Value                                                                                                  |
| ---------- | ------------------------------------------------------------------------------------------------------ |
| Category   | Theme — cross-cutting; no single system                                                                |
| Question   | When may a build start work before the plan demands it, and what makes the guess safe?                 |
| Mechanisms | previous-run replay; duplicate local/remote race; historical-duration priority                         |
| Systems    | Rattle, Bazel dynamic execution, Buck2 hybrid execution, BuildXL scheduler, CloudBuild                 |
| Vocabulary | [concepts] — _scheduler_, _rebuilder_, _trace_, _minimality_ and _early cutoff_ are not redefined here |

**Built from (in-corpus):** [concepts] (§2, §5), [a-la-carte] (the grid has no
speculation axis), [perfect-dependencies] (Rattle's hazard and speculation
model), [rattle] (the implementation's test and restart path), [bazel] (§6),
[buck2] (§2), [buildxl] (§1), [ninja], [pants], [redo] (absence findings),
[dynamic-deps-distributed], [sandboxing-overheads] and [index].

## Overview

A build cannot beat its critical path:

> "The critical path is the theoretical lower bound for the duration of a
> build, which are the slowest set of actions."
>
> — Buck2 [`docs/concepts/architecture.md`][buck2-arch]

Speculation attacks that bound from the side: if a worker is idle and a future
action will need it, start the action early and hide its latency behind required
work. It pays only where the scheduler cannot see the future action in time — a
forward system with no graph (Rattle), a discovery boundary of unknown shape, or
two executors whose relative speed varies per action (Bazel, Buck2). **Catalog
inference:** with a static DAG and homogeneous workers, ordinary ready-queue
parallelism already reaches the bound.

### The key distinction: unknown demand versus unknown inputs

"Critical-path speculation" is ambiguous in a stronger sense than the three
mechanisms below suggest. In a fully materialised static DAG, every future
task and every edge is already known. A descendant on the critical path
cannot start early merely because it is important: its inputs do not exist.
The scheduler can prioritise its ancestors, reserve resources, prefetch cache
entries, or choose a faster executor, but those are scheduling and placement
decisions, not speculative execution of the descendant. True demand
speculation needs a point where the future work is _not yet known_:

- a sequential build script whose future commands have not been issued
  (Rattle);
- a conditional or dynamically discovered graph whose branch is unresolved;
- a generated dependency or output whose contents are predicted before the
  producer finishes; or
- a cache/materialisation decision where bytes may be fetched before demand
  is certain.

That is why the apparent literature gap is partly conceptual, not merely an
unimplemented optimisation. Once a build system has a static DAG plus
duration estimates, "speculate on the critical path" collapses into
critical-path _priority_. The interesting research problem is speculation at
discovery boundaries, where the system predicts work or input values it has
not yet proved necessary.

Three mechanisms share the word:

| Mechanism                         | Need established? | What is duplicated                      | Prediction required        | Recovery                                                                    |
| --------------------------------- | ----------------- | --------------------------------------- | -------------------------- | --------------------------------------------------------------------------- |
| Speculation                       | **no**            | future work, maybe never used           | next commands / hazard set | discard, or restart a phase                                                 |
| Duplicate execution               | yes               | the same action, twice                  | none                       | cancel the loser                                                            |
| Prediction as priority            | yes               | none                                    | durations, for ordering    | none — it was going to run anyway                                           |
| Input/value speculation           | inputs unproven   | downstream work under a predicted input | output/content prediction  | discard if the predicted bytes differ; **no surveyed build implementation** |
| Speculative fetch/materialisation | maybe             | transferred or materialised bytes       | likely future demand       | evict/ignore unused bytes                                                   |

**Catalog inference:** a duplicate race is transparent only if both branches
compute the same bytes; true speculation must be able to un-run work. Rattle
states the bet:

> "we can use implicit parallelism, where some commands are executed
> speculatively, before they are required by the build script, in the hope that
> they will be executed by the script in the future and thus skipped by the
> build system."
>
> — Rattle paper §2.8 ([perfect-dependencies])

## How it works

### 1. Replay the previous run — Rattle

Rattle has no graph to schedule, so a straight-line script would run serially.
Its predictor is the previous run's `required` list, stored under
`speculate/<hash>` and reloaded through `rattleSpeculate` ([rattle]
§Speculation). A command is eligible when it has not run this build, was required
last time, and does not conflict with completed commands or with the _predicted_
accesses of running ones — the last clause lets the engine guess more than one
step ahead. The predictor is deliberately minimal: it assumes the next run
repeats the last one ([perfect-dependencies] §2.8).

Two details are more conservative than the prose: the candidate list is truncated
at the first command with no previous trace, so an edited script makes the next
cold build serial; and speculation starts only when `rattleProcesses > 1`
([rattle] §Speculation). A speculative command's failure is discarded; whoever
later requires it sees the error.

Safety is a hazard check, not a lock. Two writes are `NonRecoverable` when both
commands were required and `Restartable` when one was speculative; a
read-before-write is `Recoverable` if the reader guessed and `Restartable` if the
writer did; write-before-read is safe unless the reader was required and the
writer speculative ([rattle] §Hazards). A hazard resets the run with
`speculatable = []` and reruns the whole build without speculation;
`NonRecoverable` is rethrown. Traces commit only after every command running when
one finished has also finished, so a hazard cannot be recorded as clean
([rattle] §Rebuilding). The one case with no clean recovery is a speculative
write to an _input_ — restarting does not restore the bytes
([perfect-dependencies] §4.3). **Catalog inference:** Rattle's predictor is a
_set of commands_, not a critical-path model; it replays the author's previous
order, not the longest chain.

### 2. Race work already required — Bazel and Buck2

Bazel's dynamic execution is an execution strategy over a known action graph.
`DynamicSpawnStrategy` starts a `LocalBranch` and a `RemoteBranch` for the same
`Spawn`, waits for the first, and cancels the other ([bazel-strategy],
[`Branch.java`][bazel-branch]); `--strategy=<mnemonic>=dynamic` selects it per
mnemonic ([bazel-options]). Both branches execute the _same, already scheduled_
action, so no future need is guessed. The docs state the resource precondition
plainly: the approach assumes enough local and remote capacity that spending
extra resources improves overall time ([bazel-dynamic]).

`--dynamic_local_execution_delay` (default 1000 ms) holds the local branch back
after a remote cache hit ([bazel-options]). Failure is deliberately fatal: if the
first branch to finish fails, the action fails "to prevent differences between
local and remote execution from going unnoticed" ([bazel-dynamic]). Buck2's
hybrid executor shares the shape with an explicit claim protocol: whichever
executor claims the request runs it, and a remote claim that fails is requeued
locally ([buck2-hybrid]).

Buck2 exposes `Limited` (preferred executor only), `Fallback` and `Full` (race),
so the race is opt-in per target ([`executor_config.rs`][buck2-config]). Both
engines are **placement** mechanisms: the dependency edge decided the action was
needed; only its executor is in doubt ([dynamic-deps-distributed] §Dynamic
execution).

### 3. Predict, but only reorder — BuildXL and CloudBuild

BuildXL contributes the prediction half without the duplication. Its scheduler
is a ready-set over a static DAG; each pip's expected runtime is estimated from
its declared input/output count, summed with everything downstream, and used as
priority. The document is explicit that this includes downstream work — "the
expected runtime for a pip will contain the expected runtime for all downstream
pips" — and that the value is "static once assigned at the beginning of the
execute phase" ([bxl-sched-prio]).

After a build, actual runtimes are serialized and pushed into the cache, so
later builds — including builds on other machines sharing the datacenter
cache — use history instead of the heuristic. The document names the
limitation: "This of course wouldn't work well if the machines putting to the
cache were not homogeneous" ([bxl-sched-prio]).

The research side is a Microsoft line of work around CloudBuild. Tufano, Sajnani
and Herzig describe a model that predicts a change's effect on the longest path:

> "we describe an approach that analyzes the developer's change and predicts (i)
> whether it impacts (any of) the Longest Critical Path; (ii) may lead to build
> time increase and its delta; and (iii) the percentage of future builds that
> might be affected by such change."
>
> — Tufano et al., ICSE-NIER 2019 ([tufano], [tufano-arxiv])

It is a four-page vision paper: the deliverable is an alert, not a dispatch
decision. CloudBuild, its production context, explicitly tolerates messy inputs:
"It aims to rapidly onboard teams and hence has to support non-deterministic
build tools and specification languages that under-declare dependencies"
([cloudbuild]). **Catalog inference:** that tolerance cuts against speculation,
because under-declaration weakens the basis for predicting the next command or
its effect.

### 4. What the literature does not contain

Search boundary, 2 November 2026: arXiv returns exactly one paper for
`all:"build system" AND all:"speculative"` — the Rattle paper — and none for a
title search combining `speculative` with `build` or `compilation` in a
build-engine sense. Crossref queries for speculative build systems and for
critical path plus build surface CPU critical-path prediction, CloudBuild and
Tufano et al., but nothing that predicts per-action durations and then starts
unneeded actions.

**Catalog inference:** "critical-path speculative execution from historical
traces" therefore has no surveyed implementation. Its components exist
separately — a predictor (BuildXL's history, Rattle's previous run), a
critical-path notion (Buck2's definition, BuildXL's priority) and a dispatch
mechanism (Bazel's and Buck2's races) — but no system joins them to start work
whose need is unproven.

The absence is also a finding: Ninja queues only ready edges and has "no
speculation" ([ninja] §1), build2 is demand-driven but not speculative
([build2] §1), and redo's `--shuffle` exposes missing dependencies rather than
guessing ([redo] §1). Pants' "speculative cleaning" runs dependency _checks_ in
parallel ([pants] §2), and BuildXL's priority predicts _ordering_, not permission
to start.

### What a critical-path-aware static scheduler actually does

Bazel illustrates the non-speculative end state. Its critical-path machinery
in the open-source tree is profiler output: `CriticalPathText` prints total
and optimal paths from a completed build, and the JSON trace writer creates a
synthetic "Critical Path" thread for display ([bazel-critpath]). That diagnoses where time went;
it does not feed a historical-duration dispatch loop in the surveyed sources.
BuildXL goes one step further by using estimated and historical durations as
priority, but still starts only ready pips. Neither crosses into executing a
task before its dependencies complete.

This is not a missing trick. If durations are known and resources are finite,
the correct use of a critical path is precedence-aware list scheduling:
among ready tasks, run those with the longest estimated path to a sink first,
subject to resource claims. Starting a non-ready descendant would require
inventing its inputs. The research gap is therefore better named
**speculation across unresolved graph/input discovery**, not critical-path
speculation in a static DAG.

## When speculation pays

For demand speculation, the expected value has to survive an accounting the
surveyed papers rarely make explicit:

```text
P(command is eventually required) x latency hidden by starting early
- P(not required) x full resource cost
- delay imposed on required ready work while resources are occupied
- invalidation/restart cost when the guess conflicts
- extra cache, transfer, and tracing work
```

Idle capacity makes the second term look free, but only until the speculative
task occupies memory bandwidth, disk, a remote slot, or a lock that required
work needs. Duplicate execution has a different equation: demand is certain,
so the cost is the duplicate attempt and the benefit is bounded by executor
latency variance and queueing. A predictor that only reorders ready tasks has
near-zero downside except a worse order.

The mechanisms spend different resources: a hazard can discard Rattle's whole
run, a race spends one duplicate action and its transfer, and priority spends
nothing but needs history. Rattle's numbers are the only per-system evidence in
the catalog for speculation's own cost: in its controlled `gcc` benchmark a
whitespace edit takes 1.12 s against Make's 2.19 s, while in the real-project
replay Node.js at 32 threads stays at 92–93 minutes against Make's 4.8 because
every command is reconsidered ([perfect-dependencies] §5). Bazel and Buck2
publish no wall-clock numbers in the cited docs, only the resource argument
([bazel-dynamic]); **catalog inference:** a race is wasteful in proportion to the
variance it absorbs, so it fits actions whose remote latency is transfer- or
queue-dominated.

## Correctness and termination, as published

| System         | Published claim                                                                                     | Holds when                                                     | Not claimed                                            |
| -------------- | --------------------------------------------------------------------------------------------------- | -------------------------------------------------------------- | ------------------------------------------------------ |
| Rattle (paper) | six claims: completeness, unchanging, reordered, parallel, additional commands, hazard preservation | deterministic commands, complete traces, disjoint reads/writes | a proof; recovery from a speculative write to an input |
| Rattle (Agda)  | sequential Rattle sound and complete; speculative Rattle only **partially** correct                 | the speculative build is a permutation of the script build     | total correctness for the implementation               |
| Bazel          | no correctness claim for the race; first failure fails the action                                   | both branches compute equivalent results                       | transparency for non-deterministic actions             |
| Buck2          | claim protocol plus remote-failure fallback; no theorem                                             | one executor claims; a failed remote result is re-queued       | race-level correctness or termination                  |
| BuildXL        | prediction affects order only                                                                       | the DAG and ready-set are unchanged                            | any speculation-specific guarantee (there is none)     |

Rattle's formal treatment does **not** prove what the abstract advertises:

> "we prove that these optimizations, as embodied in the recent forward build
> system Rattle, preserve our definition of correctness."
>
> — Spall, Mitchell & Tobin-Hochstadt, CPP 2022, abstract ([fbsf-arxiv])

The body narrows it: sequential Rattle is proved sound and complete, but the
total-correctness lemma for speculation is stated and left unproved — "We cannot
prove this lemma for the current implementation of Rattle" ([fbsf-arxiv], Figure 7) —
because the implementation can speculate a command no longer in the script, or
whose dependencies changed. The authors prove _partial_ correctness instead,
where a hazard caused by speculation is acceptable, and report finding a bug in
Rattle's hazard computation during the proof ([fbsf-arxiv] §6.4). **Catalog
inference:** the burden is not the reordering — a hazard-free permutation is
provably equivalent — but the predictor's right to add commands the script no
longer contains.

For Bazel and Buck2 the race is correct only if the branches are interchangeable.
Both assume hermetic, deterministic actions ([bazel] §2, §5), and the documented
failure rule catches a branch that _fails_, not two successes that differ.
**Catalog inference:** a non-deterministic action makes the race observable —
whichever branch wins decides the bytes — and both results key under the same
action digest. Termination is per action: Bazel cancels the loser, Buck2 requeues
a failed remote claim, and neither adds nodes. Rattle terminates because the
candidate list is one previous run and recovery drops it. No surveyed system
combines speculation with graph growth, which is why [dynamic-deps-distributed]
treats discovery and placement as separate axes.

## Analysis spine

### 1. Task model & scheduling

Speculation is orthogonal to [concepts]'s three schedulers. Rattle's scheduler
is a fourth kind — the author's total order weakened by guesses — and off
[a-la-carte]'s grid entirely; Bazel stays restarting × constructive, with the
race below the scheduler; BuildXL stays a ready-set with a priority function.
**Catalog inference:** the grid has no axis for "may start before needed", which
is why no cell describes Rattle.

### 2. Rebuilding, discovery & caching

Rattle defers trace commits until concurrent commands finish, so a stored trace
cannot be invalidated by a still-running writer ([rattle] §Rebuilding). Bazel and
Buck2 must not record the loser's result; their branch and claim machinery exists
for that ([bazel-branch], [buck2-hybrid]). Rattle's predicted reads are the
previous run's `Touch` set minus `/dev/` entries, directory paths and `Ignored`
matches ([rattle] §Tracing); a missed access is exactly what makes a guess unsafe
([sandboxing-overheads]). Its file store is content-addressed by SHA-256, and its
traces are keyed by command line, so a speculative output is just another blob
([rattle] §Store), while BuildXL's history travels through the cache, making
heterogeneous workers a hazard ([bxl-sched-prio]). **Catalog inference:** key a
speculative result on content or action, never on "this task was required".

### 3. Hermeticity, provenance & distribution

An unrecoverable speculative write is a hermeticity failure, not a scheduling
one. Rattle's only clean recovery is to restart; remote execution would remove
the hazard class because speculative writes would land in a sandbox
([perfect-dependencies] §6.2). The only shipped speculation-adjacent execution is
itself a distribution feature — the local/remote race ([bazel-dynamic],
[buck2-hybrid]). **Catalog inference:** distribution makes duplication cheap
(spare workers) and a wrong guess expensive (a remote slot and a round trip);
none of the cited mechanisms records whether a start was demanded or guessed, so
an attestation that "this action ran" cannot distinguish them, and the event
stream should tag speculative starts if the mechanism ever ships.

### 4. Sparkles relevance

`sparkles.build_primitives.task` has what a speculation policy would need to
_check_, and nothing it would need to _decide_. The model carries `TaskNode`,
`TaskEdge` with `EdgeCondition` and `EdgeReason`, and a `ResourceClaim` with
`jobsWeight`, `exclusiveKeys` and `memoryHintBytes`
(`libs/build-primitives/src/sparkles/build_primitives/task/model.d`).
Admission is deterministic: "ready tasks are considered in presentation order —
the graph's index order, by `PresentationKey` then `TaskId`. A task starts when
its exclusive keys are free and its weight, clamped to the capacity, fits"
(`libs/build-primitives/src/sparkles/build_primitives/task/executor.d`).
The `usage` sink is an event, not an admission input.

Three inputs are missing: a predictor (no previous-run record), a safety check
over undeclared accesses (a driver can write anything), and a recovery rule for a
guess that is never required. More fundamentally, a validated static DAG has
little for demand speculation to do: every required node is already in the
plan, and a node whose dependencies have not completed cannot be started
without inventing inputs. What Sparkles should borrow first is therefore
**critical-path priority**: an estimated longest-path-to-sink ordering for
ready tasks, informed by recorded durations. A speculative lane only becomes
coherent if graph construction later gains conditional/discovered edges; then
it should run a predicted not-yet-demanded node only under declared
non-conflicting resource keys, tag the execution as speculative, and discard
or restart it if the resolved graph never asks for it — Rattle's hazard
predicate without pretending that ordinary ready-task reordering is
speculation.

Borrow the disposition taxonomy first: a conflict between two required tasks is a
specification bug and should fail, while a conflict involving a guessed task is a
scheduling artifact and should be dropped — `FailurePolicy` classifies outcomes,
not conflicts ([perfect-dependencies] §7). Do not borrow the name for parallel
_checking_: Pants' speculative cleaning is a cancellation pattern ([pants] §2).

## Strengths

- **Speculation recovers parallelism a forward system gave up.** Rattle's tracing
  gives content-level early cutoff — a whitespace edit costs one compile — and
  the guess restores the script's parallelism; its safety model is small enough
  to formalize, and the Agda model found a real bug in it
  ([perfect-dependencies] §5, [fbsf-arxiv] §6.4).
- **Duplicate execution needs no predictor.** It requires spare capacity and
  deterministic actions, both of which Bazel and Buck2 already assume
  ([bazel-dynamic], [buck2-hybrid]) — while BuildXL gets the cheap prediction
  half without ever starting unneeded work ([bxl-sched-prio]).

## Weaknesses

- **True speculation has one implementation and no scale story.** Rattle has one
  speculation key, no eviction, linear rebuild, a measured cold-build loss, and a
  correctness result that is only partial ([rattle] §Maturity,
  [perfect-dependencies] §5.8, [fbsf-arxiv] §6.1).
- **Nobody has joined prediction to dispatch.** The critical-path literature
  advises developers, schedulers reorder, and the one speculative engine replays
  a set.

## Key design decisions and trade-offs

| Decision                                     | Rationale                                                 | Trade-off                                                                |
| -------------------------------------------- | --------------------------------------------------------- | ------------------------------------------------------------------------ |
| Predict from the previous run, not a model   | No training, no duration estimate, robust to tool changes | One cold build per script change; no critical-path notion                |
| Hazard-check every guess                     | Reordering is safe exactly when no conflict exists        | Needs predicted accesses; a miss is silent                               |
| Restart without speculation on a hazard      | Provably the sequential baseline; trivial to implement    | Discards work; a speculative input write is unrecoverable                |
| Race local and remote (Bazel, Buck2)         | No predictor; adapts per action                           | Double resources; first failure fails the action; needs remote execution |
| Require spare capacity for the race          | The win is latency hiding, not throughput                 | Wasteful under contention; the docs say so                               |
| Keep history-based priority static (BuildXL) | One pass at execute start; no feedback loop               | Cannot react mid-build; assumes homogeneous workers                      |

## Sources

- Rattle: Spall, Mitchell & Tobin-Hochstadt, _Build Scripts with Perfect
  Dependencies_, OOPSLA 2020 — [DOI][rattle-doi], local PDF
  `$REPOS/papers/build-systems/spall-2020-build-scripts-perfect-dependencies-oopsla.pdf`;
  [`ndmitchell/rattle`][rattle-repo] at
  `3c935ca004ec8557ad6edb92d42f8bdf5bc78f46`. Formal treatment: same authors,
  _Forward Build Systems, Formally_, CPP 2022 — [DOI][fbsf-doi],
  [arXiv:2202.05328][fbsf-arxiv] (§5 sequential proof; §6 partial correctness
  and the unproved lemma).
- Bazel `2105aec32b598dcc8e09905e7cf18ccfa4b0358e`, Buck2
  `08b403b138373f506de90d15370162677526e388` and BuildXL
  `ea34998661867b5959d7f496f8b5650611a3e446`; files are linked inline and
  clones live under `$REPOS/build-systems-research/src/`.
- Tufano, Sajnani & Herzig, ICSE-NIER 2019 — [DOI][tufano],
  [arXiv:1901.07142][tufano-arxiv] (vision paper, no dispatch evaluation).
  CloudBuild: Esfahani et al., ICSE-C 2016 — [DOI][cloudbuild].
- Mokhov, Mitchell & Peyton Jones, JFP 30, e11 (2020) — [DOI][jfp]; its local PDF
  has no "speculat" occurrence and mentions "critical path" only as a metric.
- The search boundary is in [§4](#4-what-the-literature-does-not-contain); the
  in-corpus pages are in the _Built from_ line and the references below.

<!-- References -->

[concepts]: ./concepts.md
[a-la-carte]: ./a-la-carte.md
[perfect-dependencies]: ./perfect-dependencies.md
[rattle]: ./rattle.md
[bazel]: ./bazel.md
[buck2]: ./buck2.md
[buildxl]: ./buildxl.md
[ninja]: ./ninja.md
[pants]: ./pants.md
[redo]: ./redo.md
[build2]: ./build2.md
[dynamic-deps-distributed]: ./dynamic-deps-distributed.md
[sandboxing-overheads]: ./sandboxing-overheads.md
[index]: ./index.md
[jfp]: https://doi.org/10.1017/S0956796820000088
[rattle-doi]: https://doi.org/10.1145/3428237
[fbsf-doi]: https://doi.org/10.1145/3497775.3503687
[tufano]: https://doi.org/10.1109/ICSE-NIER.2019.00021
[cloudbuild]: https://doi.org/10.1145/2889160.2889222
[rattle-repo]: https://github.com/ndmitchell/rattle/tree/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46
[fbsf-arxiv]: https://arxiv.org/abs/2202.05328
[tufano-arxiv]: https://arxiv.org/abs/1901.07142
[bazel-dynamic]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/docs/remote/dynamic.mdx
[bazel-strategy]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/src/main/java/com/google/devtools/build/lib/dynamic/DynamicSpawnStrategy.java
[bazel-options]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/src/main/java/com/google/devtools/build/lib/dynamic/DynamicExecutionOptions.java
[bazel-branch]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/src/main/java/com/google/devtools/build/lib/dynamic/Branch.java
[bazel-critpath]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/src/main/java/com/google/devtools/build/lib/profiler/output/CriticalPathText.java
[buck2-arch]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/docs/concepts/architecture.md
[buck2-hybrid]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/app/buck2_execute_impl/src/executors/hybrid.rs
[buck2-config]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/app/buck2_core/src/execution_types/executor_config.rs
[bxl-sched-prio]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Documentation/Wiki/Advanced-Features/Scheduler-Prioritization.md
