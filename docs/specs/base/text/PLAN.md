---
status: draft
owner: sparkles:base
reviewed: 2026-10-05
---

# Owned text delivery plan

## Abstract

This plan delivers the [owned text contract](./SPEC.md) through executable slices:
owned codecs, reproducible data and unbounded graphemes first; complete Unicode
algorithms, width profiles, and source maps next; consumer cutovers and independent
acceptance last. It also tracks the shared [wrapping contract](./wrapping.md),
without duplicating its requirements. Passing a slice does not certify the rest of
the target.

## Introduction

Encoding, table generation, and segmentation can be implemented and falsified
without a font subsystem. They are the first production slice because every later
measurement, transformation, and paragraph consumer needs a stable source model.
Consumer migration follows complete mechanisms, not replacement aliases that hide
old behavior behind a new module name. A _cutover_ moves a caller onto the contract
and removes the code it replaces in the same change.

This is the sole milestone tracker for the base text target. [Testing](./testing.md)
owns expected observations and evidence; [decisions](./decisions.md) owns choices.
Proposed operation names in the specification remain proposed until a milestone
delivers them.

## 1. State and gates

| Milestone                                       | State                                                                                      | Acceptance boundary                                                                                                                                                                                                                                                                                                  |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Stage 0 (incl. wrapping W0): contract and scope | scope approved; review recorded for the contracts committed in `9db961a35`; re-review open | testing.md §9 records independent review and repaired-trace rechecks of the base and wrapping contracts as committed in `9db961a35`. Requirements added or split since (TXT-CELL4–13, TXT-SIZE1–5, TXT-MIG3, and the restructured wrapping requirements) await re-review; publication validation is a separate gate. |
| M1a: owned encoding                             | in progress; core smoke verified for TXT-UTF1–12                                           | TXT-OWN1/3 and TXT-UTF1–18, through real prefix/stream/whole operations.                                                                                                                                                                                                                                             |
| M1b: reproducible Unicode 18 data               | in progress; offline generation verified                                                   | TXT-DATA1–6, offline regeneration, license retention, upgrade invalidation, and raw-data independent checks.                                                                                                                                                                                                         |
| M1c: unbounded graphemes                        | in progress; corpus and chunk spans verified                                               | TXT-SEG1–4, including chunk partitions and source-span behavior.                                                                                                                                                                                                                                                     |
| M2: complete Unicode algorithms                 | in progress; independent corpora verified for the prior contract subset                    | TXT-SEG5/6, TXT-BIDI1/2, TXT-ALG1, TXT-NORM1–4, TXT-CASE1, TXT-PROV1/2.                                                                                                                                                                                                                                              |
| M3: width profiles and maps                     | in progress; typed map smoke verified, expanded profile acceptance pending                 | TXT-CELL1–13, TXT-MAP1–7, TXT-CACHE1–3; both `terminalKitty` and `terminalUnclustered` with its folded emission, and the glyph-channel set.                                                                                                                                                                          |
| M3s: scaled footprints                          | not started                                                                                | TXT-SIZE1–5 as pure operations; the design system's `textSizing` consumer is gated on its own text-sizing entry condition (GLY5).                                                                                                                                                                                    |
| M4/W1: cell wrapping end to end                 | in progress; runtime acceptance pending                                                    | WRAP-OPP1–4, WRAP-POL1–6, plans, cell geometry and tabs, greedy, bounded emission, ANSI/style; §5.1.                                                                                                                                                                                                                 |
| M4/W2: exact balanced                           | in progress; runtime acceptance pending                                                    | Whole-candidate provider, variable geometry, exact budgets, squared objective and ties; §5.1.                                                                                                                                                                                                                        |
| M4/W3: exact measurable solver                  | in progress; runtime acceptance pending                                                    | Primitive algebra, Knuth–Plass ratio/demerits/glue realization, full path state, alternatives; §5.1.                                                                                                                                                                                                                 |
| M4/W5: hyphenation resources                    | in progress; runtime acceptance pending                                                    | Bounded parser/matcher and provenance over licensed resources supplied above base; §5.1.                                                                                                                                                                                                                             |
| M5 (incl. W4): caller cutover and removal       | in progress; expanded public-surface acceptance pending                                    | TXT-MIG1–3, WRAP-MIG1–2, and real consumer integration; no competing owning helpers; §6.                                                                                                                                                                                                                             |
| W6: contextual provider acceptance              | not started; owned by text-layout                                                          | Real shaped provider above base, after font M4/M7; §5.1.                                                                                                                                                                                                                                                             |
| M6: independent acceptance                      | in progress; complete acceptance pending                                                   | Complete promised suite, review, publication, and bounded-cost evidence.                                                                                                                                                                                                                                             |

