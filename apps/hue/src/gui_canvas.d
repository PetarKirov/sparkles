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
import sparkles.base.term_style : TextAttr, UnderlineStyle;

import sparkles.ui.canvas : isCanvas, LineStyle;
import sparkles.ui.geometry : Insets, Point, Rect, Size;
import sparkles.ui.style : BorderStyle, Visual;

import gui_text : columnWidth;

/// A resolved `Visual`'s foreground as a raylib `Color` (with its alpha).
Color rlFg(in Visual v) pure nothrow @nogc @trusted
    => Color(v.fg.r, v.fg.g, v.fg.b, v.fgAlpha);

/// A resolved `Visual`'s background as a raylib `Color` (with its alpha).
Color rlBg(in Visual v) pure nothrow @nogc @trusted
    => Color(v.bg.r, v.bg.g, v.bg.b, v.bgAlpha);

/// The resolved box border as a raylib `Color` (edge color + fade alpha).
private Color rlBorder(in Visual v) pure nothrow @nogc @trusted
    => Color(v.border.color.r, v.border.color.g, v.border.color.b, v.border.alpha);

/// Maps a `Visual`'s packed `TextAttr` bits + underline into the raylib-text
/// `TextStyle` (real bold/italic faces, strike, underline). `FontRole`/`fontScale`
/// are HTML-honored; the fixed-size cell grid keeps mono at 1em (documented).
TextStyle rlTextStyle(in Visual v) pure nothrow @nogc @safe
{
    TextStyle t;
    if (v.styleBits & TextAttr.bold.bits)
        t.bits |= TextStyle.bold;
    if (v.styleBits & TextAttr.italic.bits)
        t.bits |= TextStyle.italic;
    if (v.styleBits & TextAttr.strikethrough.bits)
        t.bits |= TextStyle.strikethrough;
    if (v.underline != UnderlineStyle.none)
        t.bits |= TextStyle.underline;
    return t;
}

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

    /// Paints a box: drop shadow (behind), background fill (rounded when
    /// `borderRadius`), border (per-side, dotted/solid), and a popup arrow —
    /// each gated on the resolved `Visual`. A plain filled cell is the common
    /// fast path (no chrome ⇒ one `DrawRectangle`).
    void fillRect(in Rect r, in Visual v) @system
    {
        const x = px(r.x), y = py(r.y);
        const w = cast(float)(r.w * cellW), h = cast(float)(r.h * cellH);

        // Drop shadow first, behind the surface: an offset translucent rect.
        if (v.shadow.any)
        {
            const s = v.shadow;
            const sc = Color(s.color.r, s.color.g, s.color.b, s.alpha);
            const sr = Rectangle(x + s.dx - s.blur / 2.0f, y + s.dy,
                w + s.blur, h + s.blur / 2.0f);
            if (v.borderRadius > 0)
                DrawRectangleRounded(sr, roundnessOf(v.borderRadius, sr.width, sr.height), 8, sc);
            else
                DrawRectangleRec(sr, sc);
        }

        // Background fill.
        if (v.hasBg)
        {
            if (v.borderRadius > 0)
                DrawRectangleRounded(Rectangle(x, y, w, h),
                    roundnessOf(v.borderRadius, w, h), 8, rlBg(v));
            else
                DrawRectangle(cast(int) x, cast(int) y, r.w * cellW, r.h * cellH, rlBg(v));
        }

        // Border and popup arrow.
        if (v.border.any)
            drawBorder(x, y, w, h, v);
        if (v.arrow)
            drawArrow(x, y, v);
    }

    /// Draws `text` at `at`, selecting the real bold/italic/strike/underline face
    /// from the resolved `Visual`.
    void textRun(in Point at, scope const(char)[] text, in Visual v) @system
    {
        drawText(*fonts, cstr(text), px(at.x), py(at.y), rlTextStyle(v), rlFg(v));
    }

    /// Draws a single glyph `g` at `at` in `v.fg` (with its face).
    void glyph(in Point at, dchar g, in Visual v) @system
    {
        import std.utf : encode;

        char[4] enc;
        const n = encode(enc, g);
        drawText(*fonts, cstr(enc[0 .. n]), px(at.x), py(at.y), rlTextStyle(v), rlFg(v));
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

    /// raylib's rounded-rect `roundness` (0..1 of the shorter half-side) for a
    /// px corner radius on a `w × h` box.
    private static float roundnessOf(int radiusPx, float w, float h) pure nothrow @nogc @safe
    {
        const half = (w < h ? w : h) / 2.0f;
        if (half <= 0)
            return 0;
        const rr = radiusPx / half;
        return rr > 1 ? 1 : rr;
    }

    /// Strokes the box border. A rounded box (`borderRadius > 0`) gets a uniform
    /// rounded outline; a square box strokes each present side, honoring the
    /// dotted/dashed style (the `.twoslash-hover` bottom underline is dotted).
    private void drawBorder(float x, float y, float w, float h, in Visual v) @system
    {
        const b = v.border;
        const c = rlBorder(v);
        if (v.borderRadius > 0)
        {
            const thick = maxSide(b.width);
            DrawRectangleRoundedLinesEx(Rectangle(x, y, w, h),
                roundnessOf(v.borderRadius, w, h), 8, thick, c);
            return;
        }
        strokeEdge(x, y, w, b.width.top, true, b.style, c);                    // top
        strokeEdge(x, y + h - b.width.bottom, w, b.width.bottom, true, b.style, c); // bottom
        strokeEdge(x, y, b.width.left, h, false, b.style, c);                  // left
        strokeEdge(x + w - b.width.right, y, b.width.right, h, false, b.style, c);  // right
    }

    /// Strokes one horizontal/vertical edge of thickness `thick`, dashed for a
    /// dotted/dashed style, solid otherwise.
    private void strokeEdge(float x, float y, float len, float thick, bool horizontal,
        BorderStyle style, Color c) @system
    {
        if (thick <= 0 || len <= 0)
            return;
        if (style == BorderStyle.dotted || style == BorderStyle.dashed)
        {
            const dash = style == BorderStyle.dotted ? thick : thick * 3;
            const gap = style == BorderStyle.dotted ? thick : thick * 2;
            for (float p = 0; p < len; p += dash + gap)
            {
                const seg = (p + dash <= len) ? dash : (len - p);
                if (horizontal)
                    DrawRectangle(cast(int)(x + p), cast(int) y, cast(int) seg, cast(int) thick, c);
                else
                    DrawRectangle(cast(int) x, cast(int)(y + p), cast(int) thick, cast(int) seg, c);
            }
        }
        else if (horizontal)
            DrawRectangle(cast(int) x, cast(int) y, cast(int) len, cast(int) thick, c);
        else
            DrawRectangle(cast(int) x, cast(int) y, cast(int) thick, cast(int) len, c);
    }

    /// Draws the popup arrow/tail: a small upward triangle off the box's top edge
    /// at `arrowOffset` cells, filled with the surface color and outlined in the
    /// border color (approximating the CSS 6×6 rotated-square notch).
    private void drawArrow(float boxX, float boxY, in Visual v) @system
    {
        const asz = cellH / 3 < 4 ? 4.0f : cast(float)(cellH / 3);
        const cx = boxX + v.arrowOffset * cellW + cellW * 0.5f;
        const apex = Vector2(cx, boxY - asz);
        const left = Vector2(cx - asz, boxY);
        const right = Vector2(cx + asz, boxY);
        if (v.hasBg)
            DrawTriangle(apex, right, left, rlBg(v)); // CCW (screen y-down)
        if (v.border.any)
        {
            const c = rlBorder(v);
            DrawLineEx(left, apex, 1, c);
            DrawLineEx(apex, right, 1, c);
        }
    }

    /// The greatest of an `Insets`' four sides (border outline thickness).
    private static float maxSide(in Insets i) pure nothrow @nogc @safe
    {
        int m = i.top;
        if (i.right > m)
            m = i.right;
        if (i.bottom > m)
            m = i.bottom;
        if (i.left > m)
            m = i.left;
        return m <= 0 ? 1 : cast(float) m;
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
