---
status: accepted
owner: sparkles:font
reviewed: 2026-10-06
---

# `sparkles:font` — Testing and evidence

Oracles, acceptance scenarios and the evidence ledger for the requirements in
[`SPEC.md`](./SPEC.md). Each requirement is checked against an implementation
that shares no code with this library, or against traces worked by hand.

## Oracle independence

The library's correctness claims are checked against implementations that share
no code with it. The table says which oracle backs which requirements and why it
is independent.

| Oracle                                  | Independent because                                                                               | Checks                                                                                                                                                                                                                                                                |
| --------------------------------------- | ------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **HarfBuzz's own OpenType parsers**     | A separate C++ implementation, reached from D tests by `extern(C)`                                | upem and glyph count; `name` strings (`hb_ot_name_get_utf8`); coverage (`hb_face_collect_unicodes`); `cmap` lookups; axes and normalization; advances and metrics; outlines; layout features; resolved `MATH`, `BASE`, vertical metrics and GDEF carets where exposed |
| **FreeType**                            | A separate C implementation of parsing and rasterization                                          | per-pixel coverage of unhinted renders (`FTR3`); `CFF` outlines as a second opinion                                                                                                                                                                                   |
| **fontTools** (developer machines only) | A separate Python implementation; the reference most tools copy                                   | raw fields HarfBuzz does not expose, including `MATH` assemblies, `BASE` records, vertical tables and `JSTF`; committed goldens record the generating command and font hash                                                                                           |
| **Hand-derived traces**                 | Worked from the OpenType and CSS specifications by hand                                           | normalization arithmetic; `cmap` selection; line-metric rule; physical conversion and arithmetic exhaustion; cluster source partitions in both directions; math-kern height selection and connector constraints; CSS matching; PNG filter reversal                    |
| **Hostile-input fixtures**              | Built by a test-only byte builder, with expectations from the trust contract, not from the parser | every `FTB*` limit and failure kind                                                                                                                                                                                                                                   |

HarfBuzz is also the shaping engine (`FTX1`), so it cannot be an independent
oracle for shaping itself. Recorded `hb-shape` output through a separate call
path can check wrapper compatibility, but forwarding checks alone do not establish
consumer correctness. Context, source-coverage and reusable-cut scenarios below
also check observable source partitions and compare actual full/fragment shaping
under explicit boundary conditions. FontTools/hand traces independently establish
table semantics; no shaping-engine differential is called independent.

Differential tests inherit upstream defects. A disagreement is a finding to
triage, not automatically this library's bug; triaged upstream divergences are
listed in the ledger with the HarfBuzz or FreeType revision.

## Corpus

- **Bundled fonts.** The `sparkles-fonts` package (Maple Mono NF CN, Fira Code
  Nerd Font Mono, DejaVu Sans Mono, Uiua386, the Noto Sans script set including
  variable faces, Noto Color Emoji; about 180 faces). Exposed to tests as
  `$SPARKLES_FONTS_PATH`, a derived-package variable set by the dev shell. Tests
  needing it **skip** when it is unset, and a gate that requires corpus evidence
  is unmet until a run with it set passes.
- **Committed fixtures.** Small fonts and malformed byte sequences built by a
  test-only byte builder, `libs/font/test/sparkles/font/fixtures.d`, so the
  parser's unit tests run with no environment.
- **System fonts** are never a test input: they differ between machines.

The publication corpus must add at least one real OpenType math face (a candidate
is STIX Two Math), one verified horizontal/vertical `BASE` and vertical-metrics
face, and real shaping faces whose GSUB/GPOS/GDEF tables exercise ligature merges,
marks and caret records. These are acquisition requirements, not claims that the
bundle contains them. Before accepting a gate, a manifest records file SHA-256,
collection index, license, upstream release/source revision, table inventory,
selected glyphs/strings, axes, features, direction/script/language, physical em
size and expected values with generating commands. A real `JSTF` corpus face is
required for corpus evidence of that table; synthetic table fixtures additionally
cover rarely available formats and failures. A missing face, missing table or
missing engine capability leaves the corresponding gate unmet, never a zero-case
pass. Font versions/feature effects must be inspected, not inferred from a family
name. Every shaping run also records base's Unicode release/algorithm manifest and
the exact compatible HarfBuzz build.

