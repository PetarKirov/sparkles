---
status: draft
owner: sparkles:wired
reviewed: 2026-10-05
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

| Slice | Obligations                               | Status      | Required result                                                                           |
| ----- | ----------------------------------------- | ----------- | ----------------------------------------------------------------------------------------- |
| C0    | Scope, decisions, oracles, publication    | in progress | Independently reviewed draft with explicit blocking questions                             |
| C1    | WCFG1–10, WCFG13–14, WCFG17–21, WCFG25–37 | implemented | Scalar core and original-policy JSON adapter; local conformance and checked driver passed |
| C2    | WCFG11–16, WCFG20–21, WCFG38–51           | not started | Typed collection/submodule presence, projections, normalized graphs, exact budgets        |
| C3    | WCI1–24, WCFG24                           | not started | Typed bounded report, checked table floors/guides, actual docs targets and OSC isolation  |
| C4    | WCFG22–24, WCI1–24                        | not started | Hue and terminal startup/report/persistence use one definition model                      |
| C5    | WCFG22–24, WCI1–24                        | not started | Diagram preserves its grid wire contract and shares resolution with startup               |

The obligations listed for C1 apply to its scalar/string subset; C2 closes their
collection and recursion cases. Lazy evaluation and executable configuration are
excluded rather than implied by a distant milestone.

## C0 — Specification and review

Deliverables are this specification tree, glossary terms, and navigation.
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

**Prerequisites:** owner review of the concrete
[scalar interface](./scalar-resolution.md); Q1 is specified for this subset.
Collection/custom-value accounting remains gated for C2. The scalar implementation
and its conformance evidence are recorded in
[testing.md](./testing.md#c1-scalar-implementation).

C1 supports exactly the scalar/section matrix in WCFG25, with no silent filtering
of collection fields. Implement the move-only builder/input/snapshot interface,
original-policy JSON presence adapter, byte identities, explicit budget updates,
and structured admission/semantic/operational outcomes. The JSON adapter must not
decode `Sparse!T` for nullable or renamed fields. Use the exact defaults and
accounting in WCFG33–34; all built-in definitions consume the same budgets.

Acceptance stimuli are the hand-derived scalar/default/conflict traces in
[testing.md](./testing.md#first-slice-oracle), plus its operation, exact accounting,
identity, lifetime, and failure-injection cases. Exercise all source permutations,
section/leaf priority inheritance, explicit-at-default/null values, enclosing
initializers and their primitive domains, failed owned transfer, saved source
handles across owner transfers, independent config-copy lifetime, mixed semantic
outcomes, scope escape rejection, copied-owner rejection, and budget recovery.
Known-bad last-writer, validate-all, partial-commit, or shallow-copy implementations
must fail for the intended behavior, not incidental diagnostic wording.

```bash
dub test :wired -- -i 'wired.config' -v
```

Both LDC and DMD discover and pass the scalar acceptance cases; the full wired
suite passes 243 tests on each compiler. The runnable
`libs/wired/examples/scalar-config.d` driver submits three sources, reports all
retained definitions, rejects a conflicting full-config copy, and checks that
the caller's running value remains unchanged.

Exclude collection composition, custom-value ownership, file discovery, persistence,
and graphical hosts. Do not publish a complete-config value when any option is
unresolved. Local implementation evidence is distinct from publication and CI;
neither implies delivery of the deferred collection or application slices.

## C2 — Composition and contributor provenance

Prerequisites are owner review of [composition.md](./composition.md), the shared
original-site decoder/presence experiment in Q6, and C1's retained-owner interface.
Q1 specifies finite collection accounting; custom conversion/ownership remains
excluded. Q2 blocks keybinding-specific integration, not the generic core policies.

Implement WCFG38–51 using root definitions plus typed presence and branch
projections, not a second merge engine. The native AA/struct decoder overwrites
duplicates and a root-subtree decoder loses containing-field policy, so neither
is a faithful source-admission shortcut. Preserve typed null/non-null-empty
containers explicitly: `.dup` alone loses that state. Source/node, generated
default, normalized candidate, contribution and canonical metadata charges have
independent boundary/fault cases.

Gate: focused wired tests, original-site full/sparse decoding and duplicate
admission, permutation/grouping and mixed-child-failure oracles, exact collection
accounting, and a real conflict/projection driver. Production allocator failure
must preserve all owners and builder state. A finite hand-written clone or
`Unique` move establishes only primitive feasibility, not this gate. No lazy or
custom-value policy can silently enter the supported matrix.

Readiness evidence: original-site recursive list/map decoding, canonical duplicate
preflight, generated full/sparse presence, nested independent capture/copy, and
typed null/non-null-empty preservation passed bounded checked-build probes under
DMD and LDC. The native key parser is now package-visible; no collection resolver
is implemented. [The recorded fixtures](./testing.md#c2-original-site-and-generated-presence-readiness)
exposed native enum validation against unused case styles. That native defect is
repaired: schema reification uses the resolved case/representation, and the codec
regressions cover original spellings, selected collisions, field overrides, and
numeric aliases. Q6 remains open for production projection/input and canonical
key-domain admission; owner acceptance and the full C2 gate remain pending.

## C3 — Shared inspection and links

Use the concrete [inspection interface](./inspection.md#_5-proposed-report-interface)
with snapshot typed/presence visits, the property kernel's inspection profile,
generic prettyprint value/member/limit policies, and the existing table solver/
wrapper. Resolve its §9 bounded experiments before relying on those seams.

The real baseline exposed table width overflow below the hard floor and OSC
link leakage across mandatory cell breaks, including source/value leakage for a
513-byte opening. Q7 gates the shared table repair; a 506-byte URI bound alone is
not label isolation. Do not hide the failure by disabling links or adding an
app-local wrapper. Use the existing `OutputCapabilities` vocabulary.

Gate: focused UI/base tests for WCI1–24, the independent ANSI-byte/width oracle,
bounded source/value/label work and balanced cuts, full/sparse definition formatting,
checked 47-cell flat fit versus 46-cell refusal, and an actual host-free report
driver plus terminal-capable visual smoke. Verify page/anchor manifests against
real built pages; Q4 remains a separate per-app acceptance gate. No app startup
or resolver conformance is certified by a table/prettyprint baseline probe.

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
- Implementation: C1 scalar core and JSON presence adapter are implemented;
  collection composition, reporting, and application migration remain deferred.
- Evidence and review findings: [testing.md](./testing.md#evidence-ledger).
- Blocking questions: [decisions.md](./decisions.md#open-questions).
- Next action: publish and validate C1, then implement C2 composition and Q7/C3
  shared table/formatter seams. Custom ownership, keybindings, diagram's adapter,
  and actual app documentation gates remain explicitly blocked.