A milestone's state refers to this target. The initial baseline included
compiler-derived segmentation and Unicode 17 analysis data; current runtime paths
have moved to owned Unicode 18 cores. Historical assets and passing isolated drivers
alone do not certify integrated consumers. The scoped implementation evidence below
does not sign off a complete milestone or newly added requirements.

Stage 0 publication and independent semantic review are separate gates. The owner's
scope decision (D-TXT-01) implies no reviewer identity, implementation signoff, or
verified evidence. Review walks the malformed stream, long-cluster, provenance,
stale-cache, and public selection scenarios in [testing](./testing.md).

### Initial implementation evidence

- Owned codec runtime smoke: maximal-subpart replacement, opaque-byte reconstruction,
  retained UTF-8 carry, UTF-16 output backpressure and final intent, and bounded
  replacement UTF-16z publication passed.
- The five affected UTF/grapheme/width feature modules passed their isolated
  unittests under LDC. The historical `unique.move.transfersSoleOwnership`
  copy-assertion blocker was subsequently fixed; the full published pre-rebase
  `b11d4eaf6` LDC base run passed 685 runtime tests and one CTFE test. Rebased-tree
  verification remains separate.
- The Unicode 18 official grapheme corpus passed all 853 records in the real
  conformance CLI. A separate smoke also checked finite break state, borrowed
  ranges, and absolute streaming spans over all 6,163 single-byte split positions.
- Offline LDC and DMD generation produced identical artifacts, SHA-256
  `9d05e431a3fd34e0b87c6eaaca3fd1bb467ecb2c2d26322aa1c37357dc2fba51`.
  A corrupted authenticated input was rejected without replacing an existing
  output or leaving a staging artifact. A failing Turkic-fold inheritance fixture
  passed after repairing C/F inheritance beneath T overrides.
- Independent raw Unicode 18 corpus drivers passed 1,944 word-break and 512
  sentence-break records, checking both UTF-32 and UTF-8 boundary coordinates.
  The line-opportunity driver passed 19,346 records and 80,131 boundaries.
- The bidi driver passed all 490,846 BidiTest and 91,707 BidiCharacterTest
  records: 861,948 resolved-direction cases, with no allowlist.
- The normalization driver passed 4,783,064 checks: the complete 20,171-record
  normalization corpus, omitted-scalar identities in all four forms, and exact
  provenance through 99,999 nonstarters. The casing driver passed 5,560,490
  complete transformations plus all-scalar simple mappings and locale contexts.
- A real bounded analyzer smoke passed composition/reordering contributor sets,
  full folding, accent and stopword deletions, opaque barriers, final-capacity and
  segment exhaustion, and empty publication after failure. A real fuzzy matcher
  smoke highlighted `[0,1)` and `[3,6)` for `ÀZ` against `A\u0315\u0300Z`,
  excluding the unrelated reordered mark rather than highlighting its envelope.
  The integrated fuzzy allocation audit subsequently passed 45 tests, including
  zero allocation calls for a complete keystroke. Workspace cost is recorded in
  the fuzzy specification; this is not a performance-improvement claim.
- Typed source-map smoke passed UTF-16 surrogate and UTF-8 interior positions,
  wide/zero/control geometry, affinity, stale keys/views, workspace reuse and
  exhaustion, and exact transformed contributor relationships. Caller snapshots
  borrow arenas and are invalidated on rebuild, including failed rebuilds.
- Analysis now declares separate final, segment, intermediate and provenance
  capacities; capacity exhaustion is an error, not successful truncation. The
  fuzzy intermediate-capacity and deleted-mark witness regressions pass in the
  integrated allocation-audit configuration.
