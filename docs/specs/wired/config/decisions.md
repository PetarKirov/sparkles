---
status: draft
owner: sparkles:wired
reviewed: 2026-10-05
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

## D5 — Separate presence and explicit ownership transfers

**State:** proposed. **Affected:** WCFG4, WCFG7, WCFG13, WCFG17, WCFG25–32, WCFG35–37.

**Question:** Can `Sparse!T` decoding and ordinary struct copies provide the scalar
input and snapshot interface?

**Alternatives:** decode the derived nullable overlay; deep-copy the entire
accumulated builder at resolution; separate presence from payload and capture or
transfer owned storage explicitly.

**Evidence:** The scalar probe preserved false/zero/empty values, but wired rejected
`Sparse` over a nullable payload as a nested null-aware wrapper. The mapped overlay
also lost a field's `@WireName`, while decoding the original type honored it.
Separate slots reused leaf null/value decoding. A move-only capsule transferred
its captured string with the same payload pointer; `-preview=dip1000` compile
probes rejected copying an owner and leaking scoped text/nullable-text views.
These are feasibility results, not proof of a configuration implementation.

**Choice:** [scalar-resolution.md](./scalar-resolution.md) owns the exact proposed
interface. Input slots retain presence outside original typed payloads and decoding
carries the original field policy. Borrowed input captures once; an owned capsule
transfers on successful submission. Resolution transfers a builder into a
read-only snapshot, including conflicts, while operational failure retains the
builder. Independent mutable configuration materialization is an explicit copy.
Section metadata supplies priority inheritance without manufacturing absent leaf
definitions. Source handles identify retained storage across builder/snapshot moves,
not the wrapper object's address.

**Trade-off:** Ownership forms must not manufacture ownership from mutable aliases.
The codec needs an original-field-policy seam rather than a sparse-wrapper shortcut.
Move-only owners are not Regular values; read-only borrowed records are not
independently owned copies. Implementation lifetime and failure-injection gates
remain necessary even though the language primitives work.

**Revisit when:** an actual scalar implementation cannot enforce the scoped visitor
interface or allocation-failure rollback; resolve that evidence before broadening
the public interface or introducing collection ownership.

## D6 — Logical scalar budgets and byte identities

**State:** proposed. **Affected:** WCFG6, WCFG11, WCFG21, WCFG26, WCFG33–35.

**Question:** Should admission depend on locale/Unicode identity processing,
allocator capacity, or whether equal immutable values happen to share storage?

**Alternatives:** textual normalized IDs and physical allocation accounting;
opaque byte IDs and deterministic logical-content accounting.

**Evidence:** The unsigned-byte probe sorted prefix IDs and `0x7f/0x80/0xff`
without locale or signed-char dependence. A reflective census measured hue's
108 leaf-shaped fields (98 scalar), terminal's 43 (35 scalar), and diagram's 23
(19 scalar), at depths 3/4/3. Their scalar defaults used 607/195/37 value bytes.
The subtraction-based budget model admitted exact limits and rejected overflow.
It does not measure peak memory or validate production rollback.

**Choice:** Nonempty byte IDs of at most 1024 bytes have byte equality and
ascending unsigned lexicographic ordering. Scalar defaults are 1024 sources,
65,536 definitions, 16 MiB logical payload, 4096 options, and depth 32.
Metadata identities are interned and charged once; definition values are charged
per definition regardless of physical sharing. This explicitly refines WCFG21's
original shared-content wording so alias/interner choices cannot change admission.

**Trade-off:** Logical content is not RSS. Record limits bound count, not allocator
overhead; transient decoding/capture storage has no RSS claim. These defaults give
headroom above the measured scalar subjects without promising arbitrary document
sizes. Collections/custom values require separate accounting before C2 acceptance.

**Revisit when:** measured valid application workloads exceed the policy or expose
unacceptable overhead. Preserve exact boundary semantics and update the oracle
with any accepted default/accounting change.

## Open questions

Questions name the work they block. They do not block publication of a draft or
permit an implementation completion claim with missing prerequisites.

### Q1 — Storage and default limits

**Owner:** wired implementer and reviewer. **State:** scalar contract specified;
collection accounting open. **Blocks:** C2 collection/custom-value accounting,
not C1 scalar interface design. **Affected:** WCFG7, WCFG17, WCFG21, WCFG25–37.

[D5](#d5-separate-presence-and-explicit-ownership-transfers) and
[D6](#d6-logical-scalar-budgets-and-byte-identities) select the scalar ownership,
identity, default-limit, and logical-accounting rules, with feasibility evidence
in [testing.md](./testing.md#scalar-readiness-feasibility). Owner acceptance and
implementation conformance remain separate gates. C2 must specify map/list/custom
payload accounting, recursion, and ownership before those shapes are accepted.
No scalar code may silently approximate nullable presence or ignore wire policies.

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
