---
status: draft
owner: sparkles:text-layout
reviewed: 2026-10-04
---

# `sparkles:text-layout` — Testing and evidence

## Abstract

Acceptance requires observable paragraph behavior at the actual base/font boundary,
not agreement between two views of the same wrong widths. This strategy combines
small exhaustive line models, manually derived source/bidi maps, real-font reference
shaping, and consumer interaction. It separates font-independent planning evidence
from shaped composition and publication handoff evidence.

## Introduction

[The specification](./SPEC.md) owns requirements and [the plan](./PLAN.md) owns
milestone state. All scenarios here are **planned and unverified** unless a scoped
evidence record says otherwise. No test names below imply an existing test symbol
or executable package. Documentation publication and link checks cannot certify
paragraph correctness.

A layout's shape and its reference shape can share the same font engine. Such a
comparison detects incorrect itemization, context, scale and realization in this
library, not independent correctness of that shaper. Shaper/parser/Unicode
conformance belongs to [font testing](../font/testing.md) and
[base text testing](../base/text/testing.md); integration must still test our
composition and public source maps.

## 1. Oracles and fixtures

Use several independent expectations, chosen by the failure they can expose:

- An exhaustive, separately written small-graph enumerator lists legal break paths,
  discretionary continuations and objective costs, using base's declared arithmetic
  and cost semantics but not its production solver. It establishes an optimum for
  the enumerated finite graph, including line-dependent geometry. Deliberately
  merge two continuation states in a known-bad harness and require rejection.
- Manually derived source spans, logical order, branch choices and anchors test
  identity and projection without requiring a shaper. The expected map must not
  call production projection or segmentation to construct itself.
- Versioned base vectors establish Unicode behavior at the dependency boundary.
  Paragraph integration fixtures contain manually reviewed base-result boundaries;
  repeating the base test runner does not exercise font-run/line resets here.
- A separately driven actual font engine shapes exactly one selected line with
  recorded full pre/post-context, BOT/EOT flags, script/language/direction, features,
  variation coordinates and scale. Compare glyphs, clusters, rational positions and
  flags to composition traces before rendering. It must not consume production
  layout's generated expected glyph array. One-line comparison isolates integration
  defects; font's own independent differential suite remains a prerequisite.
- Simple hand-derived baseline/object/ruby geometries test extent unions and
  transforms. Raster images provide visual interaction proof, not an advance oracle.
- A bounded real composition host exercises alternatives, fragmentation, geometry
  feedback and export. It is not a fake page engine and does not fabricate paragraph
  summaries to make a handoff test pass.

Every actual-font fixture must record font-byte SHA-256, collection face index,
license/redistribution status, instance coordinates, physical em size, engine build
revision/configuration, base data/algorithm identity, language/script/direction,
features, candidate context, geometry and adjustment policy. Stable fixture IDs may
name installed corpus fonts only if CI and the release check have a verified
manifest; a developer's system family name is not reproducible provenance.

The corpus needs Latin kerning and discretionary ligatures, Arabic joining and
elongation, Hebrew mixed-direction text, Indic conjuncts, CJK vertical/ruby data,
emoji/variation sequences and a variable font with width-dependent metrics. Choose
concrete redistributable faces and pin their bytes before the shaped acceptance
suite is implemented; their absence is a gate, not permission to mock these scripts.
Font-dependent expected traces are recorded from the independent reference and
reviewed before running the implementation against them, never re-pinned just to
match a failing layout.

## 2. Permanent observable scenarios

The labels below identify scenario contracts, not delivered symbols. `u` in the
fixed-object examples is an explicitly supplied representable physical length in
base's `LayoutUnit`; no glyph measurement is inferred from a textual label.

### Fixed-object planning and projection

P1–P3 are **author-worked success, failure and boundary traces**, not independent
review or executed acceptance. Their arithmetic/source expectations are derived
here to make the first delivery falsifiable; permanent tests and a real public
operation must establish that an implementation follows them.

