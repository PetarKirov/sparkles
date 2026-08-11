/**
$(MREF sparkles,ui) — a canvas-first, three-level UI toolkit (state machines /
layout / widgets) for rendering the same view across the raylib GUI, the
terminal, and static HTML. The pipeline is `view() → layout() →
buildDisplayList() → paint(canvas)`; every stage before `paint` is `@safe pure`
and testable against a $(REF RecordingCanvas, sparkles,ui,canvas) with no GL.

The core depends only on `sparkles:base` (whose color/style types it reuses — it
adds no color type of its own) and `sparkles:math` (whose numeric `Vector` its
geometry specializes into `Point`/`Size`, the way `TermSize`/`TermPosition`
specialize it for the terminal); concrete canvas backends are adapters that
depend on $(D sparkles:ui), never the reverse. See
`docs/specs/hue/ui-architecture.md`.
*/
module sparkles.ui;

public import sparkles.ui.geometry;
public import sparkles.ui.style;
public import sparkles.ui.theme;
public import sparkles.ui.themes;
public import sparkles.ui.canvas;
public import sparkles.ui.widget;
public import sparkles.ui.wrap;
public import sparkles.ui.layout;
public import sparkles.ui.tracks;
public import sparkles.ui.state;
public import sparkles.ui.components.scroll_view;
public import sparkles.ui.components.dock;
public import sparkles.ui.display_list;
public import sparkles.ui.interp.immediate;
public import sparkles.ui.interp.cells;
