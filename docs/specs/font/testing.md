---
status: draft
owner: sparkles:font
reviewed:
---

# `sparkles:font` — Testing and evidence

Oracles, acceptance scenarios and the evidence ledger for the requirements in
[`SPEC.md`](./SPEC.md). Each requirement is checked against an implementation
that shares no code with this library, or against traces worked by hand.

## Oracle independence

The library's correctness claims are checked against implementations that share
no code with it. The table says which oracle backs which requirements and why it
is independent.

| Oracle                                  | Independent because                                                                               | Checks                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| --------------------------------------- | ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **HarfBuzz's own OpenType parsers**     | A separate C++ implementation, reached from D tests by `extern(C)`                                | upem and glyph count; `name` strings (`hb_ot_name_get_utf8`); coverage (`hb_face_collect_unicodes`); `cmap` lookups (`hb_font_get_nominal_glyph`, `hb_font_get_variation_glyph`); axes and instances (`hb_ot_var_*`); normalization (`hb_ot_var_normalize_coords`); metrics (`hb_ot_metrics_get_position`); advances (`hb_font_get_glyph_h_advance`); glyph names; outlines (`hb_font_draw_glyph`); layout feature lists (`hb_ot_layout_*`) |
| **FreeType**                            | A separate C implementation of parsing and rasterization                                          | per-pixel coverage of unhinted renders (`FTR3`); `CFF` outlines as a second opinion                                                                                                                                                                                                                                                                                                                                                         |
| **fontTools** (developer machines only) | A separate Python implementation; the reference most tools copy                                   | fields HarfBuzz does not expose (raw `OS/2`, `post`, `head`), recorded once as committed JSON goldens with the generating command                                                                                                                                                                                                                                                                                                           |
| **Hand-derived traces**                 | Worked from the OpenType and CSS specifications by hand                                           | normalization arithmetic on synthetic axes, `cmap` subtable selection order, `FTM2`'s line-metric rule, CSS matching steps, PNG filter reversal                                                                                                                                                                                                                                                                                             |
| **Hostile-input fixtures**              | Built by a test-only byte builder, with expectations from the trust contract, not from the parser | every `FTB*` limit and failure kind                                                                                                                                                                                                                                                                                                                                                                                                         |

HarfBuzz is also the shaping engine (`FTX1`), so it cannot be an oracle for
shaping itself. Shaping tests check this library's wrapper — that coordinates,
features and clusters pass through intact — against `hb-shape` command-line
output recorded as goldens, which reaches HarfBuzz through a different call path.

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
- **Committed fixtures.** Small fonts and malformed byte sequences under
  `libs/font/test/data/`, so the parser's unit tests run with no environment.
- **System fonts** are never a test input: they differ between machines.

## Requirement scenarios

### Parsing (`FTP1`–`FTP12`)

- For every bundled face: open succeeds; `upem`, glyph count, every `name`
  record, coverage ranges, and `glyphIndex` for every covered codepoint equal
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

### Variation normalization

For every axis of every variable bundled face, at the minimum, default, maximum
and 17 evenly spaced user values: normalized `F2Dot14` values equal
`hb_ot_var_normalize_coords`. Hand-derived traces cover an `avar` map with a
non-identity segment and a clamp beyond the axis range.

### Metrics (`FTM1`–`FTM5`)

For every bundled face, the three vertical sets, x-height, cap height, underline
and strikeout equal `hb_ot_metrics_get_position` at upem scale; at a variable
face's extreme instances, advances equal `hb_font_get_glyph_h_advance` within
1/64 unit. `FTM5`'s cell metrics are checked against hand-computed values for
DejaVu Sans Mono and Maple Mono at 14, 16 and 18 px.

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

### Shaping (`FTS1`–`FTS6`)

- `shape` output for fixed strings in Maple Mono, Noto Sans (at two `wght`
  values) and Noto Sans Arabic equals recorded `hb-shape` goldens.
- `FTS4`: property test over the corpus's sample strings — clusters are
  monotonic and cover every byte.
- `FTS6`: a unittest-only ImportC file includes `hb.h` and the D declarations;
  `static assert`s compare sizes and `offsetof` per field.

### Discovery and fallback (`FTD1`–`FTD6`)

Scenarios are refined with milestone M7. The fixed points: matching steps are
checked against hand-derived traces of CSS Fonts Level 4 §5.2 over a synthetic
family of nine weights and two widths; fallback chains are checked over a
temporary directory of committed fixtures with known coverage; the persistent
index is checked by touching, deleting and replacing files between builds.

### Consumer migration (`FTA12`–`FTA14`)

- `FTA12`: grep checks over `libs/raylib-text/` for `.c` files and for imports
  of HarfBuzz, FreeType or font parsing.
- `FTA13`: the Android APK derivations build in CI, and a manual emulator run
  shows bundled text and emoji (manual evidence, recorded with the commit).
- `FTA14`: `hue` and `terminal` screenshot goldens, captured locally under
  `xvfb` before and after the migration on the same commit pair. CI cannot run
  these; the evidence is a recorded local run.

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

No requirement has evidence. Entries are added here as milestones land, each
naming requirement IDs, source revision, command, configuration and remaining
gap, per the [spec guideline](../../guidelines/spec-docs.md#keep-evidence-scoped-and-honest).

| Requirement | Revision | Command | Result | Gap |
| ----------- | -------- | ------- | ------ | --- |

<!-- References -->

[ex-shape]: ../../research/font-libraries/examples/harfbuzz-shape-features.d
[ex-raster]: ../../research/font-libraries/examples/outline-sink-raster.d
[ex-ligature]: ../../research/font-libraries/examples/ligature-cells.d
[ex-scan]: ../../research/font-libraries/examples/font-scan-timing.d
[ex-oracle]: ../../research/font-libraries/examples/raster-oracle-diff.d