**P1 — Discretionary choices and copy (TL-004/TL-005/TL-010–TL-013).** Source
`ABCD` has snapshot S1, byte spans A `[0,1)`, BC `[1,3)`, D `[3,4)`. Fixed A and D
boxes have explicit visible-text associations and each advance `10u`; the
discretionary has unbroken BC advance `20u`, pre-break
B advance `10u` plus synthetic hyphen `3u`, and post-break C advance `10u`. With no
break, projection is A/BC/D and total `40u`. With only the discretionary selected,
the first line is A/B/hyphen with advance `23u`, the second C/D with advance `20u`.
Original copy is `ABCD` in both cases; visible text is `AB-CD` in the broken case.
The hyphen has no invented byte span. Upstream/downstream anchors at the break map
to their respective line edges; an anchor in the unselected fragment is inactive.
No font bytes or provider is involved.

**P2 — Kern, glue and geometry (TL-012/TL-017/TL-021).** Fixed boxes have advances
`10u`, `10u`, `10u`, with natural glue `2u` between the first pair and kern `-1u`
between the second pair. The natural total is `31u`, not `32u` or `33u`; an allowed
glue adjustment of `+2u` realizes `33u`. Requesting `34u` without another eligible
adjustment is infeasible. Keep the negative kern across the unbroken pair and do
not turn it into a legal break. Vary the second-line measure so two paths at one
break have different feasible successors; compare the chosen cost/path to exhaustive
enumeration, not just line count.

**P3 — Plan rejection and atomics (TL-007–TL-010).** Inject a span beyond S1, a
conflicting font/size/feature boundary inside `e` + U+0301, duplicate item IDs, a cyclic discretionary
reference, a glue minimum above maximum, and a text item requiring unresolved
physical measurement. Check the exact invalid-input or unsupported-capability
category and offending item; prior result bytes/lengths remain unchanged. Empty
input under explicit one-empty-line policy yields its paragraph-end anchor; under
explicit zero-line policy it yields no line and a paragraph-level anchor record.
Also insert an optional Penalty into each pre-break, post-break and unbroken
fragment. Each must return invalid input for the offending fragment atomically;
dropping the penalty or exposing an unrepresentable interior break is not a repair.
For P1's broken projection, provide capacity for exactly five content-span records
and two line records: A, B, synthetic hyphen, C and D commit with the expected
`23u`/`20u` line advances. Reduce either capacity by one: `outputTooSmall` leaves
the prior projection unchanged. The last valid source span `[3,4)` is accepted;
extending it to `[3,5)` rejects before publication. These are author-derived
capacity/source-boundary traces, not executed results.
For first-slice fixed objects with source text `e\u0301` as their visible association,
validate and retain a paint-only range at the accent's scalar boundary. This checks
source-span admission only: unresolved text measurement still reports unsupported
capability under TL-012. Glyph, RTL brush, shaping-reuse and actual painting
assertions belong to A1/I1 and their real-font integration gates, not TL-M1.

**P4 — Snapshot lifetime and stale identity (TL-004/TL-006).** Build a plan/result
borrowing S1 and its immutable styles, reset/reuse scratch, and check exact source
and anchor maps. Create S2 with the same byte length but a different revision, then
submit an S1 position to an S2 result and an old visual position to a reflowed S1
result. Both reject as stale without touching the other result's storage. Lifetime
instrumentation catches releasing borrowed source/font backing before the last
live result, not merely a round trip through IDs.

**P5 — Continuation-state optimum (TL-011/TL-012/TL-017/TL-032).** Enumerate small
paragraphs whose paths reach the same break boundary with different post-break
fragments, fitness classes or preceding flagged breaks, including line-indexed
measures. Derive every candidate advance and base-owned transition cost in the
independent enumerator. Require the same least-cost path and stable tie-breaking;
a deliberate endpoint-only-state solver must fail at least one retained fixture.

### Analysis and cell-grid behavior

**A1 — Whole-paragraph semantics (TL-001/TL-014/TL-015/TL-020/TL-038).** Use combining
text, regional-indicator flags, ZWJ emoji, Indic conjuncts and mixed Hebrew/Latin
with isolates and punctuation. Add paint changes, eligible font changes and page
fragment boundaries without altering logical bytes. Compare grapheme/opportunity
and paragraph-bidi records to independently reviewed whole-paragraph expectations;
none may reset at a paint run or page boundary. A conflicting shaping-style change
inside a grapheme rejects rather than splitting it. For `e\u0301`, a paint-only
boundary at source byte 1 succeeds, retains two paint spans and one unchanged
grapheme/shape, introduces no interior-grapheme caret, and selects the default brush
from the minimum logical source contributor.

