---
status: draft
owner: sparkles:text-layout
reviewed: 2026-10-04
---

# `sparkles:text-layout` — Decisions and architectural gates

## Abstract

This is the decision record for `sparkles:text-layout`. Its central decision is a
paragraph-composition layer above owned Unicode and font services, not a second
Unicode engine, font stack or page builder. It measures each candidate line in the
context it will be drawn in, and ties every result to the text revision it was
computed from, so typography and interaction are meant to agree, and
publication features are explicit bounded interfaces to hosts above the layer.

## Introduction

[The specification](./SPEC.md) is authoritative for requirements;
[the plan](./PLAN.md) tracks delivery and [testing](./testing.md) tracks evidence.
These records explain choices and unresolved gates, not a second normative contract.

Each decision carries a state and a condition for revisiting it. A decision is
`proposed` until the specification is accepted or the owner settles it
individually, and `accepted` from then on. It becomes `superseded` when a later
decision replaces it, and links to that decision. Section 2 lists the
architectural gates: facts about delivery or feasibility that must hold before a
blocked claim can be made.

## 1. Decisions

### TLD-001: Paragraph composition is a distinct layer

**State:** accepted (owner, 2026-10-04) · **Revisit when** a consumer needs
contextual composition that cannot be expressed through base's and font's
contracts without one of them importing paragraph policy.

The owner's scope discussion on 2026-10-04 approved the direction of owned
UTF/Unicode, wrapping and text/publication foundations, which settles this
decision. That approval is not reviewer signoff or verification of the contract.

**Choice.** Base owns decoding, Unicode analysis, cells, physical units and generic
solvers. Font owns resources, matching/fallback, metrics, shaping and rasterization.
Text-layout owns combining those services into contextual paragraph results and
source/visual interaction. Document, math, page and export consumers sit above it.

**Reason.** Each lower layer has independently useful consumers and dependency
constraints. A terminal needs base cells without publication shaping; a font
inspector needs font resources without paragraph composition. Putting shaping
inside base or parsing documents inside font would force those consumers to import
unrelated policy and dependencies.

**Rejected alternatives.** A monolithic “text” package, a font-layout owner and a
platform paragraph stack with different Unicode/version behavior. The rejected
platform approach can be a research oracle, not a production escape hatch.

**Consequence.** A package graph is not a delivery schedule. The shaped path waits
for actual font implementations, while the fixed-object plan can be useful first.
Related requirements: TL-001–TL-003/TL-012/TL-036.

### TLD-002: Exact widths are candidate-context results

**State:** proposed · **Revisit when** Stage 0's workload experiment shows exact
contextual measurement exceeding every reviewable budget, or font's safe-reuse
contract proves a cheaper measurement equivalent.

**Choice.** The exact provider measures each admitted line in its actual selected
branch, font, boundary and adjustment context. An exact-measure token either
retains that result or enables identical recomputation. Font safe-break/concat
information permits proven reuse, not nominal prefix-width assumptions.

**Reason.** Contextual forms, ligatures, fallback and discretionary replacements can
change glyphs and advance at a boundary. Negative kerns and variable geometry also
invalidate “longer is wider” shortcuts. Comparing final output to a different
unbroken measurement does not repair an invalid optimum.

**Rejected alternatives.** Shaping words independently; accumulating nominal
per-codepoint widths; choosing breaks from one paragraph shape and hoping final
reshaping preserves them; silently switching to greedy when exact work exhausts.

**Consequence.** “Exact” describes the finite candidate/adjustment graph and declared
cost policy. It says nothing about an unsearched continuous expansion space or a
host's page optimization. Resource failure is honest failure; an explicitly chosen
approximate/local policy is a different result classification. Base remains the
sole owner of solver state equivalence and objective arithmetic.
Related requirements: TL-017–TL-022/TL-026/TL-032.

### TLD-003: Logical identity is not visual position

**State:** proposed · **Revisit when** a migrated consumer's interaction cannot be
expressed through the logical/visual maps without reconstructing positions itself.

**Choice.** Source snapshots and spans are independent of graphemes, shaping clusters
and glyph occurrences; visual positions are qualified by a layout result. Affinity
preserves multiple visual edges for a logical boundary, and synthetic content keeps
item/branch provenance instead of pretending to have source bytes.

**Reason.** A ligature can cover several graphemes, a mark can have no advance, a
control can have no glyph, and bidi can map one source boundary to distinct visual
locations. Reflow changes geometry without editing source. Copying glyph order or
using one array index for all identities loses those distinctions.

