---
status: accepted
owner: sparkles:font-explorer
reviewed: 2026-10-06
---

# `font-explorer` — Design register

The mockups drawn for every surface, the variant chosen for each, and what
the reference applications showed. Behaviour is specified in
[`SPEC.md`](./SPEC.md); this page records appearance and layout.

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

Chosen by the project owner on 2026-10-03.

| Surface                 | Variants drawn                                                                                                                | Chosen                                                                                          |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Explorer window         | **A** three panes. **B** specimen first, with a face palette and an inspector drawer. **C** family grid beside a detail page. | **A**, with the left pane reworked into a source navigator and a family list (`FXP28`, `FXP29`) |
| Compare                 | **A** synced cards. **B** aligned rows. **C** outline overlay.                                                                | **All three**, as modes of one view (`FXP30`)                                                   |
| Programming-font checks | **A** dashboard of blocks. **B** code first with a checklist.                                                                 | **A**, built on the dock container so users arrange it (`FXP31`)                                |
| Terminal arm            | **A** explorer A in cells. **B** tabs with a key guide.                                                                       | **A**, with the window's width classes and overlays (`FXP32`, `FXP33`)                          |
| `inspect` output        | **A** boxed sections. **B** compact key/value lines.                                                                          | **A**                                                                                           |

### Revised explorer A

The second round of mockups draws the chosen layout at each width class:

| Board                      | Size           | Width class | Shows                                                                         |
| -------------------------- | -------------- | ----------- | ----------------------------------------------------------------------------- |
| Explorer A revised, wide   | 1440 × 900 px  | wide        | navigator, family list with own-face samples, specimen, inspector             |
| Explorer A revised, medium | 1024 × 768 px  | medium      | source picker folded into the list; inspector collapsed to an edge handle     |
| Explorer A revised, narrow | 640 × 860 px   | narrow      | specimen only, with the library overlay open over it                          |
| Terminal A, wide           | 160 × 48 cells | wide        | the four panes in cells; each family row's sample is one kitty image          |
| Terminal A, medium         | 120 × 36 cells | medium      | the original terminal A, with the source picker in the library header         |
| Terminal A, narrow         | 80 × 24 cells  | narrow      | specimen only, and the same with the library overlay open                     |
| Checks on the dock         | 1440 × 900 px  | —           | split and tabbed panes, a tab mid-drag over an east drop zone, a saved layout |

At the mockups' 13 px interface font, 1,440 px is about 184 cells, 1,024 px
about 131, and 640 px about 82, which places the three window boards in the
three classes.

### What the reference apps showed

The left-pane rework follows three font managers, read from their product
screenshots on 2026-10-03:

- **Sources and fonts are separate panes.** FontBase, RightFont and Typeface
  each keep a navigator of where fonts come from beside a separate list of the
  fonts. Their navigators hold "All" with a total, recents or favourites,
  collections, providers, folders as a tree with per-node counts, and tags or
  smart filters.
- **The list renders each family in itself.** All three show a sample per
  family in that family's face, under one global sample text and size
  control, with the family name, a style count and a status mark above it.
  FontBase uses full-width rows, while RightFont and Typeface use a card grid.
- **A family opens into its styles.** Typeface lists a family's styles as rows
  with designer, version, source and file, with tabs for characters, text,
  features, variables and info. That last set matches this application's
  inspector.
- **Smart filters are saved rule sets.** RightFont builds them from rules such
  as "languages contains Arabic". `FXP28` keeps the facets as saved filters and
  leaves a rule editor out of scope.

Families not available as web fonts, such as Maple Mono and DejaVu Sans Mono,
are drawn with a stand-in face in the mockups.

## Findings made while drawing

- Fira Code Nerd Font Mono stores four advance records; every glyph but glyph 1
  (zero-width) advances 1,200 units, so the cell-grid check can be exact.
- Its Nerd Font coverage, counted from the bundle's charset sidecar: Powerline
  8/8, Powerline Extra 32/36, Devicons 496/496, Font Awesome 1,488/1,536,
  Material Design 6,896/6,896, Codicons 439/447, Octicons 308/308, Weather
  228/228, box drawing 128/128, block elements 32/32. Range bounds are the
  Nerd Fonts 3 assignments as written in the counting script; a partial range
  may reflect the bounds rather than the font.