**A2 — Cell maps are not glyph maps (TL-003/TL-023–TL-025).** For `e` + U+0301 +
`x`, `x` maps to original UTF-8 byte 3; for a two-regional-indicator flag + `x`, it
maps to byte 8. For a width-two CJK grapheme, either occupied cell maps to the same
grapheme start with the declared cell-edge affinity; the following cell maps after
the full source span. With an actual ligature programming font, ink may cross cells
but occupancy and these source maps remain identical to the unshaped cell plan.

**A3 — Unbounded grapheme and hostile input (TL-001/TL-008/TL-009/TL-014).** Use
valid extended graphemes longer than 16 and 32 scalars, including a long combining
sequence, alongside malformed UTF according to each selected base policy. Compare
whole-grapheme spans and continuation behavior to base's declared vectors. At one
below/exactly/one above the caller's analysis/workspace limit, valid clusters either
remain intact or fail with the named exhaustion outcome; never expose a truncated
cluster or trap on input data. The renderer does not execute embedded controls.

**A4 — Branch-induced analysis changes (TL-014/TL-017/TL-037).** A discretionary
replaces neutral content with a strong RTL fragment or a balanced isolate in a
mixed-direction paragraph, and another joins a base character with a combining
fragment. Independently derive base analysis for each complete selected projection.
Check that earlier/later run levels, grapheme spans and candidate shapes match
that projection, not cached unbroken levels or line-local reanalysis. Enumerate the
small complete choice graph independently and compare exact ranked layouts; an
adapter unable to represent the whole-projection analysis identity must return an
explicit capability/work failure, not a falsely exact result or a ban on the input.

### Actual shaped composition

**S1 — Candidate context versus unbroken widths (TL-015–TL-018).** Use a Latin
ligature/kerning pair and an Arabic joining sequence whose independent engine traces
change at a selected line boundary. Measure all candidates, choose breaks through
base, and realize the selected lines. Each selected candidate must match the
independently shaped actual-line trace; an intentionally naive prefix-width/sum-of-
words implementation must select or realize a wrong retained fixture. Include a
Unicode-legal break flagged unsafe and prove actual reshaping on both sides, not
suppression of that opportunity.

**S2 — RTL clusters and controls (TL-014/TL-020/TL-023).** Compose Arabic/Hebrew
with Latin numbers, isolates, punctuation and trailing whitespace. Independently
review paragraph levels and line visual order. Verify every source span remains
reachable, including zero-glyph controls; glyph-order traversal must not stand in
for source-order traversal. Resize so the bidi transition moves between lines and
check the revised line resolution without reparsing fragments as paragraphs.

**S3 — Whole-span fallback (TL-016/TL-022/TL-023).** Provide a primary real font
covering a base scalar but not its required mark/variation glyph or conjunct, and a
real fallback covering the whole selection unit. Inspect the chosen instance and
reference glyph trace; the unit cannot become separately positioned per-codepoint
fallback fragments. Repeat with no capable fallback: check explicit real-notdef
policy versus `missingFont`, source coverage and the original typed dependency
error on a malformed face. Success must not come from an empty-engine singleton.

**S4 — Physical scale and accumulation (TL-002/TL-019).** Shape a repeated run
whose design advance converts to a fractional `LayoutUnit`. Hand-derive the exact
rational cumulative origins and total, then nearest-even endpoints; total must not
equal a sum of incorrectly rounded individual advances. Repeat the same paragraph
at two device scales with all physical inputs unchanged: break identities,
physical origins and line total are identical, though raster bounds may differ.
Inject nonfinite/unrepresentable conversion and near-limit arithmetic; require
`arithmeticExhausted` and unchanged prior result, not saturation.

**S5 — Two different caches (TL-017/TL-018/TL-022).** Compose a snapshot at two
measures with unchanged font instances. Instrument cache observations in the
exercise harness: parsed font/instance identity is reused, geometry-dependent
candidate results are recomputed, and boundary-changing lines match independent
reference shaping. Then keep text/measure unchanged while changing a variable-font
coordinate or replacing font bytes under the same family name: glyph/advance
output changes to the new reference and affected shape/candidate keys do not reuse
stale results. Inspect outputs as well as counters; cache forwarding alone is not
a permanent behavioral test.

