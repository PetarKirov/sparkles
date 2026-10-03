---
status: draft
owner: apps/font-explorer
reviewed:
---

# `font-explorer` — Design register

_Mockups for every surface, and the variant chosen for each. Layout stays open
until a variant is chosen; behaviour in [`SPEC.md`](./SPEC.md) holds for any
choice._

**Mockups:** the "Font Explorer mockups" design canvas (private to the project
owner until shared), produced 2026-10-03.

## Rules every variant follows

- Colours are named by design-system slot (`surface.*`, `text.*`, `border.*`,
  `accent.*`, `status.*`), so a theme swap restyles the app; no variant depends
  on a literal colour.
- Focus is visible without colour: the focused row is reverse video with a `▸`
  marker, and the focused pane carries a framed title (`┤ preview ├`).
- Status is never colour alone: ✓, ! and ✗ marks accompany every status colour.
- Chrome is laid out in whole cells; only specimens are free-form images.
- Every figure shown is read from the bundled Fira Code Nerd Font Mono and
  Noto Sans files on 2026-10-03, or is a bracketed placeholder.

## Surfaces

| Surface                 | Variants                                                                                                                                                                                               | Chosen |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------ |
| Explorer window         | **A** three panes: library, specimen tabs, inspector tabs. **B** specimen first: a fuzzy face palette and a bottom inspector drawer. **C** family grid of sample cards beside a scrolling detail page. | open   |
| Compare                 | **A** synced cards in columns with metric lines and per-face figures. **B** aligned rows, one per face, sortable by a metric. **C** two faces' outlines overlaid, distinguished by line style.         | open   |
| Programming-font checks | **A** dashboard of six blocks: code, cell grid, Nerd Font coverage, disambiguation, seams. **B** code first, ligature sites underlined, a checklist and live terminal beside it.                       | open   |
| Terminal arm (120×36)   | **A** the three panes of explorer A in cells, specimen as one kitty image. **B** tabbed, library rows with per-row sample images, a which-key guide.                                                   | open   |
| `inspect` output        | **A** boxed sections. **B** compact headed key/value lines.                                                                                                                                            | open   |

## Findings made while drawing

- Fira Code Nerd Font Mono stores four advance records; every glyph but glyph 1
  (zero-width) advances 1,200 units, so the cell-grid check can be exact.
- Its Nerd Font coverage, counted from the bundle's charset sidecar: Powerline
  8/8, Powerline Extra 32/36, Devicons 496/496, Font Awesome 1,488/1,536,
  Material Design 6,896/6,896, Codicons 439/447, Octicons 308/308, Weather
  228/228, box drawing 128/128, block elements 32/32. Range bounds are the
  Nerd Fonts 3 assignments as written in the counting script; a partial range
  may reflect the bounds rather than the font.
