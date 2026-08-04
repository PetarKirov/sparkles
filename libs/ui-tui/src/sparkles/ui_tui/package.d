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

/*
`sparkles.ui_tui.session` is deliberately NOT re-exported here.

The canvas is portable — it paints cells into a `Grid` and needs no terminal.
The session is not: it reaches `sparkles.tui.terminal`, whose `core.sys.posix.termios`
imports (`tcgetattr`/`tcsetattr`) do not resolve under the Android NDK's bionic
druntime. Re-exporting it from the package module put termios in the import
closure of every consumer of `paintGrid` — including hue's `tui.d`/`explorer.d`/
`twoslash_tui.d`, which ARE compiled for Android even though its `runWorkspace`
is version-gated out. That broke the APK build and nothing else.

So a caller that wants a terminal names the module: `import sparkles.ui_tui.session`.
This mirrors how consumers already reach `sparkles.tui.cell` rather than the
`sparkles.tui` package module, for the same reason.
*/
