/**
$(MREF sparkles,ui) — a canvas-first, three-level UI toolkit (state machines /
layout / widgets) for rendering the same view across the raylib GUI, the
terminal, and static HTML. The pipeline is `view() → layout() →
buildDisplayList() → paint(canvas)`; every stage before `paint` is `@safe pure`
and testable against a $(REF RecordingCanvas, sparkles,ui,canvas) with no GL.

The core depends only on `sparkles:base` and `sparkles:syntax` (it reuses their
color/style types and adds no color type of its own); concrete canvas backends
are adapters that depend on $(D sparkles:ui), never the reverse. See
`docs/specs/hue/ui-architecture.md`.
*/
module sparkles.ui;

public import sparkles.ui.geometry;
public import sparkles.ui.style;
public import sparkles.ui.canvas;
public import sparkles.ui.widget;
public import sparkles.ui.layout;
public import sparkles.ui.state;
public import sparkles.ui.display_list;
public import sparkles.ui.interp.immediate;
public import sparkles.ui.interp.cells;
