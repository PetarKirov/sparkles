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

| Module             | Role                                                                                                                                                                      |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `geometry`         | `Point`/`Size`/`Rect`/`Insets` in abstract cells; `SizeSpec`; `cellsOf` — the **one** width authority                                                                     |
| `style`            | `Slot`, the resolved `Visual` (color + border/radius/shadow/font), authoring `Decoration`/`TextStyle`, `Palette`, `defaultTwoslashPalette`, `resolveSlot`/`resolveVisual` |
| `canvas`           | the DbI `isCanvas!T` capability concept (not an interface), `DrawOp`, the `@safe` `RecordingCanvas`                                                                       |
| `widget`           | the flat-arena tagged-union `Widget` (children as `uint[]` index lists) + `Builder`                                                                                       |
| `layout`           | the two-pass box-flow layout (`row`/`column`/`stack`/`panel`/`popup`)                                                                                                     |
| `state`            | `HoverState` — a presentation-free hit-test                                                                                                                               |
| `display_list`     | `buildDisplayList` — resolves each node's slot + decoration + text style into `DrawOp`s                                                                                   |
| `interp/immediate` | `paint(canvas, ops)` — the immediate-mode replay (attributes inferred from the canvas)                                                                                    |
| `interp/cells`     | a retained cell-grid interpreter (diffed minimal updates)                                                                                                                 |
| `interp/html`      | the **widget → semantic HTML + inline CSS** emitter — the parity ground-truth oracle (see below)                                                                          |

The concrete canvases are adapters that depend on `sparkles:ui`: `RaylibCanvas`
(`apps/hue/src/gui_canvas.d`) and `GridCanvas` (`apps/hue/src/tui_canvas.d`).

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