**Rejected alternative.** A byte-to-x table reconstructed by the renderer, a glyph
index masquerading as source offset, and normalized/replacement text without
provenance.

**Consequence.** Raw-source copy and visible-text export are separate operations;
selection and hits consume the same committed layout as paint. Equal-advance
ligature caret subdivision is explicitly estimated when real font carets are
absent. It is an interaction policy, not an invented font measurement.
Related requirements: TL-004–TL-007/TL-013/TL-023–TL-025/TL-035.

### TLD-004: Cell grids and physical typography do not share a width fiction

**State:** proposed · **Revisit when** a terminal target needs shaped occupancy
that base's [width profiles](../../glossary.md#width-profile) and scaled cell
footprints cannot express.

**Choice.** Cell-grid layout uses base's complete-grapheme occupancy under a named
width profile and explicit footprints. Font shaping, when present, affects ink
only, and no visual bidi reordering is applied (TL-052). Shaped-flow layout uses
base's physical `LayoutUnit` and font's scalable design metrics; device conversion
is outside paragraph selection.

**Reason.** A programming ligature may paint across cells without changing terminal
columns. A proportional paragraph cannot be measured by wcwidth. Hinting/DPI/atlas
state must not alter a publication's physical line choices.

**Rejected alternative.** One float called `width` whose meaning is pixels, points,
font units or cells depending on the call site, or rounding each glyph separately
and accumulating the drift.

**Consequence.** Typed mode and scale inputs prevent accidental interchange. Font
owns per-run conversion of its metrics; layout owns exact cross-run/line accumulation
and the physical result. Neither redefines base's shared unit.
Related requirements: TL-002/TL-003/TL-019/TL-022/TL-025.

### TLD-005: Rich input is not a frozen list of pre-shaped words

**State:** proposed · **Revisit when** a host's paragraph content cannot be
represented by the rich item vocabulary, or finite nonnested branch fragments
reject content a real front end must express.

**Choice.** Rich paragraphs retain text, fixed objects, glue, kerns, penalties,
three-branch discretionaries, anchors and ruby. Only the measurable projection uses
base primitives. Branch fragments are finite nonnested lists so source consumption
and continuation remain reviewable; unresolved physical text is not converted to
fake boxes.

**Reason.** Freezing a word shape too early hides boundary context and prevents
correct post-break fragments, annotation pairing and source maps. Fixed boxes are
useful when a host genuinely owns their metrics, including mathematical objects,
not when they cover for an absent shaper.

**Consequence.** A real source-mapped fixed-object plan and projection is useful
before any shaping exists. Its acceptance cannot be promoted into shaped text, fallback,
RTL or math claims. Hosts composing formulas remain responsible for genuine metrics
and explicit breakable fragments.
Related requirements: TL-010–TL-018/TL-031.

### TLD-006: Publication features are bounded choices and explicit handoffs

**State:** proposed · **Revisit when** the Stage 0 publication-handoff exercise
finds a host decision that the finite feedback protocol cannot carry.