**S6 — Alignment and exact justification (TL-020/TL-021).** Use LTR and RTL
paragraphs with distinct start/end/left/right alignment, explicit last-line policy,
and unequal permitted glue adjustments. Derive line origins and adjustment totals
by hand. Applied adjustments remain within limits and sum exactly to the target
when feasible; stable logical-order residual distribution is observable at glyph
origins. For insufficient shrink/stretch, explicit overfull/ragged policy reports
its residual while strict policy rejects. Clipping must not masquerade as fit.

### Interaction and consumer surfaces

**I1 — Source, cluster and glyph identity (TL-004/TL-023/TL-038).** Use a decomposed
accent, one-to-many substitution, multi-grapheme ligature, zero-glyph control and
synthetic discretionary hyphen in one paragraph. Independently list source spans,
grapheme boundaries and glyph/cluster occurrence relationships. Require complete
many-to-many mapping, no synthetic byte offsets, and distinct font-qualified glyph
identities for identical glyph IDs from different instances.
Add a multi-grapheme RTL ligature with different source brushes: default paint
selection follows the minimum logical contributor, not first visual glyph order.
Synthetic discretionary content inherits its recorded origin/affinity brush.
Changing colour or a post-composition paint resolver updates the committed brushes
while preserving glyphs, origins, breaks, maps and carets and reusing semantic caches;
retained source paint spans do not imply exact partial-glyph colouring.

**I2 — Bidi and ligature carets (TL-024).** With actual fonts, hit-test on both
sides of a bidi boundary and inside a ligature with font-provided GDEF carets.
Expected stops come from reviewed font caret data and logical grapheme boundaries.
Repeat with a font lacking carets: stops follow equal-advance subdivision and carry
`estimated`; no guessed ink boundary is reported exact. At an exact tie use the
specified visual-coordinate/logical-order rule; zero-advance coincident stops
retain their separate affinities.

**I3 — Selection and copy through reflow (TL-004/TL-025).** Select a logical span
crossing an RTL run and discretionary break, obtain disjoint visual rectangles,
copy original source, and export visible text. Resize/recompose: logical selection
IDs and source copy remain the same, old visual IDs become stale, rectangles and
visible hyphenation follow the changed result. Verify cell-grid equivalents without
claiming they prove shaped geometry.

**I4 — Inline object hit policy (TL-023–TL-025/TL-031).** Place an object between
bidi runs with nonzero baseline offset and an alternative-text span. Its declared
directional role determines visual placement; default hits expose edge stops only.
A host-provided internal interaction map is used only for that object identity,
never fabricated by dividing object advance into character widths.

**C1 — Real consumer cutover (TL-003/TL-025/TL-036).** Exercise a migrated public
consumer with accent/flag/CJK and a real-font mixed-direction paragraph, as
applicable to its enabled modes. Observe actual rendering, pointer/source hits,
selection/copy and resize. Record captures and query outputs from the same committed
result. Deliberately change only renderer device scale: shaped physical breaks
remain unchanged; remove the old measuring/hit-test path rather than testing a
shim. An unavailable GUI/terminal/font surface stays an explicit verification gap.

### Publication typography and writing modes

**U1 — Finite expansion and protrusion (TL-017/TL-026/TL-027).** Compose real
punctuated text with two explicit width-axis or geometric expansion choices and
bounded protrusion. Independently measure each actual candidate and enumerate the
finite objective. The chosen expansion changes actual glyph origins/advance and
reported cost; visual edge punctuation's protrusion is reflected in effective
fitting measure and ink extent but not invented source/caret offsets. DPI and
atlas changes do not affect the result. A missing width-axis capability rejects or
uses only an explicitly authorized labelled transform, never a fabricated axis.

**U2 — Script-aware Arabic/CJK adjustment (TL-018/TL-021/TL-028).** With a font
reporting safe elongation, justify Arabic through authorized insertion/alternate
choices and compare the final reshaped line to the reference. Tatweel is synthetic
with origin provenance; no insertion occurs inside unsafe joins or combining
sequences. A font lacking this capability rejects the elongating profile but can
run an explicitly non-elongating one. CJK opportunities and prohibited positions
come from the declared profile; a Latin-space algorithm must fail the fixture.

