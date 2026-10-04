---
status: draft
owner: sparkles:font
reviewed:
---

# `sparkles:font` — Decisions

The consequential choices behind [`SPEC.md`](./SPEC.md), with the evidence and
trade-offs of each, and the open questions that block named requirements. A
decision is `proposed` until the specification is accepted.

## Exclusions and entry conditions

Each capability below is outside the specification. An entry condition says
what evidence would bring it back; without one, the item is not planned.

| Excluded                                | Why                                                                                            | Entry condition                                                                                                     |
| --------------------------------------- | ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Line breaking, bidi, paragraph layout   | Base owns analysis/opportunities and generic solving; text-layout owns contextual composition. | None in this library; link their owning contracts.                                                                  |
| Hinting, bytecode or automatic          | The largest single part of every rasterizer that has it.                                       | A measured legibility gap at terminal sizes on a low-DPI panel that gamma-corrected unhinted coverage cannot close. |
| LCD subpixel anti-aliasing              | Colour fringes off RGB-stripe panels; cannot composite over arbitrary backgrounds.             | None.                                                                                                               |
| `COLR` version 1 rendering              | A paint graph with gradients and compositing, a small renderer of its own.                     | After `COLR` version 0 ships, when a consumer needs it.                                                             |
| `SVG ` glyphs                           | Needs an SVG renderer.                                                                         | None.                                                                                                               |
| WOFF and WOFF2                          | Web containers; WOFF2 needs a Brotli decoder and table reconstruction.                         | A consumer that must open web fonts.                                                                                |
| Type 1 and `dfont`                      | Legacy formats.                                                                                | None.                                                                                                               |
| Writing, subsetting or instancing files | No consumer writes fonts.                                                                      | None.                                                                                                               |
| A D OpenType shaping engine             | See `FTX1`.                                                                                    | A target that must shape and cannot link HarfBuzz.                                                                  |
| GPU rasterization                       | Bitmap specimens and cell glyphs do not need it.                                               | A consumer drawing transformed or continuously zoomed text.                                                         |
| Font activation, network catalogs       | Application features, not library features.                                                    | None in this library.                                                                                               |
| Math composition, pagination and export | Font supplies `MATH`/baseline/justification resources, not formula or page policy.             | None in this library; composition and frontends remain above font.                                                  |

---

## Settled scope (2026-10-02 design interview)

These were decided by the project owner in the interview that scoped the font
explorer, before the research ran. They bound this specification rather than
being decided by it:

- The `raylib-text` FreeType/HarfBuzz code from PR #555 was a spike; the font
  stack is **rewritten from scratch**, with no compatibility obligation outside
  the repository. Every in-repository consumer is updated.
- **One library** with configurations, not several packages. Discovery and DPI
  arithmetic move out of `raylib-text` into it.
- **D wherever possible**; a C shim is to be minimized. GPU compute through
  `sparkles:shader` is available if needed.
- The Android `hue` APK building is a **hard gate** for the migration.
- Formats in: TrueType, CFF-flavoured OpenType, collections. Bitmap emoji and
  `COLR` v0 in. WOFF, WOFF2, Type 1 and `dfont` out.

---

## FTX1: HarfBuzz is the shaper

**State:** proposed · **Affects:** `FTS1`–`FTS11`, the `engine` configuration

**Question.** Write an OpenType shaping engine in D, or use HarfBuzz?

