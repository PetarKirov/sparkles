---
status: draft
owner: sparkles:build-primitives
reviewed: 2026-11-01
---

# Task DAG — Delivery plan

_Companion to [SPEC.md](./SPEC.md). The milestone numbers continue those of
the [`apps/ci` task DAG plan](../../ci/task-dag/PLAN.md), where M1–M6 were
first delivered inside `apps/ci`. M3, the prerequisite gate, and every
command cutover belong to that plan._

Each milestone is independently green. Its gate names the commands and tests
that must pass.

## M1: Pure task vocabulary and graph validation

- Add `task/model.d` with `TaskId`, `TaskNode`, `TaskEdge`, `ResourceClaim`,
  outcomes, and events.
- Add `task/graph.d` with a builder, duplicate/unknown-edge checks, cycle
  detection, stable presentation order, and edge-condition resolution helpers.
- Add an action vocabulary sufficient for inert test actions and dry-run
  rendering. Do not execute commands yet.
- Unit-test graph validation, stable topological order, conditional edges,
  blocked propagation, id formatting, and associative-array-order independence.

Gate: `dub test :ci` and `dub build :ci` pass; existing CLI behavior is
unchanged; pure graph tests import neither Event Horizon nor UI modules.

Status: delivered. `libs/build-primitives/src/sparkles/build_primitives/task/action.d` holds the action vocabulary and
its redacting dry-run summary. `libs/build-primitives/src/sparkles/build_primitives/task/model.d` holds ids, keys,
claims, nodes, edges, pointer-free outcomes and events. `libs/build-primitives/src/sparkles/build_primitives/task/graph.d`
holds the builder, validation, stable topological order, edge resolution,
blocked propagation, and `writePlan`.

## M2: SDL-backed package graph and focused selectors

- Decode root and package `dub.sdl` files through the completed
  `sparkles.wired.sdl` backend; add package identities and configuration-aware
  in-tree dependency discovery.
- Implement exact/glob `--from` matching over short name, qualified name, and
  path.
- Implement `--since [REF]`, changed-path ownership, and the declarative global
  invalidator list.
- Implement dependency and dependent closure with fixed-point union semantics.
- Add selection reasons to the dry-run projection.
- Test union of `--from` and `--since`, deleted paths, root invalidators,
  both closures, empty matches, cycles, and platform-skipped seeds.

Gate: a test-only planner API can print deterministic selected package ids and
edges for fixture repositories; production commands still use the old executor.

