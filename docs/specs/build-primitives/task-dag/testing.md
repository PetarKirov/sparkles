---
status: draft
owner: sparkles:build-primitives
reviewed: 2026-11-01
---

# Task DAG — Testing and evidence

This page maps each requirement of [SPEC.md](./SPEC.md) to the tests that
falsify it, and records the evidence. The executor and reporters are tested
in three ways:

- a fake action driver under the deterministic `TestSched` and a fake clock,
  with completion orders deliberately scrambled;
- real short-lived child processes for the subprocess adapter;
- byte-exact transcripts compared across every completion order of a fixed
  graph.

A test is also checked against a deliberately broken implementation where the
ledger says so: the starvation and primary-cause tests fail when their rule is
removed.

Every row below was run on Linux (kernel 6.18, LDC 1.43) on 2026-11-01. The
tests live in `libs/build-primitives` and, for the TTY reporter, in
`apps/ci`.

## Evidence ledger

| Requirement | Status     | Evidence                                                                                                                                           | Scenarios                                                                                                                                                                     |
| ----------- | ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| TDS1–TDS3   | verified   | `libs/build-primitives/src/sparkles/build_primitives/workspace/package_graph.d`                                                                    | `buildPackageGraph.rejectsInvalidGraphs`, `.configurationAwareEdges`, `discoverPackages.thisRepository`                                                                       |
| TDS4        | verified   | `libs/build-primitives/src/sparkles/build_primitives/workspace/select.d`                                                                           | `selectPackages.fromExactAndGlob`, `.emptyMatchesAreErrors`                                                                                                                   |
| TDS5–TDS6   | partial    | `libs/build-primitives/src/sparkles/build_primitives/workspace/select.d`                                                                           | `gitChangesSince.fixtureRepository`, `.defaultBaseAndErrors`, `selectPackages.sinceOwnershipDeletionsAndInvalidators`. Missing: invalidators taking precedence over ownership |
| TDS7–TDS8   | verified   | `libs/build-primitives/src/sparkles/build_primitives/workspace/select.d`                                                                           | `selectPackages.closuresAreAFixedPointUnion`, `.platformSkippedSeedsAreNotEmpty`, `.cyclicGraphsNeverReachSelection`                                                          |
| TDM1–TDM3   | verified   | `libs/build-primitives/src/sparkles/build_primitives/task/model.d`, `libs/build-primitives/src/sparkles/build_primitives/task/action.d`            | `taskId.formatting`, `writeActionSummary.process`, `.inProcessAndInert`                                                                                                       |
| TDM4        | verified   | `libs/build-primitives/src/sparkles/build_primitives/task/process.d`                                                                               | `redact.masksEveryOccurrence`, `run.timeoutAndRedaction`                                                                                                                      |
| TDM5–TDM6   | partial    | `libs/build-primitives/src/sparkles/build_primitives/task/graph.d`                                                                                 | `resolveEdge.conditions`, `propagateBlocked.cascadesAndKeepsTheRoot`, `.successBlocksTheFallbackWithoutFailing`. Missing: the summary's separate count of unneeded fallbacks  |
| TDM7–TDM9   | verified   | `libs/build-primitives/src/sparkles/build_primitives/task/executor.d`                                                                              | `admission.capacityAndPresentationOrder`, `.exclusiveKeysSerializeOnlyTheirHolders`, `.noStarvationOfAHeavyTask`, `.overCapacityClaimRunsAlone`                               |
| TDM10       | unverified | —                                                                                                                                                  | The capacity formula is not implemented                                                                                                                                       |
| TDM11–TDM14 | verified   | `libs/build-primitives/src/sparkles/build_primitives/task/executor.d`, `libs/build-primitives/src/sparkles/build_primitives/task/output.d`         | `run.eventsAreSequencedAndMonotonic`, `OutputSpool.spillsLosslesslyAndKeepsATail`, `run.largeOutputSpillsToTheSandbox`                                                        |
| TDE1–TDE3   | partial    | `libs/build-primitives/src/sparkles/build_primitives/task/process.d`                                                                               | `run.reporterOnAnotherWorker`, `run.exitStatusesArgvAndFraming`. Missing: an import audit for the forbidden constructs; Windows                                               |
| TDC1–TDC3   | verified   | `libs/build-primitives/src/sparkles/build_primitives/task/executor.d`, `libs/build-primitives/src/sparkles/build_primitives/task/process.d`        | `failFast.blockedCancelledAndCleanup`, `.simultaneousFailuresPickTheLowestKey`, `run.failFastTearsDownTheTree`                                                                |
| TDC4        | verified   | `libs/build-primitives/src/sparkles/build_primitives/task/executor.d`                                                                              | `failFast.provisionalFailureFallsBackWithoutCancelling`                                                                                                                       |
| TDC5–TDC6   | partial    | `libs/build-primitives/src/sparkles/build_primitives/task/executor.d`                                                                              | `cancel.externalInterrupt`. Missing: a real signal delivered to a running command                                                                                             |
| TDD1–TDD2   | verified   | `libs/build-primitives/src/sparkles/build_primitives/task/executor.d`, `libs/build-primitives/src/sparkles/build_primitives/task/graph.d`          | `run.outcomesIndependentOfCompletionOrder`, `build.orderIsIndependentOfInsertionOrder`, `build.reportsTheShortestCycleFromItsLowestMember`                                    |
| TDO1, TDO3  | verified   | `libs/build-primitives/src/sparkles/build_primitives/task/reporter_plain.d`, `libs/build-primitives/src/sparkles/build_primitives/task/reporter.d` | `transcriptIsIdenticalAcrossCompletionOrders` (120 orders), `spilledBlocksReplayInFull`, `OrderedBlocks.releasesInPresentationOrder`                                          |
| TDO2        | partial    | `apps/ci/src/task/reporter_tty.d`                                                                                                                  | `interactiveShowsTailsAndRestoresTheCursor`, `nonInteractiveDegradesToPlainLines`. Missing: collapsing past a height limit; a timer-driven spinner                            |
| TDO4        | partial    | `libs/build-primitives/src/sparkles/build_primitives/task/reporter_plain.d`                                                                        | `interlacedIsImmediateLineAtomicAndPrefixed`. Missing: the sorted failure replay at the end                                                                                   |
| TDO5        | unverified | —                                                                                                                                                  | No command with a JSON mode runs on the executor yet                                                                                                                          |
| TDO6–TDO7   | planned    | `sparkles.base.ci_provider` (proposed)                                                                                                             | Per-provider golden output; no other provider's syntax; plain fallback                                                                                                        |
| TDY1–TDY3   | partial    | `libs/build-primitives/src/sparkles/build_primitives/task/graph.d`                                                                                 | `writePlan.dryRun`. Missing: a command-level dry run that checks no file is written                                                                                           |
