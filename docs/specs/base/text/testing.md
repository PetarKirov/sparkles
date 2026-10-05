---
status: draft
owner: sparkles:base
reviewed: 2026-10-05
---

# Owned text testing and evidence

## Abstract

Acceptance combines published Unicode vectors, manually derived encoding and
coordinate traces, independent raw-data checks, bounded-state exploration, and
actual consumer interactions. Default-algorithm conformance is distinct from
terminal-width interoperability: width profiles and
[scaled footprints](./SPEC.md#_6-4-scaled-grid-cell-footprints), the grid-cell blocks
that scaled text occupies, are checked against pinned terminals' cursor reports. The
scenarios are planned acceptance work: each names its oracle, and the evidence ledger
records which have run.

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
  clean-room width oracle in the conformance harness mirrors the cell-width reference and
  cannot independently validate that model's policy assumptions. A terminal/library
  disagreement is categorized as version skew, accepted width profile divergence, or bug;
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

### C04 — stream carry and absolute offsets (TXT-UTF5/7/8/15)

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

### C05 — token-atomic backpressure (TXT-UTF6/7/8/13–15)

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

### C06 — whole transaction and termination (TXT-UTF9/11/17)

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

**P01 — measure/fit identity (TXT-CELL1–4, TXT-CELL9–11).** Under narrow ambiguous
`terminalKitty`, measure `e\u0301x`, `界x`, `🇺🇸x`, and `👩‍👩‍👧‍👦x`
as 2, 3, 3, and 3 grid cells. Budgets around the first cluster's width admit or exclude
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
storage. Changing only the Unicode manifest, the width profile, or the analysis profile yields `stalePolicy`.
One-short map storage returns `workspaceFull`; sparse checkpoints and uncached results
must agree for every coordinate in the small traces.

**P05 — incremental invalidation (TXT-CACHE2).** Insert one RI at the beginning of
a long RI run and check changed pair parity throughout; insert a linker/Extend in
an Indic context; modify bidi paragraph direction. A fixed nearby rescan is not enough.
Compare accepted updated-cache maps against full rescans, including before/after
relationships and deleted spans. Unproven reuse must be rejected, not merely likely.

**P06 — terminal policy interoperability (TXT-CELL1/4–6).** Freeze real
kitty/Ghostty engine revisions, clustering/configuration assumptions, input
transcripts and cursor readings. Compare `terminalKitty` with the control-free corpus
and exercise an actual terminal surface; classify documented spacing-mark/Prepend and
emoji presentation differences as width profile differences, not Unicode segmentation
failures. Ghostty-backed consumers retain the engine's authoritative cell coordinates
instead of reconstructing them under `terminalKitty`. Missing engine/configuration
leaves interoperability evidence unmet, but does not block pure width profile and map
acceptance or make an installed engine's tables the production fallback.

**P07 — clustered layout, folded emission (TXT-CELL5, TXT-CELL9, TXT-CELL12–13).**
Under `terminalUnclustered` with narrow ambiguous width, measurement, fitting, and
hit maps equal `terminalKitty`'s for every P01 input; only emitted bytes differ.
Emit each grapheme below at the line's start, then `x`, and read a pinned XTerm's
cursor report (`CSI 6 n`), the measurement design-system D38 performs, as the
independent oracle:

- `👨‍👩‍👧` (U+1F468 U+200D U+1F469 U+200D U+1F467), advance 2: emitted as
  U+1F468 alone; `x` lands at grid cell 2. Emitting the whole cluster instead would
  put `x` at 6, which is the failure the rule prevents.
- `❤️` (U+2764 U+FE0F), advance 2: emitted as U+2764 and one space; `x` at 2.
- `⌚︎` (U+231A U+FE0E), an emoji-presentation base with VS15, advance 1: the base alone
  is 2 wide, so the replacement U+003F is emitted; `x` at 1.
- `🇺🇸`, advance 2, and a single scalar such as `界`: emitted unchanged.

Copying any of these from the grid returns the source bytes, not the folded ones.
Fitting the family into budget 1 admits nothing and never splits the cluster;
budget 2 admits it whole.

**P08 — glyph-channel set (TXT-CELL7).** Under `terminalKitty` and
`terminalUnclustered`, each with ambiguous width narrow and then wide, measure one
scalar from the start, the end, and one interior point of every listed range: for
example U+2500, U+257F, U+2588, U+2800, U+1FB00, U+1CD00, U+25CB, U+2022, U+26A0,
U+E0B0, U+F0001, and U+10FFFD. Each measures 1 under all four configurations. Under the wide ambiguous choice, the ambiguous non-set scalar U+00A7
measures 2, proving the choice is active. U+25FD measures 2 under every
configuration, and U+2714 U+FE0F measures as its width profile's ordinary rules give,
because a variation selector takes the grapheme outside the set. Changing the set
changes the width profile identity and yields `stalePolicy` from a cache built under
the earlier set.

**P09 — width profile selection (TXT-CELL1, TXT-MIG1/3).** Build maps for one source
under `terminalKitty`, then query them under `terminalUnclustered`: the cache returns
`stalePolicy`. A caller that selects `terminalUnclustered` uses it for measure, fit,
hit mapping, and emission on the same row; mixing width profiles within a row
is a failing observation. An import audit finds no per-scalar or code-point advance
helper outside a named width profile.

**P10 — scaled footprints (TXT-SIZE1–5).** With `s = 2, w = 0`, the run `abc`
has a footprint 6 grid cells wide and 2 rows high, and `界` one 4 wide and 2 high.
With `s = 3, w = 2`, any run fitting the protocol has a footprint 6 wide and 3 high.
With `s = 2, w = 0, n = 1, d = 2`, the footprint equals that of `s = 2, w = 0`.
Sizing `s = 0`, `s = 8`, `w = 8`, `n = 2, d = 2`, and `d = 16` each return
`invalidSizing`; `s = 1, w = 0, n = d = 0` measures exactly as unsized text. Fitting
`abc` at `s = 2, w = 0` into a budget of 5 grid cells admits `ab`; at `s = 2, w = 3`
it admits nothing. A hit at row 1 of the block maps to the same source positions as
row 0. The independent oracle is a pinned kitty revision's cursor report after each
escape: the cursor moves by the footprint width on the run's first row.

**X01 — table drag/copy (TXT-MIG1/2).** Use real string and widget table views with
`e\u0301x` and `🇺🇸x`. Locate the x cell and observe hit byte offsets 3 and
8; drag over the complete preceding cluster and copy exactly its original bytes.
Copy x alone and observe exactly `78`, not the final combining mark or second RI.
Repeat after wrap/clip and verify source offsets remain attached to the displayed line.
Both views must measure/render/select using one width profile.

**X02 — UI and relocated doc-view (TXT-MIG1/2).** Launch the real UI/display-list
and doc-view surfaces, fit CJK and ZWJ text into narrow rows, then select/copy from
DSV and ANSI fences. Observe no cut cluster, consistent measured/painted extent,
and correct original byte spans across escapes. A replaced document revision must
invalidate old selection caches. Text regenerated by cursor motion must be marked
non-source/adapter-generated rather than given a fabricated original span.

**X03 — TUI storage/render (TXT-CELL8, TXT-MIG1/2).** Launch an actual TUI terminal
flow under each width profile the probe can select: a terminal answering mode 2027
or measuring its test cluster as two grid cells, and one doing neither. Emit a
cluster exceeding the TUI cell's 16-byte inline storage followed by x. Observe the
same grid advance under both. Under `terminalKitty` the complete grapheme appears in
the emitted bytes; under `terminalUnclustered` the emitted bytes follow TXT-CELL12–13
exactly as for a short grapheme, never truncated because of length. Grid copy
returns the complete source grapheme under both.
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

The implemented offline command shapes are the harness entry points. Scoped
pre-rebase executions are recorded below; they do not establish acceptance of
this expanded target or constitute a final integrated rebased-tree run:

Only the manifest is tracked as raw-input metadata; the ignored inventory is a
local cache. For a cold checkout, the generator's default command fetches the
absent root, authenticates the staged inventory, and then generates:

```sh
dub run --single libs/base/tools/gen_unicode_tables.d -- \
  --out-file /tmp/unicode-tables-cold.d
```

For the commands below, first provision that cache (or use explicit `--acquire`
into an absent root). Nix provisions its immutable data separately using
manifest-driven fixed-output downloads; only the normative build/execution phase
is no-network, not missing-store-object provisioning.

```sh
# Complete required CI derivation: provisions pinned data, then executes offline.
nix build -L .#checks.x86_64-linux.text-conformance

# Official segmentation and owned algorithm corpora from authenticated inputs.
dub run --root=libs/base/tools/text-conformance --config=offline -- \
  --layers 0,11,12,13,14,15,16 --no-network \
  --manifest libs/base/tools/unicode/manifest.json \
  --ucd-dir libs/base/tools/unicode/18.0.0

# Existing correctness sweep without foreign runtime dependencies.
dub test --root=libs/base/bench/utf --compiler=ldc2 -b bench \
  -c unittest -- -i 'utf\.correctness$'

# Generator: authenticate all pinned inputs before replacing installed output.
dub run --single libs/base/tools/gen_unicode_tables.d -- \
  --no-network --manifest libs/base/tools/unicode/manifest.json \
  --ucd-dir libs/base/tools/unicode/18.0.0 --out-file /tmp/unicode-tables.d
```

The official corpus adapters do not use generated implementation tables as their
expected oracle. Delivery records executed counts, manifest identity, toolchain,
scalar/SIMD selection, and retained artifacts. Performance evidence reuses
benchmark lifecycle, corpus, setup-cost, affinity, and environment reporting;
no universal speed threshold or allocation-free claim follows from wall time.

## 8. Evidence ledger

Each row names the revision it was observed at where one was recorded. A historical
row without a recorded revision is a motivating baseline, weaker than an acceptance
record. Supplied pre-rebase owned-implementation observations cover the prior
contract subset, not newly introduced obligations or a final rebased-tree snapshot.

| Evidence                                                                                            | Revision                                                                                                 | Classification                                              | Result and limitation                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| --------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Pre-cutover scalar-cell measurement/truncation probe through the public table                       | before `9db961a35`; commit not recorded; supplied 2026-10-04                                             | historical failing baseline                                 | The former cellsOf/takeCells paths split accents/ZWJ/flags and undercounted CJK. The table's x hit mapped `e + accent + x` to byte 1 rather than 3, and flag+x to byte 4 rather than 8. Motivates P02/X01; not post-change proof or a citation of a current API.                                                                                                                                                                                                                                    |
| Conformance layer 0 with Unicode 17 input                                                           | before `9db961a35`; commit not recorded                                                                  | historical failing baseline                                 | 750 pass, 16 fail; Indic conjunct failures. Certifies neither Unicode 18, a width profile, nor the owned engine.                                                                                                                                                                                                                                                                                                                                                                                    |
| `analysis.d` and `gen_unicode_tables.d` read                                                        | `9db961a35`                                                                                              | historical source observation                               | Analysis then consumed generated Unicode 17 normalization/folding/word properties and exposed bounded source/output/segment errors. Not evidence of all-four-form or full-word conformance, or a description of the current owned runtime.                                                                                                                                                                                                                                                          |
| Pre-cutover segmentation, width, decoding, and compiler-probed grapheme-generator source inspection | `9db961a35`                                                                                              | historical source observation                               | Segmentation, category, and replacement paths then depended on Phobos beside owned validators, SIMD, and conversion paths; `unclusteredWidth` computed the per-scalar advance outside any width profile. The separate gen_grapheme_tables.d generator was subsequently removed. TXT-OWN1 and TXT-MIG3 were unverified at that revision; this records the baseline, not the current owned runtime or a citation of a current generator.                                                              |
| Unicode 18 final UCD ReadMe and UAX #29 revision 49 read                                            | external; read 2026-10-04                                                                                | historical source availability, not implementation evidence | Final release artifacts were reachable; consumed source hashes were not recorded at that observation. The release index's stale draft warning is discussed in decisions.md (D-TXT-02). Current manifest authentication and executed corpus observations are recorded below.                                                                                                                                                                                                                         |
| Owned-codec/grapheme/width modules and published pre-rebase base package                            | `b11d4eaf6` for full LDC base; initial feature-module snapshot not recorded                              | observed revision-scoped execution                          | Five feature modules passed initially. The ownership-copy assertion was subsequently fixed: full LDC base passed 685 runtime tests and one CTFE test, including `unique.move.transfersSoleOwnership`. This is not a full rebased-tree result or proof of the expanded width contract.                                                                                                                                                                                                               |
| Official grapheme corpus and independent streaming smoke                                            | pre-rebase execution; exact snapshot not recorded                                                        | observed scoped execution                                   | 853 records and all 6,163 single-byte split positions passed. This does not certify every consumer.                                                                                                                                                                                                                                                                                                                                                                                                 |
| Integrated official Unicode 18 CLI layers 11–16                                                     | pre-rebase execution; exact snapshot not recorded                                                        | observed scoped execution                                   | 16,974 word and 4,734 sentence UTF-32/UTF-8 endpoints; 80,131 line boundaries; 861,948 bidi direction cases; 4,783,064 normalization checks; 11,120,810 simple/full casing checks. Zero divergences. These are algorithm results for the prior contract subset, not complete scenario acceptance.                                                                                                                                                                                                   |
| Offline LDC/DMD generator runs                                                                      | pre-rebase execution; exact snapshot not recorded                                                        | observed reproducibility                                    | Identical canonical output SHA-256 `9d05e431a3fd34e0b87c6eaaca3fd1bb467ecb2c2d26322aa1c37357dc2fba51`; pinned manifest `df3659783f974cb439f4f6436dc4e72f0d06313a45b865c04921dba1d938abcc`.                                                                                                                                                                                                                                                                                                          |
| Required offline Unicode CI derivation                                                              | pre-rebase integration plus fetched-input provisioning; observed 2026-10-05; exact snapshot not recorded | observed integrated execution                               | `nix build --no-link --print-build-logs .#checks.x86_64-linux.text-conformance` succeeded with LDC 1.42, checked build, and sandboxed `--no-network` execution. All 35 inputs were provisioned by manifest-pinned fixed-output downloads, not tracked corpus files. Layers 0/11/12/13/14/15/16 passed 853/16,974/4,734/80,131/861,948/4,783,064/11,120,810 checks with zero known/new divergences. Retained check output and `nix log` are the gate's artifacts; CI job/fan-in wiring is unchanged. |
| Generation-time acquisition and offline refusal                                                     | pre-rebase execution; observed 2026-10-05; exact snapshot not recorded                                   | observed scoped execution                                   | A cold absent inventory was fetched and authenticated, then generated byte-identical committed tables; warm `--no-network` generation produced identical bytes. A tampered existing input failed SHA-256 authentication without replacing the protected output. Missing offline input and contradictory `--acquire --no-network` both failed without creating an inventory.                                                                                                                         |
| Typed source-map and analyzer/fuzzy witness smokes                                                  | pre-rebase execution; exact snapshot not recorded                                                        | observed scoped execution                                   | Map boundary/interior, affinity, stale/reuse/exhaustion and exact contributor cases passed. Reordered fuzzy highlighting retained `[0,1)` and `[3,6)`, excluding the unrelated mark.                                                                                                                                                                                                                                                                                                                |
| Fuzzy and DQL consumer runtime                                                                      | pre-rebase execution; exact snapshot not recorded                                                        | observed scoped execution                                   | Fuzzy 42 tests, complete-keystroke allocation audit 43 tests, and DQL 37 tests plus one CTFE passed. Valid final-unit capacity queries and exact witnesses passed; retained DQL query sources survived later pool growth.                                                                                                                                                                                                                                                                           |
| Real V8 document and fixture consumers                                                              | pre-rebase execution; exact snapshot not recorded                                                        | observed scoped execution                                   | Immutable BMP/supplementary source snapshot survived on-disk replacement before coverage attachment; selected UTF-16 offsets mapped to original byte spans. Real fixture CLI corrected a decoded-scalar search index to a byte index and roundtripped through ingest.                                                                                                                                                                                                                               |
| Optimized fuzzy bounded-cost comparison                                                             | pre-rebase execution; exact snapshot not recorded                                                        | observed scoped execution                                   | Same LDC `-O3 -mcpu=native`, assertions live, 32 samples and 10 ms minimum sample window. Complete keystroke median increased from about 6 µs to 19 µs; matcher storage increased from 791,840 to 13,721,976 bytes. This is a measured correctness/provenance cost, not a speed improvement.                                                                                                                                                                                                        |
| Scenarios C01–C10, D01–D06, G01–G05, A01–A06, P01–P10, X01–X04                                      | final integrated snapshot not recorded                                                                   | gate: full acceptance unverified                            | Scoped owned Unicode 18, manifest reproducibility and consumer results above are retained, but do not establish every scenario, final consumer cutover, or complete M6 and wrapping/layout/GUI acceptance. No implementation evidence is recorded for the newly added width-profile, glyph-channel, overflow-storage, and scaled-footprint obligations (TXT-CELL4–13, TXT-SIZE1–5, TXT-MIG3; P07–P10/X03). Their implementation and independent-review gates remain open.                           |

A verification entry **must** name the source revision or dirty-tree snapshot, the
command and discovered/executed counts, configuration and toolchain, the result or
artifact, the covered IDs, and residual cases. Publication checks certify links and
rendering only and are a separate gate from every row above.

The retired `cellsOf`/`takeCells` names belong to the historical first-row probe,
not live source-symbol evidence. Observations above are supplied execution
records; this documentation edit did not rerun them. Commands, artifacts and
final integrated snapshot provenance remain the integrator's acceptance record.

## 9. Independent contract review

Read-only reviewers examined the owned-codec, data, and Unicode contracts and the
wrapping/provider contracts as committed in `9db961a35`, including the worked success, failure and
boundary traces, without executing an implementation. The scoped rechecks found no
remaining blocking contract defect in that scope.

| Finding                                                                         | Disposition                    | Contract and falsifying trace                                                              |
| ------------------------------------------------------------------------------- | ------------------------------ | ------------------------------------------------------------------------------------------ |
| Empty non-final feeds contradicted sealed/failed/pending-final state precedence | Fixed; independently rechecked | TXT-UTF8 and TXT-UTF15; C04/C05 require state validation first                             |
| Reordered contributor maps did not define before/after boundary projection      | Fixed; independently rechecked | TXT-MAP4–7; A04 fixes cut envelopes and inverse deletion ambiguity                         |
| A global Ghostty default was not supported by the approved scope                | Fixed; independently rechecked | TXT-CELL1 and D-TXT-09 retain `terminalKitty` as default, with engine-owned grids separate |
| Glue realization ignored individual provider limits                             | Fixed; independently rechecked | WRAP-KP3 intersects bounds and rejects the single-glue counterexample                      |
| Clamping could cause width-proportional residual iteration                      | Fixed; independently rechecked | WRAP-KP6 batches rounds; the billion-tick scenario preserves WRAP-WORK1                    |

**Gate: review of the width profile, glyph-channel, overflow-storage, and
scaled-footprint requirements.** TXT-CELL4–13, TXT-SIZE1–5, and TXT-MIG3 were
written after that review and have not been reviewed independently. The gate closes
when a reviewer walks P07–P10 and X03 against them and their dispositions are added
to the table above.

This is independent specification review, not Unicode conformance, performance,
platform or consumer acceptance. Publication checks and implementation evidence
have their own gates; real font and contextual provider feasibility remain distinct.

## 10. Wrapping scenarios and evidence

The normative acceptance obligations of wrapping (WRAP-TEST1–5) live in
[wrapping.md](./wrapping.md); this section holds the scenarios, worked traces, and
evidence that satisfy them.

### 10.1 Permanent observable scenarios

These scenarios for the [wrapping contract](./wrapping.md) are planned tests, not
named test symbols.

| Requirements                            | Stimulus and boundary                                                                                                    | Required observation                                                                                                                                           |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `WRAP-OPP1`, `WRAP-OPP2`                | Release-pinned UAX #14 vectors, grapheme intersection, CRLF split between source chunks                                  | Correct default opportunity classes, no interior-cluster soft break, one consumed CRLF break                                                                   |
| `WRAP-POL1–6`                           | Empty source, `a\n\n`, bounded zero, protected NBSP unit, overwide single CJK cluster, indent wider than capacity        | One initial empty line; three lines for `a\n\n`; explicit progress/overfull/rejection results; no repeated indent-only soft lines                              |
| `WRAP-PLAN1–3`, `WRAP-MAP1`             | Collapse `a  b`, take a soft hyphen, expand a tab, insert indent                                                         | Copy-original exactly matches original bytes; rendered-copy matches chosen fragments; omitted/replaced/synthetic provenance stays distinct                     |
| `WRAP-CELL1`, `WRAP-TAB1`               | `a\tb` with interval 4 at start column 0; repeat at start column 1; wrap into a continuation with two-cell indent        | First tab advances 3, second advances 2; continuation recomputes from its actual indent, never reuses previous-line width                                      |
| `WRAP-FIT1`, `WRAP-MAP1`                | `e` + combining acute + `x`, flag + `x`, ZWJ family + `x`; fit or hit at cluster edges/interior cells                    | Whole-cluster fitting; `x` maps to byte 3 after accented `e`, byte 8 after a two-RI flag; before/after selects the proper side of a soft wrap                  |
| `WRAP-CELL4`                            | The same source wrapped under `terminalKitty` and `terminalUnclustered`; a box-drawing and a Private Use Area scalar     | Identical line ends under both width profiles; glyph-channel scalars advance one grid cell under both                                                          |
| `WRAP-GREEDY1`, `WRAP-MEASURE2`         | Candidate endpoints with whole widths 4, 7, 5 at capacity 5, no monotonicity capability                                  | Greedy selects the third endpoint; the failed second does not terminate scanning                                                                               |
| `WRAP-BAL1`                             | Rigid `aaa bb cc ddddd`, collapse spaces, capacity 6, last line free                                                     | Greedy gives `aaa bb` / `cc` / `ddddd`; exact balanced gives `aaa` / `bb cc` / `ddddd` with squared-slack cost 10 instead of 16                                |
| `WRAP-BAL1`, `WRAP-DP1`                 | Same source endpoint reached on different line counts; geometry capacities alternate 4 and 7                             | Exhaustive minimum preserved; no endpoint-only merge loses the geometry-dependent winner                                                                       |
| `WRAP-MEASURE1–3`                       | Provider reports widths of separate pieces whose sum differs from whole candidate; ending hyphen changes context         | Exact whole-candidate result selects lines; forbidden prefix-sum shortcut is falsified; selected descriptor emits that same advance                            |
| `WRAP-KP1–5`                            | `N=8,T=10,S=4` in raw integral units, optional penalty 3, linePenalty 10                                                 | Ratio 1/2, badness 13, decent fitness, demerit 538 before adjacency terms; realized glue reaches 10                                                            |
| `WRAP-KP1–5`                            | Shrink ratio exactly -1 and just below -1; stretch exactly tolerance and just above; zero capacity; negative penalty     | Boundary feasibility matches exact rationals; signed penalty subtraction and objective ordering match oracle                                                   |
| `WRAP-MEASURE1`, `WRAP-KP3`, `WRAP-KP7` | One glue: natural 1, stretch 4, shrink 0, provider maximum 2, tolerance 1, target 4                                      | Aggregate ratio 3/4 does not admit a width-4 realization; intersection/residual feasibility rejects the candidate without publishing output                    |
| `WRAP-KP6`, `WRAP-WORK1`                | Two glues: natural 1 each, stretch M/1, shrink 0, individual maxima 1/M+1, tolerance M, target M+2, with M=1,000,000,000 | Exact realized widths 1 and M+1; allocation uses at most 64 record scans plus final pass, not M-1 tick iterations; input/state/record work bound remains valid |
| `WRAP-KP2`, `WRAP-DP1`                  | Two paths at one endpoint with different fitness/flag and pre/post alternatives; cheaper prefix has expensive successor  | Full-path optimum beats endpoint-only minimum; consecutive and terminal discretionary costs occur on the declared transitions                                  |
| `WRAP-UNIT1–3`, `WRAP-BAL1`, `WRAP-KP2` | Raw signed-64 extremes, half-tick conversions, accumulation past cost capacity                                           | Ties-to-even or precise arithmetic error; no saturated tie, device-dependent break, or implicit cells/points conversion                                        |
| `WRAP-API1–3`, `WRAP-MEASURE4`          | Fill output/old plan with sentinels; inject failure on each callback ordinal; exact-sized output and one byte short      | Failed operation leaves sentinels/old plan/outExtent unchanged; successful output has exact byte count; unused suffix unchanged                                |
| `WRAP-BUDGET1–4`                        | Budgets zero, exact-needed, and one below; complete approximate incumbent after prune; no incumbent                      | Exact success only with full search; exact exhaustion is uncommitted; approximate result labeled; no-incumbent exhaustion is failure                           |
| `WRAP-ANSI1`, `WRAP-STYLE1`             | SGR between base/accent, OSC 8 inside a flag or ZWJ sequence, active style at chosen wrap                                | Same text clusters/lines as unstyled content; authored style boundaries survive; link/SGR suspension and resumption match stored snapshots                     |
| `WRAP-ANSI2`                            | CSI cursor move, erase, mode change, image/query; incomplete CSI/OSC; oversized URI                                      | Exact offending range and declared error; no terminal side effect, hidden stripping, truncated resource, or committed bytes                                    |
| `WRAP-HYP1–4`                           | Overlapping odd/even pattern weights, explicit exception, lookup casing expansion, source cluster with many marks        | Max-weight/exception rules and whole-source-boundary filtering; no length-subtraction offset; budget failure distinct from no candidates                       |
| `WRAP-MIG1–2`                           | Real plain/rich UI and both table views with accents, flags, CJK, tabs, wrapped no-break spans and synthetic icons       | Matching sizing/paint advance/line ends; click/selection/copy identify correct original bytes; icons/borders never become source                               |
| `WRAP-ALT1–3`                           | Exhaustively enumerate a tiny graph; constrain exact line count; request top 1, top 2, all; repeat with two geometries   | Ranked prefixes equal oracle, no endpoint-only loss of second-best path, explicit exhaustive/more status, no-result constraint distinct from exhaustion        |

The hand-derived Knuth–Plass example uses `ceil(100*(1/2)^3)=13` and
`(10+13)^2+3^2=538`. It is an explanatory expected result, not an executed probe.
The balanced example excludes the final line's slack and counts no overfull or
emergency choices. Tests derive those observations independently (WRAP-TEST3).
The `WRAP-CELL4` row asserts only that wrapping follows the width profile; the exact
advances come from P01, P07, and P08.

### 10.2 Worked cell traces

These are author-derived review inputs, not executed implementation evidence or
independent acceptance. They bind the cell operation's success, failure, and
boundary behavior to specific byte/source observations.

**Success — formatting inside a cluster.** Use source `e\x1b[31ḿx`, width
`bounded(1)`, empty indents, strict UTF/formatting, the `terminalKitty` width
profile, `graphemeEmergency`, `suspendResume`, and `restoreInitialState`. Source
byte ranges are `e` at `[0,1)`, SGR at `[1,6)`, acute at `[6,8)`, and `x` at
`[8,9)`. The `e`/acute cluster consumes `[0,8)` including internal formatting; it is
not broken at the SGR. The second line's `x` consumes `[8,9)`. Each line advances
one grid cell, neither is overfull, and the soft break is anchored at byte 8 with
before/after on the two lines.

The rendered bytes are `e\x1b[31ḿ\x1b[0m\n\x1b[31mx\x1b[0m`: 23 bytes. The
boundary snapshot is red; the newline is neutral; the final state is the initial
default. The original-copy traversal is the nine original bytes, without synthetic
resets, resumption, or newline. A 23-byte output slice succeeds; a 22-byte slice
returns `needOutput(23)` with all bytes and `outExtent` unchanged. Splitting the
logical view after byte 7 gives the same result, despite dividing the acute's UTF-8
encoding between chunks.

**Failure — style state cannot be committed early.** Start with a published plan and
unrelated output-storage sentinels. For the same source, the callback consuming SGR
`[1,6)` returns caller error 17 while deriving its output snapshot. Planning reports
the style phase, that source range, and error 17. The old plan, its storage, the
publication variable, and the caller's initial style snapshot remain unchanged; no
newline, reset, or text has reached a sink. The scratch prefix is unusable. Changing
that callback to success and retrying on the same immutable source can produce the
success trace; base does not retry it automatically.

**Boundary — capacity is zero, not "no wrap."** Use source `世\n`, `bounded(0)`,
empty indents, preserve whitespace, and `graphemeEmergency`. The three-byte CJK
cluster is indivisible, advances two grid cells under the width profile's wide rule,
and occupies one overfull line. The following LF is a consumed mandatory separator,
and the final line is empty with zero advance. The result has two lines, not a
sequence of empty soft-break lines and not an unbounded line. With `reject`, the
same source returns `unbreakableOverflow([0,3))` and publishes nothing. An
`unbounded` request remains distinct and still retains the LF/final-empty-line
convention.

**Boundary — the cluster is not the scratch capacity.** Replace the accented cluster
in the success trace with a base followed by 1000 combining marks and place a
chunk/style boundary inside it. With enough byte/record budget the plan still has one
whole first cluster, not groups of 16 or 32. With insufficient scratch the result is
the explicit uncommitted capacity failure, not a different segmentation or a
shortened copied source.

### 10.3 Wrapping evidence ledger

The shared Unicode prerequisite and historical defect baselines are in §8; they are
not implementation proof for wrapping. Entries follow §8's rule for what a
verification entry names; budget or arithmetic failures do not count as successful
exact solves, and a missing font provider, unavailable dictionary, skipped driver,
or pending review leaves its gate unmet.

| Evidence                                  | Revision                              | Classification       | Result and remaining gate                                                                                                        |
| ----------------------------------------- | ------------------------------------- | -------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| Base, UI, and table wrapping modules read | `9db961a35`                           | source observation   | The integration baseline in PLAN.md §6.1. No runtime conformance follows from reading source.                                    |
| Wrapping/provider contract review         | contracts as committed in `9db961a35` | specification review | Findings and rechecks in §9. Requirements restructured since then (WRAP-KP6/KP7, WRAP-POL1–6, WRAP-CELL4) await re-review.       |
| Wrapping scenarios in §10.1 and §10.2     | none                                  | gate: unverified     | No implementation run is recorded. Permanent scenarios, real drivers, consumer migration, and shaped-provider acceptance remain. |
