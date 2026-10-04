---
status: draft
owner: sparkles:wired
reviewed: 2026-10-04
---

# `sparkles.wired.config` — Decisions and open questions

This record explains the consequential choices in [SPEC.md](./SPEC.md) and
[inspection.md](./inspection.md). Decision states are independent of delivery
progress, which belongs only to [PLAN.md](./PLAN.md). User direction establishes
the requested behavior; PR review accepts the exact contract and local policies.

## D1 — Retained definitions, not provenance reconstructed from values

**State:** proposed. **Affected:** WCFG4–8, WCFG16–18, WCI2.

**Question:** Can effective values plus a last-source mirror support priority
merging and all-definitions troubleshooting?

**Alternatives:** retain only the effective value; retain one winning origin;
retain every typed definition and derive the effective value and dispositions.

**Evidence:** `wired.overlay.applyOverlay` overwrites origins for scalar fields
and records the last contributing origin for `WireCompose`. Its `Origins` mirror
contains no overwritten values. `wired.config_file.renderConfigShow` prints that
mirror; associative values are reported by entry count. These facilities cannot
recover explicit-at-default or overridden definitions from a final-value diff.

**Choice:** retain typed definitions and source references, with schema-derived
built-in definitions. The user explicitly requested all-definitions inspection.

**Trade-off:** retained values cost more memory than a last-writer fold. Ownership
and limits are first-slice gates rather than an unsupported allocation-free claim.

**Revisit when:** bounded retention cannot serve the demonstrated app workloads;
any alternative must still explain all definitions or report explicit exhaustion.

## D2 — NixOS-inspired semantics, not a Nix implementation

**State:** proposed. **Affected:** WCFG8–15.

**Question:** Which semantics transfer from NixOS module options?

**Alternatives:** source-order overwrite; composition across every priority;
minimum-priority selection followed by typed equal-priority composition.

