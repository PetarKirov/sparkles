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

import sparkles.ui.canvas : DrawOp, fillRectOp, isCanvas, LineStyle, OpKind,
    ruleSpan, RuleEdge, Scrollbar, scrollbarCell, scrollbarCellCount,
    textRunOp;
import sparkles.ui.geometry : Point, Rect, Size;
// The glyph decisions are the cell grid's, not this adapter's: two cell
// canvases each choosing their own box-drawing runs is how they came to
// disagree, with `--render` showing dashes the live terminal did not.
import sparkles.ui.glyphs : projectGlyph;
import sparkles.ui.interp.cells : accentGlyph, blend;
import sparkles.ui.effect : EffectId, EffectRegistry, Tier0Fn, Tier0Input;
import sparkles.ui.interp.immediate : paintImagePlaceholder;
import sparkles.ui.style : BorderStyle, Visual;
import sparkles.ui.tokens : boxGlyphs, projectBorder, TargetCapabilities;

import sparkles.base.term_color : Color, RgbColor, toRgb;
import sparkles.base.term_style : TextAttr, UnderlineStyle;

@safe:

/**
What a cell grid holds before any terminal narrows it (`CAP1`): every color
(the terminal's `Screen` folds to its real depth on the way out), every glyph
tier — a grid cell stores any code point, so blocks, braille and Nerd Font
icons all pass unprojected — link ids and styled underlines. The chrome a
pixel target honours — radius, shadow, alpha, a second face, sub-cell
scrolling — a grid always projects.

The default for a canvas nobody declared anything to, so every existing caller
paints exactly what it did; a live terminal passes its own declaration
(`TerminalSession.target`), and `ui-gallery --profile` passes a profile's.
*/
enum TargetCapabilities gridCapabilities = () {
    import sparkles.base.term_caps : BlockTier;
    import sparkles.base.term_color : ColorDepth;
    import sparkles.input.capability : cellPointer;

    TargetCapabilities c;
    c.colorDepth = ColorDepth.trueColor;
    c.unicode = true;
    c.blocks = BlockTier.octant;
    c.braille = true;
    c.nerdFont = true;
    c.hyperlinks = true;
    c.extendedUnderline = true;
    c.input = cellPointer;
    return c;
}();

