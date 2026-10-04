---
status: draft
owner: sparkles:terminal
reviewed: 2026-10-05
---

# Acceptance scenarios and evidence

This ledger owns evidence for [environment integration](./SPEC.md) and
[profiles](../terminal/profiles.md). Existing rendering, input and workspace
checks remain in [terminal testing](../terminal/testing.md). A shell prompt is
not evidence of the complete development workflow; a stock Microdroid boot is
not evidence of custom native-owned NixOS.

## Oracles and scenario matrix

Launch checks use a small independently implemented recorder that writes its
received argv, selected synthetic environment variables, cwd and PTY properties.
Expected values are literal fixture data, not generated through production launch
code. Separate process/guest observations identify execution and resource cleanup.
Configuration fixtures have hand-derived expected contributors and conflicts.
Filesystem markers and hashes check preservation; a browser response containing a
unique marker checks the real network boundary. Model tests supplement these
observations but cannot qualify firmware or native ownership.

| Scenario                  | Requirements                   | Actions and falsifying observations                                                                                                                                                                                                                                                                                                                                |
| ------------------------- | ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| P1 — Composition          | `TPF1`–`TPF3`                  | Module A contributes `dev` argv/env and `build`; stronger B changes one `dev` variable. Expect unchanged argv, other variables and `build`. Supply competing equally preferred argv arrays: expect a located conflict, never concatenation or last writer. Reverse submission order: same result. Missing references and duplicate IDs are rejected                |
| P2 — Imports and edits    | `TPF4`–`TPF5`                  | Resolve nested relative imports from their respective files. Exercise cycle, missing file, repeated import and configured byte/depth boundaries after policy selection. Save/reset one local field: imported files and unrelated fields unchanged. Failed reload retains a valid live snapshot but requested invalid target cannot launch                          |
| P3 — Exact launch         | `TPF2`, `TPF9`, `ADE7`         | Record `['recorder', '', 'two words', '$HOME', ';']`, synthetic env and cwd through every adapter. Observe literal bytes, correct namespace and independent PTY. Invalid cwd/NUL/empty executable causes no recorder entry. One-off on Android cannot execute in the host environment                                                                              |
| P4 — Selection            | `TPF6`, `TPF10`                | New tab uses platform default; split inherits focused profile/current cwd. Explicit different environment does not reuse incompatible cwd. Disabled/missing/unready selection shows recovery and creates no process elsewhere. Missing reliable cwd is disclosed                                                                                                   |
| P5 — Capture and restore  | `TPF7`–`TPF8`, `TPF11`         | Edit argv after launch: live snapshot and explicit rerun unchanged. Restore normal pane against latest profile; restore one-off at exit prompt with no recorder execution. Change/delete environment: recovery, no directory reinterpretation. Legacy one-off and unknown format cannot become automatic execution; workspace contains no captured variable values |
| E1 — Readiness            | `ADE4`, `ADE6`                 | Remove executable/grant or present incomplete external NNS stack. Observe named failed prerequisite and recovery action, no entry execution and no external stack mutation                                                                                                                                                                                         |
| E2 — Partial launch       | `ADE7`                         | Fail after partial PTY/process creation; inspect handles/processes for leaks and sibling effects. If command execution began, result says so. Ambiguous result is not automatically retried                                                                                                                                                                        |
| E3 — Cancellation         | `ADE8`                         | Cancel creation then deliver late success; remove/reconfigure target before completion. Expect cleanup, no attached pane or readiness publication, and no use-after-release                                                                                                                                                                                        |
| E4 — Provisioning         | `ADE5`–`ADE6`                  | Interrupt download/extraction/validation/publication and retry; issue simultaneous install/remove. Existing marker survives, partial target cannot launch, staging is identifiable and can be discarded explicitly. Fail artifact validation before readiness publication                                                                                          |
| B1 — PRoot                | `ADE2`, `ADE6`, `ADE7`         | Clean physical-device installation without another terminal app; first generation and final profile handoff. Record artifact and network requirements; separate panes run in the installed guest                                                                                                                                                                   |
| B2 — NNS                  | `ADE2`, `ADE6`, `ADE9`         | On explicitly provisioned physical stack, launch configured entry wrapper with recorder/login shell. Check independent panes. Close/stop app sessions and compare externally owned daemons/store before/after                                                                                                                                                      |
| B3 — AVF                  | `ADE2`–`ADE3`, `ADE7`, `ADE13` | Execute F1–F3 from PLAN on one exact stock Pixel firmware. Observe native owner, custom NixOS/systemd/store and distinct guest PTYs. A console-only result fails the session gate                                                                                                                                                                                  |
| W1 — Development          | `ADE1`                         | Fetch project through Git/SSH with synthetic test credentials; edit with LSP feedback; enter flake dev environment, build, run tests, execute result. Record revisions and independently verify resulting behavior. Repeat per backend; second language is not required                                                                                            |
| L1 — Activity lifecycle   | `ADE10`                        | Background and recreate activity while owner lives; continuous marker job and session identity persist. Repeat documented Android pressure case; owner loss becomes disconnected/recovery rather than false success                                                                                                                                                |
| L2 — Explicit stop        | `ADE9`                         | Close one of two sessions: sibling survives. Close last AVF pane: VM stays running. Decline stop: unchanged. Confirm stop with active sessions: new launch refused, affected sessions end, resources released; NNS external resources remain                                                                                                                       |
| L3 — Owner death          | `ADE10`–`ADE11`, `TPF8`        | Write/hash project, kill owner/force-stop/reboot, recover workspace. Data survives under documented storage assumptions; one-off execution counter does not increment. No claim of live job reattachment                                                                                                                                                           |
| D1 — Rebuild and recovery | `ADE13`                        | Perform documented guest config rebuild; stop/start and check project hash. Exercise failed boot and documented recovery with synthetic disposable disk. Unsupported boot-asset changes are not represented as safe upgrades                                                                                                                                       |
| D2 — Preservation/removal | `ADE5`, `ADE11`, `ADE13`       | Update app with existing project; no disk replacement. Decline removal: hash and sessions unchanged. Confirm named environment removal: only authorized data removed. Document uninstall/storage-clear exclusions                                                                                                                                                  |
| D3 — Transfer             | `ADE12`                        | Import/export a nested project and compare file hashes. Interrupt transfer: source intact and incomplete output identified. Test stopped/unbootable guest procedure where supported and explicitly record inaccessible cases                                                                                                                                       |
| N1 — Browser/network      | `ADE1`, `ADE14`                | Outbound Git/Nix requests succeed under documented conditions. Android browser reads unique local server marker. Occupied host port causes exact conflict, not new port. Without explicit LAN configuration, remote client cannot connect. Stop releases owned listener                                                                                            |
| R1 — Resource limits      | `ADE15`                        | Exercise default, minimum/maximum and just-outside values from qualified firmware. Compare configured/effective values. Unsupported CPU/memory requests rejected, not reduced; change applies only to stopped guest next start                                                                                                                                     |
| R2 — Exhaustion/authority | `ADE15`–`ADE16`                | Fill disposable disk and transport queues; no project/store auto-deletion, bounded buffers, control/teardown still works. Synthetic unauthorized/stale session requests cannot launch commands, read session output or affect another session                                                                                                                      |
| R3 — Privacy              | `ADE17`, `TPF8`                | Put synthetic secret markers in argv/env/output/project. Default logs, workspace and report preview contain no prohibited values; review explicit export/redaction separately                                                                                                                                                                                      |

