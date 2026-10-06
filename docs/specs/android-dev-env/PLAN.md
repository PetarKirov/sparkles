---
status: draft
owner: sparkles:terminal
reviewed: 2026-10-05
---

# Android development environment delivery plan

This is the milestone tracker for the whole terminal-based Nix development
product. `ADE-M0`–`ADE-M10` retain the original broad project sequence; the prefix
distinguishes them from the existing [terminal UI milestones](../terminal/PLAN.md).
Requirements belong to [SPEC.md](./SPEC.md) and [profiles](../terminal/profiles.md).
Evidence belongs to [testing.md](./testing.md). Scope agreement is not implementation
completion; terminal milestone summaries retain their named partial gaps.

## Milestones

| Milestone                                 | Deliverable and obligations                                                                           | Prerequisites                                        | Acceptance gate                                                                                  | Exclusions                                                          | State                                                                                                       |
| ----------------------------------------- | ----------------------------------------------------------------------------------------------------- | ---------------------------------------------------- | ------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| ADE-M0 — Scope and contracts              | Reviewed contracts, ownership and support tiers (`ADE1`–`ADE3`, compatibility map)                    | Interview scope agreement                            | Cold read, adversarial review, doc checks; explicit contract acceptance                          | Implementation-completion claim                                     | in progress: scope confirmed; draft review and feasibility gates remain                                     |
| ADE-M1 — Environments and profiles        | Shared launch contract, modular configuration and readiness (`TPF1`–`TPF11`, `ADE4`, `ADE7`–`ADE8`)   | M0; wired dynamic resolution and migration decisions | P1–P5 and E1–E3 in testing                                                                       | Remote session attach                                               | partial: PTY/workspace foundations exist; profile integration not started                                   |
| ADE-M2 — Complete Nix workflow            | Git/SSH, editor/LSP, flake build/test/run (`ADE1`)                                                    | M1 and usable backend                                | W1 on each qualified backend                                                                     | Second language suite                                               | partial: bootstrap and physical-device experience; complete workflow unverified                             |
| ADE-M3 — Android terminal experience      | Existing accepted input/render/session/integration obligations                                        | Existing terminal delivery                           | Close applicable partial rows in terminal testing; phone/tablet/keyboard exercise                | Redesign of accepted surfaces                                       | partial: most UI delivered; named verification gaps remain                                                  |
| ADE-M4 — Provisioning and reproducibility | Versioned artifacts, staged install/retry, documented guest rebuild/recovery (`ADE5`–`ADE6`, `ADE13`) | M0; artifact policy; boot compatibility              | E4 and D1–D2 including interrupted provisioning                                                  | Automatic image upgrade/rollback; complete offline promise          | partial: bootstrap and builders exist; integration gates unmet                                              |
| ADE-M5 — Backend coverage                 | PRoot, NNS and AVF qualification (`ADE2`–`ADE3`, `ADE7`)                                              | Native owner/boot/PTY spikes; M1/M4                  | B1–B3 and backend-specific W1; exact stock Pixel recorded                                        | QEMU TCG; universal SoC support                                     | partial: PRoot/NNS device experience, stock Microdroid research; custom native NixOS integration unverified |
| ADE-M6 — Lifecycle and recovery           | Owner/pane distinctions, backgrounding, restore (`ADE8`–`ADE11`, `TPF7`–`TPF8`)                       | M1/M5                                                | L1–L3, stale completion and death traces                                                         | Live job restoration across owner death                             | partial: layout/fresh-shell restoration exists; profile/environment lifecycle unverified                    |
| ADE-M7 — Android development integration  | Project transfer, browser development server (`ADE12`, `ADE14`)                                       | M2/M5; transport proof                               | D3 and N1 on each backend                                                                        | Live folders; transparent network; deeper Podroid features          | partial: clipboard/notifications/viewer exist; transfer/network qualification unmet                         |
| ADE-M8 — Safe operation and maintenance   | Bounds, removal, exhaustion and privacy (`ADE11`, `ADE15`–`ADE17`)                                    | Resource/authority design; M4–M7                     | R1–R3 and D2–D3                                                                                  | Automatic tuning/shrink; NNS management                             | partial: persistence/staging foundations; environment-specific gates unmet                                  |
| ADE-M9 — Qualification                    | Exact support matrix and independent acceptance                                                       | M1–M8                                                | Required scenarios passed, skips recorded as unmet; independent review                           | Exhaustive Android device coverage; invented performance guarantees | partial: host/phone/tablet evidence; backend release suite unverified                                       |
| ADE-M10 — Distribution                    | Published signed artifacts and procedures                                                             | M9; release artifact policy                          | Clean on-device PRoot installation, documented NNS/AVF provisioning, published artifacts checked | Play Store commitment                                               | partial: builders/docs exist; publication and release qualification unmet                                   |

