---
status: draft
owner: sparkles:ui
reviewed: 2026-10-05
---

# Glyphs & typography (`GLY`)

## Abstract

Glyphs and type are how `sparkles:ui` draws one theme on a terminal's
character grid, in a GPU window and on a web page. This page specifies their
projection, the rule that turns a request a target cannot draw into one it can.
The canvas caps each requested glyph at what the target declares, so a border,
rule, fill, status mark (the small symbol that pairs with an error, warning or
success color) or icon falls back to a simpler character. The page also fixes
which width profile a terminal grid is driven under, how chrome glyphs (the
characters a widget draws around and between its content) occupy cells, and
which face each kind of text is drawn in. Every substitution is a published,
tested rule, and proportional text stays inside the cell rectangle layout gave
it.

## Introduction

A theme asks for things a character grid cannot hold: a two-pixel rounded
border, a one-pixel hairline rule, a scrollbar thumb that moves by less than a
character, a file-type icon, a larger heading. A window and a web page can draw
all of them. A terminal can draw some of them, depending on its font and the
protocols it speaks, and a pipe can draw none. The
[capabilities page](./capabilities.md) says what each target declares; this
page says what is drawn for each declaration.

Text compounds the problem. A terminal advances its cursor by whole grid cells,
and terminals disagree about how many cells an emoji sequence or a combining
mark occupies. When the toolkit's idea of a width differs from the terminal's,
every later character on the row lands in the wrong column. Proportional text in
a window has the opposite problem: it has no cells at all, but the layout around
it is made of them.

