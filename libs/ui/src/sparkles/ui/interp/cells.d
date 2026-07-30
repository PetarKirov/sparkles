/**
The retained cell-grid interpreter for $(MREF sparkles,ui): $(LREF CellGrid) is a
$(REF isCanvas, sparkles,ui,canvas)-conforming canvas that paints a
$(REF DrawOp, sparkles,ui,canvas) stream into a 2-D buffer of character cells
(glyph + fg/bg + underline), then serializes to ANSI ($(LREF CellGrid.writeAnsi))
or emits a $(B minimal update) against a previous frame ($(LREF CellGrid.diff)) —
the retained path the interactive terminal twoslash overlay repaints each frame.

Unlike the immediate ANSI renderer (`sparkles:twoslash`'s `render_ansi`, which
walks the node model straight to escapes), this composites: translucent fills
($(D highlight)) blend over whatever is already in the cell, and a floating
popup simply overwrites the cells beneath it (paint order = z-order). That
compositing is exactly what a terminal overlay needs and an escape stream can't
express. GL-free; depends only on `sparkles:base`.
*/
module sparkles.ui.interp.cells;

import std.range.primitives : put;

import sparkles.ui.canvas : isCanvas, LineStyle;
import sparkles.ui.style : BorderStyle;
import sparkles.ui.geometry : cellsOf, Point, Rect, Size;
import sparkles.ui.style : Visual;

import sparkles.base.term_color :
    Color, ColorChannel, ColorDepth, RgbColor, writeSgrColor;
import sparkles.base.text.writers : writeInteger;

@safe:

/// One terminal cell: a glyph plus resolved fore/background and an optional
/// (possibly curly) underline. Compared field-for-field by $(LREF CellGrid.diff).
struct Cell
{
    dchar glyph = ' ';
    RgbColor fg;
    RgbColor bg;
    bool hasBg;
    bool underline;
    bool curly;              /// undercurl (SGR 4:3) — the error squiggle
    RgbColor underColor;
}

/// Alpha-composites `over` onto `base` (`a` = 0 keeps `base`, 255 = `over`).
RgbColor blend(in RgbColor base, in RgbColor over, ubyte a) pure nothrow @nogc
{
    ubyte mix(ubyte b, ubyte o) => cast(ubyte)((b * (255 - a) + o * a) / 255);
    return RgbColor(mix(base.r, over.r), mix(base.g, over.g), mix(base.b, over.b));
}

/**
A retained grid of $(LREF Cell)s (`width × height`, row-major) that paints the
`sparkles:ui` primitives. Construct with the page fore/background (the cleared
cell's colors and the blend base for translucent fills), paint a display list
into it via $(REF paint, sparkles,ui,interp,immediate), then serialize.
*/
struct CellGrid
{
    int width;
    int height;
    RgbColor pageFg;
    RgbColor pageBg;
    Cell[] cells; /// row-major, `width * height`

    /// Allocates a `w × h` grid cleared to the page colors.
    this(int w, int h, in RgbColor pageFg, in RgbColor pageBg)
    {
        this.width = w;
        this.height = h;
        this.pageFg = pageFg;
        this.pageBg = pageBg;
        cells = new Cell[](w * h);
        clear();
    }

    /// Resets every cell to a blank in the page colors.
    void clear()
    {
        foreach (ref c; cells)
            c = Cell(glyph: ' ', fg: pageFg, bg: pageBg);
    }

    /// The active clip stack (empty = unclipped). The display list pushes
    /// *effective* rects (ancestors already intersected), so only the top
    /// matters for the write guard.
    private Rect[] clips;

    private bool inBounds(int x, int y) const scope pure nothrow @nogc
        => x >= 0 && x < width && y >= 0 && y < height
            && (clips.length == 0 || clips[$ - 1].contains(Point(x, y)));

    private ref Cell at(int x, int y) pure nothrow @nogc
        => cells[y * width + x];

