---
status: draft
owner: sparkles:base
reviewed: 2026-10-04
---

# Wrapping, fitting, and measurable paragraphs

## Abstract

`sparkles:base` supplies source-preserving line wrapping for terminal cells and
pure line-selection algorithms for measured paragraphs. It separates the places
where text can break from the policy that permits a break, the objective that
chooses lines, and the operation that emits those lines. Callers provide geometry,
measurement, and storage; the library preserves source identity and reports
capacity or work exhaustion instead of silently weakening an exact result. The
same solver mechanisms serve cell text and physically measured composition without
importing fonts, a user-interface toolkit, or a publication engine.

## Introduction

A terminal table, a prose widget, and a typeset paragraph all need to choose line
ends, but their measurements and policies differ. Cells have whole-grapheme widths
and column-dependent tabs. Shaped text has contextual advances: measuring pieces
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
line extents, and source-preserving materialization. The [base text
contract](./SPEC.md) owns UTF processing, Unicode algorithms, grapheme and width
semantics, and unwrapped fitting and affinities. [Contextual text
composition](../../text-layout/SPEC.md#_5-contextual-composition) owns semantic rich
paragraphs, shaping providers, visual ordering, fragmentation, and physical
paragraph composition. Font resources and shaping belong to the separate font
library; base has no font import. Page construction, frontends, and export belong
above text-layout. These mechanisms are not a claim to replace TeX.

The compact contract precedes operation details. Sections on units, opportunities,
plans, measurements, and solvers define behavior; the closing sections own the
delivery order, decisions, and evidence for this page. All API names introduced
here are **proposed**, not claims that symbols exist in the source tree. The
target remains draft for PR review. Independent adversarial review and repaired
trace rechecks are recorded in [base testing](./testing.md#_9-independent-contract-review);
the approved scope and contract review do not constitute implementation acceptance.

## 1. Contract at a glance

1. **WRAP-BOUND1: One owner per layer.** Base **must** own pure generic solvers and
   cell wrapping, with no font or UI dependency; text-layout **must** supply shaped
   measurements and semantic paragraph construction rather than duplicate a solver.
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
   geometry, continuation, fitness, and discretionary state must also agree.
6. **WRAP-FAIL1: Transactional planning.** Failure **must** leave the published
   output plan and its storage unchanged. Scratch and explicitly documented
   diagnostic counters may change; a failed scratch prefix is not a usable plan.
7. **WRAP-CUT1: Clean caller cutover.** Delivery **must** migrate consumers to this
   authority and remove competing wrap and width helpers; permanent aliases or
   old code paths are not an acceptance strategy.

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

Multiplication or division by a rational uses exact widened intermediates, rounds
once to nearest tick with ties to even, and reports a zero denominator as
`invalidInput`. Conversion from an explicitly supplied finite floating-point
physical value uses the same final rounding rule; NaN, infinity, and an
out-of-range rounded result are rejected. Exact comparison and cost arithmetic
use the unrounded raw values or rational values specified by the solver, not a
rounded ratio stored in a `LayoutUnit`.

**WRAP-UNIT3: Distinct dimensions.** Terminal column counts **must** use a distinct
nonnegative integral cell extent, not `LayoutUnit`. Conversion between cells and
physical lengths **must** require an explicit caller-supplied scale and checked
arithmetic; base **must not** assume a font, DPI, monitor scale, or a physical
width of a cell.

Font design units and device pixels are also different dimensions. Font adapters
convert design advances to `LayoutUnit` at the declared physical font size.
Rasterization converts physical positions to device pixels after composition.
Physical line selection must not depend on rasterization hinting or monitor DPI.
Signed physical kerns are valid; supplied line capacities are nonnegative.

**WRAP-UNIT4: Aggregate before quantization.** A font measurement adapter **must**
sum design-unit advances, kerns, and positioning adjustments as exact scaled
quantities at its declared measurement boundary before rounding that aggregate
to `LayoutUnit`. Whole-candidate or whole-run measurement **must not** sum
independently rounded glyph advances when that changes the rounded aggregate.
Mixed-font or mixed-scale aggregates retain their exact rational scales until
that final conversion. Individual positioned glyphs may have rounded output
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
Scratch may be released after successful publication only if no published span
points into it.

The first cell operation accepts a complete immutable source snapshot. Chunked
sources must be represented as one logical view, so a UTF sequence, escape, CRLF,
or grapheme may cross chunks. It is not a streaming partial-input API; an
unfinished final UTF or escape follows the selected core error policy. An
adapter that collects a stream must label that allocation and borrow lifetime.

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

For the first cell operation, each mandatory separator ends a logical paragraph
and resets first-line geometry/indent and solver adjacency state; the logical
source style continues through the break under the selected continuity mode.
The generic primitive interface instead distinguishes a forced line endpoint
from an explicit paragraph endpoint, so text-layout can preserve within-paragraph
fitness/geometry across an authored hard line break.

UAX #29 word segmentation is an available policy input, not the definition of a
line opportunity. A caller that requests a word-preserving policy identifies its
word-tailoring policy and no-break spans. The word policy can prohibit optional
opportunities but cannot erase a mandatory break or invent a break inside a
cluster.

**WRAP-POL1: Explicit policy.** The first cell operation **must** expose
`unicode` and `wordPreserving` opportunity filters, `preserve` and `collapse`
whitespace transforms, and one of `reject`, `overflowUnit`, or `graphemeEmergency`
for an unbreakable unit that cannot fit on an otherwise empty content line.
Defaults are `unicode`, `preserve`, and `graphemeEmergency`; the choice is recorded
in the plan. No no-wrap convention is overloaded onto width zero.

For this operation `collapse` replaces maximal runs of U+0020 and horizontal tab
with one synthetic U+0020 between content, and omits such a run at a chosen line
start or end. It does not collapse NBSP, other Unicode spaces, or mandatory
separators. `preserve` retains horizontal whitespace on its authored side of a
chosen opportunity; a break after a space does not silently trim it. Explicit
replacement and omission records carry the consumed source ranges in either mode.
Terminal tabs are processed after the whitespace transform.

**WRAP-POL2: Emergency precedence.** Emergency breaks **must** be admitted only
inside a maximal policy-unbreakable unit whose complete measurement exceeds its
empty-line capacity for the relevant geometry and continuation. They **must**
respect cluster boundaries and explicit no-break ranges; they **must not** override
NBSP, WJ, or an author no-break range unless a separate explicit policy permits
that protected range. The first cell operation does not permit that override.

For `reject`, the operation returns `unbreakableOverflow` with the offending source
range. For `overflowUnit`, the smallest policy-unbreakable unit is placed whole on
an otherwise empty content line, marked `overfull`; it must not swallow adjacent
units to reduce line count. For `graphemeEmergency`, the legal graph includes
interior whole-cluster boundaries of an eligible overwide unit. A cluster wider
than the empty-line capacity is emitted alone, marked `overfull`. A protected
no-break unit remains whole and overfull under this policy. The solvers compare
overfull and emergency choices using the precedence in section 7, not a hidden
large penalty constant.

**WRAP-POL3: Progress and empty lines.** A soft break **must** advance source
consumption or consume a nonempty discretionary replacement range; it **must not**
create a line containing only a continuation indent. Empty input **must** produce
one empty content line, and mandatory breaks **must** preserve empty lines,
including the final empty line after a trailing mandatory separator.

The width setting is `bounded(cellCount)` or `unbounded`. Bounded zero is a real
zero capacity: zero-width content may fit, and nonzero indivisible content follows
the declared overflow policy. Unbounded suppresses optional wrapping, but retains
mandatory breaks and requested whitespace/style transformations.

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
and line/source mappings. It **must** record source revision, Unicode/profile
identity for cell text, solver and policy options, and the proof class
`localGreedy`, `completeExact`, or `completeApproximate`. Only `completeExact`
certifies a global objective minimum. A plan **must not** imply that unselected
alternatives were copied into output.

Each source byte belongs to one consumed source record: emitted original,
replacement provenance, omitted transform, or mandatory separator. A source span
can have several output spans only when the explicit provenance relation says so;
it cannot be duplicated by guessing a source offset. Synthetic indentation,
hyphens, resets, link actions, and newlines have explicit anchor boundaries and
reasons, not invented source byte ranges. A discretionary owns its replacement
range; taking it substitutes pre/post for unbroken content, rather than emitting
all three. Alternatives at an identical boundary are distinct IDs; duplicate IDs
in one snapshot are invalid.

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
its declared starting column after its indent, using the core grapheme/width
profile, the chosen discretionary, and the declared tab stops. The plan **must**
retain `startColumn`, `indentExtent`, `contentAdvance`, `endColumn`, and `capacity`
separately. The line extent is advance, not an ink bounding box.

The first-line and continuation indents are borrowed styled text or prevalidated
fragment lists. They must have no mandatory separator, tab, nontext terminal
operation, or discretionary. Their full cluster advance counts against line
capacity. Indents may exceed a bounded capacity; the overflow policy then applies
to content without producing repeated empty indented lines. Geometry is selected
by paragraph-local line index; a mandatory paragraph separator resets that index.
An explicit geometry array either covers every needed line or declares a repeat
last-entry rule. Missing geometry is `geometryExhausted`, not inferred width.

**WRAP-TAB1: Column-dependent tabs.** The tab policy **must** be either preserve
or expand. A periodic stop interval is a positive cell count; the next stop from
absolute column `c` is `c + (interval - c % interval)`, including when `c` is
already a stop. Explicit stops are strictly increasing nonnegative columns and
require an explicit periodic tail or `noNextTabStop` failure.

A preserved tab emits its authored byte and records the measured advance; an
expanded tab emits that many spaces with provenance to the tab's one-byte range.
Line indents affect the next stop, and a wrap recomputes it for the next line.
Source chunks or style spans cannot reset the column. Overflow in column or stop
arithmetic returns `arithmeticExhausted`. A tab's output cells map to that source
unit's before/after boundary using affinity, not to fabricated repeated bytes.

### Borrowed fitting and wrapped affinities

**WRAP-FIT1: Reuse core fitting.** Prefix and suffix fitting on ordinary cell text
**must** use the whole-cluster and malformed-input policy of [core fitting and
coordinates](./SPEC.md#_6-cell-text-and-coordinates). Proposed `fitPrefix` and
`fitSuffix` return borrowed ranges and measured extents, not silently allocated
strings; wrapping **must not** introduce another segmentation or width model.

The line-aware variant additionally supplies an initial column and tab policy.
A suffix is measured as it appears from that supplied starting column, not by
subtracting a width from a previously measured prefix. It may require enumeration
when tabs or a provider are nonmonotone. Truncation reserves the exact measured
ellipsis/replacement extent before fitting; if the replacement itself cannot fit,
the explicit result is `replacementDoesNotFit`, not a split ellipsis or negative
budget.

**WRAP-MAP1: Boundary affinity.** Wrapped cell-to-source and source-to-line queries
**must** retain the core `before`/`after` boundary affinities. At a soft-wrap
boundary that appears on two lines, `before` chooses the preceding line's end and
`after` the following line's start. An interior cell of a wide cluster maps only
to that whole cluster's boundary pair, never an interior UTF byte or scalar.

Synthetic indent and pre-break hyphen cells map to their explicit anchor with the
requested affinity. Post-break replacements use their own provenance/anchor.
Collapsed whitespace exposes its complete consumed source range; omitted ranges
map to the adjacent retained boundary with affinity. ANSI/style-only spans share
the enclosing text boundary and have zero advance. The result includes whether it
is exact original, transformed, or synthetic. Base must not promise a byte-exact
inverse for an intentionally many-to-one transform.

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
  shrink coefficients; shrink may not exceed natural advance. One stretch
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
  taken. Each sequence may contain boxes, glue, kerns, and anchors, but not another
  opportunity or recursively nested discretionary. It declares its penalty,
  flagged bit, stable alternative ID, and next-line continuation identity.
- An **anchor** carries a source position or external marker with zero advance and
  no break. It survives transformation in an explicitly declared order.

**WRAP-PRIM2: Validation.** Primitives **must** have a finite acyclic logical order,
nonoverlapping owned replacement ranges, valid source boundaries, and unique IDs.
Negative glue capacities, mixed units, out-of-order mandatory breaks, recursive
alternatives, and ambiguous overlapping replacement ranges **must** return
`invalidInput` before publication. A paragraph with no legal full path returns
`noFeasiblePlan`; the solver must not insert an undeclared opportunity.

A continuation is a finite immutable pending post-break fragment sequence plus
provider-defined state needed to measure the next candidate. Its identity is
explicit and equality must mean equivalent future behavior for the snapshot.
Anchors at equal source boundaries preserve authored ordinal order. Empty
replacement ranges are allowed only when advancing the primitive/opportunity
ordinal; they must not permit a cycle or an unbounded number of zero-consumption
lines.

## 6. Measurement providers

A _candidate_ specifies its start state, endpoint alternative, line index,
geometry ID and capacity, pending post-break material, selected internal unbroken
alternatives, and whitespace/tab transform. Its measurement is for the exact
emitted content of that line, not for a substring approximation.

**WRAP-MEASURE1: Candidate result.** The measurement callback **must** return either
an explicit failure or a deterministic result containing natural advance,
stretch and shrink coefficients and individual realizability bounds, validated
break safety, and a borrowed or stored candidate-materialization descriptor.
Ink bounds may be supplementary; they
**must not** replace advance in the objective. Results **must** be stable for the
same complete candidate key and immutable resource snapshot.

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

A capability does not grant another capability: additive signed kerns can be
nonmonotone; monotone shaping can be nonadditive. Cache keys include the complete
candidate key, source/resource revision, and measurement options. Reusing a result
from another line geometry, pre/post alternative, language, or shaping context is
not allowed. Providers own the truth of declarations; acceptance includes a
provider-adapter capability audit and counterexamples, not only solver tests.

**WRAP-MEASURE3: Shaping safety.** A shaped provider **must** validate candidate
boundaries using its shaping-safe-break information and reshape contextual edges
or the whole candidate as needed. An unsafe break **must** be rejected or measured
through a safe contextual reshape; it **must not** be emitted by splitting a glyph
run at a byte offset. Its next-state identity must include any context influencing
future candidates.

**WRAP-MEASURE4: Callback failure.** Measurement, geometry, resource, or style
callback failure **must** abort planning with its phase, candidate/line identity,
and caller error code, leaving the published plan and output storage unchanged.
Base **must not** skip a failed candidate, retry callbacks implicitly, or return a
partial plan as success.

Callbacks are synchronous and do not reenter the same workspace. A callback may
update instrumentation but must not mutate source/resource snapshots or published
output. Base cannot roll back external callback side effects; the callback contract
therefore forbids externally committed output during planning. Callback-owned
memory/resource failure is translated by the callback, not mislabeled solver
scratch exhaustion. Cancellation is an explicit callback result with the same
uncommitted-plan behavior.

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
then (4) the mode's objective below. This prevents a numerical penalty shortcut
from making illegal overflow preferable to feasible ordinary lines.

A legal overfull edge contains only the permitted indivisible unit and its
mandatory pending/indent material. Emergency origin is counted even when its
numeric penalty is zero. Optional opportunities explicitly forbidden by policy
are absent, not expensive. Solver weights are nonnegative integers except an
optional penalty's signed value. Invalid weights are `invalidInput`.

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

For a nonmonotone provider the solver must examine every legal endpoint up to the
next mandatory boundary: a failed shorter candidate does not prove a longer one
fails. Under a declared proof of monotone feasibility it may stop earlier. Greedy
reports `localGreedy`, not global optimality or an approximation to a specific
Knuth–Plass minimum. If its locally selected continuation leads to a dead end, it
returns `noFeasiblePlan`; it must not silently backtrack and keep the greedy label.

### Balanced

**WRAP-BAL1: Raggedness objective.** Balanced **must** minimize the sum of squared
nonnegative trailing slack for every nonterminal line of each paragraph; the
terminal line contributes zero. Slack is `max(0, capacity - naturalAdvance)` after
indent, explicit transforms, and the selected break material. Glue remains at its
natural width; balanced is ragged-right, not justified Knuth–Plass.

The common policy tuple and tie order apply first. An ordinary under-capacity edge
is feasible regardless of glue; an over-capacity edge requires the explicit
common overflow policy. Costs use exact raw-unit integer squares and checked
unsigned-128 accumulation. Unrepresentable accumulated cost returns
`arithmeticExhausted`; it must not be capped to hide a lost ordering. Balanced
with variable line geometries needs line index/state in its dynamic program;
one cost per source endpoint is insufficient.

### Exact Knuth–Plass

**WRAP-KP1: Adjustment and badness.** Exact Knuth–Plass **must** evaluate natural
advance `N`, target content capacity `T`, total stretch coefficient `S`, and total
shrink coefficient `H` from the exact candidate. The rational adjustment ratio
is `(T-N)/S` when `N < T`, `(T-N)/H` when `N > T`, and zero when equal. A zero
applicable coefficient makes that nonzero adjustment infeasible; shrink ratio
below -1 or stretch ratio above the explicit finite nonnegative rational
tolerance is infeasible.

The terminal-line option is explicit: `ragged` accepts `N <= T` with ratio and
badness zero, whereas `justified` uses the same ratio rule as other lines. A
permitted overfull indivisible edge bypasses ratio feasibility with badness 10000
and ratio category `tight`; it still loses to any path with fewer overfull lines.
All other feasible edges have badness
`b = min(10000, ceil(100 * abs(r)^3))`, evaluated exactly as a rational. Fitness is
`tight` for `r < -1/2`, `decent` for `-1/2 <= r <= 1/2`, `loose` for
`1/2 < r <= 1`, and `veryLoose` for `r > 1`.

**WRAP-KP2: Demerit objective.** For each feasible line the demerit **must** be
`(linePenalty + b)^2`, plus `p^2` for an optional nonnegative penalty `p`, minus
`p^2` for an optional negative penalty, and zero penalty contribution for a forced
endpoint. Add `fitnessDemerit` when successive fitness categories differ by more
than one; add `consecutiveDiscretionaryDemerit` when both successive endpoints are
flagged; add `terminalDiscretionaryDemerit` when the immediately preceding endpoint
is flagged and this line terminates the paragraph.

There is no fitness/consecutive comparison on the first line. Paragraph-local
fitness and previous-flag state reset at a paragraph boundary. The objective is
the checked signed-128 sum of line demerits, after the common policy tuple. Negative
penalty contributions are allowed because the candidate graph is acyclic. Tolerance
and the nonnegative `linePenalty` and three adjacency/terminal demerit weights
are caller input recorded in the plan; there are no hidden TeX-compatibility
constants. Intermediate rational arithmetic
must be exact and checked; inability to represent an intermediate is
`arithmeticExhausted`, not a rounded decision.

**WRAP-KP3: Glue materialization.** A successful exact plan **must** retain its
exact adjustment ratio and allocation of adjusted glue widths. Each glue's
ideal advance is `natural + r * stretch` for nonnegative `r`, or
`natural + r * shrink` for negative `r`. Its realizable raw-unit interval **must**
be the intersection of `[natural - shrink, floor(natural + tolerance * stretch)]`
with its provider-supplied individual bounds from `WRAP-MEASURE1`. Supplied bounds
must be finite, nonnegative, ordered and contain the natural advance; malformed
bounds are an invalid provider result, not a silently ignored constraint.

For physical fixed-point output, each ideal advance is rounded to nearest tick
with ties to even and clamped to that interval. The signed residual between the
target and rounded total defines a logical round-robin allocation: one tick per
eligible glue in logical order, without leaving any interval. Implementation
**must** batch that allocation, never iterate once per residual tick. Let `c[i]`
be each glue's remaining capacity in the residual direction and
`F(q) = sum(min(c[i], q))`. Reject an absolute residual exceeding total capacity.
Choose the largest `q` in `[0, max(c)]` with `F(q)` no greater than the absolute
residual, apply `min(c[i], q)` ticks to each glue, then apply one tick to the
first remaining eligible glues for the remainder. Fixed-width binary search
requires at most 64 scans of the glue records; the final pass is linear. Checked
widened arithmetic is required for capacities, sums and residuals. This preserves
the round-robin result with work independent of physical width magnitude.
A justified feasible line **must** end at its exact target in raw ticks;
inability to realize that target within these bounds is infeasible.
A candidate whose intersected intervals cannot realize the target is infeasible
even when its aggregate adjustment ratio passes `WRAP-KP1`. Neither rounding nor
residual allocation may exceed an individual bound. For natural 1, stretch 4,
shrink 0, provider maximum 2, tolerance 1 and target 4, the ratio 3/4 is not
sufficient: that single-glue candidate is infeasible, not a width-4 realization.

Cell inputs use the same rule in integral cells. Ragged terminal lines and
policy-permitted overfull lines keep natural glue widths. Adjustment does not
modify box/kern advances. Realization is part of candidate feasibility, not a
later undocumented repair of the solver's chosen line.

### State, approximation, and bounded work

**WRAP-DP1: Exact state equivalence.** The dynamic-programming key **must** include
source/primitive endpoint and selected continuation identity, paragraph-local
line index and geometry state, prior fitness category, prior flagged-discretionary
state, and any provider state that affects future candidates. Prior discretionary
identity and pending post-break fragments **must** remain distinguishable when
they change a successor's measurement or penalty. States may merge only under a
proved future-equivalence relation, with the common objective and tie order
preserved.

A geometry callback that depends on history supplies a finite explicit geometry
state and deterministic transition. A callback that depends on undeclared global
history is incompatible with exact solving. Candidate measurements distinguish
ending discretionary alternatives as well as starting continuations. Forced
breaks alone are not proof that all prior state can be discarded.

When an alternative changes analysis beyond its adjacent lines, provider state
**must** distinguish the complete projected branch/analysis identity. Enumerating
finite whole-paragraph branch contexts before line selection is permitted and
charged to the same budgets. Reusing an unbroken paragraph's contextual analysis
for another projected branch without an equivalence proof cannot produce exact
success. Text-layout owns that analysis; feasibility of its finite provider-state
representation remains a contextual-provider acceptance gate, not a reason for
base to suppress valid alternatives or add a competing analyzer.

**WRAP-BUDGET1: Caller-owned workspace.** Planning **must** allocate no hidden
heap storage. It **must** use disjoint caller-provided scratch and output metadata
storage and expose limits for source bytes, input primitive/fragment records,
opportunities/alternatives, admitted states, transitions examined, measurement
calls, provider work units, and output fragments/style snapshots. Each limit is
a nonnegative explicit count; arithmetic for deriving storage or counts is checked.

Each admitted state and examined transition consumes one budget unit, each
measurement callback consumes one measurement unit, and a provider result reports
its declared work units. Providers must enforce a pre-call remaining-work grant
before performing expensive work; reporting overspend afterwards cannot establish
a work bound. Source/token scanning charges consumed bytes and emitted boundary
records, not a fixed per-grapheme scalar limit. Unlimited-length grapheme semantics
use finite segmentation state and borrowed source spans, never a 16/32-scalar cap.

**WRAP-BUDGET2: Exhaustion outcomes.** Exact mode **must** return
`budgetExhausted(kind, used, limit)` or `needScratch(kind, minimumAdditional)` when
it cannot complete, with no published partial plan. A caller can retry with larger
workspace/limits against the same immutable inputs; restarting does not imply a
persistent hidden search. `minimumAdditional` is a proven lower bound, not a
claimed exact total if exploration has not determined it.

Explicit approximate mode may use an incumbent complete plan, beam pruning, or
bounded candidate exploration. It must declare the approximation algorithm and
parameters before entry. It returns `completeApproximate` with objective,
consumed budgets, pruning reason, and `optimalityNotProven`, or an exhaustion
failure if it has no complete plan. A lower bound or optimality gap is exposed only
when proved. It must not switch from exact to approximate internally. A default
cell operation uses local greedy; choosing balanced means exact balanced unless
the caller explicitly opts into approximation.

**WRAP-WORK1: Work model.** For `B` source bytes, `P` logical primitives and
alternative-fragment records, `A` legal endpoint alternatives, `V` admitted
complete states, and `E` examined edges, engine work excluding provider work
**must** be bounded by
`O(B + P + A + (V + E) * (P + A + log(V + 1)) + output records)`.
This conservative bound includes assembling candidate descriptions, walking
predecessor paths for tie comparison, and ordered state lookup; an implementation
may establish tighter bounds for declared capabilities.

Stored engine metadata **must** be `O(V + P + A + output records)` plus one bounded
candidate workspace. Candidate continuations borrow immutable records rather
than copying full source text or predecessor paths into every state. Caching
every measured edge is optional caller storage charged separately.

A straightforward rigid constant-geometry balanced graph has `O(A^2)` edges and
`O(A)` endpoint states only if future-equivalence removes the line index. Variable
geometry, fitness, and post-break state invalidate that simplification. General
exact solving can have many states and must rely on declared budgets rather than
claim a universal linear or quadratic bound. Nonmonotone greedy can examine
`O(A^2)` candidates across lines; a proven monotone provider permits a linear
endpoint scan. Providers publish their own per-candidate work bounds and charge
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

The request declares an inclusive positive line-count range and positive maximum
result count `K`. Exact `topK` success certifies the first `min(K, available)`
ranked paths, separately reporting `exhaustive` or `moreAlternatives`. A request
for exhaustive enumeration fails with `needResults` if every legal constrained
path cannot fit its result storage; it does not publish a silently truncated list.
When no feasible constrained path exists, the operation returns a successful
exhaustive empty result, distinguishable from `budgetExhausted`. Each result has
the same source/borrow and materialization contracts as a single plan, and
failure leaves the previously published list unchanged.

Equivalent future states may share structural data, but ranked search preserves
the multiple prefix labels needed for distinct complete solutions, not only the
cheapest prefix. Such labels consume the admitted-state budget. All transitions,
measurements, result records, and proof work consume the declared budgets.
Approximate enumeration is opt-in and reports `rankingNotProven` and
`completenessNotProven`; exact budget exhaustion never becomes an approximate
list automatically. Text-layout owns contextual summaries and publication's
choice among these paragraphs; it must not create a second generic line solver.

## 8. First operations and materialization

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
selected fragment and source mapping is valid. Its first delivery supports
complete borrowed UTF-8 views, bounded/unbounded widths, mandatory breaks, both
whitespace modes, tabs, first/continuation indents, local greedy, explicit overflow
policy, and ANSI formatting continuity.

Balanced and generic Knuth–Plass enter in later slices under the same operation
contracts; they are required delivery targets, not inferred first-slice symbols.
The malformed-input mode is an explicit core mode: strict, Unicode replacement
by maximal subpart, or opaque-byte analysis. Replacement records retain original
malformed spans. In opaque mode an invalid byte is the core opaque unit and is not
silently fed into a Unicode scalar classifier. The core contract determines its
segmentation/width classification; wrapping supplies no competing decoder.

**WRAP-API2: Generic solve operation.** `trySolveWrap` **must** validate the
primitive graph, geometry, capabilities, exactness request, weights, budgets, and
workspace aliasing; then solve the declared graph and publish its selected
candidate descriptors. Exact mode with an estimate-only provider returns
`exactMeasurementRequired`, not exact success with an estimated objective.

Output plan storage may not alias source, scratch, provider snapshots, or the
storage of the previously published `outPlan`. Unsupported options, invalid
source boundaries, duplicate IDs, and incompatible capabilities return
`invalidInput` or `unsupportedCapability` before publication. Programmer lifetime
violations remain caller obligations; hostile external bytes, sizes, escape
sequences, and resource formats must not become assertion failures. Structured
errors contain phase, source range or candidate ID where meaningful, and budget
kind/caller code; diagnostics do not retain or log source text by default.

**WRAP-API3: Materialization operation.** `tryMaterializeWrap` **must** emit exactly
the selected plan into a bounded caller byte slice, without invoking the solver or
measurement callbacks again. It **must** reject a source/resource revision mismatch
as `stalePlan`, calculate the complete byte requirement with checked arithmetic,
and return `needOutput(requiredBytes)` without modifying output or `outExtent`
when capacity is insufficient.

For the first cell materializer, `emissionOptions` selects LF or CRLF between
planned lines, defaults to LF, and adds no newline after the final planned line.
Original mandatory separators remain in the source ledger; rendered-copy uses
the chosen emitted separator. A final empty planned line after a mandatory
separator therefore preserves its trailing newline. Indent/style transforms are
stored in the plan and cannot be changed at emission in a way that invalidates
its geometry; such a change requires replanning.

Materialization stages fallible style/candidate encoding in caller scratch before
committing bytes, or consumes prevalidated immutable emission descriptors. Any
encoding callback failure, `needScratch`, or arithmetic failure leaves output and
`outExtent` unchanged. On success, only `outputBytes[0..outExtent]` is written;
unused capacity remains unchanged. Source and output must be disjoint unless a
separate explicitly specified in-place algorithm is requested; the first operation
rejects overlap. Plain borrowed lines need not be copied merely to expose them.

A separate writer adapter can call the bounded materializer for one prepared
line and then write it. A fallible external sink is not transactional: its contract
reports the exact accepted prefix and does not rewind a file, terminal, or network
connection. It must not masquerade as the all-or-none bounded operation. A
convenience owned-string API may allocate once using the complete byte requirement;
it delegates line selection and mappings rather than introducing another engine.

### ANSI and styling state

**WRAP-ANSI1: Formatting transparency.** Supported SGR and OSC 8 hyperlink tokens
**must** be zero-width formatting over one logical scalar/grapheme stream, including
when a token lies between a base and combining mark, between regional indicators,
or inside a ZWJ sequence. They **must not** force a cluster or break opportunity.
Unknown SGR parameters may remain opaque formatting payload only under an
explicit parser policy whose state-restoration limitations are reported.

**WRAP-ANSI2: Nontext operations.** Cursor motion, erase commands, terminal mode
changes, device queries, images, and other nontext VT operations **must** return
`nonTextTerminalOperation` with source range, or be delegated by an explicit
caller adapter outside this text operation. They **must not** be silently stripped,
classified as zero-width styling, or executed during planning/materialization.
Malformed/incomplete escape input returns `invalidFormatting` under the first
operation's strict formatting parser; it is not an unfinished streaming state.

**WRAP-STYLE1: Snapshot transitions.** A style callback **must** consume an immutable
input snapshot plus a formatting event and produce an explicit output snapshot
and validated emission descriptor. Snapshots include SGR attributes and active
OSC 8 link identity for the built-in adapter. They **must** have finite, caller-
bounded storage and stable snapshot IDs; input snapshots and the caller's live
style state remain unchanged on callback failure.

Chosen line boundaries store the logical state at both sides of the boundary.
In `suspendResume` mode, materialization closes active OSC 8 and resets active SGR
before the emitted newline, emits the continuation indent in the caller's declared
indent style, and restores the selected source snapshot before following content.
The trailing final line has an explicit `preserveFinalState` or `restoreInitialState`
option. `copyThrough` mode copies original style tokens without suspension;
the plan records the possibility of style extending through synthetic newlines
and indents. It does not promise neutral borders. No style mode changes text
breaks or measurement.

A style change inside a cluster remains at its authored scalar boundary on output;
the cluster is not split to move that change to a convenient line boundary. Source
records retain the original escape ranges even when equivalent synthetic resets
or resumptions are added. An oversized link URI or unsupported snapshot state
reports the bounded state/resource error; silent truncation is not allowed.

## 9. Hyphenation machinery and resources

**WRAP-HYP1: Shared mechanism, external language policy.** Base **must** own a pure
hyphenation-candidate mechanism and validated borrowed resource representation.
Language selection, spelling rules, dictionary acquisition/licensing, left/right
minima, compound policy, and whether linguistic hyphenation is enabled belong to
the caller or text-layout. Base **must not** choose a locale, fetch a dictionary,
or interpret TeX macros to acquire hyphenation rules.

The resource model contains a scalar-keyed pattern trie with interleaved integral
weights, explicit word-boundary markers, and exception records. The matching
mechanism overlays maximum weights over all matched patterns; odd resulting
weights mark candidate positions, then the explicit caller minima and exception
policy filter them. Exceptions replace pattern results for the exact declared
lookup key. Every resource carries a format revision, language/policy identity,
Unicode release identity, and content hash; reproducible resource generation also
records the source license and generator revision. The validated in-memory format
is separate from its bounded external parser.

**WRAP-HYP2: Provenance and budgets.** Hyphenation lookup **must** receive an
explicit normalized/cased lookup key and its core provenance map, or operate on
unaltered source text. A candidate is admitted only if it maps to an allowed whole
source-grapheme boundary and declares its pre/post/unbroken fragments. Expansion,
reordering, and ambiguous many-to-one mappings **must not** be converted to source
offsets by subtracting lookup lengths.

Base resource validation rejects cycles, invalid scalar keys, out-of-range
weights/positions, malformed exceptions, release mismatch, and unsupported format
revisions before publication. Matching charges scalar input and trie transitions
against caller work grants; an exhausted lookup does not silently mean “no
hyphenation points.” Explicit soft hyphens and resource hyphenation share the
same discretionary solver and materialization machinery. No global mutable
resource registry is required. The linguistic policy and real resource corpus
must be supplied before the resource acceptance slice can be accepted.

## 10. Migration and decisions

### Verified integration baseline

The following are existing integration paths, not evidence of the proposed APIs:

- [Base wrapping](../../../../libs/base/src/sparkles/base/text/wrap.d) has
  `WrapOptions`, `writeWrappedText`, `wrapText`, `WrappedLines`, and
  `WrappedChunks`; its classifier is a reduced UAX #14 subset and imports
  `std.uni`. Noncontiguous inputs are gathered, and wrapped ranges own a
  materialized buffer rather than borrowing a source plan.
- [UI wrapping](../../../../libs/ui/src/sparkles/ui/wrap.d) has `wrapLines`
  and `wrapSpans`, with ASCII-space tokenization and separate greedy/balanced
  logic. Its balanced width accumulation assumes additivity; its plain greedy
  path adds independently measured substrings.
- [UI geometry](../../../../libs/ui/src/sparkles/ui/geometry.d) has `cellsOf`
  and `takeCells`, based on lead-byte/codepoint counting, not whole graphemes.
- The [table string renderer](../../../../libs/ui/src/sparkles/ui/components/table/render.d)
  and [table widget renderer](../../../../libs/ui/src/sparkles/ui/components/table/widgets.d)
  use different width/wrap authorities. The shared [table layout](../../../../libs/ui/src/sparkles/ui/components/table/layout.d)
  describes this divergence explicitly. Source metadata is carried in rich UI
  spans, but that is not proof of cluster-exact screen/source mappings.

**WRAP-MIG1: Consumer migration.** The delivery cutover **must** migrate base
writers/ranges, UI plain and rich wrapping, measurement and clipping callsites,
and both table views to one base plan/width authority. UI types and styled spans
may remain UI-owned; UI-specific adapters project their style/no-break/source
metadata into base and consume the resulting fragments without duplicating the
classifier or solver.

**WRAP-MIG2: Table provenance.** Table painting, column sizing, wrapping, selection,
click-to-source, and copy **must** consume the same measured plans. Source-sliced
cells keep cluster-exact byte boundaries; normalized prose exposes its explicit
many-to-one provenance and cannot claim byte-exact inverse mappings. Synthetic
borders, padding, bullets, and copy icons remain synthetic, not text byte offsets.

Delete the reduced classifier, independent UI solver, codepoint-count width and
cutting helpers, incompatible tests asserting those policies, and duplicate table
mapping arithmetic when migrated. Update every affected caller and delivered API
documentation in the same cutover. Do not keep a legacy re-export or an option
that quietly selects the old semantics. The codec `LineWrapWriter` that inserts
newlines after a count of encoded ASCII characters is a byte-formatting adapter,
not a competing text solver; it is intentionally outside this migration.

### Decision records

**WRAP-D1 — Proposed: plans before strings.** A source-preserving plan is the
owning representation; strings and writer output are projections. Direct emission
would be simpler for a log line but loses tab/transform/source identity and makes
callback failures partially visible. Revisit only if an allocation-free streaming
contract can preserve the same invariants without weakening transactional batch
planning; it must be a separately accepted operation.

**WRAP-D2 — Proposed: explicit local and global objectives.** Greedy, squared
raggedness, and exact Knuth–Plass are separate named modes. Treating balanced as
“Knuth–Plass” without adjustment, fitness, and consecutive-discretionary state
would conceal a different objective. These local demerit and tie rules choose
reproducibility over undocumented parity with a particular TeX engine.

**WRAP-D3 — Proposed: capability-based optimization.** Whole-candidate measurement
is the safe default, and providers opt into proved optimizations. Universal prefix
sums or “stop when too wide” are rejected because shaping, tabs, and negative
kerns falsify them. Optimization evidence must cover contextual edges and the
exact declared geometry, not only ASCII additive fixtures.

**WRAP-D4 — Proposed: physical fixed point, distinct cells.** Shared signed-64
physical units allow device-independent paragraph and later page composition.
Floating-point costs and implicit cell-to-pixel conversion are rejected because
they can change line choice across hosts. Checked overflow and explicit unit
conversion make the boundary observable. Physical-scale/range changes require
joint review by base, font, and text-layout owners.

**WRAP-D5 — Proposed: no silent fallback.** Exact resource exhaustion is a failure;
approximation is opt-in and labeled. An emergency break is a policy-controlled
candidate, not a fallback that bypasses no-break constraints. This costs callers
an explicit quality/budget decision but prevents a “balanced” label from hiding
a different algorithm on long or hostile input.

These decisions are scoped by the approved specification effort. Separate
independent reviewers dispositioned the worked failure traces and rechecked the
repairs; [the review record](./testing.md#_9-independent-contract-review) is not
executed solver/provider acceptance.

## 11. Delivery slices and gates

These delivery-slice contracts decompose the wrapping work in [the base delivery
plan](./PLAN.md), which is the sole milestone/progress tracker. All slices are
planned definitions, not delivery claims. The first implementation gate is the
owned core Unicode/grapheme/cell foundation, not another dependency on Phobos
decoding or tables.

| Slice                              | Required deliverable and prerequisites                                                                                                                | Acceptance gate                                                                                                                                                                                                  |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| W0: contract review                | This page, core ownership links, worked objective/failure traces                                                                                      | Independent adversarial review plus publication validation; draft until both recorded                                                                                                                            |
| W1: cell end-to-end                | `WRAP-OPP1–2`, `WRAP-POL1–3`, plans, cell geometry/tabs, greedy, first cell API, bounded emission, ANSI/style; requires owned core algorithms/profile | Real cell driver, source-copy and rendered-copy checks, transactional fault injection, mandatory/emergency/zero-width/long-cluster cases                                                                         |
| W2: exact balanced                 | Whole-candidate provider, variable geometry state, exact budgets, squared objective and ties                                                          | Independent tiny exhaustive oracle, nonadditive/nonmonotone provider cases, exact exhaustion and approximate labeling                                                                                            |
| W3: exact measurable solver        | Primitive algebra, Knuth–Plass ratio/demerits/glue realization, full path state, constrained/ranked alternatives                                      | Exhaustive path-state oracle, hand-derived discretionary/fitness/geometry cases, alternative completeness and top-K ranking, arithmetic boundaries; contextual shaping integration is not simulated as delivered |
| W4: complete caller cutover        | Base/UI wrappers, both table views, mappings, deleted competing code                                                                                  | Actual table paint/selection/copy and UI line observations using the same plans; public consumer regressions; updated delivered docs                                                                             |
| W5: hyphenation resources          | Bounded parser/matcher, provenance, real licensed versioned resources supplied above base                                                             | Pattern/exception vectors, hostile parser cases, expansion/reordering mappings, resource reproducibility and linguistic-policy review                                                                            |
| W6: contextual provider acceptance | Real text-layout provider and font delivery prerequisites                                                                                             | Real shaped candidates, safe-break reshaping, alternative widths, physical-unit invariance; font M4/M7 prerequisites must be delivered rather than mocked                                                        |

W1 is an end-to-end cell slice, not an empty solver interface. W2/W3 remain generic
and independently useful without font imports. W6 acceptance requires the actual
font library and text-layout integration; `libs/font` absence is a delivery blocker
for that integration, not permission to claim a stub provider as shaping proof.
W4 requires matching width changes in painting, not only changing a measurer while
renderers still advance by codepoint. W5 supplies mechanisms; linguistic quality
acceptance belongs to the resource/policy owner.

## 12. Testing, oracles, and evidence

### Independent solver oracle

**WRAP-TEST1: Tiny exhaustive reference.** Solver acceptance **must** include an
independently implemented enumerator over tiny finite candidate graphs, without
production DP, prefix sums, caches, or cost helpers. It enumerates every legal
complete path, carries the complete state, computes rational ratios and integer
costs using unbounded reference arithmetic, and applies the objective and tie
rules directly. Production results are compared by complete selected alternatives,
state transitions, objective tuple, and realized glue, not only line count.

The bounded exhaustive domain includes up to six endpoint positions, two distinct
alternatives at a boundary, two geometries, signed kerns, a pending post-break
fragment, four fitness classes, zero/positive stretch and shrink, and negative,
positive, forced, and forbidden penalties. Enumerate compact subsets by risk,
record which Cartesian combinations are omitted, and retain minimized failing
cases and deterministic seeds. The oracle must reject deliberately faulty engines
that merge states by endpoint alone, reuse a wrong-context width, or saturate cost.
A terminal-fill or glue-distribution helper shared with production is not an
independent oracle.

### Permanent observable scenarios

These acceptance scenarios are planned tests, not named existing test symbols.

| Requirements                            | Stimulus and boundary                                                                                                    | Required observation                                                                                                                                           |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `WRAP-OPP1`, `WRAP-OPP2`                | Release-pinned UAX #14 vectors, grapheme intersection, CRLF split between source chunks                                  | Correct default opportunity classes, no interior-cluster soft break, one consumed CRLF break                                                                   |
| `WRAP-POL1–3`                           | Empty source, `a\n\n`, bounded zero, protected NBSP unit, overwide single CJK cluster, indent wider than capacity        | One initial empty line; three lines for `a\n\n`; explicit progress/overfull/rejection results; no repeated indent-only soft lines                              |
| `WRAP-PLAN1–2`, `WRAP-MAP1`             | Collapse `a  b`, take a soft hyphen, expand a tab, insert indent                                                         | Copy-original exactly matches original bytes; rendered-copy matches chosen fragments; omitted/replaced/synthetic provenance stays distinct                     |
| `WRAP-CELL1`, `WRAP-TAB1`               | `a\tb` with interval 4 at start column 0; repeat at start column 1; wrap into a continuation with two-cell indent        | First tab advances 3, second advances 2; continuation recomputes from its actual indent, never reuses previous-line width                                      |
| `WRAP-FIT1`, `WRAP-MAP1`                | `e` + combining acute + `x`, flag + `x`, ZWJ family + `x`; fit or hit at cluster edges/interior cells                    | Whole-cluster fitting; `x` maps to byte 3 after accented `e`, byte 8 after a two-RI flag; before/after selects the proper side of a soft wrap                  |
| `WRAP-GREEDY1`, `WRAP-MEASURE2`         | Candidate endpoints with whole widths 4, 7, 5 at capacity 5, no monotonicity capability                                  | Greedy selects the third endpoint; the failed second does not terminate scanning                                                                               |
| `WRAP-BAL1`                             | Rigid `aaa bb cc ddddd`, collapse spaces, capacity 6, last line free                                                     | Greedy gives `aaa bb` / `cc` / `ddddd`; exact balanced gives `aaa` / `bb cc` / `ddddd` with squared-slack cost 10 instead of 16                                |
| `WRAP-BAL1`, `WRAP-DP1`                 | Same source endpoint reached on different line counts; geometry capacities alternate 4 and 7                             | Exhaustive minimum preserved; no endpoint-only merge loses the geometry-dependent winner                                                                       |
| `WRAP-MEASURE1–3`                       | Provider reports widths of separate pieces whose sum differs from whole candidate; ending hyphen changes context         | Exact whole-candidate result selects lines; forbidden prefix-sum shortcut is falsified; selected descriptor emits that same advance                            |
| `WRAP-KP1–3`                            | `N=8,T=10,S=4` in raw integral units, optional penalty 3, linePenalty 10                                                 | Ratio 1/2, badness 13, decent fitness, demerit 538 before adjacency terms; realized glue reaches 10                                                            |
| `WRAP-KP1–3`                            | Shrink ratio exactly -1 and just below -1; stretch exactly tolerance and just above; zero capacity; negative penalty     | Boundary feasibility matches exact rationals; signed penalty subtraction and objective ordering match oracle                                                   |
| `WRAP-MEASURE1`, `WRAP-KP3`             | One glue: natural 1, stretch 4, shrink 0, provider maximum 2, tolerance 1, target 4                                      | Aggregate ratio 3/4 does not admit a width-4 realization; intersection/residual feasibility rejects the candidate without publishing output                    |
| `WRAP-KP3`, `WRAP-WORK1`                | Two glues: natural 1 each, stretch M/1, shrink 0, individual maxima 1/M+1, tolerance M, target M+2, with M=1,000,000,000 | Exact realized widths 1 and M+1; allocation uses at most 64 record scans plus final pass, not M-1 tick iterations; input/state/record work bound remains valid |
| `WRAP-KP2`, `WRAP-DP1`                  | Two paths at one endpoint with different fitness/flag and pre/post alternatives; cheaper prefix has expensive successor  | Full-path optimum beats endpoint-only minimum; consecutive and terminal discretionary costs occur on the declared transitions                                  |
| `WRAP-UNIT1–3`, `WRAP-BAL1`, `WRAP-KP2` | Raw signed-64 extremes, half-tick conversions, accumulation past cost capacity                                           | Ties-to-even or precise arithmetic error; no saturated tie, device-dependent break, or implicit cells/points conversion                                        |
| `WRAP-API1–3`, `WRAP-MEASURE4`          | Fill output/old plan with sentinels; inject failure on each callback ordinal; exact-sized output and one byte short      | Failed operation leaves sentinels/old plan/outExtent unchanged; successful output has exact byte count; unused suffix unchanged                                |
| `WRAP-BUDGET1–2`                        | Budgets zero, exact-needed, and one below; complete approximate incumbent after prune; no incumbent                      | Exact success only with full search; exact exhaustion is uncommitted; approximate result labeled; no-incumbent exhaustion is failure                           |
| `WRAP-ANSI1`, `WRAP-STYLE1`             | SGR between base/accent, OSC 8 inside a flag or ZWJ sequence, active style at chosen wrap                                | Same text clusters/lines as unstyled content; authored style boundaries survive; link/SGR suspension and resumption match stored snapshots                     |
| `WRAP-ANSI2`                            | CSI cursor move, erase, mode change, image/query; incomplete CSI/OSC; oversized URI                                      | Exact offending range and declared error; no terminal side effect, hidden stripping, truncated resource, or committed bytes                                    |
| `WRAP-HYP1–2`                           | Overlapping odd/even pattern weights, explicit exception, lookup casing expansion, source cluster with many marks        | Max-weight/exception rules and whole-source-boundary filtering; no length-subtraction offset; budget failure distinct from no candidates                       |
| `WRAP-MIG1–2`                           | Real plain/rich UI and both table views with accents, flags, CJK, tabs, wrapped no-break spans and synthetic icons       | Matching sizing/paint advance/line ends; click/selection/copy identify correct original bytes; icons/borders never become source                               |
| `WRAP-ALT1`                             | Exhaustively enumerate a tiny graph; constrain exact line count; request top 1, top 2, all; repeat with two geometries   | Ranked prefixes equal oracle, no endpoint-only loss of second-best path, explicit exhaustive/more status, no-result constraint distinct from exhaustion        |

The hand-derived Knuth–Plass example uses `ceil(100*(1/2)^3)=13` and
`(10+13)^2+3^2=538`. It is an explanatory expected result, not an executed probe.
The balanced example excludes the final line's slack and counts no overfull or
emergency choices. Tests must independently derive those observations; a test
that asks the production solver to compute its own expected cost is insufficient.

### Author-worked first-slice traces

These are author-derived review inputs, not executed implementation evidence or
independent acceptance. They bind W1 success, failure, and boundary behavior to
specific byte/source observations.

**Success — formatting inside a cluster.** Use source
`e\x1b[31m\u0301x`, width `bounded(1)`, empty indents, strict UTF/formatting,
the declared cell profile, `graphemeEmergency`, `suspendResume`, and
`restoreInitialState`. Source byte ranges are `e` at `[0,1)`, SGR at `[1,6)`,
acute at `[6,8)`, and `x` at `[8,9)`. The `e`/acute cluster consumes `[0,8)`
including internal formatting; it is not broken at the SGR. The second line's
`x` consumes `[8,9)`. Each line advances one cell, neither is overfull, and the
soft break is anchored at byte 8 with before/after on the two lines.

The rendered bytes are
`e\x1b[31m\u0301\x1b[0m\n\x1b[31mx\x1b[0m`: 23 bytes.
The boundary snapshot is red; the newline is neutral; the final state is the
initial default. The original-copy traversal is the nine original bytes,
without synthetic resets, resumption, or newline. A 23-byte output slice succeeds;
a 22-byte slice returns `needOutput(23)` with all bytes and `outExtent` unchanged.
Splitting the logical view after byte 7 gives the same result, despite dividing
the acute's UTF-8 encoding between chunks.

**Failure — style state cannot be committed early.** Start with an existing
published plan and unrelated output-storage sentinels. For that same source,
the callback consuming SGR `[1,6)` returns caller error 17 while deriving its
output snapshot. Planning reports the style phase, that source range, and error 17. The old plan, its storage, the publication variable, and the caller's initial
style snapshot remain unchanged; no newline, reset, or text has reached a sink.
The scratch prefix is unusable. Changing that callback to success and retrying
on the same immutable source can produce the success trace; base does not retry
it automatically.

**Boundary — capacity is zero, not “no wrap.”** Use source `世\n`,
`bounded(0)`, empty indents, preserve whitespace, and `graphemeEmergency`.
The three-byte CJK cluster is indivisible, advances two cells under the declared
wide-cell policy, and occupies one overfull line. The following LF is a consumed
mandatory separator, and the final line is empty with zero advance. The result
has two lines, not a sequence of empty soft-break lines and not an unbounded
line. With `reject`, the same source returns `unbreakableOverflow([0,3))` and
publishes nothing. An `unbounded` request remains distinct and still retains the
LF/final-empty-line convention.

**Boundary — the cluster is not the scratch capacity.** Replace the accented
cluster in the success trace with a base followed by 1000 combining marks and
place a chunk/style boundary inside it. With enough byte/record budget the plan
still has one whole first cluster, not groups of 16 or 32. With insufficient
scratch the result is the explicit uncommitted capacity failure, not a different
segmentation or a shortened copied source.

### Real materialization and provider boundary

**WRAP-TEST2: Real boundary proof.** Cell acceptance **must** execute a small driver
using production source views, planning, bounded materialization, and mapping APIs,
then compare emitted bytes and source queries to manually derived fixtures.
Migration acceptance **must** exercise actual table/UI painting and public
selection/copy paths, not only a pure solver with mock widths. Physical contextual
acceptance **must** use real font resources and shaping, compare selected candidate
advances to the emitted shaped lines, and exercise safe-break reshaping.

Long combining sequences must include at least 1000 scalar values in one cluster,
source chunks and ANSI boundaries inside it, and a budget boundary. Passing a
16/32-element buffer test is not an unlimited-grapheme proof. Resource/grapheme
storage is charged against source/output budgets, not an arbitrary semantic cap.
Do not make a new test that merely checks adapter forwarding or a nonempty result;
permanent tests assert externally observable bytes, source boundaries, objective,
state, failure commit behavior, or declared limits.

### Evidence ledger

This ledger records wrapping-specific evidence. The [base testing
ledger](./testing.md) owns the shared Unicode prerequisite and historical defect
baselines; those observations are not new implementation proof here.

| Area                        | Evidence state | Checked observation                                                                                | Remaining gate                                                                                             |
| --------------------------- | -------------- | -------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Existing integration paths  | partial        | Source inspection of the linked base/UI/table modules in the specification worktree                | No runtime conformance follows from source inspection                                                      |
| W0 detailed semantic review | unverified     | Scope instruction accepted 2026-10-04; detailed solver review has not been recorded                | Independent worked success/failure/boundary review and dispositioned findings                              |
| W1–W6 implementation        | unverified     | Proposed API/algorithm contracts only; no implementation runs claimed                              | Required permanent scenarios, real drivers, consumer migration and shaped-provider acceptance              |
| Publication                 | unverified     | This author did not run builds, tests, lint, or formatters during the parallel documentation batch | Parent's integrated sidebar/link/evidence/build/format checks; publication pass is not semantic acceptance |

Each later entry must name requirement IDs, the source revision or explicit
dirty-tree snapshot, command/scenario, actual execution/discovery counts where
applicable, toolchain/configuration, result artifact, and omitted cases. Budget or
arithmetic failures do not count as successful exact solves. A missing font
provider, unavailable dictionary, skipped driver, or independent review still
pending leaves its gate unmet. Record implementation and publication evidence
separately; no result in this ledger has been fabricated to make the draft look
delivered.
