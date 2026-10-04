---
status: draft
owner: sparkles:wired
reviewed: 2026-10-04
---

# `sparkles.wired.config` — Delivery plan

This is the single milestone tracker for the
[resolver contract](./SPEC.md) and [shared inspection](./inspection.md).
Contract acceptance is distinct from implementation progress. The specification
PR establishes a reviewable draft, not a shipped module or approved app migration.

## Delivery dependencies

```text
C0 specification review
  -> C1 scalar definitions and conflict inspection
  -> C2 collection/submodule resolution
  -> C3 property-tree/table report and documentation links
  -> C4 hue and terminal cutover
  -> C5 diagram wire adapter and cutover
```

C1 uses a throwaway driver over the actual resolver. C3's fixture is host-free;
C4/C5 exercise actual app commands. No milestone introduces a package dependency
from wired to UI or CLI. Later slices refine their unresolved contracts before
starting, rather than implementing around confident-looking interface sketches.

## Milestones

| Slice | Obligations                            | Status      | Required result                                                                           |
| ----- | -------------------------------------- | ----------- | ----------------------------------------------------------------------------------------- |
| C0    | Scope, decisions, oracles, publication | in progress | Independently reviewed draft with explicit blocking questions                             |
| C1    | WCFG1–10, WCFG14, WCFG17–21            | not started | Finite scalar/string definition resolver, complete conflict snapshot, explicit limits     |
| C2    | WCFG11–16, WCFG20–21                   | not started | UDA-directed lists, lines, maps, nested sections, contributor traces                      |
| C3    | WCI1–15, WCFG24                        | not started | Host-free property/source/value report, all-definitions mode, capability-gated docs links |
| C4    | WCFG22–24, WCI1–15                     | not started | Hue and terminal startup/report/persistence use one definition model                      |
| C5    | WCFG22–24, WCI1–15                     | not started | Diagram preserves its grid wire contract and shares resolution with startup               |

The obligations listed for C1 apply to its scalar/string subset; C2 closes their
collection and recursion cases. Lazy evaluation and executable configuration are
excluded rather than implied by a distant milestone.

## C0 — Specification and review

Deliverables are the five pages in this directory, glossary terms, and navigation.
The gate requires a cold read of both openings and a semantic review of worked
priority, conflict, recursive-map, ordering, and hyperlink traces. Findings have
explicit dispositions in the evidence ledger. Contract acceptance requires owner
review of consequential local policies; publication does not imply acceptance.

Publication commands:

```bash
prek run prettier --files docs/specs/wired/config/*.md docs/.vitepress/sidebar.json docs/.vitepress/glossary.json
dub run :ci -- --check-docs-sidebar
dub run :ci -- --check-glossary
dub run :ci -- --check-spec-evidence
yarn docs:build
```

Pinned external source checks apply when GitHub citations are introduced. There
are no executable examples in this draft; illustrative command blocks are not
implementation evidence. The first executable action after contract review is
C1's scalar/string definition driver and independent table oracle.

## C1 — Scalar definitions and conflicts

**Prerequisites:** accepted first-slice contracts; Q1 resolved for scalar/string
ownership and default limits. Nullable payload support is not accepted until its
presence probe passes; it cannot be silently approximated.

C1 is restricted to scalar/string schemas with explicit test limits. Collection
and recursive composition acceptance belongs to C2, not this slice.

Deliver a typed source submission interface, schema-derived built-in definitions,
per-definition priority/order metadata, immutable inspection snapshot, structured
conflicts, and non-mutating resolution. Use `Sparse!T` where it faithfully retains
presence; repair or wrap its presence channel where it does not.

Acceptance stimuli are the hand-derived scalar/default/conflict traces in
[testing.md](./testing.md#first-slice-oracle), with all permutations of three
sources, explicit-at-default definitions, enclosing section initializers, boundary
priorities, duplicate identities, input-lifetime mutation, and count/byte exhaustion.
Tests must fail against an ordered last-writer model for the intended reason.

```bash
dub test :wired -- -i 'wired.config' -v
```

That command is a future acceptance command, not evidence that those tests exist.
Verify nonzero discovery counts. Run a throwaway `dub run --single` driver that
submits three sources, reports all retained definitions, and checks a conflict
without mutating the caller's running value. Delete the driver after its evidence
is recorded; keep consumer-visible regression tests in feature modules.

Exclude collection composition, file discovery, persistence, and graphical hosts.
Do not publish a complete-config value when any scalar conflicts.

## C2 — Composition and contributor provenance

Resolve Q1 for collection accounting and Q2's generic/app-semantic distinction.
Implement compatible composition UDAs, explicit order, option-level map selection,
recursive section selection, stable contributor references, and canonical errors.
Run the map/list/lines traces and small exhaustive permutation/grouping oracle.
Probe canonical map-key spelling collisions and supported enum-key conversions.

Gate: focused wired tests plus a real driver reproducing the losing-key-map and
mixed-source section examples without using the production engine as its oracle.
Review the implementation's work/memory bounds before selecting default limits.
No lazy policy or native-order map enumeration may masquerade as this contract.

## C3 — Shared inspection and links

Use the existing property-tree walk with the explicit inspection profile,
`prettyprint`'s typed formatting seam, and `ui.components.table` for layout.
Add only the seams needed for wire enum spelling, wrapped guide continuation,
redaction, and documentation label links; preserve editor mutation policy.

Gate: focused UI/base tests covering all WCI obligations and a real host-free
report driver at narrow, normal, and redirected widths. Capture terminal bytes
for OSC containment, and view the report in an actual terminal-capable surface.
All-definitions inspection of conflicts must remain available before startup.
Q4 must be resolved for the fixture's page/anchor metadata. Whole-app startup
behavior is not certified by this fixture.

## C4 — Hue and terminal integration

Declare each app's priority/order profile without introducing unrequested source
layers. Assign equal priorities to intentionally composing grammar/search paths;
record their order separately. Resolve Q2 before migrating keybindings, including
unbind/subtree and reserved-chord diagnostics. Update origin consumers in settings
panes and sparse save paths, not just report wrappers.

Gate: isolated config homes, explicit project roots, injected env/CLI settings,
conflicts, malformed-source policy, `--changed`, and both report modes exercised
through the actual app commands with no display/PTY. Verify no configuration
writes. Run sparse persistence regressions proving untouched env/CLI values do not
leak into files. Resolve Q4 for actual option documentation pages. Remove obsolete
app-specific show/composition code at cutover; unrelated overlay consumers remain.

## C5 — Diagram integration

Resolve Q3 before prescribing a replacement decoder. The typed wire adapter must
preserve presets, aliases, live array counts, palette overrides, accepted numeric
ranges, and explicit-at-default provenance. Host-free loading precedes board
creation. Session-only board preferences remain session-only unless separately
approved; this effort does not expand persistence or automatic file discovery.

Gate: independent old-wire fixtures compared with contract expectations, actual
headless `diagram config show` and `--definitions`, conflict/invalid-file paths,
and a launch exercising the same resolved values. Preserve existing save behavior
unless an explicit accepted migration changes it. Resolve Q4 for diagram options.

## Handoff

- Contract: draft; owner acceptance remains a PR review gate.
- Implementation: no resolver/report migration delivered by C0.
- Evidence and review findings: [testing.md](./testing.md#evidence-ledger).
- Blocking questions: [decisions.md](./decisions.md#open-questions).
- Next action: resolve C1's Q1 scalar ownership/limits, then establish its
  failing-before/passing-after acceptance scenarios against a real implementation.