**U3 — Baselines and vertical composition (TL-029/TL-030).** Compose runs and an
object with hand-derived before/after-baseline extents under a fixed strut; verify
their union and separately reported ink overflow. With actual vertical metrics and
orientation data, compose vertical-rl and vertical-lr mixed CJK/Latin and inspect
vertical substitutions/advances, transformed caret hits and block progression.
A rotated horizontal output is a known-bad case; missing vertical data produces a
capability outcome rather than zero metrics.

**U4 — Ruby geometry and segmentation (TL-017/TL-023/TL-031).** Compose a real-font
base group plus longer annotation at an explicit smaller size and placement side.
Check separately pinned source identities, annotation shaping, permitted overhang,
line fit and baseline extent against hand-derived/reference geometry. Change the
measure to force a break: the group stays atomic unless explicit paired segmentation
is supplied; in the latter case each fragment keeps its correct annotation pairing.

**U5 — Math/document object boundary (TL-008/TL-031/TL-035).** A real math composer
above font supplies a formula's measured box or breakable fragments using validated
font MATH data, source map and alternative text. Paragraph composition respects
advance/extents, anchors and permitted breaks without parsing formula tokens.
Unknown object metrics reject before commit. This acceptance needs an actual
composer for a math-consumer claim; a hand-measured ordinary box proves only the
paragraph object interface, not math support, TeX syntax or MATH parser conformance.

### Alternatives, fragments and page/export handoffs

**F1 — Complete versus bounded alternatives (TL-032).** For a small finite paragraph,
independently enumerate admissible break/adjustment paths with two requested line
counts and two geometry choices. Check returned costs, policy IDs, stable order and
break identities. An exact top-K limit below the admissible count returns the
independently proven ranked prefix plus `moreAlternatives`; full enumeration marks
`exhaustive` only when all admissible choices are accounted for. Insufficient
result storage for requested exhaustive enumeration fails atomically. A deliberately
approximate best-found list reports unproven ranking/completeness, not global ranks.

**F2 — Fragment/rejoin and suffix geometry (TL-013/TL-033).** Fragment a real mixed-
direction, discretionary paragraph at a legal line boundary, retaining a break
anchor and post-break replacement. Rejoin unchanged fragments: source coverage,
branches, bidi state, lines and geometry match the original. Reject mid-line and
stale-revision tokens. Change following geometry and request recomposition: the
suffix is remeasured with original paragraph context, not copied from a cached
locally optimal layout or reshaped as a new paragraph.

**F3 — Bounded page feedback (TL-009/TL-034).** A real exercise host selects an
alternative, locates an anchor, supplies a revised exclusion/line-measure sequence
and requests recomposition. Use one hand-derived stable geometry case and one
intentional two-state oscillation. The stable case reaches the host's declared
criterion with matching geometry revision; the oscillating case reaches the named
round limit and returns nonconverged while preserving prior committed results.
The paragraph library neither places the float nor chooses a page.

**F4 — Device-independent export (TL-002/TL-035).** Consume actual composed glyph,
font-identity, source/provenance, logical-order, anchor, object and transform records
without GPU or raster handles. An independent simple exporter reconstructs original
logical text including RTL while recognizing visible synthetic hyphens; scaling to
a different device changes only output conversion, not physical paragraph geometry.
This does not claim a PDF writer, tagged document, embedded fonts or subsetting.

**F5 — Front-end equivalence at the paragraph seam (TL-010/TL-031/TL-035).** Two
real host inputs that resolve to the same explicit paragraph items/styles must
produce identical committed paragraph choices and maps under the same snapshot
association policy. Changing only a front-end annotation/paint token must not
split shaping or change physical breaks. A real front-end acceptance needs its
parser and ownership tests above this seam; hand-constructed item lists prove only
text-layout's input contract, not HTML/Markdown/MathML/TeX compatibility.

### Resource and failure boundaries