/**
Paints a display list into `grid` through a $(LREF GridCanvas) with `pageBg` as
the blend base. A dedicated dispatch (rather than the generic
$(REF paint, sparkles,ui,interp,immediate)) keeps the borrowed-`Grid` canvas
`scope`-local — it never leaves this call, so no stack `Grid` pointer escapes and
the whole path stays `@safe` under dip1000.
*/
void paintGrid(ref Grid grid, in RgbColor pageBg, in DrawOp[] ops,
    int originX = 0, int originY = 0, Rect clip = Rect.init,
    in TargetCapabilities caps = gridCapabilities,
    in EffectContext effects = EffectContext.init)
{
    auto canvas = GridCanvas(&grid, pageBg, originX, originY, caps);
    canvas.effects = effects;
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
            case image:
                // `IMG5`'s fallback half. No terminal image protocol is
                // wired up yet — detection is the terminal's answer to give,
                // and nothing in the tree gives it — so every image takes
                // `IMG4`'s placeholder, through the SHARED routine rather
                // than a second one written here.
                paintImagePlaceholder(canvas, op.rect, op.imageAlt, op.visual);
                break;
            case pushEffect:
                canvas.pushEffect(op.rect, op.effectId);
                break;
            case popEffect:
                canvas.popEffect();
                break;
            case rule:
                // The cell backend has no sub-cell resolution: a hairline
                // becomes the box-drawing line along the same edge (UIA2).
                Point rf, rt;
                ruleSpan(op.rect, op.ruleEdge, rf, rt);
                canvas.line(rf, rt, op.visual, LineStyle.solid);
                break;
            case scrollbar:
                paintScrollbarCells(canvas, op);
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

private void paintScrollbarCells(ref scope GridCanvas canvas, in DrawOp op)
{
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

    const track = vertical ? op.rect.height : op.rect.width;
    const available = vertical ? op.rect.width : op.rect.height;
    int breadth = scrollbarCellCount(op.expandPercent);
    if (breadth > available)
        breadth = available;
    if (track <= 0 || breadth <= 0)
        return;

    int cross;
    final switch (op.ruleEdge) with (RuleEdge)
    {
        case left: case top:
            cross = vertical ? op.rect.x : op.rect.y;
            break;
        case right:
            cross = op.rect.x + op.rect.width - breadth;
            break;
        case bottom:
            cross = op.rect.y + op.rect.height - breadth;
            break;
        case centerX:
            cross = op.rect.x + (op.rect.width - breadth) / 2;
            break;
        case centerY:
            cross = op.rect.y + (op.rect.height - breadth) / 2;
            break;
    }

    foreach (at; 0 .. track)
    {
        const thumb = scrollbarCell(op.barContent, op.barViewport,
            op.barOffset, track, at);
        Visual visual = op.visual;
        if (!thumb)
            visual.fg = op.barTrackColor;
        foreach (across; 0 .. breadth)
        {
            const p = vertical
                ? Point(cross + across, op.rect.y + at)
                : Point(op.rect.x + at, cross + across);
            // Below `unicode` the thumb must still read against the track, so
            // it takes the solid fill rather than a second stroke (`GLY2`).
            const g = canvas.capabilities.unicode
                ? projectGlyph(thumb ? op.barThumbGlyph : op.barTrackGlyph,
                    canvas.capabilities)
                : (thumb ? '#' : vertical ? '|' : '-');
            canvas.glyph(p, g, visual);
        }
    }
}

/**
What a cell grid needs in order to honour a tier-0 effect (`EFX9`): the
registry that resolves an id, and the page foreground a `default`/`unset` cell
colour concretizes against.

$(B Optional, and absent by default.) A caller that passes none gets no
effects, which is `EFX3`'s declared degradation rather than a failure — the
same answer a canvas without the primitive gives. It travels as one value
because `paintGrid` has a long positional tail and two more parameters there
would be two more things to pass in the right order.

`pageFg` is here rather than on the canvas because the canvas never needed it:
a glyph arrives with its colour already resolved. Only an effect, which rewrites
a colour the grid already holds, has to ask what `default` means.
*/
struct EffectContext
{
    /// Borrowed; must outlive the paint. `null` disables effects entirely.
    const(EffectRegistry)* registry;
    /// What a `default`/`unset` foreground concretizes to before transforming.
    RgbColor pageFg;
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
    /// What the target can show (`CAP1`): every glyph written — chrome and
    /// text alike — is projected down its ladder to one the target admits
    /// (`GLY1`), without `hyperlinks` a cell carries no link id, and without
    /// `extendedUnderline` every underline is a straight one — each a row of
    /// `sparkles.ui.degradation`'s report.
    TargetCapabilities capabilities = gridCapabilities;

    /// The effect registry and page colours, or all-null for "no effects".
    EffectContext effects;

    /// The open effect brackets, innermost last. An unresolvable id still
    /// occupies a slot so `popEffect` stays paired with `pushEffect` — an
    /// `EFX17` miss must not desynchronise the stack.
    private ActiveEffect[] effectStack;

    private static struct ActiveEffect
    {
        Rect rect;
        Tier0Fn fn; /// null when the id resolved to nothing, or to a higher tier
    }

    /// The active clip stack in canvas cell coordinates (empty = unclipped).
    /// The display list pushes *effective* (pre-intersected) rects, but an
    /// externally pushed base viewport (`paintGrid`'s `clip`) is not folded
    /// into them, so a write must satisfy every entry.
    private Rect[] clips;

    /**
    `true` when row `y` is outside the grid or every pushed clip — so a caller
    can reject a whole run before doing per-character work.

    The row test alone, deliberately: it is the one that pays. A document
    scrolled to its middle has thousands of rows above and below the viewport
    and at most a screenful inside it, so rejecting by row turns "decode every
    character of every line" into "compare two integers per line". The column
    case stays with `inBounds`, where it costs one test on characters that are
    being walked anyway.
    */
    private bool rowOutside(int y) const scope pure nothrow @nogc
    {
        const gy = originY + y;
        if (grid is null || gy < 0 || gy >= grid.rows)
            return true;
        foreach (ref const c; clips)
            if (y < c.y || y >= c.y + c.height)
                return true;
        return false;
    }

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

    /// A glyph as this target can show it (`GLY1`).
    private dchar stroke(dchar g) const scope pure nothrow @nogc
        => projectGlyph(g, capabilities);

    /// An underline style as this target can draw it.
    private UnderlineStyle underlineOf(UnderlineStyle u) const scope pure nothrow @nogc
        => capabilities.extendedUnderline || u == UnderlineStyle.none
            ? u : UnderlineStyle.single;

    /**
    Opens an effect bracket (`EFX1`). Resolution happens here, once per
    bracket, rather than per cell.
    */
    void pushEffect(in Rect r, EffectId id) scope
    {
        Tier0Fn fn;
        if (effects.registry !is null)
            fn = effects.registry.tier0Of(id);
        effectStack ~= ActiveEffect(r, fn);
    }

    /**
    Closes the bracket and applies its tier-0 transform to the cells it
    covers (`EFX9`).

    $(B At pop, not per write.) The transform is defined over the $(I resolved)
    colour of each cell (`EFX8`), and a cell is only resolved once the subtree
    has finished painting it — a glyph drawn over a fill, an underline added
    afterwards. Hooking each of the canvas's ten write sites would apply the
    transform to intermediate states and would have to be repeated in each.

    $(B This is also what makes nesting compose) (`EFX2`). The inner bracket
    pops first and transforms its rect; the outer pops later and transforms
    its own, larger rect — over cells the inner one has already changed. So an
    ancestor's effect is applied to the descendant's result rather than
    replacing it, with no composition machinery of its own.

    $(B The declared cell-grid degradation.) The transform covers every cell in
    the bracket's rect, including any the subtree did not itself paint — a
    parent's background showing through a transparent panel is tinted along
    with the panel. A grid has no record of which subtree last touched a cell,
    and inventing one would cost a per-cell tag on every write to serve
    decoration. A GPU backend rendering the bracket to its own texture does not
    have this difference (`EFX11`).
    */
    void popEffect() scope
    {
        if (!effectStack.length)
            return;
        const active = effectStack[$ - 1];
        effectStack = effectStack[0 .. $ - 1];
        if (active.fn !is null)
            applyTier0(active.rect, active.fn);
    }

    private void applyTier0(in Rect r, Tier0Fn fn) scope
    {
        const extent = Size(r.width, r.height);
        foreach (y; r.y .. r.y + r.height)
        {
            if (rowOutside(y))
                continue;
            foreach (x; r.x .. r.x + r.width)
            {
                if (!inBounds(x, y))
                    continue;
                auto c = &cell(x, y);
                const at = Point(x - r.x, y - r.y);

                // Concretize, transform, write back as RGB. A cell whose
                // colour was `default` has been given one BY the effect,
                // which is what applying a colour transform to it means.
                c.style.fg = Color.fromRgb(
                    fn(Tier0Input(at, extent, toRgb(c.style.fg, effects.pageFg))));
                c.style.bg = Color.fromRgb(
                    fn(Tier0Input(at, extent, cellBg(c.style))));
                if (c.style.underline != UnderlineStyle.none)
                    c.style.underlineColor = Color.fromRgb(fn(Tier0Input(at,
                        extent, toRgb(c.style.underlineColor, effects.pageFg))));
            }
        }
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
        {
            // An opaque fill is a *surface*: it hides what it covers, so the
            // cell's glyph AND its decoration go with its background. A
            // translucent one is a tint over content that must stay legible
            // (the highlight band, the error line), so it keeps both — a
            // selection band over an error squiggle must not erase the
            // squiggle.
            const opaque = v.bgAlpha == 0xFF;
            foreach (y; r.y .. r.y + r.height)
            {
                if (rowOutside(y))
                    continue; // `DVG5`: skip the row's cells wholesale
                foreach (x; r.x .. r.x + r.width)
                    if (inBounds(x, y))
                    {
                        auto c = &cell(x, y);
                        c.style.bg = Color.fromRgb(blend(cellBg(c.style), v.bg, v.bgAlpha));
                        if (opaque)
                        {
                            c.bytes[0] = ' ';
                            c.len = 1;
                            c.width = 1;
                            // …and its DECORATION goes too. An underline is
                            // an attribute of the cell, not of the character
                            // in it, so blanking the glyph alone leaves the
                            // line painted: $(LREF GridCanvas.line) draws a
                            // horizontal rule AS an underline, so a surface
                            // laid over one kept a stripe running through
                            // itself, full width, at every ruled row.
                            c.style.underline = UnderlineStyle.none;
                            c.style.underlineColor = Color.init;
                            c.style.attrs = TextAttr.none;
                        }
                    }
            }
        }

        if (v.border.any)
        {
            const bw = v.border.width;
            const bottomOnly = bw.bottom > 0 && bw.top == 0 && bw.left == 0 && bw.right == 0;
            const leftOnly = bw.left > 0 && bw.top == 0 && bw.bottom == 0 && bw.right == 0;
            const rightOnly = bw.right > 0 && bw.top == 0 && bw.bottom == 0 && bw.left == 0;
            const fullBox = bw.top > 0 && bw.bottom > 0 && bw.left > 0 && bw.right > 0;
            const sidesOnly = bw.left > 0 && bw.right > 0 && bw.top == 0 && bw.bottom == 0;
            const openTop = bw.left > 0 && bw.right > 0 && bw.bottom > 0 && bw.top == 0;
            if (sidesOnly || openTop)
                openTopBox(r, v, openTop); // the fence chrome's side walls
            else if (leftOnly)
                barColumn(r, v); // the quote / callout accent bar
            else if (bottomOnly && v.border.style == BorderStyle.solid && r.height == 1)
                ruleRow(r, v); // a thematic break: `─` glyphs, not an underline
            else if (bottomOnly)
                underlineRow(r, v);
            else if (rightOnly)
                accentColumn(r, v, left: false);
            else if (fullBox)
                drawBoxBorder(r, v);
            // else: a TOP-only accent, which a cell genuinely cannot express —
            // there is an underline attribute and no overline. The block's
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
                c.setCodepoint(stroke('─'), 1, st);
            }
    }

    /// Sides-only / open-top borders → `│` down both side columns, plus a
    /// rounded `╰──╯` bottom when `closeBottom` (the markdown fence chrome:
    /// its glyph-composed top/scrollbar rows supply the other edges).
    private void openTopBox(in Rect r, in Visual v, bool closeBottom) scope
    {
        const fg = Color.fromRgb(v.border.color);
        void setc(int x, int y, dchar g) scope
        {
            if (!inBounds(x, y))
                return;
            auto c = &cell(x, y);
            auto st = c.style;
            st.fg = fg;
            c.setCodepoint(stroke(g), 1, st);
        }

        const x1 = r.x + r.width - 1;
        const yEnd = r.y + r.height - (closeBottom ? 1 : 0);
        foreach (y; r.y .. yEnd)
        {
            setc(r.x, y, '│');
            setc(x1, y, '│');
        }
        if (closeBottom && r.height >= 1)
        {
            const y1 = r.y + r.height - 1;
            foreach (x; r.x + 1 .. x1)
                setc(x, y1, '─');
            setc(r.x, y1, '╰');
            setc(x1, y1, '╯');
        }
    }

    /// A left-only border → glyphs down the rect's left column (the quote /
    /// callout accent bar; the panel's padding keeps content clear of it) —
    /// heavy `┃` for a border 2+ wide (the callout).
    private void barColumn(in Rect r, in Visual v) scope
    {
        const g = stroke(v.border.width.left >= 2 ? '┃' : '│');
        foreach (y; r.y .. r.y + r.height)
            if (inBounds(r.x, y))
            {
                auto c = &cell(r.x, y);
                auto st = c.style;
                st.fg = Color.fromRgb(v.border.color);
                c.setCodepoint(g, 1, st);
            }
    }

    /// A single vertical accent → an eighth-block in that column, weighted by
    /// the px width a pixel target would stroke — from the cell grid's own
    /// table (`accentGlyph`), not a second copy here. The right-side
    /// counterpart of `barColumn`, which owns the left (the goldens' form).
    private void accentColumn(in Rect r, in Visual v, bool left) scope
    {
        const bw = v.border.width;
        const x = left ? r.x : r.x + r.width - 1;
        const g = stroke(accentGlyph(left ? bw.left : bw.right, left));
        foreach (y; r.y .. r.y + r.height)
            if (inBounds(x, y))
            {
                auto c = &cell(x, y);
                auto st = c.style;
                st.fg = Color.fromRgb(v.border.color);
                c.setCodepoint(g, 1, st);
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
                c.style.underline = underlineOf(us);
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
        const x0 = r.x, y0 = r.y, x1 = r.x + r.width - 1, y1 = r.y + r.height - 1;

        void setc(int x, int y, dchar g) scope
        {
            if (!inBounds(x, y))
                return;
            auto c = &cell(x, y);
            auto st = c.style;
            st.fg = fg;
            c.setCodepoint(stroke(g), 1, st);
        }

        // One projection (`GLY2`) picks the family — weight, dash run, arcs
        // or ASCII — and one table strokes it, so this painter and the
        // degradation report cannot disagree about what a border became.
        const g = boxGlyphs(projectBorder(v.border, v.borderRadius, capabilities));
        foreach (x; x0 + 1 .. x1)
        {
            setc(x, y0, g.horizontal);
            setc(x, y1, g.horizontal);
        }
        foreach (y; y0 + 1 .. y1)
        {
            setc(x0, y, g.vertical);
            setc(x1, y, g.vertical);
        }
        setc(x0, y0, g.topLeft);
        setc(x1, y0, g.topRight);
        setc(x0, y1, g.bottomLeft);
        setc(x1, y1, g.bottomRight);
        if (v.arrow)
            setc(x0 + 1 + v.arrowOffset, y0, '┴');
    }

    /// Writes `text` at `at` in `v.fg`, advancing by each glyph's display width
    /// and preserving the cell background already painted underneath.
    void textRun(in Point at, scope const(char)[] text, in Visual v) scope
    {
        import std.utf : byDchar;

        // `DVG5`: an off-screen run costs one comparison, not a UTF-8 decode
        // and a width lookup per character. Scroll cost then tracks what is
        // VISIBLE rather than how long the document is.
        if (rowOutside(at.y))
            return;
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
        // A text-decoration underline rides the run's own visual (the tab
        // strip's bottom border); one another op composited stays.
        if (v.underline != UnderlineStyle.none)
        {
            st.underline = underlineOf(v.underline);
            st.underlineColor = st.fg;
        }
        if (v.hasBg)
            st.bg = Color.fromRgb(blend(cellBg(st), v.bg, v.bgAlpha));
        const link = capabilities.hyperlinks ? v.linkId : 0;
        // `GLY1`: nothing above the target's tier reaches the grid. Every
        // rung is one cell, so a wide glyph that folds fills both of its
        // cells with the stand-in rather than shifting the row.
        const shown = projectGlyph(cp, capabilities);
        if (shown != cp)
        {
            c.setCodepoint(shown, 1, st, link);
            if (w == 2 && inBounds(x + 1, y))
                cell(x + 1, y).setCodepoint(shown, 1, st, link);
            return;
        }
        c.setCodepoint(cp, w, st, link);
        // A wide glyph claims the next column as a zero-width continuation.
        if (w == 2 && inBounds(x + 1, y))
            cell(x + 1, y).setCodepoint(' ', 0, st, link);
    }

    /// Underlines the cells `from` → `to` in `v.fg`: `wavy` → an SGR-58 curly
    /// undercurl (the error squiggle), `solid` → a single underline. The glyphs
    /// beneath keep their own foreground.
    void line(in Point from, in Point to, in Visual v, LineStyle style) scope
    {
        if (from.y == to.y || from.x != to.x)
        {
            const y = from.y;
            foreach (x; from.x .. to.x)
                if (inBounds(x, y))
                {
                    auto c = &cell(x, y);
                    c.style.underline = underlineOf(style == LineStyle.wavy
                        ? UnderlineStyle.curly : UnderlineStyle.single);
                    c.style.underlineColor = Color.fromRgb(v.fg);
                }
            return;
        }
        // Vertical: no underline can express it, so it degrades to the cell's
        // own left edge — the eighth-block the accent borders already use, so
        // a rule and a border of the same weight agree. This REPLACES the
        // glyph where an underline rides alongside it; that asymmetry is the
        // cell grid's, not this function's.
        const x = from.x;
        const g = stroke(accentGlyph(1, left: true));
        foreach (y; from.y .. to.y)
            if (inBounds(x, y))
            {
                auto c = &cell(x, y);
                auto st = c.style;
                st.fg = Color.fromRgb(v.fg);
                c.setCodepoint(g, 1, st);
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

@("tui_canvas.opaqueFillHidesWhatItCovers")
@safe unittest
{
    // A popup is a surface, not a tint: whatever the document already painted
    // under it must be gone, or its text reads through the popup's blank areas.
    // A translucent fill is the opposite — it exists to let content show.
    import sparkles.ui.canvas : DrawOp, OpKind;
    import sparkles.ui.geometry : Rect;
    import sparkles.ui.style : Visual;

    Grid g;
    g.resize(20, 2);
    CellStyle st;
    g.putText(0, 0, "document text here", st);
    g.putText(0, 1, "document text here", st);

    const surface = RgbColor(0xf8, 0xf8, 0xf8);
    DrawOp[] ops = [
        fillRectOp(Rect(2, 0, 6, 1),
            visual: Visual(bg: surface, hasBg: true)),
        fillRectOp(Rect(2, 1, 6, 1),
            visual: Visual(bg: surface, hasBg: true, bgAlpha: 0x40)),
    ];
    paintGrid(g, RgbColor(0x1e, 0x1e, 0x2e), ops);

    assert(g[2, 0].grapheme == " ", "an opaque fill blanks the cell");
    assert(g[1, 0].grapheme == "o", "and only inside its own rect");
    assert(g[9, 0].grapheme == "t", "and stops at its right edge");
    assert(g[2, 1].grapheme == "c", "a translucent fill keeps the glyph");
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

@("tui_canvas.offScreenRunsCostAlmostNothing")
@safe unittest
{
    import std.datetime.stopwatch : StopWatch;

    // `DVG5`: scroll cost must track what is VISIBLE, not how long the
    // document is. The property is asserted as a ratio rather than a wall
    // time, so it holds on any machine: painting a document ten times longer
    // through the same small viewport must not cost ten times as much.
    //
    // Without the row rejection this fails outright — every off-screen run
    // decoded its characters, so the two loops differed by exactly the
    // document-length factor.
    static DrawOp[] document(size_t lines)
    {
        DrawOp[] ops;
        foreach (i; 0 .. lines)
            ops ~= textRunOp(
                Rect(0, cast(int) i, 60, 1),
                "const int some_reasonably_long_identifier = 12345;",
                visual: Visual(fg: RgbColor(0xcc, 0xcc, 0xcc)));
        return ops;
    }

    static long paintCost(in DrawOp[] ops, ushort rows)
    {
        Grid grid;
        grid.resize(80, rows);
        StopWatch sw;
        sw.start();
        foreach (_; 0 .. 20)
            paintGrid(grid, RgbColor(0x1e, 0x1e, 0x1e), ops,
                clip: Rect(0, 0, 80, rows));
        sw.stop();
        return sw.peek.total!"usecs";
    }

    enum ushort viewport = 40;
    const small = paintCost(document(200), viewport);
    const large = paintCost(document(4000), viewport);

    // 20× the document through the same viewport. The remaining cost is the
    // per-op walk and its row test, so allow generous headroom — the point is
    // that the factor is nowhere near 20.
    assert(large < small * 6,
        "off-screen rows must not cost what visible ones do");
}

@("tui_canvas.borderStylesAndAccentsMatchTheCellGrid")
@safe unittest
{
    import sparkles.ui.geometry : Insets;
    import sparkles.ui.interp.cells : CellGrid;
    import sparkles.ui.style : BorderStyle, BoxBorder;

    // Two cell canvases, one op stream, one picture — for BOX CHROME. They
    // drifted once: this adapter kept drawing `─`/`│` for every border style
    // and dropping every single-side accent long after the other had learnt
    // both, so a headless render showed dashes and accent bars the live
    // terminal did not.
    //
    // Scoped to `fillRect` deliberately. The two do NOT agree on text: this
    // one advances by `codepointWidth` and the other by one column per
    // codepoint, which is the open `LAY5`/`MIG5` measurement gap and not
    // something to freeze in a test. The glyph decisions box chrome makes now
    // live in one place; this is what keeps them there.
    const white = RgbColor(255, 255, 255);
    const black = RgbColor(0, 0, 0);

    void agreeOn(in Visual v, int w, int h)
    {
        Grid grid;
        grid.resize(cast(ushort) w, cast(ushort) h);
        auto canvas = GridCanvas(&grid, black);
        canvas.fillRect(Rect(0, 0, w, h), v);

        auto reference = CellGrid(w, h, white, black);
        reference.fillRect(Rect(0, 0, w, h), v);

        foreach (ushort y; 0 .. cast(ushort) h)
            foreach (ushort x; 0 .. cast(ushort) w)
            {
                const mine = grid[x, y].grapheme;
                const theirs = reference.cells[y * w + x].glyph;
                char[4] buf;
                import std.utf : encode;

                const n = encode(buf, theirs);
                assert(mine == buf[0 .. n],
                    "the two cell canvases disagree at a cell");
            }
    }

    // Every border style, as a full box.
    static foreach (style; [BorderStyle.solid, BorderStyle.dashed,
            BorderStyle.dotted])
        agreeOn(Visual(border: BoxBorder(width: Insets.all(1), style: style,
            color: white)), 6, 4);

    // A rounded box, whose corners differ from the square one's.
    agreeOn(Visual(borderRadius: 4, border: BoxBorder(width: Insets.all(1),
        style: BorderStyle.solid, color: white)), 6, 4);

    // Single-side accents, at each weight the eighth-blocks offer.
    static foreach (px; [1, 2, 3])
    {
        agreeOn(Visual(border: BoxBorder(width: Insets(0, 0, 0, px),
            style: BorderStyle.solid, color: white)), 6, 3);
        agreeOn(Visual(border: BoxBorder(width: Insets(0, px, 0, 0),
            style: BorderStyle.solid, color: white)), 6, 3);
    }

    // And the one-row thematic break, which is a rule rather than an underline.
    agreeOn(Visual(border: BoxBorder(width: Insets(0, 0, 1, 0),
        style: BorderStyle.solid, color: white)), 6, 1);
}

@("tui_canvas.scrollbarMatchesImmediateCellFallback")
@safe unittest
{
    import sparkles.ui.interp.cells : CellGrid;
    import sparkles.ui.interp.immediate : paint;

    const white = RgbColor(255, 255, 255);
    const grey = RgbColor(80, 80, 80);
    const black = RgbColor(0, 0, 0);

    foreach (edge; [RuleEdge.right, RuleEdge.bottom])
        foreach (expand; [0, 49, 50, 100])
            foreach (trackLit; [false, true])
            {
                const vertical = edge == RuleEdge.right;
                const op = DrawOp(Scrollbar(
                    rect: vertical ? Rect(1, 1, 2, 8) : Rect(1, 1, 8, 2),
                    content: 40,
                    viewport: 10,
                    offset: 15,
                    trackColor: grey,
                    trackLit: trackLit,
                    expandPercent: cast(ubyte) expand,
                    edge: edge,
                    trackGlyph: vertical ? '│' : '─',
                    thumbGlyph: vertical ? '█' : '━',
                    fg: white,
                ));

                Grid grid;
                grid.resize(10, 10);
                paintGrid(grid, black, [op]);

                auto reference = CellGrid(10, 10, white, black);
                paint(reference, [op]);

                foreach (ushort y; 0 .. 10)
                    foreach (ushort x; 0 .. 10)
                    {
                        const theirs = reference.cells[y * 10 + x].glyph;
                        char[4] buf;
                        import std.utf : encode;

                        const n = encode(buf, theirs);
                        assert(grid[x, y].grapheme == buf[0 .. n],
                            "the two semantic-scrollbar cell fallbacks disagree");
                    }
            }
}

@("ui_tui.grid_canvas.anOpaqueSurfaceHidesTheDecorationBeneathIt")
@safe unittest
{
    // A horizontal rule reaches the cell grid as an UNDERLINE (`line` has no
    // sub-cell resolution to draw one with), which makes it an attribute of
    // the cell rather than of the character in it. So a surface drawn over a
    // rule has to clear the attribute as well as the glyph — `apps/diagram`'s
    // settings pane over a lined grid backdrop showed the rule striping
    // straight through the panel, at full width, on every ruled row.
    Grid g;
    g.resize(20, 3);
    auto canvas = GridCanvas(&g, RgbColor(0, 0, 0));

    Visual rule;
    rule.fg = RgbColor(0x80, 0x80, 0x80);
    canvas.line(Point(0, 1), Point(20, 1), rule, LineStyle.solid);
    assert(g[5, 1].style.underline == UnderlineStyle.single, "the rule is drawn");

    Visual surface;
    surface.hasBg = true;
    surface.bg = RgbColor(0x20, 0x20, 0x28);
    surface.bgAlpha = 0xFF;
    canvas.fillRect(Rect(2, 0, 10, 3), surface);

    assert(g[5, 1].style.underline == UnderlineStyle.none,
        "the surface hides the rule under it");
    assert(g[15, 1].style.underline == UnderlineStyle.single,
        "…and only the part it actually covers");
}

@("ui_tui.grid_canvas.aTranslucentTintKeepsTheDecorationBeneathIt")
@safe unittest
{
    // The other half of the same rule, and the reason it is a conditional
    // rather than an unconditional reset: a selection band or a diff-row tint
    // is drawn OVER content that has to stay legible. Erasing the undercurl
    // under a highlighted error line would delete the error.
    Grid g;
    g.resize(20, 3);
    auto canvas = GridCanvas(&g, RgbColor(0, 0, 0));

    Visual squiggle;
    squiggle.fg = RgbColor(0xD4, 0x56, 0x56);
    canvas.line(Point(0, 1), Point(20, 1), squiggle, LineStyle.wavy);
    assert(g[5, 1].style.underline == UnderlineStyle.curly);

    Visual tint;
    tint.hasBg = true;
    tint.bg = RgbColor(0x40, 0x40, 0x60);
    tint.bgAlpha = 0x40;
    canvas.fillRect(Rect(0, 0, 20, 3), tint);

    assert(g[5, 1].style.underline == UnderlineStyle.curly,
        "a tint is not a surface: the squiggle under it survives");
}

@("tui_canvas.aVerticalRuleIsDrawnAtAll")
@safe unittest
{
    import sparkles.ui.canvas : ruleOp, RuleEdge;
    import sparkles.ui.style : Slot;

    // A cell grid has no sub-cell resolution, so a rule degrades to the cell
    // edge along it: a horizontal one to an underline, a vertical one to a
    // left eighth-block. The vertical case was not degraded — it was DROPPED:
    // `line` read `from.y` as the row and walked `from.x .. to.x`, which for a
    // vertical segment is an empty range. `apps/diagram`'s board showed it as
    // a lattice with horizontal rules and no verticals at all.
    Grid g;
    g.resize(6, 4);
    auto ops = [ruleOp(Rect(2, 0, 1, 4), RuleEdge.left, Slot.border,
        Visual(fg: RgbColor(0x88, 0x88, 0x88)))];
    paintGrid(g, RgbColor(0, 0, 0), ops);

    foreach (y; 0 .. 4)
        assert(g[2, cast(ushort) y].grapheme == "▏",
            "the whole column is stroked");
    assert(g[1, 0].grapheme == " ", "…and only that column");
    assert(g[3, 0].grapheme == " ");
}

@("tui_canvas.aHorizontalRuleReachesItsLastCell")
@safe unittest
{
    import sparkles.ui.canvas : ruleOp, RuleEdge;
    import sparkles.ui.style : Slot;

    // `ruleEndpoints` names the last cell ON the rule; `line` takes a
    // half-open span (a widget's `lineTo` is exclusive, which the undercurl
    // test above pins). The degradation passed one to the other unchanged, so
    // every rule came up one cell short of its own rect — a full-width board
    // rule stopped a column before the right edge.
    Grid g;
    g.resize(6, 2);
    auto ops = [ruleOp(Rect(0, 1, 6, 1), RuleEdge.top, Slot.border,
        Visual(fg: RgbColor(0x88, 0x88, 0x88)))];
    paintGrid(g, RgbColor(0, 0, 0), ops);

    foreach (x; 0 .. 6)
        assert(g[cast(ushort) x, 1].style.underline == UnderlineStyle.single,
            "the rule covers its whole rect, last cell included");
}

@("tui_canvas.capabilities.painterDoesWhatTheReportSays")
@safe unittest
{
    import sparkles.ui.canvas : BoxChrome, lineOp, Scrollbar, textRunOp;
    import sparkles.ui.degradation : degradationsOf, Substitution;
    import sparkles.ui.geometry : Insets;
    import sparkles.ui.tokens : capabilitiesOf, Profile;

    // `CAP6`'s other half: the report is a promise about the painter, so each
    // row it claims at `baseline` is checked against the cells this canvas
    // actually writes.
    static immutable BoxChrome box = () {
        BoxChrome c;
        c.border.width = Insets(1, 1, 1, 1);
        c.border.style = BorderStyle.dashed;
        c.borderRadius = 4;
        c.border.color = RgbColor(0x88, 0x88, 0x88);
        return c;
    }();
    auto link = Visual(fg: RgbColor(0x40, 0x80, 0xff), linkId: 1,
        underline: UnderlineStyle.curly);
    Scrollbar bar;
    bar.rect = Rect(9, 0, 1, 4);
    bar.content = 8;
    bar.viewport = 4;
    bar.edge = RuleEdge.right;
    bar.expandPercent = 100;
    const DrawOp[4] ops = [
        fillRectOp(Rect(0, 0, 6, 4), chrome: &box),
        textRunOp(Rect(1, 1, 2, 1), "go", visual: link),
        lineOp(Point(7, 0), Point(7, 3)),
        DrawOp(bar),
    ];

    const caps = capabilitiesOf(Profile.baseline);
    const report = degradationsOf(ops[], caps);
    assert(report[Substitution.asciiBorder] == 2); // the box, the vertical line
    assert(report[Substitution.radiusDropped] == 1);
    assert(report[Substitution.asciiScrollbar] == 1);
    assert(report[Substitution.linkAsText] == 1);
    assert(report[Substitution.plainUnderline] == 1);

    Grid g;
    g.resize(10, 4);
    paintGrid(g, RgbColor(0, 0, 0), ops[], caps: caps);

    foreach (y; 0 .. 4)
        foreach (x; 0 .. 10)
        {
            const c = g[cast(ushort) x, cast(ushort) y];
            foreach (ch; c.grapheme)
                assert(ch < 0x80, "a baseline frame paints only ASCII chrome");
            assert(c.linkId == 0, "no hyperlink without `hyperlinks`");
            assert(c.style.underline == UnderlineStyle.none
                || c.style.underline == UnderlineStyle.single);
        }
    assert(g[0, 0].grapheme == "+" && g[5, 3].grapheme == "+", "square ASCII corners");
    assert(g[1, 0].grapheme == "-" && g[0, 1].grapheme == "|");
    assert(g[7, 1].grapheme == "|");
    assert(g[1, 1].style.underline == UnderlineStyle.single);

    // The same list at the grid's own reach keeps every glyph it asked for.
    Grid u;
    u.resize(10, 4);
    paintGrid(u, RgbColor(0, 0, 0), ops[]);
    assert(u[0, 0].grapheme == "╭" && u[1, 1].linkId == 1);
    assert(u[1, 1].style.underline == UnderlineStyle.curly);
    assert(degradationsOf(ops[], gridCapabilities)[Substitution.asciiBorder] == 0);
}

@("tui_canvas.capabilities.theThemeIsNotGatedOnATerminal")
@safe unittest
{
    import std.algorithm : canFind;
    import std.array : appender;
    import sparkles.ui.display_list : buildDisplayList;
    import sparkles.ui.geometry : Insets;
    import sparkles.ui.interp.html : renderWidgetHtml;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : BoxBorder, Decoration, defaultTwoslashPalette, Slot;
    import sparkles.ui.tokens : capabilitiesOf, Profile;
    import sparkles.ui.widget : Builder, Widget, WidgetKind;

    // `CAP4`: one process, one theme, two targets. The cell target declared
    // `unicode = false` and draws ASCII; the HTML target, rendered from the
    // same tree and palette in the same process, is untouched by that.
    auto b = Builder();
    const label = b.add(Widget(kind: WidgetKind.text, text: "ok"));
    Decoration d;
    d.borderWidth = Insets.all(1);
    d.borderStyle = BorderStyle.solid;
    d.borderRadius = 4;
    const box = b.container(WidgetKind.panel, [label], slot: Slot.surface,
        padding: Insets.all(1), decoration: d);
    auto tree = b.finish(box);
    const pal = defaultTwoslashPalette();
    const fg = RgbColor(0, 0, 0), bg = RgbColor(0xff, 0xff, 0xff);
    auto ops = buildDisplayList(tree, layout(tree), pal, fg, bg);

    Grid cells;
    cells.resize(8, 3);
    paintGrid(cells, bg, ops, caps: capabilitiesOf(Profile.baseline));
    assert(cells[0, 0].grapheme == "+");

    auto out_ = appender!string;
    renderWidgetHtml(out_, tree, pal, fg, bg);
    const html = out_[];
    assert(html.canFind("border-radius"), "the HTML keeps its radius");
    assert(!html.canFind("+--"), "and no ASCII chrome leaked in");

    Grid unicode;
    unicode.resize(8, 3);
    paintGrid(unicode, bg, ops);
    assert(unicode[0, 0].grapheme == "╭", "nor did the first paint change the theme");
}

@("tui_canvas.capabilities.glyphChannel")
@safe unittest
{
    import sparkles.base.term_caps : BlockTier;
    import sparkles.ui.canvas : BoxChrome, lineOp, textRunOp;
    import sparkles.ui.degradation : degradationsOf, Substitution;
    import sparkles.ui.geometry : Insets;
    import sparkles.ui.tokens : capabilitiesOf, Profile;

    // `GLY1`/`GLY2` at the canvas: text runs are projected like chrome, a
    // wide glyph that folds keeps both of its cells, a 2px border strokes
    // heavy, and a Unicode target without blocks draws its accents as strokes.
    static immutable BoxChrome heavy = () {
        BoxChrome c;
        c.border.width = Insets(2, 2, 2, 2);
        c.border.style = BorderStyle.solid;
        return c;
    }();
    const DrawOp[3] ops = [
        fillRectOp(Rect(0, 0, 4, 3), chrome: &heavy),
        textRunOp(Rect(5, 0, 5, 1), "日▸✔"),
        lineOp(Point(5, 1), Point(5, 3)),
    ];

    Grid b;
    b.resize(10, 3);
    const baseline = capabilitiesOf(Profile.baseline);
    paintGrid(b, RgbColor(0, 0, 0), ops[], caps: baseline);
    assert(b[5, 0].grapheme == "?" && b[6, 0].grapheme == "?", "a wide glyph folds to two cells");
    assert(b[7, 0].grapheme == ">" && b[8, 0].grapheme == "+");
    assert(degradationsOf(ops[], baseline)[Substitution.asciiGlyph] == 1);

    Grid u;
    u.resize(10, 3);
    paintGrid(u, RgbColor(0, 0, 0), ops[]);
    assert(u[0, 0].grapheme == "┏" && u[1, 0].grapheme == "━", "2px is the heavy family");
    assert(u[5, 1].grapheme == "▏");

    auto noBlocks = capabilitiesOf(Profile.enhanced);
    noBlocks.blocks = BlockTier.none;
    Grid n;
    n.resize(10, 3);
    paintGrid(n, RgbColor(0, 0, 0), ops[], caps: noBlocks);
    assert(n[5, 1].grapheme == "│", "an eighth-block bar thins to the light stroke");
    assert(n[5, 0].grapheme == "日", "Unicode text is untouched");
    assert(degradationsOf(ops[], noBlocks)[Substitution.blocksFolded] == 1);
}

@("ui_tui.grid_canvas.tier0EffectLandsInTheTerminal")
@safe unittest
{
    import sparkles.ui.canvas : fillRectOp, popEffectOp, pushEffectOp;
    import sparkles.ui.effect : builtinEffects, EffectRegistry;
    import sparkles.ui.style : Slot, Visual;

    // `EFX24`'s claim, checked: a terminal showing scanlines is the proof
    // that the tier split is real and not a GPU feature wearing a label.
    EffectRegistry reg;
    const builtin = builtinEffects(reg);
    const ctx = EffectContext(&reg, RgbColor(0xFF, 0xFF, 0xFF));

    const white = RgbColor(0xFF, 0xFF, 0xFF);
    Visual fill;
    fill.bg = white;
    fill.hasBg = true;

    Grid grid;
    grid.resize(4, 4);
    paintGrid(grid, RgbColor(0, 0, 0), [
        pushEffectOp(Rect(0, 0, 4, 4), builtin.scanlines),
        fillRectOp(Rect(0, 0, 4, 4), Slot.inherit, fill),
        popEffectOp(),
    ], 0, 0, Rect.init, effects: ctx);

    // Even rows untouched, odd rows darkened — through the SAME D function
    // the GPU path would compile, not a terminal-only reimplementation.
    assert(grid[0, 0].style.bg.rgb == white);
    assert(grid[0, 1].style.bg.rgb.r < white.r);
    assert(grid[0, 2].style.bg.rgb == white);
    assert(grid[3, 1].style.bg.rgb == grid[0, 1].style.bg.rgb);

    // `EFX3`/`EFX17`: with no registry the very same op stream paints the
    // subtree unaffected, rather than failing.
    Grid plain;
    plain.resize(4, 4);
    paintGrid(plain, RgbColor(0, 0, 0), [
        pushEffectOp(Rect(0, 0, 4, 4), builtin.scanlines),
        fillRectOp(Rect(0, 0, 4, 4), Slot.inherit, fill),
        popEffectOp(),
    ]);
    assert(plain[0, 1].style.bg.rgb == white);
}

@("ui_tui.grid_canvas.nestedEffectsComposeWithTheirAncestors")
@safe unittest
{
    import sparkles.ui.canvas : fillRectOp, popEffectOp, pushEffectOp;
    import sparkles.ui.effect : builtinEffects, EffectRegistry;
    import sparkles.ui.style : Slot, Visual;

    EffectRegistry reg;
    const builtin = builtinEffects(reg);
    const ctx = EffectContext(&reg, RgbColor(0xFF, 0xFF, 0xFF));

    const white = RgbColor(0xFF, 0xFF, 0xFF);
    Visual fill;
    fill.bg = white;
    fill.hasBg = true;

    // `EFX2`: an inner `dim` inside an outer `dim` must be dimmer than either
    // alone — composing with the ancestor, not replacing it.
    Grid grid;
    grid.resize(4, 2);
    paintGrid(grid, RgbColor(0, 0, 0), [
        pushEffectOp(Rect(0, 0, 4, 2), builtin.dim),
        fillRectOp(Rect(0, 0, 4, 2), Slot.inherit, fill),
        pushEffectOp(Rect(0, 0, 2, 2), builtin.dim),
        fillRectOp(Rect(0, 0, 2, 2), Slot.inherit, fill),
        popEffectOp(),
        popEffectOp(),
    ], 0, 0, Rect.init, effects: ctx);

    const both = grid[0, 0].style.bg.rgb;
    const outerOnly = grid[3, 0].style.bg.rgb;
    assert(outerOnly.r < white.r, "the outer effect reached its own cells");
    assert(both.r < outerOnly.r, "the nested cell took BOTH, not just one");

    // An unbalanced stream must not corrupt the next frame: a stray pop is
    // ignored, and an unclosed push simply never applies.
    Grid odd;
    odd.resize(2, 1);
    paintGrid(odd, RgbColor(0, 0, 0), [
        popEffectOp(),
        pushEffectOp(Rect(0, 0, 2, 1), builtin.dim),
        fillRectOp(Rect(0, 0, 2, 1), Slot.inherit, fill),
    ], 0, 0, Rect.init, effects: ctx);
    assert(odd[0, 0].style.bg.rgb == white, "an unclosed bracket never fires");
}
