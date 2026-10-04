---
status: draft
owner: sparkles:base
reviewed: 2026-10-04
---

# Owned text testing and evidence

## Abstract

Acceptance combines published Unicode vectors, manually derived encoding and
coordinate traces, independent raw-data checks, bounded-state exploration, and
actual consumer interactions. Default-algorithm conformance is distinct from a
terminal-width interoperability policy. Historical failures motivate the target
but do not verify any replacement implementation.

## Introduction

An encoder and decoder can share the same defect, a generated table can agree with
its own generator, and a UI can draw plausible text while copying the wrong source
bytes. These tests therefore name the expected consumer observation and an oracle
independent of the production operation. Long and malformed input exercise limits
that small official corpora alone cannot settle.

[SPEC](./SPEC.md) owns requirements, [PLAN](./PLAN.md) owns delivery state, and
[decisions](./decisions.md) records consequential evidence limitations. Scenarios
below are planned acceptance work unless an evidence entry explicitly says otherwise.
Proposed test labels and operation names are not assertions that symbols exist.
The worked traces are author-derived success, failure, and boundary expectations
for review, not independent acceptance evidence. A reviewer must inspect the oracle
derivation and exercise the implementation before those traces can become verified.

## 1. Oracle and execution rules

- Encoding expected bytes and code units come from Unicode 18 chapter 3 tables,
  hand-derived scalar encodings, and explicit maximal-subpart traces. Round trips
  are supplementary, never the only oracle.
