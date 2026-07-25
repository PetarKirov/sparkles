/++
`sparkles:tui` — a full-screen, interactive terminal-UI library.

The rendering core is a $(B 2-D cell-grid with a compact packed cell), chosen by
the [render-cost benchmark](../../../../../docs/specs/tui/render-bench-baseline.md)
under `libs/tui/bench/render/` (line-diff vs cell-grid, decided by measurement).
Paint a frame into a $(REF Grid, sparkles,tui,cell) and hand it to a
$(REF Screen, sparkles,tui,render): only the cells that changed since the last
frame are emitted.

$(B Shipped:) the render core ($(MREF sparkles,tui,cell) + $(MREF sparkles,tui,render)).
The backend/lifecycle, input, event loop, layout, and widget layers are being
built out on top of it (see `docs/specs/tui/`).
+/
module sparkles.tui;

public import sparkles.tui.cell;
public import sparkles.tui.render;
public import sparkles.tui.terminal;