The approach has three parts. Glyphs form nested tiers, from ASCII up to Nerd
Font icons, and the canvas caps each requested glyph at the target's tier and
reports the substitution. Text width on a grid is measured per
[grapheme cluster](../../glossary.md#grapheme-cluster) under a named
[width profile](../../glossary.md#width-profile) that matches what the terminal
does, so the cursor and the drawing agree. Proportional text is laid out by the
text-layout library inside the rectangle of [cells](../../glossary.md#cell) the
toolkit gave it, so the cell layout around it never moves.

The design system owns the projection rules, the status marks and the
[font roles](../../glossary.md#font-role). It does not own the width algorithm,
the Unicode data or the scaled cell footprints of sized text: those belong to
[`sparkles:base` text](../base/text/SPEC.md). It does not match fonts or build
fallback chains, which belong to the [font specification](../font/SPEC.md), and
it does not lay out proportional paragraphs, which belong to
[text layout](../text-layout/SPEC.md). Bidirectional text and shaping on a cell
target are non-goals.

Glyph tiers, border projection and status marks come first, then fonts and
icons, then typography and sizing, then sub-cell rendering and media. Oracles
and evidence live in [testing.md](./testing.md), delivery order in
[PLAN.md](./PLAN.md), and the reasoning behind each choice in
[decisions.md](./decisions.md).

## Contract at a glance

1. The canvas caps every glyph at the target's declared tier and reports the
   substitution; a component never degrades a glyph itself (D30).
2. A bordered box on a cell target reserves one cell per drawn edge; weight,
   style and radius only choose the glyphs in that cell.
3. Every glyph in the [glyph channel](../../glossary.md#glyph-channel) — marks,
   box drawing, rules, sub-cell blocks and Private Use Area icons — is one
   [grid cell](../../glossary.md#grid-cell) wide under every width profile.
4. Text width on a grid is measured in grapheme clusters under a base/text
   width profile chosen from what the terminal was measured to do; a cluster is
   never truncated.
5. A [font role](../../glossary.md#font-role) names a font request, a fallback
   chain and code-point routes; components name roles, never faces.
6. Proportional text occupies the cell rectangle layout gave it on every
   target, and one layout result serves painting, hit-testing and selection.

## Glyph tiers

| ID     | Requirement                                                                                                                                                                                                                                                                    | Status  | Traces to                                                                                                                                                       |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GLY1` | Glyphs **must** be organised in **nested tiers**: `ascii ⊂ boxLight ⊂ boxFull ⊂ blocks ⊂ braille ⊂ nerdFont`. The target's declared tier **must** cap the charset a theme prefers per role, and the capped choice is the published substitution ([`CAP6`](./capabilities.md)). | partial | `glyphs.d` `needOf`/`admits`/`fallbackOf`/`projectGlyph`; `ui_tui` `GridCanvas` projects every glyph; per-role theme preferences only for marks (`MarkCharset`) |

**GLY1 notes.** `boxFull` adds the heavy, double, rounded and dashed families
to `boxLight`; `blocks` is graded by the target's `blocks` level. The roles a
theme names a charset for are frame, rule, tree guide, thumb and marks.
Violation: a glyph outside the target's tier reaching the canvas.

## Border projection

A bordered box on a cell target **always reserves one cell** per drawn edge;
weight, style and radius select the glyphs in that cell. Sub-cell edges are for
things that do not own a cell: rules, separators, scrollbar thumbs and progress
fills.

| ID      | Requirement                                                                                                                                                                                                                                 | Status  | Traces to                                                                                                                                |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `GLY2`  | A px-typed border **must** project onto a cell target by one pure function of `(BoxBorder, radius, TargetCapabilities)` that follows the projection table below. The table is exhaustive and **must** be tested per cell.                   | full    | `tokens.d` `projectBorder`, `boxGlyphs`, test `ui.tokens.projectBorder.table` (`O7`); `ui_tui` `drawBoxBorder`; `cells.d` tables derived |
| `GLY2a` | **Sub-cell edges.** Where `blocks ≥ half`, a hairline rule or separator **may** be drawn as a thin edge on the cell boundary, and a thumb or fill as eighth-blocks. A sub-cell glyph **must not** reach a target declaring `blocks = none`. | partial | `glyphs.d` ladder (eighth-block bars thin to strokes at `blocks = none`); `ui_tui` accents. Pending: the sub-cell hairline rule          |

The `GLY2` projection table:

| Request              | Glyphs on a cell target                                         |
| -------------------- | --------------------------------------------------------------- |
| width `0`            | no edge                                                         |
| width `1`            | the light family                                                |
| width `≥ 2`          | the heavy family                                                |
| style `double_`      | `boxDouble` (`═║╔╗╚╝`); weight and radius are lost and reported |
| style `dashed`       | `╌╍╎╏`, in its weight                                           |
| style `dotted`       | `┈┉┊┋`, in its weight                                           |
| radius `> 0`, light  | arcs (`╭╮╰╯`)                                                   |
| radius `> 0`, heavy  | arcs drawn light; the weight is reported lost (D31)             |
| radius `> 0`, double | square corners; the radius is reported lost                     |
| any, below `unicode` | `+-\|`, except dotted, which keeps `.`/`:`                      |

**GLY2a notes.** The thin cell-boundary edges are `▏▕▔▁`; the eighth-block
ladders are `▏▎▍▌▋▊▉█` and `▁▂▃▄▅▆▇█`. Which elements use sub-cell edges is a
theme choice per role (`GLY1`); the mechanism is the target's. A 1 px rule drawn
this way does not consume a whole cell of `─`.

## Status marks

| ID     | Requirement                                                                                                                                                                                                                                                                                                                                                                              | Status | Traces to                                                                          |
| ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ | ---------------------------------------------------------------------------------- |
| `GLY3` | The glyph channel **must** carry one **mark** per `status.*` token and per task state (`WGT25`), in the `nerdFont`, `unicode` and `ascii` charsets, which `ACC3` reads. Every glyph-channel glyph, marks included, **must** be one grid cell under every width profile, as base/text's glyph-channel set ([`TXT-CELL7`](../base/text/SPEC.md#_6-cell-text-and-coordinates)) measures it. | full   | `glyphs.d` `Mark`/`markGlyph`; `components/theme.d` `StatusGlyphs` reads the table |

**GLY3 notes.** The `unicode` marks are `✔ ✖ ⚠ • ○ ◐ ┄`; the `ascii` marks are
`+ x ! * o ~ .`. The charsets' forms agree with the fallback ladder (`GLY1`),
and because a mark is one cell in every charset, columns do not shift between
charsets. The glyph channel is box drawing, block elements and the sub-cell
ladder, status marks, and Private Use Area icons. A width profile's
ambiguous-width choice applies to text, not to that set: base/text names the
exempt set by range (`TXT-CELL7`, decided in its D-TXT-13), so measurement and painting agree on a terminal configured
for wide ambiguous characters (D52).

## Fonts and icons

| ID      | Requirement                                                                                                                                                                                                                                                                                                                        | Status      | Traces to                                                                                                                                                                        |
| ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GLY4`  | A **Nerd Font is baseline on GUI and Web** and **optional on the TUI**, where it is the configured `nerdFont` capability. Its version **must** be the one the flake's pinned nixpkgs ships, and the toolkit's icon table **must** be generated from that release's `glyphnames.json` and checked in.                               | not started | `nix/packages/fonts.nix`; proposed `sparkles.ui.icons`                                                                                                                           |
| `GLY11` | The design system **must** own the **font roles** (`FontRole`). A role's value **must** be a font request ([`FTD4`](../font/SPEC.md#_13-discovery-matching-and-fallback)), a fallback chain (`FTD5`) and code-point routes (`FTD6`); a component **must** name a role, never a face.                                               | not started | proposed role values in `sparkles.ui.theme_file` (`FMT1`); [font `FTD4`–`FTD6`](../font/SPEC.md#_13-discovery-matching-and-fallback)                                             |
| `GLY7`  | On targets with `proportionalText`, a run in `FontRole.docs` **may** be set in a proportional face. It **must** then be laid out as a text-layout [`shapedFlow`](../../glossary.md#shaped-flow) paragraph inside the widget's cell rect, and painting, hit-testing and selection **must** use that paragraph's one cluster result. | not started | [text-layout `TL-003`, `TL-025`](../text-layout/SPEC.md#_6-source-maps-and-interaction); gated on text-layout TL-M3                                                              |
| `GLY10` | An application's own chrome **may** name the **interface face** (`FontRole.ui`) at a step of the **chrome type scale** (`TypeStep`), never at a raw size. Its painted extent **must** stay inside its layout rect, and runs on one line **must** share a baseline.                                                                 | partial     | `TypeStep`, `typeStepDp`, `isStyledTextMeasure`, `Frame.lineRows`, `UiFonts`, `resolveUiFace`, `GuiMeasure`, `RaylibCanvas.textRunIn`, `loadUiFaces`; `Substitution.monospaceUi` |

**GLY4 notes.** The bundled `sparkles-fonts` set carries the Nerd Font faces on
GUI and Web ([`FNT`](../hue/gui.md)). A terminal cannot be queried for a Nerd
Font, so the TUI learns it only from configuration (D29). The design system does
not pin the version separately (D10). Because the icon table (`nf-*` names to
code points) is checked in, a nixpkgs bump that moves a code point is a golden
diff, not a silent glyph swap. On GUI and Web, Nerd Font icons reach a role
through a code-point route (`GLY11`).

**GLY11 notes.** A font request is the family, width, style and weight the font
library matches. The fallback chain is the ordered list of faces tried after the
match. A code-point route sends a range to a chosen face; the canonical route
sends the Private Use Area to a Nerd Font face. The font library never learns
the word "role": it receives the request, the chain and the routes (D54). The
theme file maps the roles to DTCG `fontFamily`, `fontWeight` and `typography`
tokens (`FMT1`), the Sparkles theme fixes their values (`SPK4`), and the web
target declares them as CSS custom properties (`WEB6`).

**GLY7 notes.** The paragraph is text-layout's `shapedFlow` mode
([`TL-003`](../text-layout/SPEC.md#_2-ownership-and-scope)): it consumes
physical lengths and real font shaping. The cell rect is the layout's; the
paragraph is measured in px and wrapped or clipped inside it, and text-layout's
shared-geometry rule ([`TL-025`](../text-layout/SPEC.md#_6-source-maps-and-interaction))
makes painting, hit-testing and selection read one committed result. A cell
target renders the same run monospace in the same rect. Violation: a docs run
whose painted extent leaves its layout rect on any target, or a hit-test or
selection computed from geometry other than the painted result. No interim
implementation outside text-layout satisfies this requirement (D53; text-layout
[`TLD-008`](../text-layout/decisions.md#tld-008-toolkit-proportional-prose-is-a-shaped-flow-consumer)).
The same run on a cell target is never visually reordered (text-layout
`TL-052`). Its gate,
text-layout TL-M3, is itself gated on font M4 and M7 ([PLAN.md](./PLAN.md)).

**GLY10 notes.** The steps are caption 12, label 13, body 14 and title 17
density-independent px. A target with `proportionalText` draws the run in a
proportional sans at that size: the run is measured in px and rounded up to
whole cells, a line takes as many rows as the step's line height needs, and the
run is centred in those rows. A code point the face lacks is drawn from the
cell font at the same size. A cell target draws the run in the cell font, one
row a line, and reports `monospace-ui`. The face choice is D49. Violation: an
interface run whose painted extent leaves its layout rect, or two runs on one
line drawn at different baselines.

## Typography and sizing

| ID      | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                          | Status      | Traces to                                                                                                                                                                                                |
| ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GLY5`  | The type hierarchy **must** be expressed **in attributes first**, so a heading is distinguishable at `baseline`. Where `textSizing` is declared, a heading **may** also render at scale; its footprint **must** be base/text's scaled grid-cell footprint, and the fallback **must** consume the same rows and columns.                                                                                                                              | not started | `source_view.markdown` heading icons; `TextStyle.fontScale`; [base/text `TXT-SIZE1`–`TXT-SIZE5`](../base/text/SPEC.md#_6-4-scaled-grid-cell-footprints)                                                  |
| `GLY6`  | Width **must** be measured **in grapheme clusters** under a base/text width profile, never per code point. Where `graphemeClusters` is declared, the grid **must** run under `terminalKitty`; elsewhere it **must** run under `terminalUnclustered`, whose emission rule draws a cluster **folded** to its leading scalar, padded to the clustered advance, only where its scalars would advance differently (base/text `TXT-CELL12`, `TXT-CELL13`). | partial     | `base.text` graphemes (`graphemeClusterWidth`, `unclusteredWidth`); `ui-tui` `GridCanvas.textRun` (`tui_canvas.capabilities.graphemeClusters`); `degradation.d` `grapheme-folded`; base/text `TXT-CELL5` |
| `GLY12` | A cluster longer than a TUI cell's inline bytes **must** be kept whole through the cell's overflow storage. Exhausting that storage **must** fail explicitly; a cluster is never truncated.                                                                                                                                                                                                                                                          | not started | [base/text `TXT-CELL8`](../base/text/SPEC.md#_6-cell-text-and-coordinates); `libs/tui` cell storage under base/text's M5 cutover                                                                         |

**GLY5 notes.** A heading level maps to a weight, a color token, an underline
or overline, and a leading glyph. Scaled rendering uses kitty's text-sizing
protocol (OSC 66). base/text owns the scaled grid-cell footprint
([`TXT-SIZE1`–`TXT-SIZE5`](../base/text/SPEC.md#_6-4-scaled-grid-cell-footprints)):
a run's integer scale and fractional width as part of the cell model, that is,
grid-cell advances at a scale (D54, text-layout
[`TLD-009`](../text-layout/decisions.md#tld-009-terminal-text-sizing-belongs-to-base)). The design system owns only the choice to use it and
the capability question of whether a terminal honours it (`textSizing`,
[OQ5](./decisions.md#open-questions)). Because the fallback consumes the same
rows and columns, a document does not reflow between a sizing and a non-sizing
terminal. The [text-sizing proposal](../../research/tui-libraries/text-sizing/sparkles-proposal.md)
is the surveyed mechanism; its M0 is this row's entry condition.

**GLY6 notes.** The width profiles and their rules are base/text's
([cell text and coordinates](../base/text/SPEC.md#_6-cell-text-and-coordinates),
[cell policy](../base/text/index.md)). The two width profiles have the same
advances, so layout is identical on every terminal: a ZWJ family takes two grid
cells, and so does `❤️`. They differ only in emission. `terminalKitty`, the
default, emits each cluster whole. `terminalUnclustered` (base/text `TXT-CELL5`)
emits a cluster whose scalars would advance differently, such as a ZWJ
sequence or a `VS16` presentation, as its leading scalar padded with spaces to
the clustered advance, or as a one-cell substitute when the leading scalar
alone would be wider (`TXT-CELL12`, `TXT-CELL13`). A cluster whose scalars
already sum to its advance, such as a letter with a combining accent, is
emitted whole. That emission rule is the toolkit's fold (`grapheme-folded`): a
terminal that does not cluster advances its cursor by every scalar it receives,
so sending only the leading scalar keeps the cursor and the drawing in
agreement, and the row never moves (D50). `graphemeClusters` is declared where
the terminal answered mode 2027 or a test cluster was measured as one character
(D38). The fold belongs to a named width profile, not to a compatibility helper: each
caller uses one profile, as base/text's `TXT-MIG1` requires. East Asian ambiguous width is a user setting of the
profile, which the glyph channel ignores (`GLY3`). The toolkit's segmentation is
reconciled with the terminal's by the libghostty-vt width oracle in tests.
Bidi and shaping are a **non-goal** on the cell target.

**GLY12 notes.** A TUI cell holds 16 bytes of cluster inline. A longer cluster,
such as a long ZWJ sequence or a base with many combining marks, spills into
storage the grid owns, so it is drawn and copied whole on every target (D50).
When that storage is exhausted, the render fails with an explicit error rather
than truncating the cluster or folding it. base/text states the storage rule as
`TXT-CELL8` (decided in its D-TXT-12). The requirement follows base/text's
cutover of the TUI grid (the `libs/tui` row of base/text's
[M5 cutover](../base/text/PLAN.md#_6-m5-concrete-clean-cutovers)).

## Sub-cell rendering and media

| ID     | Requirement                                                                                                                                                                                                                                 | Status  | Traces to                                                                                                                                                                                                                                                                |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `GLY8` | Meters, sparklines and scroll thumbs **must** use the **finest sub-cell unit the target declares**. Each **must** have an exact fallback ladder down to `ascii` (`#` / `=` / `-`), and the rung chosen **must** be reported (`CAP6`).       | partial | `components/meter.d`, `progress.d`; eighth-block fills fold by the `GLY1` ladder and are reported (`blocks-folded`)                                                                                                                                                      |
| `GLY9` | An image **must** render by the ladder **protocol → block raster (`blocks` level) → braille → alt text**. The placeholder's cell size **must** be the same on every rung, so layout never depends on which rung a target reached (`WGT22`). | full    | `sparkles.ui.image_raster` (`imageRungOf`, `paintImageRaster`, `blockOctantGlyphs`); `degradation.d` rows `image-rastered`/`image-as-alt`; the protocol rung `IMG5` (`sparkles.tui.images`, `sparkles.tui.sixel`, `sparkles.tui.probe`); tests `ui.imageRaster.*` (`O7`) |

**GLY8 notes.** The finest unit is eighth-blocks for one-dimensional fills,
`braille` (2×4) for plots, and the `blocks` level for two-dimensional rasters.

**GLY9 notes.** The cell rungs draw half blocks, quadrants, sextants, octants
and braille, with two colours per cell chosen by an area-sampled split. They are
drawn by `ui-tui`'s grid and by a `ui-raylib` window narrowed to a capability profile. The
octant glyphs are generated with `sparkles.base.text.unicode_tables` by
`libs/base/tools/gen_unicode_tables.d`. The protocol rung draws kitty graphics
and sixel. The tests cover every pattern of every rung.

→ [Overview](./index.md) · [Capabilities](./capabilities.md) · [Specification](./SPEC.md)
