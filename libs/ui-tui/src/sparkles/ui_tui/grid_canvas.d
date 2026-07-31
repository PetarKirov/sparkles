// The sparkles:tui adapter for `sparkles:ui` (`TGT6`).
//
// `GridCanvas` satisfies the `sparkles.ui.canvas.isCanvas` capability concept by
// painting the ui primitives into a `sparkles.tui.Grid`, so the same
// `view() -> layout() -> buildDisplayList() -> paint(canvas)` pipeline that
// drives the raylib GUI (hue's `gui_canvas.RaylibCanvas`, until it too is
// extracted) also drives the terminal — and `sparkles:tui`'s retained `Screen`
// diffs the grid to a minimal byte stream.
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
// terminal-free — `dub test :ui-tui` exercises it against a real `Grid`.
module sparkles.ui_tui.grid_canvas;

import sparkles.tui.cell : CellStyle, Grid;

import sparkles.base.text.width : codepointWidth;

import sparkles.ui.canvas : DrawOp, isCanvas, LineStyle, OpKind;
import sparkles.ui.geometry : Point, Rect, Size;
import sparkles.ui.interp.cells : blend;
import sparkles.ui.style : BorderStyle, Visual;

import sparkles.base.term_color : Color, RgbColor, toRgb;
import sparkles.base.term_style : TextAttr, UnderlineStyle;

@safe:

