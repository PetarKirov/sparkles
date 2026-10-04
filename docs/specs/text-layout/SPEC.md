---
status: draft
owner: sparkles:text-layout
reviewed: 2026-10-04
---

# `sparkles:text-layout` — Specification

## Abstract

`sparkles:text-layout` composes rich paragraphs into backend-neutral lines with
stable links between source text, glyphs, and interaction geometry. It combines
owned Unicode analysis and generic wrapping from base with font selection and
contextual shaping from font. Paragraphs contain text, fixed objects, adjustable
space, explicit breaks, and discretionary replacements; the selected layout is the
one measured, painted, hit-tested, and exported. Physical typography and terminal
cell placement are distinct modes. Publication consumers can request alternatives,
fragment paragraphs, and supply geometry feedback without surrendering document or
page policy to the paragraph engine. Font loading, rasterization, document parsing,
mathematical composition, page building, and PDF writing belong to other owners.

## Introduction

An editor needs a click on a right-to-left ligature to reach the right source
position. A publication engine needs paragraph choices whose actual line widths
include contextual forms, discretionary hyphens, and spacing adjustments. A terminal
needs cells whose occupancy remains independent of a programming font's ligature
ink. These consumers all need a reusable paragraph result, but not the same width
model or a renderer-specific text stack.

The difficult boundary is between choosing breaks and shaping text. A word's width
inside an unbroken paragraph need not be its width at a line boundary. A grapheme
is not a shaping cluster, a cluster is not a glyph, and visual order is not source
order. Summing separately shaped words and subsequently reshaping the chosen lines
can invalidate the very optimization that chose those lines.

This library retains a source-mapped rich paragraph and measures complete candidate
lines in the context that their realization uses. Base owns Unicode behavior and
the pure solvers; font owns resources, matching, fallback, and shaping. This layer
owns their composition, source/visual maps, line geometry, and interaction. All
operation and type names below are **proposed**, not delivered public symbols.

This is a paragraph and publication-interface contract, not a TeX-language or
TeX-output compatibility claim. It does not parse HTML, CSS, Markdown, MathML or
TeX, choose pages or floats, implement mathematical layout, rasterize glyphs, or
serialize a document. Its interfaces make those consumers possible without
pretending they are implemented. The physical shaped path requires a real font
engine; a fixed-object paragraph plan is useful independently and is not a substitute
for that path.

[The delivery plan](./PLAN.md) owns prerequisites and progress.
[Testing](./testing.md) defines falsifying scenarios and planned evidence.
[Decisions](./decisions.md) records trade-offs and unresolved architectural gates.
Sections 4–6 define paragraph operations, contextual composition, and interaction;
section 7 defines the publication seam.

## 1. Contract at a glance

1. Base is the sole owner of [UTF and Unicode](../base/text/SPEC.md), including
   segmentation, line opportunities, bidi, normalization and casing. Text-layout
   consumes those results; it does not implement competing algorithms.
