---
status: draft
owner: apps/ci
reviewed: 2026-11-01
---

# `apps/ci` commands — Testing and evidence

This page maps each requirement of [SPEC.md](./SPEC.md) to the tests that
falsify it. The generic executor's evidence lives in the
[task DAG's testing page](../../build-primitives/task-dag/testing.md), and the
build graph's in [its own](../../build-primitives/build-graph/testing.md).
Command tests run real `ci` invocations against fixture repositories and
compare plain transcripts, exit codes and the files left behind.

| Requirement | Oracle                                                                                                                                                                                                                                                                                                        |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| CIC1        | Option-validation tests: zero and negative `--jobs`, `--dry-run --interlaced`, `SPARKLES_CI_JOBS` precedence.                                                                                                                                                                                                 |
| CIC2        | Every single-check command's transcript has one task block and the executor's summary.                                                                                                                                                                                                                        |
| CIC3        | The same `ci test` selection under `--backend local` and `--backend nix` gives the same verdicts (build graph oracle 6).                                                                                                                                                                                      |
| CIC4        | A parser test enumerates the table: every flag is rejected as an unknown option, before any command runs.                                                                                                                                                                                                     |
| CIC5        | `repository_inputs.cic5`: over this repository, the files planning read, the toolchain's patterns, the planner's inputs and the working-directory names are workspace inputs, and a package outside the planner, documentation and a recipe tool are not (build graph oracle 20).                             |
| CIC6        | No test node has an incoming edge from another package's test; a stack-heavy test fails the `-t 1` leg.                                                                                                                                                                                                       |
| CIC7        | Fixtures that fail only to build under `-cov`, fail only their coverage test, and pass both, with their classifications and exits.                                                                                                                                                                            |
| CIC8        | A run with tests and examples plans no library variant for the examples beyond those the tests plan.                                                                                                                                                                                                          |
| CIC9        | The completion criteria, each checked by the milestone that delivers it.                                                                                                                                                                                                                                      |
| CIC10       | The listing's JSON and the provider output, for a fixture with named, unnamed and no `@slow` tests.                                                                                                                                                                                                           |
| CIC11       | A binary run under `ci test` and standalone, with the same options: the same per-test statuses and verdict; and two packages' worker nodes admitted at once.                                                                                                                                                  |
| CIC12       | Under `--require-cached compile`, a run with one edited module fails exactly the compiles that read it: the owning package's with a `declared` miss explanation, each dependent's with a `manifest` one, both naming the module, and a run with no edit passes.                                               |
| CIC13       | A pipeline run plans one determinism-check task; a planted nondeterministic compile in the sample fails it as authoritative and removes the result (build graph oracle 19).                                                                                                                                   |
| CIC14       | `ci placements list` on a fixture placement file prints every task in exactly one placement and shard, packed longest first by recorded `task.wall` with the default weight for unseen tasks; `--placement NAME` runs only its tasks and their build actions, and every other task ends `Skipped(placement)`. |
| CIC15       | A scan of `.github/workflows/` finds no `ci` invocation with `--since`.                                                                                                                                                                                                                                       |
| CIC16       | Every command struct's `run` returns a `RunExpected` (a compile-time check over the command tree); a failing command's exit status and `Error:` line come from it, and `ci perf record` exits with its child's status.                                                                                        |
| CIC17       | `ci check --help` lists every check the hooks and workflows run; a bare group exits non-zero with its help.                                                                                                                                                                                                   |

## Evidence ledger

| Requirement | Status      | Evidence |
| ----------- | ----------- | -------- |
| CIC1–CIC11  | not started | —        |
| CIC12–CIC15 | planned     | —        |
| CIC16–CIC17 | planned     | —        |
