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

| Requirement | Oracle                                                                                                                             |
| ----------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| CIC1        | Option-validation tests: zero and negative `--jobs`, `--dry-run --interlaced`, `SPARKLES_CI_JOBS` precedence.                      |
| CIC2        | Every single-check command's transcript has one task block and the executor's summary.                                             |
| CIC3        | The same `ci test` selection under `--backend local` and `--backend nix` gives the same verdicts (build graph oracle 6).           |
| CIC4        | Every flag in the table is rejected with its replacement named; a parser test enumerates the table.                                |
| CIC5        | A fixture change under each invalidator selects every package under `--since`.                                                     |
| CIC6        | No test node has an incoming edge from another package's test; a stack-heavy test fails the `-t 1` leg.                            |
| CIC7        | Fixtures that fail only to build under `-cov`, fail only their coverage test, and pass both, with their classifications and exits. |
| CIC8        | A run with tests and examples plans no library variant for the examples beyond those the tests plan.                               |
| CIC9        | The completion criteria, each checked by the milestone that delivers it.                                                           |
| CIC10       | The listing's JSON and the provider output, for a fixture with named, unnamed and no `@slow` tests.                                |

## Evidence ledger

| Requirement | Status      | Evidence |
| ----------- | ----------- | -------- |
| CIC1–CIC10  | not started | —        |