## Delivery order and next slices

Milestones are not a strict waterfall. Run the AVF blockers early beside profile
work; a successful PRoot slice cannot replace the required AVF gate.

1. **Configuration/profile slice.** Consume the wired owner's specification PR
   answering [WQ1–WQ10](./decisions.md#questions-for-the-wired-configuration-owner).
   [TPC](../terminal/profile-config.md) settles application source precedence,
   Home Manager isolation, imports and migration policy; refine its remaining
   host acquisition/transaction/format gates, then implement explicit
   argv/env/cwd profiles on desktop and externally provisioned NNS. Execute P1–P5,
   E1–E3 before expanding backend ownership. No implicit shell-string migration.
2. **AVF feasibility slice, in parallel.** Execute F1–F3 below on exact firmware.
   Record negative results. Do not choose an unproved native owner or session wire
   protocol as production architecture.
3. **PRoot integration slice.** Route bootstrap completion, tabs, splits and
   one-offs through profiles; verify fresh-install handoff, current directory and
   restore on device. Keep first-generation network requirements explicit.
4. **AVF product slice.** After F1–F3, refine transport authority/bounds and resources,
   stage the image, implement lifecycle/network/transfer, and run the full suite.
5. **Release closure.** Close accepted terminal gaps relevant to the workload,
   document support tiers and recovery, independently review the combined artifact,
   and qualify installation from published artifacts.

## Bounded feasibility experiments

| ID  | Question and experiment                                                                                                                                                                     | Decision criterion                                                                                                                        | Owner / blocked work                                                   |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| F1  | Can a no-DEX app/helper own AVF on one stock Pixel build? Record framework APIs, declarations/grants and SDK flavor constraints; native probe creates, starts, observes and stops a test VM | Repeated native ownership succeeds under documented grants without managed code or unverifiable private-API assumptions                   | terminal Android integration; blocks AVF owner design and distribution |
| F2  | Can that owner boot custom NixOS? Build a pinned guest artifact and observe systemd, canonical store and disk persistence across stop/start                                                 | Guest reaches a verifiable ready state and preserves a written marker; Microdroid success is insufficient                                 | AVF adapter/image integration; blocks NixOS provisioning               |
| F3  | Can a native broker deliver independent guest sessions? Launch two instrumented commands with different argv/env/cwd; interleave resize, output, exit and close                             | Independent PTYs, exact launch values, exit status and cleanup; unauthorized/stale control rejected; bounded buffering demonstrated       | AVF session transport; blocks production pane transport                |
| F4  | What resource and file/network capabilities are usable on that build? Probe RAM/CPU/disk requests, loopback forwarding and stopped/unbootable guest extraction                              | Document exact supported ranges and observed effective values; required transfer/browser cases work or receive an explicit scope decision | AVF integration; blocks limits, recovery and networking acceptance     |

Each spike records app/source revisions, artifact identity, firmware, grants,
commands, raw result and remaining limitations in the evidence ledger. Stop at
its stated criterion; prototypes do not bypass production acceptance.

## Resume point

Historical baseline: `d43f88a39`; PR #586 landed as `bc69a5216`.
Interview Q1–Q49 establishes scope/application policy, not implementation conformance.
The configuration slice is specified by TPC and TPF12/13; the generic wired seam
is delegated to its owner through WQ1–WQ10. TPC6/11/16/17 settle alias ambiguity,
supported-writer assumptions, root-scoped workspaces and unsupported-version recovery.
TPC18/19 settle retained migration/reset backups and legacy workspace destinations.
Next executable actions are the wired handoff and specification of terminal
acquisition bounds, writer coordination and persisted-format transactions, alongside
F1 native ownership evidence. Profile, resolver, watcher and migration code remains
unimplemented; no device is assumed connected.
