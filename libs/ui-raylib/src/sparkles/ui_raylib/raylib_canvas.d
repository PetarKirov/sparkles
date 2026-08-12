// The raylib adapter for `sparkles:ui` (`TGT6`).
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
module sparkles.ui_raylib.raylib_canvas;

import raylib;

import sparkles.raylib_text : TextStyle, FontSet, drawText;
import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.term_style : TextAttr, UnderlineStyle;

import sparkles.ui.canvas : DrawOp, isCanvas, LineStyle, RuleEdge;
import sparkles.ui.geometry : cellsOf, Insets, Point, Rect, Size;
import sparkles.base.term_color : RgbColor;
import sparkles.ui.state : scrollbarThumb;
import sparkles.ui.style : BorderStyle, Visual;

/// The idle scrollbar rail thickness for a cell extent, in device pixels.
int railIdlePx(int cellExtent) @safe pure nothrow @nogc
{
    const third = cellExtent / 3;
    return third < 2 ? 2 : third;
}

/// The fully-expanded scrollbar rail thickness: exactly 1.5 cells, including
/// odd cell sizes (integer multiply before divide is the normative rounding).
int railExpandedPx(int cellExtent) @safe pure nothrow @nogc
    => cellExtent * 3 / 2;

/// The pixel backend's minimum grabbable scrollbar-handle length.
enum int scrollbarMinExtentPx = 24;

/// Pure, window-free resolved pixel geometry for one semantic scrollbar op.
struct ScrollbarRail
{
    Rect track;
    Rect thumb;
    bool live;
}

