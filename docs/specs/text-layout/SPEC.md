---
status: draft
owner: sparkles:text-layout
reviewed: 2026-10-04
---

# `sparkles:text-layout` — Specification

## Abstract

`sparkles:text-layout` composes rich paragraphs into lines that every consumer
reads the same way, with stable links between source text, glyphs, and interaction
geometry. It combines Unicode analysis and line-breaking solvers from
`sparkles:base` with font selection and contextual shaping from `sparkles:font`.
A paragraph holds text, fixed-size objects, stretchable or shrinkable space,
explicit breaks, and hyphenation points whose text changes when a line breaks
there. Hosts may ask for alternative layouts before one is selected; every
consumer then uses that one layout for hit-testing and hands it to the painter and
the exporter. Proportional typography and terminal grid placement are distinct
modes. Publication hosts can split a paragraph across pages and return revised
line widths, but page policy remains theirs.

## Introduction

An editor needs a click on a right-to-left ligature to reach the right source
position. A publication engine needs paragraph choices whose actual line widths
include contextual forms, discretionary hyphens, and spacing adjustments. A terminal
needs cells whose occupancy remains independent of a programming font's ligature
ink, the pixels a ligature glyph paints, which may spread across several cells. A
toolkit window draws documentation prose in a proportional face as shaped flow
inside a widget's rectangle, which the toolkit sizes in its own layout
[cells](../../glossary.md#cell). These consumers all need a reusable paragraph result, but
not the same width model or a renderer-specific text stack.

The difficult boundary is between choosing breaks and shaping text. A word's width
inside an unbroken paragraph need not be its width at a line boundary. A grapheme
is not a shaping cluster, a cluster is not a glyph, and visual order is not source
order. Summing separately shaped words and subsequently reshaping the chosen lines
can invalidate the very optimization that chose those lines.

This library retains a source-mapped rich paragraph and measures complete candidate
lines in the context that their realization uses.
[`sparkles:base`](../base/text/SPEC.md) owns Unicode behavior and the
[pure line-breaking solvers](../base/text/wrapping.md);
[`sparkles:font`](../font/SPEC.md) owns font resources, matching, fallback, and
shaping. This layer owns their composition, source/visual maps, line geometry, and
interaction. Every request names one of two modes.
[_Shaped flow_](../../glossary.md#shaped-flow) measures in physical lengths with
real fonts. _Cell grid_ places text on a terminal's
[grid cells](../../glossary.md#grid-cell), where shaping can change ink but never
occupancy.

This is a paragraph contract plus a publication seam: the interfaces through which
a page, document or export host requests alternatives, fragments, and geometry
changes. It is not a TeX-language or TeX-output compatibility claim. It does not
parse HTML, CSS, Markdown, MathML or TeX, choose pages or floats, implement
mathematical layout, rasterize glyphs, or serialize a document; those belong to
the hosts above the seam. The physical shaped path requires a real font engine. A
paragraph made only of fixed objects, boxes whose size the host already knows, can
be planned without fonts, but that plan is not a substitute for the shaped path.

Section 1 states the contract at a glance, section 2 the ownership boundaries, and
section 3 the identities, lifetimes and failures every operation shares. Sections
4–6 define paragraph operations, contextual composition, and interaction; section 7
defines the publication seam. [The delivery plan](./PLAN.md) owns prerequisites and
progress, [testing](./testing.md) defines falsifying scenarios and planned
evidence, and [decisions](./decisions.md) records trade-offs and unresolved
architectural gates.

## 1. Contract at a glance

Operation and type names in this document, such as `planParagraph` and `cellGrid`,
are proposed names for the contract, not existing public symbols.

1. Base is the sole owner of [UTF and Unicode](../base/text/SPEC.md), including
   segmentation, line opportunities, bidi, normalization and casing. Text-layout
   consumes those results; it does not implement competing algorithms.
2. Base owns [physical `LayoutUnit`](../base/text/wrapping.md#layoutunit) and
   [pure wrapping solvers](../base/text/wrapping.md#_7-solvers).
   [Grid cells](../../glossary.md#grid-cell) are not physical lengths and cannot
   enter a shaped solver through an implicit conversion.
3. Font owns [faces, instances, matching, fallback and shaping](../font/SPEC.md).
   Layout never opens a font file, manufactures a fake shaper, or measures from an
   atlas. Package dependencies point from text-layout to base and font, never back.
4. Candidate measurement and final realization use the same resolved typography,
   boundary context and adjustment decisions. Exact means exact for that declared
   discrete model, not for unknown fonts or an unsearched typographic continuum.
5. One immutable source snapshot underlies logical identities, projections and
   layout results. Reflow changes geometry, not source identity.
6. Results commit atomically into caller-owned storage; limits and arithmetic
   exhaustion are failures, not silent truncation or implicit quality downgrades.

## 2. Ownership and scope

An arrow below means “imports or consumes a contract from,” not delivery order:

```text
text-layout ──> base (UTF, Unicode, cells, physical units, generic solvers)
            └─> font (font resources, instances, match/fallback, shaping, metrics)
renderer    ──> text-layout + font (drawing and device conversion)
document/page/math/export host ──> text-layout (+ font where needed)
```

**TL-001: Unique owners.** Text-layout **must** use the base contracts for all
Unicode semantics and wrapping optimization, and the font contract for every font
resource, selection and shaping operation. It **must not** call `std.utf`, `std.uni`,
auto-decoding ranges, platform paragraph engines, or private Unicode tables as an
alternative production path.

Base's single hashed Unicode 18.0.0 release and its declared algorithm revisions
are the paragraph analysis authority. A font engine's internal Unicode behavior is
a separately versioned dependency, not a replacement for base analysis; any mismatch
required for shaping is recorded at the font integration boundary. This spec
does not restate UAX algorithms or codec error rules.

**TL-002: Backend neutrality.** Paragraph planning and physical composition
**must** depend only on explicit inputs, base, and font's engine contract, never
on DPI, framebuffer size, a window, GPU, atlas residency or platform font discovery
side effects. A renderer **must** convert the physical result at its own device
boundary; changing only device scale **must not** change physical line breaks.

**TL-003: Explicit mode.** Every plan and layout **must** name `cellGrid` or
[`shapedFlow`](../../glossary.md#shaped-flow). Cell-grid placement **must** consume
base's grid-cell advances under the caller's
[width profile](../../glossary.md#width-profile) and explicit integer footprints;
optional font shaping affects ink only, not occupancy or source-column positions.
Shaped-flow placement **must** consume physical lengths and real font shaping,
never grid-cell widths or per-codepoint width estimates.

A document host owns language/style inheritance, hyphenation dictionaries and their
versions, object resources, page policy, accessibility tree and export format. It
resolves those policies before planning. Text-layout owns their paragraph-level
consequences: valid break choices, shaped annotation/object placement, source maps
and diagnostic outcomes. No caller can change a policy after measurement without
creating a new keyed request.

## 3. Identities, lifetime and failures

The [borrowed source snapshot](../base/text/wrapping.md#borrowed-snapshots) and its
non-reused identity/revision follow base's ownership contract. A **source span** is
a half-open logical byte range qualified by that snapshot. A **projection** maps a
rich paragraph branch to source-backed or synthetic content without changing the
snapshot; it does not prescribe a document buffer implementation.

A **grapheme identity** names a base-produced extended
[grapheme cluster](../../glossary.md#grapheme-cluster) span. A **shaping cluster
identity** names font's input cluster span within an item and can cover several
graphemes or glyphs. A **glyph identity** additionally qualifies the font instance,
glyph ID and occurrence within the shaped result. A **logical position** names a
source boundary and an [affinity](../base/text/SPEC.md#_6-2-typed-coordinates-and-affinity),
which says whether the position belongs with the text before or after that
boundary. A **visual position** names a layout result, line, run and caret edge.
The relationship is many-to-many, not an index cast. A **continuation identity**
names what a selected break hands to the following line: the chosen post-break
branch and any retained context that affects the next line's measurement.

**TL-004: Qualified identities.** Every source-backed output **must** retain its
snapshot-qualified span; every synthetic glyph, discretionary insertion, ruby
annotation or object **must** retain its origin item and branch identity rather
than inventing source bytes. A source position from another snapshot, or a visual
position from another layout result, **must** return `staleIdentity` without
reading the foreign result's storage.

**TL-005: No implicit editing.** Planning **must** preserve input bytes and logical
ordering. Normalization, replacement decoding and case transformations **must** be
explicit base-owned projections with provenance back to the original spans; raw
source copy and visible-text export **must** be distinct operations.

**TL-006: Borrowing and invalidation.** Plans **must** borrow immutable snapshot,
style, object and branch storage for their documented lifetime; layouts additionally
borrow the resolved font instances and backing font bytes under font's lifetime
contract. Scratch **must not** escape a call, and resetting it **must not**
invalidate a committed layout. The caller **may** destroy a snapshot or font backing
only after all plans/results borrowing it are released; mutation requires a new
revision.

**TL-007: Atomic operation effects.** Planning, projection, composition,
fragmentation and bulk source/visual export **must** publish a result only after
validation, dependency calls and capacity checks succeed. Failure leaves previously
published results and caller output lengths unchanged; scratch contents are
unspecified. Output and scratch **must not** overlap input or another live result,
and hostile input violations **must** return structured errors, not assertions.

**TL-008: Structured exhaustion.** A fallible operation **must** distinguish invalid
spans/styles/items, invalid UTF under the chosen base policy, `staleIdentity`,
`missingFont`, dependency font failure, `unsupportedCapability`, `noFeasibleLayout`,
`outputTooSmall`, `workspaceTooSmall`, `workLimit` and `arithmeticExhausted`.
Errors **must** name the operation, affected source/item when known and exhausted
limit, but **must not** include raw paragraph text or font bytes. Base and font
errors retain their typed cause rather than becoming an empty successful paragraph.

**TL-009: Declared resource limits.** Requests **must** supply maximum analysis
entries, candidate measurements, solver states, glyph records, alternatives and
feedback rounds, plus caller-owned output and workspace capacities.

**TL-039: Counted consumption.** Each consumed unit **must** be counted and
checked before storage growth or dependency invocation, and a failure **must**
report the exhausted limit. Dependency work limits apply in addition to these.

**TL-040: Whole long graphemes.** A long grapheme **must** remain a semantically
valid borrowed span, never a fixed-size scalar array. Exhausting a limit **must**
reject the operation rather than split or truncate the grapheme.

_Rationale:_ A truncated grapheme is a different piece of text that still looks
like a valid result, so the caller could not tell that anything was lost.

**TL-041: Documented cost.** Each concrete operation's documentation **must**
state its worst-case cost in input bytes, items, measured candidates, font work
and solver states.

There is no hidden allocation or global mutable paragraph cache. Solver bounds are
those of base's selected solver, not an unsupported “linear time” claim for
contextual composition. Immutable plans/results **may** be read concurrently; scratch
and mutable caches have one caller-controlled mutation owner and are not reentrant.

## 4. Rich paragraphs and planning

### Input model

A paragraph is an ordered immutable item sequence, a source snapshot, fully resolved
styles, explicit direction/language/writing-mode policy, and a typography-policy
revision. Composition inputs additionally identify per-line geometry, alignment,
base solver/objective and terminal-line option, whitespace/emergency policies,
resource limits and the permitted [typography profile](../../glossary.md#typography-profile):
the named set of adjustments, such as spacing changes, expansion and protrusion,
that the request allows. Text styles include font request, physical size, variation
coordinates, OpenType feature ranges, script/language overrides, baseline offset
and permitted adjustments. Paint-only attributes are opaque consumer IDs; they do
not alter measurement or cut a shaping run merely by changing colour.

The item vocabulary follows TeX's paragraph model. Glue is space that can stretch
or shrink within declared bounds, a kern is a fixed spacing adjustment, a penalty
marks a break point with a cost, and a discretionary is a hyphenation point with
distinct text for the broken and unbroken readings. The vocabulary preserves these
semantics before projecting to
[base's measurable primitives](../base/text/wrapping.md#_5-measurable-primitives):

| Rich item           | Paragraph information retained by text-layout                                                                                   |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| Text                | Source span or explicit provenance projection, resolved style and language                                                      |
| Box / inline object | Opaque host ID, fixed advance, before/after-baseline extents, ink bounds, source/alternative-text association, directional role |
| Glue                | Natural size, permitted adjustment from the base primitive, source association and edge-discard policy                          |
| Kern                | Signed fixed adjustment and the adjacent items it connects; no implicit break                                                   |
| Penalty             | Break boundary and base-owned cost/forced/forbidden semantics; source origin                                                    |
| Discretionary       | Three item fragments: pre-break, post-break and unbroken, plus one source origin and chosen branch identity                     |
| Anchor              | Zero-advance semantic ID, source boundary and affinity; no implied break or visible glyph                                       |
| Ruby                | Base item group plus associated annotation paragraph and alignment/overhang policy                                              |

**TL-010: Valid paragraph plan.** `planParagraph` **must** validate half-open
source bounds, scalar boundaries under the selected base decoding policy, style
coverage, unique item IDs, glue bounds, object metrics and branch references before
publishing a plan.

**TL-042: Empty paragraphs.** An empty paragraph **must** be valid. A physical
fixed-object or shaped-flow request **must** select `oneEmptyLine` or `noLines`;
cell-grid mode consumes base's empty-line convention.

`oneEmptyLine` produces one line whose extent is the request's strut, its declared
minimum before/after-baseline line extent, and which carries the paragraph-end
anchor. `noLines` produces no line and a paragraph-level end anchor.

**TL-043: Atomic branch fragments.** Each discretionary fragment **must** be a
finite nonnested item list with no interior break opportunity, whether optional,
forbidden, forced, or discretionary. Mandatory separators and explicit Penalty
items inside a fragment **must** be rejected as invalid input. Text branches
**must** suppress interior optional Unicode opportunities, never mandatory ones.

_Rationale:_ Each fragment is atomic under the owning base primitive algebra, so
its selected pre-break or post-break reading belongs wholly to the adjacent line.

**TL-044: Branch source coverage.** Source-backed coverage of the unbroken reading
**must** be declared in logical order, and repeated source references **must**
declare explicit duplication semantics. A discretionary replacement **may** remove
or replace visible source text, but original-copy operations **must** still refer
to its original span. Opaque controls **must** receive an explicit projection
policy, never accidental terminal escape interpretation.

**TL-038: Paint-only spans.** Paint-only changes **must** preserve their exact
snapshot-qualified source spans without splitting Unicode analysis or shaping,
changing candidate advances, or invalidating a shape solely because its brush
changed.

**TL-045: Cluster brush selection.** The default brush for a merged shaping
cluster **must** be the brush at its minimum logical source-byte contributor,
applied to all glyph occurrences of that cluster independent of visual glyph
order. Synthetic content **must** use its recorded origin anchor and affinity. A
caller **may** select an explicit post-composition paint-resolution policy over
the retained spans and cluster maps; that policy **must not** change geometry.

_Rationale:_ Cluster provenance does not decompose a ligature into per-glyph
contributors, so exact partial-glyph colouring is not guaranteed; a fixed logical
rule keeps the default stable under RTL reordering.

**TL-046: Grapheme-internal shaping styles.** A font, size, feature or other
shaping-affecting range boundary inside an extended grapheme **must** be rejected
rather than silently moved. A paint-only range boundary at a scalar boundary inside
a grapheme is valid and follows TL-038 and TL-045.

**TL-011: Discretionary projection.** `projectParagraph` with a valid selected
break set **must** emit the unbroken fragment for an unselected discretionary, or
emit its pre-break fragment on the preceding line and post-break fragment on the
following line when selected, exactly once each. Synthetic insertions **must** map
to the origin and branch; hidden original text **must** remain reachable by
source-copy operations. Invalid, duplicate or out-of-order selected breaks **must**
fail atomically.

**TL-012: Fixed-object projection.** Planning and projection of paragraphs whose
content is fixed boxes, glue, kerns, penalties, anchors and finite discretionary
fragments **must** execute without font resources or a fake font provider. Their
base-solver projection **must** preserve item identity, legal breaks, continuation
identity and costs; a text or ruby item requiring unresolved physical measurement
**must** return `unsupportedCapability`, not pretend its width is known.

The fixed-object path is an independently useful operation for a host that already
owns object geometry. It does not certify text itemization, font fallback, shaping,
carets inside glyphs, or publication composition.

**TL-013: Anchor preservation.** Anchors **must** survive reflow, branch selection,
zero-width controls and fragmentation. At a selected break an upstream anchor
attaches to the preceding line edge and a downstream anchor to the following line
edge; paragraph-start/end anchors attach to their existing line, including an
empty line. An anchor in an unselected branch is explicitly inactive, not silently
reattached to unrelated text.

## 5. Contextual composition

### Analysis and itemization

**TL-014: Whole-paragraph analysis.** `analyzeParagraph` **must** invoke base over
the complete logical paragraph projection to obtain grapheme boundaries, line
opportunities, script properties and paragraph bidi state. Font runs, paint spans,
line widths and fragment/page boundaries **must not** reset paragraph analysis.
Tailorings and host-supplied hyphenation opportunities **must** be explicit,
versioned inputs identified separately from default Unicode behavior.

**TL-037: Projection-dependent analysis.** When a discretionary choice changes
grapheme/script/bidi analysis outside its replaced span, composition **must** analyze
the complete selected paragraph projection through base and carry that analysis
identity into itemization and the exact candidate graph. Reusing unbroken analysis
requires demonstrated equivalence; a line-local reshape cannot repair stale
paragraph levels. Branch choices that affect earlier measurements **must** be
represented as finite explicit analysis/choice states, not merged into an
endpoint-only dynamic program.

This can require exploring complete branch-choice contexts before line selection;
it is a bounded exactness obligation, not a promised fast path. If the provider or
base state interface cannot represent those contexts, an exact request fails with
the specified capability/work outcome rather than guessing levels or disallowing
otherwise valid discretionary content.

**TL-047: Object directional roles.** An inline object's directional role **must**
enter bidi analysis through the declared base object/projection interface, never
by modifying source bytes.

**TL-048: Common-script resolution.** Itemization **must** resolve common and
inherited script by adopting a compatible surrounding script within the same
bidi/style item, preferring the preceding script when both neighbors differ, and
retaining base's script-extension compatibility. With no compatible neighbor it
**must** use the declared paragraph fallback script. An explicit script override
**must** win and be reported.

**TL-015: Deterministic itemization.** Itemization **must** partition content at
resolved bidi-level, shaping-style, script/language, object and selected-branch
boundaries, retaining the full paragraph context for font shaping. It **must not**
partition solely at words, paint changes or every grapheme. A font-affecting boundary
that cannot preserve the required contextual semantics **must** report its
unsupported capability rather than falsely label isolated shaping exact.

**TL-016: Context-safe fallback.** Text-layout **must** request matching and fallback
from font using the complete selection unit and context, consuming font's reported
face/instance and diagnostics. A unit **must not** split an extended grapheme,
variation sequence or shaping-unsafe span; nominal per-codepoint coverage alone
**must not** be treated as successful shaping. Exhausted real fallback **must**
produce a reported missing glyph or `missingFont` according to explicit request
policy, not fabricated metrics.

Fallback consumes font's
[fallback-chain and whole-span fallback contracts](../font/SPEC.md#_13-discovery-matching-and-fallback)
(FTD5, FTD7), not a private layout font catalog. A notdef policy draws the font's
`.notdef` glyph, which a font shows for a character it does not map. Such a policy
**may** preserve that glyph's real metrics and source maps; it is not permission to
convert a failed dependency call into success. The resolved fallback choice
participates in all measurement keys.

### Measuring and selecting lines

**TL-017: Exact contextual candidates.** For an exact solver request, every feasible
candidate **must** be measured using its selected discretionary fragments, actual
font instances, line-start/end context, direction, features, permitted adjustment
choices and geometry. An unbroken shaped paragraph, sum of separately shaped words,
nominal advances or prefix-width subtraction **must not** be used as exact candidate
width unless font's safe-reuse contract proves equivalence for that candidate.

The candidate provider implements
[base's contextual measurement capability](../base/text/wrapping.md#_6-measurement-providers).
Its continuation identity includes the selected post-break branch and any retained
context affecting the next line. Each measured candidate carries an
**exact-measure token**: an identity of the complete measurement request and the
typography decisions chosen for it, from which the line can be realized without
remeasuring. Generic solver state, fitness, penalties and tie-breaking remain owned
by [base](../base/text/wrapping.md#_7-solvers).

**TL-049: Context-complete measurement.** The provider **must** pass every context
distinction through base's measurement interface and **must not** merge paths only
because they end at the same byte offset.

**TL-018: Break safety and reshaping.** A legal base break marked unsafe by font
**must** cause shaping with the actual boundary context on both resulting sides;
unsafe-to-concatenate joins require reshaping when branches or runs are joined.
Safe flags permit validated reuse, not new Unicode opportunities. Selected lines
**must** be realized from the exact-measure token or recomputed with identical
inputs; a difference between measured and realized advance is a dependency/contract
failure and **must not** publish the layout.

**TL-050: Breaks inside shaping clusters.** A legal base opportunity inside a
shaping cluster **must not** be forbidden on that account; the engine **must**
reshape the cluster's source at that boundary.

**TL-051: No silent downgrade.** Emergency breaking **must** be an explicit request
policy and **must not** bisect a base grapheme. A cache or work limit **must not**
replace exact search with greedy search.

**TL-019: Physical scale conversion.** Candidate and realized metrics **must** use
[base's `LayoutUnit` and aggregation contract](../base/text/wrapping.md#layoutunit),
consuming [font's scalable design metrics](../font/SPEC.md#_9-metrics) with explicit
design-position scale, units-per-em and physical em size. Text-layout **must**
preserve the exact across-run accumulator for absolute origins and line totals
until that contract's final quantization, never sum individually quantized glyph
advances. Conversion failures **must** propagate atomically; no DPI-derived scale
is allowed.

### Final line geometry

**TL-020: Line bidi and alignment.** After selecting logical breaks, shaped-flow
composition **must** consume base's line-level bidi resolution/reordering for the
selected content, preserving the analyzed paragraph state. Start/end alignment
**must** resolve against paragraph inline direction; left/right are explicit
physical alternatives. The result **must** expose both logical sequence and visual
run order, including trailing whitespace and controls, without rewriting source
order.

**TL-052: No cell-grid reordering.** In `cellGrid` mode composition **must not**
apply visual reordering: each line's visual run order is its logical order. The
analyzed paragraph bidi state remains available to the consumer.

_Rationale:_ Base's per-line bidi contract
([TXT-BIDI2](../base/text/SPEC.md#_4-2-word-sentence-line-and-bidi)) forbids
automatic reordering of terminal text, and the design system treats bidi as a
non-goal on the cell target ([GLY6](../design-system/glyphs.md)).

**TL-021: Justification realization.** A justified line **must** report natural
advance, target measure, each applied adjustment and its final advance. Adjustments
**must** stay within the request's declared per-opportunity and line limits; exact
fit **must** sum to the target in `LayoutUnit`, distributing a rounding residual in
stable logical opportunity order. An infeasible target **must** return
`noFeasibleLayout` or an explicitly requested ragged/overfull alternative carrying
its residual, not conceal an overfull line by clipping.

A shaped line contains positioned glyph occurrences referencing immutable font
instances, object rectangles, source/cluster maps, anchors, baseline, advance and
ink bounds. It has no renderer handles. Overfull advance, protruding ink and object
ink overflow are distinct observations; visual clipping belongs to the consumer.

**TL-022: Independent caches.** Caller-owned font resource/shape caches **must** be
independent of paragraph candidate/width/layout caches. A width change **may** reuse
font resources but **must** invalidate candidate keys involving geometry, line
ordinal or boundary context. A font, catalog or instance change **must** invalidate
affected shape and candidate entries even if text and width are unchanged.

**TL-053: Complete cache keys.** A cache key **must** include snapshot/projection
identity, resolved selection, base/font revision, scale, features,
language/script/direction, branch/context, adjustment policy and geometry wherever
each affects the cached result. A pointer or family name alone **must not** serve
as a key.

**TL-054: Paint-only revisions.** Paint-only revisions **must not** invalidate
reusable analysis, shape or measurement entries whose semantic inputs are
unchanged. Committed presentation records carry paint-span and paint-resolver
identities; changing either **must** update brushes without returning stale
presentation or changing glyphs, physical origins, breaks, source maps or caret
geometry.

_Rationale:_ Neither default nor custom paint resolution implies per-glyph source
attribution or partial-glyph colouring, so colour can change without any geometric
consequence.

## 6. Source maps and interaction

**TL-023: Complete logical/visual mapping.** Composition **must** provide mappings
among source spans, graphemes, shaping clusters, glyph occurrences, lines and visual
runs, including source text with zero glyphs, multiple glyphs per cluster, ligatures
spanning graphemes, synthetic discretionary text and inline objects. RTL glyph
order **must not** be mistaken for increasing source offsets. Reflow **must**
preserve logical identities while replacing result-qualified visual identities.

**TL-024: Caret affinity.** Caret queries **must** return a source boundary and
upstream/downstream affinity, never a byte inside a grapheme. At bidi transitions
and selected breaks, multiple visual positions for one logical boundary **must** be
retained. Hit-testing **must** return the nearest inline-axis stop, breaking an
exact tie by smaller visual inline coordinate and then logical source order.
Block-axis selection **must** choose the nearest line box, breaking ties by earlier
line ordinal.

**TL-055: Caret stops inside clusters.** When font supplies ligature carets,
caret stops within a cluster **must** use those validated positions. Without them,
stops **must** subdivide the cluster's advance equally among its legal grapheme
boundaries in logical order, transformed to visual direction, and be marked
`estimated`. Zero-advance clusters **must** retain coincident stops and affinities;
objects **must** expose only their declared edge stops unless a host supplies an
object-specific interaction map.

_Rationale:_ Equal subdivision is an interaction policy that claims no internal ink
boundary; the `estimated` mark keeps it from being mistaken for font data.

**TL-025: Shared geometry.** Painting, hit-testing, selection and visible-text
export **must** consume the same committed line/cluster result, never independently
measure text. Selection rectangles are visual fragments of a logical source range;
copy **must** return the requested original source span in logical order unless the
caller explicitly requests visible-text projection. A discretionary hyphen **must
not** appear in original-source copy merely because it is visible.

**TL-056: Cell-grid interaction.** Cell-grid interaction **must** use base's
source/grid-cell projection, including whole-grapheme occupancy and wide-cell
continuation. When shaping ink extends across several grid cells, a terminal
renderer **must** damage the covered ink without changing grid-cell advance or
reinterpreting a source column as a glyph index.

Proportional documentation prose in a toolkit window, the design system's
[GLY7](../design-system/glyphs.md), is a `shapedFlow` paragraph laid out inside the
widget's [cell](../../glossary.md#cell) rect. The host converts that rect to a
physical line measure. Painting, hit-testing and selection inside the rect consume
the paragraph's one committed cluster result under TL-025, and the paragraph never
paints outside the rect it was given. On a cell target the same run is a `cellGrid`
paragraph in the same rect.

## 7. Publication interfaces

These are mandatory paragraph interfaces, not claims that a document or page engine
exists. A typography profile explicitly enables supported capabilities and bounds.

**TL-057: Explicit typography profiles.** A request for a capability its typography
profile does not support **must** fail before publishing a result. Disabling a
typography profile **must not** silently approximate its typography.

### Microtypography and script-aware justification

**TL-026: Bounded microtypography.** Publication requests **must** identify allowed
space adjustment, tracking, font-width/expansion choices and margin protrusion
separately, with finite bounds and a versioned cost policy. Expansion choices are
finite declared font-instance or geometric-transform alternatives, not an implicit
continuous optimizer; every width-affecting choice **must** be part of exact
candidate measurement and final output. Geometric transforms **must** be explicitly
labelled and **must not** stand in for an unprovided font axis.

**TL-027: Protrusion accounting.** Edge protrusion **must** name the actual visual
edge glyph/object and its permitted offset, expose ink outside the measure, and
report the effective fitting measure separately from physical advance. It **must
not** alter source ordering, hide overflow, or move caret positions by treating ink
bounds as advances; renderer clipping and page clearance are host decisions.

**TL-028: Script-aware adjustment.** Justification **must** use explicit eligible
opportunities from the resolved script/font policy: glue, authorized inter-character
spacing, or engine-supported Arabic elongation/alternate forms. It **must not**
insert spaces between arbitrary Unicode scalars or stretch joining/combining text by
Latin-space rules. Inserting a tatweel (U+0640 ARABIC TATWEEL, the kashida stroke
that lengthens a join between Arabic letters) **must** require font-reported safe
positions, an explicit synthetic projection and reshaping; the resulting glyphs,
cost and provenance **must** be included in the measured candidate. Absent
capabilities **must** fail or select an explicit declared non-elongating typography
profile, never guessed kashidas.

### Baselines, writing modes, ruby and objects

**TL-029: Baseline geometry.** Every line **must** report inline advance, block
extent, baseline kind and position, before/after-baseline extents and ink bounds.
An explicit strut and each run/object baseline offset participate in the extent
union; ink overflow is reported separately. Absent baseline metrics **must** follow
an explicit request fallback policy, not a silently inferred zero metric.

**TL-030: Writing-mode composition.** Requests **must** distinguish horizontal,
vertical-rl and vertical-lr, paragraph inline direction and upright/rotated run
orientation. Vertical composition **must** use actual vertical metrics/shaping and
orientation policy from the declared font/base capabilities, and **must** expose the
inline/block-to-physical transform for rendering and hit-testing. Rotating a
horizontal paragraph alone **must not** be labelled vertical composition.

**TL-031: Ruby and inline objects.** Ruby **must** retain distinct base and
annotation source identities, resolved annotation typography, placement side and
alignment/overhang limits. Both **must** be measured contextually and participate in
line fitting, baseline extents and interaction; base/annotation pairs are atomic
unless the host supplies explicit paired segmentation. An inline object **must**
retain host ID, advance/extents/ink, baseline and bidi role, alternative text and
permitted fragmentation behavior; text-layout **must not** invoke its renderer or
inspect its resource bytes.

Mathematical formulae enter through the same object or explicit breakable-fragment
interface. [Font owns OpenType parsing](../font/SPEC.md#_7-parsing), including its
FTP13 MATH-table contract; a math composer above font owns atom spacing, fractions,
radicals, scripts, stretch assemblies and mathematical line breaking. Text-layout
consumes its measured, source-mapped output, not a fake math box whose metrics are
still unknown.

### Alternatives, fragmentation and page feedback

**TL-032: Alternative paragraph layouts.** `composeAlternatives` **must** accept a
finite count limit and explicit objective/constraints, including requested line
counts or geometry alternatives. It **must** consume
[base's ranked alternative solver](../base/text/wrapping.md#constrained-and-alternative-solutions)
rather than owning another search algorithm. Each result **must** report geometry
revision, line count/block extent, break/branch identities, adjustment summary,
overfull status and cost-policy identity. The list **must** retain base's
ranking-proof and exhaustive/more status. A top-K ranking proof establishes that
the first K returned layouts are the K lowest-cost admissible layouts, in order; an
exact top-K prefix **may** carry it without exhausting all paths, and an approximate
best-found list **must not** claim it.

**TL-033: Fragment continuation.** `fragmentLayout` at a declared legal line
boundary **must** expose the fragment's lines, block extent, anchors, source
coverage and a continuation token qualified by paragraph/projection/layout,
geometry and policy revisions. Rejoining unchanged fragments **must** recover the
same logical content, selected branches and line geometry as the original result.
Continuation **must** retain original paragraph bidi state and discretionary
post-break identity; a page boundary **must not** pretend to be a paragraph start.

**TL-058: Recomposition after fragmentation.** A continuation token into an already
composed layout **must** select immutable lines without reshaping. Recomposition
with different following geometry **must** be a separate composition request with a
revision-qualified break checkpoint and full paragraph context, and it **must**
re-evaluate affected candidates rather than preserve a locally optimal suffix.

Stale tokens fail under TL-004. The page host owns widow/orphan, keep, float,
footnote and cross-paragraph/page cost policy.

**TL-034: Page feedback boundary.** A host **must** be able to supply a finite
revisioned sequence of per-line origins/measures, exclusion geometry and fragment
constraints, receive alternative summaries plus anchor positions, and request
recomposition after choosing a page/float placement. Every feedback request **must**
name the previous result and a new geometry revision; exceeding the explicit
feedback limit or failing to reach the host's declared fixed-point criterion
**must** return an observable nonconverged outcome. Text-layout **must not** run an
unbounded callback cycle, select pages, or claim global optimality across host page
decisions.

**TL-035: Export handoff.** A committed result **must** expose positioned glyph
occurrences and immutable font identities, original-source spans, synthetic
provenance, logical reading order, visual geometry, anchors, object IDs and
orientation/transforms without raster-only handles. An export host **must** be able
to preserve logical text independently of glyph order and distinguish synthetic
hyphens from source text. PDF serialization, font embedding/subsetting, tagged
structure, colour management and front-end parsing are outside this owner; their
absence **must not** be advertised as completed publication support.

## 8. Compatibility and acceptance boundary

**TL-036: Clean caller cutover.** A consumer migrated to text-layout **must** use
the committed result for all affected measurement, painting and source interaction,
and remove its competing paragraph, width and hit-test helpers. Migration **must
not** leave deprecated aliases or fallback code paths that silently reintroduce
Phobos Unicode or renderer-derived geometry. Independent base-only terminal-cell
consumers **may** remain base-only; they do not need a physical paragraph engine.

## 9. Sources and authority

Normative shared contracts are [base text](../base/text/SPEC.md),
[base wrapping](../base/text/wrapping.md), and [font](../font/SPEC.md).
Their editions and revisions govern the imported algorithms; this document adds
local composition policy rather than claiming conformance to a second Unicode
edition. Research informs, but does not accept, these requirements:

- [HarfBuzz research](../../research/font-libraries/harfbuzz.md#_3-shaping) describes
  pre/post-context, cluster levels and safe-break/concat/tatweel flags at a pinned
  revision. Those capabilities motivate TL-017–TL-018 and TL-028, not a private
  text-layout binding.
- [Parley research](../../research/font-libraries/parley.md) motivates separation
  of font resources, analysis, composition and renderer output; its policies are
  not adopted wholesale.
- [Pango research](../../research/font-libraries/pango.md) demonstrates why a
  platform layout facade is not an owned deterministic font boundary.
- [Knuth–Plass research](../../research/ui-layout/tex-knuth-plass.md) motivates
  paragraph-wide alternatives. Its historical complexity summaries are not a bound
  on this contextual model and its three-item sketch is not our rich input contract.
- [Text sizing proposal](../../research/tui-libraries/text-sizing/sparkles-proposal.md)
  supplies source-map and shared-measurement concerns, not an accepted physical
  paragraph API. Terminal text sizing, a run drawn at an integer scale or a
  fractional width of grid cells, is base's scaled cell footprint contract in
  [base text](../base/text/SPEC.md), consumed by the design system's
  [GLY5](../design-system/glyphs.md) and its open question
  [OQ5](../design-system/decisions.md); it is not a paragraph API here.
