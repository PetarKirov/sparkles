---
status: draft
owner: sparkles:terminal
reviewed: 2026-10-05
---

# Environment decisions and design gates

## Accepted scope decisions

The project owner explicitly confirmed Q1–Q22 during the specification interview
on 2026-10-05. These choices establish scope; the detailed draft requirements and
implementation conformance require their own reviews. Revisit a choice explicitly
if feasibility evidence conflicts with it.

| Decision                        | Choice and rationale                                                                                                                            | Trade-off / revisit condition                                                                           |
| ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| D-ADE1 — Release backends       | PRoot/nix-on-droid, external NNS and AVF/NixOS all required. AVF pressure-tests ownership and supplies a reason to switch from Android Terminal | Higher release risk; failed native/boot spikes require a product decision, not silent AVF deferral      |
| D-ADE2 — Profiles               | Cross-platform environment/profile/pane separation; explicit argv/env; modular contributions by ID and field                                    | Shared configuration prerequisite; no shell-command mode or implicit command-string conversion          |
| D-ADE3 — Provisioning authority | Sparkles installs ordinary PRoot on device and provisions a documented AVF image. NNS is explicitly provisioned outside Sparkles                | ADB/root documentation permitted; native-store installation/management excluded                         |
| D-ADE4 — AVF qualification      | One exact stock Pixel firmware with explicit development grants; native-only components                                                         | No universal Pixel/Qualcomm/MediaTek promise; SDK/API feasibility can block architecture                |
| D-ADE5 — Launch and restore     | Platform default tabs, inherited splits, captured live rerun, latest-ID restore; one-offs never auto-replay                                     | Configuration edits can cause restore recovery; live process reattachment excluded                      |
| D-ADE6 — Lifecycle              | Owner retains AVF after last pane closes; confirmed stop ends active sessions. NNS daemons/store external                                       | VM can consume resources with no panes; Android owner death may end jobs                                |
| D-ADE7 — Data and updates       | Persistent local project storage, documented import/export/recovery; in-guest NixOS rebuild                                                     | App-managed image upgrades/rollback and live Android folders excluded; recovery may be platform-limited |
| D-ADE8 — Network/resources      | Explicit browser access; loopback forwarding default; configurable documented AVF resources                                                     | Firmware-specific limits; no silent port/CPU fallback, automatic tuning or disk shrink                  |
| D-ADE9 — Deferred integration   | QEMU TCG, deeper Podroid features and second-language qualification excluded                                                                    | Revisit after fundamental workflow and ownership gates are met                                          |

## Open design gates

These are explicit refinements of the draft, not authorization to weaken the
accepted scope. Their owner is terminal integration unless named otherwise.
They block the indicated implementation/acceptance work; publication of a draft
can proceed without claiming Stage 0 feasibility completion.

| Gate                              | Required decision/evidence                                                                                                                                               | Blocks / decision point                                                             |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------- |
| G1 — Dynamic configuration        | Wired owner defines dynamic ID → independent field resolution preserving metadata without whole-map selection; test P1                                                   | Profile schema implementation; settle before resolver cutover                       |
| G2 — Import and writable layer    | Define repeated imports, source identities/priorities, finite limits and dedicated local override persistence; preserve existing TCF precedence and TSP deliberate edits | P2 and settings migration; settle before config implementation                      |
| G3 — Persisted compatibility      | Legacy startup commands and workspace migration, version markers, backup and downgrade behavior; no guessed argv or one-off replay                                       | Profile cutover and P5; review fixtures first                                       |
| G4 — Native AVF support           | Exact stock firmware, grants, owner API and SDK/flavor constraints; F1/F2                                                                                                | Production owner/image architecture; no target device assumed connected             |
| G5 — Guest transport              | Independent PTYs, authority, protocol, buffer bounds, cancellation, namespace/lookup/inherited-env semantics; F3                                                         | Production guest broker and E/P/R acceptance                                        |
| G6 — Storage/network/resources    | Firmware-specific units/defaults/limits, transfer interruption semantics, stopped/unbootable extraction, port transport; F4                                              | Resource/transfer/network implementation acceptance                                 |
| G7 — Distribution/authenticity    | Artifact hosting, integrity/authenticity trust root, signing/key handling and interrupted publication; PRoot channel/flake pinning                                       | Provisioning and release acceptance, not mere builder success                       |
| G8 — Diagnostics and presentation | Redaction/export contract and reviewed profile/environment/recovery mockups                                                                                              | Diagnostic distribution and visible-context UI; ADE17 detail is proposed for review |

No planned symbol is evidence of an implemented facility. Wired configuration is
a draft resolver specification: its whole-map `WCFG12` is not the required dynamic
object policy. AVF consoles and prior-art managed helpers do not prove the native
multi-session boundary. Protocol and persistence designs need operation/boundary
contracts before implementation, not guessed API sketches here.

## Draft review

Review scope: new environment contract and profile extension, especially per-ID
composition, non-replay, owner lifetime, provisioning publication and AVF evidence.
A cold reader receives only each new contract's opening. An independent adversarial
reader inspects the final contracts, scenarios and compatibility boundaries.
Findings and dispositions:

| Finding                                                                           | Disposition and validation                                                                                                                                                                  |
| --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Cold read: NNS/AVF/DEX unexplained; persistence/stop boundaries unclear           | fixed: expanded names, named persistent operations and external owner boundary; opening recheck required                                                                                    |
| Cold read: atomic argv and restored exit prompt unclear                           | fixed: whole-array replacement and inactive restored pane explained                                                                                                                         |
| Cold read: abstract present tense might imply delivery                            | rejected: spec-prose requires a system description rather than document narration; draft front matter, unverified ledger and explicit release requirements distinguish intent from evidence |
| Cold read: TPF title abbreviation and configuration identity                      | fixed identity explanation; TPF retained as requirement namespace, consistent with terminal topic pages                                                                                     |
| Cold read: inconsistent workspace owner links                                     | fixed: sessions identified as the terminal specification's workspace contract                                                                                                               |
| Adversarial: last-pane close could kill AVF owner through TSS5                    | fixed: explicit empty-workspace outcome and compatibility amendment; L2 tests separate close and quit                                                                                       |
| Adversarial: repeated IDs could forbid composition                                | fixed: cross-module object contributions distinguished from source-local/definition duplicates; P1 refined                                                                                  |
| Adversarial: restored directory precedence absent                                 | fixed: reliable saved cwd wins in unchanged environment; inaccessible cwd enters recovery; P5 refined                                                                                       |
| Adversarial: TSS8 and namespace preparation boundaries omitted                    | fixed: compatibility row and authorized preparation versus requested entry execution distinction                                                                                            |
| Adversarial: stop confirmation session-set race                                   | fixed: changed set requires reconfirmation; L2 refined                                                                                                                                      |
| Exact imports, migration, native AVF, transport, resources and publication policy | deferred: G1–G8 name owners and blocked delivery gates; no Stage 0 feasibility or release completion claim                                                                                  |

The draft's detailed privacy, cancellation and compatibility clauses are review
proposals derived from the agreed scope, not separately accepted implementation
designs. Their owning gates require review before implementation.

Final read-only rechecks found no opening blockers and no remaining adversarial
blocker to draft publication. Independent readers checked the corrected combined
artifact, including the additional scenario traces. The optional opening note on
guest directory namespaces is covered explicitly by `TPF2`. This review does not
accept an implementation or waive G1–G8.
