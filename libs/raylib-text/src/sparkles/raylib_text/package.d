/**
`sparkles:raylib-text` — a small, app-agnostic raylib text-rendering core:
font-set management with a glyph atlas and fallback selection, and an
attribute-aware draw primitive. Extracted from `apps/terminal` and `hue --gui`
(issue #121 M5) once two callers validated the boundary — the terminal lays a
fixed cell grid from a `ghostty` render state; hue flows styled runs from a
`sparkles:syntax` event stream. Terminal clusters use `FontSet.drawCluster`;
fixed-column styled runs use `drawText`.

The library owns layout-independent rendering only: it never sees a cell
coordinate, a `StyledSpan`, or a `GhosttyStyle`. Callers translate their own
attribute vocabulary into the minimal $(LREF TextStyle) and own their layout,
backgrounds, viewport, and event loop. Native dependencies are raylib,
FreeType, and HarfBuzz; no syntax or VT dependency leaks into the renderer.
Cached cluster textures preserve combining placement, variation selectors,
regional flags and ZWJ emoji, including embedded color strikes. Drawing only
queues cache misses; call `FontSet.flushPending` after `EndDrawing` and repaint
when it returns true. Reloading or unloading the FontSet releases its shaped
textures and native faces together with the raylib atlases.

The pure logic (fallback selection, atlas ranges, cell-metric math,
`TextStyle` → draw-op mapping, grapheme encoding, column widths) is unit-tested
directly; the GL-backed rendering is validated by the apps' screenshot goldens.
*/
module sparkles.raylib_text;

public import sparkles.raylib_text.style;
public import sparkles.raylib_text.atlas;
public import sparkles.raylib_text.metrics;
public import sparkles.raylib_text.metrics_dpi;
public import sparkles.raylib_text.font;
public import sparkles.raylib_text.font_discovery;
// macOS only: the module body is behind `version (OSX)`, so this is an empty
// import everywhere else and costs a consumer nothing.
public import sparkles.raylib_text.font_coretext;
public import sparkles.raylib_text.font_set;
public import sparkles.raylib_text.draw;
public import sparkles.raylib_text.ui_font;
public import sparkles.raylib_text.box;
