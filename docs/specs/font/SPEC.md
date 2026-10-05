---
status: draft
owner: sparkles:font
reviewed:
---

# `sparkles:font` — Specification

## Abstract

`sparkles:font` reads font files and turns text into glyphs, outlines and
pixels for Sparkles programs: a terminal emulator, a code viewer, and a font
explorer that shows everything inside a font. Its parser reads TrueType and
OpenType files in place, in the caller's memory and without allocating, so a
hostile file can produce an error but never an out-of-bounds read. Every step,
including the HarfBuzz shaper it delegates to, receives the same variable-font
coordinates. Font matching and fallback follow the same rules on every
platform, including those without a system font service.

## 1. Introduction

Every program that draws text from a font file answers the same questions.
Which file serves this character? Which glyphs does this text become, and
where do they go? What pixels does each glyph cover at this size? A terminal
answers them for a fixed grid of cells sixty times a second. A code viewer
answers them for styled runs it can zoom. A font explorer answers them for
thousands of files the user downloaded, and must also show what each file
contains: its tables, its OpenType features, its variation axes, the
characters it covers and its metrics.

No single existing component serves all three. Rasterization libraries hide a
font's tables behind their own API, so an inspector cannot show them. Parsers
that expose the tables do not render. Platform text stacks render and match
well, but differ on every operating system and are absent on Android. Variable
fonts add a further trap: the coordinates that select an instance must reach
the shaper, the metrics and the outline decoder identically, and libraries
that let each layer take them separately drift apart. Finally, a program that
opens downloaded files is exposed to every malformed offset an attacker can
write.

