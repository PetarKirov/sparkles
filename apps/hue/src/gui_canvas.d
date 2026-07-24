// `hue --gui` — the raylib adapter for `sparkles:ui`.
//
// `RaylibCanvas` satisfies the `sparkles.ui.canvas.isCanvas` capability concept
// (fillRect / textRun / glyph / line / measure) by folding each primitive into a
// raylib draw call over the shared `FontSet`. It is the GPU backend of the
// `view() -> layout() -> buildDisplayList() -> paint(canvas)` pipeline: the pure
// model emits a cell-space `DrawOp[]`, and this canvas scales cells to pixels.
//
// Cell space -> pixels: a cell `(x, y)` maps to `(originX + x*cellW,
// originY + y*cellH)`. A caller renders a laid-out subtree (positioned from the
// origin) at an arbitrary screen position by setting `originX`/`originY` before
// `paint`. Colors come already-resolved on each `Visual` (fg/bg + alpha), so the
// canvas never consults a palette or theme — it only paints.
//
// Compiled only by the `gui` build configuration (version(HueGui)); inert in the
// terminal / unittest builds (which never link raylib). See gui.d.
module gui_canvas;

version (HueGui):

import raylib;

import sparkles.raylib_text : TextStyle, FontSet, drawText;
import sparkles.base.smallbuffer : SmallBuffer;

import sparkles.ui.canvas : isCanvas, LineStyle;
import sparkles.ui.geometry : Point, Rect, Size;
import sparkles.ui.style : Visual;

import gui_text : columnWidth;

/// A resolved `Visual`'s foreground as a raylib `Color` (with its alpha).
Color rlFg(in Visual v) pure nothrow @nogc @trusted
    => Color(v.fg.r, v.fg.g, v.fg.b, v.fgAlpha);

/// A resolved `Visual`'s background as a raylib `Color` (with its alpha).
Color rlBg(in Visual v) pure nothrow @nogc @trusted
    => Color(v.bg.r, v.bg.g, v.bg.b, v.bgAlpha);

/**
The raylib canvas: a `sparkles:ui` drawing backend over a `FontSet`. Cell
coordinates are scaled to pixels through `cellW`/`cellH` and offset by
`originX`/`originY` (move the origin between `paint` calls to place laid-out
subtrees anywhere on screen). Every method is `@system` (raylib is), so the
`sparkles:ui` interpreter instantiated against it infers `@system` — exactly the
attribute-by-canvas design the concept exists for.
*/
struct RaylibCanvas
{
    FontSet* fonts;            /// the glyph atlas + metrics (borrowed)
    SmallBuffer!(char, 4096)* buf; /// scratch for NUL-terminated draw strings
    int cellW;                 /// one cell's pixel width
    int cellH;                 /// one cell's pixel height
    float originX = 0;         /// pixel x of cell column 0
    float originY = 0;         /// pixel y of cell row 0

    private float px(int cx) const @safe pure nothrow @nogc => originX + cx * cellW;
    private float py(int cy) const @safe pure nothrow @nogc => originY + cy * cellH;

    /// Fills `r` with `v.bg` (no-op when the visual has no background).
    void fillRect(in Rect r, in Visual v) @system
    {
        if (!v.hasBg)
            return;
        DrawRectangle(cast(int) px(r.x), cast(int) py(r.y),
            r.w * cellW, r.h * cellH, rlBg(v));
    }

    /// Draws `text` at `at` in `v.fg`.
    void textRun(in Point at, scope const(char)[] text, in Visual v) @system
    {
        drawText(*fonts, cstr(text), px(at.x), py(at.y), TextStyle(0), rlFg(v));
    }

    /// Draws a single glyph `g` at `at` in `v.fg`.
    void glyph(in Point at, dchar g, in Visual v) @system
    {
        import std.utf : encode;

        char[4] enc;
        const n = encode(enc, g);
        drawText(*fonts, cstr(enc[0 .. n]), px(at.x), py(at.y), TextStyle(0), rlFg(v));
    }

    /// Strokes `from` -> `to` in `v.fg`. A `wavy` line is the twoslash error
    /// squiggle along the cell's baseline; a `solid` line is a 1px rule.
    void line(in Point from, in Point to, in Visual v, LineStyle style) @system
    {
        const y0 = cast(int) py(from.y);
        const x0 = cast(int) px(from.x);
        const x1 = cast(int) px(to.x);
        const w = x1 - x0;
        if (style == LineStyle.wavy)
        {
            // Alternating 2px segments, one row above the cell bottom.
            const baseY = y0 + cellH - 2;
            for (int i = 0; i < w; i += 4)
            {
                const seg = i + 2 <= w ? 2 : w - i;
                DrawRectangle(x0 + i, baseY + (i / 2 % 2), seg, 1, rlFg(v));
            }
        }
        else
            DrawRectangle(x0, y0, w, 1, rlFg(v));
    }

    /// The cell extent of a text run (height 1). The width authority is
    /// `columnWidth`, the same one `drawText` advances by.
    Size measure(scope const(char)[] text) @system
        => Size(cast(int) columnWidth(text), 1);

    /// NUL-terminates `s` in the scratch buffer for a raylib string draw.
    private const(char)[] cstr(scope const(char)[] s) @system
    {
        buf.clear();
        *buf ~= s;
        *buf ~= '\0';
        return (*buf)[0 .. $ - 1];
    }
}

// The raylib canvas must satisfy the ui capability concept, or the shared
// `paint` interpreter won't accept it.
static assert(isCanvas!RaylibCanvas);
