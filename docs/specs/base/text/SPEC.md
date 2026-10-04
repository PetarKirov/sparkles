---
status: draft
owner: sparkles:base
reviewed: 2026-10-04
---

# Owned UTF, Unicode, and cell text

## Abstract

`sparkles:base` supplies allocation-free encoding primitives, reproducible Unicode
properties and algorithms, and source-preserving terminal-cell text operations.
Consumers can validate hostile input, replace malformed sequences for display, or
preserve malformed bytes for analysis without inheriting compiler Unicode tables.
Segmentation has no artificial cluster-length limit. Explicit coordinates and
provenance connect original bytes, transformed text, UTF-16 integrations, and cell
positions. Fonts, shaping, graphical text layout, and publication remain separate
owners of their respective contracts.

## Introduction

Text crosses several boundaries before it becomes visible: a file contains bytes,
a platform API accepts UTF-16, search normalizes and folds, and a terminal places
clusters in cells. Treating any two of those coordinate systems as interchangeable
produces plausible ASCII output but broken selection, clipping, and diagnostics.
Long combining sequences and malformed external bytes make such mistakes observable
without exotic fonts or a graphical host.

The foundation uses one owned decoding model and one pinned Unicode release.
Algorithms consume explicit scalar or opaque-byte units and retain source spans;
terminal consumers apply a named cell policy rather than counting bytes or code
points. Bounded caller storage can reject an operation, but it cannot redefine a
Unicode boundary to make the input fit.

This specification owns encoding, property data, Unicode algorithms, plain-cell
measurement, and logical coordinate maps. [Wrapping](./wrapping.md) owns line
selection, virtual indentation, tabs, line-relative maps, generic paragraph solvers,
and the physical `LayoutUnit` contract. [Font](../../font/SPEC.md) owns font resources,
matching, fallback, shaping, and rasterization. [Text layout](../../text-layout/SPEC.md)
owns contextual paragraph composition and visual caret geometry above base and font.
Locale dictionaries, collation, language-specific hyphenation, font-dependent widths,
page construction, and document import/export are not base Unicode algorithms.

[The delivery plan](./PLAN.md) is the sole milestone tracker.
[Testing and evidence](./testing.md) defines falsifying scenarios and distinguishes
historical measurements from target conformance. [Decisions](./decisions.md) records
scope approval and consequential trade-offs. The [existing cell specification](./index.md)
records the delivered policy, not completion of this target.

## Contract at a glance

1. Production text semantics depend on owned code and one Unicode 18.0.0 manifest,
   not `std.utf`, `std.uni`, their transitive auto-decoding, or runtime downloads.
2. Strict rejection, maximal-subpart replacement, and opaque-byte preservation are
   distinct operations; malformed external input is never a programmer assertion.
3. Whole bounded conversion commits only after validation, sizing, and alias checks.
   Incremental conversion commits complete output tokens and reports exact progress.
4. Default Unicode segmentation is complete and has no 16- or 32-code-point cap.
   Storage exhaustion is not a boundary or a truncated successful result.
5. Source bytes, Unicode scalars, UTF-16 code units, graphemes, cells, and physical
   layout units are different coordinate types. Ambiguous mapping requires affinity.
6. Borrowed views and caches carry source identity, revision, and policy identity;
   mutation invalidates them before reuse.

## 1. Scope, vocabulary, and ownership

