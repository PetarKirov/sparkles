---
status: accepted
owner: sparkles:font
reviewed: 2026-10-06
---

# `sparkles:font` — Delivery plan

The order in which the requirements of [`SPEC.md`](./SPEC.md) are delivered,
the gate each milestone must pass, and progress. Scenarios and oracles live in
[`testing.md`](./testing.md).

## Progress

| Milestone                                                                 | State       |
| ------------------------------------------------------------------------- | ----------- |
| [Stage 0](#stage-0-specification-and-spikes)                              | done        |
| [M1 Parse](#m1-parse)                                                     | done        |
| [M2 Variation, metrics, inspection](#m2-variation-metrics-and-inspection) | not started |
| [M3 Outlines](#m3-outlines)                                               | not started |
| [M4 Shaping](#m4-shaping)                                                 | not started |
| [M5 Grayscale raster](#m5-grayscale-raster)                               | not started |
| [M6 Colour glyphs](#m6-colour-glyphs)                                     | not started |
| [M7 Discovery and fallback](#m7-discovery-and-fallback)                   | not started |
| [M8 Consumer migration](#m8-consumer-migration)                           | not started |

The font explorer's own plan interleaves with this one: its `inspect`
subcommand needs M1–M2, its glyph map M3 and M5, and its text specimens
text-layout's TL-M3, which itself needs M2, M4 and M7. The explorer plan lives
in [`../font-explorer/PLAN.md`](../font-explorer/PLAN.md).
The [design system](../design-system/PLAN.md) is a downstream consumer: its
[font roles](../../glossary.md#font-role) resolve through `FTD4`–`FTD6`, so
discovery-backed role resolution waits on M7, and its proportional documentation
runs (design-system M9, `GLY7`) wait on text-layout TL-M3.
The [base text foundation](../base/text/PLAN.md) and
[text-layout plan](../text-layout/PLAN.md) are separate delivery plans. Base
does not wait for font. Text-layout's real-font composition waits for delivered
font capabilities, not merely these draft requirements or a substitute shaper.

## Stage 0: specification and spikes

**Deliverable.** This specification tree accepted, and the three spikes run.
The spikes ran on 2026-10-03 (`FTX7`–`FTX10`); the owner accepted the
specification on 2026-10-06.

**Gate.** Per the [spec guideline's Stage 0 gate](../../guidelines/spec-docs.md#stage-0-gate):
scope, ownership, non-goals and invariants agreed; first-slice (M1) contracts
at operation level with oracles; spike results recorded; an adversarial review
of `SPEC.md` § 2–4 with worked success, failure and boundary traces, its
findings dispositioned. Acceptance is recorded by the project owner, not
implied by merging.

The text-foundation boundary additions dated 2026-10-04 require a separate
adversarial pass over `FTA15`–`FTA16`, `FTP13`, `FTM6`–`FTM7`, `FTS7`–`FTS11`
and `FTD7`, including arithmetic exhaustion, RTL source coverage and engine-data
mismatch traces. They do not constitute acceptance of the font specification.
Operation signatures in the additions are proposed, not delivered symbols.

### Stage 0 spikes

| Spike | Question                                                                                          | Experiment                                                                                                                                                                                                                                                                                                 | Decision criterion                                                                                                   |
| ----- | ------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| S1    | Is a synchronous first-launch scan of a large font directory acceptable? (`FTQ2`)                 | Time reading the table directory, `name`, `OS/2` and `cmap` coverage of every font file on a Linux desktop and in the bundle, cold and warm cache. **Done, 2026-10-03:** 2,222 desktop files in 44 ms warm (20 ms on 4 workers), 1.6 s on first touch; the bundle in 1.9 ms (`FTX8`).                      | Under 1 s warm for the machine's full font set → synchronous with a cache; otherwise a background builder.           |
| S2    | What tolerance does an overlap-correct accumulation rasterizer achieve against FreeType? (`FTQ1`) | Extend the research example with per-contour accumulation; diff every glyph of three bundled faces at four sizes against FreeType unhinted. **Done, 2026-10-03; accepted 2026-10-04:** four faces, 48,330 glyphs; FreeType's overlap rule (`FTX9`); two raster oracles with recorded tolerances (`FTX10`). | Record the distribution; propose the `FTR3` tolerance at a percentile that a reviewer accepts as visually identical. |
| S3    | Does any common programming font's `liga`/`calt` change glyph count? (`FTQ3`)                     | Shape 160 ligature sequences in Fira Code, JetBrains Mono, Cascadia Code and Maple Mono with `calt` and `liga` on and off. **Done, 2026-10-03:** no glyph-count change and no off-cell advance in eight faces; ink reaches up to 6 cells past its own cell (`FTX7`).                                       | Record per font; identifies an audited fast path, never permits a general glyph-index-to-cell-index assumption.      |

## M1 Parse

**Obligations.** `FTB1`–`FTB5` for the tables in scope, `FTA1`, `FTA2`,
`FTA6`, `FTA7`, `FTA9`–`FTA11`, `FTA15`, `FTP1`–`FTP12`, `FTP14`–`FTP33`, `FTI1`,
`FTI5`. The operation contracts are in [`parsing.md`](./parsing.md).

**Prerequisites.** Stage 0 accepted. `$SPARKLES_FONTS_PATH` exported by the dev
shell and the CI shell. Owned base UTF codecs for name decoding; no Phobos
decoding or temporary competing font-local UTF helper.

**Deliverable.** `libs/font` with the `library` configuration: `Face`,
`Collection`, `FontError`, table directory and the typed tables of `FTP7`.
Committed fixtures and the byte builder for hostile input.

**Acceptance.** `dub test :font` passes with the corpus set, with the test count
reported; the HarfBuzz differential suite for parsing passes in the test-only
`sparkles:font-oracle` package, which links HarfBuzz so that `sparkles:font`'s
own configurations never do (`FTA7`); the mutation corpus runs clean under
AddressSanitizer, as `ci --test-sanitize` builds it.

**State.** Done on 2026-10-06; the evidence and its remaining gaps are in
[`testing.md`](./testing.md#evidence-ledger).

**Excluded.** Variation application, metrics beyond the raw tables, outlines.

## M2 Variation, metrics and inspection

**Obligations.** `FTA3`, `FTV1`–`FTV5`, `FTM1`–`FTM7`, `FTP13`, `FTI2`–`FTI4`.

**Prerequisites.** M1; base's accepted physical-unit arithmetic and conversion
contract. Borrowed table-query/result contracts and error distinctions for `MATH`,
`BASE` and vertical metrics refined before implementation.

**Deliverable.** `FontInstance`, normalization, `HVAR`/`MVAR`, physical/design
and pixel measurements, line and cell metrics, baseline/vertical metrics, `MATH`
data, layout-feature enumeration and colour-capability reporting. Raw reference-point
records remain inspectable before outline resolution. Completion of the `FTM7`
reference-point gate requires the M3 outline-point primitive; M2 and M3 may
interleave after M2 establishes the instance coordinate vector.

**Acceptance.** Normalization and metrics differentials against HarfBuzz pass
over the corpus; hand-derived traces pass. Device-scale invariance, ties-to-even
conversion and exhaustion scenarios pass. Real math and vertical-font data are
checked under the pinned corpus manifest described in `testing.md`; absence of
such fonts is an unmet gate, not successful skipping. The baseline reference-point
gate cannot be marked complete until the outline-point primitive is delivered.

## M3 Outlines

**Obligations.** `FTO1`–`FTO5`, `FTI6`; `FTB3`/`FTB5` for composites and `CFF`
subroutines.

**Prerequisites.** M1 and the `FTV1`–`FTV3` instance-coordinate portion of M2.
The outline-point primitive also completes M2's `FTM7` reference-point gate;
this dependency does not require every M2 table query to finish before M3 starts.

**Acceptance.** Outline differentials against `hb_font_draw_glyph`; the `FTO4`
property over the variable corpus; limit and cycle fixtures.

## M4 Shaping

**Obligations.** `FTA4`, `FTA8`, `FTS1`–`FTS11`.

**Prerequisites.** M2 physical metrics; M3 for GDEF contour-point caret resolution;
base owned strict decoding and Unicode analysis; a pinned engine compatibility
manifest satisfying `FTS8`. A supported callback surface alone does not meet the
Unicode-version gate.

**Deliverable.** The `engine` configuration, contextual range shaping and complete
source-cluster coverage, explicit segment properties, safety flags, optional caret
data and exact justification-candidate measurements. This is a real-font API, not
a test-shaped substitute for text-layout.

**Acceptance.** Recorded `hb-shape` wrapper goldens; hand-reviewed LTR/RTL coverage;
context/BOT/EOT and break/concat scenarios; real-font feature/caret measurements;
Unicode mismatch rejection; the ImportC layout check. Commands, face hashes,
engine revision and measured values are recorded before claiming this gate.

## M5 Grayscale raster

**Obligations.** `FTA5`, `FTR1`–`FTR4`, `FTR6`, `FTR8`.

**Prerequisites.** The tolerances of `FTX10`, recorded in `testing.md`.

**Acceptance.** The FreeType raster differential (`FTR3`) and the flattening
differential (`FTR8`) at the recorded tolerances; the
overlap fixtures; cache-key determinism (equal keys, identical bytes).

## M6 Colour glyphs

**Obligations.** `FTR5`, `FTR7`.

**Acceptance.** `COLR` v0 fixtures render layer order and palette colours
correctly against hand-derived expectations; every glyph of the bundled
Noto Color Emoji decodes at three sizes, and PNG filter fixtures for all five
filter types pass.

## M7 Discovery and fallback

**Obligations.** `FTD1`–`FTD7`.

**Prerequisites.** [`FTX8`](decisions.md#ftx8-the-catalog-builds-synchronously-over-a-worker-pool);
M1 face records and M4 contextual whole-span shaping. Public catalog, chain and
trial-shape operation contracts refined in `SPEC.md` § 13 before work starts.

**Acceptance.** CSS matching traces, cache replace/delete/stale-format scenarios
and whole-span fallback trials in `testing.md` pass. A real emoji/mark/RTL span
must retain cluster coverage and selection provenance when the primary face fails;
an all-faces-fail span must remain explicitly unresolved.

## M8 Consumer migration

**Obligations.** `FTA12`–`FTA14`, `FTA16`.

**Prerequisites.** M1–M7. [`FTX7`](decisions.md#ftx7-ligatures-keep-one-glyph-per-cell-their-ink-crosses-cells)
permits only an audited terminal fast path; general cluster placement is required.

**Deliverable.** `sparkles:raylib-text` rebuilt over `sparkles:font`; the
spike's `shaping_c.c`, `shaping_api.h` and `shaping.d` and the discovery modules
deleted; `hue`, `terminal`, `terminal-view`, `ui-raylib` and `ui-app` updated.

**Acceptance.** All consumers' test suites pass; the Android APKs build in CI;
local screenshot goldens identical or listed with captures (`FTA14`); with a
ligature font, the terminal neither clips a ligature's ink to one cell nor leaves
stale ink when one of its cells changes (`FTX7`). Non-fast-path ligatures, combining
marks, RTL and multi-cell source spans use returned positions and cluster mappings,
not glyph index. Obsolete UTF/Unicode and cluster-placement helpers are deleted
at caller cutover rather than kept as alternate owning paths.

**Consumer surface to replace**, measured on 2026-10-03 at `d4bf07306`:

| Consumer                        | Uses from `sparkles:raylib-text`                                                                          | Moves to                                                             |
| ------------------------------- | --------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| `sparkles:ui-app` `gui_setup.d` | `FontSet.tryLoad`, `FontSources`, `FaceOverrides`, `reload`, `unload`, cell width and height, DPI helpers | the font catalog and fallback chain, cell metrics, DPI helpers moved |
| `hue` `gui.d`                   | cell width and height, `reload`, `flushPending`, `drawText`, DPI helpers                                  | cell metrics; drawing stays in `raylib-text` over this library       |
| `sparkles:ui-raylib`            | `drawText`, `drawBox`, `TextStyle`, cell metrics                                                          | the same `raylib-text` calls with new internals                      |
| `sparkles:terminal-view`        | `drawGrapheme`, `drawSolid`, `drawCluster`, `resolveFace`, `primaryFont`, `whiteFace`                     | fallback lookup, shaping, and atlas upload in `raylib-text`          |
| `apps/terminal` (Android)       | `drawText`, `TextStyle`                                                                                   | the same `raylib-text` calls                                         |

### Gates for the text/publication stack

Delivered M2 scalable measurements and M4/M7 shaping/fallback are prerequisites
for [text-layout contextual composition](../text-layout/SPEC.md#_5-contextual-composition).
M2 `MATH` data plus M3 outlines where required are prerequisites for math resource
integration; M2 `BASE`/vertical metrics plus M4 vertical shaping gate vertical
writing. GDEF/JSTF capability acceptance belongs to M4. Optional tables can be
absent in a particular face, but a feature gate cannot be accepted only on fonts
that lack the relevant data. Math composition and page/frontend/export delivery
remain above font and are not milestones satisfied by this plan.

**Gate:** these prerequisites pass only when `libs/font` exists and M2, M4 and M7
carry implementation evidence in [`testing.md`](./testing.md). The research spikes
establish only their recorded configurations; they do not satisfy M2/M4/M7 or
permit text-layout to substitute fake fonts. Progress states above remain the
delivery authority.

**Handoff.** Stage 0 and M1 are done: the owner accepted the specification on
2026-10-06, and `libs/font` parses faces, tables, character maps, names and
glyph names, checked against HarfBuzz over the bundle, and passes its tests on
an x86_64 Android emulator. Open M1 gaps are in the evidence ledger: running
the arm64-v8a tests (`FTA7`) and a race-detector run of the concurrency test
(`FTA2`). Next action: M2. It waits for base's accepted
physical-unit arithmetic and conversion contract, and for its `MATH`, `BASE`
and vertical-metric query contracts to be refined first.