**Choice.** Spacing, finite expansion alternatives, protrusion, script-aware
elongation, baselines, writing modes, ruby and objects are explicit
[typography profiles](../../glossary.md#typography-profile) and recorded choices. Alternatives, fragments and revisioned geometry feedback connect
to a page host; glyph/source/reading-order records connect to an export host.

**Reason.** Paragraphs need publication-quality interfaces without inheriting a
macro language, page builder, document model or PDF serializer. Automatic loops
between float placement and paragraph width can oscillate; a finite host-driven
feedback protocol makes nonconvergence visible.

**Rejected alternatives.** Claiming TeX replacement from a Knuth–Plass solver;
inserting arbitrary Arabic tatweels; rotating horizontal text and calling it
vertical composition; treating “PDF support” as raster screenshots; unbounded
page callbacks inside layout.

**Consequence.** Paragraph exactness is not cross-page optimality. Mathematical
composition stays above font, with validated MATH parsing at font and a measured
object/fragments interface here. Front-end syntax and document/export compatibility
need their own owners and acceptance suites.
Related requirements: TL-026–TL-035.

### TLD-007: Caller-owned resources and independent caches

**State:** proposed · **Revisit when** measured reflow workloads show the separate
cache owners costing more than the Stage 0 budget allows.

**Choice.** Immutable plans/results borrow their explicitly qualified snapshots,
styles and real font backing. Output/workspace capacities and work budgets are
caller-controlled. Font-resource/shape caches and paragraph candidate/layout caches
are separate mutable resources with one mutation owner each.

**Reason.** Reflow should reuse parsed font resources while invalidating contextual
width choices. Replacing a font under the same family name should invalidate widths
without corrupting existing live results. Hidden mutable state and pointer-only
keys make these transitions untestable.

**Consequence.** Atomic result publication and typed errors preserve the last valid
result after a failed request. Scratch may be reused immediately after publication,
while the source/font lifetime remains a caller obligation. Bounded limits never
truncate valid long graphemes or convert a failed engine call to empty success.
Related requirements: TL-006–TL-009/TL-022/TL-039–TL-041/TL-053.

### TLD-008: Toolkit proportional prose is a shaped-flow consumer

**State:** accepted (owner, 2026-10-05) · **Revisit when** text-layout TL-M3 is
abandoned or the design system drops proportional documentation runs.

**Choice.** The design system's proportional documentation prose in a window
([GLY7](../design-system/glyphs.md)) is a `shapedFlow` paragraph laid out inside
the widget's cell rect. Painting, hit-testing and selection use its one committed
cluster result (TL-025). It waits on text-layout TL-M3, which waits on font M4 and
M7.

**Rejected alternative.** An interim paragraph engine in `sparkles:raylib-text`
that measures and wraps proportional runs on its own; it would be a second owner of
exactly the measurement this layer exists to unify.

**Consequence.** Design-system M9's GLY7 work stays partial until TL-M3 delivers.
Related requirements: TL-003/TL-025/TL-056.

### TLD-009: Terminal text sizing belongs to base

**State:** accepted (owner, 2026-10-05) · **Revisit when** a terminal sizing
protocol needs contextual shaping or line selection rather than grid-cell
footprints.

**Choice.** A run drawn at an integer scale or a fractional width of grid cells,
as kitty's text-sizing protocol allows, is a scaled cell footprint in
[base text](../base/text/SPEC.md), not a text-layout paragraph contract. The design
system's GLY5 consumes base; whether a given terminal honours the protocol stays
the design system's open question OQ5.

**Consequence.** Text-layout's `cellGrid` mode consumes those footprints like any
other explicit integer footprint and owns no sizing protocol.
Related requirements: TL-003.

## 2. Architectural gates and unresolved choices

These are missing delivery or feasibility facts, not permissions to weaken the
specified behavior. Each gate names what resolves it and what remains blocked.
Real font delivery and independent review are prerequisites, never presumed: a
font specification describing shaping is not an available shaping implementation.

### TLG-001: A real font library

**State:** open · **Revisit when** `libs/font` exists and delivers font M2, M4 and
M7 with real-font acceptance; the [plan's gate table](./PLAN.md#_1-progress-and-dependencies)
tracks whether it does.

The [font plan](../font/PLAN.md) places instances/metrics at font M2, shaping at
font M4 and matching/fallback at font M7. Its contracts describe physical scalable
metrics (FTM6), baselines/vertical data (FTM7), MATH parsing (FTP13), contextual
shaping and flags (FTS7–FTS9), GDEF carets (FTS10), exact justification trials
(FTS11) and whole-span fallback (FTD7); a specification does not supply their
implementation.

**Resolution.** Deliver actual font milestones with their real-font acceptance and
an independently reviewed text-layout adapter capability audit. Physical aggregation
must consume font's design-position scale/units-per-em, not fractional pixel
convenience metrics. Full RTL cluster coverage and glyphless spans need the refined
font contract, not merely the older monotone-LTR condition.

**Blocked.** Shaped-flow release and claims of actual-font RTL/fallback, safe
candidate reuse, vertical/elongation typography or font-data-backed math objects.
Do not create a fake provider, a layout-private HarfBuzz binding, or a dummy package.

### TLG-002: Engine Unicode compatibility needs executable proof

**State:** open · **Revisit when** font's engine integration manifest records the
engine's data revision and a compatibility corpus run against base's release.

Base owns a single hashed Unicode release and algorithm revisions. A real shaping
engine has internal data and script behavior beyond the Unicode callbacks it may
expose. Font's FTS8 makes the compatibility profile explicit, but callbacks alone
do not establish alignment for joining/normalization/script classification.

**Resolution.** Record actual engine build/data revision, supported owned callbacks,
remaining internal semantics and tested compatibility corpus. Exercise adversarial
sequences whose base grapheme and font cluster boundaries differ, including long
Indic conjuncts and newer release properties. Keep findings at the font/base
boundary; do not privately patch layout's Unicode classifiers.

**Blocked.** Claims that the production stack's entire Unicode semantics are
compiler-independent and release-consistent without that dependency evidence.
The base-owned analysis contract itself remains authoritative.

### TLG-003: Exact contextual work and storage are unmeasured

**State:** open · **Revisit when** Stage 0's workload experiment records bounds on
named hardware and a budget is proposed.

Full candidate reshaping can require far more work than additive-word layout. Safe
flags, exact memoization and retained exact-measure tokens can reduce work, but
neither monotonicity nor linear complexity follows from a paragraph's length.
Discretionary branches can also change whole-paragraph bidi/script/grapheme
analysis, so complete projected-choice contexts may be part of the graph state
(TL-037), not merely an ending hyphen flag. This is an expressive-capability gate
as well as a measurement cost.

**Resolution.** Run Stage 0's real-engine experiment and named workload measurement,
including negative kerns, varying geometry, discretionary continuations and
branch-induced paragraph analysis, long runs and cache invalidation. Confirm the
generic state interface can represent complete choice/analysis identity. Record
bounds and propose budgets before accepting a production budget. If work exceeds a budget, expose exhaustion or require an
explicit different policy; do not falsely retain the exact label.

**Blocked.** Performance promises and default production budgets, not semantic
acceptance scenarios or the independently executable fixed-object slice.

### TLG-004: Vertical and publication typography profiles need concrete authorities

**State:** open · **Revisit when** a typography profile is proposed for enabling,
with its orientation and script-policy data pinned.

Font's vertical/baseline and justification interfaces are necessary, but a
writing-mode [typography profile](../../glossary.md#typography-profile) also needs a
pinned orientation policy, language/script-specific eligible spacing and ruby
behavior. Font metrics alone do not define those choices.

**Resolution.** Before enabling the typography profile, select and pin its vertical orientation
and script-policy data/revision through the existing base/font ownership boundary,
choose actual CJK/Arabic fixtures, and review worked upright/rotated, ruby overhang,
non-elongating and elongating traces. Mathematical objects additionally need a real
composer above font; a hand-measured box is not that composer.

**Blocked.** An enabled publication typography profile without an accepted concrete policy or
font/host implementation. Unsupported requests remain explicit outcomes; horizontal
basic composition can be accepted independently.

### TLG-005: Alternative solver capabilities must remain generic

**State:** open · **Revisit when** base delivers WRAP-ALT1 and exact small graphs
compare equal against an independent enumerator.

Text-layout needs finite alternatives constrained by line counts or geometry, cost
ordering, and explicit enumeration completeness. Base owns the solver mechanism;
this layer owns contextual candidate providers and publication-facing summaries.

**Resolution.** Deliver base's WRAP-ALT1
[constrained/alternative solver](../base/text/wrapping.md#constrained-and-alternative-solutions)
and compare exact small graphs independently before TL-M6. Preserve its exact
top-K ranking proof separately from exhaustive enumeration; an approximate list
has neither proof. A fixed geometry request's best layout alone is not proof of
complete alternative enumeration. If integration disproves a constraint's
expressibility, revise the owning base contract, not add a private optimizer.

**Blocked.** Complete alternatives and related host page-choice claims until the
specified generic capabilities are executable with actual contextual providers.

### TLG-006: Host page feedback does not establish whole-document optimality

**State:** open · **Revisit when** a document/page host with its own global search
and convergence policy is specified.

A paragraph's alternatives do not specify a page objective, float placement,
footnote allocation, keep/widow/orphan policy, or a full document model. Multiple
host geometry revisions can have no fixed point under a chosen iteration policy.

**Resolution.** Prove the bounded handoff with one stable and one oscillating actual
composition case. A document/page host separately owns global search, constraints,
convergence policy and errors. Export needs real font embedding/subsetting/tagging
outside this layer before a PDF/publication-system claim can be made.

**Blocked.** TeX-language compatibility, TeX replacement, full-page optimality,
front-end parsing and finished PDF production claims. None is delivered by this
paragraph specification or its first fixed-object operation.

## 3. Change control

Retain requirement and decision IDs when sections move. A disproved assumption
changes the owning contract and its falsifying scenario together, with the negative
trace linked from testing. Do not silently switch engine versions, Unicode data,
source-map granularity, objective costs or typography profiles. Concrete symbols
remain proposed until their operation actually exists and its named configuration
has executable evidence.

Clean consumer migration removes obsolete paragraph/width/source-position helpers;
keeping them as permanent compatibility aliases would violate the selected owner
boundary. Independent adversarial review and owner acceptance, not a merged PR or
a successful documentation build, promote this draft contract.