Normative **must**, **must not**, and **may** carry [BCP 14](https://www.rfc-editor.org/info/bcp14)
meanings. Requirement IDs beginning `TXT-` belong to this page. API names described
as **proposed** specify an operation shape, not an existing public symbol; concrete
D naming is settled in the implementing slice without weakening the operation.

A _scalar_ is a Unicode scalar value, excluding surrogates. A _source span_ is a
half-open interval in the immutable input's code-unit coordinates. A _token_ is one
successfully decoded scalar, one replacement together with the malformed source
span it consumed, or one explicitly tagged opaque source byte. _Before_ and _after_
are logical-source affinities, not visual left and right. A _source revision_ is a
caller-supplied identity that changes whenever contents or interpretation change.

**TXT-OWN1: Owned semantics.** Production base text algorithms **must not** call
`std.utf`, `std.uni`, compiler-derived Unicode probes, or range operations that
implicitly auto-decode through them. ASCII-only byte routines **must** use explicit
code-unit iteration; independent foreign or Phobos comparisons **may** remain in
test-only or benchmark-only code and **must not** compute normative expectations.

**TXT-OWN2: Dependency direction.** Base text **must** remain usable without fonts,
UI, terminal engines, networking, or a host event loop. Font and text-layout consumers
**must** use these owned encoding/property/source contracts rather than establish a
second owning Unicode implementation; terminal interoperability engines belong to
verification, not production dependencies.

**TXT-OWN3: Execution parity.** Scalar and accelerated paths **must** return the
same output, statuses, offsets, and commit effects on identical inputs. Owned
primitives **must** support `@safe pure nothrow @nogc` where their borrowed input/output
contract permits it, and **must** retain a scalar implementation on unsupported
architectures and at CTFE; acceleration **must not** require readable padding.

## 2. Encoding operations and progress

### 2.1 Input domains and modes

UTF-8 inputs are bytes. UTF-16 inputs are 16-bit code units, not a byte stream with
implicit endianness. UTF-32 inputs are 32-bit values. UTF-16LE/BE serialization and
BOM detection are explicit adapter operations; these core conversions neither strip
nor insert a BOM. U+0000, noncharacters, and unassigned scalars are valid Unicode
encoding input. Protocols that forbid them own that validation separately.

**TXT-UTF1: Strict scalar validity.** Validation and strict decoding **must** accept
exactly the well-formed encodings in Unicode 18 chapter 3, including UTF-8 shortest
forms and UTF-16 surrogate pairing. A failure **must** identify the first code unit
of the first ill-formed token in source units; overlong forms, surrogate scalars,
values above U+10FFFF, and truncated final sequences **must** fail.

**TXT-UTF2: Replacement policy.** Replacement decoding **must** emit one U+FFFD per
Unicode maximal subpart of an ill-formed sequence, as defined in
[Unicode 18 §3.9.6, D93b](https://www.unicode.org/versions/Unicode18.0.0/core-spec/chapter-3/#G66453).
It **must** retain the exact consumed source span and
**must not** absorb a following independently valid token. Replacement is not one
replacement per arbitrary parser error and is not one replacement per byte.

For UTF-8, `E1 80 41` yields U+FFFD for `[0,2)` then `A`; final `F0 90 80`
yields one U+FFFD for `[0,3)`. `ED A0 80` yields three replacements: neither
`ED A0` nor `A0 80` is a prefix of a well-formed UTF-8 scalar. A lone UTF-16
surrogate and an invalid UTF-32 value each yield one replacement per code unit.

**TXT-UTF3: Opaque byte analysis.** Opaque decoding of UTF-8 **must** consume a
well-formed scalar as one token and otherwise consume exactly one byte as a tagged
opaque token with its original value and span. Opaque tokens **must not** masquerade
as scalars or be accepted by a Unicode scalar encoder; an explicit raw reconstruction
operation **must** restore their bytes exactly, while cross-encoding conversion
**must** reject them as `opaqueNotEncodable` without committing that token.

**TXT-UTF4: Encoding.** Encoding a scalar to UTF-8, UTF-16, or UTF-32 **must** emit
the unique well-formed representation. Strict encoding of a non-scalar **must**
return `invalidScalar`; explicit replacement encoding **must** encode U+FFFD.
One-token encoding **must** check capacity before writing, return the exact required
code-unit count, and leave the entire destination unchanged on failure.

Opaque mode is intentionally byte-specific, matching the existing analysis use
case. Surrogate-preserving WTF-8, CESU-8, modified UTF-8, and opaque UTF-16 modes
are outside this contract; JNI adapters must not accidentally interpret modified
UTF-8 as ordinary UTF-8.

### 2.2 Prefix and stream operations

Proposed `decodePrefix` and `convertPrefix` take a source slice, mode, and `final`
flag. Prefix operations retain no hidden carry: `consumed` counts only committed
source code units; a potentially valid incomplete suffix remains borrowed and
unconsumed. Proposed stream operations add caller-owned state that retains at most
three UTF-8 bytes or one UTF-16 high surrogate. They accept arbitrarily divided
chunks without requiring the caller to join them.

Every incremental result contains a status, source units consumed from this call,
destination units written, stream-global offset of the blocking token where relevant,
and its required output units when known. Stream-global offsets are checked integer
counts, not pointer differences. Strict errors expose encoding and reason without
copying input bytes into diagnostics.

| Status           | Meaning and next action                                                                                                                                                                              |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ok`             | A one-token operation committed a token.                                                                                                                                                             |
| `end`            | Final input is completely consumed; the stream is finalized.                                                                                                                                         |
| `needInput`      | Non-final supplied input is exhausted or ends in a potentially valid incomplete token; provide input or finalize.                                                                                    |
| `outputFull`     | The next complete output token cannot fit; retry with capacity.                                                                                                                                      |
| `invalid`        | A token is not accepted in the chosen mode; reason distinguishes malformed encoding, invalid scalar, or `opaqueNotEncodable`. Stateless calls may choose another mode; failed streams require reset. |
| `overflow`       | A size or global-offset count is not representable; no wraparound.                                                                                                                                   |
| `overlap`        | Conversion source and destination overlap; no input/output/state progress.                                                                                                                           |
| `invalidOptions` | The operation's mode/encoding combination is unsupported; no progress.                                                                                                                               |
| `invalidState`   | A finalized/failed stream was fed without reset or a pending final feed was changed to non-final; no progress.                                                                                       |

`outputFull` is not a general request for more input. A prefix with an incomplete
suffix reports `needInput` even if the destination is full: no complete output token
is yet available. Definite invalidity is detected before output capacity, so strict
`C0` is `invalid`, not `outputFull`, even with zero destination capacity.

**TXT-UTF5: Incomplete versus invalid.** At non-final end, a suffix that can still
become a well-formed token **must** report `needInput`, not invalidity or replacement.
A suffix already excluded by the encoding constraints **must** be resolved immediately
according to mode. At final end, an incomplete suffix **must** be strict-invalid or
be replaced according to TXT-UTF2; a final empty input with no retained suffix **must**
return `end`.

**TXT-UTF6: Incremental commit.** Prefix and stream conversion **must** commit only
complete encoded tokens, with no half surrogate pair or half UTF-8 representation.
On `outputFull` or an invalid token, earlier tokens remain committed but the blocking
token **must** remain unconsumed and unwritten; state and retained carry for that token
**must** remain retryable on `outputFull`. Reported progress **must** describe exactly
those effects, and unused destination bytes/code units **must** remain unchanged.
Invalid options and overlap **must** be rejected before progress, without failing
an otherwise usable stream; a rejected token **must** fail a stream, with its
structured reason retained. Once a stream accepts `final=true`, subsequent retries
**must** retain that final intent until `end` or failure; retracting it **must**
return `invalidState` without changing the pending-final state.

**TXT-UTF7: Carry ownership.** A stream **must** copy only its bounded incomplete
encoding suffix into caller-owned state; input slices otherwise remain borrowed only
for the duration of the call. Consumed counts **must** include newly retained units,
whereas a blocking token completed from carry and a new chunk **must not** consume
new chunk units until it commits; absolute error offsets **must** still point to
that token's original start.

**TXT-UTF8: Finalization and reset.** `end` **must** seal a stream; strict-invalid
and overflow **must** mark it failed. Feeding either state **must** return
`invalidState` without input/output changes. Explicit reset **must** discard carry,
zero offsets, and restore the selected initial mode. Retrying `outputFull` with the
same unconsumed input and final flag **must** produce the same token as uninterrupted
execution. State validation and pending-final validation **must** precede empty-input
handling. An empty non-final feed **must** return `needInput` without state changes
only for an active stream with no pending final intent; finalized, failed, or
pending-final streams instead return the applicable `invalidState`.

### 2.3 Whole bounded conversion

Proposed `measureConversion` returns the exact payload and optional terminator
capacity without writing. Proposed whole `convert` validates and measures the full
source before writing into caller-provided storage. Existing `utf8ToUtf16`,
`utf16ToUtf8`, and their `z` forms already provide an analogous transactional seam;
this contract extends that seam rather than inventing a second conversion family.

**TXT-UTF9: Transactional conversion.** Whole conversion **must** leave destination
and published result state byte-for-byte unchanged on malformed input, embedded-NUL
rejection, unsupported opaque output, count overflow, overlapping buffers, or
insufficient capacity. Success **must** write only the payload and requested
terminator, return payload length excluding that terminator, and preserve the unused
suffix. Source validation **must** precede capacity rejection so an empty destination
does not hide malformed source.

**TXT-UTF10: Aliasing and lifetimes.** Any overlap between conversion source and
destination storage **must** return `overlap` before decoding/writing, including
cross-element-type overlap. Zero-length slices cover no storage. Exact in-place
conversion is not supported; caller-supplied disjoint scratch is the escape hatch.
Inputs and destination ownership **must** remain with the caller, and results **must
not** retain either buffer past its stated borrowed lifetime.

**TXT-UTF11: Counts and terminators.** Required capacity **must** include a requested
terminator using checked arithmetic. Ordinary conversion **must** preserve embedded
U+0000; `z` conversion **must** reject the first embedded U+0000 at its source offset
before checking capacity, and **must** append exactly one zero code unit on success.
An unrepresentable required capacity **must** return `overflow`, not an estimated
size or `insufficientSpace` with a wrapped count.

For whole conversion, validation order is options, overlap, first source defect
(including embedded NUL for `z`), measurement overflow, then capacity. A source
encoding defect or forbidden NUL at the earlier source token wins over a later one.
Successful measurement does not permit source mutation before conversion: borrowed
source contents must remain stable for the full operation.

**TXT-UTF12: Memory and work bounds.** Encoding and prefix operations **must** use
constant internal storage and linear work in consumed source units; whole conversion
**may** make validation/sizing and emission passes, but **must not** allocate a copy
of the source. SIMD reads/writes **must** stay within the exact supplied slices,
including unaligned, guard-page-adjacent, empty, and one-unit-tail buffers.

## 3. One reproducible Unicode data pipeline

The normative release is [Unicode 18.0.0](https://www.unicode.org/versions/Unicode18.0.0/).
These exact algorithm editions, not a moving `latest` page, are part of the target:

| Contract                            | Authority                                                                                   |
| ----------------------------------- | ------------------------------------------------------------------------------------------- |
| Encoding/scalar/casing conformance  | [Unicode 18 chapter 3](https://www.unicode.org/versions/Unicode18.0.0/core-spec/chapter-3/) |
| Bidirectional algorithm             | [UAX #9 revision 52](https://www.unicode.org/reports/tr9/tr9-52.html)                       |
| East Asian width properties         | [UAX #11 revision 46](https://www.unicode.org/reports/tr11/tr11-46.html)                    |
| Default line-break opportunities    | [UAX #14 revision 57](https://www.unicode.org/reports/tr14/tr14-57.html)                    |
| Normalization                       | [UAX #15 revision 58](https://www.unicode.org/reports/tr15/tr15-58.html)                    |
| Grapheme, word, sentence boundaries | [UAX #29 revision 49](https://www.unicode.org/reports/tr29/tr29-49.html)                    |
| Property parsing and defaults       | [UAX #44 revision 38](https://www.unicode.org/reports/tr44/tr44-38.html)                    |
| Emoji data and presentation         | [UTS #51 revision 31](https://www.unicode.org/reports/tr51/tr51-31.html)                    |

**TXT-DATA1: Immutable manifest.** The generator **must** accept only a reviewed
manifest containing release, exact algorithm revisions, source URLs, SHA-256 of
every consumed source and test artifact, generator revision, and generated schema
revision. Production tables and their exposed identity **must** identify that
manifest; mixing property versions or falling back to compiler tables **must** fail
rather than emit plausible output.

The source inventory includes UnicodeData, DerivedCoreProperties including InCB,
PropList, PropertyValueAliases, GraphemeBreakProperty, WordBreakProperty,
SentenceBreakProperty, LineBreak, EastAsianWidth, DerivedNormalizationProps,
CompositionExclusions, CaseFolding, SpecialCasing, Scripts, ScriptExtensions,
ArabicShaping, BidiBrackets, BidiMirroring, extracted DerivedBidiClass, emoji-data,
emoji-variation-sequences, and RGI emoji sequence/test inputs. Some are prerequisites
for font consumers, not extra base algorithms. Conformance artifacts include all
break tests, NormalizationTest, BidiTest, and BidiCharacterTest from the same release.
The manifest names actual relative paths under [the versioned UCD](https://www.unicode.org/Public/18.0.0/ucd/)
and [emoji data](https://www.unicode.org/Public/18.0.0/emoji/), not flattened ambiguous
basenames. A byte hash is recorded only after fetching those bytes; this document
does not invent manifest hash values.

**TXT-DATA2: Independent generation.** The owned parser **must** interpret property
ranges, aliases, `@missing` defaults, UnicodeData First/Last pairs, explicit mappings,
and algorithmic Hangul from the pinned artifacts. It **must** reject conflicting
ranges, malformed fields, unknown required properties, missing files, and bad hashes
before replacing any generated output. Generator semantics **must not** depend on
`std.uni`, `std.utf`, compiler Unicode categories, or compiler grapheme probes.

**TXT-DATA3: Reproducibility and atomic output.** With the same manifest and inputs,
generation **must** produce byte-identical artifacts across supported compilers and
host locales, without timestamp, absolute-path, or iteration-order differences.
Offline generation **must** perform no network request. Download/update is an explicit
build-tool operation; failure **must** leave checked-in generated output unchanged.
Runtime and consumer compilation **must** read checked-in tables and **must not**
contact the network or regenerate properties.

**TXT-DATA4: Defaults and bounds.** Property queries for every scalar, assigned or
unassigned, **must** return the release's property defaults and values. Table-index
arithmetic **must** be checked or construction-proven within bounds; non-scalars
**must** be rejected before scalar-only lookup. Generated accelerators **must** be
validated against raw-file expectations across the whole scalar domain, not against
another lookup from the same generated table.

**TXT-DATA5: License and attribution.** Redistribution of pinned sources and
generated data **must** retain the applicable [Unicode data license](https://www.unicode.org/license.txt)
and attribution under [Unicode's terms](https://www.unicode.org/copyright.html),
with the license artifact and its hash included in the manifest. The generator
**must** preserve required notices in emitted distributions; a content hash does
not replace licensing obligations.

**TXT-DATA6: Release upgrades.** A Unicode release, algorithm revision, or generated
schema change **must** create a distinct manifest identity and invalidate persisted
or in-memory property, analysis, boundary, and mapping caches before reuse. The
upgrade **must** regenerate and verify every affected table as one reviewed change;
consumers **must not** load a partially upgraded mixture or silently accept a
previous-version cache. Persisted consumer indexes require an explicit rebuild
under their owning application's storage contract.

The existing [Unicode generator](../../../../libs/base/tools/gen_unicode_tables.d),
[grapheme generator](../../../../libs/base/tools/gen_grapheme_tables.d), and
[analysis module](../../../../libs/base/src/sparkles/base/text/analysis.d) are migration
seams. A single manifest-driven pipeline may emit several cohesive modules; it is
not a requirement to store every property in one giant source file. Compiler-probed
grapheme singleton data becomes obsolete at cutover.

## 4. Segmentation and Unicode algorithms

### 4.1 Grapheme operations

Proposed `scanGrapheme` returns the next default extended grapheme cluster as a
borrowed UTF-8 source span plus metadata, not a bounded copied array of scalars.
Proposed `graphemeBoundaries` returns boundaries in increasing source order,
including 0 and source length exactly once. Empty input has the single boundary 0
and no clusters. Strict input failure uses TXT-UTF1; replacement input segmentation
runs over TXT-UTF2 tokens while retaining their original spans. Opaque analysis
makes each opaque token a hard barrier and an individually addressable unit; that
extension is not claimed to be UAX #29 segmentation of Unicode scalars.

**TXT-SEG1: Full extended graphemes.** Scalar input **must** follow every default
extended grapheme rule of the pinned UAX #29, including Indic conjunct GB9c,
Extended_Pictographic/ZWJ context, and regional-indicator parity. No fixed decoded
window or code-point count **may** force a boundary, including sequences longer than
16, 32, or 65,536 scalars.

**TXT-SEG2: Borrowed cluster and state.** Forward grapheme scanning **must** use
finite algorithm state and linear source work without storing every scalar of a
cluster. Returned cluster slices **must** borrow immutable source storage, and
iteration state **must** invalidate on mutation. Repeated iteration of a stable
source **must** yield identical boundaries regardless of SIMD availability.

**TXT-SEG3: Streaming boundaries.** A non-final chunk end **must not** be emitted
as a grapheme boundary merely because the chunk ended. Streaming scans **must**
retain finite break-rule context and absolute offsets, and emit a cluster-end event
only when a following token or finalization proves it. Events **must** cover the
same spans as whole-source scanning for every chunk partition; a contiguous slice
for a cross-chunk span **must** be obtained from caller-retained source or explicitly
reported as unavailable, not synthesized by hidden allocation.

**TXT-SEG4: Incomplete decode and backpressure.** Stream segmentation **must** apply
the encoding carry and final-input rules before deciding boundaries. Caller event
storage exhaustion **must** report `outputFull` with an uncommitted boundary event
and retryable state; it **must not** discard a cluster, split it, or advance beyond
an event that cannot be delivered. Stopping a scan is not finalization.

### 4.2 Word, sentence, line, and bidi

**TXT-SEG5: Default word and sentence boundaries.** Base **must** expose full default
word and sentence boundaries of the pinned UAX #29, in logical source order with
source endpoints. Dictionary/language tailoring **must** be an explicit caller
policy and **must not** alter the default operation; the bounded analysis module's
word-start flags **must** be derived from this owner rather than its own partial
word rules.

**TXT-SEG6: Line opportunities.** Base **must** expose prohibited, allowed, and
mandatory default UAX #14 opportunities with source offsets, including end-of-text
and hard-break semantics. Opportunity generation **must not** choose line widths,
claim shaping safety, or insert a visible hyphen. Wrapping owns selection and
explicit tailoring; text-layout additionally constrains candidates by contextual
shaping and safe-break information.

**TXT-BIDI1: Complete logical resolution.** Base **must** implement the pinned
UAX #9 paragraph algorithm, including explicit embeddings/overrides, isolates,
paired brackets, weak/neutral resolution, implicit levels, and the standard overflow
counters and depth limit. It **must** accept explicit LTR, RTL, or automatic paragraph
direction and return resolved base level, per-scalar levels, and logical reordering
indices without mutating source bytes or stripping original controls.

**TXT-BIDI2: Per-line application.** Given paragraph resolution and caller-selected
logical line ranges, base **must** expose the UAX #9 line-level reset and reordering
steps with inverse mappings. It **must** retain source identities for characters
removed by rule X9 without assigning them invented visible glyph positions. Font
mirroring/substitution and text-layout's visual caret geometry remain consumers;
terminal rendering **must not** automatically reorder logical terminal input.

**TXT-ALG1: Algorithm versus storage limits.** Limits mandated by an algorithm,
such as UAX #9 explicit-depth handling, **must** have that algorithm's prescribed
semantics. Caller-configured capacities for paragraph levels, events, provenance,
and transformation workspace **must** instead return structured exhaustion with
required storage when computable and the blocking source span; they **must not**
be described as Unicode character, word, or paragraph maxima.

## 5. Normalization, casing, and provenance

**TXT-NORM1: Four forms.** Base normalization **must** support NFC, NFD, NFKC, and
NFKD per the pinned UAX #15, including recursive mappings, canonical ordering,
composition exclusions, blocking, and algorithmic Hangul. It **must not** impose
Stream-Safe Text's 30-nonstarter insertion rule unless the caller explicitly selects
a separately named stream-safe transformation; ordinary normalization **must not**
insert CGJ or silently truncate a combining segment.

**TXT-CASE1: Complete default casing.** Base **must** expose simple scalar casing,
full string lower/upper/title casing with default context-sensitive SpecialCasing,
and simple/full case folding with explicit default versus Turkic folding. Locale
special casing for `tr`, `az`, and `lt` **must** be selected explicitly; an unknown
requested locale **must** return `unsupportedLocale`, not silently act as default.
Casing/folding **must** preserve source provenance across one-to-many and
context-dependent mappings, and title casing **must** use the owned word-boundary
contract rather than ASCII separators.

**TXT-PROV1: Contributing source spans.** Each transformed unit **must** retain the
ordered, deduplicated set of original contributing spans. Expansion shares the
original scalar span; composition takes the union of contributing spans; canonical
reordering preserves each unit's own provenance rather than pretending output
order is source order. A coarse enclosing span **may** be additionally exposed but
**must not** be represented as exact provenance when it includes unrelated bytes.

**TXT-PROV2: Deleted and opaque input.** Transformations that remove marks or
stopwords **must** retain the relationship needed to map surrounding output
boundaries back to the deleted source interval with explicit affinity. Opaque
bytes **must** preserve identity and act as barriers to normalization, folding,
and Unicode segmentation; a transform **must not** reinterpret them as PUA scalars
or combine across them.

**TXT-NORM2: Bounded workspace failure.** Normalization and analysis **must** accept
caller-owned workspace or an explicit caller allocator with configured limits. An
unbounded combining segment exceeding that storage **must** return workspace
exhaustion rather than an altered boundary. A whole workspace transformation
**must** invalidate earlier borrowed output at invocation and publish an empty,
invalid-for-consumption output view on failure, with no successful partial result;
workspace bytes **may** be overwritten but source bytes **must** remain unchanged.
Streaming transformations **must** expose only complete normalized segments, exact
committed progress, and retryable backpressure, because an incomplete segment may
still reorder or compose.

**TXT-NORM3: Analysis composition.** Search analysis **must** apply explicitly named
steps in order: decode, requested normalization, selected casing/folding, any
renormalization needed by the declared profile, optional mark stripping, owned word
boundaries, then caller-owned stopword filtering. The profile identity **must**
include each choice and lexicon revision. `sourceTooLong`, output capacity,
segment/workspace exhaustion, and invalid options **must** remain distinguishable;
32-bit provenance storage **must** reject a longer source rather than wrap offsets.

NFC-sensitive code/path analysis and NFKC-full-fold-mark-stripping language analysis
are policies above the core transforms. Their profile specifications must say whether
folded output is renormalized; they cannot claim normalization by merely doing NFC
before a folding step that may change it. Existing bounded storage is reusable, but
its old set of supported forms is not the scope of this target.

## 6. Cell text and coordinates

### 6.1 Named cell policy and whole-cluster fitting

A cell is a terminal grid advance, not a pixel or typographic point. Plain-cell
operations consume a single logical line without tabs, line separators, cursor
controls, or ANSI escapes. ANSI/stateful terminal adapters and wrapping own those
interpretations and return provenance to this plain input. Policy selection is
explicit and shared by measurement, clipping, hit mapping, and rendering.

**TXT-CELL1: Policy identity.** Base **must** provide a named terminal-width profile
whose identity includes Unicode manifest, profile revision, ambiguous-width choice,
emoji/presentation rules, malformed-input mode, and any explicit substitutions.
Changing any of these **must** change the identity. The default proposed
`terminalKitty`, revision 1, **must** retain the delivered kitty-oriented width
algorithm while deriving all properties from the owned Unicode release. Isolated
controls, separators, noncharacters, marks (`Mn`, `Mc`, `Me`), format characters
and the conjoining ranges specified in [the cell policy](./index.md) have width
zero; regional indicators and East Asian Wide/Fullwidth scalars have width two;
other scalars have width one, with ambiguous width narrow. A complete grapheme
takes its leading scalar's width, modified by the last applicable VS15/VS16 for
an emoji-variation base to one/two respectively; its members are not summed.
These scalar rules do not waive TXT-CELL2's plain-input rejection.

This is a named local terminal profile, not a universal font-width claim.
Independent kitty and Ghostty comparisons **must** pin engine revision and
configuration and document disagreements; they do not define production tables.
An actual Ghostty-backed grid remains authoritative for its own cell coordinates:
consumers **must not** reconstruct those coordinates under another profile.
A distinct explicitly selected policy requires a real consumer requirement and
separate evidence; backward aliases are not required.

**TXT-CELL2: Measurement and unsupported input.** Plain measurement **must** sum
profile-defined whole-grapheme advances using checked counts. It **must** reject
unsupported controls, tabs, line separators, and escapes with their source offset,
unless the caller supplies an explicit substitution before measurement. Its width
for ordinary ASCII, `e` plus combining acute, CJK `界`, a regional-indicator flag,
and an RGI ZWJ emoji **must** be 1, 1, 2, 2, and 2 respectively under the selected
narrow-ambiguous target profile. Replacement and opaque-display substitution
**must** use their declared displayed token widths and preserve original spans.

**TXT-CELL3: Prefix and suffix fitting.** Proposed `fitPrefix` and `fitSuffix`
**must** return borrowed source spans, measured cells, and source boundary positions
for the longest whole-cluster prefix or suffix within a nonnegative cell budget.
They **must not** split a grapheme, manufacture padding, or count each scalar as a
cell. A zero budget **must** include adjacent zero-advance clusters until a positive
advance would be needed; negative budgets **must** return `invalidBudget`. Suffix
fitting **must** use the same boundaries as forward scanning, including RI parity,
rather than an independent backward heuristic.

### 6.2 Typed coordinates and affinity

**TXT-MAP1: Distinct units.** Public mapping inputs and results **must** identify
source-byte offsets, scalar indices, UTF-16 code-unit offsets, grapheme boundaries,
and cell positions distinctly. Physical `LayoutUnit` is defined only by
[wrapping](./wrapping.md), and **must not** be substituted for cells or bytes.
All offset arithmetic **must** check overflow; out-of-range requests **must** return
`outOfRange`, not silently clamp or wrap.

**TXT-MAP2: Interior affinity.** A map request inside a multi-byte scalar, UTF-16
surrogate pair, grapheme, or wide cell **must** either return `notBoundary` in exact
mode or snap to that unit's source start for `before` and source end for `after`.
The result **must** say whether it was exact or snapped. Byte/UTF-16 scalar maps
**must** be lossless at valid scalar boundaries, including supplementary scalars;
grapheme maps apply the additional grapheme constraint explicitly.

**TXT-MAP3: Cell inverse and zero width.** Mapping a cell interior **must** select
the complete grapheme's start/end by affinity. At an exact cell coordinate shared
by zero-advance spans, `before` **must** choose the earliest source boundary and
`after` the latest at that coordinate, including source start/end. Mapping source
interiors to cells **must** obey the same whole-grapheme snapping, not expose
selection positions inside the cluster.

For `e\u0301x`, cell coordinate 1 maps exactly to byte 3. For `🇺🇸x`,
coordinate 2 maps to byte 8. For `界x`, coordinate 1 is inside the wide cluster:
`before` maps to byte 0 and `after` to byte 3. In UTF-16, the interior of a
supplementary scalar's surrogate pair is not a scalar boundary.

**TXT-MAP4: Transformation maps.** Source-to-transformed mapping **must** return
all corresponding unit/range relationships when expansion, composition, reordering,
or deletion prevents a one-to-one map. A consumer asking for one boundary **must**
select before/after affinity and receive an exactness marker; source highlighting
**must** use TXT-PROV1 spans rather than infer source offsets from transformed UTF-8
length. Empty output **must** retain both original source endpoints as a mapping
relationship, not invent a source of length zero.

For a source boundary `b`, first validate or snap the source coordinate under
TXT-MAP2. Define `L` as the earliest transformed-unit start having any contributor
whose source end exceeds `b`, or transformed end if none exists. Define `R` as the
latest transformed-unit end having any contributor whose source start precedes
`b`, or zero if none exists. `before` **must** return `L` and `after` **must**
return `R`. At a valid source boundary `L <= R`; the interval is a conservative
cut envelope, not an exact range of contributors, and may include unrelated
transformed units when order changes. The complete relation remains available.
The boundary result is exact only when `L == R`, the source coordinate was exact,
and no nonempty deleted source span contains `b` in its closed endpoint interval;
otherwise it is explicitly projected. Exact-only requests reject a projected cut.
For inverse queries, apply the contributor-cut predicates with the domains
exchanged, then include every deleted source span anchored at the queried output
boundary. Return the minimum and maximum of these candidates as before/after;
when deletion leaves a gap between the neighboring surviving source units, its
two endpoints remain candidates even though no output unit represents the gap.
Any non-singleton envelope or deleted-span candidate is projected, not exact.
Synthetic output and its zero-length anchors are outside Unicode transformations
and use the owning wrapping/projection contract.

### 6.3 Mapping cache ownership

**TXT-CACHE1: Borrowing and invalidation.** A mapping or boundary cache **must**
include source identity, revision, encoding, malformed mode, Unicode manifest,
transform profile, and cell policy where used. It **must** reject `staleSource` or
`stalePolicy` before a cached result is used with a mismatched key. Borrowed source
and returned spans **must** remain valid only while that immutable revision lives;
base **must not** own UI document identities or secretly retain released buffers.

**TXT-CACHE2: Incremental edits.** A caller may supply edits for incremental cache
maintenance, but **must** supply the changed revision and affected source intervals.
The cache **must** invalidate all context-dependent results until an algorithmically
proven restart/synchronization point; a fixed lookbehind window **must not** certify
RI parity, arbitrary combining runs, word/sentence context, or bidi paragraphs.
A full rescan **may** be used when no such proof exists and **must** produce the same
result as an uncached operation.

**TXT-CACHE3: Cache exhaustion.** Caller-owned mapping storage **must** report
`workspaceFull` and required entries when known without returning an apparently
complete map. Eviction or sparse checkpoints **may** reduce stored entries but
**must not** change mapping results; concurrent immutable queries require disjoint
mutable workspace or an explicitly synchronized consumer cache, not hidden globals.

## 7. Cutover and acceptance boundaries

**TXT-MIG1: One authority per caller.** Each migrated caller **must** use the same
profile for measure, fit, wrap integration, render advance, hit testing, and copy
selection. The migration **must** remove competing Unicode/width helpers and
code-point-count compatibility paths after all callers are moved; it **must not**
leave obsolete re-exports or shims as an alternative default.

**TXT-MIG2: Real public behavior.** Acceptance **must** exercise actual UI/table/TUI
and relocated doc-view consumers with combining accents, flags, CJK, and ZWJ text,
checking both rendered extents and byte ranges copied by selection. A pure decoder
pass or source-level import audit **must not** be presented as proof of that cutover.
Platform UTF-16 adapters **must** exercise native-boundary units and termination,
with unavailable platforms recorded as unverified rather than assumed passing.

Stable obligation IDs map to independent scenarios in [testing](./testing.md).
Delivery exclusions do not reduce the final scope: later implementation slices
must refine any externally dependent operation before accepting it, and the draft
contract is not accepted until independent adversarial review is recorded.