    /// The optional clipping pair: cell writes outside the pushed rect are
    /// dropped, so a scrolled viewport cannot bleed into the chrome around it.
    void pushClip(in Rect r)
    {
        clips ~= r;
    }

    /// ditto
    void popClip()
    {
        if (clips.length)
            clips = clips[0 .. $ - 1];
    }

    // --- isCanvas primitives ---

    /// Composites `v.bg` (respecting its alpha) over the cells of `r`, then
    /// draws the box chrome the cell grid can express: a full border becomes
    /// box-drawing glyphs on the perimeter, a solid bottom-only border on a
    /// one-row box becomes a `─` rule, any other bottom-only border a cell
    /// underline. Other single-side accents have no cell analog and drop.
    void fillRect(in Rect r, in Visual v)
    {
        if (v.hasBg)
            foreach (y; r.y .. r.y + r.height)
                foreach (x; r.x .. r.x + r.width)
                    if (inBounds(x, y))
                    {
                        auto c = &at(x, y);
                        c.bg = blend(c.hasBg ? c.bg : pageBg, v.bg, v.bgAlpha);
                        c.hasBg = true;
                    }

        if (v.border.any)
        {
            const bw = v.border.width;
            const bottomOnly = bw.bottom > 0 && bw.top == 0 && bw.left == 0
                && bw.right == 0;
            const fullBox = bw.top > 0 && bw.bottom > 0 && bw.left > 0
                && bw.right > 0;
            if (bottomOnly && v.border.style == BorderStyle.solid && r.height == 1)
            {
                // A thematic break: `─` glyphs, not an invisible underline row.
                foreach (x; r.x .. r.x + r.width)
                    if (inBounds(x, r.y))
                    {
                        auto c = &at(x, r.y);
                        c.glyph = '─';
                        c.fg = v.border.color;
                    }
            }
            else if (bottomOnly)
            {
                const y = r.y + r.height - 1;
                foreach (x; r.x .. r.x + r.width)
                    if (inBounds(x, y))
                    {
                        auto c = &at(x, y);
                        c.underline = true;
                        c.curly = false;
                        c.underColor = v.border.color;
                    }
            }
            else if (fullBox && r.width >= 2 && r.height >= 2)
            {
                const rounded = v.borderRadius > 0;
                const x0 = r.x, y0 = r.y;
                const x1 = r.x + r.width - 1, y1 = r.y + r.height - 1;
                void setc(int x, int y, dchar g)
                {
                    if (!inBounds(x, y))
                        return;
                    auto c = &at(x, y);
                    c.glyph = g;
                    c.fg = v.border.color;
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
        }
    }

    /// Writes `text` (one column per codepoint) at `at` in `v.fg`.
    void textRun(in Point at, scope const(char)[] text, in Visual v)
    {
        import std.utf : decode;

        int x = at.x;
        size_t i = 0;
        while (i < text.length)
        {
            dchar g;
            try
                g = decode(text, i);
            catch (Exception)
            {
                ++i;
                g = '�';
            }
            putGlyph(x, at.y, g, v);
            ++x;
        }
    }

    /// Writes a single glyph `g` at `at` in `v.fg`.
    void glyph(in Point at, dchar g, in Visual v)
    {
        putGlyph(at.x, at.y, g, v);
    }

    private void putGlyph(int x, int y, dchar g, in Visual v)
    {
        if (!inBounds(x, y))
            return;
        auto c = &at(x, y);
        c.glyph = g;
        c.fg = v.fg;
        if (v.hasBg)
        {
            c.bg = blend(c.hasBg ? c.bg : pageBg, v.bg, v.bgAlpha);
            c.hasBg = true;
        }
    }

    /// Underlines the row of cells `from` → `to` in `v.fg` (a terminal has no
    /// sub-cell rules, so a `line` becomes the covered cells' underline; a `wavy`
    /// line is undercurl — the twoslash error squiggle).
    void line(in Point from, in Point to, in Visual v, LineStyle style)
    {
        const y = from.y;
        foreach (x; from.x .. to.x)
            if (inBounds(x, y))
            {
                auto c = &at(x, y);
                c.underline = true;
                c.curly = style == LineStyle.wavy;
                c.underColor = v.fg;
            }
    }

    /// The cell extent of a text run (height 1); the width authority is `cellsOf`.
    Size measure(scope const(char)[] text) const
        => Size(cast(int) cellsOf(text), 1);

    // --- serialization ---

    /**
    Writes the whole grid to `w` as ANSI at `depth`: each row is an SGR-styled
    run of glyphs terminated by a reset + newline. A full frame (no cursor
    positioning); the diff path handles incremental repaints.
    */
    void writeAnsi(Writer)(ref Writer w, ColorDepth depth = ColorDepth.trueColor) const
    {
        foreach (y; 0 .. height)
        {
            foreach (x; 0 .. width)
                writeCell(w, cells[y * width + x], depth);
            put(w, "\x1b[0m");
            if (y + 1 < height)
                put(w, '\n');
        }
    }

    private void writeCell(Writer)(ref Writer w, in Cell c, ColorDepth depth) const
    {
        import std.utf : encode;

        // A fresh SGR per cell keeps this simple and correct; the diff path is
        // where run-coalescing matters.
        put(w, "\x1b[0m\x1b[");
        writeSgrColor(w, Color.fromRgb(c.fg), depth, ColorChannel.foreground);
        if (c.hasBg)
        {
            put(w, ';');
            writeSgrColor(w, Color.fromRgb(c.bg), depth, ColorChannel.background);
        }
        if (c.underline)
            put(w, c.curly ? ";4:3" : ";4");
        put(w, 'm');
        char[4] enc;
        const n = encode(enc, c.glyph);
        put(w, enc[0 .. n]);
    }

    /**
    Emits the minimal ANSI to turn a terminal showing `prev` into this grid:
    for each changed cell, a cursor move (`ESC[y;xH`, 1-based) + its styled glyph.
    Unchanged cells are skipped, so a hover that only reveals a popup repaints a
    few cells, not the screen. `prev` must share this grid's dimensions.
    */
    void diff(Writer)(ref Writer w, in CellGrid prev, ColorDepth depth = ColorDepth.trueColor) const
    in (prev.width == width && prev.height == height, "diff requires matching dimensions")
    {
        foreach (y; 0 .. height)
            foreach (x; 0 .. width)
            {
                const idx = y * width + x;
                if (cells[idx] == prev.cells[idx])
                    continue;
                put(w, "\x1b[");
                writeInteger(w, y + 1);
                put(w, ';');
                writeInteger(w, x + 1);
                put(w, 'H');
                writeCell(w, cells[idx], depth);
            }
        put(w, "\x1b[0m");
    }
}

static assert(isCanvas!CellGrid);

// ---------------------------------------------------------------------------

@("ui.cells.paintCompositesFillAndText")
@safe unittest
{
    import sparkles.ui.style : Slot, defaultTwoslashPalette, resolveSlot;
    import sparkles.ui.widget : Builder, Widget, WidgetKind;
    import sparkles.ui.geometry : Insets;
    import sparkles.ui.layout : layout;
    import sparkles.ui.display_list : buildDisplayList;
    import sparkles.ui.interp.immediate : paint;

    // popup(surface) over a one-line code run.
    auto b = Builder();
    const t = b.add(Widget(kind: WidgetKind.text, text: "T", slot: Slot.code));
    const popup = b.container(WidgetKind.popup, [t],
        slot: Slot.surface, padding: Insets.all(0), paintBackground: true);
    auto tree = b.finish(popup);

    const pageFg = RgbColor(0x22, 0x22, 0x22);
    const pageBg = RgbColor(0x1e, 0x1e, 0x2e);
    const pal = defaultTwoslashPalette();
    auto ops = buildDisplayList(tree, layout(tree), pal, pageFg, pageBg);

    auto grid = CellGrid(4, 2, pageFg, pageBg);
    paint(grid, ops);

    // Cell (0,0): the code glyph over the opaque surface background.
    assert(grid.at(0, 0).glyph == 'T');
    assert(grid.at(0, 0).fg == pageFg);           // code inherits page fg
    assert(grid.at(0, 0).hasBg && grid.at(0, 0).bg == RgbColor(0xf8, 0xf8, 0xf8));
    // An untouched cell keeps the page colors and a blank.
    assert(grid.at(3, 1).glyph == ' ' && !grid.at(3, 1).hasBg);
}

@("ui.cells.clipDropsWritesOutsideTheViewport")
@safe unittest
{
    import sparkles.ui.style : Visual;

    // A 2-row clip on a 4×4 grid: a run crossing the right edge and rows
    // outside the clip never reach the cells; after popClip writes land again.
    auto grid = CellGrid(4, 4, RgbColor(0xff, 0xff, 0xff), RgbColor(0, 0, 0));
    const v = Visual(fg: RgbColor(1, 2, 3));

    grid.pushClip(Rect(0, 0, 2, 2));
    grid.textRun(Point(0, 0), "abcd", v); // only "ab" lands
    grid.textRun(Point(0, 2), "yy", v);   // fully below the clip
    grid.popClip();
    grid.textRun(Point(0, 3), "zz", v);   // unclipped again

    assert(grid.at(0, 0).glyph == 'a' && grid.at(1, 0).glyph == 'b');
    assert(grid.at(2, 0).glyph == ' ' && grid.at(3, 0).glyph == ' ');
    assert(grid.at(0, 2).glyph == ' '); // clipped row untouched
    assert(grid.at(0, 3).glyph == 'z'); // popClip restored writes
}

@("ui.cells.translucentFillBlends")
@safe unittest
{
    auto grid = CellGrid(2, 1, RgbColor(0, 0, 0), RgbColor(0, 0, 0));
    // A 50% white fill over black → mid grey.
    grid.fillRect(Rect(0, 0, 1, 1), Visual(bg: RgbColor(255, 255, 255), bgAlpha: 128, hasBg: true));
    const b = grid.at(0, 0).bg;
    assert(b.r >= 126 && b.r <= 128);
}

@("ui.cells.wavyLineIsUndercurl")
@safe unittest
{
    auto grid = CellGrid(5, 1, RgbColor(0, 0, 0), RgbColor(0, 0, 0));
    grid.line(Point(1, 0), Point(4, 0), Visual(fg: RgbColor(0xd4, 0x56, 0x56)), LineStyle.wavy);
    assert(!grid.at(0, 0).underline);
    foreach (x; 1 .. 4)
        assert(grid.at(x, 0).underline && grid.at(x, 0).curly
            && grid.at(x, 0).underColor == RgbColor(0xd4, 0x56, 0x56));
}

@("ui.cells.diffOnlyEmitsChangedCells")
@safe unittest
{
    import std.algorithm.searching : canFind;
    import std.array : appender;

    const fg = RgbColor(0xcc, 0xcc, 0xcc);
    const bg = RgbColor(0, 0, 0);
    auto a = CellGrid(3, 1, fg, bg);
    auto b = CellGrid(3, 1, fg, bg);

    // b differs from a in one cell only.
    b.textRun(Point(1, 0), "X", Visual(fg: RgbColor(255, 0, 0)));

    auto w = appender!string;
    b.diff(w, a);
    const s = w[];
    // Cursor moved to row 1, col 2 (1-based) for the single changed cell.
    assert(s.canFind("\x1b[1;2H"));
    assert(s.canFind("X"));
    // The unchanged cols 1 and 3 are not addressed.
    assert(!s.canFind("\x1b[1;1H") && !s.canFind("\x1b[1;3H"));
}