/**
Resolves a semantic scrollbar operation into pixel track/thumb geometry. The
op keeps content units and an expansion percentage; this backend alone chooses
pixel rail thickness and the 24px minimum grabbable thumb.
*/
ScrollbarRail scrollbarRail(in DrawOp op, int cellW, int cellH,
    int originX = 0, int originY = 0,
    int minExtent = scrollbarMinExtentPx)
    @safe pure nothrow @nogc
{
    ScrollbarRail r;
    if (op.barContent <= op.barViewport || op.barContent <= 0)
        return r;

    bool vertical;
    final switch (op.ruleEdge) with (RuleEdge)
    {
        case left: case right: case centerX:
            vertical = true;
            break;
        case top: case bottom: case centerY:
            vertical = false;
            break;
    }

    const x = originX + op.rect.x * cellW;
    const y = originY + op.rect.y * cellH;
    const w = op.rect.width * cellW;
    const h = op.rect.height * cellH;
    const cellExtent = vertical ? cellW : cellH;
    const idle = railIdlePx(cellExtent);
    const expanded = railExpandedPx(cellExtent);
    const thickness = idle
        + (expanded - idle) * cast(int) op.expandPercent / 100;

    final switch (op.ruleEdge) with (RuleEdge)
    {
        case left:
            r.track = Rect(x, y, thickness, h);
            break;
        case right:
            r.track = Rect(x + w - thickness, y, thickness, h);
            break;
        case centerX:
            r.track = Rect(x + w / 2 - thickness / 2, y, thickness, h);
            break;
        case top:
            r.track = Rect(x, y, w, thickness);
            break;
        case bottom:
            r.track = Rect(x, y + h - thickness, w, thickness);
            break;
        case centerY:
            r.track = Rect(x, y + h / 2 - thickness / 2, w, thickness);
            break;
    }

    const track = vertical ? h : w;
    if (track <= 0 || thickness <= 0)
        return ScrollbarRail.init;
    const thumb = scrollbarThumb(op.barContent, op.barViewport,
        op.barOffset, track, minExtent);
    r.thumb = vertical
        ? Rect(r.track.x, y + thumb.start, thickness, thumb.extent)
        : Rect(x + thumb.start, r.track.y, thumb.extent, thickness);
    r.live = true;
    return r;
}

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

    /// The optional clipping pair of the canvas concept: a GL scissor per
    /// pushed rect (cell coordinates → pixels), stacked so nested viewports
    /// restore the enclosing one — widget content never bleeds past its rect.
    private Rect[] clips;

    void pushClip(in Rect r) scope @system
    {
        clips ~= r;
        applyScissor();
    }

    /// ditto
    void popClip() scope @system
    {
        if (clips.length)
            clips = clips[0 .. $ - 1];
        applyScissor();
    }

    private void applyScissor() scope @system
    {
        EndScissorMode();
        if (!clips.length)
            return;
        // The display list pushes pre-intersected effective rects, so the top
        // of the stack is the active region — but an axis-only viewport
        // (`clipX` without `clipY`) leaves the other axis UNBOUNDED (huge
        // sentinels), so clamp to the window before pixel math or the
        // scissor arithmetic overflows.
        const r = clips[$ - 1];
        const sw = cast(float) GetScreenWidth();
        const sh = cast(float) GetScreenHeight();
        static float cl(float v, float lo, float hi) pure nothrow @nogc @safe
            => v < lo ? lo : (v > hi ? hi : v);
        // Long math throughout: the sentinel cell coords overflow `int` when
        // multiplied by the cell size (px()/py() are fine for real cells).
        const x0 = cl(originX + cast(long) r.x * cast(float) cellW, 0, sw);
        const y0 = cl(originY + cast(long) r.y * cast(float) cellH, 0, sh);
        const x1 = cl(originX + (cast(long) r.x + r.width) * cast(float) cellW, 0, sw);
        const y1 = cl(originY + (cast(long) r.y + r.height) * cast(float) cellH, 0, sh);
        if (x1 <= x0 || y1 <= y0)
            BeginScissorMode(0, 0, 0, 0); // fully clipped away
        else
            BeginScissorMode(cast(int) x0, cast(int) y0,
                cast(int)(x1 - x0), cast(int)(y1 - y0));

    }

    /**
    A flat fill in $(B pixels), for chrome that is genuinely not cell-aligned
    (`UIA7`).

    The rest of this canvas speaks cells, and that is the right unit for
    anything the layout engine positions. Some application chrome is not:
    a one-pixel pane divider, a hairline under a header bar, a band whose
    height is `cellH - 1`. Quantising those to cells would move them.

    So this exists to let an application stop naming raylib without changing
    what it paints — the `UIA7` boundary, not the `UIA2` one. Chrome that CAN
    be a widget should be: it then gets layout, hit-testing and theming for
    free, and this method is not involved. Treat a growing number of callers
    as a signal that a widget is missing.

    Coordinates are absolute window pixels; `originX`/`originY` do not apply,
    because a caller reaching for pixels already knows where it is.
    */
    void fillPixels(int x, int y, int w, int h, RgbColor c, ubyte a = 0xFF) @system
    {
        if (w <= 0 || h <= 0)
            return;
        DrawRectangle(x, y, w, h, Color(c.r, c.g, c.b, a));
    }

    /// Paints a box: drop shadow (behind), background fill (rounded when
    /// `borderRadius`), border (per-side, dotted/solid), and a popup arrow —
    /// each gated on the resolved `Visual`. A plain filled cell is the common
    /// fast path (no chrome ⇒ one `DrawRectangle`).
    void fillRect(in Rect r, in Visual v) @system
    {
        const x = px(r.x), y = py(r.y);
        const w = cast(float)(r.width * cellW), h = cast(float)(r.height * cellH);

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
                DrawRectangle(cast(int) x, cast(int) y, r.width * cellW, r.height * cellH, rlBg(v));
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
    /**
    A sub-cell hairline along an edge of `rect` (`UIA2`).

    The optional canvas primitive a pixel target can honour exactly: the
    toolkit names an edge, and this draws the thinnest rule the display
    has there — one device pixel — instead of quantising to a whole cell,
    which for a pane divider or a header underline is the difference
    between chrome and a stripe. Canvases without this get the cell-aligned
    line along the same edge.
    */
    void rule(in Rect rect, RuleEdge edge, in Visual v) @system
    {
        const x0 = cast(int) px(rect.x);
        const y0 = cast(int) py(rect.y);
        const w = cast(int)(rect.width * cellW);
        const h = cast(int)(rect.height * cellH);
        const c = v.fg;
        const a = v.fgAlpha;
        final switch (edge) with (RuleEdge)
        {
            case top:     fillPixels(x0, y0, w, 1, c, a); break;
            case bottom:  fillPixels(x0, y0 + h - 1, w, 1, c, a); break;
            case left:    fillPixels(x0, y0, 1, h, c, a); break;
            case right:   fillPixels(x0 + w - 1, y0, 1, h, c, a); break;
            case centerX: fillPixels(x0 + w / 2, y0, 1, h, c, a); break;
            case centerY: fillPixels(x0, y0 + h / 2, w, 1, c, a); break;
        }
    }

    /// Draws the semantic scrollbar op with the backend's continuous px rail.
    void scrollbar(in DrawOp op) @system
    {
        const r = scrollbarRail(op, cellW, cellH,
            cast(int) originX, cast(int) originY);
        if (!r.live)
            return;
        if (op.barTrackLit)
            DrawRectangle(r.track.x, r.track.y, r.track.width, r.track.height,
                Color(op.barTrackColor.r, op.barTrackColor.g,
                    op.barTrackColor.b, 255));
        DrawRectangle(r.thumb.x, r.thumb.y, r.thumb.width, r.thumb.height,
            rlFg(op.visual));
    }

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
        // Border widths are CELL-space weights; stroke thickness scales by
        // the same unit the procedural box glyphs use for their arms
        // (`drawBox`'s light stroke), so "1 wide" here matches a `│` and
        // "2 wide" a `┃` at any cell size. A solid vertical side centers in
        // its border COLUMN, where the cell backends put their `│` — and
        // where a glyph-composed corner row's `╭`/`╰` stems are, so the
        // fence chrome's edges meet (the quote bar gains the same parity).
        // Dotted/dashed accents straddle the rect edge instead.
        const md = cellW < cellH ? cellW : cellH;
        const unit = md / 14 < 1 ? 1.0f : cast(float)(md / 14);
        const inset = b.style == BorderStyle.solid ? cellW / 2.0f : 0;
        // The four rectangles come from `borderEdges`, which is pure and
        // tested. Computing them here is how the vertical pair ended up
        // passing the horizontal argument order — `len` and `thick` swap
        // meaning between the two axes, and a box whose left border drew as
        // a stripe across the box was invisible to every test in the
        // repository.
        foreach (e; borderEdges(x, y, w, h, b.width, unit, inset))
            strokeEdge(e, b.style, c);
    }

    /// Strokes one edge, dashed for a dotted/dashed style, solid otherwise.
    /// Dashes run along the edge's own long axis, whichever that is.
    private void strokeEdge(in BorderEdge e, BorderStyle style, Color c) @system
    {
        if (e.empty)
            return;
        if (style != BorderStyle.dotted && style != BorderStyle.dashed)
            return DrawRectangle(cast(int) e.x, cast(int) e.y,
                cast(int) e.w, cast(int) e.h, c);

        const thick = e.horizontal ? e.h : e.w;
        const len = e.horizontal ? e.w : e.h;
        const dash = style == BorderStyle.dotted ? thick : thick * 3;
        const gap = style == BorderStyle.dotted ? thick : thick * 2;
        for (float p = 0; p < len; p += dash + gap)
        {
            const seg = (p + dash <= len) ? dash : (len - p);
            if (e.horizontal)
                DrawRectangle(cast(int)(e.x + p), cast(int) e.y,
                    cast(int) seg, cast(int) thick, c);
            else
                DrawRectangle(cast(int) e.x, cast(int)(e.y + p),
                    cast(int) thick, cast(int) seg, c);
        }
    }

    /// Draws the popup arrow/tail: a small upward triangle off the box's top edge
    /// at `arrowOffset` cells, filled with the surface color and outlined in the
    /// border color (approximating the CSS 6×6 rotated-square notch).
    private void drawArrow(float boxX, float boxY, in Visual v) @system
    {
        const asz = cellH / 3 < 4 ? 4.0f : cast(float)(cellH / 3);
        const cx = boxX + v.arrowOffset * cellW + cellW * 0.5f;
        const apex = Vector2(cx, boxY - asz);
        const left = Vector2(cx - asz, boxY + 1); // +1: overlap the border so the
        const right = Vector2(cx + asz, boxY + 1); // notch merges into the surface
        // Screen space is y-down, so apex→left→right is the counter-clockwise
        // winding raylib needs (apex→right→left is culled as a back face).
        if (v.hasBg)
            DrawTriangle(apex, left, right, rlBg(v));
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
    /// `cellsOf` — the toolkit's one width authority, the same one-column-per-
    /// codepoint advance `drawText` uses.
    Size measure(scope const(char)[] text) @system
        => Size(cast(int) cellsOf(text), 1);

    /// NUL-terminates `s` in the scratch buffer for a raylib string draw.
    private const(char)[] cstr(scope const(char)[] s) @system
    {
        buf.clear();
        *buf ~= s;
        *buf ~= '\0';
        return (*buf)[0 .. $ - 1];
    }
}

