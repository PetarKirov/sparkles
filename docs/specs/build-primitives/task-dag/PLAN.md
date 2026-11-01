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

Status: delivered. `apps/ci/src/task/action.d` holds the action vocabulary and
its redacting dry-run summary. `apps/ci/src/task/model.d` holds ids, keys,
claims, nodes, edges, pointer-free outcomes and events. `apps/ci/src/task/graph.d`
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

Status: delivered. `apps/ci/src/workspace/package_graph.d` discovers the graph
through the `sparkles.build_primitives.dub_manifest` schema.
`apps/ci/src/workspace/select.d` holds the selection algebra, `gitChangesSince`
(through `runGit`), and the test-only planner `planPackages` with
`writeSelectionPlan`. `--from` globs use `gitGlobMatch`, newly public in
`sparkles.build_primitives.gitignore`. No CLI option exists yet.

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

Status: delivered. `apps/ci/src/task/executor.d` holds `runGraph` and
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

Status: delivered for POSIX. `apps/ci/src/task/process.d` holds
`ProcessDriver` over `supervise`, compiled only where Event Horizon exports it
(`processActionsAvailable`). `apps/ci/src/task/output.d` holds the bounded
`OutputSpool`, which spills to `<sandbox>/<task path>/output.log`. The
integration tests run real children. They were not run under the sanitizer leg.
The only `Thread.sleep` is a test helper that waits for a reparented grandchild
to be reaped. There is no thread cap to route; see SPEC section 5.3.

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

- `apps/ci/src/task/reporter.d` holds the concepts, `consumeEvents`,
  `OrderedBlocks`, outcome wording, and the summary.
- `apps/ci/src/task/reporter_plain.d` holds the ordered and interlaced plain
  reporter. Its snapshot test covers all 120 completion orders of a
  six-outcome graph.
- `apps/ci/src/task/reporter_tty.d` holds `TaskReporter` over `LiveRegion`.
- `apps/ci/src/task/testing.d` holds the shared fake driver.

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

- The provider module (SPEC §7.6) with detection, groups, annotations, masks
  and step summaries for GitHub Actions, GitLab CI, Buildkite and Azure
  Pipelines, and plain output elsewhere.
- The plain reporter groups replayed blocks on providers that support it.

Gate: golden tests per provider for groups, annotations and masks; a test
that each provider's output contains no other provider's syntax.

## Progress

| Milestone | State       |
| --------- | ----------- |
| M1        | delivered   |
| M2        | delivered   |
| M4        | delivered   |
| M5        | delivered   |
| M6        | delivered   |
| M6a       | in progress |
| M6b       | not started |
