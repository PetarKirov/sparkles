---
status: draft
owner: sparkles:build-primitives
reviewed: 2026-11-06
---

# Observability — Delivery plan

_Companion to [SPEC.md](./SPEC.md). Each milestone is independently green, and
its gate names the oracles in [testing.md](./testing.md) it must pass._

Observation is delivered beside the work it measures. Its first slice is built
alongside the [build graph](../build-graph/PLAN.md)'s E3, whose actions and
store it instruments, and its first records come with
[`apps/ci`](../../ci/task-dag/PLAN.md) M7, the `ci test` cutover. Comparison
and the gate come last, once history exists to calibrate them.

## O0: Specification and spikes

- This specification, reviewed.
- Spikes S1, S3 and S5 before O1 starts, because they decide the counter,
  time-trace and spawn sources that O1 builds. S2, S4, S6 and S7 before the
  milestones that need them: O6, O3 and O5.
- The amendments this specification needs elsewhere, each in its owner's
  page:
  - the build graph: BGA3 and BGA6 name the measurement directory, and BGN5
    excludes the measurement output (OBD8), made with this specification;
    BGA8 adopts the task-id form of OBD2 at E2, and points to it;
  - `apps/ci`: §5.7's unavailable sampling is a run degradation, not a
    `Degraded` outcome (invariant 1, OBD11), made with this specification;
  - the test runner's process model: TRP1 admits `sparkles:metrics` and
    `sparkles:metadata`, and TRP16's `result` frame gains `usage` (OBV2,
    OBT1), on the branch that holds that page.

Gate: the specification passes the documentation checks and an adversarial
review; each spike's result is recorded in [decisions.md](./decisions.md); the
amendments are accepted by their owners.

## O1: The vocabulary and action accounting, with build graph E3

- `sparkles:metrics` with the descriptors of SPEC §4–§9, and the test runner's
  catalog types moved into it (OBV1–OBV9). Event Horizon's quality type becomes
  the vocabulary's.
- Event Horizon's supervised runs read accounting at the root's exit, before
  reaping, and attach counters before `exec`, by the path S5 chose (OBA1–OBA3).
- Queue wait and the executor's measurement table (OBA4–OBA5).
- The cache family in E3's store: outcomes, miss reasons, the eviction journal,
  line counts in the digest cache, and key and lookup times (OBA7–OBA9, OBC5).
- The measurement directory, and measurements stored with results as metadata
  (OBD8), except the Nix backend's separate output, which comes with E4.

Prerequisites: S1, S3 and S5; the TRP1 amendment, before the harness uses the
vocabulary.

Gate: oracles 1, 2, 3 and 5 pass on Linux. E3's test-only driver prints each
action's measurements for the repository's test selection.

Exclusions: no run record, no compile or link family, no history.

## O2: Run records and reports, with `apps/ci` M7

- Local run records with the process, counters, stall, cache and run families
  and the facts (OBD1–OBD7, OBD9–OBD12, OBR1–OBR7, OBV6).
- The privacy rules and the scan (OBP1–OBP4).
- `ci perf show` (OBQ1–OBQ2, OBQ6–OBQ8) and the `--observe` option (OBO3).
- The plain, TTY and CI-provider summaries (OBU1–OBU5), and the stall
  columns of `show` (OBA6).

Gate: oracles 4, 10, 11 and 15 pass, and oracle 16 for `show`, `--observe`
and the reporters. Every `ci test` run writes a record that passes the scan.

## O3: Compile and link families

- The fork's time-trace summary mode (OBC8), with tests that fail without it,
  and the toolchain bumped to it; the reduced coarse trace for DMD (OBC7).
- Phases, the heaviest events and modules, and template counts (OBC1–OBC4).
- ELF object analysis and `ld.lld` link analysis (OBC6, OBL1–OBL3).
- `--keep-traces` (OBO4).

Prerequisites: S3 and S4.

Gate: oracles 6, 7 and 8 pass, oracle 14 passes with LDC and DMD, and oracle
16 for `--keep-traces`. A family that misses the budget ships off by default,
and the decision is recorded.

## O4: Test usage

- The `usage` member of the runner protocol's `result` frame, implemented in
  the harness (OBT1–OBT2).
- Binary metrics and flakiness in the runner core's `ci` client, recorded in
  the run record (OBT3).

Prerequisites: `apps/ci` runs tests through the runner core (TRM5–TRM8 of the
test runner's process model); the TRP16 amendment.

Gate: oracle 9 passes, including its older-runner and older-worker scenarios.

## O5: History on `refs/perf/data`

- The ref and its README, the signing keys, the allowed-signers file and the
  environment that holds the CI key, and signature checks in every reader
  (OBH1–OBH2, OBH6, OBH8).
- Appending from CI on the mirror and rebuild paths, with validation
  (OBH3–OBH5), and CI job metrics (OBJ1–OBJ3).
- `ci perf push`, `fetch` and `history`, with flakiness and no-op marks, the
  cached partial clone, and offline behaviour (OBH9–OBH10, OBQ4–OBQ5).
- The compaction workflow (OBH7).
- `runGit` gains what the fixed commit identity needs.

Prerequisites: S6 and S7; CI workflows running `ci test` (`apps/ci` M7).

Gate: oracle 12 passes against a local remote, oracle 16 for `history`,
`push` and the CI job metrics, and oracle 17. S6's size model meets OBH7's
bound. A week of `main` landings appends with no lost record.

## O6: Comparison and the gate

- `ci perf compare`, with comparability, the noise model, the threshold and
  the `stalled` mark (OBG1–OBG10, OBQ3, OBA6).
- The gate in CI, report-only: it reports in the step summary and never fails a
  job.
- Calibration of OBG5's priors and floors from S2 and the accumulated history;
  then enforcement.

Prerequisites: S1, which fixes each environment's gate metric (OD20), and S2.

Gate: oracle 13 passes, oracle 16 for `compare`, and the gate is enforcing on
every leg whose gate metric S1 established, the `cpu-user` gate once S2 has
calibrated it.

## O7: Platform parity and the Nix backend

- The macOS and Windows sources of SPEC §4 and §7, by the paths S5 verified.
- Mach-O and COFF object analysis, and `lld-link`'s reports (OD17).
- The measurement output as a separate derivation output under the Nix
  backend, with build graph E4 (OBD8).

Gate: oracles 2, 3 and 8 on macOS and Windows, and oracle 10's Nix scenario.

## Progress

| Milestone | Deliverable                         | State       |
| --------- | ----------------------------------- | ----------- |
| O0        | Specification and spikes            | in review   |
| O1        | Vocabulary and action accounting    | not started |
| O2        | Run records and reports             | not started |
| O3        | Compile and link families           | not started |
| O4        | Test usage                          | not started |
| O5        | History on `refs/perf/data`         | not started |
| O6        | Comparison and the gate             | not started |
| O7        | Platform parity and the Nix backend | not started |