- Default grapheme/word/sentence/line/normalization/bidi expectations come from
  [Unicode 18 UCD](https://www.unicode.org/Public/18.0.0/ucd/) test files recorded
  with their actual SHA-256 values. The harness must assert every selected case ran;
  a zero-row parser, skipped corpus, or default-algorithm allowlist is not a pass.
- Property checks use a separately implemented raw-file interval interpreter, not
  production generated lookup helpers. Exercise the interpreter with known-bad
  overlaps/defaults and deliberately mutated generated values to prove disagreement
  is detected.
- Terminal compatibility uses a pinned real engine and exact configuration. The
  clean-room width oracle in the existing harness mirrors the delivered model and
  cannot independently validate that model's policy assumptions. A terminal/library
  disagreement is categorized as version skew, accepted profile divergence, or bug;
  it is not automatically a new allowlist row.
- Small models enumerate stream chunking and bounded output capacities. Keep seeds
  and minimized failures for larger randomized traces. Assertions compare tokens,
  spans, states, and statuses, not merely absence of exceptions.
- Each implementation slice runs an executable driver through real public operations
  before acceptance. Tests prove particular cases; actual consumer smoke exercises
  the corresponding interface and output. No font mocks may stand in for shaping.

## 2. Encoding scenarios

All byte values here are hexadecimal. Destination sentinels are deliberately different
from the expected payload. Successful counts exclude an optional terminator. Source
positions for UTF-8 are bytes and for UTF-16/32 are their code units.

### C01 — strict boundaries (TXT-UTF1/4, TXT-OWN3)

Encode and decode independently specified scalars 0000, 007F, 0080, 07FF, 0800,
D7FF, E000, FFFF, 10000, and 10FFFF. Examples include U+10000 = UTF-8
`F0 90 80 80`, UTF-16 `D800 DC00`; U+10FFFF = `F4 8F BF BF`,
`DBFF DFFF`. Accept noncharacters and unassigned scalars as encodings. Reject
scalar D800, DFFF, and 110000, and UTF-8 `C0 80`, `E0 9F BF`,
`ED A0 80`, `F4 90 80 80`, `F5 80 80 80`, and bare `80`.
For `41 E1 41`, strict failure starts at byte 1, not at the bad continuation
byte 2. For UTF-16 `0041 D800 0042`, failure starts at unit 1.

One-token encoding into capacities zero through four checks exact required units
and untouched whole destination on failure. Invalid scalar with zero capacity is
`invalidScalar`, not insufficient capacity. Run identical vectors through scalar,
accelerated, supported CTFE, and architecture fallback configurations.

### C02 — maximal subparts versus opaque bytes (TXT-UTF2/3)

Assert exact token/value/span lists, not just the decoded string:

| Final UTF-8 input | Replacement tokens                    | Opaque analysis tokens                          |
| ----------------- | ------------------------------------- | ----------------------------------------------- |
| `E1 80 41`        | FFFD `[0,2)`, A `[2,3)`               | opaque E1 `[0,1)`, opaque 80 `[1,2)`, A `[2,3)` |
| `F0 90 80`        | FFFD `[0,3)`                          | opaque F0, opaque 90, opaque 80, each one byte  |
| `ED A0 80`        | Three FFFD tokens, each one byte      | Three opaque tokens, each one byte              |
| `F0 90 41 80`     | FFFD `[0,2)`, A `[2,3)`, FFFD `[3,4)` | F0 and 90 opaque, A, then 80 opaque             |
| `C2 C2 A2`        | FFFD `[0,1)`, U+00A2 `[1,3)`          | opaque C2, U+00A2                               |

Raw reconstruction must recover original bytes for every opaque row. Passing an
opaque token to Unicode conversion must return `opaqueNotEncodable` with no output
for that token. Supplement this matrix with exhaustive one- and two-byte input,
all constrained second-byte windows, and deterministic longer malformed cases;
expected maximal-subpart spans come from a small independent prefix recognizer.

### C03 — prefix incomplete/final distinction (TXT-UTF5/6)

With `41 F0 90` and `final=false`, prefix conversion commits A only,
reports consumed=1 and `needInput`, and leaves `F0 90` unconsumed. Supplying
`F0 90 80 80` on retry produces U+10000 once. With `final=true`, strict
mode commits A then reports invalid at byte 1, while replacement emits one FFFD
for `[1,3)`. Non-final `E0 80` is already invalid and is not `needInput`;
non-final lone `E0` is incomplete. Non-final UTF-16 `D800` is incomplete;
`D800 0041` is definitely malformed. Empty-final is `end`, empty-non-final
is `needInput`.

### C04 — stream carry and absolute offsets (TXT-UTF5/7/8)

Feed UTF-8 chunks `41 F0`, `90 80`, `80 42` in a stream converting to
UTF-16. After the first feed the output is `0041`, consumed=2, and carry contains
`F0` at absolute byte 1. After the second, consumed=2, output is empty, carry
is `F0 90 80` at byte 1. Final third feed emits `D800 DC00 0042`,
consumed=2, then `end`. Match whole conversion exactly.

Strict finalization instead after the second feed reports invalid at absolute byte
1 with carry retained in failed state; replacement finalization emits one FFFD
for source `[1,4)` then `end`. Any subsequent feed must be `invalidState`
with unchanged destination; reset enables a fresh stream with offset zero.
Exhaust every partition of the C01/C02 vectors, including empty chunks and a
malformed continuation arriving after retained lead bytes.
An empty non-final feed to each of finalized and failed streams returns
`invalidState`, not `needInput`, with no changes. An empty non-final feed to an
active stream without pending final intent returns `needInput` and preserves carry.

### C05 — token-atomic backpressure (TXT-UTF6/7/8)

Retain UTF-8 `F0 90 80` in carry, then feed final `80 42` with only one
UTF-16 output unit available. Expect `outputFull`, new consumed=0, written=0,
required=2, and unchanged carry/destination. Retry the same final chunk into
capacity two: the pair commits, consumed=1, written=2, and `outputFull` for B.
Retry the unconsumed B into capacity one: B commits and status is `end`.
Observe no duplicated supplementary scalar. Enumerate capacities around every
encoded token length, and include zero-capacity strict `C0` which must be invalid
rather than output-full.
After the initial final feed reports `outputFull`, retry with `final=false` and
assert `invalidState` with unchanged pending-final state; restoring `final=true`
must still deliver the original token exactly once. Reject an overlapping output
buffer or unsupported option without consuming input or failing an otherwise
usable stream, then retry with disjoint storage/correct options.
An empty non-final retry while final intent is pending also returns `invalidState`
with carry and offsets unchanged.

### C06 — whole transaction and termination (TXT-UTF9/11)

Convert `A\0界` ordinarily and observe all three scalars; `z` conversion
must reject embedded NUL at byte 1 and preserve every sentinel. Convert `A界`
to UTF-16z in capacity three: output `0041 754C 0000`, returned payload count 2. Capacity two must return required=3 and preserve destination. Malformed source
in a zero-capacity destination must report invalidity, not capacity. Put malformed
source before/after NUL to check first-source-defect precedence. Empty ordinary
conversion writes nothing; empty `z` writes one zero or fails unchanged at zero
capacity.

### C07 — overlap and borrowed lifetime (TXT-UTF10)

Use overlapping source/destination slices of one aligned arena, including different
UTF element types and exact same storage, and assert `overlap` without modification.
Disjoint adjacent slices must succeed. Zero-length slices must not be rejected just
for sharing a pointer. No returned result may reference scratch after its borrow
ends; compiler lifetime checks supplement a native driver which reuses unrelated
scratch and observes stable owned counts/statuses.

### C08 — checked arithmetic (TXT-UTF11/12)

Test the count accumulator independently at representable maximum and one-past,
including terminator addition, and exercise public stream absolute-offset overflow
through a scoped test state initializer that preserves all other invariants. This
avoids allocating an impossible address-space-sized input. Production must have no
test-only semantic branch. Overflow leaves token output untouched and fails the
stream; reset recovers. Record which public overflow paths cannot be reached with
finite available memory rather than falsely claiming enormous-buffer execution.

### C09 — exact memory boundary (TXT-UTF12, TXT-OWN3)

Reuse guard-page tests for zero to SIMD-block-plus-tail sizes and all alignments.
Place malformed/truncated sequences against the last accessible byte and destination
against a protected page; inspect sentinels before and after requested output.
Exercise runtime feature dispatch with the actual selected implementations. Success
on padded heap buffers alone does not prove the no-padding requirement.

### C10 — owned analysis path (TXT-OWN1, TXT-UTF3)

Analyze a borrowed byte slice containing valid UTF-8 around `FF` and `E1 80`.
Observe distinct opaque units with exact source ranges, no exception, no normalization
across the opaque barrier, and raw reconstruction of each byte. An import/instantiation
audit checks production transitive decoding dependencies, but the observed unit list
is the semantic proof. Test-only Phobos comparisons remain isolated.

## 3. Data scenarios

**D01 — reproducibility (TXT-DATA1/3).** Using the same reviewed manifest, generate
into two clean directories with different supported compilers and host locales,
then compare complete emitted bytes. Repeat offline with network access blocked.
Assert all generated modules carry the same manifest identity and no output contains
an absolute path or timestamp. Changing one manifest source hash must fail before
output replacement, not silently regenerate under a new identity.

**D02 — parser/defaults (TXT-DATA2/4).** Independent fixtures cover UnicodeData
First/Last, `@missing` on unassigned ranges, property aliases, excluded composition,
algorithmic Hangul, InCB, and RGI sequences. Missing a required source file, truncating
a row, adding conflicting ranges, or substituting a Unicode 17 header must be rejected
with installed artifacts unchanged. Deliberately alter a generated property for one
unassigned scalar and verify the raw interpreter catches it.

**D03 — complete scalar domain (TXT-DATA4).** Compare every applicable generated
property across all scalars against the separately parsed release input, including
unassigned supplementary ranges and defaults. Non-scalars must fail the scalar query
without out-of-bounds reads. Boundary checks cover each emitted interval's first,
last, and neighbors; check mapping pool offsets independently of lookup code.

**D04 — compiler independence (TXT-OWN1, TXT-DATA1–3).** Change supported compiler
versions while keeping manifest/data fixed and compare generated bytes and query
results. Confirm neither generation nor consumer compilation probes compiler Unicode
categories or grapheme state. An offline artifact identity difference fails the gate
even if the short example output agrees.

**D05 — license retention (TXT-DATA5).** Inspect the actual consumed Unicode license
artifact/hash and required attribution in generated distributions. Strip the notice
in a disposable generation fixture and verify the distribution gate rejects it.
The test must inspect the emitted artifact, not only a copied manifest string.

**D06 — release upgrade (TXT-DATA6, TXT-CACHE1).** Build/query caches under one
manifest, then select a changed release or schema identity. Earlier property,
boundary, analysis, and map caches must be rejected before returning a result;
partial mixed-version tables must fail initialization. Rebuilding under the complete
new manifest must match uncached expectations. Persisted indexes exercise the owning
application's rebuild boundary rather than silently accepting an old cache format.

## 4. Grapheme scenarios

**G01 — release corpus (TXT-SEG1).** Execute every Unicode 18
[GraphemeBreakTest row](https://www.unicode.org/Public/18.0.0/ucd/auxiliary/GraphemeBreakTest.txt)
with exact expected boundary offsets translated from the file's scalar positions by
an independent encoder. Include 0/end once and no empty clusters. Retain GB9c Indic
rows as strict regressions, not terminal-policy divergences.

**G02 — unlimited context (TXT-SEG1/2).** `a` followed by 65,537 U+0301 then `b`
has one cluster for the full first run and a second for `b`. Build an EP + long
Extend run + ZWJ + EP trace which stays a single cluster under GB11, and Indic
consonant/linker/extend traces admitted by the revised GB9c. Long RI runs break into
pairs with a final singleton when odd. Assert exact byte endpoints at lengths around
16, 32, 64, and 65,536; do not merely assert the scanner did not throw. Observe bounded
algorithm state independently of input-sized borrowed storage.

**G03 — partitions and event capacity (TXT-SEG3/4).** Exhaust every chunk partition
of small CRLF, Hangul, Prepend, accent, flag, ZWJ, and Indic traces, including splits
inside encodings. Non-final end after `e` must not publish its cluster end because
a following accent can extend it. Finalization publishes the delayed end exactly
once. Use event capacity zero/one and assert retry produces the same boundary without
lost or duplicated source ranges. A spanning event returns offsets; requesting a
contiguous slice without caller-retained source must report unavailable storage.

**G04 — decode modes (TXT-SEG1/4, TXT-UTF2/3).** Strict malformed input returns the
owned error offset; replacement clusters refer to original maximal-subpart spans.
Opaque bytes are individual barriers even next to Extend/ZWJ. Distinguish this extension
from Unicode conformance, and confirm chunking cannot change replacement consumption.

**G05 — stable borrowing (TXT-SEG2, TXT-CACHE1).** Iterating the same immutable
revision twice produces identical spans, including long clusters; replacing its
source revision invalidates state before the next lookup. Releasing borrowed source
while a slice lives must fail lifetime checking or violate an explicit documented
caller precondition, not become hidden owned allocation. A real scanner driver prints
and asserts byte spans of the same long and chunked inputs.

## 5. Remaining Unicode algorithm scenarios

These scenarios are required scope, not already implemented evidence.

**A01 — boundary families (TXT-SEG5/6).** Run every pinned WordBreakTest,
SentenceBreakTest, and LineBreakTest row against logical-source offsets. Assert
mandatory breaks versus opportunities, including empty/end input, CRLF, apostrophe/
Hebrew contexts, numeric contexts, and Unicode 18 dash/GL updates. Default results
must not depend on terminal width or a selected dictionary.

**A02 — normalization (TXT-NORM1/2).** Execute every NormalizationTest row for all
four forms, independently assert canonical ordering/composition exclusion/Hangul,
and normalize a starter plus a nonstarter run longer than workspace. Capacity exactly
required succeeds; one-short returns workspace exhaustion without a published partial
normalized result. Retrying with sufficient workspace yields the corpus result; no
implicit CGJ appears in ordinary normalization.

**A03 — casing (TXT-CASE1).** Assert full uppercase `ß` → `SS`, default final
sigma in appropriate word context, default/Turkic I folding differences, and explicit
Lithuanian SpecialCasing examples derived from the pinned file. Unknown locale is
`unsupportedLocale`. Check title casing against owned word boundaries and one-to-many
provenance, not ASCII whitespace or a compiler locale.

**A04 — provenance (TXT-PROV1/2, TXT-MAP4).** NFC `e\u0301` → U+00E9 retains
both contributing source spans. NFD U+00E9 expands two units sharing its original
span. Reorder `a\u0315\u0300`: the original byte spans must follow the actual
contributors after reordering, not become monotonically fabricated. Remove an accent
or complete stopword and assert before/after mappings across the removed interval.
An opaque byte between starter and mark prevents composition across it. Empty
transformed output still maps to both original source endpoints.
For NFD `a\u0315\u0300` → `a\u0300\u0315`, source byte boundary 3 projects
to transformed bytes 1/5 for before/after, marked projected; the envelope includes
the reordered grave although it is not a contributor of the selected source prefix.
For NFC of the same source → `à\u0315`, boundary 3 projects to 0/4; `à` retains
exact contributor spans `[0,1)` and `[3,5)`, not their coarse hull. For NFC
`e\u0301` → `é`, boundary 1 projects to 0/2. For NFD `é` → `e\u0301`,
source end 2 maps exactly to output end 3. Deleting `a` from `ab` maps source
boundaries 0 and 1 to output 0 with a projected/deletion marker; inverse affinity
at output 0 returns source boundaries 0/1. Exact-only queries reject projected cuts.

**A05 — bidi (TXT-BIDI1/2, TXT-ALG1).** Execute BidiTest and BidiCharacterTest,
then independently traced isolate/paired-bracket/override examples with forced and
automatic base directions. Supply two different line partitions of the same resolved
paragraph and verify the line resets/inverse permutations. X9 controls retain source
identity but acquire no fake visible position. Exercise standard depth/overflow counters
separately from caller workspace exhaustion; neither is an arbitrary paragraph truncation.

**A06 — analysis/workspace (TXT-NORM3, TXT-ALG1).** Exercise each selected pipeline
order and renormalization with folds that change normalization properties. Change
lexicon revision and observe cache invalidation. Exceed provenance/source offset,
output, and combining workspace bounds separately; errors must be distinguishable
and no successful incomplete analysis may be consumed as complete text.

## 6. Cell, map, cache, and actual consumer scenarios

**P01 — measure/fit identity (TXT-CELL1–3).** Under narrow ambiguous
`terminalKitty`, measure `e\u0301x`, `界x`, `🇺🇸x`, and `👩‍👩‍👧‍👦x`
as 2, 3, 3, and 3 cells. Budgets around the first cluster's width admit or exclude
that whole cluster. Suffix fitting must agree with independently enumerated forward
boundaries, including odd RI runs. An isolated zero-advance sequence at a zero budget
is included according to policy; negative budget errors rather than silently clips.
Tabs/newlines/escapes fail plain measurement at the original offset.

**P02 — byte/cell boundary observations (TXT-MAP1–3).** For `e\u0301x`, source
bytes `[0,3)` are the first cluster, and cell 1 maps to byte 3. For `🇺🇸x`,
first cluster `[0,8)` occupies two cells and cell 2 maps to byte 8. For `界x`,
cell 1 before/after maps to bytes 0/3. Exact mode rejects those wide interiors.
A shared zero-advance cell position selects earliest/latest source boundary by
before/after. Out-of-range requests error instead of relying on UI clamping.

**P03 — UTF-16 and transformed maps (TXT-MAP1/2/4).** For `A😀B`, UTF-8
boundaries are 0/1/5/6 and UTF-16 boundaries 0/1/3/4. UTF-16 offset 2 is inside
the pair and exact scalar mapping must fail; affinities map to bytes 1/5. Follow
full-fold expansion, normalization composition/reordering, and deletion via exact
provenance; expected source highlights come from original input spans, not transformed
byte counts.

**P04 — immutable cache reuse (TXT-CACHE1/3).** Cache the maps for one revision,
replace bytes under the same document identity with a new revision, and request a
cached coordinate. It must return `staleSource` before dereferencing old borrowed
storage. Changing only the width/analysis manifest/profile yields `stalePolicy`.
One-short map storage returns `workspaceFull`; sparse checkpoints and uncached results
must agree for every coordinate in the small traces.

**P05 — incremental invalidation (TXT-CACHE2).** Insert one RI at the beginning of
a long RI run and check changed pair parity throughout; insert a linker/Extend in
an Indic context; modify bidi paragraph direction. A fixed nearby rescan is not enough.
Compare accepted updated-cache maps against full rescans, including before/after
relationships and deleted spans. Unproven reuse must be rejected, not merely likely.

**P06 — terminal policy interoperability (TXT-CELL1).** Freeze real kitty/Ghostty
engine revisions, clustering/configuration assumptions, input transcripts and cursor
readings. Compare the named local profile with the control-free corpus and exercise
an actual terminal surface; classify documented spacing-mark/Prepend and emoji
presentation differences as profile differences, not Unicode segmentation failures.
Ghostty-backed consumers retain the engine's authoritative cell coordinates instead
of reconstructing them under `terminalKitty`. Missing engine/configuration leaves
interoperability evidence unmet, but does not block pure profile/maps acceptance or
make an installed engine's tables the production fallback.

**X01 — table drag/copy (TXT-MIG1/2).** Use real string and widget table views with
`e\u0301x` and `🇺🇸x`. Locate the x cell and observe hit byte offsets 3 and
8; drag over the complete preceding cluster and copy exactly its original bytes.
Copy x alone and observe exactly `78`, not the final combining mark or second RI.
Repeat after wrap/clip and verify source offsets remain attached to the displayed line.
Both views must measure/render/select using one profile.

**X02 — UI and relocated doc-view (TXT-MIG1/2).** Launch the real UI/display-list
and doc-view surfaces, fit CJK and ZWJ text into narrow rows, then select/copy from
DSV and ANSI fences. Observe no cut cluster, consistent measured/painted extent,
and correct original byte spans across escapes. A replaced document revision must
invalidate old selection caches. Text regenerated by cursor motion must be marked
non-source/adapter-generated rather than given a fabricated original span.

**X03 — TUI storage/render (TXT-MIG1/2).** Launch an actual TUI terminal flow with
mode 2027, emit a cluster exceeding the existing 16-byte inline cell storage followed
by x, and observe the complete grapheme in emitted bytes and the correct grid advance.
Repeat grid copy, retained-frame diff, and clipping so overflow storage does not
borrow released frame memory. Configured storage failure must abort explicitly,
not produce a truncated successful glyph. Observe input decoding of a scalar split
across reads through the owned stream path.

**X04 — native adapters (TXT-UTF9–11, TXT-MAP1/2, TXT-MIG2).** Exercise available
Android/native UTF-16 boundaries with supplementary scalar, embedded NUL, and exact
termination capacities. Assert counts and selection/composition offsets in UTF-16
units. Document the native API's modified-UTF-8 boundary explicitly. Unsupported
platform runs remain unverified; a local conversion driver does not certify native
clipboard/IME behavior.

## 7. Reusing executable infrastructure

The existing [conformance harness](./conformance-harness.md),
[tool package](../../../../libs/base/tools/text-conformance/),
[UTF benchmark package](https://github.com/PetarKirov/sparkles/blob/d43f88a39191eaaa3c743f02a2b9dd49ef059442/libs/base/bench/utf/README.md), and
[memory tests](../../../../libs/base/src/sparkles/base/text/utf_memory_test.d)
are the execution seams. Do not build a parallel harness whose expectations are
computed by the production implementation.

These command shapes exist before this target and are not claimed executed here:

```sh
# Published segmentation corpus; configure the pinned target only after cutover.
dub run --root=libs/base/tools/text-conformance --config=offline -- \
  --layers 0 --unicode-version 18.0.0 --ucd-dir /path/to/hashed-ucd --no-network

# Existing correctness sweep without foreign runtime dependencies.
dub test --root=libs/base/bench/utf --compiler=ldc2 -b bench \
  -c unittest -- -i 'utf\.correctness$'

# Existing generator CLI seam; enlarged manifest-driven inputs are M1b work.
dub run --single libs/base/tools/gen_unicode_tables.d -- \
  --unicode-version 18.0.0 --ucd-dir /path/to/hashed-ucd \
  --out-file /tmp/unicode-tables.d
```

The first command cannot certify word/line/bidi/normalization families until the
harness has real adapters for them. The third command's old six-source pipeline
cannot satisfy TXT-DATA1–6 until refactored. Delivery records the actual implemented
commands, discovered/executed case counts, manifest identity, toolchain, scalar/SIMD
selection, and retained artifacts. Performance evidence reuses benchmark lifecycle,
corpus, setup-cost, affinity, and environment reporting conventions; no universal
speed threshold or allocation-free claim is inferred from a wall-clock result.

## 8. Evidence ledger

| Evidence                                                                                     | Classification                                   | Result and limitation                                                                                                                                                                             |
| -------------------------------------------------------------------------------------------- | ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 2026-10-04 previously executed `cellsOf`/`takeCells` probe supplied to this specification    | historical failing baseline                      | Accents/ZWJ/flags split; CJK undercounted. Public table x hit mapped `e + accent + x` to byte 1 rather than 3, and flag+x to byte 4 rather than 8. Motivation for P02/X01; not post-change proof. |
| Previously executed conformance layer 0 using Unicode 17 input                               | historical failing baseline                      | 750 pass, 16 fail; Indic conjunct failures. It does not certify Unicode 18, width policy, or the owned replacement engine.                                                                        |
| Existing `analysis.d` and generator inspected on this documentation branch                   | source observation                               | Analysis consumes generated Unicode 17 normalization/folding/word properties and exposes bounded source/output/segment errors. It is not evidence of all-four-form/full-word conformance.         |
| Existing `grapheme.d`, `width.d`, `utf8.d`, and compiler-probed grapheme generator inspected | source observation                               | Production segmentation/category/replacement paths still depend on Phobos, despite existing owned validators/SIMD/conversion paths. TXT-OWN1 target remains unverified.                           |
| Unicode 18 final UCD ReadMe and stable UAX #29 revision 49 read on 2026-10-04                | source availability, not implementation evidence | Final release artifacts are reachable; actual consumed source hashes and executable target results are not recorded yet. Stale draft warning on the release index is discussed in decisions.md.   |
| Target scenarios C01–X04                                                                     | planned; unverified                              | No owned Unicode 18 implementation run, consumer cutover or manifest reproducibility run is claimed by this specification batch. Contract review is recorded separately below.                    |

Baseline counts above are supplied observations from actual earlier probes; this
page does not invent a checked commit, saved artifact URL, or repeated execution.
They are intentionally weaker than an acceptance record. Future verification entries
must identify source revision or dirty-tree snapshot, actual command and counts,
configuration/toolchain, result/artifact, covered IDs, and residual cases. Publication
checks certify links/rendering only and must be reported separately by the integrator.

## 9. Independent contract review

Separate read-only reviewer sessions on 2026-10-04 examined the owned-codec/data/
Unicode contracts and the wrapping/provider contracts, including worked success,
failure and boundary traces. They did not execute an implementation. The final
scoped rechecks found no remaining blocking contract defect in the reviewed scope.

| Finding                                                                         | Disposition                                       | Contract and falsifying trace                                                              |
| ------------------------------------------------------------------------------- | ------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Empty non-final feeds contradicted sealed/failed/pending-final state precedence | Fixed; independently rechecked                    | TXT-UTF8; C04/C05 require state validation first                                           |
| Reordered contributor maps did not define before/after boundary projection      | Fixed; independently rechecked                    | TXT-MAP4; A04 fixes cut envelopes and inverse deletion ambiguity                           |
| Global Ghostty default was not supported by the approved scope                  | Fixed during integration; independently rechecked | TXT-CELL1 and D-TXT-09 retain terminalKitty local policy, with engine-owned grids separate |
| Glue realization ignored individual provider limits                             | Fixed; independently rechecked                    | WRAP-KP3 intersects bounds and rejects the single-glue counterexample                      |
| Clamping could cause width-proportional residual iteration                      | Fixed; independently rechecked                    | WRAP-KP3 batches rounds; the billion-tick scenario preserves WRAP-WORK1                    |

This is independent specification review, not Unicode conformance, performance,
platform or consumer acceptance. Publication checks and implementation evidence
have their own gates; real font and contextual provider feasibility remain distinct.