@("uiRaylib.scrollbarRail.metricsAndOddCells")
@safe pure nothrow @nogc
unittest
{
    assert(railIdlePx(5) == 2);
    assert(railIdlePx(21) == 7);
    assert(railExpandedPx(5) == 7);  // not cast(int)(5 * 1.5f) by accident
    assert(railExpandedPx(21) == 31);

    DrawOp op = {
        rect: Rect(2, 1, 10, 20),
        ruleEdge: RuleEdge.right,
        barContent: 400,
        barViewport: 100,
        expandPercent: 0,
    };
    const idle = scrollbarRail(op, 5, 7);
    assert(idle.live && idle.track == Rect(58, 7, 2, 140));
    assert(idle.thumb == Rect(58, 7, 2, 35));

    op.expandPercent = 100;
    const expanded = scrollbarRail(op, 5, 7);
    assert(expanded.track == Rect(53, 7, 7, 140));
    op.expandPercent = 50;
    const middle = scrollbarRail(op, 5, 7);
    assert(middle.track.width >= idle.track.width);
    assert(middle.track.width <= expanded.track.width);

    op.barOffset = 300;
    const bottom = scrollbarRail(op, 5, 7);
    assert(bottom.thumb.y + bottom.thumb.height
        == bottom.track.y + bottom.track.height);

    op.ruleEdge = RuleEdge.bottom;
    op.rect = Rect(1, 2, 20, 3);
    op.barContent = 200;
    op.barViewport = 100;
    op.barOffset = 100;
    op.expandPercent = 100;
    const horizontal = scrollbarRail(op, 5, 7);
    assert(horizontal.track.height == railExpandedPx(7));
    assert(horizontal.thumb.x + horizontal.thumb.width
        == horizontal.track.x + horizontal.track.width);
}

