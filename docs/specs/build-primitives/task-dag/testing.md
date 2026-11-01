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

The
tests live in `libs/build-primitives` and, for the TTY reporter, in
`apps/ci`.

## Evidence ledger

Test names below are the `@("…")` names under `build_primitives.task.` or
`build_primitives.workspace.`, shortened by that prefix; the TTY reporter's are
under `task.reporter_tty.`. Rows marked `verified` passed on Linux (kernel 6.18,
LDC 1.43) on 2026-11-01. `partial` rows name what is missing; `planned` and
`unverified` rows ran nothing.

| Requirement | Status     | Evidence                                                                                                                                                                                                       | Missing                                                                      |
| ----------- | ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| TDS1, TDS3  | verified   | `package_graph.buildPackageGraph.rejectsInvalidGraphs`, `package_graph.buildPackageGraph.configurationAwareEdges`, `package_graph.discoverPackages.thisRepository`                                             | —                                                                            |
| TDS2        | partial    | `package_graph.buildPackageGraph.configurationAwareEdges`                                                                                                                                                      | the unittest configuration's `platforms`; `platform` on dependencies         |
| TDS4        | verified   | `select.selectPackages.fromExactAndGlob`, `select.selectPackages.emptyMatchesAreErrors`                                                                                                                        | —                                                                            |
| TDS5–TDS6   | partial    | `select.gitChangesSince.fixtureRepository`, `select.gitChangesSince.defaultBaseAndErrors`, `select.selectPackages.sinceOwnershipDeletionsAndInvalidators`                                                      | consumer-supplied invalidators; staged-then-deleted and unstaged-index paths |
| TDS7–TDS8   | verified   | `select.selectPackages.closuresAreAFixedPointUnion`, `select.selectPackages.platformSkippedSeedsAreNotEmpty`, `select.selectPackages.cyclicGraphsNeverReachSelection`                                          | —                                                                            |
| TDM1–TDM3   | verified   | `model.taskId.formatting`, `action.writeActionSummary.process`, `action.writeActionSummary.inProcessAndInert`                                                                                                  | —                                                                            |
| TDM4        | verified   | `process.redact.masksEveryOccurrence`, `process.run.timeoutAndRedaction`                                                                                                                                       | —                                                                            |
| TDM5–TDM6   | partial    | `graph.resolveEdge.conditions`, `graph.propagateBlocked.cascadesAndKeepsTheRoot`, `graph.propagateBlocked.successBlocksTheFallbackWithoutFailing`                                                              | provisional blocks; `conditionUnmet` under cancellation; the cancelled rule  |
| TDM7–TDM8   | verified   | `executor.admission.capacityAndPresentationOrder`, `executor.admission.exclusiveKeysSerializeOnlyTheirHolders`, `executor.admission.noStarvationOfAHeavyTask`, `executor.admission.overCapacityClaimRunsAlone` | —                                                                            |
| TDM9–TDM10  | partial    | `model.ResourceClaim.defaultsAndClamp`                                                                                                                                                                         | build-graph weights; the capacity formula                                    |
| TDM11       | verified   | `model.TaskOutcome.kindAndFailure`, `graph.readiness.preferAFailureCauseRegardlessOfCompletionOrder`                                                                                                           | —                                                                            |
| TDM12       | partial    | `executor.run.eventsAreSequencedAndMonotonic`                                                                                                                                                                  | task-local stream and chunk sequence numbers                                 |
| TDM13–TDM14 | partial    | `process.run.reporterOnAnotherWorker`, `output.OutputSpool.spillsLosslesslyAndKeepsATail`, `process.run.largeOutputSpillsToTheSandbox`                                                                         | spilled lines containing line breaks                                         |
| TDE1–TDE3   | partial    | `process.run.reporterOnAnotherWorker`, `process.run.exitStatusesArgvAndFraming`                                                                                                                                | an import audit for the forbidden constructs; Windows                        |
| TDC1–TDC2   | partial    | `executor.failFast.blockedCancelledAndCleanup`, `process.run.failFastTearsDownTheTree`                                                                                                                         | cleanup nodes during an abnormal drain                                       |
| TDC3        | partial    | `executor.failFast.simultaneousFailuresPickTheLowestKey`                                                                                                                                                       | an interrupted node that reports `Failed`                                    |
| TDC4        | partial    | `executor.failFast.provisionalFailureFallsBackWithoutCancelling`                                                                                                                                               | provisional blocks                                                           |
| TDC5–TDC6   | partial    | `executor.cancel.externalInterrupt`                                                                                                                                                                            | a real signal delivered to a running command                                 |
| TDD1–TDD2   | verified   | `executor.run.outcomesIndependentOfCompletionOrder`, `graph.build.orderIsIndependentOfInsertionOrder`, `graph.build.reportsTheShortestCycleFromItsLowestMember`, `graph.stableTopologicalOrder.tiesAndCycles`  | —                                                                            |
| TDO1, TDO3  | partial    | `reporter_plain.transcriptIsIdenticalAcrossCompletionOrders`, `reporter_plain.spilledBlocksReplayInFull`, `reporter.OrderedBlocks.releasesInPresentationOrder`                                                 | the output policies; the unneeded count in the summary                       |
| TDO2        | partial    | `task.reporter_tty.interactiveShowsTailsAndRestoresTheCursor`, `task.reporter_tty.nonInteractiveDegradesToPlainLines`                                                                                          | collapsing past a height limit; a timer-driven spinner                       |
| TDO4        | partial    | `reporter_plain.interlacedIsImmediateLineAtomicAndPrefixed`                                                                                                                                                    | the sorted failure replay at the end                                         |
| TDO5        | unverified | —                                                                                                                                                                                                              | no command with a JSON mode runs on the executor                             |
| TDO6–TDO7   | planned    | `sparkles:ci-provider`                                                                                                                                                                                         | everything                                                                   |
| TDY1–TDY3   | partial    | `graph.writePlan.dryRun`                                                                                                                                                                                       | a command-level dry run that checks no file is written                       |