- Standalone TUI smoke passed 40-byte cells with 2,048 combining marks,
  copy-on-write/detach/grow/diff and malformed input, plus whole-cell fitting,
  styled flags and keycaps. The expanded isolated foundation/wrapping suite
  passed all 18 discovered feature modules. The UI suite passed 616 tests.
  Real raylib/Mesa rendering passed paired long-cluster and late-accent bitmap
  checks; this does not certify the unfinished text-layout paragraph consumer.
- The real offline conformance CLI passed layers 0 and 11–16 together:
  853 grapheme records, 16,974 word-boundary checks, 4,734 sentence-boundary
  checks, 80,131 line opportunities, 861,948 bidi cases, 4,783,064 normalization
  checks, and 11,120,810 casing comparisons, with zero known or new failures.

## 2. M1a: owned codecs, operation by operation

M1a has no font or UI dependency. Use the existing modules
[utf8](../../../../libs/base/src/sparkles/base/text/utf8.d),
[utf16](../../../../libs/base/src/sparkles/base/text/utf16.d), and
[utf](../../../../libs/base/src/sparkles/base/text/utf.d) as seams. Preserve observable
strict-validation offsets and transactional UTF-16 behavior while extending the
owner to all specified modes and streams. The UTF-16 byte-order adapter of
TXT-UTF18 is
[utf16_bytes](../../../../libs/base/src/sparkles/base/text/utf16_bytes.d), over
the `utf16` codec.

1. Add the scalar reference operation and structured statuses first. Strict UTF-8,
   UTF-16, and UTF-32 decoder/encoder tests must assert published byte/code-unit
   vectors, not encoder/decoder agreement. Establish one-token capacity failure
   without writes and invalid-scalar rejection before exposing optimized paths.
2. Replace `decodeReplacement`'s Phobos malformed path with owned maximal-subpart
   consumption. Exercise all invalid lead/second-byte windows and truncated-final
   examples; preserve source spans. Move opaque-byte analysis decoding to the same
   owner while retaining its distinct one-byte preservation behavior.
3. Implement stateless prefix conversion and caller-owned encoding carry. Exhaust
   every split of two-, three-, and four-byte scalars and surrogate pairs, then
   malformed/chunk-boundary examples. Assert the precise consumed/written/carry
   state at every feed, `outputFull` retry, empty feed, finalize, failed feed, and
   reset. A prefix test is not a stream-carry test.
4. Extend whole bounded conversion to the specified encoding pairs and modes,
   overflow/overlap errors, and `z` termination. Preflight must check the complete
   input before touching destination; exact-capacity and one-short tests assert
   unchanged sentinels and error precedence.