// The raylib canvas must satisfy the ui capability concept, or the shared
// `paint` interpreter won't accept it.
static assert(isCanvas!RaylibCanvas);

// ---------------------------------------------------------------------------
// Border geometry — pure, so it is testable without a GL context.
// ---------------------------------------------------------------------------

/// One stroked edge of a box border, as a device-pixel rectangle.
struct BorderEdge
{
    float x; ///
    float y; ///
    float w; ///
    float h; ///

@safe pure nothrow @nogc:

    /// `true` iff the edge covers no pixels — a side of zero width.
    bool empty() const => w <= 0 || h <= 0;

    /// `true` for the top and bottom edges: the ones whose long axis is x.
    /// Dashes run along the long axis, so this is what tells them which way.
    bool horizontal() const => w >= h;
}

/**
The four edges of a square border, in device pixels.

$(B Extracted because it was wrong.) Inline, the two axes' rectangles were
written by hand from a `(length, thickness)` pair whose meaning swaps between
them — and the vertical pair was written in the horizontal order, so a box's
left border drew as a bar $(I across) the box and its right border as a bar
poking out to the right of it. Every backend-neutral test passed: the display
list was correct, the cell grid drew the box correctly, and the defect existed
only inside a `@system` function that needs a window to run.

Pure arithmetic in, four rectangles out, and the arithmetic has tests.

`unit` scales a side's cell-space weight into pixels of stroke thickness.
`inset` centres a vertical stroke that many pixels into its border column —
half a cell for a solid border, so the stroke lands where the cell backends
put their `│` and a glyph-composed corner's stem meets it; zero makes a
vertical stroke straddle the rect edge (the dotted/dashed accents).
*/
BorderEdge[4] borderEdges(float x, float y, float w, float h, in Insets width,
    float unit = 1, float inset = 0) @safe pure nothrow @nogc
{
    const l = width.left * unit;
    const r = width.right * unit;
    return [
        BorderEdge(x, y, w, width.top * unit),                            // top
        BorderEdge(x, y + h - width.bottom * unit, w,
            width.bottom * unit),                                         // bottom
        BorderEdge(width.left ? x + inset - l / 2 : x, y, l, h),          // left
        BorderEdge(width.right ? x + w - inset - r / 2 : x + w - r, y,
            r, h),                                                        // right
    ];
}

@("ui_raylib.raylib_canvas.borderEdgesStayNearTheBoxTheyBorder")
@safe pure nothrow @nogc
unittest
{
    // The bug, stated as a property: an edge never extends a box-length past
    // the box. The old vertical pair drew `h` pixels WIDE, so the right edge
    // started at the box's right and ran another box-height past it — which is
    // what a reader saw as stray horizontal lines beside every square-cornered
    // panel. (A vertical stroke MAY straddle the rect edge by half its own
    // thickness — that is the inset-0 accent geometry — so the bound is the
    // thickness, not zero.)
    enum x = 100.0f, y = 40.0f, w = 130.0f, h = 78.0f;
    foreach (e; borderEdges(x, y, w, h, Insets.all(1)))
    {
        assert(e.x >= x - e.w && e.x + e.w <= x + w + e.w,
            "an edge escaped sideways");
        assert(e.y >= y && e.y + e.h <= y + h, "an edge escaped vertically");
    }
}

