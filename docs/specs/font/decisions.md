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

| Excluded                                | Why                                                                                | Entry condition                                                                                                     |
| --------------------------------------- | ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Line breaking, bidi, paragraph layout   | A layout layer above the library owns them.                                        | None in this library.                                                                                               |
| Hinting, bytecode or automatic          | The largest single part of every rasterizer that has it.                           | A measured legibility gap at terminal sizes on a low-DPI panel that gamma-corrected unhinted coverage cannot close. |
| LCD subpixel anti-aliasing              | Colour fringes off RGB-stripe panels; cannot composite over arbitrary backgrounds. | None.                                                                                                               |
| `COLR` version 1 rendering              | A paint graph with gradients and compositing, a small renderer of its own.         | After `COLR` version 0 ships, when a consumer needs it.                                                             |
| `SVG ` glyphs                           | Needs an SVG renderer.                                                             | None.                                                                                                               |
| WOFF and WOFF2                          | Web containers; WOFF2 needs a Brotli decoder and table reconstruction.             | A consumer that must open web fonts.                                                                                |
| Type 1 and `dfont`                      | Legacy formats.                                                                    | None.                                                                                                               |
| Writing, subsetting or instancing files | No consumer writes fonts.                                                          | None.                                                                                                               |
| A D OpenType shaping engine             | See `FTX1`.                                                                        | A target that must shape and cannot link HarfBuzz.                                                                  |
| GPU rasterization                       | Bitmap specimens and cell glyphs do not need it.                                   | A consumer drawing transformed or continuously zoomed text.                                                         |
| Font activation, network catalogs       | Application features, not library features.                                        | None in this library.                                                                                               |

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

**State:** proposed · **Affects:** `FTS1`–`FTS6`, the `engine` configuration

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

---

## Open questions

### FTQ1: Raster tolerance for `FTR3`

**Blocks:** `FTR3` acceptance, milestone M5. **Resolver:** spike S2.

What per-pixel difference from FreeType's unhinted render is acceptable? Two
correct rasterizers differ in curve flattening and in how they treat pixels
crossed by several edges. The tolerance must be chosen from the spike's
measured distribution on the corpus before the milestone starts, then frozen.

### FTQ2: Background or synchronous scanning

**Blocks:** `FTD3`'s cache design, milestone M7. **Resolver:** spike S1.

Is parsing a large font directory (a typical Linux system has 1,000–5,000 font
files) fast enough at first launch to scan synchronously? The answer decides
whether the font catalog needs a background builder and a progress surface.

### FTQ3: Ligatures that change glyph count in a cell grid

**Blocks:** the terminal half of milestone M8. **Resolver:** the terminal
migration's design review.

`FTS4` gives clusters; how a terminal places a ligature glyph that spans
several cells is the consumer's policy, but
the library must expose enough (cluster spans, glyph advances relative to the
cell) for it. The two bundled programming fonts do not (spike S3, partial): both
use spacer glyphs to keep one glyph per cell. JetBrains Mono and Cascadia Code
remain to be measured.

<!-- References -->

[rustybuzz]: ../../research/font-libraries/rustybuzz.md
[go-text]: ../../research/font-libraries/go-text-typesetting.md
[allsorts]: ../../research/font-libraries/allsorts.md
[sixlabors]: ../../research/font-libraries/sixlabors-fonts.md
[crossfont]: ../../research/font-libraries/crossfont.md
[ghostty]: ../../research/font-libraries/ghostty.md
[font-kit]: ../../research/font-libraries/font-kit.md
[ex-raster]: ../../research/font-libraries/examples/outline-sink-raster.d