## Author-worked first-delivery traces

These traces were authored for the 2026-10-04 contract extension. They are
paper checks of proposed M1 operations, not executed tests, independent review
or acceptance evidence. The fixture builder and `libs/font` remain delivery
targets; an adversarial reviewer must challenge these traces and the eventual
implementation must reproduce their outcomes.

**Successful borrowed open and lookup.** Construct a 422-byte TrueType fixture:
the 12-byte sfnt header declares three directory records; `head` is at offset 60,
length 54; `maxp` at 116, length 32; `cmap` at 148, length 274. The two bytes
between `head` and `maxp` are padding. Use a valid version-1 `head` with
units-per-em 2048 and magic `0x5F0F3CF5`, version-1 `maxp` with two glyphs, and a
version-0 `cmap` with one platform-3/encoding-1 record pointing to a format-0
subtable of length 262. That subtable maps U+0041 to glyph 1 and every other
entry to glyph 0. Set the sfnt search fields for three records and all remaining
required fields to their legal fixture values.

Opening face 0 reads the directory and required fixed headers; it returns a
borrowed immutable face with upem 2048 and glyph count 2, without decoding the
`cmap` glyph array (`FTP5`). A subsequent lookup maps U+0041 to 1 and U+0042
to 0. Raw `head` access is exactly the source slice `[60,114)`, not a copy.
A `name` query returns `missingTable`; collection face index 1 returns
`indexOutOfRange`, without replacing the face already opened at index 0.
The caller must retain the entire source buffer until that face and all borrowed
results are destroyed.

**Exact-end and one-byte-short boundary.** In the same fixture,
`148 + 274 = 422`, so `cmap` ends exactly at the buffer boundary and opening is
valid. Borrow only the first 421 bytes while keeping the declared record unchanged:
the checked `cmap` offset/length no longer fits, so `FTP3` reports `badOffset`
and opening fails because `cmap` is required. It must not read byte 421, construct
a partially usable face or turn the hostile truncation into an assertion.

**Optional-table failure stays local.** Extend the directory to four records and
relocate the three valid tables by 16 bytes, giving a 438-byte buffer. Add a `name`
record at offset 438 with length 2. Its range is invalid, but the required tables
remain valid: opening succeeds, reading `name` reports `badOffset`, and the
directory inspector still enumerates its tag/offset/length. An absent `name`
record instead reports `missingTable`; these outcomes must not be conflated.

**Strict name-decoding failure.** A UTF-16BE name payload
`00 41 D8 3D DE 00` decodes to U+0041 followed by U+1F600, encoded as UTF-8
`41 F0 9F 98 80`. Replace its final pair with `00 42`: `D8 3D` is then an
unpaired high surrogate, so strict base decoding returns `invalidEncoding` at
that surrogate's table-relative byte offset and publishes no partial name.
The neighboring valid record remains readable and the malformed raw payload
remains inspectable (`FTP8`, `FTA11`, `FTA15`).

## Requirement scenarios

### Parsing (`FTP1`–`FTP12`)

- For every bundled face: open succeeds; `upem`, glyph count, every `name`
  record, coverage ranges, and `charMap.glyph` for every covered codepoint equal
  HarfBuzz's answers.
- For each collection in the corpus and a committed two-face collection: the
  face count, and each face's `name` ID 4, equal HarfBuzz's; index =
  count is `indexOutOfRange`.
- Signature cases: WOFF and WOFF2 signatures give `unsupportedVersion`; four
  random bytes give `notAFont`.
- `cmap` selection: a committed font with both a format-4 and a format-12
  subtable mapping one codepoint to different glyphs selects format 12.
- `FTP12`: Maple Mono NF CN reports `dual`, DejaVu Sans Mono `mono`, Noto
  Sans `proportional`.
- `FTP8`/`FTA15`: a name-record fixture decodes BMP and supplementary-plane
  UTF-16BE exactly, including a valid surrogate pair. Isolated high/low surrogates,
  a reversed pair and an odd byte count produce `invalidEncoding` at the offending
  record offset with decoded-output sentinels unchanged; a neighboring valid
  record still decodes and malformed raw bytes remain inspectable.

### Variation normalization

