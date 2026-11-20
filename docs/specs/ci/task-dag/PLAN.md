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
  - the test runner's out-of-process runner (TRD1 and TRD9 in
    `docs/specs/test-runner/`), which supersedes build graph E1a, and build
    graph E3.
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

Status: met.

- **Process matrix:** the macOS matrix runs the supervision suite on both
  hosts.
- **Channels:** `CrossChannel` is the executor's production event channel.
- **Windows:** Event Horizon M19 item 5 delivered supervision on Windows, and
  the `windows-latest` leg runs the prerequisite packages' suites, the
  supervision cases among them: on #745's run 44573104254, `event-horizon`
  passed 179 tests (2 skipped), `wired` 338 and `build-primitives` 286.

## M3a: Placements before the build graph

CIC14's data path on the current test modes, with the slice of the
observability plan that
[OD21](../../build-primitives/observability/decisions.md#od21-test-wall-times-reach-the-history-before-the-build-graph-accepted)
names:

- **Records:** `--test`, `ci test --sanitize address` and `ci test --special-modes all` write a run
  record with one task per package run, task id
  `test:<package>:<mode>:<leg>` (TDM1), where `<leg>` is `serial` or
  `parallel` rather than a thread count that varies by host, its outcome and
  `task.wall`.
  `ci perf record ID -- COMMAND` records any other command the same way. CI
  uploads the records as artifacts.
- **History:** `main-checks.yml` appends the validating run's records to
  `refs/perf/data` (OBH3–OBH5), signed with the CI key (OBH8). `ci perf push`
  publishes local records, and `ci perf import-github-run RUN` builds records
  from an earlier run's job logs, to seed the history.
- **Placements:** one data file, `ci/placements.json`, declares each placement:
  its system, compiler, mode, legs, coverage, runners per provider, shard count and time
  limit. `ci placements list` prints them with their shards as JSON, and sets
  it as a job output.
- **Shards:** `--placement NAME --shard K/N` packs the placement's packages
  longest first, by the median `task.wall` of each task's last five records on
  that placement, and runs shard `K`. A package with no record takes the
  median of the placement's recorded tasks.
- **Workflows:** the test, sanitizer and extracted jobs take their matrix from
  `ci placements list`, and name no package. The steps the first shard used to
  run beside its tests move to jobs of their own. CircleCI runs the same
  placements by `--shard ${CIRCLE_NODE_INDEX}/${CIRCLE_NODE_TOTAL}`.
- **The toolchain's build plan** reads each pin's cost the same way, from the
  `pin-build:<pin>` tasks its builds record (`ci cache pin-costs`), and the
  hand-kept `nix/pin-build-costs.json` is gone.

Prerequisites from the owner: the CI signing key's environment and the
allowed-signers file (OD21).

Gate: two consecutive `main` landings append their records; a third run's
shards are packed from them, with no package named in any workflow; every
shard of a run packs identically, checked by a test that packs one placement
from two `--history-tip` reads; a forged or unsigned record is not read.

Progress: delivered. The landings of #742 and #743 appended their records
(`8133e639f`, `311256477`), and every shard of #744's run 44294916592
packed from the 15 records at `311256477`.
Run records (`perf_record`, `perf_run`), the signed history (`perf_history`),
publishing (`perf_publish`: `ci perf append`, `ci perf push`,
`ci perf import`), `ci/placements.json` with `ci placements list`
and `--shard`, the workflows (`ci.yml`'s `placements`, `test` and `platform`
jobs, `main-checks.yml`'s `perf-append`, CircleCI's parallelism) and the
toolchain's recorded costs (`ci cache pin-costs`).

## M7a: The canonical command line over the current implementations

The command surface of SPEC §1.1 replaces the flags before any command runs on
the build graph
([T16](../../build-primitives/task-dag/decisions.md#t16-the-command-line-changes-before-the-executor)).
It changes the command line, not what a command does, so it is not a cutover
and needs none of the prerequisites above.

- Add `cli.d` with the core-cli command tree, dispatched by `runCli`. Each
  command is a struct whose `run()` returns `RunExpected` (CIC16), and each
  command's options are its own fields. `CliParams`, `ProgramMode` and the
  cross-mode validation they needed are removed.
- Every current mode gets the command SPEC §1.1 names. Until M7b:
  - `ci test --build-only` runs each package's `dub build`, as `--build` did;
  - `--from` takes package names only;
  - `--since`, `--dependencies`, `--dependents`, `--backend`,
    `--require-cached` and the common `--jobs`, `--interlaced` and `--dry-run`
    are not accepted yet, since nothing could honour them.
- `ci pipeline` does not exist yet; `ci placements list` and
  `ci test --placement NAME --shard K/N` carry M3a's placements.
- Reject every removed flag as an unknown option (CIC4), and give checks,
  fixes and GitHub actions their verb groups (CIC17).
- Change every workflow, hook, script, Nix package and document that runs
  `ci` in the same change, so the repository never runs a removed flag.
- Move each command group's implementation out of `app.d` into its
  `commands/` module (SPEC §7), with the file selection, rendering and
  toolchain command lines the groups share in modules of their own.

Progress: delivered. The command tree landed in #743 and the `commands/`
split in #744; `cli.removedFlags.unknown` rejects SPEC §2's removed flags, and
no workflow, hook, script or document uses one.

Gate:

- `ci`'s tests pass, and a test rejects every flag of SPEC §2's first column
  as an unknown option.
- Repository CI is green on the canonical commands, on GitHub Actions and
  CircleCI.
- No script, hook, workflow or user-facing document uses a removed flag.

## M7b: The `ci test` cutover onto the build graph

- Add the common execution options to `ci test`.
- Add `ci test`'s focused selectors and closures (SPEC §1.2,
  §4). Plan ordinary tests and build-only runs as the build graph's actions:
  test-root compiles, dependency-library builds, test binary links and test
  runs, with no ordering edges between tests.
- Run each test binary through the test runner's core library, as worker
  nodes whose events are the nodes' output (CIC11). It needs the core that
  the test runner's
  [P1 slice 6](../../test-runner/PLAN.md#p1--the-out-of-process-runner)
  delivers, so M7b closes only after it.
- Add the CI-provider grouping to the plain reporter (task DAG M6b), and switch
  workflows to `--interlaced`. Workflows that set `SPARKLES_CI_JOBS` convert it to
  weighted units (CIC1).
- Remove the current serial test and build loops in the same change.
- Add `--require-cached` (CIC12), `ci cache explain` and
  `ci cache verify --rerun`, and run the determinism check on every CI run
  from the first workflow that builds on the shared store (CIC13).

Gate:

- `ci test --jobs 1` and `ci test` are green in their build-only and ordinary
  forms.
- A second run in another worktree passes under
  `--require-cached compile archive link`.
- A CI run includes the determinism check, and a planted nondeterministic
  fixture fails it.
- Fail-fast kills a deliberately nested child tree.
- The removed flags are rejected.
- A binary run under `ci test` and standalone agrees on every test (CIC11).

Progress, by the gate's items:

- **The cutover:** `ci test` and `ci test --build-only` plan the selected
  packages' test roots as one build graph (`runTestsOnGraph`) and run it
  against the shared store, with the compiler `$DC` names, DMD's variants
  included (build graph D19). Each test leg is the in-process action
  `test:leg`, which drives the test runner's core over workers fed their
  commands on standard input (`apps/ci/src/test_leg.d`, Event Horizon's
  `superviseFed`). The placement chooses the legs and coverage; listings
  merge into `build/coverage`, and each leg's wall time goes to the run
  record. The dub build loop is removed; `--sanitize` keeps the dub test
  loop until its variant (M8).
- **Options:** `--jobs`, `--interlaced` and `--dry-run` (CIC1), the focused
  selectors and closures (§4) and `--require-cached` (CIC12) are delivered;
  `ci cache stats|list|gc|verify|remove|replace|explain` replace
  `ci cache store`, and `ci cache verify --rerun` runs CIC13's check over the
  last run.
- **Workflows:** the `ci test` steps pass `--interlaced`, and each is
  followed by `ci cache verify --rerun`.
- **Gate checks so far:** oracle `cic11` of `apps/ci/tools/graph-oracles.d`:
  a fixture's 17 tests get the same verdicts through the core and
  standalone, and fail-fast ends another package's leg with the nested
  processes its test started. Oracle 19 plants a nondeterministic result,
  which fails the check. `cli.removedFlags.unknown` rejects the removed
  flags. A second `ci test` of `versions` passes under `--require-cached
compile archive link`.

Next: the whole repository's `ci test` in both forms, with `--jobs 1`, and a
second worktree under `--require-cached`; a CI run with the check.

## M8: Coverage, sanitizers, slow tests and special modes

- Coverage attempts with conditional plain retries and package classification;
  deterministic listing merge and atomic publication (SPEC §5.2, §6).
- `--sanitize address`, `--slow` and `--special-modes betterc|wasm|all` as
  variants and task kinds.
- Remove the current special-mode, sanitizer, slow-test and coverage loops.

Gate: ordinary tests pass with and without coverage. A fixture that fails only
under coverage is degraded and exits zero, and a true fallback failure exits
one. Parallel listings never share a destination.

Progress: delivered on the build graph, beside M7b.

- **Coverage:** each package's test is a `-cov` attempt with a plain fallback
  (build graph CIC7 planning); a package whose coverage build failed but
  whose fallback passed is reported uncovered (`Degraded(noCoverage)`), and
  the listings merge (`coverage.mergeListings`) into a sibling directory
  that replaces `build/coverage` by rename. Oracle `m8` checks the degraded
  and the failing fallback.
- **`--sanitize address`:** `-fsanitize=address` in every compile and link
  and `ASAN_OPTIONS` in every test and generator (`Tools.extraFlags`,
  `Tools.runtimeEnvironment`), one leg keeping the `@slow` tests.
- **`--slow`:** each package's chosen `@slow` tests are one leg,
  `--only-slow -i <names>` (`Tools.testArguments`).
- **`--special-modes`:** each package's modes are one leg, which runs the
  runner core's driver on a blocking pool.
- **Packages beneath the runner** (`metadata`, `profiling-counters`,
  `test-attributes`, `test-harness`, `test-runner`) speak no runner protocol:
  their test actions stay processes, the exit status their verdict.

The dub test loops are removed. Open: the gate's whole-repository runs with
and without coverage.

## M9: Markdown and standalone examples

- Markdown extraction and per-example single-file packages, shared by
  `ci examples run`, `verify` and `update`, built against the shared library
  variants.
- `ci examples standalone` with directives and platform skips.
- Remove the current example loops and `TaskPool` example
  execution.

Gate: README verification, a multi-file update fixture, standalone build-only
and run fixtures, timeout behavior, and parallel duplicate example names are
green. No `std.parallelism` import remains in `apps/ci`.

## M10: Documentation commands

- Every documentation `ci check` and `ci fix` of SPEC §5.6, including glossary,
  credits, spec evidence and the WebAssembly modules.
- Preserve every file default, selector semantic, source-position
  diagnostic, local-clone behavior and audit scope.

Gate: every documentation check and fix has a parity fixture. Mutating commands make no
writes under dry run and write atomically otherwise. The pre-commit hook
invocations remain green after their migration.

## M11: Statistics, commit checks and maintenance commands

- `ci stats` with its degradations (SPEC §5.7). Blocking HTTP runs through the
  blocking pool until a native client exists.
- `ci check commit-scope` and `ci commits build-each` on the shared store.
- `ci cache`, with removal and replacement (BGS7), `ci host probe`,
  `ci github mirror-checks`, `ci github link-rot-issue` and `ci slow-tests list`.

Gate: complete, partial, empty-comparison, authentication-failure and optional
metadata fixtures have the specified outcomes and exits; tokens are absent from
events and dry runs; commit hook output stays concise.

## M12: `ci pipeline` and removal of the legacy path

- `ci pipeline` as the union graph of every CI job (SPEC §1.3), with the
  determinism check as one of its tasks (CIC13).
- Placements (CIC14): the placement file, `--placement` and
  `ci placements list`, with shards packed from recorded wall times.
- Verify that every production command constructs a graph and uses the common
  executor. Remove superseded worker pools, serial loops, polling, duplicate
  fail-fast code and command-owned live regions.
- Measure idle behavior, peak memory, weighted saturation and the pipeline's
  wall time against the current CI.
- Measure the build graph's no-op run time, planning time, the stats and
  manifests each lookup reads, and the cutoff rate, split by whether an edit
  moved lines and by whether it changed a module's interface or only a body.
  The definitions belong to the build-primitives observability specification
  (`docs/specs/build-primitives/observability/`). The results decide two open
  build-graph questions: a planning memo past about one second of no-op
  planning (D37), and interface cutoff (D35).
- Shards recompile common libraries until a binary cache shares results
  (build graph D41); the measurement records what that costs.

Gate: `ci pipeline` covers every job `ci.yml` runs or names it as skipped.
Forced cancellation leaves no child process or live-region control residue.
Default non-TTY output is stable across a randomized completion stress run.

## M13: Repository migration

- Change workflows, hooks and developer documentation to the canonical
  commands, in the same series as the cutovers.
- Generate the workflows from `ci placements list pipeline`. No workflow
  passes `--since` (CIC15).
- Reconcile `docs/specs/ci/stats/` terminology with `ci stats` and the common
  reporter.

Gate: full repository CI is green on canonical commands, and no script, hook,
workflow or user-facing document uses a removed flag.

## Progress

| Milestone | Deliverable                       | State       |
| --------- | --------------------------------- | ----------- |
| M0        | Specifications                    | in review   |
| M3        | Prerequisite gate                 | done        |
| M3a       | Placements before the build graph | done        |
| M7a       | Canonical command line            | done        |
| M7b       | `ci test` on the build graph      | in progress |
| M8        | Coverage and special modes        | in progress |
| M9        | Examples                          | not started |
| M10       | Docs commands                     | not started |
| M11       | Stats, commits, maintenance       | not started |
| M12       | `ci pipeline`, legacy removal     | not started |
| M13       | Consumer migration                | not started |
