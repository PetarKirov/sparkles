/++
`sparkles:tui` — a full-screen, interactive terminal-UI library.

The rendering core is a $(B 2-D cell-grid with a compact packed cell), chosen by
the [render-cost benchmark](../../../../../docs/specs/tui/render-bench-baseline.md)
under `libs/tui/bench/render/` (line-diff vs cell-grid, decided by measurement).
Paint a frame into a $(REF Grid, sparkles,tui,cell) and hand it to a
$(REF Screen, sparkles,tui,render): only the cells that changed since the last
frame are emitted.

Around that core: the terminal backend and its restore-on-exit lifecycle
($(MREF sparkles,tui,terminal)), input decoding into `sparkles:input`'s events
($(MREF sparkles,tui,input)), an app-owned event loop ($(MREF sparkles,tui,app)),
inline images over kitty and sixel ($(MREF sparkles,tui,images),
$(MREF sparkles,tui,sixel)), and the cell geometry vocabulary
($(MREF sparkles,tui,geometry)). Layout and widgets are not here: they belong
to `sparkles:ui`, which paints into a `Grid` through `sparkles:ui-tui` (see
`docs/specs/tui/`).
+/
module sparkles.tui;

public import sparkles.tui.cell;
public import sparkles.tui.render;
public import sparkles.tui.images;
public import sparkles.tui.sixel;
public import sparkles.tui.terminal;
public import sparkles.tui.input;
public import sparkles.tui.app;

// The terminal-cell size / position vocabulary the API speaks (a `Terminal.size`,
// an `Event.mouse`, a `runApp` paint callback) — re-exported so consumers get it
// with the library.
public import sparkles.tui.geometry;
