// `hue --twoslash` (terminal) — the sparkles:tui adapter for `sparkles:ui`.
//
// `GridCanvas` satisfies the `sparkles.ui.canvas.isCanvas` capability concept by
// painting the ui primitives into a `sparkles.tui.Grid`, so the same
// `view() -> layout() -> buildDisplayList() -> paint(canvas)` pipeline that
// drives the raylib GUI (`gui_canvas.RaylibCanvas`) also drives the terminal —
// and `sparkles:tui`'s retained `Screen` diffs the grid to a minimal byte stream.
//
// Composites, so a twoslash popup renders correctly over the code:
//   * a translucent `fillRect` (the highlight tint) blends over the cell's
//     existing background rather than replacing it;
//   * `textRun`/`glyph` set only the glyph + foreground and PRESERVE the cell's
//     background (so a popup's surface fill survives under its text);
//   * a `wavy` `line` becomes an SGR-58 undercurl in its own color — the error
//     squiggle over syntax-colored code (needs the shaped `CellStyle`).
//
// Uses only `sparkles.tui.cell` (a cross-platform cell grid; the raw-mode loop is
// Posix-gated elsewhere in the lib), so this module and its tests are GL-free and
// terminal-free — `dub test :hue` exercises it against a real `Grid`.
module tui_canvas;

import sparkles.tui.cell : CellStyle, codepointCellWidth, Grid;

import sparkles.ui.canvas : DrawOp, isCanvas, LineStyle, OpKind;
import sparkles.ui.geometry : Point, Rect, Size;
import sparkles.ui.interp.cells : blend;
import sparkles.ui.style : Visual;

import sparkles.base.term_color : Color, RgbColor, toRgb;
import sparkles.base.term_style : UnderlineStyle;

@safe:

/**
Paints a display list into `grid` through a $(LREF GridCanvas) with `pageBg` as
the blend base. A dedicated dispatch (rather than the generic
$(REF paint, sparkles,ui,interp,immediate)) keeps the borrowed-`Grid` canvas
`scope`-local — it never leaves this call, so no stack `Grid` pointer escapes and
the whole path stays `@safe` under dip1000.
*/
void paintGrid(ref Grid grid, in RgbColor pageBg, in DrawOp[] ops,
    int originX = 0, int originY = 0)
{
    auto canvas = GridCanvas(&grid, pageBg, originX, originY);
    foreach (ref op; ops)
    {
        final switch (op.kind) with (OpKind)
        {
            case fillRect:
                canvas.fillRect(op.rect, op.visual);
                break;
            case textRun:
                canvas.textRun(op.rect.origin, op.text, op.visual);
                break;
            case glyph:
                canvas.glyph(op.rect.origin, op.glyph, op.visual);
                break;
            case line:
                canvas.line(op.rect.origin, op.to, op.visual, op.lineStyle);
                break;
        }
    }
}

/**
A `sparkles:ui` canvas that paints into a borrowed `sparkles.tui.Grid`. `pageBg`
is the blend base for translucent fills (a cell whose background is unset resolves
to it). Cell coordinates are the grid's own (the caller offsets a laid-out subtree
by translating its display list, or lays out at the target origin).
*/
struct GridCanvas
{
    Grid* grid;      /// the target grid (borrowed; must outlive the canvas)
    RgbColor pageBg; /// blend base for translucent fills / unset backgrounds
    int originX = 0; /// grid column of cell x = 0 (place a laid-out subtree)
    int originY = 0; /// grid row of cell y = 0

    private bool inBounds(int x, int y) const scope pure nothrow @nogc
    {
        const gx = originX + x, gy = originY + y;
        return grid !is null && gx >= 0 && gx < grid.cols && gy >= 0 && gy < grid.rows;
    }

    private ref auto cell(int x, int y) scope
        => grid.at(cast(ushort)(originX + x), cast(ushort)(originY + y));

    private RgbColor cellBg(in CellStyle st) const scope pure nothrow @nogc
        => toRgb(st.bg, pageBg);

    /// Composites `v.bg` (with its alpha) over the background of each cell in `r`,
    /// leaving glyphs and foregrounds intact.
    void fillRect(in Rect r, in Visual v) scope
    {
        if (!v.hasBg)
            return;
        foreach (y; r.y .. r.y + r.h)
            foreach (x; r.x .. r.x + r.w)
                if (inBounds(x, y))
                {
                    auto c = &cell(x, y);
                    c.style.bg = Color.fromRgb(blend(cellBg(c.style), v.bg, v.bgAlpha));
                }
    }

    /// Writes `text` at `at` in `v.fg`, advancing by each glyph's display width
    /// and preserving the cell background already painted underneath.
    void textRun(in Point at, scope const(char)[] text, in Visual v) scope
    {
        import std.utf : byDchar;

        int x = at.x;
        foreach (dchar cp; text.byDchar)
        {
            const w = codepointCellWidth(cp);
            if (w == 0)
                continue; // combining mark — no advance (cluster merge out of scope)
            if (inBounds(x, at.y))
                putGlyph(x, at.y, cp, cast(ubyte) w, v);
            x += w;
        }
    }

    /// Writes a single glyph `g` at `at` in `v.fg`.
    void glyph(in Point at, dchar g, in Visual v) scope
    {
        const w = codepointCellWidth(g);
        if (w != 0 && inBounds(at.x, at.y))
            putGlyph(at.x, at.y, g, cast(ubyte) w, v);
    }

