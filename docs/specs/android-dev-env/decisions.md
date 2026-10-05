---
status: draft
owner: sparkles:terminal
reviewed: 2026-10-05
---

# Environment decisions and design gates

## Accepted scope decisions

The project owner explicitly confirmed Q1–Q22 during the specification interview
on 2026-10-05. Q23–Q43 then established the application configuration policy,
including the explicit revision of invocation precedence in Q41/Q43. These choices establish scope; the detailed draft requirements and
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

| Gate                              | Required decision/evidence                                                                                                                                                                     | Blocks / decision point                                                             |
| --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| G1 — Dynamic configuration        | Wired owner defines dynamic ID → independent field resolution preserving metadata without whole-map selection; test P1                                                                         | Profile schema implementation; settle before resolver cutover                       |
| G2 — Import and writable layer    | Application policy is specified by TPC; refine source descriptor schema, file identities/limits, reload scheduling and transactional save coordination. Wired owns priority mechanism/encoding | P2/C1–C7 and settings migration; settle remaining mechanics before implementation   |
| G3 — Persisted compatibility      | Legacy startup commands and workspace migration, version markers, backup and downgrade behavior; no guessed argv or one-off replay                                                             | Profile cutover and P5; review fixtures first                                       |
| G4 — Native AVF support           | Exact stock firmware, grants, owner API and SDK/flavor constraints; F1/F2                                                                                                                      | Production owner/image architecture; no target device assumed connected             |
| G5 — Guest transport              | Independent PTYs, authority, protocol, buffer bounds, cancellation, namespace/lookup/inherited-env semantics; F3                                                                               | Production guest broker and E/P/R acceptance                                        |
| G6 — Storage/network/resources    | Firmware-specific units/defaults/limits, transfer interruption semantics, stopped/unbootable extraction, port transport; F4                                                                    | Resource/transfer/network implementation acceptance                                 |
| G7 — Distribution/authenticity    | Artifact hosting, integrity/authenticity trust root, signing/key handling and interrupted publication; PRoot channel/flake pinning                                                             | Provisioning and release acceptance, not mere builder success                       |
| G8 — Diagnostics and presentation | Redaction/export contract and reviewed profile/environment/recovery mockups                                                                                                                    | Diagnostic distribution and visible-context UI; ADE17 detail is proposed for review |

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

## Questions for the wired configuration owner

The project owner assigned authority over Q33 (priority design) to the concurrently
working wired.config agent. That agent must settle the following consumer questions
through its specification PR. Terminal requirements below are constraints on the
result, not a choice of generic policy names, numeric priorities, metadata encoding,
or resolver algorithm. Existing wired contracts should be cited where they already
answer a question; unresolved consumer support needs an explicit contract and gate.

| ID   | Question to settle in the wired specification PR                                                                                                                                                                                                                                                                                       |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| WQ1  | Which facility preserves dynamic profile/environment IDs across differently preferred sources and resolves each field independently, without whole-map/whole-object exclusion under WCFG12?                                                                                                                                            |
| WQ2  | How does the same mechanism resolve environment variables per name while argv remains atomic, with accurate per-field contributors and equal-priority conflicts?                                                                                                                                                                       |
| WQ3  | How do callers express source tiers and deliberate field overrides? Local UI overrides must win over CLI, configuration-environment, declarative, Termux and default inputs; main/imports have equal ordinary preference. Which authoring/metadata interface preserves these consumer constraints even if files can author priorities? |
| WQ4  | Which input/value policy distinguishes absent variable contributions, exact strings including empty strings, and selected explicit null? The terminal maps selected null to process-variable removal, not definition deletion.                                                                                                         |
| WQ5  | What input/snapshot operation removes a local definition so lower contributions become effective? Reset must not mean explicit null, compiled default, object deletion, or profile disabling. Persistence remains terminal-owned.                                                                                                      |
| WQ6  | How are incomplete disabled profile templates admitted and inspected, while enabled/requested profiles undergo required-field/reference validation? Supplied malformed values still fail decoding/admission.                                                                                                                           |
| WQ7  | How do sparse dynamic objects receive defaults exactly once without inventing undeclared IDs, injecting defaults as explicit source fields, or erasing weaker contributions? An explicitly empty object declares its identity.                                                                                                         |
| WQ8  | Which owning snapshots and typed references may the app retain for asynchronous launch, captured pane settings, reload rejection and inspection? Which visitor/reference data are borrowed and cannot outlive a snapshot?                                                                                                              |
| WQ9  | Which limits cover dynamic objects, generated fields, payloads, diagnostic metadata and retained snapshots, and what transactional failure prevents partial publication? File/import limits remain terminal-owned.                                                                                                                     |
| WQ10 | How can the application obtain resolved profile/environment references and contributor locations for missing, disabled or incompatible-target diagnostics, while retaining ownership of domain reference validation?                                                                                                                   |

### Consumer fixtures

These are hand-derived expectations, independent of the resolver implementation.
Names below describe values and source relationships; they do not prescribe a
JSON priority encoding or shipped API. Expand them into named tests in the owning
specification PR and link the resulting contracts back to this handoff.

```text
A (declarative):
  dev:   argv = ["recorder", "", "two words", "$HOME", ";"]
         env = { X: "old", Y: "keep" }
  build: argv = ["builder"]
B (stronger local settings):
  dev:   env = { X: "new" }
Expected:
  dev.argv unchanged; dev.env.X = "new"; dev.env.Y = "keep"
  build retained; X contributor B; argv/Y/build contributors A
```