**Authority:** the user's requested priority/merge model. The
[NixOS manual](https://nixos.org/manual/nixos/stable/#sec-option-definitions)
is conceptual context, not a pinned interoperability target or executable oracle.
No exact Nix release compatibility is claimed.

**Choice:** lower numerical priority wins; schema UDAs select merge semantics.
Priority and list ordering are separate. Scalars conflict when multiple selected
definitions exist, even if equal; this is explicit local policy. `attrsOf` selects
at the map option before key recursion, while submodules resolve declared children
independently. Lazy maps and modules have no implied evaluator in this scope.

**Trade-off:** existing prepend-across-layer lists change unless hosts deliberately
assign equal priorities. Commutativity is conditional on nested policy laws;
ordered concatenation is not commutative. Definitions retain metadata through
regrouping, avoiding the invalid algebra of merging resolved intermediate values.

**Revisit when:** a demonstrated app needs equal-scalar agreement, lazy demand, or
another merge policy. Change the authoritative requirements and oracles before
changing consumer behavior, rather than claiming those policies were implicit.

## D3 — Resolver in wired, report in UI, discovery in apps

**State:** proposed. **Affected:** WCFG1–3, WCFG22, WCI7–10.

**Question:** Does shared configuration require another DUB package or host?

**Alternatives:** a new all-in-one config package; UI depending on app loaders;
cohesive wired/UI modules over existing dependencies.

**Evidence:** UI directly depends on wired. Wired has no UI dependency. Hue and
terminal already delegate configuration reporting to `wired.config_file`, while
the property tree and table are UI-owned. Diagram already consumes UI but lacks
a host-free definition loader.

**Choice:** `sparkles.wired.config` is a proposed module family within wired.
`sparkles.ui.config_show` composes property-tree rows, typed prettyprinting, and
table layout. Apps discover sources and adapt their file semantics.

**Trade-off:** two independently useful contracts have two owners. The inspection
page owns UI requirements; the resolver links to it rather than duplicating them.
No production schema or loader becomes a second handwritten field declaration.

**Revisit when:** a non-UI consumer needs shared report data without UI linkage;
that may justify exposing an independently useful projection, not importing UI
into wired or duplicating reflection.

## D4 — Documentation links on labels, capability-gated

**State:** proposed. **Affected:** WCI13–15.

**Question:** Can prettyprint's OSC switch supply option-documentation links?

**Alternatives:** disable links; enable prettyprint source-code links; decorate
property labels with schema documentation targets using output hyperlink capability.

**Evidence:** `PrettyPrintOptions.useOscLinks` reaches `writeTypeName`, which links
a type's source location. `RenderCaps.hyperlinks` is independent of color depth.
Shared `text.wrap` closes/reopens OSC 8 links around wrapping; table rendering uses
that wrapper. Source locations are not the requested documentation web pages.

**Choice:** enable report `useOscLinks` from the sink's hyperlink capability and
link option labels to verified documentation targets. Type-value source links
remain off unless separately requested.

**Trade-off:** schema metadata and actual page/anchor generation are required.
Missing docs cannot be disguised by a plausible URL. Q4 gates each integration.

**Revisit when:** another report target needs a different link protocol; keep the
same documentation identity and change only the target adapter.

## Open questions

Questions name the work they block. They do not block publication of a draft or
permit an implementation completion claim with missing prerequisites.

### Q1 — Storage and default limits

**Owner:** wired implementer and reviewer. **Blocks:** C1 public ownership/limits;
C2 collection accounting. **Affected:** WCFG7, WCFG17, WCFG21.

Choose transfer-versus-independent-snapshot submission forms, deep ownership for
slice/map payloads, reference stability, exact default definition/payload/option
limits, and accounting hooks for custom typed values. Experiment with scalar and
nested list/map schemas, mutate/free source storage, and exercise limits at
`N-1`, `N`, `N+1`. Accept only an interface whose snapshot cannot change with
caller input and whose rejection preserves both parties' state. No avoidable
copying or per-node delegate is justified by the ownership requirement.

### Q2 — Keybinding composition

**Owner:** shared keymap and app maintainers. **Blocks:** C2 extension policy if
needed; C4 full hue/terminal cutover. **Affected:** WCFG16, WCFG22–23, WCI2, WCI8.

Define the typed policy/projection for row-wise binding overlay, null unbinding,
subtree claims, leader substitution, and terminal reserved chords. Decide which
operations are definitions and which are post-resolution validation outcomes.
An atomic `keys` map or a count of its overlay entries is not an effective binding
report. A bounded spike must merge compiled and user bindings, identify a replaced
row and an unbound subtree, and account for a rejected reserved chord without
inventing per-binding provenance.

### Q3 — Diagram wire adapter

**Owner:** diagram maintainer. **Blocks:** C5. **Affected:** WCFG22–23, WCI8.

The grid file contains aliases, optional presets, brush string arrays, and palette
overrides; the live pane uses runtime arrays/counts and includes session-only board
preferences. Specify a canonical sparse adapter, attribution for preset-expanded
fields, and an inspection subject including loaded palette effects. Compare
existing accepted numeric ranges with editor ranges; preserve file semantics
rather than treating pane metadata as an undocumented parser change. No decision
here expands diagram's persistence or source discovery.

### Q4 — Option documentation pages

**Owner:** UI docs and each app maintainer. **Blocks:** C3 fixture link gate;
C4/C5 application link gates. **Affected:** WCI14–15.

Choose shared documentation metadata spelling and generation of stable per-option
anchors from the schema. Verify every fixture/app target against built pages,
including renamed wire fields and map/list ownership. Prefer generated reference
pages to a duplicated option table. External URLs require an explicit authority;
controls and non-HTTP(S) schemes are rejected. Link capability is not a claim that
a guessed URL exists.

### Q5 — Publication versus acceptance

**Owner:** repository maintainer. **Blocks:** C0 contract acceptance, not publication.

Review the worked traces and proposed local equal-scalar, map-selection, limit,
and diagnostic policies. A merged draft can remain a draft. Record acceptance by
updating front matter and the decision states with the owning review reference;
do not infer approval from absence of PR comments.