/**
Paints a display list into `grid` through a $(LREF GridCanvas) with `pageBg` as
the blend base. A dedicated dispatch (rather than the generic
$(REF paint, sparkles,ui,interp,immediate)) keeps the borrowed-`Grid` canvas
`scope`-local — it never leaves this call, so no stack `Grid` pointer escapes and
the whole path stays `@safe` under dip1000.
*/
void paintGrid(ref Grid grid, in RgbColor pageBg, in DrawOp[] ops,
    int originX = 0, int originY = 0, Rect clip = Rect.init)
{
    auto canvas = GridCanvas(&grid, pageBg, originX, originY);
    if (!clip.empty)
        canvas.pushClip(clip); // an outer viewport in canvas cell coordinates
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
            case pushClip:
                canvas.pushClip(op.rect);
                break;
            case popClip:
                canvas.popClip();
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

    /// The active clip stack in canvas cell coordinates (empty = unclipped).
    /// The display list pushes *effective* (pre-intersected) rects, but an
    /// externally pushed base viewport (`paintGrid`'s `clip`) is not folded
    /// into them, so a write must satisfy every entry.
    private Rect[] clips;

    private bool inBounds(int x, int y) const scope pure nothrow @nogc
    {
        const gx = originX + x, gy = originY + y;
        if (grid is null || gx < 0 || gx >= grid.cols || gy < 0 || gy >= grid.rows)
            return false;
        foreach (ref const c; clips)
            if (!c.contains(Point(x, y)))
                return false;
        return true;
    }

    /// The optional `sparkles:ui` clipping pair: cell writes outside the
    /// pushed rect are dropped (a scrolled viewport cannot bleed into chrome).
    void pushClip(in Rect r) scope
    {
        clips ~= r;
    }

    /// ditto
    void popClip() scope
    {
        if (clips.length)
            clips = clips[0 .. $ - 1];
    }

    private ref auto cell(int x, int y) scope
        => (*grid)[cast(ushort)(originX + x), cast(ushort)(originY + y)];

    /// Display width of `cp` in cells (control chars clamp to 1; combining = 0).
    private static int cellCols(dchar cp)
    {
        const w = codepointWidth(cp);
        return w < 0 ? 1 : w;
    }

    private RgbColor cellBg(in CellStyle st) const scope pure nothrow @nogc
        => toRgb(st.bg, pageBg);

    /// Composites `v.bg` (with its alpha) over each cell in `r`, then draws the
    /// box border the cell grid can express. Cell-grid degradations (documented in
    /// `docs/libs/ui/`): a sub-cell corner `radius` and the drop `shadow` have no
    /// cell representation and are dropped; a 1px border becomes either a cell
    /// underline (a bottom-only border — the `.twoslash-hover` dotted underline)
    /// or box-drawing glyphs on the rect perimeter (a full box — the popup).
    void fillRect(in Rect r, in Visual v) scope
    {
        if (v.hasBg)
            foreach (y; r.y .. r.y + r.height)
                foreach (x; r.x .. r.x + r.width)
                    if (inBounds(x, y))
                    {
                        auto c = &cell(x, y);
                        c.style.bg = Color.fromRgb(blend(cellBg(c.style), v.bg, v.bgAlpha));
                    }

        if (v.border.any)
        {
            const bw = v.border.width;
            const bottomOnly = bw.bottom > 0 && bw.top == 0 && bw.left == 0 && bw.right == 0;
            const fullBox = bw.top > 0 && bw.bottom > 0 && bw.left > 0 && bw.right > 0;
            if (bottomOnly && v.border.style == BorderStyle.solid && r.height == 1)
                ruleRow(r, v); // a thematic break: `─` glyphs, not an underline
            else if (bottomOnly)
                underlineRow(r, v);
            else if (fullBox)
                drawBoxBorder(r, v);
            // else: a single-side sub-cell accent (the docs top divider, the
            // error/tag left bar) has no cell analog and is dropped — the block's
            // background tint (if any) still conveys it.
        }
    }

    /// A solid bottom-only border on a one-row box → a `─` rule row (the
    /// thematic break; an underline on blank cells would be near-invisible).
    private void ruleRow(in Rect r, in Visual v) scope
    {
        foreach (x; r.x .. r.x + r.width)
            if (inBounds(x, r.y))
            {
                auto c = &cell(x, r.y);
                auto st = c.style;
                st.fg = Color.fromRgb(v.border.color);
                c.setCodepoint('─', 1, st);
            }
    }

    /// A bottom-only border → a cell underline on the rect's last row (dotted /
    /// dashed / single, matching the border style; the fade alpha has no cell
    /// analog so the underline is drawn at full strength).
    private void underlineRow(in Rect r, in Visual v) scope
    {
        const us = v.border.style == BorderStyle.dotted ? UnderlineStyle.dotted
            : v.border.style == BorderStyle.dashed ? UnderlineStyle.dashed
            : UnderlineStyle.single;
        const y = r.y + r.height - 1;
        foreach (x; r.x .. r.x + r.width)
            if (inBounds(x, y))
            {
                auto c = &cell(x, y);
                c.style.underline = us;
                c.style.underlineColor = Color.fromRgb(v.border.color);
            }
    }

    /// A full box border → box-drawing glyphs on the rect perimeter (which the
    /// popup's 1-cell padding leaves blank). Rounded corners approximate a
    /// `borderRadius`; a popup `arrow` becomes a `┴` notch on the top edge.
    private void drawBoxBorder(in Rect r, in Visual v) scope
    {
        if (r.width < 2 || r.height < 2)
            return;
        const fg = Color.fromRgb(v.border.color);
        const rounded = v.borderRadius > 0;
        const x0 = r.x, y0 = r.y, x1 = r.x + r.width - 1, y1 = r.y + r.height - 1;

        void setc(int x, int y, dchar g) scope
        {
            if (!inBounds(x, y))
                return;
            auto c = &cell(x, y);
            auto st = c.style;
            st.fg = fg;
            c.setCodepoint(g, 1, st);
        }

        foreach (x; x0 + 1 .. x1)
        {
            setc(x, y0, '─');
            setc(x, y1, '─');
        }
        foreach (y; y0 + 1 .. y1)
        {
            setc(x0, y, '│');
            setc(x1, y, '│');
        }
        setc(x0, y0, rounded ? '╭' : '┌');
        setc(x1, y0, rounded ? '╮' : '┐');
        setc(x0, y1, rounded ? '╰' : '└');
        setc(x1, y1, rounded ? '╯' : '┘');
        if (v.arrow)
            setc(x0 + 1 + v.arrowOffset, y0, '┴');
    }

    /// Writes `text` at `at` in `v.fg`, advancing by each glyph's display width
    /// and preserving the cell background already painted underneath.
    void textRun(in Point at, scope const(char)[] text, in Visual v) scope
    {
        import std.utf : byDchar;

        int x = at.x;
        foreach (dchar cp; text.byDchar)
        {
            const w = cellCols(cp);
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
        const w = cellCols(g);
        if (w != 0 && inBounds(at.x, at.y))
            putGlyph(at.x, at.y, g, cast(ubyte) w, v);
    }

    private void putGlyph(int x, int y, dchar cp, ubyte w, in Visual v) scope
    {
        auto c = &cell(x, y);
        auto st = c.style; // keep bg / underline already composited here
        st.fg = Color.fromRgb(v.fg);
        // The resolved text chrome: bold / italic / strikethrough travel as
        // packed `TextAttr` bits — dropping them here silently un-bolds
        // every widget-pipeline text run in the TUI.
        st.attrs = TextAttr(cast(ubyte) v.styleBits);
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
            cols += cellCols(cp);
        return Size(cols, 1);
    }
}

static assert(isCanvas!GridCanvas);

// ---------------------------------------------------------------------------

@("tui_canvas.popupCompositesOverCode")
@safe unittest
{
    import sparkles.ui.display_list : buildDisplayList;
    import sparkles.ui.geometry : Insets;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : defaultTwoslashPalette, Slot;
    import sparkles.ui.widget : Builder, Widget, WidgetKind;

    // A hover popup shape: an opaque surface panel padded around a code
    // signature (the tree the twoslash view builds, hand-authored here so the
    // backend has no dependency on any particular view).
    auto b = Builder();
    const sigNode = b.add(Widget(kind: WidgetKind.text, text: "const x: number",
        slot: Slot.code));
    const popup = b.container(WidgetKind.popup, [sigNode],
        slot: Slot.surface, padding: Insets.all(1), paintBackground: true);
    auto tree = b.finish(popup);

    const pageFg = RgbColor(0xcd, 0xd6, 0xf4);
    const pageBg = RgbColor(0x1e, 0x1e, 0x2e);
    const pal = defaultTwoslashPalette();
    auto ops = buildDisplayList(tree, layout(tree), pal, pageFg, pageBg);

    Grid g;
    g.resize(40, 4);
    paintGrid(g, pageBg, ops);

    // The popup padding puts the signature at (1,1). Its cell shows the code
    // glyph with the surface background PRESERVED underneath (not the page bg).
    const sig = g[1, 1];
    assert(sig.grapheme == "c"); // "const x: number"[0]
    assert(sig.style.bg == Color.fromRgb(0xf8, 0xf8, 0xf8)); // opaque surface, kept under text
    // The corner of the surface fill (no glyph) is the surface color too.
    assert(g[0, 0].style.bg == Color.fromRgb(0xf8, 0xf8, 0xf8));
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
        assert(g[cast(ushort) x, 0].style.underline == UnderlineStyle.curly);
        assert(g[cast(ushort) x, 0].style.underlineColor == Color.fromRgb(0xd4, 0x56, 0x56));
    }
    assert(g[3, 0].style.underline == UnderlineStyle.none);
}

