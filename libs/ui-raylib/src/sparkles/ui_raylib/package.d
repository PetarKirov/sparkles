/**
`sparkles:ui-raylib` — the GPU backend adapter for $(MREF sparkles,ui): a
$(REF isCanvas, sparkles,ui,canvas)-conforming $(REF RaylibCanvas,
sparkles,ui_raylib,raylib_canvas) that scales the toolkit's cell-space display
list to pixels over the shared `sparkles:raylib-text` `FontSet`, plus the
$(MREF sparkles,ui_raylib,events) synthesizer that turns raylib's polled input
state into `sparkles:input` events (`INP8`). Backends adapt to the toolkit,
never the reverse (`TGT6`/`PKG2`).
*/
module sparkles.ui_raylib;

public import sparkles.ui_raylib.raylib_canvas;
public import sparkles.ui_raylib.events;
public import sparkles.ui_raylib.scrollbar;
public import sparkles.ui_raylib.window;