Firmware-dependent scenarios run on the qualified configurations, not every
Cartesian combination. Desktop qualifies shared profile semantics; PRoot and NNS
qualify their own execution namespaces; the stock Pixel qualifies AVF. Tablet
layout/input evidence remains separately scoped. A missing device, skipped test,
console-only pass or rooted-only result leaves its required gate unmet.

Boundary refinements: P1 accepts the same object ID across modules and rejects
duplicates within one source/definition identity. P5 restores saved reliable `/B`
when the old profile started `/A` and the latest starts `/C`; inaccessible `/B`
produces recovery. L2 observes an empty workspace and live owner after last-pane
closure, then separate explicit quit. L2 also opens a session while stop
confirmation is displayed: the changed affected set must be confirmed again.
P3/E1 permit authorized readiness/namespace probes, but reject execution of the
requested argv with invalid cwd or an unready target.

Before implementation, each first-slice scenario becomes a named executable test
or repeatable human procedure with explicit assertions. Harness mutation checks
must catch joined argv, erased profile keys, automatic one-off replay, and incorrect
loopback binding. There is no acceptance command for an unimplemented test.

## Evidence ledger

| Record    | Checked scope and revision                                                                                                                                                                        | Result                                                                        | Remaining gap                                                                                         |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| BASE-1    | Terminal implementation/spec at `d43f88a39`; [accepted terminal ledger](../terminal/testing.md) and [Android integration](../terminal/android.md)                                                 | partial: bootstrap, PTY/workspace, viewer and phone/tablet observations exist | Existing named partial rows remain; none certifies this complete environment contract                 |
| BASE-2    | Owner's interview Q1: nix-on-droid and NNS tested on physical devices                                                                                                                             | partial: user-reported experience                                             | No replayable profile/workload suite or exact NNS test snapshot establishes B2/W1                     |
| BASE-3    | [Device research](../../research/android-dev-env/device-validation/index.md) and [Pixel 7 report](../../research/android-dev-env/device-validation/pixel7.md), scoped to their recorded revisions | partial: stock Pad protected Microdroid and rooted Pixel inventory            | No proof of stock Pixel native ownership/custom NixOS/multi-PTY; historical reports remain historical |
| PROFILE-1 | Draft `TPF1`–`TPF11`, scenarios P1–P5                                                                                                                                                             | unverified                                                                    | New profile integration and dynamic resolution not implemented                                        |
| ENV-1     | Draft `ADE1`–`ADE17`, E/B/W/L/D/N/R scenarios                                                                                                                                                     | unverified                                                                    | Required backend suite, native spikes and release qualification not run                               |

Record each subsequent observation with requirement IDs, exact source/artifact
revision or explicit dirty snapshot, command/test, firmware/grants/configuration,
result, artifact and residual gap. Do not store real secrets or raw personal data.
`verified` means the declared suite passed for that named configuration.

## Draft review and publication

Cold-read and adversarial review findings and their dispositions are recorded in
[decisions](./decisions.md#draft-review). Publication checks validate navigation,
glossary, evidence references and rendering; they do not establish backend support.