For every axis of every variable bundled face, at the minimum, default, maximum
and 17 evenly spaced user values: normalized `F2Dot14` values equal
`hb_ot_var_normalize_coords`. Hand-derived traces cover an `avar` map with a
non-identity segment and a clamp beyond the axis range.

### Metrics and publication data (`FTM1`–`FTM7`, `FTP13`)

For every bundled face, the three vertical sets, x-height, cap height, underline
and strikeout equal `hb_ot_metrics_get_position` at upem scale; at a variable
face's extreme instances, advances equal `hb_font_get_glyph_h_advance` within
1/64 unit. `FTM5`'s cell metrics are checked against hand-computed values for
DejaVu Sans Mono and Maple Mono at 14, 16 and 18 px. Pixel convenience outputs
remain fractional and their cell-rounding behavior remains separately checked.

- `FTM6`: measure real shaped runs at a 12-point physical em, then rasterize at
  96 and 192 dpi. Physical advances and offsets must be identical, while the
  explicit pixel scale doubles. Compare design-unit advances to a recorded engine
  result at upem scale, then apply a hand-computed physical conversion. Use a
  selected variable face at its minimum/default/maximum coordinates; compare
  physical variation deltas, not just the unvaried default.
- Keep ink and advance distinct: measure a space, a zero-advance combining mark,
  and an audited programming ligature with overhang. Assert the measured advance
  and independently measured ink extent for each pinned face/glyph; no
  `ink.width == advance` assumption is admissible.
- Conversion fixtures reach positive and negative half-unit ties, the largest
  representable result and one-unit overflow, and intermediate product overflow.
  Assert ties-to-even and structured exhaustion with no result publication.
  Device adjustments apply only under explicit ppem; an identical design query
  without ppem must not inherit a previous device-size query's delta.
  A hand-derived two-advance fixture contributes half a `LayoutUnit` per glyph:
  individual ties round to zero, but the exposed run total must be one unit
  because it converts the design sum once. The design-position scale must permit
  layout to reproduce that result without adding rounded glyph advances.
- `FTM7`: compare a real vertical face's glyph advance/origin at two sizes and
  instance extremes to recorded HarfBuzz results; compare `BASE` tags, scripts,
  default indices, languages and coordinate formats to fontTools goldens. A
  fixture has a valid zero baseline beside an absent baseline; assert distinct
  outcomes. Reference-point coordinates are resolved against the M3 outline
  point, not treated as the record's nominal coordinate. Device and variation
  records, malformed offsets and absent `BASE`/`vmtx` are separate scenarios.
- `FTP13`: for the pinned math face compare all constants, selected italic
  corrections, accents, horizontal/vertical variants and assembly-part connector
  values against fontTools and the resolved HarfBuzz math API. For a glyph with
  math kerns, query below, at and above each correction-height threshold and
  compare the table-defined step values. Verify extender flags, minimum overlap
  and source glyph IDs without composing an assembly in font. Fixtures cover an
  absent table, absent glyph record, unsupported version, truncated arrays,
  invalid coverage indices, exactly sufficient storage and one-slot exhaustion.

### Outlines (`FTO1`–`FTO5`)

For every glyph of three bundled faces (one `glyf`, one `CFF`, one variable),
the segment sequence and coordinates equal `hb_font_draw_glyph`'s within 1/64
font unit. `FTO4` is a property test over every glyph of every variable bundled
face at its axis extremes.

### Raster oracle

For every glyph of four bundled faces at 12, 16, 24 and 48 ppem, unhinted,
coverage is compared per pixel with FreeType's `FT_LOAD_NO_HINTING` normal-mode
render, over the pixels either renderer inks. The faces are Fira Code Nerd Font
Mono, Noto Sans Arabic, Maple Mono NF CN (TrueType outlines) and Noto Sans
Anatolian Hieroglyphs (CFF outlines). Hand-built overlap fixtures, two
identical overlapping squares and a glyph whose contours cross, flagged or with
the union requested, must render the nonzero union, not a doubled coverage.

**Measured distribution.** [`raster-oracle-diff.d`][ex-oracle] ran on
2026-10-04 against FreeType 2.14.3 and HarfBuzz 13.2.1. Flagged overlapping
glyphs render at 4×4 (`FTX9`). Differences are in 1/255 steps; each cell is the
largest value over the four sizes.