**R1 — Work, capacity and arithmetic failures (TL-007–TL-009/TL-017–TL-019).** Run
each public operation with empty, one-below, exact and one-above required output and
workspace capacities; cap analysis entries, candidates, glyphs, states and
alternatives independently. The category and counter identify the exact exhausted
resource; no partial result replaces the prior output. Use an exact candidate whose
unsafe join requires a new font call and stop just before that budget: failure is
`workLimit`, not an unreshaped successful line. Retain a known-bad saturating
arithmetic case and an engine failure that would otherwise appear as zero glyphs.

## 3. Evidence ledger

| Requirement area                   | Scenario IDs | Status     | Evidence and remaining gap                                                           |
| ---------------------------------- | ------------ | ---------- | ------------------------------------------------------------------------------------ |
| Plan/projection/ownership          | P1–P5, R1    | unverified | Planned; no executable text-layout plan in this specification batch                  |
| Base analysis and cell integration | A1–A4, C1    | unverified | Planned; dependency conformance and historical cell probes are not integration proof |
| Real contextual shaping and caches | S1–S6, R1    | unverified | Planned; real font M2/M4/M7 and a pinned font corpus required                        |
| Source/visual interaction          | I1–I4, C1    | unverified | Planned; no real-font caret/reflow consumer capture supplied                         |
| Publication typography             | U1–U5        | unverified | Planned; actual vertical/elongation/math capabilities and host integration required  |
| Alternatives/page/export seam      | F1–F5        | unverified | Planned; no complete alternative search or host handoff executed                     |

The inspected dependency state on 2026-10-04 includes a draft
[font delivery plan](../font/PLAN.md), not a font package. No compiler, test,
formatter, renderer or paragraph smoke run was executed for this documentation-only
batch. The parent's integrated document checks, if run, must be recorded separately
and do not change any behavioral row to verified.

Each subsequent evidence entry records requirement IDs, scenario/test and execution
count, source revision or explicit dirty-tree snapshot, exact command, environment,
base/font/fixture manifest identities, result/artifact and residual gap. Missing
fonts, skipped GUI checks, zero matched tests and exhausted runs are not passes.
Failure invalidates the affected verification claim; a later passing run retains
the failed trace and its disposition rather than erasing history.

## 4. Sampling and limits of evidence

Run the core source/branch/limit fixtures in both modes where meaningful. Glyph,
physical-conversion and publication profiles are shaped-flow-only; cell occupancy
cannot prove them. Sample script/feature/variation combinations by risks such as
unsafe breaks, joins, fallback and caret ambiguity, recording omitted combinations
and why. Keep deterministic seeds and minimized generated paragraphs for every
solver/cache/source-map regression.

No finite corpus proves all fonts or all paragraph sizes. Measurements must report
input distributions, cold/reused font lifecycle, candidate/state/glyph counts,
workspace, hardware/toolchain and rejection limits. A benchmark that warms a font
cache while accidentally reusing stale width results is invalid. Performance
thresholds are accepted after the bounded feasibility measurement, not invented as
claims in this draft.

## Independent contract review

A separate read-only reviewer session on 2026-10-04 examined paragraph validation,
contextual provider/state identities, font integration, visual mappings and
publication seams. Final scoped rechecks found no remaining blocking defect in
the repaired requirements. No text-layout or font implementation was executed.

| Finding                                                                       | Disposition                    | Contract and falsifying trace                                                       |
| ----------------------------------------------------------------------------- | ------------------------------ | ----------------------------------------------------------------------------------- |
| Discretionary fragments admitted breaks forbidden by base's primitive algebra | Fixed; independently rechecked | TL-010 and P3 reject interior Penalty items in all three fragments                  |
| Blanket style prohibition rejected paint-only changes inside graphemes        | Fixed; independently rechecked | TL-038 and A1/I1 retain scalar paint spans without splitting analysis or shaping    |
| Paint-independent caches could return stale committed brushes                 | Fixed; independently rechecked | TL-022 distinguishes semantic caches from paint-qualified presentation              |
| Fixed-object first-slice P3 accidentally required a shaped paint result       | Fixed; independently rechecked | P3 is source-span admission only; glyph/RTL/reuse assertions remain real-font A1/I1 |

The author-worked traces remain unexecuted scenarios. Actual base solvers and font
capabilities, contextual branch-state feasibility, publication profiles, and host
integration still require the evidence and delivery gates recorded above.