Status: delivered. `libs/build-primitives/src/sparkles/build_primitives/workspace/package_graph.d` discovers the graph
through the `sparkles.build_primitives.dub_manifest` schema.
`libs/build-primitives/src/sparkles/build_primitives/workspace/select.d` holds the selection algebra, `gitChangesSince`
(through `runGit`), and the test-only planner `planPackages` with
`writeSelectionPlan`. `--from` globs use `gitGlobMatch`, which moved here from the deleted
`sparkles.build_primitives.gitignore`. No CLI option exists yet. Milestone W2 of the
[fileset-native workspace](../build-graph/fileset-native-workspace.md#_11-delivery-plan)
replaced changed-path ownership, the base revision's package map and the
invalidator list with selection by input-set claims over resolved requests
(TDS6 as amended).

## M4: Event Horizon executor core

- Add the `sparkles:event-horizon` dependency and lockfile changes in a dedicated
  preparation commit.
- Implement weighted admission, exclusive keys, ready-queue tie-breaking,
  conditional edge resolution, outcomes, and event publication.
- Use one `LoopGroup`, root scope, bounded event channel, and fake typed actions.
- Implement structured fail-fast and external cancellation with protected
  cleanup for in-process fixture tasks.
- Add deterministic tests with a fake clock/action driver for capacity,
  starvation resistance, claims larger than capacity, simultaneous failures,
  blocked propagation, and no admission after cancellation.

Gate: executor tests pass under `TestSched` or the deterministic action driver;
there is no child-process integration yet; existing production work remains on
the old path.

Status: delivered. `libs/build-primitives/src/sparkles/build_primitives/task/executor.d` holds `runGraph` and
`TaskExecutor`, generic over the fiber executor, clock, action driver
(`isActionDriver`), and event sink (`isEventSink`, the `Channel.put` shape). Its
tests run a fake driver under `TestSched` and `TestClock`. The `event-horizon`
dependency was already present, so no preparation commit was needed. The sink
is the intra-worker `Channel` until the cross-worker channel lands.

## M5: Event Horizon subprocess actions

- Implement `task/process.d` as the CI adapter over Event Horizon M19's
  supervised-process API, without reimplementing line assembly or process
  lifecycle policy.
- This adapter satisfies M19 item 6; later cutovers remove the old paths.
- Preserve argv boundaries and redact marked environment values in events and
  dry-runs.
- Implement bounded output memory with sandbox spill files.
- Route compiler thread caps and resource-usage observations through action
  metadata.
- Exercise exit, signal, timeout, large output, no-final-newline, descendant
  termination, cancellation races, and spawn failure.

Gate: real short-lived process integration tests leave no child behind and pass
under sanitizers where available; executor modules contain no `TaskPool`,
detached thread, sleep polling, or `std.process.execute` task path.

Status: delivered for POSIX. `libs/build-primitives/src/sparkles/build_primitives/task/process.d` holds
`ProcessDriver` over `supervise`, compiled only where Event Horizon exports it
(`processActionsAvailable`). `libs/build-primitives/src/sparkles/build_primitives/task/output.d` holds the bounded
`OutputSpool`, which spills to `<sandbox>/<task path>/output.log`. The
integration tests run real children. They were not run under the sanitizer leg.
The only `Thread.sleep` is a test helper that waits for a reparented grandchild
to be reaped. There is no thread cap to route; see SPEC TDM10.

## M6: Reporter stack

- Add the reporter interface and shared ordered block buffer.
- Add `TaskReporter` TTY rendering with bounded tails and protected finish.
- Add deterministic non-TTY transitions, output blocks, failure replay, and
  summary.
- Add interlaced line-atomic prefixed output for TTY and non-TTY.
- Add degraded/skipped/blocked/cancelled visual and plain-text vocabulary.
- Snapshot-test plain output under many completion permutations. Test terminal
  capability degradation and interrupted live-region cleanup.

Gate: fake-action graphs are usable interactively and through a pipe; default
plain transcripts are identical across completion permutations; interlaced
tests assert line atomicity rather than cross-task order.

Status: delivered.

- `libs/build-primitives/src/sparkles/build_primitives/task/reporter.d` holds the concepts, `consumeEvents`,
  `OrderedBlocks`, outcome wording, and the summary.
- `libs/build-primitives/src/sparkles/build_primitives/task/reporter_plain.d` holds the ordered and interlaced plain
  reporter. Its snapshot test covers all 120 completion orders of a
  six-outcome graph.
- `apps/ci/src/task/reporter_tty.d` holds `TaskReporter` over `LiveRegion`.
- `libs/build-primitives/src/sparkles/build_primitives/task/testing.d` holds the shared fake driver.

Not done: the optional stderr heartbeat and collapsing pending rows past a
height limit. The spinner advances on output only, because there is no tick
timer yet.

## M6a: Move into `sparkles:build-primitives`

- Move the generic modules (§9 of the SPEC) from `apps/ci` into this package,
  renamed under `sparkles.build_primitives.task` and `.workspace`. The TTY
  reporter stays in `apps/ci`.
- This package gains the `sparkles:event-horizon` dependency and no UI
  dependency.

Gate: `dub test :build-primitives`, `dub test :ci` and `dub build :ci -b
checked` pass. Every in-repository consumer of `sparkles:build-primitives`
builds.

## M6b: CI-provider integration

- The provider module (SPEC TDO6–TDO7), in `sparkles:base`, with detection, groups, annotations, masks
  and step summaries for GitHub Actions, GitLab CI, Buildkite and Azure
  Pipelines, and plain output elsewhere.
- The plain reporter groups replayed blocks on providers that support it.

Gate: golden tests per provider for groups, annotations and masks; a test
that each provider's output contains no other provider's syntax.

## M7: Memory-safe execution

A run's memory and disk are bounded today only by TDM10's capacity, one unit per GiB of
total memory, and by `hwParallelism`'s caps, which read available memory once,
before the run. Neither sees what an action uses. On a 32-core host with
29 GiB, a cold `ci test --build-only` admits enough test-root compiles at once
to exhaust memory, and the kernel's OOM killer then picks among every process
on the host: desktop sessions included. This milestone bounds a run's memory
by measurement and contains what is left over, and keeps a run from filling
the disks it writes.

Items 1 and 2 need no change to the executor's admission and land first;
items 4 to 7 amend the SPEC (TDM7, TDM10 and §3.3's `memoryHintBytes`, which
becomes a second admission dimension, and the disk rules), Event Horizon §13.7
and the build graph's BGS5, before any code.

1. **Containment.** A run's actions execute inside one cgroup the run owns,
   with the memory controller delegated to it: under systemd, `ci` re-executes
   itself in a transient user scope (`systemd-run --user --scope
-p Delegate=yes`) unless it already runs in a delegated cgroup, with
   `MemoryMax` (default 85 % of total memory; `--memory-max` overrides,
   `--memory-max=none` opts out) and no `MemoryHigh`. `ci`'s own process
   moves to a leaf of its own, so the no-internal-process rule lets each
   action's run cgroup reach Event Horizon's `accounted` tier. The scope is
   what items 4 to 6 stand on: without delegation no action's `memory.peak`
   can be read and no `memory.max` set. It is also the backstop for their
   prediction errors: at `MemoryMax` its OOM killer chooses only among the
   run's processes, its actions first. A `MemoryHigh` below it was dropped:
   past it the kernel throttled every allocation, and a run outgrowing it
   crawled instead of failing: in CI an AddressSanitizer compile of hue's
   test root that takes a minute ran into its 30-minute timeout, and the
   gate's cold run, its predictions too low, crawled for 15 minutes. Without
   systemd or cgroup v2 the run proceeds unconfined, and its report names the
   tier.
2. **OOM priority.** `ci` raises its own `oom_score_adj` to 900, so every
   process it starts inherits at least that, a descendant an action forks
   before its own score is written included; every supervised action (a
   build action, a test worker, an example) is raised to 1000 as soon as it
   is spawned. A shortage the kernel resolves by score takes the run's
   actions first, then `ci`, before any other program. No privilege is
   needed to raise a score.
3. **Host configuration.** A how-to for developer hosts: `systemd-oomd` with
   user slices managed (NixOS `systemd.oomd.enableUserSlices`), or `earlyoom`
   preferring the toolchain's processes and avoiding the desktop's, and
   compressed swap (`zramSwap`), so a shortage that item 1 does not contain
   degrades the host instead of ending its session.
4. **Admission by memory.** Every action's claim carries a predicted peak,
   and a node starts only when the predicted peaks of the running nodes and
   its own fit the run's memory budget (TDM7 gains the dimension, TDM8's order
   holds across both). The prediction is the action's last measured peak:
   its run cgroup's `memory.peak` in the `accounted` tier, else the peak
   resident set of its process tree that Event Horizon samples on every
   host. It is recorded with the run's records under the task's identity
   without its key digest, so an edited package keeps its history; an action
   with none takes a default per kind (a compile of a test root more than a
   library's). The budget is the `memory.max` of the cgroup that bounds the
   run (item 1's scope, a caller's, or a parent `ci`'s run), or, unbounded,
   the memory available at the start, less `ci`'s own reserve: the larger of
   its resident set at the start and 2 GiB, what it grows to over a run of
   every package, and never more than half the limit, so a small
   `--memory-max` still admits one action. A claim above the budget runs
   alone, nothing beside it. TDM10's memory unit per job goes.
5. **Back-off under pressure.** While the run cgroup's `memory.pressure`
   (unconfined: `/proc/pressure/memory`) reports `some` over a threshold for
   the last 10 seconds, the executor admits no further node, and resumes once
   it falls or after 30 seconds without a node finishing; nothing running is
   stopped, and when nothing runs one node is always admitted, so the run
   cannot stall. Predictions are wrong on a cold host and after an edit;
   pressure is what the kernel measures.
6. **A limit per action.** In the `accounted` tier, each action's run cgroup
   gets `memory.max` at twice its predicted peak (with a floor), and
   `memory.oom.group`, so a runaway action is killed whole and alone. A kill
   at its own limit, which the run cgroup's `memory.events.local` tells apart
   by its own `oom`, fails the action as a memory-limit failure that names its
   peak and limit, distinct from a signal and from a kill at the scope's
   limit, whose `oom` only the scope counts. Its next prediction is the limit
   it was killed at, so its next limit is twice that, and never above the
   run's budget: a leak costs a few runs and stops there, and a genuine need
   is met. (The first draft left the limit as it was after a second kill in a
   row; an action that needs more than two doublings would then never pass.)
   A test leg's workers share one limit, in a run group.
7. **Disk space.** The executor watches the free space of the file systems
   a run writes: the store, the run directory and the temporary directory.
   Each has a reserve, the smaller of 5 GiB and 10 % of its size, and a floor
   of half the reserve, so a small `tmpfs` gets a small one. Below the reserve
   it evicts the store, when the store is on that file system, and admits no
   node that writes there while another node runs; with none running and the
   free space still under the reserve, or below the floor at any time, it
   cancels the run, naming the file system and its free space, before an
   action fails part-way with `ENOSPC` and leaves the host's other programs
   without room. The report states each file system's free space at the start
   and the end. The task-DAG SPEC and the build graph's BGS5 gain these rules.

Gate:

- An executor test over a fixture graph of actions that each allocate and
  touch a known amount, run twice in a scope of known size: in the second run
  the running actions' predicted peaks never exceed the budget, none is
  OOM-killed, and a node larger than the budget runs alone.
- The same graph with one action that grows past its limit: only that action
  fails, as a memory-limit failure counted by its run cgroup's
  `memory.events`, and the next run predicts the limit it was killed at.
- Tests that a build action's, a test worker's and an example's process run
  with `oom_score_adj` 1000, and `ci` with 900, each from a starting score
  below it.
- A pressure test with the pressure it reads injected: above the threshold,
  admission pauses with nodes running and still admits one with none, resumes
  below it and after the bound, and every node completes.
- A disk test with the free space it reads injected: under the reserve the
  executor evicts and admits nothing that writes there while a node runs,
  with none running and no room made it cancels, under the floor it cancels
  with a message naming the file system, a 1 GiB `tmpfs` gets a reserve of
  100 MiB, and above both it runs unchanged.
- On the 29 GiB, 32-core developer host, a cold `ci test --build-only` from an
  empty store completes, and the journal shows no process outside the run's
  scope killed for memory; its wall time is recorded against the unbounded
  run's.
- `ci`'s own peak memory and CPU over a cold and a warm run, measured again
  and recorded here, so item 1's budget leaves it room. Before this
  milestone, on a 32-core host for all 406 tasks of `ci test --build-only`:
  cold, 109 s, `ci` itself peaking at 2.0 GiB resident with 131 s of CPU
  against its children's 789 s; warm, 30 s, 1.7 GiB and 104 s of CPU,
  against its children's 2 s. `ci` is the largest single process of a warm
  run, and comparable to a large compile in a cold one, so the scope contains
  it too.

Status: every item delivered, the gate partly verified.

- Items 1 and 2: `ci`'s CIC22 (`apps/ci/src/run_scope.d`), Event Horizon's
  `delegateRuns` and `writeOomScoreAdj`, `oomScoreAdj` through
  `ProcessDriverOptions`.
- Item 3: [Keeping a Developer Host Responsive Under
  Builds](../../../guidelines/developer-host-memory.md).
- Items 4 to 7: the task-DAG SPEC's TDM18 to TDM20, Event Horizon §13.7's limit
  per run, BGS5's eviction on a full disk, and `ci`'s CIC23
  (`apps/ci/src/run_resources.d`).

The gate, bullet by bullet:

- Memory admission: `executor.admission.memoryBudget`, over one run of a fake
  graph; the two-run form, in a real scope, is not automated.
- A limit per action: `process.run.memoryLimitFailure` and
  `supervise.memoryLimitKillsTheRunAlone`, each re-running itself in a
  delegated user scope; that the next run predicts the limit is `ci`'s
  (`RunStats.memoryPeaks`), not tested automatically.
- OOM scores: `supervise.oomScoreAdjReachesTheChild` and a check by hand (`ci`
  at 900, its `ldc2` at 1000); a test worker's and an example's are not
  tested automatically.
- Pressure: `executor.gate.boundedHold`, the pressure injected.
- Disk: `run_resources.decideGate` (reserve, floor, a 1 GiB `tmpfs`) and
  `executor.gate.diskCancels`; the eviction a gate starts is not tested
  automatically.
- The developer host, simulated on pc2-local (32 cores) in a 24 GiB scope
  (`--memory-max=24G`), every package's `ci test --build-only` from an empty
  cache (2026-11-27): it completed in 219 s against 137 s unbounded, the
  kernel logged no OOM kill in either, and a warm run in the scope took 15 s.
  With the first default of 4 GiB for a test root's compile, the same run
  admitted four of them at once; their 23 GB passed the scope's `MemoryHigh`,
  and the kernel's throttling slowed the run to a crawl for 15 minutes rather
  than failing it. The default is 8 GiB since; the largest recorded peak is
  hue's test root, 9.2 GB. After the review fixes (no `MemoryHigh`, children
  started in their cgroups, test legs in run groups), the same cold run in the
  same scope: 213 s, no OOM line in the kernel log, `ci` at 1.8 GiB resident
  and 46 s of CPU; warm 15.8 s; a `ci test --from versions` in the scope
  passed and recorded its parallel leg's run-group peak (27 MiB).
- `ci`'s own footprint, the same runs: 1.9 GiB resident at its peak in both,
  with 49 s of CPU in the scope and 82 s unbounded.

## Progress

| Milestone | State       |
| --------- | ----------- |
| M1        | delivered   |
| M2        | delivered   |
| M4        | delivered   |
| M5        | delivered   |
| M6        | delivered   |
| M6a       | delivered   |
| M6b       | in progress |
| M7        | delivered   |