| Face                      | `FTR3`: FreeType flattening vs FreeType, p99 / max | `FTR8`: 0.02 px vs 0.001 px, p99 / max | Default flattening vs FreeType, p99 / max |
| ------------------------- | -------------------------------------------------- | -------------------------------------- | ----------------------------------------- |
| Fira Code Nerd Font Mono  | 4 / 23                                             | 4 / 10                                 | 10 / 33                                   |
| Noto Sans Arabic          | 4 / 20                                             | 4 / 7                                  | 12 / 22                                   |
| Maple Mono NF CN          | 3 / 24                                             | 3 / 13                                 | 6 / 33                                    |
| Noto Sans Anatolian (CFF) | 4 / 40                                             | 3 / 7                                  | 24 / 53                                   |

The last column is not a gate. It shows why `FTR3` reproduces FreeType's
flattening (`FTX10`): with default flattening, FreeType's coarser cubic
subdivision dominates the difference, most visibly on the CFF face. The
`FTR8` reference has converged: 0.005 px and 0.00125 px renders differ by at
most 3 steps.

**Tolerance**, accepted 2026-10-04 (`FTX10`). Per face and size; each maximum
is the next multiple of 16 above the largest value measured, and each 99th
percentile the next multiple of 4.

| Requirement | Outlines        | Every pixel within | 99th percentile within |
| ----------- | --------------- | ------------------ | ---------------------- |
| `FTR3`      | TrueType `glyf` | 32                 | 8                      |
| `FTR3`      | CFF and CFF2    | 48                 | 8                      |
| `FTR8`      | all             | 16                 | 8                      |

**Unflagged overlaps.** The same program compares each unflagged glyph with its
4×4 render. At 24 px, 192 glyphs of Fira Code Nerd Font Mono, 428 of Noto Sans
Arabic and 82 of Maple Mono NF CN differ by more than 32 steps; the CFF face
has none. These are the glyphs `FTR2` lets render with doubled edges, and the
font explorer's overlap check lists them.

### Hostile input

- **Limits.** A fixture per `FTB3` limit, built one past the limit, returns
  `limitExceeded` naming it; built exactly at the limit, succeeds.
- **Cycles.** A composite glyph referring to itself, and a two-glyph cycle,
  return `cycle`.
- **Mutation corpus.** Seeded byte mutations (bit flips, truncations, offset
  rewrites) of every committed fixture and three bundled faces, run through
  every public read operation under AddressSanitizer (`ci --test-sanitize`).
  Seeds and any minimized failing input are committed. Passing means no
  sanitizer report and no assertion failure; any `Expected` error is acceptable.
- **No assertions on data** (`FTB2`): the mutation run is also executed in the
  `checked` build, where assertions are live.

### Shaping (`FTS1`–`FTS11`)

- Record actual `hb-shape` glyph IDs, offsets and advances for fixed strings in
  Maple Mono, Noto Sans at two `wght` values, Noto Sans Arabic and a pinned Indic
  face. Goldens include full engine/options/face manifests; they verify wrapper
  compatibility, not independent engine conformance.
- `FTS4`: hand-work source spans for `aé`, `e` + U+0301, a merging Latin
  ligature, Arabic lam-alef in RTL, an Indic conjunct and a default-ignorable-only
  run. Assert every source byte belongs to exactly one span, repeated glyph
  cluster starts are permitted, and RTL pen-order starts descend while source
  spans remain ascending. Verify an empty glyph range still covers its source,
  and that grapheme boundaries and glyph-cluster boundaries are not equated.
- `FTS7`: use an Arabic joining word from the manifest. Shape a middle run with
  surrounding context and false BOT/EOT, then the same bytes as a standalone
  word with true BOT/EOT. Record the real change in glyphs/positions; assert
  context-only bytes emit no glyphs and all cluster offsets remain absolute.
  Repeat across a style/fallback boundary without claiming a text boundary.
  Invalid UTF-8, a split multibyte scalar, inverted/out-of-range spans and invalid
  feature ranges produce their named errors with output sentinels unchanged.
  Empty runs succeed; exactly sufficient and one-glyph-short capacities distinguish
  successful committed output from `limitExceeded` with no partial publication.
