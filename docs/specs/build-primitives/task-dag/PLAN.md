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
items 4 to 6 amend the SPEC (TDM7, TDM10 and §3.3's `memoryHintBytes`, which
becomes a second admission dimension) and Event Horizon §13.7, before any
code.

1. **Containment.** A run's actions execute inside one cgroup the run owns,
   with the memory controller delegated to it: under systemd, `ci` re-executes
   itself in a transient user scope (`systemd-run --user --scope
-p Delegate=yes`) unless it already runs in a delegated cgroup, with
   `MemoryHigh` and `MemoryMax` (defaults 75 % and 85 % of total memory;
   `--memory-max` overrides, `--memory-max=none` opts out). `ci`'s own process
   moves to a leaf of its own, so the no-internal-process rule lets each
   action's run cgroup reach Event Horizon's `accounted` tier. The scope is
   what items 4 to 6 stand on: without delegation no action's `memory.peak`
   can be read and no `memory.max` set. It is also the backstop for their
   prediction errors: past `MemoryHigh` the kernel reclaims and throttles
   inside the run, and at `MemoryMax` its OOM killer chooses only among the
   run's processes. Without systemd or cgroup v2 the run proceeds
   unconfined, and its report names the tier.
2. **OOM priority.** Each action's process sets its `oom_score_adj` to 1000
   before it executes the action, so an OOM kill outside a scope (item 1's
   fallback, or a host-wide shortage) takes a compile before anything else.
   No privilege is needed to raise one's own score. `ci` keeps its own.
3. **Host configuration.** A how-to for developer hosts: `systemd-oomd` with
   user slices managed (NixOS `systemd.oomd.enableUserSlices`), or `earlyoom`
   preferring the toolchain's processes and avoiding the desktop's, and
   compressed swap (`zramSwap`), so a shortage that item 1 does not contain
   degrades the host instead of ending its session.
4. **Admission by memory.** Every action's claim carries a predicted peak,
   and a node starts only when the predicted peaks of the running nodes and
   its own fit the run's memory budget (TDM7 gains the dimension, TDM8's order
   holds across both). The prediction is the action's last measured
   `memory.peak`, recorded with the run's records under the task's identity
   without its key digest, so an edited package keeps its history; an action
   with none takes a default per kind (a compile of a test root more than a
   library's). The budget is item 1's `MemoryHigh` less `ci`'s own peak, or,
   unconfined, available memory less a reserve and that peak. A claim above the budget runs alone, as TDM7 clamps
   an oversized weight. TDM10's memory unit per job goes.
5. **Back-off under pressure.** While the run cgroup's `memory.pressure`
   (unconfined: `/proc/pressure/memory`) reports `some` over a threshold for
   the last 10 seconds, the executor admits no further node, and resumes once
   it falls; nothing running is stopped. Predictions are wrong on a cold host
   and after an edit; pressure is what the kernel measures.
6. **A limit per action.** In the `accounted` tier, each action's run cgroup
   gets `memory.max` at twice its predicted peak (with a floor), and
   `memory.oom.group`, so a runaway action is killed whole and alone. It fails
   as a memory-limit failure that names its peak and limit, distinct from a
   signal, and its next prediction is the peak it reached.
7. **Disk space.** The executor watches the free space of the file systems
   a run writes: the store, the run directory and the temporary directory.
   Below a reserve (the larger of 5 GiB and 5 % of the file system), it admits
   no node that writes there and evicts the store down to what fits; below a
   floor of half the reserve, it cancels the run, naming the file system and
   its free space, before an action fails part-way with `ENOSPC` and leaves
   the host's other programs without room. The report states each file
   system's free space at the start and the end.

Gate:

- An executor test over a fixture graph of actions that each allocate and
  touch a known amount, run in a scope of known size: the running actions'
  predicted peaks never exceed the budget, none is OOM-killed, and a node
  larger than the budget runs alone.
- The same graph with one action that grows past its limit: only that action
  fails, as a memory-limit failure, and the next run predicts its peak.
- A test that an action's process runs with `oom_score_adj` 1000.
- A pressure test: with the threshold forced low, admission pauses and
  resumes, and every node completes.
- A disk test with the free space it reads injected: under the reserve the
  executor evicts and admits nothing that writes there, under the floor the
  run is cancelled with a message naming the file system, and above both it
  runs unchanged.
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
| M7        | planned     |