@("tui_canvas.boxBorderAndDottedUnderline")
@safe unittest
{
    import sparkles.ui.style : BorderStyle;
    import sparkles.ui.geometry : Insets;

    // A rounded 4×3 popup surface with a full border and an arrow at offset 1 →
    // box-drawing perimeter with rounded corners and a `┴` arrow notch.
    Grid g;
    g.resize(6, 4);
    auto canvas = GridCanvas(&g, RgbColor(0, 0, 0));
    canvas.fillRect(Rect(0, 0, 4, 3),
        Visual(bg: RgbColor(0xf8, 0xf8, 0xf8), hasBg: true, borderRadius: 4, arrow: true,
            arrowOffset: 1, border: typeof(Visual.border)(width: Insets.all(1),
                style: BorderStyle.solid, color: RgbColor(0x88, 0x88, 0x88))));
    assert(g[0, 0].grapheme == "╭" && g[3, 0].grapheme == "╮");
    assert(g[0, 2].grapheme == "╰" && g[3, 2].grapheme == "╯");
    assert(g[2, 0].grapheme == "┴"); // arrow notch at x0 + 1 + arrowOffset(1)

    // A bottom-only dotted border → a dotted cell underline (no glyphs disturbed).
    Grid u;
    u.resize(3, 1);
    auto uc = GridCanvas(&u, RgbColor(0, 0, 0));
    uc.fillRect(Rect(0, 0, 3, 1),
        Visual(border: typeof(Visual.border)(width: Insets(0, 0, 1, 0),
            style: BorderStyle.dotted, color: RgbColor(0x22, 0x22, 0x22))));
    foreach (x; 0 .. 3)
        assert(u[cast(ushort) x, 0].style.underline == UnderlineStyle.dotted);
}

@("tui_canvas.translucentHighlightBlends")
@safe unittest
{
    Grid g;
    g.resize(2, 1);
    // Seed a known cell background, then composite a 0x20 warm tint over it.
    g[0, 0].style.bg = Color.fromRgb(0x30, 0x30, 0x30);
    auto canvas = GridCanvas(&g, RgbColor(0, 0, 0));
    canvas.fillRect(Rect(0, 0, 1, 1),
        Visual(bg: RgbColor(0xc3, 0x7d, 0x0d), bgAlpha: 0x20, hasBg: true));
    const bg = g[0, 0].style.bg;
    // Blended toward the tint but still mostly the original dark grey.
    assert(bg != Color.fromRgb(0x30, 0x30, 0x30));
    assert(bg.rgb.r > 0x30 && bg.rgb.r < 0x50);
}