```text
A: dev.env = { X: "old", Y: "keep" }
B (stronger): dev.env = { X: null }
Expected:
  selected X null remains inspectable; Y = "keep"
  terminal launch removes X from inherited process environment
Reset local X contribution:
  X = "old" becomes effective again; no null/reset conflation
```

```text
A and B equally preferred: dev.argv = ["recorder"] in each
Expected: located atomic conflict, including both definitions
A declares dev.argv; B declares dev.env with same object ID:
Expected: composition, not a duplicate-object error
Duplicate dev within one source:
Expected: located admission failure before key assignment loses evidence
```

Boundary fixtures also require: submission-order invariance; explicitly empty
objects versus absent objects; incomplete disabled templates versus enabled
missing-required-field errors; stronger empty argv selected then rejected without
weaker fallback; canonical dynamic keys containing punctuation; limit rejection
without partially retained keys/defaults; and retained values unaffected by decoder
buffer mutation/release. Existing [profile scenarios](./testing.md) remain the
consumer acceptance authority.

Terminal source acquisition, Home Manager read-only inputs, app-owned overrides,
import traversal, external reload, `--config` and configuration-environment
participation remain application policy. The wired resolver performs none of that
I/O. Q33 stays deferred until the wired owner's specification PR settles WQ3;
this handoff does not select `default`/`normal`/`override` labels or numeric bands.

## Configuration policy agreement (Q23–Q43)

The owner confirmed this revision at Q43. [Profile configuration](../terminal/profile-config.md)
owns the resulting TPC obligations; this record owns rationale and unresolved
implementation gates. No generic wired mechanism/encoding is accepted here.

| Decision                         | Accepted choice                                                                                                                                                              | Consequence / trade-off                                                                                                         |
| -------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| D-ADE10 — UI settings win        | Persistent local UI edits outrank CLI and configuration-environment inputs, even after restart                                                                               | Supersedes Q37's CLI-first proposal and the accepted TCF2 precedence on extension acceptance; reset reveals CLI/env/file values |
| D-ADE11 — Managed files          | Read-only Home Manager roots and imports are inputs; root-scoped local state is separately writable                                                                          | No managed-file rewriting or local-state loss on activation; state paths/versioning require host persistence review             |
| D-ADE12 — Root selection         | Default terminal-config.jsonc, legacy fallback; explicit --config replaces all root discovery but retains explicit imports, isolated local state, CLI and enabled config env | No implicit system/project roots; no creation of missing explicit roots                                                         |
| D-ADE13 — Explicit compatibility | Generated Android starter names every Termux compatibility input through an optional typed import                                                                            | No hidden Termux discovery; absent files harmless, existing malformed/unreadable inputs diagnosed                               |
| D-ADE14 — Partial and unset      | Sparse declarations compose; disabled templates may omit launch fields; env null explicitly unsets a process variable                                                        | Supplied malformed types still fail; reset removes a local definition instead of creating null                                  |
| D-ADE15 — Reload and save        | Observe file/symlink replacement; validate full snapshots; refuse stale saves and preserve pending drafts                                                                    | Watcher/safe-save bounds and external-writer coordination remain host implementation gates                                      |
| D-ADE16 — Conservative migration | Ordinary panes get appropriate built-in identities; legacy one-off strings stay inactive; backup and unsupported-version recovery                                            | No inferred argv; version/downgrade/backup transaction must be specified before cutover                                         |

Application acquisition limits, namespace encoding, configuration-variable bindings,
exact legacy adapter semantics and workspace format transactions remain explicit
terminal-owned gates. Q33 remains delegated; answering WQ1–WQ10 belongs to the
wired agent's specification PR. The terminal consumes that contract rather than
writing an alternative priority resolver.

## Configuration revision review

Scope: TPC1–TPC15, TPF12/13 and affected source/migration boundaries, reviewed
2026-10-05. This record covers the configuration revision independently of the
preceding environment draft review.

A fresh cold reader inspected only both contract openings, ending at the section-2
heading. The reader identified coherent ownership and acceptance boundaries.
Configuration-environment inputs are clarified as host process variables, root
path identity is named in the glance, and one-off commands link to a glossary entry.
A preceding reader accidentally saw body text; that pass is not counted as the
mandatory cold read. No implementation completion was inferred.

Independent adversarial review found no draft-publication blocker. It checked
persistent UI precedence, root isolation, Home Manager immutability, explicit imports,
CLI/config-env selection, disabled templates, null/unset and conservative migration.
The following refinements retain unmet implementation gates:

| Finding                                                                                             | Disposition / gate owner                                                                                                                     |
| --------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| Source aliases can share bytes but give relative imports different configured directories           | deferred: G2, terminal acquisition owner; define occurrence/base behavior and test reversed traversal plus alias cycle before implementation |
| Root A/B can share profile/environment ID spellings while referring to different execution contexts | deferred: G3, terminal workspace owner; settle root-scoped workspace or explicit cross-root recovery before persisted cutover                |
| Hash check followed by rename cannot alone prevent an uncoordinated external-write race             | deferred: G2, terminal persistence owner; specify writer coordination/publication assumptions and run C5 window fault injection              |
| Earlier final-review record could be mistaken for this revision's coverage                          | fixed: separate scoped review record here; corrected artifact requires final reader recheck                                                  |

These are explicit gates, not permission to infer behavior from generic wired
identity or atomic rename. The other agent's priority/merge specification authority
is preserved; no shared wired contract was edited by this revision.

Final strict opening recheck and final independent combined-artifact review found
no remaining blocker to draft publication. The review confirmed that the G2/G3
refinements remain unmet implementation gates and wired authority is unchanged.