- `FTS8`: coordinated calls preserve explicit direction/script/language even
  when content would cause standalone guessing to choose differently. Compare
  Unicode callback values for newly assigned and algorithm-sensitive characters
  to base's pinned goldens. A manifest with an uncovered internal-engine
  Unicode/version mismatch must be rejected before output; changing a system
  library without changing the accepted profile must not silently shape. Callback
  success alone cannot make this gate pass.
- `FTS9`: for each actual Arabic/Indic/ligature sample, shape the complete run and
  both fragments at each source boundary. Reusable boundaries with unchanged
  context must reproduce glyphs, positions and total advance when recombined.
  For an unsafe break, reshape fragments with their actual line flags and record
  changed output rather than cutting the old glyph array. Check unsafe-concat on
  separately shaped joining fragments and tatweel capability hints; absence,
  unknown boundaries and merged-cluster interiors never become reusable cuts.
- `FTS10`: inspect a real face with GDEF carets. Assert glyph/cluster association,
  record order, point/coordinate provenance and resolved variable/device values
  against independent table traces; a face without carets returns absence, not
  synthesized equal spacing. Synthetic fixtures cover all three caret formats,
  bad point indices, truncated device tables and caller-capacity exhaustion.
- `FTS11`: on a real face whose inspected feature changes a selected run, measure
  both feature alternatives with actual context. Record the differing glyphs and
  advances and compare them to the engine goldens; nominal advances or ink widths
  cannot be substituted. Compare a real `JSTF` record to fontTools; fixtures cover
  absent and malformed priority/extender data. An unsupported execution mode
  reports `unsupportedCapability`, not unchanged output labelled justified.
- `FTS6`: a unittest-only ImportC file includes `hb.h` and the D declarations;
  `static assert`s compare sizes and `offsetof` per field.

### Discovery and fallback (`FTD1`–`FTD7`)

Matching steps are checked against hand-derived traces of CSS Fonts Level 4 §5.2
over a synthetic family of nine weights and two widths. Chain/cache scenarios use
a temporary directory of committed faces with known coverage: touch, delete and
replace files between builds; an unknown cache version is discarded.

For `FTD7`, use primary/fallback real faces with inspected coverage of a mark
sequence, an emoji variation/ZWJ sequence and an RTL word. Force a failed primary
trial, then assert a successful complete-span trial reports its face/instance,
source partition and missing-glyph outcome accurately. A face with `cmap` coverage
but unsuitable sequence shaping cannot count as successful solely from coverage.
The requested span is never silently subdivided; an all-faces-fail case reports
the exact unresolved span. Grapheme/unsafe-cluster boundary selection is tested
in the owning text-layout integration, not duplicated as font segmentation.
Include a primary and a secondary with identical or subset `cmap` coverage where
only the secondary realizes the requested sequence under the declared shaping
policy. The secondary must remain in the whole-span trial list and succeed even
if the scalar-lookup coverage index prunes it; assert the actual selected face,
glyphs, source coverage and policy outcome, not merely candidate-list membership.

### Consumer migration (`FTA12`–`FTA14`, `FTA16`)

- `FTA12`: grep checks over `libs/raylib-text/` for `.c` files and for imports
  of HarfBuzz, FreeType or font parsing.
- `FTA13`: the Android APK derivations build in CI, and a manual emulator run
  shows bundled text and emoji (manual evidence, recorded with the commit).
- `FTA14`: `hue` and `terminal` screenshot goldens, captured locally under
  `xvfb` before and after the migration on the same commit pair. CI cannot run
  these; the evidence is a recorded local run.
- `FTA16`: retain the audited `FTX7` fast-path captures, then exercise a merging
  ligature, zero-advance mark, RTL run and multi-cell source span through general
  cluster placement. Compare pen positions and redraw damage to actual advance
  and ink measurements. A one-glyph-per-source-cell counterexample must render
  correctly without enabling the audited fast path.

## Configurations

| Configuration                             | Runs                                                                 |
| ----------------------------------------- | -------------------------------------------------------------------- |
| `dub test :font`                          | parser, variation, metrics, outlines, raster, hostile-input fixtures |
| `dub test :font --config=engine-unittest` | the above plus shaping and every HarfBuzz/FreeType differential      |
| `ci --test-sanitize`                      | the mutation corpus under AddressSanitizer                           |
| local, `xvfb`                             | consumer screenshot goldens                                          |

