---
status: draft
owner: apps/ci
reviewed: 2026-11-01
---

# `apps/ci` commands — Delivery plan

_Companion to [SPEC.md](./SPEC.md). Each milestone is independently green: the
tool builds, its tests pass, the repository's invocations of `ci` keep working,
and the milestone can be reviewed without relying on a later commit._

The generic layers are delivered by the [task DAG plan](../../build-primitives/task-dag/PLAN.md)
(M1, M2, M4–M6) and the compile machinery by the [build graph
plan](../../build-primitives/build-graph/PLAN.md) (E0–E4). This plan owns the
prerequisite gate and the command cutovers.

## Delivery rules

- Add the smallest module split the current milestone needs. The layout in
  SPEC §7 is a destination, not permission for empty files.
- These are hard prerequisites for the first cutover:
  - the complete `sparkles.wired.sdl` backend;
  - Event Horizon M19 items 1–5;
  - bounded cross-worker channels;
  - build graph E1a (the pinned test runner) and E3.
- Event Horizon M19 item 6 is delivered by the cutovers below, not by a
  separate port of the legacy process layer. `apps/ci` carries no second
  process executor.
- Switch one work family at a time. Keep no flag aliases and no fallback from
  the task-DAG executor.
- Every graph or executor test uses stable task ids, and deliberately scrambled
  completion order where ordering is under test.

## M0: Specification

The command specification, delivered with the task DAG and build graph
specifications it links to.

Gate: the three specification trees are internally consistent, reviewed, and
pass the documentation checks.

## M3: Prerequisite integration gate

- Require the `sparkles.wired.sdl` backend and the Event Horizon M19
  supervised-process surface in `apps/ci`'s dependency closure.
- Add integration probes for:
  - typed repository discovery;
  - supervised line streaming;
  - cancellation;
  - process-tree teardown;
  - resource events;
  - the scheduler-integrated blocking pool.
- Require bounded cross-worker channels, exercising backpressure, close and
  drain, cancellation, and exactly-once delivery between scheduler workers.
- Expose no partial canonical CLI.

Gate: prerequisite package tests pass on Linux, macOS and Windows. The probes
leave no process behind and use no `sparkles.core_cli.process_utils` execution
path.

Status: Linux and macOS are met.

- **Process matrix:** the macOS matrix runs the supervision suite on both
  hosts.
- **Channels:** `CrossChannel` is the executor's production event channel.
- **Pending:** Windows supervision is the remaining part of the gate.

## M7: Canonical CLI and the `ci test` cutover onto the build graph

- Add `cli.d` with the core-cli nested command tree and the common execution
  options.
- Add `ci test` with its modes, focused selectors and closures (SPEC §1.2,
  §4). Plan ordinary tests and build-only runs as the build graph's actions:
  test-root compiles, dependency-library builds, test binary links and test
  runs, with no ordering edges between tests.
- Add the CI-provider grouping to the plain reporter (task DAG M6b), and switch
  workflows to `--interlaced`. Workflows that set `SPARKLES_CI_JOBS` convert it to
  weighted units (CIC1).
- Remove `--test`, `--build` and their loops in the same change.

Gate:

- `ci test --jobs 1` and `ci test` are green in their build-only and ordinary
  forms.
- A second run in another worktree compiles nothing.
- Fail-fast kills a deliberately nested child tree.
- The removed flags are rejected.

## M8: Coverage, sanitizers, slow tests and special modes

- Coverage attempts with conditional plain retries and package classification;
  deterministic listing merge and atomic publication (SPEC §5.2, §6).
- `--sanitize address`, `--slow` and `--special-modes betterc|wasm|all` as
  variants and task kinds.
- Remove `--test-extracted`, `--test-sanitize`, `--test-slow` and
  `--coverage`'s old form.

Gate: ordinary tests pass with and without coverage. A fixture that fails only
under coverage is degraded and exits zero, and a true fallback failure exits
one. Parallel listings never share a destination.

## M9: Markdown and standalone examples

- Markdown extraction and per-example single-file packages, shared by
  `docs run`, `docs verify` and `docs update`, built against the shared library
  variants.
- `ci docs examples` with directives and platform skips.
- Remove `--example-files`, the default markdown mode and `TaskPool` example
  execution.

Gate: README verification, a multi-file update fixture, standalone build-only
and run fixtures, timeout behavior, and parallel duplicate example names are
green. No `std.parallelism` import remains in `apps/ci`.

## M10: Documentation commands

- Every `ci docs …` check and rewrite of SPEC §5.6, including glossary,
  credits, spec evidence and the WebAssembly modules.
- Preserve every file default, selector semantic, source-position
  diagnostic, local-clone behavior and audit scope.

Gate: every `ci docs` command has a parity fixture. Mutating commands make no
writes under dry run and write atomically otherwise. The pre-commit hook
invocations remain green after their migration.

## M11: Statistics, commit checks and maintenance commands

- `ci stats` with its degradations (SPEC §5.7). Blocking HTTP runs through the
  blocking pool until a native client exists.
- `ci commit-scope` and `ci commits build-each` on the shared store.
- `ci cache`, `ci host probe`, `ci checks mirror`, `ci link-rot report` and
  `ci slow-tests list`.

Gate: complete, partial, empty-comparison, authentication-failure and optional
metadata fixtures have the specified outcomes and exits; tokens are absent from
events and dry runs; commit hook output stays concise.

## M12: `ci pipeline` and removal of the legacy path

- `ci pipeline` as the union graph of every CI job (SPEC §1.3).
- Verify that every production command constructs a graph and uses the common
  executor. Remove superseded worker pools, serial loops, polling, duplicate
  fail-fast code and command-owned live regions.
- Measure idle behavior, peak memory, weighted saturation and the pipeline's
  wall time against the current CI.

Gate: `ci pipeline` covers every job `ci.yml` runs or names it as skipped.
Forced cancellation leaves no child process or live-region control residue.
Default non-TTY output is stable across a randomized completion stress run.

## M13: Repository migration

- Change workflows, hooks and developer documentation to the canonical
  commands, in the same series as the cutovers.
- Reconcile `docs/specs/ci/stats/` terminology with `ci stats` and the common
  reporter.

Gate: full repository CI is green on canonical commands, and no script, hook,
workflow or user-facing document uses a removed flag.

## Progress

| Milestone | Deliverable                          | State       |
| --------- | ------------------------------------ | ----------- |
| M0        | Specifications                       | in review   |
| M3        | Prerequisite gate                    | partial     |
| M7        | CLI and `ci test` on the build graph | not started |
| M8        | Coverage and special modes           | not started |
| M9        | Examples                             | not started |
| M10       | Docs commands                        | not started |
| M11       | Stats, commits, maintenance          | not started |
| M12       | `ci pipeline`, legacy removal        | not started |
| M13       | Consumer migration                   | not started |