This library owns the parts where correctness and inspection matter, and
delegates text shaping, the one part that is large and well solved. It parses
fonts in D, directly over a borrowed byte buffer, validating every read
against the buffer's bounds. A [face](../../glossary.md#face) is an immutable view of one font in
those bytes; an [instance](../../glossary.md#font-instance) adds a size and one normalized coordinate vector,
and every later step reads that vector from the instance.
Outlines are decoded and rasterized in D. Shaping goes to
HarfBuzz, which receives the instance's coordinates unchanged. Discovery
builds a [font catalog](../../glossary.md#font-catalog) from the files each platform lists, described by this
library's own parser. Platforms differ in which files they list, but the
matching and fallback rules applied to them are the same everywhere.

Several things are deliberately left to others. Owned UTF decoding, Unicode
properties, segmentation, line-break opportunities and bidi analysis belong to
[`sparkles:base`](../base/text/SPEC.md). Its [wrapping contract](../base/text/wrapping.md)
owns generic solvers and physical layout units. Contextual paragraph composition,
visual ordering and source-to-visual mappings belong to
[`sparkles:text-layout`](../text-layout/SPEC.md), which depends on base and font;
font never depends on layout. Math composition, page layout and export sit above
font as well. Font supplies their measured resources, not their composition policy.
Drawing rasterized pixels on a screen belongs to the consumer: a GPU backend
uploads them, a terminal backend sends them as an image.
HarfBuzz parses the same hostile bytes when it shapes; its robustness is
HarfBuzz's own, and this
library's trust guarantees cover only its own reads. Font hinting, LCD subpixel
rendering, web-font containers (WOFF and WOFF2), writing or subsetting font
files, and installing fonts system-wide are out of scope. `COLR` version 1
and `SVG ` colour glyphs are reported but not rendered. [`decisions.md`](./decisions.md)
records why each of these was excluded and what would bring it back.

Section 2 lists the terms this document defines, and section 3 states the contract at a
glance. Sections 4–15 give the requirements: the trust boundary, objects and
ownership, errors, parsing, variation, metrics, outlines, rasterization,
shaping, discovery, inspection, and the Sparkles programs that draw text
through `sparkles:raylib-text`.
[`testing.md`](./testing.md) names the independent oracle and scenarios for
every requirement and holds the evidence ledger. [`PLAN.md`](./PLAN.md) orders
delivery and tracks progress, including the migration of existing consumers.
The evidence base is the [font-libraries research catalog][research].

## 2. Terminology

The terms this specification coins, or uses in a narrower sense than usual,
are defined once in the [glossary](../../glossary.md) and listed here:

<GlossaryList owner="sparkles:font" />

Font-format terms follow the [OpenType specification][ot-spec]: a
[collection](https://learn.microsoft.com/en-us/typography/opentype/spec/otff#font-collections)
is a `ttcf` file holding several faces that may share tables, and
[user and normalized coordinates](https://learn.microsoft.com/en-us/typography/opentype/spec/otvaroverview#coordinate-scales-and-normalization)
are an axis's own units and the −1…0…+1 values, after `avar` remapping, that
variation tables interpolate in. The research catalog's [concepts
page][concepts] explains these and other font internals for newcomers.

## 3. The contract at a glance

1. **Bounded reading.** No operation reads outside the caller's byte buffer
   or does unbounded work, whatever the bytes contain.
2. **Borrowed bytes.** Faces and everything derived from them borrow the
   caller's buffer; the library never copies or frees it.
3. **Immutable faces.** A face never changes after it opens, so any number
   of threads may read it at once.
4. **One coordinate vector.** An instance holds the only copy of its
   normalized coordinates, and every consumer of variation reads that copy.
5. **Caller-owned working memory.** Decoding, shaping and rasterization
   write into storage the caller provides and keep nothing between calls.
6. **Caches beside, not inside.** Faces and instances never cache; caches
   are separate values keyed by glyph keys.
7. **No windowing.** Nothing in the library depends on a window system, a
   GPU API, raylib or `sparkles:ui`.
8. **The same behaviour everywhere.** Matching and fallback use this
   library's own face records on every platform.
9. **One Unicode owner.** UTF and Unicode semantics come from base's pinned
   release, not Phobos or an uncoordinated shaping-engine data set.
10. **Measured resources, not composition.** Font exposes scalable metrics,
    contextual shaping, baseline and math data; layout chooses breaks and places
    runs. Ink bounds never substitute for advances.

## 4. Trust boundary

Font files are attacker-controlled input. The enforcement boundary is every
public operation that reads font bytes.

**FTB1: No out-of-bounds read.** For any byte sequence, every operation that
reads font data **must** return a value derived only from bytes inside the
borrowed buffer, or return an error.

_Rationale:_ A read past the buffer is a violation whether or not it crashes,
because the explorer opens files from untrusted sources.

**FTB2: No assertion on data.** Malformed input **must not** reach an
`assert`, a contract precondition, an array bounds check or an
integer-overflow trap. Those **may** reject only caller-controlled arguments,
and each such precondition is documented on its operation.

**FTB3: Bounded work.** Every operation **must** have a documented
worst-case cost in terms of input sizes and these fixed limits: composite
glyph depth 8 and 512 components per glyph; `CFF` subroutine depth 10 and
65,536 charstring operations per glyph; 1,024 `COLR` layers per glyph; 4,096
table records per face; 64 `cmap` subtables per face. Exceeding a limit
**must** produce an error that names it, never a silent truncation.

**FTB4: Declared allocation.** Parsing, metrics and outline decoding **must
not** allocate. Rasterization **must** write into caller-owned storage. An
operation that allocates **must** say so in its documentation and state a
memory bound.

**FTB5: Cycles are errors.** A composite glyph or `CFF` subroutine that
refers back to itself, directly or transitively within the depth limit,
**must** produce a `cycle` error.

## 5. Objects and ownership

**FTA1: Borrowed bytes.** A face **must** hold the caller's bytes as a
`scope const(ubyte)[]` slice and never copy them. The owner of the buffer
keeps it alive while any face or derived value exists.

_Rationale:_ With `-preview=dip1000`, `@safe` callers get this lifetime
checked by the compiler, and a mapped file or an APK asset can back a face
without a copy.

**FTA2: Immutable face.** A face **must not** change after a successful
open. Concurrent calls to its `const` operations from several threads
**must** be safe without synchronization.

**FTA3: Instance as a value.** An instance **must** be a copyable value
holding a face, an explicitly unit-tagged size (physical or pixel), a normalized
coordinate vector and a [synthesis](../../glossary.md#synthesis) value,
with no mutable state. It is the only place variation coordinates are stored.

**FTA4: Caller-owned scratch.** Shaping, outline decoding into arrays and
rasterization **must** take their working storage from the caller and
**must not** retain it between calls.

**FTA5: Caches beside, not inside.** No operation on a face or an instance
**may** consult or fill a cache. Glyph, outline and shaping caches are
separate values keyed by values such as the [glyph key](../../glossary.md#glyph-key).

**FTA6: No windowing dependency.** No module of the library **may** import
raylib, a GPU binding, `sparkles:ui` or a `sparkles:ui` backend.

### Package configurations

The package has two configurations. The default, `library`, provides
parsing, variation, metrics, outlines, rasterization, discovery and
inspection in D, depending only on `sparkles:base` and `expected`. The
`engine` configuration adds shaping and links HarfBuzz, reached through
hand-declared `extern(C)` prototypes over opaque handles with no C source
file compiled.

**FTA7: A pure-D default.** The `library` configuration **must** build and
pass its tests with no C library on the link line other than those of the D
runtime, on the desktop targets and on Android.

**FTA8: Checked HarfBuzz layouts.** Every HarfBuzz struct whose fields the
library reads or writes **must** have its size and field offsets checked
against the installed `hb.h` by a test.

_Rationale:_ Hand-declared layouts avoid a C shim and the build constraints
of ImportC, at the risk of drifting from the headers. This test turns drift
into a failure instead of memory corruption.

Packages depend on the library, never the reverse: the font explorer,
`sparkles:raylib-text`, `sparkles:terminal-view` and `sparkles:text-layout` use
`sparkles:font`, which uses `sparkles:base`. These are dependency directions,
not claims that the proposed packages or APIs have been delivered.

**FTA15: Base owns text semantics.** Font **must** use base's owned UTF codecs
and Unicode contract, including name decoding and shaping inputs; production
modules **must not** import `std.utf` or `std.uni`, use implicit auto-decoding, or
derive Unicode tables from the compiler. Font **must not** depend on
`sparkles:text-layout` or own competing segmentation, bidi, line-breaking or
wrapping helpers. Shaping-engine integration **must** satisfy `FTS8`.

## 6. Errors

**FTA9: Structured errors.** Fallible operations **must** return
`Expected!(T, FontError)`. A `FontError` carries a kind, the table tag
involved if any, and the byte offset where the problem was found. The kinds
include at least `notAFont`, `truncated`, `badOffset`, `badValue`,
`unsupportedVersion`, `missingTable`, `limitExceeded`, `cycle`,
`indexOutOfRange`, `invalidEncoding`, `invalidRange`, `invalidFeatureRange`, `splitScalar`,
`unsupportedUnicodeVersion`, `unsupportedEngine`, `unsupportedCapability` and
`arithmeticExhausted`.

**FTA10: Absent is not malformed.** A table the font lacks **must** yield
`missingTable`, never `badOffset`. A field that the table's version predates
**must** yield its documented default, never an error.

**FTA11: Partial results stay reachable.** Where a table is a list, such as
name records, `cmap` subtables, axes or layout features, a malformed entry
**must** produce an error for that entry while the well-formed entries remain
readable.

_Rationale:_ An inspector exists to show broken fonts. Refusing a whole table
for one bad record hides exactly what the user came to see.

## 7. Parsing

[`parsing.md`](./parsing.md) refines these requirements to operation level:
inputs, results, borrowing, errors and bounds for each operation.

### Opening a face

**FTP1: Format detection.** The first four bytes **must** select the
container: `0x00010000` or `true` for TrueType outlines, `OTTO` for `CFF` or
`CFF2` outlines, `ttcf` for a collection. Any other value is `notAFont`,
except the WOFF (`wOFF`) and WOFF2 (`wOF2`) signatures, which **must** yield
`unsupportedVersion`.

_Rationale:_ Naming a web font as unsupported, rather than as not a font,
tells the user what to do with the file.

**FTP2: Collections.** Opening a collection **must** read its header, in
versions 1.0 and 2.0, and report the face count. Opening face `i` of a
collection succeeds for `0 ≤ i < count`; a single-font file accepts only
index 0. Any other index is `indexOutOfRange`. A face count above 65,535, or
an offset array that does not fit the buffer, is `badValue` or `truncated`.

**FTP3: Table directory.** Opening **must** check that the directory's
records fit the buffer and that each record's offset plus length fits without
overflow. A record failing a check makes only that table unreadable, reported
as `badOffset`, unless it is `head`, `maxp` or `cmap`, whose failure **must**
fail the open. When several records share a tag, the first is the table and
the rest are reported by inspection ([`FTP21`](./parsing.md#_2-opening)).

**FTP4: Checksums are reported.** Table checksums and
`head.checkSumAdjustment` **must** be computable on request. A mismatch is
reported to the caller and **must not** make the library refuse the face.

**FTP5: Cheap opening.** Opening a face **must** cost time proportional to
the number of tables, plus the fixed-size reads of `head` and `maxp`. It
**must not** decode glyphs, `cmap` subtables or layout tables.

### Tables

**FTP6: Raw access.** The bytes of every table in the directory **must** be
obtainable as a slice of the borrowed buffer, including tables the library
does not understand.

**FTP7: Typed tables.** The library **must** return a plain struct for each
of `head`, `hhea`, `maxp`, `OS/2` (versions 0–5), `post` (versions 1, 2,
2.5 and 3), `name`, `hmtx`, `cmap`, `fvar`, `avar` and `STAT`. Field names
**must** match the OpenType specification's. Fields a version lacks hold their
documented defaults.

**FTP8: Name records.** Every `name` record **must** be enumerable with its
platform, encoding, language, name ID and text. Text in UTF-16BE **must**
decode, which covers platform 0 and platform 3 encodings 0, 1 and 10; so
**must** Mac Roman, platform 1 encoding 0. Other encodings are reported with
their raw bytes. Version 1 language-tag records **must** decode. UTF-16BE
decoding **must** use base's strict codec: malformed surrogate pairs or an odd
byte count return `invalidEncoding` for that record, with table-relative byte
offset and no partial decoded string. Other well-formed records remain readable.
Decoding writes into caller storage; raw record bytes remain accessible.

**FTP9: Character mapping.** Mapping a codepoint to a glyph **must** use the
first `cmap` subtable that passes its checks, trying in order the symbol
subtable (platform 3 encoding 0), the full-repertoire subtables, the BMP
subtables and the Macintosh ones, as HarfBuzz does; a rejected subtable is
counted and reported. Formats 0, 4, 6, 12 and 13 **must** decode, and format
14 **must** decode for variation-sequence lookups. An unmapped codepoint
yields glyph 0. [`FTP25`](./parsing.md#_4-character-mapping) gives the exact
order and lookup rules.

**FTP10: Character coverage.** The mapped codepoints of the chosen subtable
**must** be enumerable as sorted, merged ranges, in O(L + 65,536) time for a
subtable of `L` bytes and without allocating
([`FTP27`](./parsing.md#_4-character-mapping)).

**FTP11: Glyph names.** A glyph's name **must** come from `post` version 1.0,
2.0 or 2.5, or, for a glyph `post` does not name, from the `CFF` charset. A
font with neither yields no name, not an error.

**FTP12: Measured spacing.** The library **must** classify a face as `mono`,
`dual` or `proportional` from its `hmtx` advances, ignoring zero advances.
`dual` means exactly two advances, the larger twice the smaller, as in CJK
monospace fonts. `post.isFixedPitch` is reported separately and **must not**
decide the classification.

**FTP13: Math data, not math composition.** The library **must** provide bounded
borrowed views and instance-aware queries for OpenType `MATH` version 1.0:
all math constants; per-glyph italic corrections, top-accent attachments,
extended-shape coverage and the four math-kern tables; horizontal and vertical
variants; and assembly parts with glyph IDs, start/end connector lengths, full
advances, extender flags and minimum connector overlap. Math-kern lookup **must**
select the value for the requested correction height according to the table's
step rule. Dimensional values with device/variation adjustments **must** retain
their design value and expose the resolved value under `FTM6`. Percentages,
counts and flags retain their native dimensionless units; they **must not** be
scaled as lengths. Missing `MATH`, missing glyph
records, unsupported versions and malformed offsets **must** be distinguishable;
absence **must not** silently supply invented math constants. Caller storage
exhaustion **must** return `limitExceeded` without publishing a partial result.
Font supplies data to math composition above font; it does not choose fractions,
scripts, stretching assemblies, formula breaks or math-page placement.

## 8. Variation

**FTV1: Axes and instances.** The `fvar` axes **must** be enumerable with tag,
user-space minimum, default and maximum, the hidden flag and name ID. Named
instances **must** be enumerable with subfamily name ID, optional PostScript
name ID and user coordinates.

**FTV2: Normalization.** Building an instance from user coordinates **must**
normalize them exactly once: clamp to the axis range, map piecewise-linearly
to −1…0…+1, then apply the `avar` segment maps if present. The result is
stored as F2Dot14 values. An axis left unspecified takes its default.

**FTV3: One vector for every consumer.** Metrics, outlines, shaping and glyph
keys **must** take coordinates from the instance. No operation **may** accept
variation coordinates by another route.

_Rationale:_ Libraries that let layers take coordinates separately drift. An
advance computed at one location and an outline drawn at another produce text
that overlaps or gaps.

**FTV4: User values retained.** An instance **must** keep the user
coordinates it was built from, so a reader can be shown `wght 650` rather
than `0.4375`.

**FTV5: Exact normalization.** For every axis and `avar` map in the test
corpus, normalized values **must** equal an independent reference to the
F2Dot14 unit.

## 9. Metrics

**FTM1: All vertical sets.** The `hhea` ascender, descender and line gap,
the `OS/2` typographic set and the `OS/2` Windows set **must** each be
reported in font units, together with the `USE_TYPO_METRICS` flag.

**FTM2: One line-metric rule.** The library's line metrics **must** use the
typographic set when `USE_TYPO_METRICS` is set; otherwise `hhea` when its
ascender or descender is non-zero; otherwise the typographic set; otherwise
the Windows set with the descent negated. The result names the set it used.

**FTM3: Absent, not zero.** x-height, cap height, underline position and
thickness, and strikeout position and size are optional. A value the font
does not provide **must** be reported as absent.

**FTM4: Fractional values.** The pixel convenience path **must** report advances
and metrics at an instance in fractional pixels, including `HVAR` and `MVAR`
deltas. The library **must not** round them to whole pixels. `FTM6` generalizes
this path without removing it; only the cell API of `FTM5` performs its explicit
whole-pixel rounding.

**FTM5: Cell metrics.** For an instance, the library **must** compute [cell
metrics](../../glossary.md#cell-metrics) in whole device pixels. The cell width is the rounded advance of
U+0030 DIGIT ZERO, or `OS/2.xAvgCharWidth` when the face does not map it. The
rounding rule is documented on the operation and is part of the contract.

**FTM6: Device-independent scalable measurements.** At an instance, advances,
offsets, line metrics, baselines and dimensional math values **must** be available in
fractional design units and in base's
[physical `LayoutUnit`](../base/text/wrapping.md), with the instance's physical
em size supplied explicitly. Pixel conversion **must** require an explicit
device scale; changing that scale **must not** change physical measurements.
Hinting, pixel snapping and bitmap-strike selection **must not** influence
physical advances. Conversion to `LayoutUnit` **must** round once, nearest with
ties to even, with error at most half a unit; intermediate arithmetic overflow or
an unrepresentable result **must** return a structured arithmetic-exhaustion error,
never saturate or wrap. The shared unit and arithmetic contract is owned by base,
not redefined here. Design values with pixel-device deltas **must** keep those
deltas separate until an explicit ppem is provided; instance variation deltas
apply to design/physical measurements. Ink extents (which may be negative,
overhang or be empty) and pen advances **must** be distinct results. A space
may advance without ink, and a mark may have ink without advance.
The design-position path **must** preserve the engine's integer position scale
and the face's units-per-em so a consumer can accumulate design advances/origins
before physical conversion. A run-total measurement **must** convert the accumulated
design advance once; it **must not** sum per-glyph rounded physical advances.
Layout owns accumulation across runs and candidate lines; font supplies the
scale/provenance needed to avoid a second lossy conversion.

**FTM7: Baselines and vertical metrics.** The library **must** expose `BASE`
version 1.0/1.1 horizontal and vertical axes, baseline tags, script/default and
language-system records, min/max extents and all BaseCoord formats, including
reference-glyph/point coordinates and device/variation adjustments. It **must**
report `vhea`, `vmtx`, `VORG` and `VVAR` metrics when present, and resolve vertical
advance/origin and baseline queries at the same instance coordinates as shaping.
Missing tables and missing records **must** be distinguishable from malformed
records and from a valid zero coordinate. A selected fallback vertical origin or
baseline **must** report its provenance; it **must not** be presented as a `BASE`
record. Reading these tables follows `FTB1`–`FTB5` and `FTA10`–`FTA11`; requested
indices and scratch limits have the same structured errors as other table queries.

## 10. Outlines

**FTO1: Outline sink.** Drawing a glyph's outline **must** drive any sink
type providing `moveTo`, `lineTo`, `quadTo` and `close`, and optionally
`cubicTo` and `begin(contourCount)`. A sink without `cubicTo` receives cubic
curves as quadratic approximations within 1/16 font unit.

**FTO2: Outline as data.** The same outline **must** be decodable into a
caller-owned segment array with explicit contour starts and closes. When the
array is too small, the operation **must** return `limitExceeded` and write
nothing past the array's end.

**FTO3: Font units.** Outlines **must** be in font units, y-up and unscaled.
Scaling and flipping belong to the rasterizer or the caller.

**FTO4: Variation keeps topology.** For any glyph, the sequence of segment
kinds at any instance **must** equal the sequence at the default instance.

_Rationale:_ This lets an outline cache key on glyph and coordinates without
re-deriving structure, and it is cheap to test across a whole corpus.

**FTO5: Composites and phantom points.** Composite `glyf` glyphs **must** be
flattened with their transforms. In a face without `HVAR`, the advance at an
instance **must** include the `gvar` phantom-point deltas.

## 11. Rasterization

**FTR1: Pixel coverage into caller storage.** Rasterizing a glyph **must** write
8-bit [coverage](../../glossary.md#coverage) into a caller-owned region with its own row stride and report
the glyph's bounding box and bearing. It **must not** allocate.

**FTR2: Nonzero winding.** Coverage **must** follow the nonzero rule. A glyph
whose `glyf` data sets `OVERLAP_SIMPLE` or `OVERLAP_COMPOUND` **must** render
as the union of its contours, so that overlapping contours do not double the
coverage of their edges. Any other glyph **may** double it where its contours
overlap, as FreeType does. The caller **may** request the union for every
glyph.

_Rationale:_ The union costs 6–10 times a plain render, and the flag is how
fonts and renderers agree on when to pay for it: FreeType supersamples flagged
glyphs, and Fontations reports the flag to its renderer as `has_overlaps`
([`FTX9`](./decisions.md#ftx9-flatten-to-0-02-px-render-the-union-of-flagged-glyphs)).

**FTR3: Arithmetic against an independent renderer.** The rasterizer **must**
offer a flattening policy that reproduces the subdivision rules of FreeType's
`ftgrays.c`. Under that policy, coverage for every glyph of the test corpus at
12, 16, 24 and 48 pixels per em **must** be within the tolerance recorded in
[`testing.md`](./testing.md#raster-oracle) of FreeType's unhinted rendering.
The tolerance is fixed before the requirement is accepted and is not adjusted
to make a run pass.

_Rationale:_ Compared with default flattening, most of the difference from
FreeType is FreeType's own coarser flattening, which would hide errors in the
accumulation arithmetic. Reproducing an existing engine's outline behaviour is
a feature in its own right, as Fontations' `PathStyle::FreeType` shows
([`FTX10`](./decisions.md#ftx10-two-raster-oracles)).

**FTR4: Explicit gamma.** Coverage **must** be linear. A separate,
documented transfer function maps it for display, chosen by the consumer.

**FTR5: Layered colour glyphs.** `COLR` version 0 glyphs **must** render as
`CPAL`-coloured layers into a premultiplied RGBA target. The foreground
palette index `0xFFFF` takes a colour the caller supplies.

**FTR6: Deterministic glyph keys.** Rasterizations with equal glyph keys
**must** produce byte-identical output.

**FTR7: Bitmap colour strikes.** `CBDT`/`CBLC` and `sbix` glyphs **must**
decode from their embedded PNG data in 8-bit greyscale, RGB, RGBA or indexed
colour, without interlacing. Other PNG forms yield `unsupportedVersion`. The
strike chosen is the smallest at least as large as the requested size, else
the largest, scaled to the requested size.

_Rationale:_ The emoji font Sparkles bundles is a `CBDT` font with no
outlines, so this is the only way emoji render without FreeType.

**FTR8: Flattening accuracy.** With the default flattening, coverage for every
glyph of the test corpus at 12, 16, 24 and 48 pixels per em **must** be within
the tolerance recorded in [`testing.md`](./testing.md#raster-oracle) of the
same glyph rendered by the same rasterizer with curves flattened to 0.001 px.

## 12. Shaping

These requirements apply to the `engine` configuration.

**FTS1: Shaped runs.** Shaping text with an instance **must** return glyph
IDs, source clusters as UTF-8 byte offsets into the borrowed source, and advances
and offsets in the unit selected under `FTM4`/`FTM6`, using the instance's
coordinates. Glyph order is pen traversal order for the reported direction;
offsets are relative to each glyph's pen position, not accumulated origins.
Measurement **must** use the actual substitutions and positioning of that run,
not nominal `cmap` advances or ink bounds.

**FTS2: Typed options.** Features **must** be values carrying a tag, a value
and an optional absolute source-byte range. Direction, script and language
**may** be guessed for a standalone convenience call, and the result **must**
report those used and whether each was explicit or guessed. A coordinated call
under `FTS8` **must not** guess or overwrite explicit properties.

**FTS3: Coordinates passed unchanged.** HarfBuzz **must** receive exactly the
instance's normalized coordinates. Shaping **must not** normalize again.

**FTS4: Cluster integrity.** Glyph clusters **must not** be described as Unicode
graphemes or assumed to contain one codepoint or one glyph. The coordinated path
**must** use monotone-character clustering: cluster starts in pen order are
non-decreasing for LTR/TTB and non-increasing for RTL/BTT. Repeated starts are
permitted. The result **must** separately partition the shaped source interval
into ordered, nonempty, half-open byte spans, associating each span with all its
glyphs. Sort distinct emitted cluster starts in source order and include the run
start; each span ends at the next start or at the run end. A leading span with
no emitted start has an empty glyph range; a glyphless nonempty run has one empty
glyph-range span. Absorbed characters and removed default ignorables retain byte
coverage in this partition, which does not claim that every covered scalar
emitted a glyph.
Span boundaries **must** be scalar boundaries; every byte in the shaped interval
belongs to exactly one span, and no context-only byte belongs to one. These spans
do not grant line-break or grapheme boundaries. Consumers **must not** infer
source coverage from adjacent glyph indices, especially in RTL runs.

**FTS5: Deterministic release.** HarfBuzz objects created for a face or
instance **must** be released when their owner is destroyed, and none **may**
outlive the bytes it borrows.

**FTS6: Layout check.** The D declarations of `hb_glyph_info_t`,
`hb_glyph_position_t`, `hb_feature_t`, `hb_variation_t` and
`hb_ot_var_axis_info_t` **must** match the installed headers in size and in
every field's offset. This is the test `FTA8` requires.

**FTS7: Contextual range shaping.** The proposed contextual operation takes
borrowed strict UTF-8 source, a half-open run range at scalar boundaries, an
instance, explicit segment properties, feature ranges and buffer flags. It
**must** make the surrounding source available as pre/post context while emitting
only the run. Returned byte offsets **must** remain absolute source offsets.
Beginning/end-of-text flags describe genuine shaping text boundaries, including
deliberate line boundaries, not every style, script or fallback run. The caller
**must** select these flags explicitly and the result **must** report them.
Invalid UTF-8, inverted/out-of-source ranges, split scalar boundaries and invalid
feature ranges **must** produce distinct structured errors before publishing any
output. UTF-8 decoding **must** use base and submit scalars with their source
offsets, not a second decoder hidden in the engine. An empty valid range succeeds
with no glyphs. Output and workspace capacities and engine allocation/work bounds
**must** be documented in terms of run/context sizes and configured glyph limits;
exhaustion **must** return `limitExceeded` with caller outputs uncommitted.
Results borrow source and face bytes for their lifetime; scratch is not retained.

**FTS8: Coordinated properties and engine data.** The paragraph integration path
**must** accept direction, script and language resolved by the caller from base
analysis and paragraph policy, without re-running bidi or inventing run boundaries.
The adapter **must** supply every supported HarfBuzz Unicode callback (category,
combining class, mirroring, script, canonical compose/decompose) from base's
single pinned release. This is not sufficient to guarantee engine compatibility:
the integration manifest **must** pin the HarfBuzz release and source revision,
identify internal script/category/normalization tables or algorithm behavior not
replaceable by callbacks, and demonstrate compatibility with base's release and
algorithm revisions. Uncovered mismatches **must** block coordinated shaping with
`unsupportedUnicodeVersion`, not silently mix data versions. Engine ABI/version
capability checks **must** distinguish an unsupported engine from malformed font
data; a system upgrade **must not** silently alter the accepted shaping profile.

**FTS9: Break and concatenation safety.** With the relevant HarfBuzz production
flags enabled, shaping **must** return unsafe-to-break, unsafe-to-concat and
safe-to-insert-tatweel glyph flags and a source-boundary view. For each source
cluster start, the unsafe bits **must** be the union of the flags on that
cluster's glyphs, irrespective of RTL pen order. A positive tatweel capability
**must** identify the source boundary to which the engine assigns it; contradictory
or unmappable information is unknown, not safe. Glyphless spans, cluster interiors
and run edges without an explicit engine/context guarantee **must** be unknown
for reuse. Raw glyph flags remain available with their engine meaning.
An unsafe break means that accepting a
break requires reshaping the affected fragments with their actual boundary context;
an unsafe concatenation means separately shaped fragments cannot be assumed to
equal a single shaping call. Absence of a warning **must** have the documented
meaning of the pinned engine, not a promise of Unicode break legality. A boundary
inside a merged source cluster is not a reusable cut. These flags constrain reuse
in layout; they neither select legal break opportunities nor justify estimating
contextual candidate widths from a previous paragraph run.

**FTS10: Caret data with provenance.** Font **must** expose GDEF ligature-caret
records in glyph pen coordinates, including coordinate, contour-point and
device/variation formats, resolved at the instance and direction used to shape.
Returned carets **must** identify the glyph and source cluster, retain the source
record order and label whether a value is explicit or derived from a referenced
outline point. Missing records, unsupported representations and malformed data
**must** be distinct. Font **must not** invent grapheme positions or equal-spaced
carets when data is absent; layout owns any synthesized caret policy and visual
mapping. Caret capacity exhaustion follows `FTS7`'s uncommitted-output rule.

**FTS11: Justification capabilities, not paragraph justification.** Font **must**
enumerate relevant GSUB/GPOS features and validated `JSTF` script/language,
extender-glyph and priority records when present, reporting absence and unsupported
records separately. A proposed candidate-measurement interface **must** accept
explicit feature settings/ranges and return the exact contextual shaped run under
`FTS7`, with its measured advances, coverage and safety flags. If a caller requests
a substitution/extension mode the pinned engine cannot execute, it **must** report
unsupported capability, never manufacture an advance or silently ignore the mode.
Font **must not** choose stretch/shrink budgets, distribute paragraph adjustments,
insert kashidas, select extender repetitions or mutate source text. Those choices
belong to layout; every accepted candidate is measured by real shaping. A
safe-to-insert-tatweel flag is an engine capability hint, not authorization to alter
source or a guarantee of the width of an insertion.

## 13. Discovery, matching and fallback

The requirements in this section are stated at contract level. Their
operation contracts are added to this section before they are implemented.

**FTD1: One catalog.** A font catalog **must** be built from [font sources](../../glossary.md#font-source) into [face
records](../../glossary.md#face-record) produced by this library's parser. No record's content **may** come
from a platform service's description of a font.

**FTD2: Platforms list files.** The platform source **must** list font files:
through fontconfig on Linux, Core Text on macOS, the system and per-user font
directories on Windows, and `/system/fonts` plus the application's assets on
Android. When a platform service is missing, the catalog **must** build from the
remaining sources and report why.

**FTD3: Persistent catalog.** Face records **must** be cached on disk, keyed by
path, collection index, file size and modification time, so an unchanged file is
not parsed again. The cache format is versioned; a cache of an unknown version
is discarded, not migrated.

**FTD4: Matching.** Matching a request **must** implement the [CSS Fonts
Level 4][css-match] font-matching algorithm over family, width, style and
weight. The result carries the chosen record, a comparable score, and the
synthesis needed to approximate the request.

**FTD5: Fallback chains.** A [fallback chain](../../glossary.md#fallback-chain)
**must** begin with the match and retain the ordered candidate records, including
faces with identical or subset `cmap` coverage that may add shaping capability.
A separate character-lookup index **may** prune redundant coverage, but that
index **must not** restrict `FTD7` whole-span trials. Coverage pruning may reject
a trial only when it proves that candidate cannot satisfy the requested span,
not merely because an earlier face covers the same scalars. A record's face opens
on first use; character/presentation and whole-span decisions have distinct,
context-complete memoization keys.

**FTD6: Explicit routes.** Codepoint-range routes chosen by the user and a
procedural face for box-drawing and block characters **must** take part in
the chain as ordinary entries.

_Rationale:_ Treating procedural glyphs as a face lets them share shaping,
caching and fallback with real fonts, instead of being a renderer special
case.

**FTD7: Whole-span fallback evidence.** For a caller-selected source span and
context under `FTS7`, the chain **must** expose ordered candidate faces and a
shaped trial result, including missing-glyph/source coverage, chosen instance and
selection provenance. `cmap` coverage is only a pruning mechanism, not proof that
an emoji sequence, mark sequence or contextual form shapes successfully. Font
**must not** silently split the requested span into per-codepoint fallback.
Layout owns span boundaries and any retry after examining base grapheme boundaries
and shaping safety. No usable face **must** be an explicit outcome with the
unresolved source span, not a fabricated successful shape.

## 14. Inspection

**FTI1: Reflectable tables.** Every typed table of `FTP7` **must** be a plain
struct, so a `sparkles:reflection` walk enumerates its fields under their
specification names.

**FTI2: Feature enumeration.** Layout features **must** be enumerable per
script and language system for both `GSUB` and `GPOS`, each with its lookup
indices.

**FTI3: Substitution records.** For each single, multiple, alternate and
ligature lookup reachable from a feature, the substitutions **must** be
enumerable as pairs of input and output glyph sequences. Contextual and
chaining lookups **must** report the lookups they invoke.

**FTI4: Colour capability.** The library **must** report which of `COLR`
version 0, `COLR` version 1, `CPAL`, `CBDT`, `sbix` and `SVG ` a face
contains, independent of which it renders.

**FTI5: Table directory.** The table directory **must** be enumerable with
each record's tag, offset, length, stored checksum and computed checksum,
including records `FTP3` declared unreadable.

**FTI6: Overlap flags.** For each glyph, the library **must** report whether
its outline data flags overlapping contours (`OVERLAP_SIMPLE` or
`OVERLAP_COMPOUND`), and report none for a face without `glyf`.

## 15. Consumers

**FTA12: No font code left behind.** Once its consumers use this library,
`sparkles:raylib-text` **must** contain no font parsing, discovery, shaping or
rasterization, and no C source file. It uploads and draws coverage this
library produces.

**FTA13: Android.** The Android builds of `hue` and `terminal` **must** build
with this library and render the bundled fonts without fontconfig.

**FTA14: Visible rendering changes.** A rendering change caused by moving a
consumer onto this library **must** be either byte-identical in that
consumer's screenshot goldens or listed with before-and-after captures in the
evidence ledger.

**FTA16: No universal glyph-per-cell assumption.** A cell consumer **may** use
glyph-index-to-cell-index placement only for a run whose font, features and input
have passed the audited fast-path conditions of `FTX7`. General consumers **must**
honor the returned glyph positions and source-cluster coverage, including ligature
merges, multiple glyphs per scalar, marks, RTL and fallback. Layout's placement
and hit-testing contracts are owned by [`text-layout`](../text-layout/SPEC.md);
font supplies the measurements and provenance needed to satisfy them.

The [design system](../design-system/SPEC.md) names typefaces through
[font roles](../../glossary.md#font-role), such as the monospace and sans faces of
the [Sparkles theme](../design-system/sparkles-theme.md). A role's value resolves
to the inputs this library already defines: a font request matched under `FTD4`,
a fallback chain under `FTD5`, and code-point routes under `FTD6`, for example the
Private Use Area routed to a Nerd Font face. This library has no role concept; the
design system owns the roles and their mapping onto those inputs.

<!-- References -->

[research]: ../../research/font-libraries/index.md
[concepts]: ../../research/font-libraries/concepts.md
[ot-spec]: https://learn.microsoft.com/en-us/typography/opentype/spec/
[css-match]: https://www.w3.org/TR/css-fonts-4/#font-matching-algorithm