    private void putGlyph(int x, int y, dchar cp, ubyte w, in Visual v) scope
    {
        auto c = &cell(x, y);
        auto st = c.style; // keep bg / underline already composited here
        st.fg = Color.fromRgb(v.fg);
        if (v.hasBg)
            st.bg = Color.fromRgb(blend(cellBg(st), v.bg, v.bgAlpha));
        c.setCodepoint(cp, w, st);
        // A wide glyph claims the next column as a zero-width continuation.
        if (w == 2 && inBounds(x + 1, y))
            cell(x + 1, y).setCodepoint(' ', 0, st);
    }

    /// Underlines the cells `from` → `to` in `v.fg`: `wavy` → an SGR-58 curly
    /// undercurl (the error squiggle), `solid` → a single underline. The glyphs
    /// beneath keep their own foreground.
    void line(in Point from, in Point to, in Visual v, LineStyle style) scope
    {
        const y = from.y;
        foreach (x; from.x .. to.x)
            if (inBounds(x, y))
            {
                auto c = &cell(x, y);
                c.style.underline = style == LineStyle.wavy
                    ? UnderlineStyle.curly : UnderlineStyle.single;
                c.style.underlineColor = Color.fromRgb(v.fg);
            }
    }

    /// The display-column extent of a text run (height 1) — the grid's own width
    /// authority, so measure and paint agree.
    Size measure(scope const(char)[] text) const scope
    {
        import std.utf : byDchar;

        int cols;
        foreach (dchar cp; text.byDchar)
            cols += codepointCellWidth(cp);
        return Size(cols, 1);
    }
}

static assert(isCanvas!GridCanvas);

// ---------------------------------------------------------------------------

@("tui_canvas.popupCompositesOverCode")
@safe unittest
{
    import sparkles.twoslash.protocol : Node, NodeType, TwoslashReturn;
    import sparkles.twoslash.render_widgets : viewHoverPopup;
    import sparkles.ui.display_list : buildDisplayList;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : defaultTwoslashPalette;

    // A hover popup: surface panel over a code signature.
    const tw = TwoslashReturn(code: "x\n", nodes: [
        Node(type: NodeType.hover, start: 0, length: 1, line: 0, character: 0,
            text: "const x: number"),
    ]);
    auto tree = viewHoverPopup(tw, 0);

    const pageFg = RgbColor(0xcd, 0xd6, 0xf4);
    const pageBg = RgbColor(0x1e, 0x1e, 0x2e);
    const pal = defaultTwoslashPalette();
    auto ops = buildDisplayList(tree, layout(tree), pal, pageFg, pageBg);

    Grid g;
    g.resize(40, 4);
    paintGrid(g, pageBg, ops);

    // The popup padding puts the signature at (1,1). Its cell shows the code
    // glyph with the surface background PRESERVED underneath (not the page bg).
    const sig = g.at(1, 1);
    assert(sig.grapheme == "c"); // "const x: number"[0]
    assert(sig.style.bg == Color.fromRgb(0xf8, 0xf8, 0xf8)); // opaque surface, kept under text
    // The corner of the surface fill (no glyph) is the surface color too.
    assert(g.at(0, 0).style.bg == Color.fromRgb(0xf8, 0xf8, 0xf8));
}

@("tui_canvas.errorSquiggleIsUndercurl")
@safe unittest
{
    import sparkles.ui.display_list : buildDisplayList;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : Slot, defaultTwoslashPalette;
    import sparkles.ui.widget : Builder, Widget, WidgetKind;

    // A bare wavy error line spanning 3 cells.
    auto b = Builder();
    const wavy = b.add(Widget(kind: WidgetKind.line, slot: Slot.error,
        lineStyle: LineStyle.wavy, lineTo: Point(3, 0)));
    auto tree = b.finish(b.container(WidgetKind.column, [wavy]));

    const pal = defaultTwoslashPalette();
    auto ops = buildDisplayList(tree, layout(tree), pal,
        RgbColor(0, 0, 0), RgbColor(0, 0, 0));

    Grid g;
    g.resize(5, 1);
    paintGrid(g, RgbColor(0, 0, 0), ops);

    foreach (x; 0 .. 3)
    {
        assert(g.at(cast(ushort) x, 0).style.underline == UnderlineStyle.curly);
        assert(g.at(cast(ushort) x, 0).style.underlineColor == Color.fromRgb(0xd4, 0x56, 0x56));
    }
    assert(g.at(3, 0).style.underline == UnderlineStyle.none);
}

@("tui_canvas.translucentHighlightBlends")
@safe unittest
{
    Grid g;
    g.resize(2, 1);
    // Seed a known cell background, then composite a 0x20 warm tint over it.
    g.at(0, 0).style.bg = Color.fromRgb(0x30, 0x30, 0x30);
    auto canvas = GridCanvas(&g, RgbColor(0, 0, 0));
    canvas.fillRect(Rect(0, 0, 1, 1),
        Visual(bg: RgbColor(0xc3, 0x7d, 0x0d), bgAlpha: 0x20, hasBg: true));
    const bg = g.at(0, 0).style.bg;
    // Blended toward the tint but still mostly the original dark grey.
    assert(bg != Color.fromRgb(0x30, 0x30, 0x30));
    assert(bg.rgb.r > 0x30 && bg.rgb.r < 0x50);
}
