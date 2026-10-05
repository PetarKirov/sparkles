# `sparkles:ui`

A **canvas-first, backend-neutral UI toolkit** — the shared visual language behind
the twoslash overlay across the raylib GUI (`hue --gui`), the interactive terminal
TUI (`hue --twoslash`), and HTML. One widget tree, one palette, four backends: the
`--twoslash-*` chrome that was triplicated across CSS, hand-copied raylib literals,
and ANSI SGR now traces to a single source here.

The pipeline is **`view() → layout() → buildDisplayList() → paint(canvas)`**; every
stage before `paint` is `@safe` and GL-free (the pure model is fully unit-testable
through a `RecordingCanvas`). A widget names a semantic **`Slot`**, never a concrete
color — the `Palette` resolves it to a `Visual` during display-list construction.

## Modules (`libs/ui/src/sparkles/ui/`)

| Module                     | Role                                                                                                                                                                                                                                                                                                                                |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `geometry`                 | `Point`/`Size` (specializing `sparkles:math`'s `Vector`, like `TermSize`/`TermPosition`), `Rect`/`Insets` in abstract cells and `SizeSpec`; text width/fitting comes from owned base `visibleWidth`/`fitCells`, not geometry exports                                                                                                |
| `style`                    | `Slot`, the resolved `Visual` (color + border/radius/shadow/font), authoring `Decoration`/`TextStyle`, `Palette`, `defaultTwoslashPalette`, `resolveSlot`/`resolveVisual`                                                                                                                                                           |
| `canvas`                   | the DbI `isCanvas!T` capability concept (not an interface), `DrawOp`, the `@safe` `RecordingCanvas`                                                                                                                                                                                                                                 |
| `widget`                   | the flat-arena `Widget` (currently a tagged record; `WGT3` targets a closed sum) with explicit `uint[]` child-index lists + `Builder`                                                                                                                                                                                               |
| `layout`                   | the two-pass box-flow layout (`row`/`column`/`stack`/`panel`/`popup`)                                                                                                                                                                                                                                                               |
| `state`                    | presentation-free interaction machines for hover, scroll, selection, disclosure, focus, activation and pointer capture                                                                                                                                                                                                              |
| `keymap`                   | keyboard policy as data: `Binding!(Cmd, Scope)` tables over app-supplied enums, chord matching/normalisation, and two-direction resolution (`resolve` ↔ `bindingsAt`)                                                                                                                                                               |
| `lantern`                  | the which-key-style guide machine — the pending prefix path, the reveal delay, the panel's own keys — pure over any table (`components/lantern_view` builds the panel)                                                                                                                                                              |
| `components/settings_pane` | the modal settings pane over any configuration struct (`SettingsPane!(T, resolveKey)`): live, range-checked, undoable edits through the property tree; autosave of only the changed paths with a "Saved" toast whose Undo is the tree's history; per-leaf provenance from a host-supplied `originOf`. hue and the terminal mount it |
| `display_list`             | `buildDisplayList` — resolves each node's slot + decoration + text style into `DrawOp`s                                                                                                                                                                                                                                             |
| `interp/immediate`         | `paint(canvas, ops)` — the immediate-mode replay (attributes inferred from the canvas)                                                                                                                                                                                                                                              |
| `interp/cells`             | a retained cell-grid interpreter (diffed minimal updates)                                                                                                                                                                                                                                                                           |
| `interp/html`              | the **widget → semantic HTML + inline CSS** emitter — the parity ground-truth oracle (see below)                                                                                                                                                                                                                                    |

The concrete canvases are sibling adapters that depend on `sparkles:ui`:
`RaylibCanvas` in `sparkles:ui-raylib` and `GridCanvas` in `sparkles:ui-tui`.

Text-cell authority is owned Unicode 18.0.0 **whole extended graphemes**, without
a scalar-count/UTF-8-byte cap. Plain display-list runs use base `fitCells`; rich
runs retain selected projection spans and advances. Font ink and backend glyph
coverage do not redefine cell occupancy. Retained paragraph composition is specified
separately in the [text-layout contract](../../specs/text-layout/SPEC.md).

`GridCanvas` retains complete clusters on targets declaring `graphemeClusters`,
including sequences longer than the former inline-cell storage bound. Folding
to a leading code point is negotiated target degradation, not a byte-count limit;
the following glyph keeps its original cell position on either target.

Uncommitted rich paragraphs retain `Widget.whitespace` through width allocation.
The default is owned `WhitespaceMode.collapse` for prose; source-view code rows
explicitly select `preserve`, retaining authored indentation and trailing spaces
without disabling bounded wrapping. `CodeViewOptions.tabWidth` owns contextual
tab expansion before those rows enter layout. Already-realized rich rows keep
their committed projection instead of applying whitespace policy again.

Styled targets may supply `brushMetrics(style).append(wholeClusterChunk)` for
incremental rich-row metrics. Raylib's `GuiMeasure` uses it for both cell and
interface faces: each cluster is traversed once, and cumulative pixel advances
are rounded at complete brush-run boundaries, not independently per cluster.
Inherited styles and whole-cluster paint/hit geometry remain shared. Interface
measurement and drawing both skip ANSI escape sequences with the base scanner.
Only an explicit `monotonePrefixes` certificate enables the wrapping prefix
search optimization; arbitrary callbacks remain uncertified. For a callback
whose prefixes move backwards, rich hit boundaries use their suffix-minimum
envelope: the movement is distributed backwards without changing the measured
complete-run extent or introducing negative cluster advances. Negative target
extents remain invalid; reconciliation never turns them into silent zero-width
content. Real interface pixel accumulators explicitly start at zero, not D's
default floating-point NaN.
Non-`@nogc` arbitrary adapters retain exact retry enumeration with a
collision-checked hash cache and can remain expensive; `GuiMeasure` uses the
direct `@nogc` measurement callback rather than that adapter.

## The two-direction parity harness

Visual parity is attacked from two directions, each machine-assisted:

1. **Do the widget settings match the CSS?** The `Palette` authors the canonical
   twoslash colors and scalar chrome (border widths, radius, shadow geometry, font
   scales, arrow) **once**. The `style.twoslashCss.paletteLockstep` and
   `metricsLockstep` tests (in `sparkles:twoslash`) assert those values equal the
   ones in `views/twoslash.css` — each expected token built _from_ the D value, so
   drift on either side fails the build.

2. **Are the widget settings rendered correctly?** `interp/html` renders the _same_
   widget tree the GUI/TUI paint to a self-contained HTML page; a browser then
   establishes the ground truth for what the widget spec should look like. The
   `capture-modes` QA tool (`apps/hue/tools/capture-modes.d`, `widgets-html` mode)
   screenshots it headlessly, so the raylib and terminal rasters can be compared
   against a browser's rendering of their own spec — and the generated `widgets-html`
   against the hand-authored `html` (`render_html`) mode.

```
dub run --single apps/hue/tools/capture-modes.d -- --out /tmp/parity --hover 0
```

## Backend degradations (honest, documented)

The abstract model expresses sub-cell chrome; a **cell grid cannot**, so the
`GridCanvas` (TUI) approximates and drops what it can't draw:

- a **bottom-only border** (the `.twoslash-hover` dotted underline) → a dotted/single
  **cell underline**;
- a **full box border** (the popup) → **box-drawing glyphs** on the popup's blank
  1-cell padding ring, with rounded corners (`╭╮╰╯`) approximating `borderRadius` and
  a `┴` notch for the arrow;
- a **single-side sub-cell accent** (the docs top divider, the error/tag left bar),
  the corner **radius**, the drop **shadow**, and the underline **fade alpha** have no
  cell analog and are **dropped** — the block's background tint still conveys it.

The GUI honors all of the above except **`FontRole`/`fontScale`**: the fixed-size
cell grid keeps monospace at 1em (so popup docs render mono, not sans). HTML honors
everything.

## See also

- [`sparkles:twoslash`](../twoslash/index.md) — the overlay this renders; hosts the
  `render_widgets` view (`viewTwoslash`/`viewHoverPopup`) and the CSS lockstep tests.
- [`sparkles:syntax`](../syntax/index.md) — the `RgbColor`/`Color`/theme layer reused
  here (the library adds no color type).
