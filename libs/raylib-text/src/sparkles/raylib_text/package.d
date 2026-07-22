/**
`sparkles:raylib-text` — a small, app-agnostic raylib text-rendering core:
font-set management with a glyph atlas and fallback selection, and an
attribute-aware draw primitive. Extracted from `apps/terminal` and `hue --gui`
(issue #121 M5) once two callers validated the boundary — the terminal lays a
fixed cell grid from a `ghostty` render state; hue flows styled runs from a
`sparkles:syntax` event stream. Both draw through the same `drawText`.

The library owns layout-independent rendering only: it never sees a cell
coordinate, a `StyledSpan`, or a `GhosttyStyle`. Callers translate their own
attribute vocabulary into the minimal $(LREF TextStyle) and own their layout,
backgrounds, viewport, and event loop. It depends only on `raylib-d` (plus the
native `raylib`), so a syntax consumer and a VT consumer share it without
dragging either's dependencies into the other.

The pure logic (fallback selection, atlas ranges, cell-metric math,
`TextStyle` → draw-op mapping, grapheme encoding, column widths) is unit-tested
directly; the GL-backed rendering is validated by the apps' screenshot goldens.
*/
module sparkles.raylib_text;

public import sparkles.raylib_text.style;
public import sparkles.raylib_text.atlas;
public import sparkles.raylib_text.metrics;
public import sparkles.raylib_text.font;
public import sparkles.raylib_text.font_set;
public import sparkles.raylib_text.draw;