2. Base owns [physical `LayoutUnit`](../base/text/wrapping.md#layoutunit) and
   [pure wrapping solvers](../base/text/wrapping.md#_7-solvers). Cells are not physical
   lengths and cannot enter a shaped solver through an implicit conversion.
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
required for shaping must be recorded at the font integration boundary. This spec
does not restate UAX algorithms or codec error rules.

**TL-002: Backend neutrality.** Paragraph planning and physical composition
**must** depend only on explicit inputs, base, and font's engine contract, never
on DPI, framebuffer size, a window, GPU, atlas residency or platform font discovery
side effects. A renderer **must** convert the physical result at its own device
boundary; changing only device scale must not change physical line breaks.

**TL-003: Explicit mode.** Every plan and layout **must** name `cellGrid` or
`shapedFlow`. Cell-grid placement **must** consume base cell advances and explicit
integer footprints; optional font shaping affects ink only, not occupancy or
source-column positions. Shaped-flow placement **must** consume physical lengths
and real font shaping, never cell widths or per-codepoint width estimates.

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

A **grapheme identity** names a base-produced extended grapheme span. A **shaping
cluster identity** names font's input cluster span within an item and can cover
several graphemes or glyphs. A **glyph identity** additionally qualifies the font
instance, glyph ID and occurrence within the shaped result. A **logical position**
names a source boundary and affinity; a **visual position** names a layout result,
line, run and caret edge. The relationship is many-to-many, not an index cast.

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
contract. Scratch **must not** escape a call, and resetting it must not invalidate
a committed layout. The caller may destroy a snapshot or font backing only after
all plans/results borrowing it are released; mutation requires a new revision.

**TL-007: Atomic operation effects.** Planning, projection, composition,
fragmentation and bulk source/visual export **must** publish a result only after
validation, dependency calls and capacity checks succeed. Failure leaves previously
published results and caller output lengths unchanged; scratch contents are
unspecified. Output and scratch may not overlap input or another live result, and
hostile input violations must return structured errors, not assertions.

**TL-008: Structured exhaustion.** A fallible operation **must** distinguish invalid
spans/styles/items, invalid UTF under the chosen base policy, `staleIdentity`,
`missingFont`, dependency font failure, `unsupportedCapability`, `noFeasibleLayout`,
`outputTooSmall`, `workspaceTooSmall`, `workLimit` and `arithmeticExhausted`.
Errors **must** name the operation, affected source/item when known and exhausted
limit, but must not include raw paragraph text or font bytes. Base and font errors
retain their typed cause rather than becoming an empty successful paragraph.

**TL-009: Bounded resources.** Requests **must** supply maximum analysis entries,
candidate measurements, solver states, glyph records, alternatives and feedback
rounds, plus caller-owned output and workspace capacities. Each consumed unit
**must** be counted, checked before storage growth or dependency invocation, and
reported on failure; dependency work limits also apply. Long graphemes remain
semantically valid borrowed spans, not fixed-size scalar arrays; exhaustion must
reject the operation rather than split or truncate them.

There is no hidden allocation or global mutable paragraph cache. The concrete
operation's documentation must state its worst-case cost in input bytes, items,
measured candidates, font work and solver states. Solver bounds are those of base's
selected solver, not an unsupported “linear time” claim for contextual composition.
Immutable plans/results may be read concurrently; scratch and mutable caches have
one caller-controlled mutation owner and are not reentrant.

## 4. Rich paragraphs and planning

### Input model

A paragraph is an ordered immutable item sequence, a source snapshot, fully resolved
styles, explicit direction/language/writing-mode policy, and a typography-policy
revision. Composition inputs additionally identify per-line geometry, alignment,
base solver/objective and terminal-line option, whitespace/emergency policies,
resource limits and the permitted adjustment profile. Text styles include font
request, physical size, variation coordinates, OpenType feature ranges,
script/language overrides, baseline offset and permitted adjustments. Paint-only
attributes are opaque consumer IDs; they do not alter measurement or cut a shaping
run merely by changing colour.

The item vocabulary preserves semantics before projecting to
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
publishing a plan. Conflicting font, size, feature or other shaping-affecting
ranges inside an extended grapheme **must** be rejected rather than silently moved;
paint-only ranges at scalar boundaries are valid and follow TL-038. Empty
paragraphs are valid: physical fixed-object/shaped-flow requests explicitly select
`oneEmptyLine` (one strut-sized line with the end anchor) or `noLines` (no line,
paragraph-level end anchor). Cell-grid mode consumes base's empty-line convention.

Branch fragments must be finite nonnested item lists with no interior break
opportunity, whether optional, forbidden, forced, or discretionary. Each fragment
is atomic under the owning base primitive algebra; its selected pre/post reading
belongs wholly to the adjacent line. Mandatory separators and explicit Penalty
items inside a fragment are invalid input. Text branches suppress interior optional
Unicode opportunities under that declared atomic-fragment policy, never mandatory ones.
Source-backed coverage of the unbroken reading projection must be declared in
logical order; repeated source references require
explicit duplication semantics. Discretionary replacements may remove or replace
visible source text, but original-copy operations still refer to its original span.
Opaque controls receive explicit projection policy, never accidental terminal
escape interpretation.

**TL-038: Paint-only spans.** Paint-only changes **must** preserve their exact
snapshot-qualified source spans without splitting Unicode analysis or shaping,
changing candidate advances, or invalidating a shape solely because its brush
changed. The default brush for a merged shaping cluster is selected at its
minimum logical source-byte contributor and applied to all glyph occurrences
associated with that cluster, independent of visual glyph order. Synthetic
content uses its recorded origin anchor and affinity. A caller may select an
explicit post-composition paint-resolution policy over the retained spans and
cluster maps; it must not change geometry. Cluster provenance does not guarantee
per-glyph contributor decomposition or exact partial-glyph colouring.

**TL-011: Discretionary projection.** `projectParagraph` with a valid selected
break set **must** emit the unbroken fragment for an unselected discretionary, or
emit its pre-break fragment on the preceding line and post-break fragment on the
following line when selected, exactly once each. Synthetic insertions **must** map
to the origin and branch; hidden original text must remain reachable by source-copy
operations. Invalid, duplicate or out-of-order selected breaks must fail atomically.

**TL-012: Fixed-object projection.** Planning and projection of paragraphs whose
content is fixed boxes, glue, kerns, penalties, anchors and finite discretionary
fragments **must** execute without font resources or a fake font provider. Their
base-solver projection **must** preserve item identity, legal breaks, continuation
identity and costs; a text or ruby item requiring unresolved physical measurement
must return `unsupportedCapability`, not pretend its width is known.

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
Tailorings and host-supplied hyphenation opportunities must be explicit, versioned
inputs identified separately from default Unicode behavior.

**TL-037: Projection-dependent analysis.** When a discretionary choice changes
grapheme/script/bidi analysis outside its replaced span, composition **must** analyze
the complete selected paragraph projection through base and carry that analysis
identity into itemization and the exact candidate graph. Reusing unbroken analysis
requires demonstrated equivalence; a line-local reshape cannot repair stale
paragraph levels. Future branch choices that affect earlier measurements must be
represented as finite explicit analysis/choice states, not merged into an
endpoint-only dynamic program.

This can require exploring complete branch-choice contexts before line selection;
it is a bounded exactness obligation, not a promised fast path. If the provider or
base state interface cannot represent those contexts, an exact request fails with
the specified capability/work outcome rather than guessing levels or disallowing
otherwise valid discretionary content.

Inline object directional roles enter bidi analysis through the declared base
object/projection interface, not by modifying source bytes. Common/inherited-script
resolution belongs to text-layout itemization: adopt compatible surrounding script
within the same bidi/style item, prefer preceding when both differ, and retain
base's script-extension compatibility; no compatible neighbor uses the declared
paragraph fallback script. Explicit script overrides win and are reported.

**TL-015: Deterministic itemization.** Itemization **must** partition content at
resolved bidi-level, shaping-style, script/language, object and selected-branch
boundaries, retaining the full paragraph context for font shaping. It **must not**
partition solely at words, paint changes or every grapheme. A font-affecting boundary
that cannot preserve the required contextual semantics must report its unsupported
capability rather than falsely label isolated shaping exact.

**TL-016: Context-safe fallback.** Text-layout **must** request matching and fallback
from font using the complete selection unit and context, consuming font's reported
face/instance and diagnostics. A unit must not split an extended grapheme, variation
sequence or shaping-unsafe span; nominal per-codepoint coverage alone must not be
treated as successful shaping. Exhausted real fallback produces a reported missing
glyph or `missingFont` according to explicit request policy, not fabricated metrics.

Fallback is a delivery dependency on [font M7](../font/PLAN.md#m7-discovery-and-fallback),
not a private layout font catalog. A notdef policy may preserve real notdef glyph
metrics and source maps; it is not permission to convert a failed dependency call
into success. The resolved fallback choice participates in all measurement keys.

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
context affecting the next line. Its exact-measure token identifies the complete
request and chosen typography decisions. Generic solver state, fitness, penalties
and tie-breaking remain owned by [base](../base/text/wrapping.md#_7-solvers); this
layer must pass every context distinction through that interface, not merge paths
just because they end at the same byte offset.

**TL-018: Break safety and reshaping.** A legal base break marked unsafe by font
**must** cause shaping with the actual boundary context on both resulting sides;
unsafe-to-concatenate joins require reshaping when branches or runs are joined.
Safe flags permit validated reuse, not new Unicode opportunities. Selected lines
**must** be realized from the exact-measure token or recomputed with identical
inputs; differing measured and realized advance is a dependency/contract failure
and must not publish the layout.

A legal opportunity inside a shaping cluster is not automatically forbidden: the
engine must be able to reshape its source at that boundary. Conversely, emergency
breaking is an explicit request policy and may not bisect a base grapheme. A
cache or work limit must never quietly replace exact search with greedy search.

**TL-019: Physical scale conversion.** Candidate and realized metrics **must** use
[base's `LayoutUnit` and aggregation contract](../base/text/wrapping.md#layoutunit),
consuming [font's scalable design metrics](../font/SPEC.md#_9-metrics) with explicit
design-position scale, units-per-em and physical em size. Text-layout **must**
preserve the exact across-run accumulator for absolute origins and line totals
until that contract's final quantization, never sum individually quantized glyph
advances. Conversion failures propagate atomically; no DPI-derived scale is allowed.

### Final line geometry

**TL-020: Line bidi and alignment.** After selecting logical breaks, composition
**must** consume base's line-level bidi resolution/reordering for the selected
content, preserving the analyzed paragraph state. Start/end alignment must resolve
against paragraph inline direction; left/right are explicit physical alternatives.
The result must expose both logical sequence and visual run order, including
trailing whitespace and controls, without rewriting source order.

**TL-021: Justification realization.** A justified line **must** report natural
advance, target measure, each applied adjustment and its final advance. Adjustments
must stay within the request's declared per-opportunity and line limits; exact fit
must sum to the target in `LayoutUnit`, distributing a rounding residual in stable
logical opportunity order. An infeasible target must return `noFeasibleLayout` or
an explicitly requested ragged/overfull alternative carrying its residual, not
conceal an overfull line by clipping.

A shaped line contains positioned glyph occurrences referencing immutable font
instances, object rectangles, source/cluster maps, anchors, baseline, advance and
ink bounds. It has no renderer handles. Overfull advance, protruding ink and object
ink overflow are distinct observations; visual clipping belongs to the consumer.

**TL-022: Independent caches.** Caller-owned font resource/shape caches **must** be
independent of paragraph candidate/width/layout caches. Width changes may reuse
font resources but must invalidate candidate keys involving geometry, line ordinal
or boundary context; font/catalog/instance changes must invalidate affected shape
and candidate entries even if text and width are unchanged. Keys must include
snapshot/projection identity, resolved selection, base/font revision, scale,
features, language/script/direction, branch/context, adjustment policy and geometry
where each affects the cached result; a pointer or family name alone is not a key.
Paint-only revisions **must not** invalidate reusable analysis, shape or measurement
entries whose semantic inputs are unchanged. Committed presentation records instead
carry paint-span and paint-resolver identities: changing either **must** update brushes
without returning stale presentation or changing glyphs, physical origins, breaks,
source maps or caret geometry. Neither default nor custom resolution implies missing
per-glyph source attribution or partial-glyph colouring.

## 6. Source maps and interaction

**TL-023: Complete logical/visual mapping.** Composition **must** provide mappings
among source spans, graphemes, shaping clusters, glyph occurrences, lines and visual
runs, including source text with zero glyphs, multiple glyphs per cluster, ligatures
spanning graphemes, synthetic discretionary text and inline objects. RTL glyph
order must not be mistaken for increasing source offsets. Reflow must preserve
logical identities while replacing result-qualified visual identities.

**TL-024: Caret affinity.** Caret queries **must** return a source boundary and
upstream/downstream affinity, never a byte inside a grapheme. At bidi transitions
and selected breaks, multiple visual positions for one logical boundary must be
retained; hit-testing returns the nearest inline-axis stop, breaking an exact tie
by smaller visual inline coordinate and then logical source order. Block-axis
selection chooses the nearest line box, ties by earlier line ordinal.

When font supplies ligature carets, use validated positions within the cluster.
Without them, subdivide the cluster's advance equally among its legal grapheme
boundaries in logical order, transformed to visual direction, and mark these stops
`estimated`. This policy does not claim an internal ink boundary. Zero-advance
clusters retain coincident stops and affinities; objects expose only their declared
edge stops unless a host supplies an object-specific interaction map.

**TL-025: Shared geometry.** Painting, hit-testing, selection and visible-text
export **must** consume the same committed line/cluster result, never independently
measure text. Selection rectangles are visual fragments of a logical source range;
copy returns the requested original source span in logical order unless the caller
explicitly requests visible-text projection. A discretionary hyphen must not appear
in original-source copy merely because it is visible.

Cell-grid interaction uses base's source/cell projection, including whole-grapheme
occupancy and wide-cell continuation. Shaping ink may extend across multiple cells;
a terminal renderer must damage the covered ink, but that is not a change to cell
advance or a reason to reinterpret a source column as a glyph index.

## 7. Publication interfaces

These are mandatory paragraph interfaces, not claims that a document or page engine
exists. Profiles explicitly enable supported capabilities and bounds. Unsupported
requested capabilities fail before publishing a result; disabling a profile does
not silently approximate its typography.

### Microtypography and script-aware justification

**TL-026: Bounded microtypography.** Publication requests **must** identify allowed
space adjustment, tracking, font-width/expansion choices and margin protrusion
separately, with finite bounds and a versioned cost policy. Expansion choices are
finite declared font-instance or geometric-transform alternatives, not an implicit
continuous optimizer; every width-affecting choice must be part of exact candidate
measurement and final output. Geometric transforms must be explicitly labelled and
must not stand in for an unprovided font axis.

**TL-027: Protrusion accounting.** Edge protrusion **must** name the actual visual
edge glyph/object and its permitted offset, expose ink outside the measure, and
report the effective fitting measure separately from physical advance. It must not
alter source ordering, hide overflow, or move caret positions by treating ink
bounds as advances; renderer clipping and page clearance are host decisions.

**TL-028: Script-aware adjustment.** Justification **must** use explicit eligible
opportunities from the resolved script/font policy: glue, authorized inter-character
spacing, or engine-supported Arabic elongation/alternate forms. It must not insert
spaces between arbitrary Unicode scalars or stretch joining/combining text by
Latin-space rules. Tatweel insertion requires font-reported safe positions, an
explicit synthetic projection and reshaping; resulting glyphs, cost and provenance
must be included in the measured candidate. Absent capabilities fail or select an
explicit declared non-elongating profile, never guessed kashidas.

### Baselines, writing modes, ruby and objects

**TL-029: Baseline geometry.** Every line **must** report inline advance, block
extent, baseline kind and position, before/after-baseline extents and ink bounds.
Explicit strut/minimum line extent and each run/object baseline offset participate
in the extent union; ink overflow is reported separately. Baseline-metric absence
requires an explicit request fallback policy, not a silently inferred zero metric.

**TL-030: Writing-mode composition.** Requests **must** distinguish horizontal,
vertical-rl and vertical-lr, paragraph inline direction and upright/rotated run
orientation. Vertical composition requires actual vertical metrics/shaping and
orientation policy from the declared font/base capabilities; it must expose the
inline/block-to-physical transform for rendering and hit-testing. Rotating a
horizontal paragraph alone must not be labelled vertical composition.

**TL-031: Ruby and inline objects.** Ruby **must** retain distinct base and
annotation source identities, resolved annotation typography, placement side and
alignment/overhang limits. Both must be measured contextually and participate in
line fitting, baseline extents and interaction; base/annotation pairs are atomic
unless the host supplies explicit paired segmentation. An inline object must
retain host ID, advance/extents/ink, baseline and bidi role, alternative text and
permitted fragmentation behavior; text-layout must not invoke its renderer or
inspect its resource bytes.

Mathematical formulae enter through the same object or explicit breakable-fragment
interface. [Font owns OpenType parsing](../font/SPEC.md#_7-parsing), including its
draft FTP13 MATH-table contract; a math composer above font owns atom
spacing, fractions, radicals, scripts, stretch assemblies and mathematical line
breaking. Text-layout consumes its measured, source-mapped output, not a fake
math box whose metrics are still unknown.

### Alternatives, fragmentation and page feedback

**TL-032: Alternative paragraph layouts.** `composeAlternatives` **must** accept a
finite count limit and explicit objective/constraints (including requested line
counts or geometry alternatives), consuming
[base's ranked alternative solver](../base/text/wrapping.md#constrained-and-alternative-solutions)
rather than owning another search algorithm. Each result must report geometry
revision, line count/block extent, break/branch identities, adjustment summary,
overfull status and cost-policy identity. The list must retain base's ranking-proof
and exhaustive/more status: an exact top-K prefix may have proven global ranks
without exhausting all paths; an approximate best-found list must not claim them.

**TL-033: Fragment continuation.** `fragmentLayout` at a declared legal line
boundary **must** expose the fragment's lines, block extent, anchors, source
coverage and a continuation token qualified by paragraph/projection/layout,
geometry and policy revisions. Rejoining unchanged fragments must recover the
same logical content, selected branches and line geometry as the original result.
Continuation must retain original paragraph bidi state and discretionary
post-break identity; a page boundary must not pretend to be a paragraph start.

Tokens into an already composed layout select immutable lines without reshaping.
Recomposition with different following geometry is a separate composition request
with a revision-qualified break checkpoint and full paragraph context; it must
re-evaluate affected candidates, not preserve a locally optimal suffix by fiat.
Stale tokens fail under TL-004. The page host owns widow/orphan, keep, float,
footnote and cross-paragraph/page cost policy.

**TL-034: Page feedback boundary.** A host **must** be able to supply a finite
revisioned sequence of per-line origins/measures, exclusion geometry and fragment
constraints, receive alternative summaries plus anchor positions, and request
recomposition after choosing a page/float placement. Every feedback request names
the previous result and a new geometry revision; exceeding the explicit feedback
limit or failing to reach the host's declared fixed-point criterion returns an
observable nonconverged outcome. Text-layout must not run an unbounded callback
cycle, select pages, or claim global optimality across host page decisions.

**TL-035: Export handoff.** A committed result **must** expose positioned glyph
occurrences and immutable font identities, original-source spans, synthetic
provenance, logical reading order, visual geometry, anchors, object IDs and
orientation/transforms without raster-only handles. An export host must be able to
preserve logical text independently of glyph order and distinguish synthetic
hyphens from source text. PDF serialization, font embedding/subsetting, tagged
structure, colour management and front-end parsing are outside this owner; their
absence must not be advertised as completed publication support.

## 8. Compatibility and acceptance boundary

**TL-036: Clean caller cutover.** A consumer migrated to text-layout **must** use
the committed result for all affected measurement, painting and source interaction,
and remove its competing paragraph, width and hit-test helpers. Migration must
leave no deprecated aliases or fallback code paths that silently reintroduce
Phobos Unicode or renderer-derived geometry. Independent base-only terminal-cell
consumers may remain base-only; they do not need a physical paragraph engine.

The first accepted operation must have executable success, failure and boundary
traces, not only API declarations. Delivery and evidence gates live in the sibling
documents. Draft status is intentional: scope discussion on 2026-10-04 is not an
independent adversarial review or implementation verification.

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
  paragraph API. Cell/terminal sizing remains a distinct consumer contract.