Linux is the primary configuration. macOS runs the `library` tests in CI;
Windows runs them where the Windows leg builds the package.

## Feasibility evidence

Experiments run before the specification was accepted, each answering a
question an architectural choice depends on. They establish only what they
checked, on the configuration that ran them.

| Question                                                       | Evidence                                                                      | Result                                                                                                                                                                                      |
| -------------------------------------------------------------- | ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Can D drive HarfBuzz with no C shim?                           | [`harfbuzz-shape-features.d`][ex-shape], [`outline-sink-raster.d`][ex-raster] | Yes: opaque handles plus five plain structs, run by `ci --example-files`.                                                                                                                   |
| Is an accumulation rasterizer small enough to own?             | [`outline-sink-raster.d`][ex-raster]                                          | A 71-line core renders correct coverage for Noto Sans and Maple Mono at 28 px. Spike S2 extends it to every glyph of four faces at four sizes (§ Raster oracle).                            |
| Do programming ligatures break a cell grid?                    | [`ligature-cells.d`][ex-ligature], 160 sequences in eight faces               | No glyph-count change and no off-cell advance in Cascadia Code, JetBrains Mono, Fira Code and Maple Mono, plain and Nerd Font builds; ink reaches up to 6 cells past its own cell (`FTX7`). |
| Does variation change contour topology?                        | [`outline-sink-raster.d`][ex-raster] on Noto Sans `g` at `wght` 100 and 900   | No for that glyph: 2 moves, 8 lines, 31 quadratics at both ends. `FTO4` makes it a corpus-wide property.                                                                                    |
| Is a synchronous catalog build fast enough?                    | [`font-scan-timing.d`][ex-scan] over `fc-list` and the bundle                 | Yes: 2,222 desktop files in 44 ms warm, 20 ms on 4 workers, 1.6 s on first touch; the 180-file bundle in 1.9 ms (`FTX8`).                                                                   |
| Does Phobos provide zlib's `inflate` without an extra library? | `nm` on LDC 1.42's `libphobos2-ldc.a`                                         | Yes: `inflate` and `inflateInit2_` are defined in its `inflate.c.o` member.                                                                                                                 |
| Is the bundled emoji font outline-free?                        | The table directory of the bundled `NotoColorEmoji.ttf`                       | Yes: `CBDT`, `CBLC` and no `glyf`, which is why `FTR7` exists.                                                                                                                              |

## Evidence ledger

