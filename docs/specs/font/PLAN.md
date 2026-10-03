---
status: draft
owner: sparkles:font
reviewed:
---

# `sparkles:font` — Delivery plan

The order in which the requirements of [`SPEC.md`](./SPEC.md) are delivered,
the gate each milestone must pass, and progress. Scenarios and oracles live in
[`testing.md`](./testing.md).

## Progress

| Milestone                                                                 | State       |
| ------------------------------------------------------------------------- | ----------- |
| [Stage 0](#stage-0-specification-and-spikes)                              | in progress |
| [M1 Parse](#m1-parse)                                                     | not started |
| [M2 Variation, metrics, inspection](#m2-variation-metrics-and-inspection) | not started |
| [M3 Outlines](#m3-outlines)                                               | not started |
| [M4 Shaping](#m4-shaping)                                                 | not started |
| [M5 Grayscale raster](#m5-grayscale-raster)                               | not started |
| [M6 Colour glyphs](#m6-colour-glyphs)                                     | not started |
| [M7 Discovery and fallback](#m7-discovery-and-fallback)                   | not started |
| [M8 Consumer migration](#m8-consumer-migration)                           | not started |

The font explorer's own plan interleaves with this one: its `inspect`
subcommand needs M1–M2, its specimens M4–M5, its library pane M7. The explorer
plan lives in [`../font-explorer/PLAN.md`](../font-explorer/PLAN.md).

## Stage 0: specification and spikes

**Deliverable.** This specification tree accepted, and the three spikes run
(done 2026-10-03: `FTX7`, `FTX8`, `FTX9`).

**Gate.** Per the [spec guideline's Stage 0 gate](../../guidelines/spec-docs.md#stage-0-gate):
scope, ownership, non-goals and invariants agreed; first-slice (M1) contracts
at operation level with oracles; spike results recorded; an adversarial review
of `SPEC.md` § 2–4 with worked success, failure and boundary traces, its
findings dispositioned. Acceptance is recorded by the project owner, not
implied by merging.

### Stage 0 spikes

| Spike | Question                                                                                          | Experiment                                                                                                                                                                                                                                                                                                               | Decision criterion                                                                                                   |
| ----- | ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------- |
| S1    | Is a synchronous first-launch scan of a large font directory acceptable? (`FTQ2`)                 | Time reading the table directory, `name`, `OS/2` and `cmap` coverage of every font file on a Linux desktop and in the bundle, cold and warm cache. **Done, 2026-10-03:** 2,222 desktop files in 44 ms warm (20 ms on 4 workers), 1.6 s on first touch; the bundle in 1.9 ms (`FTX8`).                                    | Under 1 s warm for the machine's full font set → synchronous with a cache; otherwise a background builder.           |
| S2    | What tolerance does an overlap-correct accumulation rasterizer achieve against FreeType? (`FTQ1`) | Extend the research example with per-contour accumulation; diff every glyph of three bundled faces at four sizes against FreeType unhinted. **Measured, 2026-10-03:** four faces, 48,330 glyphs; overlaps handled by FreeType's flag rule (`FTX9`); tolerance proposed in `testing.md`, pending review (`FTQ1`, `FTQ4`). | Record the distribution; propose the `FTR3` tolerance at a percentile that a reviewer accepts as visually identical. |
| S3    | Does any common programming font's `liga`/`calt` change glyph count? (`FTQ3`)                     | Shape 160 ligature sequences in Fira Code, JetBrains Mono, Cascadia Code and Maple Mono with `calt` and `liga` on and off. **Done, 2026-10-03:** no glyph-count change and no off-cell advance in eight faces; ink reaches up to 6 cells past its own cell (`FTX7`).                                                     | Record per font; decides whether the terminal migration needs multi-cell glyph placement.                            |

## M1 Parse

**Obligations.** `FTB1`–`FTB5` for the tables in scope, `FTA1`, `FTA2`,
`FTA6`, `FTA7`, `FTA9`–`FTA11`, `FTP1`–`FTP12`, `FTI1`, `FTI5`.

**Prerequisites.** Stage 0 accepted. `$SPARKLES_FONTS_PATH` exported by the dev
shell and the CI shell.

**Deliverable.** `libs/font` with the `library` configuration: `Face`,
`Collection`, `FontError`, table directory and the typed tables of `FTP7`.
Committed fixtures and the byte builder for hostile input.

**Acceptance.** `dub test :font` passes with the corpus set, with the test count
reported; the HarfBuzz differential suites for parsing pass in the `engine`
unittest configuration; the mutation corpus runs clean under
`ci --test-sanitize`.

**Excluded.** Variation application, metrics beyond the raw tables, outlines.

## M2 Variation, metrics and inspection

**Obligations.** `FTA3`, `FTV1`–`FTV5`, `FTM1`–`FTM5`, `FTI2`–`FTI4`.

**Deliverable.** `FontInstance`, normalization, `HVAR`/`MVAR`, line and cell
metrics, layout-feature enumeration and colour-capability reporting.

**Acceptance.** Normalization and metrics differentials against HarfBuzz pass
over the corpus; hand-derived traces pass.

## M3 Outlines

**Obligations.** `FTO1`–`FTO5`; `FTB3`/`FTB5` for composites and `CFF`
subroutines.

**Acceptance.** Outline differentials against `hb_font_draw_glyph`; the `FTO4`
property over the variable corpus; limit and cycle fixtures.

## M4 Shaping

**Obligations.** `FTA4`, `FTA8`, `FTS1`–`FTS6`.

**Deliverable.** The `engine` configuration.

**Acceptance.** `hb-shape` goldens; the cluster property; the ImportC layout
check.

## M5 Grayscale raster

**Obligations.** `FTA5`, `FTR1`–`FTR4`, `FTR6`.

**Prerequisites.** Spike S2's tolerance accepted in `testing.md` (`FTQ1`), and `FTQ4` answered.

**Acceptance.** The FreeType raster differential at the recorded tolerance; the
overlap fixtures; cache-key determinism (equal keys, identical bytes).

## M6 Colour glyphs

**Obligations.** `FTR5`, `FTR7`.

**Acceptance.** `COLR` v0 fixtures render layer order and palette colours
correctly against hand-derived expectations; every glyph of the bundled
Noto Color Emoji decodes at three sizes, and PNG filter fixtures for all five
filter types pass.

## M7 Discovery and fallback

**Obligations.** `FTD1`–`FTD6`.

**Prerequisites.** [`FTX8`](decisions.md#ftx8-the-catalog-builds-synchronously-over-a-worker-pool); contracts refined to operation level in
`SPEC.md` § 10 before work starts.

**Acceptance.** Refined with the contracts.

## M8 Consumer migration

**Obligations.** `FTA12`–`FTA14`.

**Prerequisites.** M1–M7. [`FTX7`](decisions.md#ftx7-ligatures-keep-one-glyph-per-cell-their-ink-crosses-cells) sets the terminal's ligature constraints.

**Deliverable.** `sparkles:raylib-text` rebuilt over `sparkles:font`; the
spike's `shaping_c.c`, `shaping_api.h` and `shaping.d` and the discovery modules
deleted; `hue`, `terminal`, `terminal-view`, `ui-raylib` and `ui-app` updated.

**Acceptance.** All consumers' test suites pass; the Android APKs build in CI;
local screenshot goldens identical or listed with captures (`FTA14`); with a
ligature font, the terminal neither clips a ligature's ink to one cell nor leaves
stale ink when one of its cells changes (`FTX7`).

**Consumer surface to replace**, measured on 2026-10-03 at `d4bf07306`:

| Consumer                        | Uses from `sparkles:raylib-text`                                                                          | Moves to                                                             |
| ------------------------------- | --------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| `sparkles:ui-app` `gui_setup.d` | `FontSet.tryLoad`, `FontSources`, `FaceOverrides`, `reload`, `unload`, cell width and height, DPI helpers | the font catalog and fallback chain, cell metrics, DPI helpers moved |
| `hue` `gui.d`                   | cell width and height, `reload`, `flushPending`, `drawText`, DPI helpers                                  | cell metrics; drawing stays in `raylib-text` over this library       |
| `sparkles:ui-raylib`            | `drawText`, `drawBox`, `TextStyle`, cell metrics                                                          | the same `raylib-text` calls with new internals                      |
| `sparkles:terminal-view`        | `drawGrapheme`, `drawSolid`, `drawCluster`, `resolveFace`, `primaryFont`, `whiteFace`                     | fallback lookup, shaping, and atlas upload in `raylib-text`          |
| `apps/terminal` (Android)       | `drawText`, `TextStyle`                                                                                   | the same `raylib-text` calls                                         |

**Handoff.** Not started. The three Stage 0 spikes ran on 2026-10-03. Next
executable action: the rest of the Stage 0 gate, which is M1's contracts at
operation level and the adversarial review of `SPEC.md` § 2–4; then the owner's
acceptance. Before M5, the proposed `FTR3` tolerance needs review and `FTQ4`
an answer.