5. Feed the same operation-level cases through scalar, CTFE where supported, and
   existing runtime dispatch. Keep accelerated code only when exact statuses,
   offsets, memory bounds, and output are identical. Reuse
   [utf_memory_test](../../../../libs/base/src/sparkles/base/text/utf_memory_test.d)
   and the [UTF benchmark package](https://github.com/PetarKirov/sparkles/blob/d43f88a39191eaaa3c743f02a2b9dd49ef059442/libs/base/bench/utf/README.md).
6. Migrate all base codec consumers off `std.utf` and transitive auto-decoding in
   this slice, removing obsolete decoder bodies rather than keeping a legacy
   mode. Delete tests that pin incidental Phobos malformed-byte consumption rather
   than re-pinning those assertions to the replacement implementation. Independent
   comparisons may remain isolated as supplementary diagnostics, not expectations.

Acceptance uses scenarios C01–C10 in testing.md, real bounded buffers, and a small
executable conversion driver which prints and asserts decoded tokens, source spans,
and each streaming result. Permanent regressions retain plausible failure paths;
throwaway driver and allocations are not production APIs. Run the target operations
before reporting delivery, and record actual selected test counts. No invented test
filter is a completion command: add deterministic named cases through the existing
runner and record the command which discovers and executes them.

## 3. M1b: one manifest-driven property pipeline

M1b can share M1a work on explicit byte parsing; it does not wait for shaping.
Refactor [gen_unicode_tables.d](../../../../libs/base/tools/gen_unicode_tables.d)
into the owner rather than introducing an unrelated generator convention.

1. Fetch final Unicode 18 inputs and tests from versioned paths, record their actual
   SHA-256 values in a reviewed manifest, and pin the algorithm editions from SPEC.
   Include the actual license artifact/hash and required redistribution attribution.
   Keep acquisition separate from the offline parser/emitter, and prove a release/
   schema upgrade rejects earlier cached identities rather than mixing tables.
2. Parse ASCII data fields through explicit byte operations. Implement `@missing`,
   ranges, aliases, First/Last pairs, Hangul formulas, and conflicts as independent
   cases. Remove generator dependencies on `CodepointSet`, compiler categories,
   `isWhite`, and auto-decoding Unicode iterators.
3. Generate the property families needed by the complete scope, retaining existing
   analysis lookup seams where sound. One manifest may emit multiple modules;
   generated metadata must never pretend a Phobos-probed table is Unicode 18.
4. Regenerate in two empty output directories with supported toolchains/locales,
   compare bytes, and query the full scalar domain against raw-source interpretation.
   Hash mismatch, missing input, and malformed source must leave installed output
   unchanged. Run entirely offline after initial fetch.
5. Retire the former `gen_grapheme_tables.d`
   compiler-probe pipeline and compiler-version cache gates when its consumers
   move to owned tables. Remove unused generated constants/modules, not aliases.
   Update conformance configuration to one manifest identity rather than two
   compiler-versus-width Unicode axes.

Acceptance uses D01–D06, actual generated artifacts, and the existing generator CLI
with explicit local source/output arguments. Record the final implemented command,
manifest revision, all hashes, and outputs; command examples for the old six-file
pipeline alone cannot certify the enlarged pipeline. No SHA-256 is fabricated in
this plan. Unicode final-artifact availability is evidenced in decisions.md; the
missing manifest is implementation work, not a missing external release.

## 4. M1c: forward and streaming extended graphemes

M1c requires M1a decoding and M1b GCB, Extended_Pictographic, and InCB properties.
It changes [grapheme.d](../../../../libs/base/src/sparkles/base/text/grapheme.d),
not just a width cache around Phobos.

1. Implement the full UAX #29 break-state transitions with borrowed source spans;
   manually trace CRLF, Hangul, Prepend, SpacingMark, Extend, EP/ZWJ, RI parity,
   and revised Unicode 18 GB9c before relying on generated cases.
2. Remove the decoded 16/32-code-point window as a semantic limit. Long runs must
   consume finite state, not a cluster-sized copied scalar array. Preserve styled
   escape interpretation in its adapter; plain segmentation owns Unicode input.
3. Add streaming boundary events with explicit carry, delayed cluster completion,
   retryable event backpressure, and caller source-retention requirements. Reuse
   whole-source corpus expectations across every small chunk partition.
4. Run all Unicode 18 GraphemeBreakTest rows without a default-algorithm allowlist,
   including the historical Indic failures. Add long synthesized traces because
   official corpora alone cannot disprove a fixed-window cap.
5. Cut over base width/wrap/analyzer consumers to the owned grapheme owner and
   remove `graphemeStride`, stale singleton compiler probes, and duplicated partial
   boundary rules. Default grapheme conformance must not be conflated with terminal
   width compatibility.

Acceptance uses G01–G05, conformance layer 0 configured for Unicode 18, and a real
scanner driver displaying the source byte spans of long/chunked examples. Existing
harness command shape is recorded in testing.md; delivery must report the actual
post-cutover command/configuration and counts, not the historical Unicode 17 run.

## 5. M2–M4: complete mechanisms

M2 has no external font prerequisite. It delivers complete default word/sentence
boundaries and UAX #14 opportunities, UAX #9 paragraph/line operations, all four
normalization forms, full/default/selected-locale casing, exact provenance, and the
bounded analysis cutover. These are not optional expansions of M1. Refine each
streaming transform's workspace and publication operation before its implementation;
acceptance includes all relevant official corpora, contextual casing examples,
long combining sequences, and non-monotonic provenance traces A01–A06.

M3 delivers the `terminalKitty` and `terminalUnclustered` width profiles, revision 1,
using owned Unicode properties, together with the glyph-channel set, grid-cell
fitting, and maps. `terminalKitty` carries the width algorithm of the
[cell-width reference](./index.md) without compiler-data skew; `terminalUnclustered`
shares those advances and adds the folded emission of TXT-CELL12–13, absorbing the
free-standing `unclusteredWidth` helper as its per-scalar advance rather than wrapping
it (TXT-MIG3). Pinned kitty, Ghostty, and XTerm comparisons classify interoperability
differences; they are evidence gates for those adapters, not external prerequisites
for the pure width profiles or maps. Complete scalar/UTF-16/grapheme/grid-cell maps
and stale-cache behavior come before public selection is integrated; scenarios
P01–P09 and X01–X03 own acceptance. A storage maximum produces exhaustion without
redefining a boundary.

M3s delivers scaled grid-cell footprints (TXT-SIZE1–5) as pure operations: sizing
validation, footprint measurement, block fitting, and hit mapping, accepted by P10
and decisions.md R6. It needs no terminal; a terminal adapter that emits OSC 66 and
the design system's `textSizing` consumer build on it.

M4 delivers the entire [wrapping contract](./wrapping.md). Its first cell slice
reuses owned measurement, complete opportunities, source spans, and affinity. Its
rich generic paragraph solver slice exercises exact state, boxes/glue/kerns/penalties,
discretionaries, anchors, fit objectives, and exhaustion with independent small
models; it must not add a font dependency to base. Contextual shaped candidates,
visual maps, mathematical composition, and publication are consumers above base.
The wrapping slices W1 (cell), W2 (balanced), W3 (measurable Knuth–Plass), and W5
(hyphenation resources) make up M4. W4, the caller and table cutover, is part of M5;
W6, contextual and font integration, is accepted by the text-layout owner after its
real font prerequisites. W0, the wrapping contract review, is part of Stage 0. The
first implementation gate for every wrapping slice is the owned Unicode, grapheme,
and grid-cell foundation (M1–M3), not another dependency on Phobos decoding or
tables. Mechanism implementation is in progress; wrapping.md's operation and
scenario requirements govern acceptance, and this tracker records executed slice
results, not a second milestone-progress tracker elsewhere.

### 5.1 Wrapping slices

**W1 — cell wrapping end to end.** Deliverable: `WRAP-OPP1–4`, `WRAP-POL1–6`, plans,
cell geometry and tabs, greedy, the cell operation, bounded emission, and ANSI/style;
requires the owned core algorithms and a width profile. W1 is an end-to-end cell
slice, not an empty solver interface. Within `tryWrapCells` it covers complete
borrowed UTF-8 views, bounded and unbounded widths, mandatory breaks, both whitespace
modes, tabs, first and continuation indents, local greedy, explicit overflow policy,
and ANSI formatting continuity, with LF/CRLF emission and overlap rejection. Until a
mode is delivered, the operation reports `unsupportedCapability` for it. Gate: a real
cell driver, source-copy and rendered-copy checks, transactional fault injection, and
mandatory, emergency, zero-width, and long-cluster cases.

**W2 — exact balanced.** Deliverable: a whole-candidate provider, variable geometry
state, exact budgets, and the squared objective with its ties. Gate: an independent
tiny exhaustive oracle, nonadditive and nonmonotone provider cases, and exact
exhaustion with approximate labeling.

**W3 — exact measurable solver.** Deliverable: primitive algebra, Knuth–Plass
ratio/demerits/glue realization, full path state, and constrained and ranked
alternatives. Gate: an exhaustive path-state oracle, hand-derived discretionary,
fitness, and geometry cases, alternative completeness and top-K ranking, and
arithmetic boundaries. Contextual shaping integration is not simulated as delivered.
W2 and W3 join the same operation contracts as W1, stay generic, and import no font.

**W4 — complete caller cutover (M5).** Deliverable: base and UI wrappers, both table
views, mappings, and deletion of the competing code. Gate: actual table
paint/selection/copy and UI line observations using the same plans, public consumer
regressions, and updated delivered docs. W4 requires matching width changes in
painting, not only a changed measurer while renderers advance by code point. It also
retires ui LAY10's and LAY14's own measurement: `sparkles.ui.wrap` and
`geometry.takeCells` keep policy and call base (WRAP-BOUND1).

**W5 — hyphenation resources.** Deliverable: a bounded parser and matcher with
provenance, over real licensed versioned resources supplied above base. Gate:
pattern and exception vectors, hostile parser cases, expansion and reordering
mappings, resource reproducibility, and linguistic-policy review. W5 supplies
mechanisms; linguistic quality acceptance belongs to the resource and policy owner
and requires the caller-supplied policy and a real resource corpus.

**W6 — contextual provider acceptance (text-layout).** Deliverable: a real
text-layout provider over delivered font M4/M7. Gate: real shaped candidates,
safe-break reshaping, alternative widths, and physical-unit invariance. The absence
of `libs/font` blocks this integration; a stub provider is not shaping proof.

## 6. M5: concrete clean cutovers

### 6.1 Wrapping integration baseline

The wrapping paths in the tree at `9db961a35` are the code the M5/W4 cutover
replaces; they are not evidence of the proposed operations.

- [Base wrapping](../../../../libs/base/src/sparkles/base/text/wrap.d) has
  `WrapOptions`, `writeWrappedText`, `wrapText`, `WrappedLines`, and
  `WrappedChunks`. Its classifier is a reduced UAX #14 subset and imports `std.uni`.
  Noncontiguous inputs are gathered, and wrapped ranges own a materialized buffer
  rather than borrowing a source plan.
- [UI wrapping](../../../../libs/ui/src/sparkles/ui/wrap.d) has `wrapLines` and
  `wrapSpans`, with ASCII-space tokenization and separate greedy and balanced logic.
  Its balanced width accumulation assumes additivity, and its plain greedy path adds
  independently measured substrings. ui LAY10's evidence stands for this code,
  pending the cutover to base (WRAP-BOUND1).
- [UI geometry](../../../../libs/ui/src/sparkles/ui/geometry.d) has `cellsOf` and
  `takeCells`, based on lead-byte and code-point counting, not whole graphemes. ui
  LAY14 has the same pending-cutover status.
- The [table string renderer](../../../../libs/ui/src/sparkles/ui/components/table/render.d)
  and [table widget renderer](../../../../libs/ui/src/sparkles/ui/components/table/widgets.d)
  use different width and wrap authorities, a divergence the shared
  [table layout](../../../../libs/ui/src/sparkles/ui/components/table/layout.d)
  describes. Rich UI spans carry source metadata, which is not proof of
  cluster-exact screen/source mappings.
- The codec `LineWrapWriter`, which inserts newlines after a count of encoded ASCII
  characters, is a byte-formatting adapter and stays outside the migration
  (WRAP-MIG3).

### 6.2 Cutover boundaries

Each row is a migration boundary, not evidence of delivery. All listed paths exist;
old module names in comments are not locations to edit.

| Consumer surface                                                                                         | Required cutover                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| -------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `libs/base/src/sparkles/base/text/{utf,utf8,utf16,analysis,width,grapheme,wrap,case_style}.d`            | Owned codecs/properties/breaks; remove malformed Phobos decoder, category CTFE data, partial word rules, stale cached probes, and the free-standing `unclusteredWidth`, which `terminalUnclustered` absorbs. Preserve explicit ASCII casing where that is the declared operation.                                                                                                                                                                                                                                                                                                                                                                                          |
| `libs/ui/src/sparkles/ui/{geometry,wrap,layout,display_list,canvas,cmd_buffer}.d`                        | Replace `cellsOf`/`takeCells` code-point authority and competing wrapping with base measure/fit/plan; migrate every caller and remove obsolete owning functions. Rendering extent and clipping use the same width profile as hit mapping. `sparkles.ui.wrap` (LAY10) and `takeCells` (LAY14) keep only policy and call base's wrapping (WRAP-BOUND1).                                                                                                                                                                                                                                                                                                                      |
| `libs/ui/src/sparkles/ui/components/table/{layout,widgets,render}.d`                                     | Unify string/widget widths and wrapping; replace `columnToByte` with affinity-aware grapheme/cell maps. Selection must not land in accents, flags, or wide interiors.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `libs/doc-view/src/sparkles/doc_view/{viewer_model,dsv_view,table_select,ansi_model,ansi_decode,pane}.d` | Use relocated doc-view paths, not historical `apps/hue/gui_*` names. Carry source spans through ANSI fences/DSV and table selection; source bytes copied from highlighted text must match the map. Replace scalar-stride editing where the consumer promises grapheme editing.                                                                                                                                                                                                                                                                                                                                                                                             |
| `libs/tui/src/sparkles/tui/{cell,render,input,terminal}.d`                                               | Put whole clusters and width-profile advances in the grid; replace byDchar/codepoint advance. Inline cell storage uses owned overflow storage and fails the render explicitly on exhaustion, never truncating or folding a grapheme because of its length (TXT-CELL8). Emit under the width profile chosen from design-system [D38](../../design-system/decisions.md)'s probe through `sparkles.base.term_replies`: `terminalKitty` when the terminal answers mode 2027 or its measured test cluster is two grid cells, `terminalUnclustered` otherwise. Layout is the same under both; only the emitted bytes differ (TXT-CELL12–13), and grid copy returns source bytes. |
| `libs/android/src/sparkles/android/{clipboard,http,intents,jni,text_input}.d`                            | Owned UTF-16 conversion and explicit native modified-UTF-8 distinction; verify payload versus terminator counts and source/UTF-16 map units.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| Base examples, core-cli/table consumers, source-view integration, and remaining repository callers       | Audit direct and transitive auto-decoding, cell counts, and coordinate assumptions after the named boundaries; migrate all production callers, not only the observed failing example.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |

The source-view/core-cli integration is a caller inventory task, not a claim that
all its paths import Phobos. Inspect actual callsites when the slice starts.
Consumer-specific adapter ownership and source-view parsing remain unchanged unless
obsolete competing text semantics are being removed. No font fallback or stub is
permitted to masquerade as shaped rendering. Actual font M4/M7 delivery is a
prerequisite for shaped text-layout integration, not for base cell/Unicode work.

M5 acceptance launches the real table/UI/TUI/doc-view surfaces, performs fit, hit,
drag, and copy actions using shared Unicode scenario inputs, and observes byte
ranges, widths, and long-cluster preservation. GUI configurations unavailable to the
implementer remain unverified, with a named prerequisite, not silently replaced by
pure model tests. Existing implementation-detail tests that assert code-point width
or copied strings instead of the intended contract must be removed, not re-pinned.
Keep behavior regressions at public boundaries.

## 7. M6 and handoff

M6 requires independent review of every promised obligation, full requested corpus
execution, scoped platform evidence, generator reproducibility, memory-bound checks,
and documented benchmark setup/comparison. No numerical speed promise supersedes
correctness; record performance regressions and decide with actual workloads.
Update delivered usage docs and the changelog only when corresponding implementation
has landed. Remove temporary drivers, stale helpers, old aliases, and obsolete
policy explanations during each completed cutover.

### Resume boundary

- Contract scope: approved (D-TXT-01, D-TXT-11–14). The draft contracts carry
  independent adversarial review with dispositions in testing.md §9; the width
  profile, glyph-channel, overflow-storage, and scaled-footprint requirements
  (TXT-CELL4–13, TXT-SIZE1–5, TXT-MIG3) await the same review. Publication checks
  and PR review are separate from implementation acceptance.
- Implementation target: M1–M6 are in progress for the prior contract subset;
  M3s is not started. The operation-level runtime observations above are evidence
  only for their named paths, not whole-target signoff.
- Remaining gates: integrated maps/wrapping, complete consumer/platform surfaces,
  acceptance of expanded contracts, independent implementation review, bounded-cost
  comparison, and implementation publication.
- External dependencies: none for M1a/M1b/M1c, pure M3, or pure M3s. Terminal
  interoperability evidence requires pinned real engines; shaped integration above
  base requires actual font M4/M7. Missing review or evidence is an unmet gate, not
  a pass.