@("ui_raylib.raylib_canvas.borderEdgesScaleAndCentreInTheirColumn")
@safe pure nothrow @nogc
unittest
{
    // The GPU border's two cell-parity rules, as arithmetic: `unit` scales a
    // side's cell weight into stroke pixels, and a solid vertical stroke
    // centres `inset` pixels into its border column — where the cell
    // backends put their `│` and where a glyph-composed corner's stem is.
    enum x = 0.0f, y = 0.0f, w = 40.0f, h = 20.0f;
    const e = borderEdges(x, y, w, h, Insets.all(1), unit: 2, inset: 5);

    assert(e[0].h == 2 && e[1].h == 2, "horizontal thickness scales by unit");
    assert(e[2].w == 2 && e[3].w == 2, "vertical thickness scales by unit");
    assert(e[2].x + e[2].w / 2 == x + 5, "left centres in its column");
    assert(e[3].x + e[3].w / 2 == x + w - 5, "right centres in its column");

    // Inset 0 — the dotted/dashed accents — straddles the rect edge instead.
    const a = borderEdges(x, y, w, h, Insets.all(1), unit: 2);
    assert(a[2].x + a[2].w / 2 == x && a[3].x + a[3].w / 2 == x + w);
}

@("ui_raylib.raylib_canvas.borderEdgesRunAlongTheirOwnAxis")
@safe pure nothrow @nogc
unittest
{
    enum x = 0.0f, y = 0.0f, w = 40.0f, h = 20.0f;
    const e = borderEdges(x, y, w, h, Insets(1, 2, 3, 4)); // top right bottom left

    // Horizontal edges span the width and are as thick as their own side.
    assert(e[0] == BorderEdge(0, 0, 40, 1), "top");
    assert(e[1] == BorderEdge(0, 17, 40, 3), "bottom");
    // Vertical edges span the HEIGHT and are as thick as their own side. This
    // is the assertion the swap failed: it produced (0, 0, 20, 4) — a bar four
    // pixels tall lying across the top of the box. (At inset 0 a vertical
    // stroke centres ON the rect edge, hence the half-thickness x shift.)
    assert(e[2] == BorderEdge(-2, 0, 4, 20), "left");
    assert(e[3] == BorderEdge(39, 0, 2, 20), "right");

    assert(e[0].horizontal && e[1].horizontal);
    assert(!e[2].horizontal && !e[3].horizontal);
}

@("ui_raylib.raylib_canvas.borderEdgesDropAbsentSides")
@safe pure nothrow @nogc
unittest
{
    // A bottom-only rule and a left accent bar are both real decorations
    // (`hoverUnderline`, the error accent). The sides they do not ask for must
    // draw nothing rather than a zero-thickness smear.
    const bottom = borderEdges(0, 0, 40, 20, Insets(0, 0, 1, 0));
    assert(bottom[0].empty && bottom[2].empty && bottom[3].empty);
    assert(!bottom[1].empty && bottom[1].horizontal);

    const accent = borderEdges(0, 0, 40, 20, Insets(0, 0, 0, 3));
    assert(accent[0].empty && accent[1].empty && accent[3].empty);
    assert(!accent[2].empty && !accent[2].horizontal,
        "a left accent is a vertical bar, not a horizontal one");
}

@("ui_raylib.raylib_canvas.borderEdgesOfADegenerateBox")
@safe pure nothrow @nogc
unittest
{
    // A one-pixel-tall box: no edge strays past its own thickness, and the
    // verticals are not mistaken for horizontals just because they are short.
    foreach (e; borderEdges(0, 0, 10, 1, Insets.all(1)))
    {
        assert(e.x >= -e.w && e.x + e.w <= 10 + e.w);
        assert(e.y >= 0 && e.y + e.h <= 1);
    }

    // Borders wider than the box do not invert it into negative geometry.
    foreach (e; borderEdges(0, 0, 2, 2, Insets.all(5)))
        assert(!e.empty || e.w <= 0 || e.h <= 0);
}