Entries are added here as milestones land, each naming requirement IDs, source
revision, command, configuration and remaining gap, per the
[spec guideline](../../guidelines/spec-docs.md#keep-evidence-scoped-and-honest).
The M1 rows below come from the M1 series of 2026-10-06 (`libs/font`,
`libs/font-oracle`), run on Linux x86_64 with LDC 1.42 and DMD, with
`$SPARKLES_FONTS_PATH` set to the `sparkles-fonts` bundle of that revision
(180 outline faces).

The 2026-10-04 text-foundation extensions are planned/unverified: no listed test
command or proposed API in this page is claimed to exist or to have run for
`FTA16`, `FTP13`, `FTM6`–`FTM7`, `FTS7`–`FTS11` or `FTD7`. Existing research
measurements do not certify these requirements. The
real-math/vertical/caret/JSTF corpus manifests and compatible engine profile are
acceptance prerequisites still to acquire.

| Requirement                                        | Revision       | Command                                                                                                    | Result                                                                                                                                                                                                                                                                                                                                                             | Gap                                                                                                                                                                  |
| -------------------------------------------------- | -------------- | ---------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `FTP1`–`FTP5`, `FTP14`–`FTP22`, `FTP33`, `FTI5`    | M1 series      | `dub test :font` (`face_test`)                                                                             | pass: the 422-byte trace, exact-end and one-byte-short, local `badOffset`, signatures, required tables, the 4,096-record limit, offset overflow, duplicate tags, a two-face collection, checksums                                                                                                                                                                  | The bundle has no collection file; collections are covered by the committed fixture only.                                                                            |
| `FTP7`, `FTP12`, `FTP23`, `FTP24`, `FTP32`, `FTI1` | M1 series      | `dub test :font` (`tables_test`)                                                                           | pass: every view and version length, `hmtx` leniency, spacing; on the bundle Maple Mono NF CN is `dual`, DejaVu Sans Mono `mono`, Noto Sans `proportional`; `FTI1` holds by construction: each view is a plain struct in `tables.d` whose fields carry the OpenType names (`version` spelled `version_`), so it needs no test of its own                           | —                                                                                                                                                                    |
| `FTP9`, `FTP10`, `FTP25`–`FTP27`                   | M1 series      | `dub test :font` (`cmap_test`); `dub test :font-oracle`                                                    | pass: every format, choice and fallback, symbol and Mac Roman lookups, effective spans, counters, format 14; `ranges()` equals `glyph()` over all of Unicode on five bundled faces; every codepoint either side maps agrees with HarfBuzz on all 180 faces                                                                                                         | Overlapping format-4 segments do not occur in the bundle; they are covered by fixtures only.                                                                         |
| `FTP8`, `FTP28`, `FTP29`, `FTA15`                  | M1 series      | `dub test :font` (`names_test`); `dub test :font-oracle`                                                   | pass: UTF-16BE through base's adapter, including the surrogate trace; Mac Roman and its excluded variants; every name HarfBuzz decodes on all 180 faces matches a record                                                                                                                                                                                           | —                                                                                                                                                                    |
| `FTP11`, `FTP30`, `FTP31`                          | M1 series      | `dub test :font` (`glyph_names_test`); `dub test :font-oracle`                                             | pass: `post` 1.0, 2.0, 2.5, 3.0, `CFF` charsets 0–2 and predefined, CID-keyed; the index equals direct lookup for every glyph; every glyph HarfBuzz names on all 180 faces has the same name                                                                                                                                                                       | The oracle found `post` 2.0 indices above 32,767 in Maple Mono NF CN; `FTP30` was corrected to accept them.                                                          |
| `FTB1`–`FTB3`, `FTA9`–`FTA11`                      | M1 series      | `dub test :font` (`hostile_test`); the same with `DFLAGS="-fsanitize=address --enable-stackovf-sanitizer"` | pass: 1,600 mutants of four fixtures and 120 of three bundled faces through every public read, in the debug build and under AddressSanitizer, with no assertion or report                                                                                                                                                                                          | Outline and colour limits of `FTB3` belong to M3 and M6.                                                                                                             |
| `FTA1`, `FTA6`                                     | M1 series      | `dub build :font`; `dub test :font` with LDC and DMD                                                       | pass: the library configuration builds with no C library; all public reads are `@safe` under `-preview=dip1000`                                                                                                                                                                                                                                                    | —                                                                                                                                                                    |
| `FTA7`                                             | M1 gaps series | `nix build .#font-android-tests`, then `adb push` and run on an Android emulator                           | pass: the `library` sources and their tests cross-compile for arm64-v8a and x86_64 with the static D runtime, needing only the NDK's `libc`, `libm`, `libdl` and `liblog`; run by `sparkles:test-runner`, on an x86_64 API 36 emulator with five bundled fonts pushed: 52 passed, 0 failed, threaded and with `-t 1`; without the fonts the five corpus tests skip | The arm64-v8a executable is built but not run: no arm64 device or emulator was available.                                                                            |
| `FTA2`                                             | M1 gaps series | `dub test :font` (`concurrency_test`)                                                                      | pass: one `Face` and its `CharMap` shared by a `std.parallelism` pool; four rounds over all 12,780 glyphs of Fira Code Nerd Font Mono (character mapping, `hmtx` advance, glyph name) equal a single-threaded pass                                                                                                                                                 | No race detector has checked it: a ThreadSanitizer build (`-fsanitize=thread`) of the suite ran past 25 minutes without a result, and the cause was not established. |

<!-- References -->

[ex-shape]: ../../research/font-libraries/examples/harfbuzz-shape-features.d
[ex-raster]: ../../research/font-libraries/examples/outline-sink-raster.d
[ex-ligature]: ../../research/font-libraries/examples/ligature-cells.d
[ex-scan]: ../../research/font-libraries/examples/font-scan-timing.d
[ex-oracle]: ../../research/font-libraries/examples/raster-oracle-diff.d