**Evidence.** Every independent shaper surveyed costs 16–30 thousand lines:
[rustybuzz][rustybuzz] (~17 KLOC, a HarfBuzz port, archived in favour of a fresh
port because it could not keep up), [go-text][go-text] (~16 KLOC port,
maintained by porting releases), [Allsorts][allsorts] (~17 KLOC, independent),
[SixLabors.Fonts][sixlabors] (~30 KLOC of C#). HarfBuzz is already in every
consumer's link closure since PR #555.

**Choice.** HarfBuzz, in the `engine` configuration only, so the `library`
configuration stays free of C dependencies.

**Trade-off.** Shaping cannot run where HarfBuzz is not available; `wasm32`
would need HarfBuzz compiled for it. Shaping bugs are HarfBuzz's to fix
upstream.

**Revisit when** a target that must shape cannot link HarfBuzz.

## FTX2: HarfBuzz through hand-declared prototypes

**State:** proposed · **Affects:** `FTA8`, `FTS6`

**Question.** Reach HarfBuzz through ImportC of `hb.h`, a C shim, or
hand-declared `extern(C)` prototypes?

**Evidence.** Both research examples drive HarfBuzz — faces, fonts, buffers,
shaping, variations, axis queries, outline drawing — with hand-declared
prototypes over opaque handles and five plain structs, and run under `ci`. A C
shim was the spike's approach and is what this rewrite removes. ImportC of
`hb.h` through a package forces `sourceLibrary` on every package between it and
the executable, which already broke the macOS build once for `sparkles:ghostty`.

**Choice.** Hand-declared prototypes in one module. The risk that hand-written
layouts drift from the headers is closed by `FTS6`: a test-only ImportC file
checks sizes and offsets against the installed headers, so drift fails a test
instead of corrupting memory.

**Trade-off.** Each further HarfBuzz function is declared by hand.

## FTX3: An own parser; FreeType is an oracle, not a dependency

**State:** proposed · **Affects:** `FTP*`, `FTO*`, `FTR1`–`FTR3`, `FTA7`

**Question.** Parse and rasterize through FreeType, or in D?

**Evidence.** The research verdict for a D CPU rasterizer is go: the
signed-area accumulation core is 71 lines in the [research example][ex-raster]
and ~200 lines in fontdue and ab_glyph, and Fontations proves an own outline
path differentially against FreeType. The explorer must expose every table and
feature, which no rasterization library's API does; an own parser is needed for
inspection regardless. Hinting, the one part that is large, is a non-goal.

**Choice.** Parsing, outlines and rasterization in D. FreeType stays in the dev
shell as the rasterization **oracle** for `FTR3`, never as a runtime
dependency.

**Trade-off.** Unhinted text on low-DPI panels is softer than FreeType's hinted
output; this is accepted, with the hinting entry condition under [exclusions](#exclusions-and-entry-conditions).

## FTX4: PNG strikes decoded in D over Phobos's zlib

**State:** proposed · **Affects:** `FTR7`, `FTA14`

**Question.** How are `CBDT` and `sbix` colour glyphs (the bundled Noto Color
Emoji is a `CBDT` font with no outlines) rendered without FreeType?

**Evidence.** LDC 1.42's `libphobos2-ldc` defines `inflate` and
`inflateInit2_` itself (an `inflate.c.o` member, checked with `nm` on the
installed library), so `etc.c.zlib` needs no extra library. PNG decoding past
inflate is filter reversal and palette expansion.

**Choice.** A D PNG decoder limited to what emoji fonts use (`FTR7`), delivered
before the terminal migration so emoji do not regress.

**Trade-off.** Interlaced or 16-bit PNGs in a font are refused rather than
decoded; no surveyed emoji font uses them, and the refusal is a reported error.

## FTX5: Platform services list files; the library describes faces

**State:** proposed · **Affects:** `FTD1`–`FTD3`

**Question.** Should matching use fontconfig, Core Text and DirectWrite's own
matchers, or one matcher over records this library produces?

**Evidence.** Android has none of these services, so one path must exist
without them anyway; the bundled fonts carry precomputed `.charset` sidecars for that
reason. [crossfont][crossfont] and [Ghostty][ghostty] show charset-pruned
fallback, [go-text][go-text]'s `Footprint` shows a cached record as the unit of
a font list, and [font-kit][font-kit] shows the cost of describing faces without
a cache.

**Choice.** Platforms contribute **file lists** only (`FTD2`). Records,
matching and fallback are this library's on every platform, so behaviour is
testable and identical everywhere.

**Trade-off.** User fontconfig rules (aliases, rejections, per-font rendering
preferences) are not honoured. **Revisit when** a user-visible mismatch with the
system's fallback is reported.

## FTX6: Requirement prefixes

**State:** proposed

`FT` plus a letter per area: `FTA` architecture, `FTB` trust boundary, `FTP`
parsing, `FTV` variation, `FTM` metrics, `FTO` outlines, `FTR` rasterization,
`FTS` shaping, `FTD` discovery, `FTI` inspection; `FTX` decisions and `FTQ`
open questions. None was in use under `docs/specs/` on 2026-10-03.

## FTX7: Ligatures keep one glyph per cell; their ink crosses cells

**State:** proposed · **Affects:** `FTR1`, `FTS4`, `FTA16`, milestone M8 ·
**Resolves:** `FTQ3` for the measured corpus, not arbitrary OpenType text

**Question.** Does any common programming font's `calt` or `liga` merge
characters into fewer glyphs, so that a terminal would need multi-cell glyph
placement?

**Evidence.** [`ligature-cells.d`][ex-ligature] shaped 160 ligature sequences,
the union of the four fonts' inventories, each as `a<seq>b` with `calt` and
`liga` on and off, on 2026-10-03. "Reach" is how far, in cells, a glyph's ink
extends outside the cell its advance occupies.

| Face                                | Shaped differently | Glyph count changed | Off-cell advance | Ink outside own cell | Worst reach      |
| ----------------------------------- | ------------------ | ------------------- | ---------------- | -------------------- | ---------------- |
| Cascadia Code 2407.24               | 131                | 0                   | 0                | 126                  | 2.77 (`<!--`)    |
| Cascadia Code NF 2407.24            | 131                | 0                   | 0                | 126                  | 2.77 (`<!--`)    |
| JetBrains Mono 2.304                | 127                | 0                   | 0                | 127                  | 2.89 (`####`)    |
| JetBrains Mono Nerd Font Mono 3.4.0 | 127                | 0                   | 0                | 127                  | 2.89 (`####`)    |
| Fira Code 6.2 (variable)            | 138                | 0                   | 0                | 122                  | 2.95 (`<!--`)    |
| Fira Code Nerd Font Mono 3.4.0      | 138                | 0                   | 0                | 122                  | 2.96 (`<!--`)    |
| Maple Mono 7.9                      | 124                | 0                   | 0                | 117                  | 6.00 (`[ERROR]`) |
| Maple Mono NF CN 7.9                | 126                | 0                   | 0                | 119                  | 6.00 (`[ERROR]`) |

In those measured samples every face keeps one glyph per character at the cell
advance: a ligature is drawn by spacer glyphs, the last of which carries the whole
shape and reaches back over the cells before it.

**Choice.** Glyph _i_ in cell _i_ is an audited fast path, not the library's
general placement contract. A run may take it only when its selected face,
instance, features, input and cluster mapping establish one glyph per source
cell with cell-grid advances. The measured 160 sequences establish feasibility
for those eight face builds, not all strings or future versions of those fonts.
A failed or unavailable audit routes through general shaped positions and
source-cluster spans; it does not misalign or reject an otherwise valid shape.
Both paths **do not clip** ink to a glyph's nominal cell, and redraw every cell
the ink reaches when any of them changes. `FTR1` ink bounds determine damage,
not advance or source coverage.

**Trade-off.** General placement must handle ligature merges, spacer glyphs,
multiple marks, RTL traversal and multi-cell source spans. The explorer's
[cell-grid audit](../../glossary.md#cell-grid-audit) reports which inputs satisfy
the fast path; it is not a condition for correct general shaping. This narrowing
retains the measured evidence while removing the inference that OpenType permits
a universal glyph-index-to-cell-index mapping.

## FTX8: The catalog builds synchronously over a worker pool

**State:** proposed · **Affects:** `FTD1`–`FTD3`, milestone M7 ·
**Resolves:** `FTQ2`

**Question.** Is describing every font file on a machine fast enough to do
synchronously at launch, or does the catalog need a background builder and a
progress surface?

**Evidence.** [`font-scan-timing.d`][ex-scan] reads the table directory, the
family name, the `OS/2` weight class and the code-point coverage of the best
Unicode `cmap` subtable of every face, through `mmap`, on 2026-10-03 (AMD
Ryzen 9 7940HX, NVMe, ZFS):

| Font set                      | Files | Size    | First pass | Warm, serial | Warm, 4 workers |
| ----------------------------- | ----- | ------- | ---------- | ------------ | --------------- |
| Linux desktop (`fc-list`)     | 2,222 | 2.85 GB | 1,564 ms   | 44 ms        | 20 ms           |
| The bundle (`sparkles-fonts`) | 180   | 125 MB  | 23 ms      | 1.9 ms       | 1.8 ms          |

The desktop's first pass read files no process had read since boot; it is the
only cold figure, because eviction needs root and ZFS's cache ignores
`posix_fadvise`. Neither set holds a collection, so each file is one face.

**Choice.** The catalog builds synchronously, on a worker pool, with no
background builder and no progress surface. The `FTD3` cache stays: it turns
the cold first launch after boot into one `stat` per file.

**Trade-off.** A cold launch with a stale cache over a large font set blocks
for over a second, measured here at 1.6 s single-threaded. **Revisit when** a
warm build exceeds 1 s on a supported platform; Android's `/system/fonts` and
macOS are not yet measured.

## FTX9: Flatten to 0.02 px; render the union of flagged glyphs

**State:** accepted 2026-10-04 · **Affects:** `FTR1`–`FTR3`, `FTR8`, `FTI6`,
milestone M5 · **Resolves:** `FTQ4`

**Question.** How does the accumulation rasterizer flatten curves, and how
does it keep overlapping contours from doubling edge coverage (`FTR2`)?

**Evidence.** Spike S2 ran [`raster-oracle-diff.d`][ex-oracle] over the
48,330 glyphs of four bundled faces at four sizes (testing.md § Raster
oracle). Plain accumulation adds the coverage of every edge that crosses a
pixel, so a pixel half-covered by the edges of two overlapping contours reads
as fully covered. Maple Mono NF CN builds its CJK glyphs from overlapping
strokes; there, 59% of glyphs differed from FreeType by more than 32 steps,
the worst by 123. FreeType avoids this only for glyphs whose `glyf` data sets
`OVERLAP_SIMPLE` or `OVERLAP_COMPOUND`, 22,931 of that face's 33,637: it
renders them at 4×4 and averages ([`ttgload.c`][ft-ttgload],
[`ftsmooth.c`][ft-smooth]). Doing the same brought every glyph of the face
within 33 steps. Supersampling every glyph costs 6–10× a plain render: 11–33
µs rise to 64–327 µs per glyph from 12 to 48 px on Fira Code Nerd Font Mono.

No surveyed library computes the union exactly and cheaply. fontdue,
[ab_glyph][ab-glyph], [stb_truetype][stb] and Go's `x/image/vector` all
accumulate signed area and over-cover overlaps; [Vello][vello]'s exact-area
mode documents the same "conflation artifacts" and escapes only through
multisampling. [Fontations][fontations] reports the flag to its renderer as
`has_overlaps`.

Overlaps without the flag are common. Comparing each unflagged glyph with its
4×4 render at 24 px, 192 glyphs of Fira Code Nerd Font Mono and 428 of the
1,392 in Noto Sans Arabic differ by more than 32 steps. Noto Sans Arabic is a
variable font that overlaps its contours and sets no flag; FreeType renders it
the same way, which the matching FreeType comparison confirms.

**Choice.** Curves are flattened adaptively to 0.02 px. A glyph flagged
`OVERLAP_SIMPLE` or `OVERLAP_COMPOUND` renders at 4×4 and is averaged; every
other glyph renders by plain accumulation, which is FreeType's rule. The
caller may request the 4×4 union for every glyph, and the library reports each
glyph's flag (`FTI6`), so the font explorer can find unflagged overlaps.

**Trade-off.** Unflagged overlaps, including Noto Sans Arabic's joins, render
with darker edges where contours overlap, exactly as under FreeType.
**Revisit when** a side-by-side capture at a terminal size shows that
darkening in a face users rely on; the remedy then is the union for that face,
not for every glyph.

## FTX10: Two raster oracles

**State:** accepted 2026-10-04 · **Affects:** `FTR3`, `FTR8`, milestone M5 ·
**Resolves:** `FTQ1`

**Question.** What tolerance against FreeType makes `FTR3` falsifiable,
when the two rasterizers flatten curves differently?

**Evidence.** Against FreeType with default flattening, the largest per-pixel
difference was 33 steps on TrueType faces and 53 on the CFF face. Reproducing
FreeType's flattening rules in the D sink lowered the median glyph maximum to
3 or 4 on every face: most of that difference is FreeType's flattening, which
bisects a cubic only until each control point is within about 1/6 px of a
trisection point of its chord. A tolerance wide enough for it would hide errors
in the accumulation arithmetic. Fontations' `PathStyle::FreeType` and
`PathStyle::HarfBuzz` reproduce each engine's outline quirks bit for bit, which
is the precedent for a compatibility policy.

**Choice.** Two checks, each tight. `FTR3` compares with FreeType under a
flattening policy that reproduces `ftgrays.c`, so it measures the arithmetic.
`FTR8` compares default flattening with the same rasterizer at 0.001 px, so it
measures the flattening. testing.md § Raster oracle records both tolerances.

**Trade-off.** The library carries a flattening policy whose only purpose is
compatibility. It is a few dozen lines and is also useful to a consumer that
must match FreeType's rendering.

## FTX11: One owner for Unicode and paragraph semantics

**State:** proposed 2026-10-04 · **Affects:** `FTA15`, `FTS7`–`FTS9`, `FTD7`

**Question.** Should font continue exposing shaping as an isolated UTF-8 string
operation, with independently guessed Unicode properties and paragraph context?

**Choice.** Font depends on [base's owned text foundation](../base/text/SPEC.md),
never on [text-layout](../text-layout/SPEC.md). Base owns UTF/Unicode analysis and
[generic wrapping](../base/text/wrapping.md); layout owns paragraph context,
candidate composition and visual mappings. Font consumes explicit segment
properties and supplies real contextual measurements, safety flags and whole-span
fallback evidence. Standalone property guessing remains a named convenience,
not a parallel owning paragraph-analysis path.

**Trade-off.** Callers must preserve source context and distinguish actual text
boundaries from style/script/fallback boundaries. The font-to-layout cutover
updates every caller and removes competing decoding/segmentation/placement
helpers. A layout candidate cannot be measured by summing nominal advances or
reusing unsafe shaped fragments.

**Evidence state.** This is a draft boundary contract, not a font implementation
result. The 2026-10-04 text-foundation scope instruction does not settle the
independent font Stage 0 acceptance or establish adversarial reviewer signoff.

## FTX12: Unicode callbacks do not replace an engine compatibility profile

**State:** proposed 2026-10-04 · **Affects:** `FTS8`, milestone M4

**Question.** Is installing base-backed HarfBuzz Unicode callbacks enough to
ensure all shaping uses the selected Unicode release?

**Choice.** Install all supported callbacks from the pinned base data, and pin
the exact engine release/revision with an audited compatibility manifest for
internal tables and algorithms that callbacks cannot replace. A callback-only
claim is insufficient; an uncovered mismatch blocks coordinated shaping.
No runtime font path fetches data or inherits the compiler's Unicode version.

**Trade-off.** Updating HarfBuzz or base's Unicode release is an explicit
compatibility-profile update and real-font acceptance run. The ABI layout test
does not prove Unicode compatibility, and the engine's own goldens are not an
independent shaping oracle. An unsupported system engine is reported rather than
used under a misleading profile.

## FTX13: Scalable resources below publication composition

**State:** proposed 2026-10-04 · **Affects:** `FTP13`, `FTM4`–`FTM7`,
`FTS10`–`FTS11`, milestones M2/M4

**Question.** Can pixel-only measurements and feature names serve contextual
paragraphs, vertical writing and mathematical publication?

**Choice.** Add design-unit and base-owned physical-unit measurements while
retaining fractional pixel convenience and whole-device-pixel cell metrics.
Expose `MATH`, `BASE`, vertical metrics, GDEF carets and justification capability
records with explicit absence/provenance and actual candidate shaping.
Ink and advance remain different quantities. Font supplies data; math composition,
justification policy, pages and export do not move into font.

**Trade-off.** Real math, vertical and caret/justification corpus evidence is a
delivery prerequisite, not optional demonstration. Missing tables are legal
font inputs, but testing only their absence cannot accept a supported capability.
The acceptance manifest records the pinned faces and measured values; no such
measurement is claimed by this decision.

---

## Open questions

### FTQ1: Raster tolerance for `FTR3`

Answered by spike S2; see [`FTX10`](#ftx10-two-raster-oracles).

### FTQ2: Background or synchronous scanning

Answered by spike S1; see [`FTX8`](#ftx8-the-catalog-builds-synchronously-over-a-worker-pool).

### FTQ3: Ligatures that change glyph count in a cell grid

Answered by spike S3; see [`FTX7`](#ftx7-ligatures-keep-one-glyph-per-cell-their-ink-crosses-cells).

### FTQ4: Overlaps the font does not flag

Answered on review of spike S2; see
[`FTX9`](#ftx9-flatten-to-0-02-px-render-the-union-of-flagged-glyphs).

<!-- References -->

[rustybuzz]: ../../research/font-libraries/rustybuzz.md
[go-text]: ../../research/font-libraries/go-text-typesetting.md
[allsorts]: ../../research/font-libraries/allsorts.md
[sixlabors]: ../../research/font-libraries/sixlabors-fonts.md
[crossfont]: ../../research/font-libraries/crossfont.md
[ghostty]: ../../research/font-libraries/ghostty.md
[font-kit]: ../../research/font-libraries/font-kit.md
[ex-raster]: ../../research/font-libraries/examples/outline-sink-raster.d
[ex-ligature]: ../../research/font-libraries/examples/ligature-cells.d
[ex-scan]: ../../research/font-libraries/examples/font-scan-timing.d
[ex-oracle]: ../../research/font-libraries/examples/raster-oracle-diff.d
[ft-ttgload]: https://github.com/freetype/freetype/blob/aff94e1306400217dfd14a35009418d142871f87/src/truetype/ttgload.c#L461
[ft-smooth]: https://github.com/freetype/freetype/blob/aff94e1306400217dfd14a35009418d142871f87/src/smooth/ftsmooth.c#L628
[ab-glyph]: ../../research/font-libraries/ab-glyph.md
[stb]: ../../research/font-libraries/stb-truetype.md
[vello]: ../../research/font-libraries/vello.md
[fontations]: ../../research/font-libraries/fontations.md

## Text-foundation extension review

The 2026-10-04 coordinated text-foundation extension received a separate read-only
adversarial review of contextual shaping, units, source-cluster coverage, safety
flags, caret data, publication font capabilities and fallback. The reviewer found
that FTD5 coverage-only admission contradicted FTD7 whole-span shaping trials.
FTD5 now retains shaping candidates with identical/subset character coverage and
keeps scalar coverage pruning separate; the real-sequence acceptance scenario in
testing.md checks chosen face, glyphs and source outcome. A final scoped recheck
found that blocker resolved.

This review covers the text-foundation extensions, not independent acceptance of
the entire font Stage 0 or an absent font implementation. Existing raster-spike
evidence remains scoped to its measured fonts, sizes and revisions.

## M1 operation-contract review

On 2026-10-05 an independent read-only reviewer walked the first draft of
[`parsing.md`](./parsing.md) and `SPEC.md` § 2–7 against HarfBuzz and
FreeType sources, with fourteen traces: a TrueType and a `CFF` success, seven
failures (a truncated `head`, an unsorted directory with a duplicate tag, a
malformed preferred `cmap` subtable, `post` 2.0 with a glyph-count mismatch, a
UTF-16 name with an unpaired surrogate, a format-12 group past U+10FFFF, a
collection index out of range) and five boundaries (4,096 and 4,097 directory
records, an offset plus length past 32 bits, `numberOfHMetrics` equal to the
glyph count and to 1, a wrapping format-4 segment). Its findings and their
dispositions:

| Finding                                                                                                                                                                                                                                   | Disposition                                                                                                                                                                                                                                                |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Blocker: duplicate tags failed the open in `FTP3` but not in the draft                                                                                                                                                                    | `FTP3` amended: the first record is the table, later ones are reported (`FTP21`).                                                                                                                                                                          |
| Blocker: the subtable order ignored symbol (3/0) and Macintosh subtables                                                                                                                                                                  | `FTP9` amended and `FTP25` adopts HarfBuzz's order, with the symbol remap and Mac Roman conversion.                                                                                                                                                        |
| Blocker: strict validation with no fallback refused fonts both engines render                                                                                                                                                             | `FTP25`–`FTP26`: lenient checks (a corrected `length`, overlapping format-4 segments, out-of-range targets unmapped), then the next subtable; every rejection is counted and reported. Where the checks differ from FreeType's, `parsing.md` § 7 lists it. |
| Blocker: overlapping format-4 segments broke the linear bound and the sorted ranges                                                                                                                                                       | `FTP26`: effective spans `[max(start, previous end + 1), end]`; bound O(L + 65,536).                                                                                                                                                                       |
| Major: a quadratic duplicate check at open contradicted `FTP5`                                                                                                                                                                            | `FTP20`: open is O(r); duplicate flags are computed by inspection (`FTP33`).                                                                                                                                                                               |
| Major: static name tables broke the borrowing rule                                                                                                                                                                                        | `FTP16` allows immutable static data.                                                                                                                                                                                                                      |
| Major: `post` version cases undefined; HarfBuzz rejects 2.5                                                                                                                                                                               | `FTP30` result table; FreeType is the 2.5 oracle (§ 7 of `parsing.md`).                                                                                                                                                                                    |
| Major: "no usable `post` names" undefined; predefined charsets missing; no `CFF` name index                                                                                                                                               | `FTP31`: per-glyph fallback, the three predefined charsets, `glyphNameIndex` covers `CFF`.                                                                                                                                                                 |
| Major: oracles diverge from the contract by design                                                                                                                                                                                        | `parsing.md` § 7 lists each divergence with its substitute oracle.                                                                                                                                                                                         |
| Major: `checkSumAdjustment` cost and meaning for collections                                                                                                                                                                              | `FTP33`: whole buffer for a single font, not applicable in a collection.                                                                                                                                                                                   |
| Major: error kinds missing                                                                                                                                                                                                                | `FTP26` names an error per check; `FTP29` gives `decodedLength` the decode error; `avar` no longer depends on `fvar` in M1.                                                                                                                                |
| Minor: wrong cross-reference, Mac Roman language variants, `head` version, `indexToLocFormat` at open, `fvar` `instanceSize`, unsourced table-count claim, version-0 language IDs, error offsets for invalid tables, the limit's identity | Each fixed in `parsing.md`; the table-count claim now cites 2,402 measured faces. `FTP14` carries an absolute offset always, and a table offset when the table is readable.                                                                                |

The review confirmed the `OS/2`, `head`, `maxp` and `post` length rules, the
391 standard `CFF` strings, and the format-12 rule for glyphs past
`numGlyphs`.

The same reviewer then rechecked the repaired draft. All eleven repeated
traces, and a new one for a symbol font, now have a single correct outcome,
and no blocker remains. Its remaining findings and their dispositions:

| Finding                                                                                                                                                                                                                                                                                                       | Disposition                                                                                                  |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Major: trimming format-12/13 groups against the previous end did not keep spans disjoint                                                                                                                                                                                                                      | `FTP26` also requires group ends to be non-decreasing, so effective spans stay disjoint.                     |
| Major: four oracle divergences missing (symbol and Mac Roman coverage, format-4 overlap resolution, `hmtx` leniency, the `post`-to-`CFF` fallback on error)                                                                                                                                                   | Listed in `parsing.md` § 7 with substitutes; `FTP31` now falls back on a `post` error too, as HarfBuzz does. |
| Minor: `FTP10` cost, the rejection error on `CharMap`, HarfBuzz's Arabic remap, format-14 error kinds and out-of-range variants, format 6 past 65,536, glyph-ID arithmetic, spacing with truncated entries, the `glyphNameIndex` scratch length, a truncated format-0 charset, the Top DICT in the cost bound | Each fixed in `parsing.md` or `SPEC.md`.                                                                     |

The reviewer's gate verdict: with these fixed, the M1 contracts meet the Stage
0 criterion of first-slice contracts at operation level with oracles.
