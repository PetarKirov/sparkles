---
status: draft
owner: sparkles:base
reviewed: 2026-10-05
---

# Wrapping, fitting, and measurable paragraphs

## Abstract

`sparkles:base` supplies source-preserving line wrapping for terminal cells and
pure line-selection algorithms for measured paragraphs. It separates the places
where text can break from the policy that permits a break, the objective (the cost
that ranks one set of line ends against another) that chooses lines, and the
operation that emits those lines. Callers provide geometry, measurement, and storage;
the library preserves source identity and, when a caller's storage or search budget
runs out, reports that failure instead of silently weakening an exact result. The
same solver mechanisms serve cell text and physically measured composition without
importing fonts, a user-interface toolkit, or a publication engine.

## Introduction

A terminal table, a prose widget, and a typeset paragraph all need to choose line
ends, but their measurements and policies differ. Terminal text is measured in
[grid cells](../../../glossary.md#grid-cell): whole-grapheme advances with
column-dependent tabs. Shaped text has contextual advances: measuring pieces
separately need not give the advance of their concatenation, and inserting a
hyphen can change the preceding glyphs. A useful shared library cannot assume
that every width is additive or that a longer candidate is wider.

Line ends also affect more than appearance. Selection, hit testing, copying, and
search need original source boundaries after a space is collapsed, a soft hyphen
is realized, or a continuation indent is inserted. A list of newly allocated
strings loses that distinction. The central representation here is a borrowed
source plus an explicit plan of fragments, omissions, and break alternatives.
Emission consumes that plan; it does not repeat line selection.

This page owns generic wrapping, solver primitives, physical length units, cell
line extents, and source-preserving materialization, which turns a chosen plan into
output bytes or fragments while keeping each one's source span. It also owns the
hyphenation mechanism: discretionary breaks and matching against hyphenation
resources the caller supplies. Language dictionaries, and whether and how a language
is hyphenated, belong to the host. Throughout, "cell" means a
grid cell, the terminal grid advance that base text defines, not the toolkit's
layout unit. The [base text contract](./SPEC.md) owns UTF processing, Unicode
algorithms, grapheme semantics, the named [width profiles](../../../glossary.md#width-profile)
that assign grid-cell advances, and unwrapped fitting and affinities. [Contextual
text composition](../../text-layout/SPEC.md#_5-contextual-composition) owns
semantic rich paragraphs, shaping providers, visual ordering, fragmentation, and
physical paragraph composition. Font resources and shaping belong to the separate
font library; base has no font import. `sparkles:ui` decides wrap policy and calls these
operations. Page construction, frontends, and export belong
above text-layout. These mechanisms are not a claim to replace TeX.

The compact contract precedes operation details. Sections 2–9 define units,
opportunities, plans, measurements, solvers, operations, and hyphenation; §10
specifies how base, UI, and table callers share one plan and width authority, and
§11 the acceptance obligations. All API names
introduced here are **proposed**, not claims that symbols exist in the source tree.
The choices behind this contract are recorded in [decisions](./decisions.md),
delivery order in [the base text plan](./PLAN.md), and scenarios, worked traces,
and evidence in [testing](./testing.md).

## 1. Contract at a glance

1. **WRAP-BOUND1: One owner per layer.** Base **must** own pure generic solvers and
   cell wrapping, with no font or UI dependency; text-layout **must** supply shaped
   measurements and semantic paragraph construction rather than duplicate a solver.
   In `sparkles:ui`, `sparkles.ui.wrap` ([LAY10](../../ui/layout.md#text-wrapping-lay10))
   and `geometry.takeCells` ([LAY14](../../ui/layout.md)) **must** keep only policy
   (wrap or cut, the width, and which width profile) and call base for
   opportunities, measurement, fitting, and line selection.
2. **WRAP-BOUND2: Four independent choices.** Opportunity generation, word and
   emergency policy, solver objective, and materialization **must** be separate
   contracts. A greedy or balanced setting **must not** select a different Unicode
   line-break classifier.
3. **WRAP-SOURCE1: Source identity survives.** Every plan **must** distinguish
   original spans, replaced or omitted spans, and synthetic output; wrapping
   **must not** infer source offsets from emitted byte counts or scalar counts.
4. **WRAP-EXACT1: Exact means complete.** An exact success **must** certify the
   minimum of the declared objective over the declared legal candidate graph.
   Exhaustion, pruning without proof, or approximate measurements **must not** be
   reported as exact success.
5. **WRAP-STATE1: Sufficient path state.** Two paths **must not** be merged merely
   because they end at the same source boundary. Their future-relevant line
   geometry, continuation, fitness, and discretionary state **must** also agree.
6. **WRAP-FAIL1: Transactional planning.** Failure **must** leave the published
   output plan and its storage unchanged. Scratch and explicitly documented
   diagnostic counters **may** change; a failed scratch prefix is not a usable plan.
7. **WRAP-CUT1: Clean caller cutover.** Every consumer **must** reach wrapping and
   cell width through this authority, and competing wrap and width helpers **must**
   be removed; permanent aliases or old code paths are not an acceptance strategy.

## 2. Units and input ownership

### LayoutUnit

This section is the sole owner of the shared physical length contract.

**WRAP-UNIT1: Physical representation.** `LayoutUnit` **must** be a distinct signed
64-bit fixed-point value with one raw tick equal to 1/65536 typographic point and
one point equal to exactly 1/72 inch. Its representable range is the complete
signed-64 raw range; zero is ordinary zero, not an unknown-width sentinel.

**WRAP-UNIT2: Checked physical arithmetic.** Addition, subtraction, accumulation,
rescaling, and conversion **must** detect an unrepresentable result and return
`arithmeticExhausted` without a partial committed result. They **must not** wrap,
saturate, use infinities, or let floating-point roundoff choose a line break.

**WRAP-UNIT5: Rational rescaling and float conversion.** Multiplication or division
by a rational **must** use exact widened intermediates, round once to nearest tick
with ties to even, and report a zero denominator as `invalidInput`. Conversion
from an explicitly supplied finite floating-point physical value **must** use the
same final rounding rule and reject NaN, infinity, and an out-of-range rounded
result.

Exact comparison and cost arithmetic use the unrounded raw values or rational
values specified by the solver, not a rounded ratio stored in a `LayoutUnit`.

**WRAP-UNIT3: Distinct dimensions.** Terminal column counts **must** use a distinct
nonnegative integral grid-cell extent, not `LayoutUnit`. Conversion between grid
cells and physical lengths **must** require an explicit caller-supplied scale and
checked arithmetic; base **must not** assume a font, DPI, monitor scale, or a
physical width of a grid cell.

**WRAP-UNIT6: Device independence.** Font design units and device pixels are
distinct dimensions from `LayoutUnit`, and physical line selection **must not**
depend on rasterization hinting or monitor DPI.

Font adapters convert design advances to `LayoutUnit` at the declared physical
font size. Rasterization converts physical positions to device pixels after
composition. Signed physical kerns are valid; supplied line capacities are
nonnegative.

**WRAP-UNIT4: Aggregate before quantization.** A font measurement adapter **must**
sum design-unit advances, kerns, and positioning adjustments as exact scaled
quantities at its declared measurement boundary before rounding that aggregate
to `LayoutUnit`. Whole-candidate or whole-run measurement **must not** sum
independently rounded glyph advances when that changes the rounded aggregate.

Mixed-font or mixed-scale aggregates retain their exact rational scales until
that final conversion. Individual positioned glyphs **may** have rounded output
coordinates, but those coordinates do not redefine the candidate's measured
advance or choose a different break.

### Borrowed snapshots

A _source snapshot_ is an immutable logical text view identified by the caller's
source identity and revision. A view may consist of contiguous bytes or immutable
spans; span boundaries are not text boundaries. A _source boundary_ is a validated
byte boundary in that logical view. Plans identify source boundaries and span
ranges, never addresses as persistent identities.

**WRAP-OWN1: Borrow lifetime.** The source, explicit replacement text, geometry,
measurement resources, and external style snapshots **must** remain immutable and
alive throughout planning and while a plan borrows them. Published metadata
**must** reside in caller-owned plan storage whose reuse invalidates the plan.
Scratch **may** be released after successful publication only if no published span
points into it.

**WRAP-OWN2: Complete snapshot input.** The cell operation **must** accept a
complete immutable source snapshot, and chunked sources **must** be represented as
one logical view, so a UTF sequence, escape, CRLF, or grapheme may cross chunks.
An adapter that collects a stream **must** label that allocation and borrow
lifetime.

The cell operation is not a streaming partial-input API; an unfinished final UTF
sequence or escape follows the selected core error policy.

## 3. Break opportunities and policy

An _opportunity_ names a source boundary, its origin, its legal alternatives, and
whether breaking there is allowed, forbidden, or mandatory. The origin is one of
Unicode line break, explicit author break, explicit discretionary, hyphenation,
or emergency. It is a reason, not a solver score.

**WRAP-OPP1: Unicode opportunities.** The default cell opportunity generator
**must** use the full default UAX #14 algorithm from the single Unicode release
and algorithm revisions owned by [base text](./SPEC.md#_4-segmentation-and-unicode-algorithms),
then intersect allowed opportunities with complete extended-grapheme boundaries.
It **must not** substitute ASCII spaces, ideographs, or word segmentation for
that algorithm. Mandatory separators **must** remain mandatory.

**WRAP-OPP2: Boundary invariance.** Formatting tokens and view-span boundaries
**must not** create a text boundary. A mandatory CRLF pair **must** be one break
consuming both source bytes; LF, CR, NEL, LS, and PS follow the core line-break
classification. A mandatory break terminates the candidate graph even when a
longer line would fit.

**WRAP-OPP3: Paragraph endpoints.** In the cell operation, each mandatory separator
**must** end a logical paragraph and reset first-line geometry, indent, and solver
adjacency state, while the logical source style continues through the break under
the selected continuity mode. The generic primitive interface **must** instead
distinguish a forced line endpoint from an explicit paragraph endpoint.

_Rationale:_ The distinction lets text-layout preserve within-paragraph fitness and
geometry across an authored hard line break.

**WRAP-OPP4: Word segmentation as a filter.** UAX #29 word segmentation is an
available policy input, not the definition of a line opportunity. A
word-preserving policy **may** prohibit optional opportunities but **must not**
erase a mandatory break or invent a break inside a cluster.

A caller that requests a word-preserving policy identifies its word-tailoring
policy and no-break spans.

**WRAP-POL1: Explicit policy.** The cell operation **must** expose `unicode` and
`wordPreserving` opportunity filters, `preserve` and `collapse` whitespace
transforms, and one of `reject`, `overflowUnit`, or `graphemeEmergency` for an
unbreakable unit that cannot fit on an otherwise empty content line. Defaults are
`unicode`, `preserve`, and `graphemeEmergency`; the choice is recorded in the plan.
No no-wrap convention is overloaded onto width zero.

**WRAP-POL4: Whitespace transforms.** `collapse` **must** replace maximal runs of
U+0020 and horizontal tab with one synthetic U+0020 between content, and omit such
a run at a chosen line start or end; it **must not** collapse NBSP, other Unicode
spaces, or mandatory separators. `preserve` **must** retain horizontal whitespace
on its authored side of a chosen opportunity, so a break after a space does not
silently trim it.

Explicit replacement and omission records carry the consumed source ranges in
either mode. Terminal tabs are processed after the whitespace transform.

**WRAP-POL2: Emergency precedence.** Emergency breaks **must** be admitted only
inside a maximal policy-unbreakable unit whose complete measurement exceeds its
empty-line capacity for the relevant geometry and continuation. They **must**
respect cluster boundaries and explicit no-break ranges; they **must not** override
NBSP, WJ, or an author no-break range unless a separate explicit policy permits
that protected range. The cell operation **must not** permit that override.

**WRAP-POL5: Overwide-unit outcomes.** Under `reject`, the operation **must** return
`unbreakableOverflow` with the offending source range. Under `overflowUnit`, the
smallest policy-unbreakable unit **must** be placed whole on an otherwise empty
content line, marked `overfull`, and **must not** swallow adjacent units to reduce
line count. Under `graphemeEmergency`, the legal graph **must** include interior
whole-cluster boundaries of an eligible overwide unit.

Under `graphemeEmergency`, a cluster wider than the empty-line capacity is emitted
alone, marked `overfull`, and a protected no-break unit remains whole and overfull.
The solvers compare overfull and emergency choices using the precedence in
section 7, not a hidden large penalty constant.

**WRAP-POL3: Progress and empty lines.** A soft break **must** advance source
consumption or consume a nonempty discretionary replacement range; it **must not**
create a line containing only a continuation indent. Empty input **must** produce
one empty content line, and mandatory breaks **must** preserve empty lines,
including the final empty line after a trailing mandatory separator.

**WRAP-POL6: Width setting.** The width setting **must** be `bounded(cellCount)` or
`unbounded`. Bounded zero is a real zero capacity: zero-width content **may** fit,
and nonzero indivisible content follows the declared overflow policy. Unbounded
suppresses optional wrapping but **must** retain mandatory breaks and requested
whitespace and style transformations.

## 4. Plans, cell geometry, and fitting

### WrapPlan

A _fragment_ is an ordered piece of line content. It is a borrowed source span, a
borrowed replacement or synthetic span, a tab expansion, or a style action.
An _omission_ records consumed source absent from the output. A _break alternative_
records a stable caller- or generator-assigned ID, the boundary or replacement
range, and its unbroken, pre-break, and post-break fragments. Chosen pre-break
fragments end the preceding line; post-break fragments start the next line.

**WRAP-PLAN1: Plan contents.** A successful `WrapPlan` **must** expose, in logical
line order: fragments, omissions, selected opportunity/alternative IDs, consumed
source ranges, line geometry, measured advance, overfull status, style snapshots,
and line/source mappings. It **must** record source revision, the Unicode and
width-profile identity for cell text, solver and policy options, and the proof
class `localGreedy`, `completeExact`, or `completeApproximate`. Only
`completeExact` certifies a global objective minimum. A plan **must not** imply that
unselected alternatives were copied into output.

**WRAP-PLAN3: Provenance records.** Each source byte **must** belong to exactly one
consumed source record: emitted original, replacement provenance, omitted
transform, or mandatory separator. A source span **must not** have several output
spans unless the explicit provenance relation says so, and **must not** be
duplicated by guessing a source offset. Duplicate alternative IDs in one snapshot
are invalid.

Synthetic indentation, hyphens, resets, link actions, and newlines have explicit
anchor boundaries and reasons, not invented source byte ranges. A discretionary
owns its replacement range; taking it substitutes pre/post for unbroken content,
rather than emitting all three. Alternatives at an identical boundary are
distinct IDs.

**WRAP-PLAN2: Source reconstruction.** Copy-original traversal **must** recover
the exact source bytes in authored order, including whitespace, discretionary
markers, and mandatory separators, from the source records without copying
synthetic formatting. Copy-rendered traversal **must** follow the chosen
fragments and declared newline/indent transform. These are separate operations;
selection policy above base chooses which the UI offers.

A plan is a logical layout, not a bidi visual layout. Shaped visual maps and
bidirectional cursor positions belong to text-layout. A caller-supplied contextual
candidate result may carry borrowed opaque visual-map handles; base preserves
those handles but does not interpret glyphs or reorder them.

### Cell tabs and line extents

**WRAP-CELL1: Whole-line measurement.** Each cell line **must** be measured from
its declared starting column after its indent, using the selected width profile,
the chosen discretionary, and the declared tab stops. The plan **must** retain
`startColumn`, `indentExtent`, `contentAdvance`, `endColumn`, and `capacity`
separately. The line extent is advance, not an ink bounding box.

**WRAP-CELL4: The width profile is the only cell measure.** Every grid-cell advance
in cell wrapping **must** come from the width profile selected for the operation
([TXT-CELL1–3](./SPEC.md#_6-1-width-profiles-and-whole-cluster-fitting)), whether
`terminalKitty` or `terminalUnclustered`, whose advances are identical
([TXT-CELL5](./SPEC.md#_6-1-width-profiles-and-whole-cluster-fitting)); wrapping
**must not** apply a width rule of its own. Wrapping honours the
[glyph-channel](../../../glossary.md#glyph-channel) exemption through the width
profile, which measures those scalars as one grid cell under every width profile
([TXT-CELL7](./SPEC.md#_6-1-width-profiles-and-whole-cluster-fitting)), not through a
separate exemption. Scaled cell footprints reach wrapping the same way, as
width-profile advances at a run's scale
([TXT-SIZE1](./SPEC.md#_6-4-scaled-grid-cell-footprints)), not as a scale wrapping
applies.

**WRAP-CELL2: Indents.** First-line and continuation indents **must** be borrowed
styled text or prevalidated fragment lists with no mandatory separator, tab,
nontext terminal operation, or discretionary. Their full cluster advance **must**
count against line capacity. An indent **may** exceed a bounded capacity; the
overflow policy then applies to content without producing repeated empty indented
lines.

**WRAP-CELL3: Geometry selection.** Geometry **must** be selected by paragraph-local
line index, and a mandatory paragraph separator resets that index. An explicit
geometry array **must** either cover every needed line or declare a repeat
last-entry rule; missing geometry is `geometryExhausted`, not inferred width.

**WRAP-TAB1: Column-dependent tabs.** The tab policy **must** be either preserve
or expand. A periodic stop interval is a positive cell count; the next stop from
absolute column `c` is `c + (interval - c % interval)`, including when `c` is
already a stop. Explicit stops are strictly increasing nonnegative columns and
require an explicit periodic tail or `noNextTabStop` failure.

**WRAP-TAB2: Tab emission and mapping.** A preserved tab **must** emit its authored
byte and record the measured advance; an expanded tab **must** emit that many spaces
with provenance to the tab's one-byte range. Line indents **must** affect the next
stop, a wrap **must** recompute it for the next line, and source chunks or style
spans **must not** reset the column.

Overflow in column or stop arithmetic returns `arithmeticExhausted`. A tab's
output cells map to that source unit's before/after boundary using affinity, not
to fabricated repeated bytes.

### Borrowed fitting and wrapped affinities

**WRAP-FIT1: Reuse core fitting.** Prefix and suffix fitting on ordinary cell text
**must** use the whole-cluster and malformed-input policy of [core fitting and
coordinates](./SPEC.md#_6-cell-text-and-coordinates). Proposed `fitPrefix` and
`fitSuffix` return borrowed ranges and measured extents, not silently allocated
strings; wrapping **must not** introduce another segmentation or width model.

**WRAP-FIT2: Line-aware fitting and truncation.** The line-aware variant
additionally takes an initial column and tab policy, and **must** measure a suffix
as it appears from that starting column, not by subtracting a width from a
previously measured prefix. Truncation **must** reserve the exact measured
ellipsis or replacement extent before fitting, and return `replacementDoesNotFit`
when the replacement itself cannot fit, not a split ellipsis or negative budget.

Line-aware fitting may require enumeration when tabs or a provider are
nonmonotone.

**WRAP-MAP1: Boundary affinity.** Wrapped cell-to-source and source-to-line queries
**must** retain the core `before`/`after` boundary affinities. At a soft-wrap
boundary that appears on two lines, `before` chooses the preceding line's end and
`after` the following line's start. An interior cell of a wide cluster maps only
to that whole cluster's boundary pair, never an interior UTF byte or scalar.

**WRAP-MAP2: Transformed and synthetic mappings.** Synthetic indent and pre-break
hyphen cells **must** map to their explicit anchor with the requested affinity,
and post-break replacements to their own provenance anchor. Each mapping result
**must** state whether it is exact original, transformed, or synthetic, and base
**must not** promise a byte-exact inverse for an intentionally many-to-one
transform.

Collapsed whitespace exposes its complete consumed source range; omitted ranges
map to the adjacent retained boundary with affinity. ANSI and style-only spans
share the enclosing text boundary and have zero advance.

## 5. Measurable primitives

These are solver inputs, not a second semantic paragraph model. A text-layout
paragraph retains text, style, bidi level, language, font choices, and source
identity, then projects measurable inputs into this contract.

**WRAP-PRIM1: Primitive algebra.** The generic solver **must** accept boxes, glue,
kerns, penalties, discretionaries, and zero-advance anchors with stable IDs and
source provenance. Units **must** be uniform within a solve: all physical
`LayoutUnit`, or all integral cells; mixed-dimensional input is `invalidInput`.

- A **box** is indivisible measured content with a nonnegative advance and a
  provider-defined payload. It has no implicit break or implicit whitespace.
- **Glue** has a nonnegative natural advance and nonnegative finite stretch and
  shrink coefficients; shrink **must not** exceed natural advance. One stretch
  coefficient is the change at ratio 1, not an infinite or hard maximum. The
  solve's finite stretch tolerance supplies the maximum realizable stretch.
  Its explicit break alternative declares retained and discarded edge glue;
  the solver does not infer discardability from adjacency.
- A **kern** is a signed fixed advance. It creates no opportunity. A negative
  kern may make a longer candidate narrower.
- A **penalty** is a zero-advance optional, forbidden, or forced opportunity plus
  an integral penalty in [-10000, 10000] when optional, and a flagged-discretionary
  bit. Force and forbid are tags, not arithmetic sentinels. Visible break material
  is supplied through an associated alternative, not an implicit hyphen width.
- A **discretionary** replaces a declared consumed source or primitive range with
  pre-break and post-break sequences when taken, or an unbroken sequence when not
  taken. Each sequence **may** contain boxes, glue, kerns, and anchors, but not another
  opportunity or recursively nested discretionary. It declares its penalty,
  flagged bit, stable alternative ID, and next-line continuation identity.
- An **anchor** carries a source position or external marker with zero advance and
  no break. It survives transformation in an explicitly declared order.

**WRAP-PRIM2: Validation.** Primitives **must** have a finite acyclic logical order,
nonoverlapping owned replacement ranges, valid source boundaries, and unique IDs.
Negative glue capacities, mixed units, out-of-order mandatory breaks, recursive
alternatives, and ambiguous overlapping replacement ranges **must** return
`invalidInput` before publication. A paragraph with no legal full path returns
`noFeasiblePlan`; the solver **must not** insert an undeclared opportunity.

**WRAP-PRIM3: Continuations and zero-consumption progress.** Continuation identity
**must** be explicit, and equal identities **must** mean equivalent future behavior
for the snapshot. Empty replacement ranges **must** be allowed only when they
advance the primitive or opportunity ordinal, and **must not** permit a cycle or an
unbounded number of zero-consumption lines.

A continuation is a finite immutable pending post-break fragment sequence plus
provider-defined state needed to measure the next candidate. Anchors at equal
source boundaries preserve authored ordinal order.

## 6. Measurement providers

A _candidate_ specifies its start state, endpoint alternative, line index,
geometry ID and capacity, pending post-break material, selected internal unbroken
alternatives, and whitespace/tab transform. Its measurement is for the exact
emitted content of that line, not for a substring approximation.

**WRAP-MEASURE1: Candidate result.** The measurement callback **must** return either
an explicit failure or a deterministic result containing natural advance,
stretch and shrink coefficients and individual realizability bounds, validated
break safety, and a borrowed or stored candidate-materialization descriptor.
Ink bounds **may** be supplementary; they **must not** replace advance in the
objective. Results **must** be stable for the same complete candidate key and
immutable resource snapshot.

**WRAP-MEASURE2: Capability declarations.** A provider **must** declare separately
whether advances are additive across the solver's boundaries, monotone under
candidate extension, and exact for final materialization. Absence of a declaration
means no such capability. Shaping, tabs, and negative kerns **must not** inherit
additivity or monotonicity by default.

| Declared capability                                     | Permitted optimization                                      | Obligation                                                                        |
| ------------------------------------------------------- | ----------------------------------------------------------- | --------------------------------------------------------------------------------- |
| Additive advance and glue coefficients                  | Prefix sums over exactly those declared boundary contexts   | Sum equals whole-candidate result, including edges and continuation               |
| Monotone extension for a fixed start state and geometry | Stop extending after an irrevocable over-capacity candidate | Proof also covers the declared overflow/adjustment feasibility test               |
| Exact final measurement                                 | Use measurement in an exact solver and emit its descriptor  | Materialized advance equals the candidate result                                  |
| Approximate estimate only                               | Order exploration in explicitly approximate mode            | Exact success remains unavailable until every used candidate is validated exactly |

**WRAP-MEASURE5: Capability independence and cache keys.** A declared capability
**must not** be taken to imply another. Measurement cache keys **must** include the
complete candidate key, source and resource revision, and measurement options, and
a result **must not** be reused across line geometry, pre/post alternative,
language, or shaping context.

Additive signed kerns can be nonmonotone, and monotone shaping can be nonadditive.
Providers own the truth of their declarations; acceptance includes a
provider-adapter capability audit and counterexamples, not only solver tests.

**WRAP-MEASURE3: Shaping safety.** A shaped provider **must** validate candidate
boundaries using its shaping-safe-break information and reshape contextual edges
or the whole candidate as needed. An unsafe break **must** be rejected or measured
through a safe contextual reshape; it **must not** be emitted by splitting a glyph
run at a byte offset. Its next-state identity **must** include any context
influencing future candidates.

**WRAP-MEASURE4: Callback failure.** Measurement, geometry, resource, or style
callback failure **must** abort planning with its phase, candidate/line identity,
and caller error code, leaving the published plan and output storage unchanged.
Base **must not** skip a failed candidate, retry callbacks implicitly, or return a
partial plan as success.

**WRAP-MEASURE6: Callback discipline.** Callbacks **must** be synchronous and
**must not** reenter the same workspace. A callback **may** update instrumentation
but **must not** mutate source or resource snapshots, published output, or any
externally committed output during planning. Cancellation is an explicit callback
result with the same uncommitted-plan behavior.

_Rationale:_ Base cannot roll back external callback side effects, so the callback
contract forbids them. Callback-owned memory or resource failure is translated by
the callback, not mislabeled as solver scratch exhaustion.

## 7. Solvers

All solver modes traverse the same legal candidate graph. An edge consumes one
line and ends at an optional or mandatory opportunity. No edge crosses a
mandatory opportunity. The terminal edge completes the paragraph, including its
empty-line convention. Exact algorithms do not promise TeX's token language,
macro expansion, page builder, or implementation-specific demerit policies.

### Common feasibility and tie order

**WRAP-SOLVE1: Policy precedence.** A complete balanced or Knuth–Plass path
**must** minimize, lexicographically: (1) number of policy-permitted overfull lines,
(2) sum of their positive overflow in raw units, (3) number of emergency breaks,
then (4) the mode's objective below.

_Rationale:_ The precedence prevents a numerical penalty shortcut from making
illegal overflow preferable to feasible ordinary lines.

**WRAP-SOLVE2: Overfull edges and weights.** A legal overfull edge **must** contain
only the permitted indivisible unit and its mandatory pending and indent material.
Emergency origin **must** be counted even when its numeric penalty is zero.
Optional opportunities explicitly forbidden by policy are absent, not expensive.
Solver weights **must** be nonnegative integers, except an optional penalty's
signed value; invalid weights are `invalidInput`.

**WRAP-TIE1: Deterministic ties.** For equal complete objective tuples, balanced
and Knuth–Plass **must** prefer fewer lines, then the lexicographically later
sequence of consumed source-end boundaries, then the lexicographically smaller
sequence of alternative IDs, then authored opportunity ordinals. Boundary order
is logical source order, not pointer order. Greedy uses its separately defined
local order. Arithmetic overflow **must not** turn a cost into a tie or infinity.

### Greedy

**WRAP-GREEDY1: Local choice.** Greedy **must** choose the furthest fitting legal
ordinary endpoint for the current complete state, without crossing a mandatory
endpoint. If none fits, it **must** use the configured overwide-unit policy; when
eligible emergency endpoints fit, it chooses the furthest fitting one. Equal
endpoints prefer the smaller alternative ID and then authored ordinal.

**WRAP-GREEDY2: Nonmonotone scanning and dead ends.** For a nonmonotone provider,
greedy **must** examine every legal endpoint up to the next mandatory boundary,
because a failed shorter candidate does not prove a longer one fails; under a
declared proof of monotone feasibility it **may** stop earlier. If its locally
selected continuation leads to a dead end, it **must** return `noFeasiblePlan` and
**must not** silently backtrack and keep the greedy label.

Greedy reports `localGreedy`, not global optimality or an approximation to a
specific Knuth–Plass minimum.

### Balanced

**WRAP-BAL1: Raggedness objective.** Balanced **must** minimize the sum of squared
nonnegative trailing slack for every nonterminal line of each paragraph; the
terminal line contributes zero. Slack is `max(0, capacity - naturalAdvance)` after
indent, explicit transforms, and the selected break material. Glue remains at its
natural width; balanced is ragged-right, not justified Knuth–Plass.

**WRAP-BAL2: Balanced feasibility and arithmetic.** An ordinary under-capacity edge
is feasible regardless of glue, and an over-capacity edge **must** require the
explicit common overflow policy. Costs **must** use exact raw-unit integer squares
and checked unsigned-128 accumulation; an unrepresentable accumulated cost returns
`arithmeticExhausted` and **must not** be capped to hide a lost ordering.

The common policy tuple and tie order apply first. Balanced with variable line
geometries needs line index and state in its dynamic program; one cost per source
endpoint is insufficient.

### Exact Knuth–Plass

**WRAP-KP1: Adjustment ratio.** Exact Knuth–Plass **must** evaluate natural
advance `N`, target content capacity `T`, total stretch coefficient `S`, and total
shrink coefficient `H` from the exact candidate. The rational adjustment ratio
is `(T-N)/S` when `N < T`, `(T-N)/H` when `N > T`, and zero when equal. A zero
applicable coefficient makes that nonzero adjustment infeasible; shrink ratio
below -1 or stretch ratio above the explicit finite nonnegative rational
tolerance is infeasible.

**WRAP-KP4: Terminal lines, badness, and fitness.** The terminal-line option
**must** be explicit: `ragged` accepts `N <= T` with ratio and badness zero, whereas
`justified` uses the same ratio rule as other lines. A permitted overfull
indivisible edge bypasses ratio feasibility with badness 10000 and ratio category
`tight`; it still loses to any path with fewer overfull lines. Every other
feasible edge **must** have badness `b = min(10000, ceil(100 * abs(r)^3))`,
evaluated exactly as a rational.

Fitness is `tight` for `r < -1/2`, `decent` for `-1/2 <= r <= 1/2`, `loose` for
`1/2 < r <= 1`, and `veryLoose` for `r > 1`.

**WRAP-KP2: Demerit objective.** For each feasible line the demerit **must** be
`(linePenalty + b)^2`, plus `p^2` for an optional nonnegative penalty `p`, minus
`p^2` for an optional negative penalty, and zero penalty contribution for a forced
endpoint. Add `fitnessDemerit` when successive fitness categories differ by more
than one; add `consecutiveDiscretionaryDemerit` when both successive endpoints are
flagged; add `terminalDiscretionaryDemerit` when the immediately preceding endpoint
is flagged and this line terminates the paragraph.

**WRAP-KP5: Objective arithmetic.** The objective **must** be the checked signed-128
sum of line demerits, after the common policy tuple, and intermediate rational
arithmetic **must** be exact and checked; an unrepresentable intermediate is
`arithmeticExhausted`, not a rounded decision. Tolerance, the nonnegative
`linePenalty`, and the three adjacency and terminal demerit weights **must** be
caller input recorded in the plan, with no hidden TeX-compatibility constants.

There is no fitness or consecutive comparison on the first line. Paragraph-local
fitness and previous-flag state reset at a paragraph boundary. Negative penalty
contributions are allowed because the candidate graph is acyclic.

**WRAP-KP3: Glue materialization.** A successful exact plan **must** retain its
exact adjustment ratio and allocation of adjusted glue widths. Each glue's
ideal advance is `natural + r * stretch` for nonnegative `r`, or
`natural + r * shrink` for negative `r`. Its realizable raw-unit interval **must**
be the intersection of `[natural - shrink, floor(natural + tolerance * stretch)]`
with its provider-supplied individual bounds from `WRAP-MEASURE1`. Supplied bounds
**must** be finite, nonnegative, ordered and contain the natural advance; malformed
bounds are an invalid provider result, not a silently ignored constraint.

**WRAP-KP6: Rounding and residual allocation.** For physical fixed-point output,
each ideal advance **must** be rounded to nearest tick with ties to even and
clamped to its realizable interval. The signed residual between the target and the
rounded total **must** be distributed as a logical round-robin, one tick per
eligible glue in logical order, without leaving any interval. An implementation
**must** batch that allocation and **must not** iterate once per residual tick.

The batched allocation proceeds as follows. Let `c[i]` be each glue's remaining
capacity in the residual direction and `F(q) = sum(min(c[i], q))`. Reject an
absolute residual exceeding total capacity. Choose the largest `q` in
`[0, max(c)]` with `F(q)` no greater than the absolute residual, apply
`min(c[i], q)` ticks to each glue, then apply one tick to the first remaining
eligible glues for the remainder. Fixed-width binary search requires at most 64
scans of the glue records; the final pass is linear. Capacities, sums, and
residuals use checked widened arithmetic.

_Rationale:_ Batching preserves the round-robin result with work independent of
physical width magnitude.

**WRAP-KP7: Exact target realization.** A justified feasible line **must** end at its
exact target in raw ticks, and a candidate whose intersected intervals cannot
realize that target **must** be infeasible, even when its aggregate adjustment
ratio passes `WRAP-KP1`. Neither rounding nor residual allocation **may** exceed an
individual bound.

For natural 1, stretch 4, shrink 0, provider maximum 2, tolerance 1 and target 4,
the ratio 3/4 is not sufficient: that single-glue candidate is infeasible, not a
width-4 realization.

**WRAP-KP8: Natural-width lines.** Cell inputs **must** use the same realization
rule in integral cells. Ragged terminal lines and policy-permitted overfull lines
**must** keep natural glue widths, and adjustment **must not** modify box or kern
advances. Realization is part of candidate feasibility, not a later undocumented
repair of the solver's chosen line.

### State, approximation, and bounded work

**WRAP-DP1: Exact state equivalence.** The dynamic-programming key **must** include
source/primitive endpoint and selected continuation identity, paragraph-local
line index and geometry state, prior fitness category, prior flagged-discretionary
state, and any provider state that affects future candidates. Prior discretionary
identity and pending post-break fragments **must** remain distinguishable when
they change a successor's measurement or penalty. States **may** merge only under a
proved future-equivalence relation, with the common objective and tie order
preserved.

**WRAP-DP2: Geometry history.** A geometry callback that depends on history **must**
supply a finite explicit geometry state and deterministic transition; a callback
that depends on undeclared global history is incompatible with exact solving.
Candidate measurements **must** distinguish ending discretionary alternatives as
well as starting continuations.

Forced breaks alone are not proof that all prior state can be discarded.

**WRAP-DP3: Projected branch identity.** When an alternative changes analysis
beyond its adjacent lines, provider state **must** distinguish the complete
projected branch and analysis identity. Reusing an unbroken paragraph's contextual
analysis for another projected branch without an equivalence proof **must not**
produce exact success.

Enumerating finite whole-paragraph branch contexts before line selection is
permitted and charged to the same budgets. Text-layout owns that analysis.
Whether its finite provider-state representation is feasible remains a
contextual-provider acceptance gate, not a reason for base to suppress valid
alternatives or add a competing analyzer.

**WRAP-BUDGET1: Caller-owned workspace.** Planning **must** allocate no hidden
heap storage. It **must** use disjoint caller-provided scratch and output metadata
storage and expose limits for source bytes, input primitive/fragment records,
opportunities/alternatives, admitted states, transitions examined, measurement
calls, provider work units, and output fragments/style snapshots. Each limit is
a nonnegative explicit count; arithmetic for deriving storage or counts is checked.

**WRAP-BUDGET3: Budget charging.** Each admitted state and examined transition
**must** consume one budget unit, each measurement callback one measurement unit,
and each provider result its declared work units. Providers **must** enforce a
pre-call remaining-work grant before performing expensive work. Source and token
scanning **must** charge consumed bytes and emitted boundary records, not a fixed
per-grapheme scalar limit.

_Rationale:_ Reporting overspend afterwards cannot establish a work bound.
Unlimited-length grapheme semantics use finite segmentation state and borrowed
source spans, never a 16/32-scalar cap.

**WRAP-BUDGET2: Exhaustion outcomes.** Exact mode **must** return
`budgetExhausted(kind, used, limit)` or `needScratch(kind, minimumAdditional)` when
it cannot complete, with no published partial plan. A caller can retry with larger
workspace/limits against the same immutable inputs; restarting does not imply a
persistent hidden search. `minimumAdditional` is a proven lower bound, not a
claimed exact total if exploration has not determined it.

**WRAP-BUDGET4: Explicit approximation.** Approximate mode **must** be explicitly
requested and **must** declare its approximation algorithm and parameters before
entry. It returns `completeApproximate` with objective, consumed budgets, pruning
reason, and `optimalityNotProven`, or an exhaustion failure if it has no complete
plan. A lower bound or optimality gap **must** be exposed only when proved, and a
solve **must not** switch from exact to approximate internally.

Approximate mode may use an incumbent complete plan, beam pruning, or bounded
candidate exploration. The cell operation defaults to local greedy; choosing
balanced means exact balanced unless the caller explicitly opts into
approximation.

**WRAP-WORK1: Work model.** For `B` source bytes, `P` logical primitives and
alternative-fragment records, `A` legal endpoint alternatives, `V` admitted
complete states, and `E` examined edges, engine work excluding provider work
**must** be bounded by
`O(B + P + A + (V + E) * (P + A + log(V + 1)) + output records)`.
This conservative bound includes assembling candidate descriptions, walking
predecessor paths for tie comparison, and ordered state lookup; an implementation
**may** establish tighter bounds for declared capabilities.

**WRAP-WORK2: Stored metadata.** Stored engine metadata **must** be
`O(V + P + A + output records)` plus one bounded candidate workspace. Candidate
continuations **must** borrow immutable records rather than copying full source text
or predecessor paths into every state. Caching every measured edge is optional
caller storage charged separately.

A straightforward rigid constant-geometry balanced graph has `O(A^2)` edges and
`O(A)` endpoint states only if future-equivalence removes the line index. Variable
geometry, fitness, and post-break state invalidate that simplification. General
exact solving can have many states and relies on declared budgets rather than a
universal linear or quadratic bound. Nonmonotone greedy can examine `O(A^2)`
candidates across lines; a proven monotone provider permits a linear endpoint
scan. Providers publish their own per-candidate work bounds and charge
borrowed-source scans; base does not conceal whole-paragraph shaping inside an
`O(1)` measurement label.

### Constrained and alternative solutions

**WRAP-ALT1: Ranked alternatives.** The generic solver **must** support an explicit
paragraph-local line-count constraint and a finite caller-ordered set of geometry
alternatives. A proposed `trySolveWrapAlternatives` **must** return complete legal
plans in nondecreasing common objective/mode cost order, applying `WRAP-TIE1`
and then the geometry-alternative ordinal. A path's identity includes its selected
opportunities/alternatives and geometry identity; equal cost does not justify
discarding a distinct path.

**WRAP-ALT2: Result completeness.** A request **must** declare an inclusive positive
line-count range and a positive maximum result count `K`. Exact `topK` success
**must** certify the first `min(K, available)` ranked paths and report `exhaustive`
or `moreAlternatives`. A request for exhaustive enumeration **must** fail with
`needResults` if every legal constrained path cannot fit its result storage, rather
than publish a silently truncated list.

When no feasible constrained path exists, the operation returns a successful
exhaustive empty result, distinguishable from `budgetExhausted`. Each result has
the same source/borrow and materialization contracts as a single plan, and
failure leaves the previously published list unchanged.

**WRAP-ALT3: Ranked search state.** Ranked search **must** preserve the multiple
prefix labels needed for distinct complete solutions, not only the cheapest
prefix, and those labels **must** consume the admitted-state budget. Approximate
enumeration **must** be opt-in and report `rankingNotProven` and
`completenessNotProven`; exact budget exhaustion **must not** become an approximate
list automatically.

Equivalent future states may share structural data. All transitions,
measurements, result records, and proof work consume the declared budgets.
Text-layout owns contextual summaries and publication's choice among these
paragraphs; it **must not** create a second generic line solver.

## 8. Operations and materialization

The following signatures are conceptual **proposed API contracts**, not runnable
D declarations. Storage layouts and names may be refined before implementation,
but an accepted change to their externally observable outcomes requires updating
this contract and its acceptance scenarios together.

```text
tryWrapCells(sourceSnapshot, cellOptions, scratch, planStorage, ref outPlan)
    -> PlanResult
trySolveWrap(measurableInput, geometry, provider, solverOptions, limits,
             scratch, planStorage, ref outPlan)
    -> PlanResult
trySolveWrapAlternatives(measurableInput, geometryAlternatives, provider,
                         solverOptions, lineCountRange, resultLimit, limits,
                         scratch, resultStorage, ref outPlans)
    -> AlternativeResult
tryMaterializeWrap(plan, emissionOptions, scratch, outputBytes, ref outExtent)
    -> MaterializeResult
```

**WRAP-API1: Cell plan operation.** `tryWrapCells` **must** validate the complete
source/options, generate or validate opportunities and transforms, measure whole
cell candidates, select lines, and publish a complete plan only after every
selected fragment and source mapping is valid. It **must** support complete
borrowed UTF-8 views, bounded and unbounded widths, mandatory breaks, both
whitespace modes, tabs, first and continuation indents, the local greedy solver,
explicit overflow policy, and ANSI formatting continuity.

**WRAP-API9: Cell solver modes.** `tryWrapCells` **must** offer balanced and generic
Knuth–Plass solver modes under the same operation contracts as greedy. A build
that does not provide a requested mode **must** return `unsupportedCapability`
rather than substitute another mode.

**WRAP-API4: Malformed-input mode.** The malformed-input mode **must** be an
explicit core mode: strict, Unicode replacement by maximal subpart, or opaque-byte
analysis. Replacement records **must** retain original malformed spans. In opaque
mode an invalid byte is the core opaque unit and **must not** be silently fed into
a Unicode scalar classifier.

The core contract determines segmentation and width classification of malformed
input; wrapping supplies no competing decoder.

**WRAP-API2: Generic solve operation.** `trySolveWrap` **must** validate the
primitive graph, geometry, capabilities, exactness request, weights, budgets, and
workspace aliasing; then solve the declared graph and publish its selected
candidate descriptors. Exact mode with an estimate-only provider returns
`exactMeasurementRequired`, not exact success with an estimated objective.

**WRAP-API5: Validation and structured errors.** Output plan storage **must not**
alias source, scratch, provider snapshots, or the storage of the previously
published `outPlan`. Unsupported options, invalid source boundaries, duplicate IDs,
and incompatible capabilities **must** return `invalidInput` or
`unsupportedCapability` before publication. Hostile external bytes, sizes, escape
sequences, and resource formats **must not** become assertion failures.

Programmer lifetime violations remain caller obligations. Structured errors
contain phase, source range or candidate ID where meaningful, and budget kind or
caller code; diagnostics do not retain or log source text by default.

**WRAP-API3: Materialization operation.** `tryMaterializeWrap` **must** emit exactly
the selected plan into a bounded caller byte slice, without invoking the solver or
measurement callbacks again. It **must** reject a source/resource revision mismatch
as `stalePlan`, calculate the complete byte requirement with checked arithmetic,
and return `needOutput(requiredBytes)` without modifying output or `outExtent`
when capacity is insufficient.

**WRAP-API6: Emitted separators.** For cell plans, `emissionOptions` **must** select
LF or CRLF between planned lines, default to LF, and add no newline after the
final planned line. Indent and style transforms are stored in the plan, and
emission **must not** change them in a way that invalidates its geometry; such a
change requires replanning.

Original mandatory separators remain in the source ledger; rendered-copy uses the
chosen emitted separator. A final empty planned line after a mandatory separator
therefore preserves its trailing newline.

**WRAP-API7: Staged materialization.** Materialization **must** stage fallible
style and candidate encoding in caller scratch before committing bytes, or consume
prevalidated immutable emission descriptors. Any encoding callback failure,
`needScratch`, or arithmetic failure **must** leave output and `outExtent`
unchanged. On success, only `outputBytes[0..outExtent]` is written and unused
capacity remains unchanged. The bounded materializer **must** reject overlapping
source and output.

An in-place algorithm would be a separate, explicitly specified operation. Plain
borrowed lines need not be copied merely to expose them.

**WRAP-API8: Streaming adapters.** A writer adapter over a fallible external sink
**must** report the exact accepted prefix and **must not** masquerade as the
all-or-none bounded operation. A convenience owned-string API **may** allocate once
using the complete byte requirement, and **must** delegate line selection and
mappings rather than introduce another engine.

A writer adapter calls the bounded materializer for one prepared line and then
writes it. Its sink is not transactional and does not rewind a file, terminal, or
network connection.

### ANSI and styling state

**WRAP-ANSI1: Formatting transparency.** Supported SGR and OSC 8 hyperlink tokens
**must** be zero-width formatting over one logical scalar/grapheme stream, including
when a token lies between a base and combining mark, between regional indicators,
or inside a ZWJ sequence. They **must not** force a cluster or break opportunity.
Unknown SGR parameters **may** remain opaque formatting payload only under an
explicit parser policy whose state-restoration limitations are reported.

**WRAP-ANSI2: Nontext operations.** Cursor motion, erase commands, terminal mode
changes, device queries, images, and other nontext VT operations **must** return
`nonTextTerminalOperation` with source range, or be delegated by an explicit
caller adapter outside this text operation. They **must not** be silently stripped,
classified as zero-width styling, or executed during planning/materialization.
Malformed or incomplete escape input returns `invalidFormatting` under the strict
formatting parser; it is not an unfinished streaming state.

**WRAP-STYLE1: Snapshot transitions.** A style callback **must** consume an immutable
input snapshot plus a formatting event and produce an explicit output snapshot
and validated emission descriptor. Snapshots include SGR attributes and active
OSC 8 link identity for the built-in adapter. They **must** have finite, caller-
bounded storage and stable snapshot IDs; input snapshots and the caller's live
style state remain unchanged on callback failure.

**WRAP-STYLE2: Continuity modes.** Chosen line boundaries **must** store the logical
style state at both sides of the boundary. In `suspendResume` mode, materialization
**must** close active OSC 8 and reset active SGR before the emitted newline, emit
the continuation indent in the caller's declared indent style, and restore the
selected source snapshot before following content. No style mode **may** change
text breaks or measurement.

The trailing final line has an explicit `preserveFinalState` or
`restoreInitialState` option. `copyThrough` mode copies original style tokens
without suspension; the plan records that style may extend through synthetic
newlines and indents, and it does not promise neutral borders.

**WRAP-STYLE3: Authored style boundaries.** A style change inside a cluster **must**
remain at its authored scalar boundary on output; the cluster **must not** be split
to move that change to a convenient line boundary. Source records **must** retain
the original escape ranges even when equivalent synthetic resets or resumptions
are added. An oversized link URI or unsupported snapshot state **must** report the
bounded state or resource error rather than be silently truncated.

## 9. Hyphenation machinery and resources

**WRAP-HYP1: Shared mechanism, external language policy.** Base **must** own a pure
hyphenation-candidate mechanism and validated borrowed resource representation.
Language selection, spelling rules, dictionary acquisition/licensing, left/right
minima, compound policy, and whether linguistic hyphenation is enabled belong to
the caller or text-layout. Base **must not** choose a locale, fetch a dictionary,
or interpret TeX macros to acquire hyphenation rules.

**WRAP-HYP3: Resource model.** A hyphenation resource **must** contain a
scalar-keyed pattern trie with interleaved integral weights, explicit
word-boundary markers, and exception records, and **must** carry a format revision,
language and policy identity, Unicode release identity, and content hash.
Matching **must** overlay maximum weights over all matched patterns, mark odd
resulting weights as candidate positions, and then filter them by the explicit
caller minima and exception policy.

Exceptions replace pattern results for the exact declared lookup key.
Reproducible resource generation also records the source license and generator
revision. The validated in-memory format is separate from its bounded external
parser.

**WRAP-HYP2: Provenance and budgets.** Hyphenation lookup **must** receive an
explicit normalized/cased lookup key and its core provenance map, or operate on
unaltered source text. A candidate is admitted only if it maps to an allowed whole
source-grapheme boundary and declares its pre/post/unbroken fragments. Expansion,
reordering, and ambiguous many-to-one mappings **must not** be converted to source
offsets by subtracting lookup lengths.

**WRAP-HYP4: Resource validation and lookup budgets.** Resource validation **must**
reject cycles, invalid scalar keys, out-of-range weights or positions, malformed
exceptions, release mismatch, and unsupported format revisions before
publication. Matching **must** charge scalar input and trie transitions against
caller work grants, and an exhausted lookup **must not** be reported as "no
hyphenation points." A resource **must not** be accepted for linguistic use
without its supplied linguistic policy and a real resource corpus.

Explicit soft hyphens and resource hyphenation share the same discretionary
solver and materialization machinery. No global mutable resource registry is
required.

## 10. Consumer migration

**WRAP-MIG1: Consumer migration.** Base writers and ranges, UI plain and rich
wrapping, measurement and clipping callsites, and both table views **must** use one
base plan and width authority. UI types and styled spans **may** remain UI-owned;
UI-specific adapters **must** project their style, no-break, and source metadata into
base and consume the resulting fragments without duplicating the classifier or
solver.

**WRAP-MIG2: Table provenance.** Table painting, column sizing, wrapping, selection,
click-to-source, and copy **must** consume the same measured plans. Source-sliced
cells keep cluster-exact byte boundaries; normalized prose exposes its explicit
many-to-one provenance and cannot claim byte-exact inverse mappings. Synthetic
borders, padding, bullets, and copy icons remain synthetic, not text byte offsets.

**WRAP-MIG3: No retained competing helpers.** Migration **must** delete the reduced
line-break classifier, the independent UI solver, code-point-count width and
cutting helpers, tests asserting those policies, and duplicate table mapping
arithmetic, and update every affected caller and delivered API documentation in
the same cutover. It **must not** keep a legacy re-export or an option that quietly
selects the old semantics.

The codec `LineWrapWriter`, which inserts newlines after a count of encoded ASCII
characters, is a byte-formatting adapter, not a competing text solver; it is
outside this migration. The existing code paths that the migration replaces are
listed in [the base text plan](./PLAN.md).

## 11. Acceptance obligations

**WRAP-TEST1: Tiny exhaustive reference.** Solver acceptance **must** include an
independently implemented enumerator over tiny finite candidate graphs, without
production DP, prefix sums, caches, or cost helpers. It enumerates every legal
complete path, carries the complete state, computes rational ratios and integer
costs using unbounded reference arithmetic, and applies the objective and tie
rules directly. Production results **must** be compared by complete selected
alternatives, state transitions, objective tuple, and realized glue, not only line
count.

**WRAP-TEST3: Oracle domain and independence.** The exhaustive domain **must**
include up to six endpoint positions, two distinct alternatives at a boundary, two
geometries, signed kerns, a pending post-break fragment, four fitness classes,
zero and positive stretch and shrink, and negative, positive, forced, and forbidden
penalties. The oracle **must** reject deliberately faulty engines that merge states
by endpoint alone, reuse a wrong-context width, or saturate cost. Expected
observations **must** be derived independently of the production solver.

Compact subsets are enumerated by risk, with the omitted Cartesian combinations
recorded and minimized failing cases and deterministic seeds retained. A
terminal-fill or glue-distribution helper shared with production is not an
independent oracle, and a test that asks the production solver to compute its own
expected cost is insufficient.

**WRAP-TEST2: Real boundary proof.** Cell acceptance **must** execute a small driver
using production source views, planning, bounded materialization, and mapping APIs,
then compare emitted bytes and source queries to manually derived fixtures.
Migration acceptance **must** exercise actual table/UI painting and public
selection/copy paths, not only a pure solver with mock widths. Physical contextual
acceptance **must** use real font resources and shaping, compare selected candidate
advances to the emitted shaped lines, and exercise safe-break reshaping.

**WRAP-TEST4: Unlimited clusters.** Long-cluster acceptance **must** include at least
1000 scalar values in one cluster, source chunks and ANSI boundaries inside it, and
a budget boundary. Resource and grapheme storage **must** be charged against source
and output budgets, not an arbitrary semantic cap.

_Rationale:_ Passing a 16/32-element buffer test is not an unlimited-grapheme proof.

**WRAP-TEST5: Observable assertions.** Permanent tests **must** assert externally
observable bytes, source boundaries, objective, state, failure commit behavior, or
declared limits. A test that only checks adapter forwarding or a nonempty result
**must not** count toward acceptance.

## 12. Decisions, delivery, and evidence

This page states requirements only. The decision records `WRAP-D1`–`WRAP-D5`,
with their states and revisit conditions, live in [decisions](./decisions.md).
Delivery slices and their gates are tracked in [the base text plan](./PLAN.md),
the one milestone tracker for this target. Permanent observable scenarios, worked
success, failure, and boundary traces, the independent contract review, and the
wrapping evidence ledger live in [testing](./testing.md).
