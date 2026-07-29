/**
`sparkles:ui-tui` — the terminal backend adapter for $(MREF sparkles,ui): a
$(REF isCanvas, sparkles,ui,canvas)-conforming $(REF GridCanvas,
sparkles,ui_tui,grid_canvas) painting the toolkit's display list into a
$(REF Grid, sparkles,tui,cell), which `sparkles:tui`'s retained `Screen`
cell-diffs to a minimal byte stream. Backends adapt to the toolkit, never the
reverse (`TGT6`/`PKG2`).
*/
module sparkles.ui_tui;

public import sparkles.ui_tui.grid_canvas;
